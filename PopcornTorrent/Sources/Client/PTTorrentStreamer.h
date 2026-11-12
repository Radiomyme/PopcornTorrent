
#import <Foundation/Foundation.h>
#import "PTTorrentStatus.h"

@class PTSize;

/**
 Block called when the status of the currently streamed torrent is called.

 A stream calls it every 0.5 s from the moment its torrent is added, before the metadata is known (a magnet: seeds, peers and download rate while the metadata resolves, `bufferingProgress` 0; see `hasMetadata`), and when pieces arrive. A `PTTorrentDownload` calls it from the metadata on.

 @param status  The buffering progress of the current piece of the torrent, overall buffering of the torrent, the current download speed, the current upload speed, the amount of active seeds downloading from and the amount of peers connected to.
 */
typedef void (^PTTorrentStreamerProgress)(PTTorrentStatus status);

/**
 Block called when the first piece of the torrent has sufficiently buffered enough for streaming.
 
 @param videoFileURL    The `GCDWebServer` url that the torrent should be streamed from.
 @param videoFilePath   The local path to the video file. This should not be used for streaming.
 */
typedef void (^PTTorrentStreamerReadyToPlay)(NSURL * _Nonnull videoFileURL, NSURL * _Nonnull videoFilePath);

/**
 Block called if there is a fatal error processing the torrent.
 
 @param error    The underlying error.
 */
typedef void (^PTTorrentStreamerFailure)(NSError * _Nonnull error);

/**
 Block called when the torrent metadata have been downloaded and the user has to select the torrent to play
 
 @param torrentsAvailable  The available torrents names that the user can select from
 
 @return The index of the item in the array torrentsAvailable the user has selected, or `PTTorrentStreamerNoFileIndex` when none of them is the file wanted (a season pack without the requested episode): the stream then fails with `PTTorrentStreamerErrorNoFileSelected` (any other index out of range too)
 */
typedef int (^PTTorrentStreamerSelection)(NSArray<NSString*> * _Nonnull torrentsAvailable, NSArray<NSNumber*> * _Nonnull fileSizes);

NS_ASSUME_NONNULL_BEGIN

/**
 Posted when the status of the current Torrent changes finishes executing. Torrent status can be retrieved by accessing the `torrentStatus` variable of the posting object.
 */
FOUNDATION_EXPORT NSNotificationName const PTTorrentStatusDidChangeNotification;

/**
 Domain of the errors passed to the failure block.
 */
FOUNDATION_EXPORT NSErrorDomain const PTTorrentStreamerErrorDomain;

/**
 Codes of the errors passed to the failure block (`PTTorrentStreamerErrorDomain`).
 */
typedef NS_ERROR_ENUM(PTTorrentStreamerErrorDomain, PTTorrentStreamerError) {
    /// The selected file does not fit in the free space (bounded storage not allowed), or the disk became full while downloading (full mode; bounded mode recovers instead).
    PTTorrentStreamerErrorNotEnoughSpace = -4,
    /// Even bounded storage cannot run: the free space is below its minimum working set. `NSLocalizedDescriptionKey` says how much to free.
    PTTorrentStreamerErrorNotEnoughSpaceForBoundedStorage = -5,
    /// Another file error (I/O error, permissions...) stopped the torrent. `NSLocalizedDescriptionKey` is libtorrent's message.
    PTTorrentStreamerErrorFile = -6,
    /// The torrent is already used by this app in a way that cannot be shared: a bounded stream of it, a stream of another file of it, or (for a download) any stream or download of it. Stop the other one and try again.
    PTTorrentStreamerErrorTorrentInUse = -7,
    /// This stream was reading the file of an offline download of the same torrent (see `cancelStreamingAndDeleteData:`), and the download was stopped or removed before the file was complete.
    PTTorrentStreamerErrorSharedTorrentRemoved = -8,
    /// The selection block chose no file of the torrent (`PTTorrentStreamerNoFileIndex`, or any index out of range): the torrent does not hold the video wanted, e.g. a season pack without the requested episode. Nothing of that file is downloaded: a .torrent file is not even added; a magnet's other files may have received their first pieces between the metadata and the priorities (a few MiB, removed with the stream's folder). A download (`PTTorrentDownload`) failing so deletes its folder. `NSLocalizedDescriptionKey` says so.
    PTTorrentStreamerErrorNoFileSelected = -9,
};

