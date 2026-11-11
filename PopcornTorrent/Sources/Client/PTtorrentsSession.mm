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
#import <libtorrent/extensions/smart_ban.hpp>
#import <libtorrent/extensions/ut_metadata.hpp>
#include "libtorrent/hex.hpp" // to_hex
#include <libtorrent/peer_connection.hpp>
#include <libtorrent/peer_info.hpp>
#include <libtorrent/aux_/session_interface.hpp>
#include <boost/asio/post.hpp>
#import "../Bounded/PTStreamController.h"
#import "../Resources/NSString+Localization.h"


#if TARGET_OS_IOS || TARGET_OS_TV
#import <UIKit/UIApplication.h>
#endif

using namespace libtorrent;

#define ALERTS_LOOP_WAIT_MILLIS 500

// Testing aid: -1 = normal session, otherwise the loopback port (0 = any).
static int PTLoopbackTestingPort = -1;

@interface PTTorrentsSession () {
}

// Guarded by @synchronized (self): read on the alerts queue, written where streams start and stop.
@property (nonatomic, strong) NSMutableDictionary<NSString *, PTTorrentStreamer *> *streamers; // hash Id as key: the streamer that added the torrent
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<PTTorrentStreamer *> *> *guests; // streams that joined it, oldest first
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *pendingDeletions; // removals with delete_files not finished yet
@property (nonatomic, strong) NSMutableDictionary<NSString *, dispatch_group_t> *deletionGroups;
@property (nonatomic, strong, nullable) dispatch_queue_t alertsQueue;
@property (nonatomic, getter=isAlertsLoopActive) BOOL alertsLoopActive;


@end

@implementation PTTorrentsSession {
    libtorrent::session *_session;
    std::string _listenInterfaces;
    bool _dhtEnabled;
    int _minReconnectTime;
    NSInteger _reopenGeneration;
}

+ (void)prepareSharedSessionForLoopbackTestingOnPort:(int)port {
    PTLoopbackTestingPort = MAX(0, port);
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
    [self setupSession];
    [self setupAlertLoop];
    return self;
}

- (void)setupSession {
    settings_pack pack = default_settings();
    
    auto dht_nodes = pack.get_str(settings_pack::dht_bootstrap_nodes);
    dht_nodes += ",router.bittorrent.com:6881,router.utorrent.com:6881,router.bitcomet.com:6881,dht.transmissionbt.com:6881',dht.aelitis.com:6881,";
    pack.set_str(settings_pack::dht_bootstrap_nodes, dht_nodes);
    
    pack.set_str(settings_pack::listen_interfaces, "0.0.0.0:6881,[::]:6881");
    pack.set_int(settings_pack::max_retry_port_bind, 6889 - 6881);
    
    pack.set_int(settings_pack::alert_mask,
                 alert::status_notification |
                 alert::piece_progress_notification |
                 alert::storage_notification
                 //                 alert::all_categories
                 );
    
    pack.set_bool(settings_pack::listen_system_port_fallback, false);
    pack.set_bool(settings_pack::suggest_read_cache, false);
    // libtorrent 1.1 enables UPnP & NAT-PMP by default
    // turn them off before `libt::session` ctor to avoid split second effects
    pack.set_bool(settings_pack::enable_upnp, false);
    pack.set_bool(settings_pack::enable_natpmp, false);
    pack.set_bool(settings_pack::upnp_ignore_nonrouters, true);
    pack.set_int(settings_pack::file_pool_size, 2);

    if (PTLoopbackTestingPort >= 0) {
        // Offline tests: localhost only, no DHT, LSD, UPnP or NAT-PMP.
        pack.set_str(settings_pack::listen_interfaces, "127.0.0.1:" + std::to_string(PTLoopbackTestingPort));
        pack.set_int(settings_pack::max_retry_port_bind, 0);
        pack.set_str(settings_pack::dht_bootstrap_nodes, "");
        pack.set_bool(settings_pack::enable_dht, false);
        pack.set_bool(settings_pack::enable_lsd, false);
        pack.set_bool(settings_pack::allow_multiple_connections_per_ip, true);
    }

    _listenInterfaces = pack.get_str(settings_pack::listen_interfaces);
    _dhtEnabled = pack.get_bool(settings_pack::enable_dht);
    _minReconnectTime = pack.get_int(settings_pack::min_reconnect_time);

    // Settings take effect before the session starts (no split second of defaults).
    _session = new session(session_params(std::move(pack)));
    
    // Enabling plugins
    _session->add_extension(&lt::create_smart_ban_plugin);
    _session->add_extension(&lt::create_ut_metadata_plugin);
}

- (void)setupAlertLoop {
    self.alertsQueue = dispatch_queue_create("com.popcorntimetv.popcorntorrent.alerts", DISPATCH_QUEUE_SERIAL_WITH_AUTORELEASE_POOL);
    self.alertsLoopActive = YES;
    dispatch_async(self.alertsQueue, ^{
        [self alertsLoop];
    });
}

- (void)alertsLoop {
    @autoreleasepool {
        
        std::vector<alert *> deque;
        time_duration max_wait = milliseconds(ALERTS_LOOP_WAIT_MILLIS);
        
        while ([self isAlertsLoopActive]) {
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

    // Never auto-managed: libtorrent's auto-manager (3 active downloads by default) would
    // queue a new stream behind other torrents, and resume torrents paused on purpose.
    // Streams always run; downloads run until they are paused, explicitly.
    torrentParams.flags &= ~libtorrent::torrent_flags::auto_managed;
    torrentParams.flags &= ~libtorrent::torrent_flags::paused;
    torrentParams.flags |= libtorrent::torrent_flags::sequential_download;
    // A torrent still in libtorrent but not registered here is an error, not a silent reuse
    // (it would not have this stream's plugin).
    torrentParams.flags |= libtorrent::torrent_flags::duplicate_is_error;

    error_code ec_1;
    torrent_handle th = _session->add_torrent(std::move(torrentParams), ec_1);
    
    if (ec_1) {
        *error = [[NSError alloc] initWithDomain:@"com.popcorntimetv.popcorntorrent.error" code:-1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithCString:ec_1.message().c_str() encoding:NSUTF8StringEncoding]}];
        return th;
    }
    
    th.set_max_connections(60);
    th.set_max_uploads(10);
    
    @synchronized (self) {
        self.streamers[[self hashIDForTorrentHandle:th]] = torrentStreamer;
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
        } else {
            self.pendingDeletions[hashId] = @(pending - 1);
        }
        dispatch_group_leave(group);
    }
}

#pragma mark Network

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
    // Peers whose connection went with the old sockets (uTP runs over the listen socket's
    // UDP socket) are only retried after min_reconnect_time (60 s): a stream would stall
    // that long. Retry them at once for a little while.
    on.set_int(settings_pack::min_reconnect_time, 1);
    _session->apply_settings(on);
    NSInteger const generation = ++_reopenGeneration;
    __weak __typeof__(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_session == nullptr || strongSelf->_reopenGeneration != generation) return;
        settings_pack restore;
        restore.set_int(settings_pack::min_reconnect_time, strongSelf->_minReconnectTime);
        strongSelf->_session->apply_settings(restore);
    });
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
            orphans = [guests copy];
            [self.guests removeObjectForKey:hashId];
            if (deleteFiles) [self deletionStarted:hashId];
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
