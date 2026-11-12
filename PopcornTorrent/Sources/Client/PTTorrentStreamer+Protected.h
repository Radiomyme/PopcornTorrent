
#import "PTTorrentStreamer.h"
#import "PTTorrentsSession.h"
#import <libtorrent/session.hpp>
#import <libtorrent/torrent_info.hpp>
#import <libtorrent/add_torrent_params.hpp>
#import <libtorrent/magnet_uri.hpp>
#import <libtorrent/read_resume_data.hpp>
#import <libtorrent/write_resume_data.hpp>

#import <GCDWebServer.h>

#include <memory>

namespace ptbounded {
class StreamController;
}

using namespace libtorrent;

/**
 Variables to be used by `PTTorrentStreamer` subclasses only.
 */
@interface PTTorrentStreamer () {
    @protected
    libtorrent::torrent_handle _torrentHandle;
    PTTorrentStatus _torrentStatus;
    NSString *_fileName;
    long long _requiredSpace;
    long long _totalDownloaded;
    NSString *_savePath;
    std::vector<libtorrent::piece_index_t> required_pieces;
    libtorrent::piece_index_t firstPiece;
    libtorrent::piece_index_t endPiece;
    libtorrent::piece_index_t lastFilePiece;
    std::mutex mtx;
    int MIN_PIECES; //they are calculated by divind the 3% of a torrent file size with the size of a torrent piece / selected file in case we load a multi movie torrent
    int selectedFileIndex;
    // Piece availability, download window and bounded storage of the current stream.
    // Shared with the HTTP responses and the libtorrent plugin: use -controller (atomic load).
    std::shared_ptr<ptbounded::StreamController> _controller;
}

@property (nonatomic, getter=isStreaming) BOOL streaming;

@property (nonatomic, strong, nonnull) PTTorrentsSession *session;

@property (nonatomic, copy, nullable) PTTorrentStreamerProgress progressBlock;
@property (nonatomic, copy, nullable) PTTorrentStreamerReadyToPlay readyToPlayBlock;
@property (nonatomic, copy, nullable) PTTorrentStreamerFailure failureBlock;
@property (nonatomic, copy, nullable) PTTorrentStreamerSelection selectionBlock;
@property (nonatomic, strong, nonnull) GCDWebServer *mediaServer;
@property (nonatomic) libtorrent::torrent_status status;
@property (nonatomic) libtorrent::torrent_handle torrentHandle;
@property (nonatomic) bool isFinished;

- (void)startWebServerAndPlay;
- (std::shared_ptr<ptbounded::StreamController>)controller;
/// Starts into `<download directory>/<directoryName>` (nil: a folder named after the torrent).
/// The file to stream is chosen by `selectionBlock`, set before.
- (void)startStreamingFromFileOrMagnetLink:(nonnull NSString *)filePathOrMagnetLink
                             directoryName:(nullable NSString *)directoryName
                                  progress:(nullable PTTorrentStreamerProgress)progress
                               readyToPlay:(nullable PTTorrentStreamerReadyToPlay)readyToPlay
                                   failure:(nullable PTTorrentStreamerFailure)failure;

@end

@interface PTTorrentStreamer()

- (void)metadataReceivedAlert:(torrent_handle)th;
- (void)pieceFinishedAlert:(torrent_handle)th forPieceIndex:(piece_index_t)index;
- (void)torrentFinishedAlert:(torrent_handle)th;
- (void)handleTorrentError:(NSError *_Nullable)error;
- (void)fileErrorAlert:(NSString *_Nonnull)description diskFull:(BOOL)diskFull;
- (void)prioritizeNextPieces:(torrent_handle)th;

/// Publishes the status now (progress block and `PTTorrentStatusDidChangeNotification`, on the
/// main queue) and makes sure the 0.5 s monitor runs: one loop per stream. Any thread.
- (void)updateAndMonitorTorrentProgress;
/// Whether the status is published from the moment the torrent is added (before its metadata):
/// `YES` for a stream that added its torrent, `NO` for a guest and for a download (whose status
/// starts with the metadata, as before).
- (BOOL)publishesStatusBeforeMetadata;

#pragma mark Shared torrents (see -[PTTorrentsSession joinTorrent:params:error:])

/// `YES` while this stream reads a torrent another streamer added (an offline download).
@property (nonatomic, readonly, getter=isGuest) BOOL guest;
/// May this streamer join a torrent another one added? `NO` for downloads (own copy).
- (BOOL)canJoinSharedTorrent;
/// May streams join this streamer's torrent? Only when it keeps the whole file (never bounded).
- (BOOL)canShareTorrentWithGuests;
/// When this streamer removes its torrent while streams still read it: `YES` (streams) hands
/// the torrent and its files over to the oldest of them, `NO` (downloads) removes it anyway.
- (BOOL)handsTorrentOverToGuests;
/// This guest now owns the torrent it joined (its owner handed it over).
- (void)sharedTorrentBecameOwned;
/// The first stream joins this streamer's torrent / the last one leaves (main thread).
- (void)sharedTorrentWillGainGuests;
- (void)sharedTorrentDidLoseGuests;
/// The streamer that added the torrent this guest reads removed it (main thread).
- (void)sharedTorrentRemovedByOwner:(BOOL)deletedFiles;

@end