/**
 What a selection block (`PTTorrentStreamerSelection`) returns when none of the torrent's files is the one wanted: the stream fails with `PTTorrentStreamerErrorNoFileSelected` instead of downloading another file.
 */
FOUNDATION_EXPORT int const PTTorrentStreamerNoFileIndex;

/**
 How the selected file is kept on disk. Decided when the torrent metadata is received.
 */
typedef NS_ENUM(NSInteger, PTStorageMode) {
    /// The metadata has not been received yet.
    PTStorageModeUndetermined = 0,
    /// The whole file is downloaded and kept (legacy behaviour, the file fits).
    PTStorageModeFull = 1,
    /// Only a window of the file is kept on disk; consumed pieces are deleted. See BOUNDED_STORAGE.md.
    PTStorageModeBounded = 2,
};

/**
 A class that streams magnet links or `.torrent` files to a `GCDWebServer`.
 */
@interface PTTorrentStreamer : NSObject
    
/**
 The directory to which all torrents are saved. Defaults to `NSTemporaryDirectory`. Will return `nil` if there is an error creating the directory.
 */
+ (NSString * _Nullable)downloadDirectory;

/**
 Directory used for this streamer's data instead of `+downloadDirectory` (for example another volume, or tests). `nil` (default) keeps `+downloadDirectory`. Set it before starting the stream.
 */
@property (atomic, copy, nullable) NSString *downloadDirectoryOverride;

/**
 Begins streaming of a torrent.
 
 @param filePathOrMagnetLink    The direct link of a locally stored `.torrent` file or a `magnet:?` link.
 @param progress                Block containing useful information about the torrent currently being streamed. Called every time the `torrentStatus` variable changes.
 @param readyToPlay             Block called when the torrent has finished processing and is ready to begin being played.
 @param failure                 Block called if there is an error while processing the torrent.
 @param callback                Block called when the torrent data are received and user needs to chose file to play
 */
- (void)startStreamingFromMultiTorrentFileOrMagnetLink:(NSString *)filePathOrMagnetLink
                                              progress:(PTTorrentStreamerProgress)progress
                                           readyToPlay:(PTTorrentStreamerReadyToPlay)readyToPlay
                                               failure:(PTTorrentStreamerFailure)failure
                                    selectFileToStream:(PTTorrentStreamerSelection)callback;

/**
 Cancels loading of the current torrent and optionally clears the download directory. The torrent is removed from the session (it no longer downloads or uploads in the background).

 A stream of a torrent that an offline download of this app (`PTTorrentDownload`) is downloading does not download it a second time: it reads the download's file (always in full mode) and its window drives the torrent while it plays. Cancelling such a stream never removes, pauses or deletes anything of the download, whatever `deleteData` is; the download goes on as before.
 
 @param deleteData  Pass `YES` to clear the download directory, `NO` to keep the downloaded directory. In bounded mode the data is always deleted: a file with deleted pieces cannot be resumed.
 */
- (void)cancelStreamingAndDeleteData:(BOOL)deleteData;
    
/**
 Status of the torrent that is currently streaming. Will return all 0 struct if no torrent is being streamed. In bounded mode `totalProgress` is the share of the file downloaded once and reaches 1 only if the whole file is on disk (`fileComplete`).
 */
@property (nonatomic, readonly) PTTorrentStatus torrentStatus;

/**
 The name of the torrent that is currently streaming. Will be `nil` if no torrent is being streamed or the currently streaming torrent has not been processed yet.
 */
@property (strong, nonatomic, readonly, nullable) NSString *fileName;

/**
 The size of the selected file of the torrent that is currently streaming. Will be 0 if no torrent is being streamed or the currently streaming torrent has not been processed yet.
 */
@property (nonatomic, readonly, strong) PTSize *fileSize;

/**
 The total size of the torrent that has been downloaded. Will be 0 if no torrent is being streamed or the currently streaming torrent has not been processed yet. In bounded mode it counts every piece downloaded once, deleted or not, so it only grows.
 */
@property (nonatomic, readonly, strong) PTSize *totalDownloaded;

/**
 The local path to the torrent directory. Will be `nil` if no torrent is being streamed or if the torrent is still processing.
 */
@property (strong, nonatomic, readonly, nullable) NSString *savePath;

#pragma mark - Loading

