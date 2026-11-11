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

/// The TCP port the session listens on (0 if it does not listen).
@property (nonatomic, readonly) int listenPort;

@end

