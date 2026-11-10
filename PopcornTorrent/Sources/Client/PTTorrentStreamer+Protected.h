
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
@property (nonatomic) bool deleteOnlyDownloadedFile;

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

@end

@interface PTTorrentStreamer()

- (void)metadataReceivedAlert:(torrent_handle)th;
- (void)pieceFinishedAlert:(torrent_handle)th forPieceIndex:(piece_index_t)index;
- (void)torrentFinishedAlert:(torrent_handle)th;
- (void)handleTorrentError:(NSError *_Nullable)error;
- (void)fileErrorAlert:(NSString *_Nonnull)description diskFull:(BOOL)diskFull;
- (void)prioritizeNextPieces:(torrent_handle)th;

@end