/*
 What a loading screen can show before the stream is ready. The progress block and
 `PTTorrentStatusDidChangeNotification` start when the torrent is added (every 0.5 s), so a
 magnet still resolving its metadata, or a swarm that never answers, reports its peers, seeds
 and download rate (`bufferingProgress` stays 0 until the metadata is known). A stream that
 joined a torrent already in the session, and `PTTorrentDownload`, report from the metadata
 on, as before. Both properties can be read from any thread.
 */

/**
 `YES` once the torrent's metadata (its file list) is received and the file to stream is chosen: `fileName`, `fileSize` and `storageMode` are set from then on. At once for a `.torrent` file, or a magnet whose metadata is already known (in the session, or resumed); otherwise after the metadata exchange with the peers. `NO` before, and when no stream runs.
 */
@property (atomic, readonly) BOOL hasMetadata;

/**
 Seconds since the current stream was started (`startStreaming…`), on a monotonic clock (system uptime). 0 when no stream runs.
 */
@property (atomic, readonly) NSTimeInterval timeSinceStart;

#pragma mark - Bounded storage

/*
 Bounded storage lets a file larger than the free space be streamed: only the
 pinned head and tail of the file, the data the consumer has not released yet
 and a window ahead of the reader are kept on disk. See BOUNDED_STORAGE.md.

 Thread safety: every method and property of this section can be used from any
 thread. The configuration properties (`allowsBoundedStorage`, `storageReserve`,
 `mediaDurationHint`) are read when the metadata is received: set them before
 starting the stream. `storageBudget` can change at any time.
 */

/**
 Allows bounded storage when the selected file plus `storageReserve` does not fit in the free space. Defaults to `NO`: such a file is refused with `PTTorrentStreamerErrorNotEnoughSpace` as before (always for `PTTorrentDownload`, which needs the whole file).

 Set it to `YES` only if the consumer releases what it has read with `setConsumedBefore:` (and, when it does not read through the HTTP server, reports its position with `setReadPosition:`): without that nothing is freed, the window stays at the start of the file and the stream stalls once the budget is full. Bounded storage also needs a volume that supports holes (APFS); elsewhere the legacy refusal applies.
 */
@property (atomic) BOOL allowsBoundedStorage;

/**
 Free space, in bytes, that bounded storage never uses. Defaults to 512 MiB.
 */
@property (atomic) int64_t storageReserve;

/**
 The most bytes the torrent may keep on disk in bounded mode (pins, data not yet released by the consumer, window ahead of the reader). The app keeps its own copy (HLS segments) in the rest. 0 (default) = automatic: about 5 min ahead and 3 min behind the reader at the file's bitrate. Raised to the minimum working set if smaller.
 */
@property (atomic) int64_t storageBudget;

/**
 Optional duration of the media, in seconds. Used to derive the bitrate (minimum working set, window sizes). 0 = unknown: the bitrate is estimated from the size, assuming 2 hours.
 */
@property (atomic) NSTimeInterval mediaDurationHint;

/**
 Optional: seconds of media (at the file's bitrate) the app keeps on the same volume next to the whole file when it is downloaded in full (its own copy, such as HLS segments around the playhead). When `allowsBoundedStorage` is `YES`, full mode is chosen only if the file, `storageReserve` and this fit in the free space; otherwise the stream is bounded. 0 (default) = the file and the reserve alone, as before. Read when the metadata is received.
 */
@property (atomic) NSTimeInterval appWorkingSetSeconds;

/**
 Optional: bytes other writers of the same volume will still add while this stream runs (offline downloads in progress). Bounded storage does not count them as free space, both when it decides the mode and while it runs. Set it any time; 0 by default.
 */
@property (atomic) int64_t pendingExternalBytes;

/**
 How the selected file is kept on disk. `PTStorageModeUndetermined` until the metadata is received.
 */
@property (atomic, readonly) PTStorageMode storageMode;

/**
 `YES` once the stream runs in bounded mode.
 */
@property (atomic, readonly, getter=isStorageBounded) BOOL storageBounded;

/**
 The next byte of the file (offset in the selected file) the consumer needs. Setting it (`setReadPosition:`) moves the download window and its deadlines there; it is cheap, set it whenever the reader moves (seeks included). HTTP reads through the streamer's server also update it: a read that waits for a missing piece moves it there, and reads moving forward through the window advance it.
 */
@property (atomic) int64_t readPosition;

