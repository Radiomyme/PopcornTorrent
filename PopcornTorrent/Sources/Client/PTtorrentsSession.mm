//
//  PTtorrentsSession.m
//  
//
//  Created by Alexandru Tudose on 21.09.2022.
//

#import <Foundation/Foundation.h>
#import "PTTorrentsSession.h"
#import "PTTorrentsSession+Testing.h"
#import "PTTorrentStreamer+Protected.h"
#import <libtorrent/session.hpp>
#import <libtorrent/torrent.hpp>
#import <libtorrent/alert.hpp>
#import <libtorrent/alert_types.hpp>
#import <libtorrent/bencode.hpp>
#import <libtorrent/write_resume_data.hpp>
#import <libtorrent/announce_entry.hpp>
#include "libtorrent/hex.hpp" // to_hex
#include <libtorrent/peer_connection.hpp>
#include <libtorrent/peer_info.hpp>
#include <libtorrent/aux_/session_interface.hpp>
#include <boost/asio/post.hpp>
#include <algorithm>
#include <cctype>
#include <set>
#include <sys/resource.h>
#import "../Bounded/PTStreamController.h"
#import "../Resources/NSString+Localization.h"


#if TARGET_OS_IOS || TARGET_OS_TV
#import <UIKit/UIApplication.h>
#endif

using namespace libtorrent;

#define ALERTS_LOOP_WAIT_MILLIS 500

// Testing aid: -1 = normal session, otherwise the loopback port (0 = any).
static int PTLoopbackTestingPort = -1;
// Testing aid: the network profile of another platform ("tv", "ios", "mac"; nil = this one).
static NSString *PTNetworkProfileOverride = nil;
// Testing aid: default trackers on 127.0.0.1 that loopback testing adds as a real session adds
// the public ones (nullptr: none are added in loopback testing).
static std::vector<std::string> *PTDefaultTrackersForTesting = nullptr;

#pragma mark - Network tuning

// What each kind of device can afford to download fast (NetworkBench numbers and the
// reasons for each value: BOUNDED_STORAGE.md, "Network").
struct PTNetworkTuning {
    int torrentConnections;   // peers per torrent (libtorrent: unlimited; this fork had 60)
    int connectionsLimit;     // peers for the whole session (libtorrent: 200; see PTRaiseOpenFilesLimit)
    int connectionSpeed;      // connection attempts per second (libtorrent: 30)
    int connectBoost;         // attempts at once when a torrent starts (libtorrent: 30)
    int queuedDiskBytes;      // received data waiting for the disk before peers are no longer read (1 MiB)
    int requestQueue;         // most block requests in flight to one peer (500, 16 KiB each)
    bool portMapping;         // UPnP and NAT-PMP: peers behind the router can connect to us
    bool localDiscovery;      // LSD (multicast)
};

static PTNetworkTuning PTNetworkTuningForProfile(NSString *profile) {
    if (profile == nil) {
#if TARGET_OS_TV
        profile = @"tv";
#elif TARGET_OS_IOS
        profile = @"ios";
#else
        profile = @"mac";
#endif
    }
    // Peers per torrent and connection attempts stay moderate: each attempt to a peer that
    // never answers holds an entry in the home router's NAT table for 30 s (uTP) to 2 min
    // (TCP SYN), and small ISP boxes drop connections for the whole household when that
    // table fills. 100 peers is already well above what a stream uses (NetworkBench: 8).
    if ([profile isEqualToString:@"tv"]) {
        // Plugged in, usually on Ethernet or 5 GHz Wi-Fi, a few GB of RAM: about 100 peers
        // cost a few MB. tvOS has no local network privacy: UPnP, NAT-PMP and LSD need no
        // entitlement and show no prompt (TN3179).
        return {100, 200, 40, 40, 4 * 1024 * 1024, 500, true, true};
    }
    if ([profile isEqualToString:@"ios"]) {
        // On battery. iOS asks the user before any unicast to the local network (NAT-PMP talks
        // to the router) and needs the multicast entitlement for UPnP and LSD: none of them.
        return {80, 160, 30, 30, 2 * 1024 * 1024, 500, false, false};
    }
    // Mac: room for a stream next to several downloads. macOS 15+ asks once for the local
    // network (the multicast entitlement is not needed there); UPnP / NAT-PMP / LSD just fail
    // when it is denied.
    return {100, 400, 50, 50, 16 * 1024 * 1024, 1000, true, true};
}

/// Public trackers added to every public torrent, after its own: magnets from the indexers
/// often carry few trackers (or dead ones) and peers come faster from several at once (every
/// tracker and tier is announced to, see setupSession). Never added to private torrents
/// (BEP 27) nor in the offline tests.
static std::vector<std::string> const& PTDefaultTrackers() {
    if (PTDefaultTrackersForTesting != nullptr) return *PTDefaultTrackersForTesting;
    static std::vector<std::string> const trackers = {
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.demonii.com:1337/announce",
        "udp://open.stealth.si:80/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://exodus.desync.com:6969/announce",
        "udp://explodie.org:6969/announce",
        "udp://tracker.dler.org:6969/announce",
        "udp://tracker.qu.ax:6969/announce",
        "udp://opentracker.io:6969/announce",
        "udp://tracker.theoks.net:6969/announce",
        "udp://tracker-udp.gbitt.info:80/announce",
        "udp://tracker.tiny-vps.com:6969/announce",
        "http://tracker.opentrackr.org:1337/announce",
    };
    return trackers;
}

/// Whether new torrents get the default trackers: always, but in loopback testing (unless a test
/// set loopback ones, `setDefaultTrackersForTesting:`).
static bool PTAddsDefaultTrackers() {
    return PTLoopbackTestingPort < 0 || PTDefaultTrackersForTesting != nullptr;
}

