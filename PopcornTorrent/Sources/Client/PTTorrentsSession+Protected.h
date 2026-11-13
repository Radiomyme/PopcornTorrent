//
//  Header.h
//  
//
//  Created by Alexandru Tudose on 27.09.2022.
//

#import "PTTorrentsSession.h"
#import "PTTorrentStreamer.h"
#import <libtorrent/torrent.hpp>
#include <memory>

namespace ptbounded {
class StreamController;
}

@interface PTTorrentsSession()

/// Adds the torrent, never auto-managed (libtorrent's auto-manager neither queues nor
/// resumes it). Error -2: another streamer of this session already has this torrent (the
/// handle returned is that torrent's): the caller may join it (`joinTorrent:`).
- (libtorrent::torrent_handle)addTorrent:(PTTorrentStreamer *)torrentStreamer params:(libtorrent::add_torrent_params)torrentParams error:(NSError **)error;
- (void)removeTorrent:(PTTorrentStreamer *)torrentStreamer;
/// Removes the torrent from the libtorrent session (optionally with its files). Returns `YES`
/// when the torrent was not removed but handed over to a stream that joined it (its files are
/// that stream's now: the caller must not delete them).
- (BOOL)removeTorrent:(PTTorrentStreamer *)torrentStreamer deleteFiles:(BOOL)deleteFiles saveResumeData:(BOOL)saveResumeData;
/// Full mode: pauses a finished torrent for good (no seeding); it is removed at cancel.
- (void)finishTorrent:(PTTorrentStreamer *)torrentStreamer;
- (BOOL)tryToResumeTorrentParams:(libtorrent::add_torrent_params *)torrentParams atPath:(NSString *)directory;

- (PTTorrentStreamer *)torrentStreamerForTorrentHandle:(libtorrent::torrent_handle)torrentHandle;

#pragma mark Shared torrents

/// A stream joins the torrent another streamer of this session added (an offline download in
/// progress, or a stream in full mode): it reads that streamer's file and drives the
/// torrent's priorities while it is attached (the newest guest does). Refused with
/// `PTTorrentStreamerErrorTorrentInUse` when the owner cannot share it (a bounded stream) or
/// the newcomer is a download. Returns the owner's handle.
- (libtorrent::torrent_handle)joinTorrent:(PTTorrentStreamer *)guest params:(libtorrent::add_torrent_params const &)torrentParams error:(NSError **)error;
/// The guest leaves. Returns the controller that drives the torrent from now on (the previous
/// guest or the owner), or nullptr when the guest was not the one driving it.
- (std::shared_ptr<ptbounded::StreamController>)leaveTorrent:(PTTorrentStreamer *)guest;
/// The streamer that added the torrent `guest` joined (nil once it removed it).
- (PTTorrentStreamer *)ownerOfGuest:(PTTorrentStreamer *)guest;
- (BOOL)hasGuests:(PTTorrentStreamer *)owner;

#pragma mark Network

/// Reopens the listen sockets (and the DHT) of the session and re-announces every torrent,
/// keeping the torrents and their peers. Called when a tvOS app becomes active after a long
/// time in the background (its sockets may have been reclaimed while it was suspended).
- (void)reopenNetwork;

/// Peers dropped a moment ago are retried at once for a little while (min_reconnect_time 1 s
/// for 30 s, instead of 60 s), for every torrent: after a torrent that turned finished with
/// pieces of its file missing dropped its seeds (PTTorrentStreamer torrentFinishedAlert:).
- (void)retryDroppedPeersSoon;

@end
