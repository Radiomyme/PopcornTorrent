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


#if TARGET_OS_IOS || TARGET_OS_TV
#import <UIKit/UIApplication.h>
#endif

using namespace libtorrent;

#define ALERTS_LOOP_WAIT_MILLIS 500

// Testing aid: -1 = normal session, otherwise the loopback port (0 = any).
static int PTLoopbackTestingPort = -1;

@interface PTTorrentsSession () {
}

@property (nonatomic, strong) NSMutableDictionary<NSString *, PTTorrentStreamer *> *streamers; // hash Id as key
@property (nonatomic, strong, nullable) dispatch_queue_t alertsQueue;
@property (nonatomic, getter=isAlertsLoopActive) BOOL alertsLoopActive;


@end

@implementation PTTorrentsSession {
    libtorrent::session *_session;
}

+ (void)prepareSharedSessionForLoopbackTestingOnPort:(int)port {
    PTLoopbackTestingPort = MAX(0, port);
}

- (int)listenPort {
    return _session ? (int)_session->listen_port() : 0;
}

+ (instancetype)sharedSession {
    static dispatch_once_t onceToken;
    static PTTorrentsSession *sharedSession;

    static id backgroundToken;
    static id activeToken;
    static NSDate *lastDate;

    dispatch_once(&onceToken, ^{
        sharedSession = [[PTTorrentsSession alloc] init];

        // FIX: torrents not starting after apple tv comes from sleep after a period of time
        // workaround to create a new torrent session on tv, after a period of time
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
                                                    sharedSession = [[PTTorrentsSession alloc] init];
                                                }
                                                lastDate = nil;
                                              }];
        #endif
    });

    return sharedSession;
}

- (instancetype)init {
    self.streamers = [@{} mutableCopy];
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

- (PTTorrentStreamer *)torrentStreamerForTorrentHandle:(libtorrent::torrent_handle)torrentHandle {
    NSString *hashID = [self hashIDForTorrentHandle:torrentHandle];
    return self.streamers[hashID];
}

- (void)metadataReceivedAlert:(torrent_handle)th {
    NSString *hashID = [self hashIDForTorrentHandle:th];
    [self.streamers[hashID] metadataReceivedAlert:th];
}

- (void)pieceFinishedAlert:(torrent_handle)th forPieceIndex:(piece_index_t)index {
    NSString *hashID = [self hashIDForTorrentHandle:th];
    [self.streamers[hashID] pieceFinishedAlert:th forPieceIndex:index];
}

- (torrent_handle)addTorrent:(PTTorrentStreamer *)torrentStreamer params:(add_torrent_params)torrentParams error:(NSError **)error {
    error_code ec_1;
    torrent_handle th = _session->add_torrent(torrentParams, ec_1);
    
    if (ec_1) {
        *error = [[NSError alloc] initWithDomain:@"com.popcorntimetv.popcorntorrent.error" code:-1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithCString:ec_1.message().c_str() encoding:NSUTF8StringEncoding]}];
        return th;
    }
    
    th.set_flags(libtorrent::torrent_flags::sequential_download);
    th.set_max_connections(60);
    th.set_max_uploads(10);
    
    NSString *hashId = [self hashIDForTorrentHandle:th];
    if (self.streamers[hashId] != nil) {
        *error = [[NSError alloc] initWithDomain:@"com.popcorntimetv.popcorntorrent.error" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"Torrent already added (multiple files in same torrent not supported on same torrentsession)"}];
        return th;
    }
    
    self.streamers[hashId] = torrentStreamer;
    
#if TARGET_OS_IOS
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
    });
#endif
    return th;
}

- (void)torrentFinishedAlert:(torrent_handle)th {
    // The streamer decides: full mode pauses the finished torrent, bounded mode keeps it.
    NSString *hashID = [self hashIDForTorrentHandle:th];
    [self.streamers[hashID] torrentFinishedAlert:th];
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
    [self removeTorrent:torrentStreamer deleteFiles:NO saveResumeData:YES];
}

- (void)removeTorrent:(PTTorrentStreamer *)torrentStreamer deleteFiles:(BOOL)deleteFiles saveResumeData:(BOOL)saveResumeData {
    if (!torrentStreamer.torrentHandle.is_valid()) {
        return;
    }
    
    auto torrent = torrentStreamer.torrentHandle;
    NSString *hashId = [self hashIDForTorrentHandle:torrent];
    PTTorrentStreamer *registered = self.streamers[hashId];
    if (registered != nil && registered != torrentStreamer) {
        return; // the torrent belongs to another streamer of this session
    }
    
    self.streamers[hashId] = NULL;
    
    if (saveResumeData && !deleteFiles && torrent.need_save_resume_data()) {
        torrent.save_resume_data();
    }
    torrent.flush_cache();
    
    // A paused auto-managed torrent is resumed by libtorrent's auto-manager and keeps
    // downloading in the background: take it out of the session for good.
    torrent.unset_flags(torrent_flags::auto_managed);
    torrent.pause(torrent_handle::graceful_pause);
    _session->remove_torrent(torrent, deleteFiles ? session_handle::delete_files : remove_flags_t{});

#if TARGET_OS_IOS
    if (_session->get_torrents().empty()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
        });
    }
#endif
}

- (void)fileErrorAlert:(file_error_alert *)alert {
    NSString *description = [NSString stringWithFormat:@"%s", alert->message().c_str()];
    BOOL diskFull = alert->error == boost::system::errc::no_space_on_device || alert->error.value() == EDQUOT;
    NSString *hashID = [self hashIDForTorrentHandle:alert->handle];
    [self.streamers[hashID] fileErrorAlert:description diskFull:diskFull];
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
