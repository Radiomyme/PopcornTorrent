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

@end