/// The local-network settings of a profile (see PTNetworkTuning): the session's, and what the
/// tests check for each profile (the loopback testing session turns them all off).
static void PTApplyLocalNetworkSettings(settings_pack& pack, PTNetworkTuning const& tuning) {
    pack.set_bool(settings_pack::enable_upnp, tuning.portMapping);
    pack.set_bool(settings_pack::enable_natpmp, tuning.portMapping);
    pack.set_bool(settings_pack::upnp_ignore_nonrouters, true);
    pack.set_bool(settings_pack::enable_lsd, tuning.localDiscovery);
}

/// `existing` followed by the default trackers it does not have yet (same URL, ignoring case
/// and a trailing slash), each in its own tier after the existing ones.
static void PTAppendDefaultTrackers(std::vector<std::string>& trackers, std::vector<int>& tiers) {
    auto normalized = [](std::string url) {
        std::transform(url.begin(), url.end(), url.begin(), [](unsigned char c) { return char(std::tolower(c)); });
        while (!url.empty() && url.back() == '/') url.pop_back();
        return url;
    };
    if (tiers.size() != trackers.size()) tiers.resize(trackers.size(), 0);
    std::set<std::string> known;
    int tier = 0;
    for (size_t i = 0; i < trackers.size(); ++i) {
        known.insert(normalized(trackers[i]));
        tier = std::max(tier, tiers[i] + 1);
    }
    for (std::string const& url : PTDefaultTrackers()) {
        if (!known.insert(normalized(url)).second) continue;
        trackers.push_back(url);
        tiers.push_back(tier++);
    }
}

/// Whether a tracker URL carries a key (a passkey in its path or query: "/<key>/announce",
/// "announce.php?passkey=..."), as private trackers' URLs do; public trackers announce at a
/// plain "/announce". A magnet with such a tracker may be a private torrent (BEP 27): it gets
/// the default trackers only once its metadata says it is not.
static bool PTTrackerLooksKeyed(std::string const& url) {
    auto const scheme = url.find("://");
    if (scheme == std::string::npos) return true;
    auto const slash = url.find('/', scheme + 3);
    if (slash == std::string::npos) return false; // "udp://host:port"
    std::string path = url.substr(slash);
    std::transform(path.begin(), path.end(), path.begin(), [](unsigned char c) { return char(std::tolower(c)); });
    if (path.find('?') != std::string::npos) return true;
    while (path.size() > 1 && path.back() == '/') path.pop_back();
    return !(path == "/" || path == "/announce" || path == "/announce.php");
}

/// The TCP/UDP port the session listens on (the next 10 when it is taken): picked at random
/// once per installation, outside the well-known BitTorrent ports (6881-6889) some networks
/// throttle or block, and not shared by two devices behind the same router (their port
/// mappings would collide), kept in the app's defaults so the router's mapping and the peers
/// that learned it stay valid.
static int PTListenPort(void) {
    static NSString *const key = @"PopcornTorrentListenPort";
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    int port = (int)[defaults integerForKey:key];
    if (port < 1024 || port > 65000) {
        port = 20000 + (int)arc4random_uniform(28000); // below the ephemeral range (49152+)
        [defaults setInteger:port forKey:key];
    }
    return port;
}

/// libtorrent caps the session's peers at 80 % of the soft limit of open files minus 20
/// (session_impl, when the session is created). Apps launched from the Finder, the Dock or
/// SpringBoard get a soft limit of 256: every profile became 188 peers in all, and one stream
/// could hold most of the process's descriptors, which GCDWebServer (two per HTTP
/// connection), the remuxed HLS files, AVFoundation, URLSession and SQLite also need (their
/// open or accept then simply fails). The soft limit is raised once, to 4096 or the hard
/// limit, before the first session is created.
static void PTRaiseOpenFilesLimit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        struct rlimit limit;
        if (getrlimit(RLIMIT_NOFILE, &limit) != 0) return;
        rlim_t const wanted = std::min<rlim_t>(limit.rlim_max, 4096);
        if (limit.rlim_cur >= wanted) return;
        rlim_t const before = limit.rlim_cur;
        limit.rlim_cur = wanted;
        if (setrlimit(RLIMIT_NOFILE, &limit) != 0) {
            NSLog(@"PopcornTorrent: could not raise the open files limit from %llu (errno %d)", (unsigned long long)before, errno);
        }
    });
}

@interface PTTorrentsSession () {
}

// Guarded by @synchronized (self): read on the alerts queue, written where streams start and stop.
@property (nonatomic, strong) NSMutableDictionary<NSString *, PTTorrentStreamer *> *streamers; // hash Id as key: the streamer that added the torrent
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<PTTorrentStreamer *> *> *guests; // streams that joined it, oldest first
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *pendingDeletions; // removals with delete_files not finished yet
@property (nonatomic, strong) NSMutableDictionary<NSString *, dispatch_group_t> *deletionGroups;
@property (nonatomic, strong) NSMutableSet<NSString *> *deferredDefaultTrackers; // magnets that get the default trackers with their metadata
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *deletionFolders; // the folder of a torrent removed with its files
@property (nonatomic, strong, nullable) dispatch_queue_t alertsQueue;
@property (nonatomic, getter=isAlertsLoopActive) BOOL alertsLoopActive;


@end

@implementation PTTorrentsSession {
    libtorrent::session *_session;
    std::string _listenInterfaces;
    int _torrentConnections;
    bool _dhtEnabled;
    int _minReconnectTime;
    NSInteger _reopenGeneration;
}

+ (void)prepareSharedSessionForLoopbackTestingOnPort:(int)port {
    PTLoopbackTestingPort = MAX(0, port);
}

+ (void)setNetworkProfileForTesting:(NSString *)profile {
    PTNetworkProfileOverride = [profile copy];
}

