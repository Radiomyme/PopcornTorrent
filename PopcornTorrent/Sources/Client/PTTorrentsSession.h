//
//  Header.h
//  
//
//  Created by Alexandru Tudose on 21.09.2022.
//
#import <Foundation/Foundation.h>

@interface PTTorrentsSession: NSObject

/// instantiate shared session used for torrents
/// call early in app life cycle for faster DHT boostrap
+ (instancetype)sharedSession;

/// Testing aid, not for apps: makes sessions created afterwards (the shared one
/// included) listen on 127.0.0.1:`port` only (0 = any free port), with no DHT,
/// LSD, UPnP or NAT-PMP. Call it before the first `+sharedSession`.
+ (void)prepareSharedSessionForLoopbackTestingOnPort:(int)port;

/// The TCP port the session listens on (0 if it does not listen).
@property (nonatomic, readonly) int listenPort;

@end

