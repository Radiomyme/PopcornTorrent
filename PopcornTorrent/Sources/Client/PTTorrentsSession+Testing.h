//
//  PTTorrentsSession+Testing.h
//  PopcornTorrent
//
//  Testing aids, not exported by the package (not in include/): the offline harness
//  (Tools/BoundedStorageHarness) imports it from Sources/Client.
//

#import "PTTorrentsSession.h"

@interface PTTorrentsSession (Testing)

/// Makes sessions created afterwards (the shared one included) listen on
/// 127.0.0.1:`port` only (0 = any free port), with no DHT, LSD, UPnP or NAT-PMP.
/// Call it before the first `+sharedSession`.
+ (void)prepareSharedSessionForLoopbackTestingOnPort:(int)port;

/// What the tvOS app does when it becomes active after more than 5 minutes in the
/// background: reopens the listen sockets and re-announces every torrent.
- (void)reopenNetworkForTesting;

/// Makes sessions created afterwards use the network settings of another platform: "tv",
/// "ios" or "mac" (nil: this one). Call it before the first `+sharedSession`.
+ (void)setNetworkProfileForTesting:(NSString *)profile;

/// The trackers a public torrent with `trackers` gets: its own, then the default public
/// trackers it does not have (never added in loopback testing, nor to private torrents).
+ (NSArray<NSString *> *)trackersForTesting:(NSArray<NSString *> *)trackers;

/// The session's network settings, by libtorrent setting name, "torrent_connections" (the
/// peers allowed per torrent) and "open_files_limit" (the process's soft RLIMIT_NOFILE).
- (NSDictionary<NSString *, NSNumber *> *)networkSettingsForTesting;

/// Whether a magnet with this tracker waits for its metadata before it gets the default
/// trackers (the URL carries a key, as private trackers' do).
+ (BOOL)trackerLooksKeyedForTesting:(NSString *)url;

/// The process's soft limit of open files (raised before the first session is created).
+ (long long)openFilesLimit;

/// Whether sessions are made loopback-only (`prepareSharedSessionForLoopbackTestingOnPort:`).
+ (BOOL)isLoopbackTesting;

@end