+ (NSArray<NSString *> *)trackersForTesting:(NSArray<NSString *> *)trackers {
    std::vector<std::string> list;
    for (NSString *url in trackers) list.push_back(url.UTF8String);
    std::vector<int> tiers;
    for (size_t i = 0; i < list.size(); ++i) tiers.push_back(int(i));
    PTAppendDefaultTrackers(list, tiers);
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (std::string const& url : list) [result addObject:[NSString stringWithUTF8String:url.c_str()]];
    return result;
}

- (NSDictionary<NSString *, NSNumber *> *)networkSettingsForTesting {
    if (_session == nullptr) return @{};
    settings_pack const pack = _session->get_settings();
    return @{
        @"connections_limit": @(pack.get_int(settings_pack::connections_limit)),
        @"connection_speed": @(pack.get_int(settings_pack::connection_speed)),
        @"torrent_connect_boost": @(pack.get_int(settings_pack::torrent_connect_boost)),
        @"max_queued_disk_bytes": @(pack.get_int(settings_pack::max_queued_disk_bytes)),
        @"max_out_request_queue": @(pack.get_int(settings_pack::max_out_request_queue)),
        @"peer_connect_timeout": @(pack.get_int(settings_pack::peer_connect_timeout)),
        @"utp_connect_timeout": @(pack.get_int(settings_pack::utp_connect_timeout)),
        @"file_pool_size": @(pack.get_int(settings_pack::file_pool_size)),
        @"request_queue_time": @(pack.get_int(settings_pack::request_queue_time)),
        @"whole_pieces_threshold": @(pack.get_int(settings_pack::whole_pieces_threshold)),
        @"announce_to_all_tiers": @(pack.get_bool(settings_pack::announce_to_all_tiers)),
        @"announce_to_all_trackers": @(pack.get_bool(settings_pack::announce_to_all_trackers)),
        @"enable_upnp": @(pack.get_bool(settings_pack::enable_upnp)),
        @"enable_natpmp": @(pack.get_bool(settings_pack::enable_natpmp)),
        @"enable_lsd": @(pack.get_bool(settings_pack::enable_lsd)),
        @"enable_dht": @(pack.get_bool(settings_pack::enable_dht)),
        @"torrent_connections": @(_torrentConnections),
        @"open_files_limit": @([PTTorrentsSession openFilesLimit]),
    };
}

+ (long long)openFilesLimit {
    struct rlimit limit;
    if (getrlimit(RLIMIT_NOFILE, &limit) != 0) return -1;
    return limit.rlim_cur == RLIM_INFINITY ? LLONG_MAX : (long long)limit.rlim_cur;
}

+ (BOOL)trackerLooksKeyedForTesting:(NSString *)url {
    return PTTrackerLooksKeyed(url.UTF8String);
}

+ (BOOL)isLoopbackTesting {
    return PTLoopbackTestingPort >= 0;
}

+ (NSArray<NSString *> *)setDefaultTrackersForTesting:(NSArray<NSString *> *)trackers {
    // Loopback URLs only: a test must never announce to a real tracker.
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    for (NSString *url in trackers) {
        NSString *host = [NSURL URLWithString:url].host;
        if ([host isEqualToString:@"127.0.0.1"] || [host isEqualToString:@"localhost"]) [kept addObject:url];
    }
    delete PTDefaultTrackersForTesting;
    PTDefaultTrackersForTesting = nullptr;
    if (kept.count == 0) return kept;
    PTDefaultTrackersForTesting = new std::vector<std::string>();
    for (NSString *url in kept) PTDefaultTrackersForTesting->push_back(url.UTF8String);
    return kept;
}

+ (NSDictionary<NSString *, NSNumber *> *)localNetworkSettingsForTesting:(NSString *)profile {
    settings_pack pack;
    PTApplyLocalNetworkSettings(pack, PTNetworkTuningForProfile(profile));
    return @{
        @"enable_upnp": @(pack.get_bool(settings_pack::enable_upnp)),
        @"enable_natpmp": @(pack.get_bool(settings_pack::enable_natpmp)),
        @"enable_lsd": @(pack.get_bool(settings_pack::enable_lsd)),
    };
}

- (int)listenPort {
    return _session ? (int)_session->listen_port() : 0;
}

- (void)reopenNetworkForTesting {
    [self reopenNetwork];
}

+ (instancetype)sharedSession {
    static dispatch_once_t onceToken;
    static PTTorrentsSession *sharedSession;

    static id backgroundToken;
    static id activeToken;
    static NSDate *lastDate;

    dispatch_once(&onceToken, ^{
        sharedSession = [[PTTorrentsSession alloc] init];

        // FIX: torrents not starting after apple tv comes from sleep after a period of time.
        // The sockets of a suspended app may be gone: reopen them (and the DHT) and
        // re-announce, in the same session. (A new session per long background used to be
        // created here: the old one leaked, with its threads and sockets, and the streams and
        // downloads already running stayed on it, with the sockets that had stopped working.)
        #if TARGET_OS_TV
        backgroundToken = [[NSNotificationCenter defaultCenter] addObserverForName: UIApplicationDidEnterBackgroundNotification
                                              object: nil
                                              queue: nil
                                              usingBlock:^(NSNotification *notification) {
                                                lastDate = [[NSDate alloc] init];
                                              }];

        double backgroundDuration = 5 * 60; // 5 minutes
        activeToken = [[NSNotificationCenter defaultCenter] addObserverForName: UIApplicationDidBecomeActiveNotification
                                              object: nil
                                              queue: nil
                                              usingBlock:^(NSNotification *notification) {
                                                if (lastDate && -[lastDate timeIntervalSinceNow] > backgroundDuration) {
                                                    [sharedSession reopenNetwork];
                                                }
                                                lastDate = nil;
                                              }];
        #endif
    });

    return sharedSession;
}

