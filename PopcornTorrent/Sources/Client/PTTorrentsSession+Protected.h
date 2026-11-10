//
//  Header.h
//  
//
//  Created by Alexandru Tudose on 27.09.2022.
//

#import "PTTorrentsSession.h"
#import "PTTorrentStreamer.h"
#import <libtorrent/torrent.hpp>

@interface PTTorrentsSession()

- (libtorrent::torrent_handle)addTorrent:(PTTorrentStreamer *)torrentStreamer params:(libtorrent::add_torrent_params)torrentParams error:(NSError **)error;
- (void)removeTorrent:(PTTorrentStreamer *)torrentStreamer;
/// Removes the torrent from the libtorrent session (optionally with its files).
- (void)removeTorrent:(PTTorrentStreamer *)torrentStreamer deleteFiles:(BOOL)deleteFiles saveResumeData:(BOOL)saveResumeData;
/// Full mode: pauses a finished torrent for good (no seeding); it is removed at cancel.
- (void)finishTorrent:(PTTorrentStreamer *)torrentStreamer;
- (BOOL)tryToResumeTorrentParams:(libtorrent::add_torrent_params *)torrentParams atPath:(NSString *)directory;

- (PTTorrentStreamer *)torrentStreamerForTorrentHandle:(libtorrent::torrent_handle)torrentHandle;

@end