/**
 Bytes of the selected file below this offset will never be read again (`setConsumedBefore:`). In bounded mode the pieces entirely below it, minus one guard piece and except the pinned head and tail, are deleted from disk and never downloaded again in this stream; peers are told so (lt_donthave) and never get them from us. It only increases: smaller values are ignored. No effect in full mode.
 */
@property (atomic) int64_t consumedBefore;

/**
 Bounded mode: data below this offset (apart from the pinned head) is deleted, or consumed and queued for deletion (pieces are deleted in batches of 32 MiB or once a second), and can never be read again: a rewind before it must be blocked. It is the end of the highest consumed piece: every piece lying entirely below `consumedBefore` minus one guard piece, pinned pieces excepted. Exact at call time (it follows `setConsumedBefore:` at once) and never decreases. 0 in full mode or when nothing was consumed yet. It says nothing about the data above it: pieces skipped by a forward seek are not on disk either (once consumed they are never downloaded, and the HTTP server answers 410 for them as for deleted data). For a rewind use `contiguousAvailableOffsetBefore:`, or `isRangeAvailable:length:` for one range.
 */
@property (atomic, readonly) int64_t lowestAvailableOffset;

/**
 End offset of the last chunk served by the HTTP server (the server's read position).
 */
@property (atomic, readonly) int64_t servedOffset;

/**
 The first offset at or after `fileOffset` that is not on disk now (`fileOffset` itself if its piece is missing), or the file size if everything from `fileOffset` to the end is on disk. A piece counts as on disk once it passed its hash check and was verified as written to the file. Consumed pieces still on disk count (see `isRangeAvailable:length:`).
 */
- (int64_t)firstMissingOffsetFrom:(int64_t)fileOffset;

/**
 `YES` if every byte of `[fileOffset, fileOffset + length)` is on disk now and can be read from the file. `NO` for an empty range or one outside the file. A snapshot: in bounded mode data below `lowestAvailableOffset` is deleted within about a second even if it is still on disk; data ahead of the read position can be dropped when the disk is full (and is downloaded again).
 */
- (BOOL)isRangeAvailable:(int64_t)fileOffset length:(int64_t)length;

/**
 The lowest offset `start` <= `fileOffset` such that every byte of `[start, fileOffset)` is on disk now and, in bounded mode, stays there (pinned head and tail, or not consumed yet): the backward counterpart of `firstMissingOffsetFrom:`. `fileOffset` when the byte just before it is not available. Rewind policy for a reader at `readPosition`: a rewind to `target` that then reads forward finds every byte up to the current position iff `target >= [streamer contiguousAvailableOffsetBefore:streamer.readPosition]` (a gap left by a forward seek, or deleted data, stops it). Cheap: one pass over the piece states.
 */
- (int64_t)contiguousAvailableOffsetBefore:(int64_t)fileOffset NS_SWIFT_NAME(contiguousAvailableOffset(before:));

/**
 `YES` if every byte of the selected file is on disk now. Never `YES` in bounded mode once something was deleted.
 */
@property (atomic, readonly, getter=isFileComplete) BOOL fileComplete;

/**
 Bytes of the selected file actually allocated on disk now (fresh `stat`, holes excluded).
 */
@property (atomic, readonly) int64_t bytesOnDisk;

/**
 Counters for logging (budgets, window, pace state, free space, freed pieces...). Keys are listed in BOUNDED_STORAGE.md. Empty before the metadata is received.
 */
@property (atomic, readonly) NSDictionary<NSString *, NSNumber *> *storageStatistics;

/**
 Checks, in `directory` (created if missing), the volume primitives bounded storage relies on: `_PC_MIN_HOLE_SIZE`, a 2 MiB file created as a hole with its first MiB written (`SEEK_HOLE` must find the hole at 1 MiB, `SEEK_DATA` the data at 0), `F_PUNCHHOLE` of its first 512 KiB (the call must succeed, the range must read as zeros and `SEEK_DATA` find the data at 512 KiB; the allocated size before and after is reported). The file is deleted. Returns one line (PASS or FAIL with the reason, the block size and the free space). `passed`: whether bounded storage can run there. A stream runs it once per volume before bounded storage is first allowed (and logs that line); the app's debug pre-flight calls it directly.
 */
+ (NSString *)holeSupportReportForDirectory:(NSString *)directory passed:(BOOL * _Nullable)passed;

@end

NS_ASSUME_NONNULL_END