- (instancetype)init {
    self.streamers = [@{} mutableCopy];
    self.guests = [@{} mutableCopy];
    self.pendingDeletions = [@{} mutableCopy];
    self.deletionGroups = [@{} mutableCopy];
    self.deferredDefaultTrackers = [NSMutableSet set];
    self.deletionFolders = [@{} mutableCopy];
    [self setupSession];
    [self setupAlertLoop];
    return self;
}

- (void)setupSession {
    PTRaiseOpenFilesLimit();
    settings_pack pack = default_settings();
    PTNetworkTuning const tuning = PTNetworkTuningForProfile(PTNetworkProfileOverride);
    
    // libtorrent's node first (dht.libtorrent.org:25401), then the well-known routers. (A stray
    // quote used to make "dht.transmissionbt.com:6881'" an invalid entry.)
    auto dht_nodes = pack.get_str(settings_pack::dht_bootstrap_nodes);
    dht_nodes += ",router.bittorrent.com:6881,router.utorrent.com:6881,router.bitcomet.com:6881,dht.transmissionbt.com:6881,dht.aelitis.com:6881";
    pack.set_str(settings_pack::dht_bootstrap_nodes, dht_nodes);
    
    if (PTLoopbackTestingPort < 0) {
        std::string const port = std::to_string(PTListenPort());
        pack.set_str(settings_pack::listen_interfaces, "0.0.0.0:" + port + ",[::]:" + port);
    }
    pack.set_int(settings_pack::max_retry_port_bind, 10);
    
    pack.set_int(settings_pack::alert_mask,
                 alert::status_notification |
                 alert::piece_progress_notification |
                 alert::storage_notification
                 //                 alert::all_categories
                 );
    
    pack.set_bool(settings_pack::listen_system_port_fallback, false);
    pack.set_bool(settings_pack::suggest_read_cache, false);
    // Port mapping (see PTNetworkTuning): without it no peer behind another NAT can ever
    // connect to us. Set before the session starts (no split second of defaults).
    PTApplyLocalNetworkSettings(pack, tuning);
    // The selected file, the part file of the others and another torrent's (a stream next to
    // a download): 2 made libtorrent close and reopen files between writes.
    pack.set_int(settings_pack::file_pool_size, 8);

    // Peers: more of them, found faster (see PTNetworkTuning). A magnet lists each tracker in
    // its own tier and libtorrent announced to the first tier that answered only: one tracker.
    pack.set_int(settings_pack::connections_limit, tuning.connectionsLimit);
    pack.set_int(settings_pack::connection_speed, tuning.connectionSpeed);
    pack.set_int(settings_pack::torrent_connect_boost, tuning.connectBoost);
    pack.set_bool(settings_pack::announce_to_all_tiers, true);
    pack.set_bool(settings_pack::announce_to_all_trackers, true);
    // Most peers found by trackers and the DHT do not answer: give up on them after 10 s
    // instead of 15 (each one holds a connection slot meanwhile; 7 s made the attempts to
    // dead peers, and the NAT entries they leave in the router, come twice as fast).
    pack.set_int(settings_pack::peer_connect_timeout, 10);
    // libtorrent tries uTP first with every new peer; a peer without uTP (rtorrent seedboxes)
    // was only tried over TCP after 3 s.
    pack.set_int(settings_pack::utp_connect_timeout, 1500);
    // Throughput: received blocks waiting for the disk (above it libtorrent stops reading
    // the sockets), requests in flight per peer (fills the bandwidth-delay product of a fast,
    // distant peer: 500 x 16 KiB = 8 MiB, 1000 on the Mac).
    pack.set_int(settings_pack::max_queued_disk_bytes, tuning.queuedDiskBytes);
    pack.set_int(settings_pack::max_out_request_queue, tuning.requestQueue);
    // Fast peers no longer take whole pieces each (libtorrent: when a peer could download a
    // piece in 20 s): the blocks of the next pieces are spread over every peer, so pieces
    // complete in file order at the speed of the whole swarm, not one at the speed of the peer
    // that took it (a stream waits for the next piece, not for any piece).
    pack.set_int(settings_pack::whole_pieces_threshold, 0);
    // Requests in flight per peer: 2 s of its rate instead of 3. A request is served after
    // the ones queued before it: a seek, or the next piece of a stream, waited behind 3 s of
    // each peer's queue (NetworkBench, forward seek: first MiB 3.1 s at 3, 2.2 s at 2).
    // Not 1: the queue must cover a peer's round trip, or its rate falls, then its queue,
    // down to libtorrent's 2-block minimum; peers 1.2-1.5 s away (distant seedboxes, uplinks
    // bloated by other traffic) delivered 13 % of 256 MiB in 3 min at 1 s, all of it in 96 s
    // at 2, 79 s at 3.
    pack.set_int(settings_pack::request_queue_time, 2);
    _torrentConnections = tuning.torrentConnections;

    if (PTLoopbackTestingPort >= 0) {
        // Offline tests: localhost only, no DHT, LSD, UPnP or NAT-PMP.
        pack.set_str(settings_pack::listen_interfaces, "127.0.0.1:" + std::to_string(PTLoopbackTestingPort));
        pack.set_int(settings_pack::max_retry_port_bind, 0);
        pack.set_str(settings_pack::dht_bootstrap_nodes, "");
        pack.set_bool(settings_pack::enable_dht, false);
        pack.set_bool(settings_pack::enable_lsd, false);
        pack.set_bool(settings_pack::enable_upnp, false);
        pack.set_bool(settings_pack::enable_natpmp, false);
        pack.set_bool(settings_pack::allow_multiple_connections_per_ip, true);
    }

    _listenInterfaces = pack.get_str(settings_pack::listen_interfaces);
    _dhtEnabled = pack.get_bool(settings_pack::enable_dht);
    _minReconnectTime = pack.get_int(settings_pack::min_reconnect_time);

    // Settings take effect before the session starts (no split second of defaults). The
    // session parameters bring libtorrent's default plugins: ut_metadata, ut_pex and smart_ban
    // (ut_metadata and smart_ban used to be added a second time).
    _session = new session(session_params(std::move(pack)));
}

- (void)setupAlertLoop {
    self.alertsQueue = dispatch_queue_create("com.popcorntimetv.popcorntorrent.alerts", DISPATCH_QUEUE_SERIAL_WITH_AUTORELEASE_POOL);
    self.alertsLoopActive = YES;
    dispatch_async(self.alertsQueue, ^{
        [self alertsLoop];
    });
}

- (void)alertsLoop {
    std::vector<alert *> deque;
    time_duration max_wait = milliseconds(ALERTS_LOOP_WAIT_MILLIS);

    while ([self isAlertsLoopActive]) {
        // One pool per round: the loop never returns, so a pool around it never drained, and
        // every streamer an alert handler touched (streamersForTorrentHandle: returns an
        // autoreleased array holding them) stayed alive for the life of the process
        // (verify-playback: 15 streams closed, 15 PTTorrentStreamer and BoundedStorageSession
        // objects left, each session with its timer).
        @autoreleasepool {
            const alert *ptr = _session->wait_for_alert(max_wait);
            if (![self isAlertsLoopActive]) {
                break;
            }
            
            try {
                if (ptr != nullptr && _session != nullptr) {
                    _session->pop_alerts(&deque);
                    for (alert* alert : deque) {
                        switch (alert->type()) {
                            case metadata_received_alert::alert_type:
                                [self metadataReceivedAlert:((metadata_received_alert *)alert)->handle];
                                break;
                                
                            case piece_finished_alert::alert_type:
                                [self pieceFinishedAlert:((piece_finished_alert *)alert)->handle forPieceIndex:((piece_finished_alert *)alert)->piece_index];
                                break;
                                // In case the video file is already fully downloaded
                            case torrent_finished_alert::alert_type:
                                [self torrentFinishedAlert:((torrent_finished_alert *)alert)->handle];
                                break;
                            case save_resume_data_alert::alert_type: {
                                [self saveResumeDataWithAlert:(save_resume_data_alert *)alert];
                                break;
                            }
                            case file_error_alert::alert_type: {
                                [self fileErrorAlert:(file_error_alert *)alert];
                                break;
                            }
                            case torrent_deleted_alert::alert_type:
                                [self deletionFinished:((torrent_deleted_alert *)alert)->info_hash];
                                break;
                            case torrent_delete_failed_alert::alert_type:
                                [self deletionFinished:((torrent_delete_failed_alert *)alert)->info_hash];
                                break;
                            default:
                                break;
                        }
                    }
                    deque.clear();
                    deque.shrink_to_fit();
                }
            } catch (const std::exception& e) {
                NSLog(@"%s", e.what());
            }
        }
    }
}

- (NSString *)hashIDForTorrentHandle:(torrent_handle)th {
    NSString *hashId = [NSString stringWithCString:aux::to_hex(th.info_hash()).c_str() encoding:NSUTF8StringEncoding];
    return hashId;
}

- (NSString *)hashIDForParams:(add_torrent_params const &)params {
    sha1_hash const hash = params.ti ? params.ti->info_hash() : params.info_hash;
    return [NSString stringWithCString:aux::to_hex(hash).c_str() encoding:NSUTF8StringEncoding];
}

- (PTTorrentStreamer *)torrentStreamerForTorrentHandle:(libtorrent::torrent_handle)torrentHandle {
    NSString *hashID = [self hashIDForTorrentHandle:torrentHandle];
    @synchronized (self) {
        return self.streamers[hashID];
    }
}

/// The owner first, then the streams that joined its torrent (oldest first).
- (NSArray<PTTorrentStreamer *> *)streamersForTorrentHandle:(torrent_handle)th {
    NSString *hashID = [self hashIDForTorrentHandle:th];
    @synchronized (self) {
        NSMutableArray<PTTorrentStreamer *> *result = [NSMutableArray array];
        if (self.streamers[hashID]) [result addObject:self.streamers[hashID]];
        if (self.guests[hashID]) [result addObjectsFromArray:self.guests[hashID]];
        return result;
    }
}

- (void)metadataReceivedAlert:(torrent_handle)th {
    for (PTTorrentStreamer *streamer in [self streamersForTorrentHandle:th]) [streamer metadataReceivedAlert:th];
    [self addDeferredDefaultTrackers:th];
}

/// A magnet with keyed trackers (see addTorrent): the default trackers once its metadata
/// says it is public.
- (void)addDeferredDefaultTrackers:(torrent_handle)th {
    NSString *hashId = [self hashIDForTorrentHandle:th];
    @synchronized (self) {
        if (![self.deferredDefaultTrackers containsObject:hashId]) return;
        [self.deferredDefaultTrackers removeObject:hashId];
    }
    auto const ti = th.torrent_file();
    if (!ti || ti->priv()) return;
    std::vector<announce_entry> const existing = th.trackers();
    std::vector<std::string> urls;
    std::vector<int> tiers;
    for (announce_entry const& entry : existing) {
        urls.push_back(entry.url);
        tiers.push_back(entry.tier);
    }
    size_t const known = urls.size();
    PTAppendDefaultTrackers(urls, tiers);
    for (size_t i = known; i < urls.size(); ++i) {
        announce_entry entry(urls[i]);
        entry.tier = std::uint8_t(std::min(tiers[i], 255));
        th.add_tracker(entry);
    }
}

- (void)pieceFinishedAlert:(torrent_handle)th forPieceIndex:(piece_index_t)index {
    for (PTTorrentStreamer *streamer in [self streamersForTorrentHandle:th]) [streamer pieceFinishedAlert:th forPieceIndex:index];
}

- (torrent_handle)addTorrent:(PTTorrentStreamer *)torrentStreamer params:(add_torrent_params)torrentParams error:(NSError **)error {
    NSString *hashId = [self hashIDForParams:torrentParams];
    @synchronized (self) {
        if (self.streamers[hashId] != nil) {
            // Not added again (libtorrent would hand back the same torrent): the caller decides.
            *error = [[NSError alloc] initWithDomain:@"com.popcorntimetv.popcorntorrent.error" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"Torrent already added"}];
            return self.streamers[hashId].torrentHandle;
        }
    }
    // The same torrent removed with its files a moment ago: libtorrent deletes them by path
    // on its disk thread, which would delete the new torrent's file too. Wait for it.
    [self waitForPendingDeletionOf:hashId];
    // Once that deletion was done, its folder went too when it was empty (deletionFinished:
    // rmdir): the one this stream created before it waited, when both use the same one (a
    // stream of the same magnet started again at once). Without it the stream saw no free
    // space limit and no hole punching (bounded storage disabled, a file that does not fit
    // streamed in full).
    if (!torrentParams.save_path.empty()) {
        [[NSFileManager defaultManager] createDirectoryAtPath:[NSString stringWithUTF8String:torrentParams.save_path.c_str()]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
    }

    // Never auto-managed: libtorrent's auto-manager (3 active downloads by default) would
    // queue a new stream behind other torrents, and resume torrents paused on purpose.
    // Streams always run; downloads run until they are paused, explicitly.
    torrentParams.flags &= ~libtorrent::torrent_flags::auto_managed;
    torrentParams.flags &= ~libtorrent::torrent_flags::paused;
    // Streams fetch the file in order (bounded storage depends on it); an offline download
    // nobody plays fetches the rarest pieces first (PTTorrentDownload, wantsSequentialDownload).
    if ([torrentStreamer wantsSequentialDownload]) {
        torrentParams.flags |= libtorrent::torrent_flags::sequential_download;
    } else {
        torrentParams.flags &= ~libtorrent::torrent_flags::sequential_download;
    }
    // The default trackers: never for a private torrent (BEP 27: its info-hash must not reach
    // other trackers). A magnet does not say whether it is private until its metadata comes:
    // one whose trackers carry a key gets them then, if it is public (metadataReceivedAlert).
    bool const isPrivate = torrentParams.ti && torrentParams.ti->priv();
    bool const mayBePrivate = !torrentParams.ti
        && std::any_of(torrentParams.trackers.begin(), torrentParams.trackers.end(), PTTrackerLooksKeyed);
    if (PTAddsDefaultTrackers() && !isPrivate && !mayBePrivate) PTAppendDefaultTrackers(torrentParams.trackers, torrentParams.tracker_tiers);
    // A torrent still in libtorrent but not registered here is an error, not a silent reuse
    // (it would not have this stream's plugin).
    torrentParams.flags |= libtorrent::torrent_flags::duplicate_is_error;

    error_code ec_1;
    torrent_handle th = _session->add_torrent(std::move(torrentParams), ec_1);
    
    if (ec_1) {
        *error = [[NSError alloc] initWithDomain:@"com.popcorntimetv.popcorntorrent.error" code:-1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithCString:ec_1.message().c_str() encoding:NSUTF8StringEncoding]}];
        return th;
    }
    
    th.set_max_connections(_torrentConnections);
    th.set_max_uploads(10);
    
    @synchronized (self) {
        self.streamers[[self hashIDForTorrentHandle:th]] = torrentStreamer;
        if (PTAddsDefaultTrackers() && mayBePrivate) [self.deferredDefaultTrackers addObject:[self hashIDForTorrentHandle:th]];
    }
    
#if TARGET_OS_IOS
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
    });
#endif
    return th;
}

- (void)torrentFinishedAlert:(torrent_handle)th {
    // The streamer decides: full mode pauses the finished torrent, bounded mode keeps it.
    for (PTTorrentStreamer *streamer in [self streamersForTorrentHandle:th]) [streamer torrentFinishedAlert:th];
}

#pragma mark Shared torrents

- (torrent_handle)joinTorrent:(PTTorrentStreamer *)guest params:(add_torrent_params const &)torrentParams error:(NSError **)error {
    NSString *hashId = [self hashIDForParams:torrentParams];
    PTTorrentStreamer *owner = nil;
    PTTorrentStreamer *driving = nil;
    BOOL first = NO;
    @synchronized (self) {
        owner = self.streamers[hashId];
        // A download keeps its own copy of the file; a bounded stream deletes what it read.
        if (owner != nil && [guest canJoinSharedTorrent] && [owner canShareTorrentWithGuests] && owner.torrentHandle.is_valid()) {
            NSMutableArray<PTTorrentStreamer *> *guests = self.guests[hashId];
            if (guests == nil) {
                guests = [NSMutableArray array];
                self.guests[hashId] = guests;
            }
            driving = guests.lastObject ?: owner;
            first = guests.count == 0;
            [guests addObject:guest];
        } else {
            owner = nil;
        }
    }
    if (owner == nil) {
        NSString *description = @"This video is already being played or downloaded. Stop the other playback or the download, then try again.".localizedString;
        *error = [[NSError alloc] initWithDomain:PTTorrentStreamerErrorDomain code:PTTorrentStreamerErrorTorrentInUse userInfo:@{NSLocalizedDescriptionKey: description}];
        return torrent_handle();
    }
    // The newest stream drives the torrent: the one before hands it over.
    auto controller = [driving controller];
    if (controller) controller->suspendPlanning();
    if (first) [owner sharedTorrentWillGainGuests];
    return owner.torrentHandle;
}

- (std::shared_ptr<ptbounded::StreamController>)leaveTorrent:(PTTorrentStreamer *)guest {
    PTTorrentStreamer *owner = nil;
    PTTorrentStreamer *next = nil;
    BOOL last = NO;
    @synchronized (self) {
        for (NSString *hashId in self.guests.allKeys) {
            NSMutableArray<PTTorrentStreamer *> *guests = self.guests[hashId];
            NSUInteger const index = [guests indexOfObjectIdenticalTo:guest];
            if (index == NSNotFound) continue;
            BOOL const driving = index == guests.count - 1;
            [guests removeObjectAtIndex:index];
            owner = self.streamers[hashId];
            if (driving) next = guests.lastObject ?: owner;
            if (guests.count == 0) {
                [self.guests removeObjectForKey:hashId];
                last = YES;
            }
            break;
        }
    }
    if (last) [owner sharedTorrentDidLoseGuests];
    return next ? [next controller] : nullptr;
}

- (PTTorrentStreamer *)ownerOfGuest:(PTTorrentStreamer *)guest {
    @synchronized (self) {
        for (NSString *hashId in self.guests) {
            if ([self.guests[hashId] indexOfObjectIdenticalTo:guest] != NSNotFound) return self.streamers[hashId];
        }
        return nil;
    }
}

- (BOOL)hasGuests:(PTTorrentStreamer *)owner {
    @synchronized (self) {
        for (NSString *hashId in self.guests) {
            if (self.streamers[hashId] == owner && self.guests[hashId].count > 0) return YES;
        }
        return NO;
    }
}

#pragma mark Deletions

- (void)waitForPendingDeletionOf:(NSString *)hashId {
    dispatch_group_t group;
    @synchronized (self) {
        group = self.deletionGroups[hashId];
    }
    if (group == nil) return;
    if (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) {
        NSLog(@"PopcornTorrent: files of the previous %@ still being deleted after 5 s", hashId);
    }
}

- (void)deletionStarted:(NSString *)hashId {
    @synchronized (self) {
        dispatch_group_t group = self.deletionGroups[hashId];
        if (group == nil) {
            group = dispatch_group_create();
            self.deletionGroups[hashId] = group;
        }
        dispatch_group_enter(group);
        self.pendingDeletions[hashId] = @(self.pendingDeletions[hashId].integerValue + 1);
    }
}

- (void)deletionFinished:(sha1_hash const &)infoHash {
    NSString *hashId = [NSString stringWithCString:aux::to_hex(infoHash).c_str() encoding:NSUTF8StringEncoding];
    @synchronized (self) {
        NSInteger const pending = self.pendingDeletions[hashId].integerValue;
        dispatch_group_t group = self.deletionGroups[hashId];
        if (pending <= 0 || group == nil) return;
        if (pending == 1) {
            [self.pendingDeletions removeObjectForKey:hashId];
            [self.deletionGroups removeObjectForKey:hashId];
            // The streamer removed its folder when it cancelled, but piece writes still queued
            // on libtorrent's disk thread then created it again; delete_files removes the
            // files and the torrent's own folders, not this one: it stayed, empty. rmdir only
            // removes an empty folder (a stream of the same torrent started since writes into
            // it, and libtorrent creates its folders again when it writes).
            NSString *folder = self.deletionFolders[hashId];
            [self.deletionFolders removeObjectForKey:hashId];
            if (folder.length > 0 && self.streamers[hashId] == nil) rmdir(folder.fileSystemRepresentation);
        } else {
            self.pendingDeletions[hashId] = @(pending - 1);
        }
        dispatch_group_leave(group);
    }
}

#pragma mark Network

- (void)retryDroppedPeersSoon {
    if (_session == nullptr) return;
    settings_pack fast;
    fast.set_int(settings_pack::min_reconnect_time, 1);
    _session->apply_settings(fast);
    // The last call restores the setting, 30 s after it (a call meanwhile pushes it back).
    NSInteger generation;
    @synchronized (self) { generation = ++_reopenGeneration; }
    __weak __typeof__(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_session == nullptr) return;
        @synchronized (strongSelf) { if (strongSelf->_reopenGeneration != generation) return; }
        settings_pack restore;
        restore.set_int(settings_pack::min_reconnect_time, strongSelf->_minReconnectTime);
        strongSelf->_session->apply_settings(restore);
    });
}

- (void)reopenNetwork {
    if (_session == nullptr) return;
    // No listen socket (nor DHT), then the configured ones again: sockets are recreated even
    // when their address did not change (reopen_network_sockets keeps sockets that look the
    // same). Peer connections and torrents are kept.
    settings_pack off;
    off.set_str(settings_pack::listen_interfaces, "");
    if (_dhtEnabled) off.set_bool(settings_pack::enable_dht, false);
    _session->apply_settings(off);
    settings_pack on;
    on.set_str(settings_pack::listen_interfaces, _listenInterfaces);
    if (_dhtEnabled) on.set_bool(settings_pack::enable_dht, true);
    _session->apply_settings(on);
    // Peers whose connection went with the old sockets (uTP runs over the listen socket's
    // UDP socket) are only retried after min_reconnect_time (60 s): a stream would stall
    // that long. Retry them at once for a little while.
    [self retryDroppedPeersSoon];
    for (torrent_handle const& handle : _session->get_torrents()) {
        // uTP connections ran over a UDP socket that is closed now: nothing tells them, and
        // one that does not send would hang until its timeout (about a minute). Drop them:
        // they are retried at once. (On the network thread, after the settings above.)
        std::weak_ptr<libtorrent::torrent> weak = handle.native_handle();
        if (auto torrent = weak.lock()) {
            boost::asio::post(torrent->session().get_io_service(), [weak] {
                auto t = weak.lock();
                if (!t) return;
                std::vector<std::shared_ptr<peer_connection>> utp;
                for (peer_connection *connection : *t) {
                    peer_info info;
                    connection->get_peer_info(info);
                    if (info.flags & peer_info::utp_socket) utp.push_back(connection->self());
                }
                for (auto const& connection : utp) {
                    connection->disconnect(boost::asio::error::network_reset, operation_t::sock_read);
                }
            });
        }
        // Find peers again at once (trackers, DHT) instead of at the next announce interval.
        handle.force_reannounce(0, -1, torrent_handle::ignore_min_interval);
        if (_dhtEnabled) handle.force_dht_announce();
    }
    NSLog(@"PopcornTorrent: network reopened after a long time in the background");
}

- (void)finishTorrent:(PTTorrentStreamer *)torrentStreamer {
    auto torrent = torrentStreamer.torrentHandle;
    if (!torrent.is_valid()) {
        return;
    }
    // Not auto-managed any more, or libtorrent's auto-manager would resume it and seed in the background.
    torrent.unset_flags(torrent_flags::auto_managed);
    if (torrent.need_save_resume_data()) {
        torrent.save_resume_data();
    }
    torrent.flush_cache();
    torrent.pause(torrent_handle::graceful_pause);
}

- (void)removeTorrent:(PTTorrentStreamer *)torrentStreamer {
    (void)[self removeTorrent:torrentStreamer deleteFiles:NO saveResumeData:YES];
}

- (BOOL)removeTorrent:(PTTorrentStreamer *)torrentStreamer deleteFiles:(BOOL)deleteFiles saveResumeData:(BOOL)saveResumeData {
    if (!torrentStreamer.torrentHandle.is_valid()) {
        return NO;
    }
    
    auto torrent = torrentStreamer.torrentHandle;
    NSString *hashId = [self hashIDForTorrentHandle:torrent];
    NSArray<PTTorrentStreamer *> *orphans = nil;
    PTTorrentStreamer *heir = nil;
    @synchronized (self) {
        PTTorrentStreamer *registered = self.streamers[hashId];
        if (registered != torrentStreamer) {
            // The torrent belongs to another streamer of this session, or this one already
            // removed it: libtorrent's remove_torrent finds torrents by info-hash, so the
            // same torrent added again since then would be removed.
            return NO;
        }
        NSMutableArray<PTTorrentStreamer *> *guests = self.guests[hashId];
        if (guests.count > 0 && [torrentStreamer handsTorrentOverToGuests]) {
            // A stream other streams joined: the oldest one owns the torrent from now on.
            heir = guests.firstObject;
            [guests removeObjectAtIndex:0];
            if (guests.count == 0) [self.guests removeObjectForKey:hashId];
            self.streamers[hashId] = heir;
        } else {
            [self.streamers removeObjectForKey:hashId];
            [self.deferredDefaultTrackers removeObject:hashId];
            orphans = [guests copy];
            [self.guests removeObjectForKey:hashId];
            if (deleteFiles) {
                [self deletionStarted:hashId];
                if (torrentStreamer.savePath.length > 0) self.deletionFolders[hashId] = torrentStreamer.savePath;
            }
        }
    }
    if (heir != nil) {
        [heir sharedTorrentBecameOwned];
        return YES;
    }
    
    if (saveResumeData && !deleteFiles && torrent.need_save_resume_data()) {
        torrent.save_resume_data();
    }
    torrent.flush_cache();
    
    // A paused auto-managed torrent is resumed by libtorrent's auto-manager and keeps
    // downloading in the background: take it out of the session for good.
    torrent.unset_flags(torrent_flags::auto_managed);
    torrent.pause(torrent_handle::graceful_pause);
    _session->remove_torrent(torrent, deleteFiles ? session_handle::delete_files : remove_flags_t{});

    // Streams that joined this torrent: they go on only if the whole file is there.
    for (PTTorrentStreamer *guest in orphans) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [guest sharedTorrentRemovedByOwner:deleteFiles];
        });
    }

#if TARGET_OS_IOS
    if (_session->get_torrents().empty()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
        });
    }
#endif
    return NO;
}

- (void)fileErrorAlert:(file_error_alert *)alert {
    NSString *description = [NSString stringWithFormat:@"%s", alert->message().c_str()];
    BOOL diskFull = alert->error == boost::system::errc::no_space_on_device || alert->error.value() == EDQUOT;
    for (PTTorrentStreamer *streamer in [self streamersForTorrentHandle:alert->handle]) {
        [streamer fileErrorAlert:description diskFull:diskFull];
    }
}

- (void)saveResumeDataWithAlert:(save_resume_data_alert *)alert {
    // The alert carries the save path: the torrent may already be removed from the session.
    NSString *directory =  [NSString stringWithUTF8String:(alert->params.save_path + "/resumeData.fastresume").c_str()];

    auto const buf = write_resume_data_buf(alert->params);
    std::string str(buf.begin(), buf.end());
    
    NSData *resumeDataFile = [[NSData alloc] initWithBytesNoCopy:(char *)str.c_str() length:str.size() freeWhenDone:false];
    NSAssert(resumeDataFile != nil, @"Resume data failed to be generated");
    [resumeDataFile writeToFile:[NSURL URLWithString:directory].relativePath atomically:NO];
}

- (BOOL)tryToResumeTorrentParams:(add_torrent_params *)torrentParams atPath:(NSString *)directory {
    NSData *resumeData = [NSData dataWithContentsOfFile:[directory stringByAppendingString:@"/resumeData.fastresume"] ];
    if (resumeData == nil) {
        return NO;
    }

    error_code ec;
    add_torrent_params resumeParams;

    unsigned long int len = resumeData.length;
    //read resume file
    std::vector<char> resumeVector((char *)resumeData.bytes, (char *)resumeData.bytes + len);
    resumeParams = read_resume_data(resumeVector, ec); //load it into the torrent
    if (ec) { 
        std::printf("  failed to load resume data: %s\n", ec.message().c_str());
        return NO;
    }

    *torrentParams = resumeParams;
    return YES;
}

@end
