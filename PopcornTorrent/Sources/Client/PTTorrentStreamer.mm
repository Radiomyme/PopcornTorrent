

#import "PTTorrentStreamer.h"
#import <Foundation/Foundation.h>
#import <string>
#import <sys/stat.h>
#import <unistd.h>
#import <fcntl.h>
#import <sys/mount.h>
#import <vector>
#import <mutex>
#import <atomic>
#import <libtorrent/bencode.hpp>
#import "../Security/CocoaSecurity.h"
#import "../Resources/NSString+Localization.h"
#import "PTTorrentStreamer+Protected.h"
#import <GCDWebServer.h>
#import "PTTorrentsSession.h"
#import "PTTorrentsSession+Protected.h"
#import "PTSize.h"
#import "PTTorrentDownload.h"
#import "../Bounded/PTStreamController.h"
#import "../Bounded/PTGatedFileResponse.h"

#define PIECE_DEADLINE_MILLIS 100

NSNotificationName const PTTorrentStatusDidChangeNotification = @"com.popcorntimetv.popcorntorrent.status.change";
NSErrorDomain const PTTorrentStreamerErrorDomain = @"com.popcorntimetv.popcorntorrent.error";
int const PTTorrentStreamerNoFileIndex = -1;


using namespace libtorrent;

@implementation PTTorrentStreamer {
    BOOL _allowsBoundedStorage;
    int64_t _storageReserve;
    int64_t _storageBudget;
    NSTimeInterval _mediaDurationHint;
    NSTimeInterval _appWorkingSetSeconds;
    int64_t _pendingExternalBytes;
    PTStorageMode _storageMode;
    // _status holds strings: it is written from the alerts queue and the main queue.
    std::mutex _statusMutex;
    // This stream joined a torrent another streamer of the session added (see joinTorrent:).
    BOOL _guest;
    // Bounded mode: free space needed to start (planBudget), for the start-starvation error.
    int64_t _minimumFreeBytes;
    BOOL _starvationReported;
    // Loading state, read from any thread: when the stream started (system uptime; 0: none)
    // and whether its metadata was processed (hasMetadata).
    std::atomic<double> _startUptime;
    std::atomic<bool> _hasMetadata;
    // The 0.5 s status monitor runs one loop per stream: the generation changes at every start
    // and cancel (a loop of another generation stops); _monitorLoopGeneration is the
    // generation whose loop is scheduled (main queue only, 0: none).
    std::atomic<uint64_t> _monitorGeneration;
    uint64_t _monitorLoopGeneration;
    // The selection chose no file and the failure was reported (once: the metadata alert
    // and the direct call at start may both come).
    std::atomic<bool> _noFileReported;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _startUptime = 0;
        _hasMetadata = false;
        _monitorGeneration = 0;
        _monitorLoopGeneration = 0;
        _noFileReported = false;
        selectedFileIndex = -1;
        // Opt-in: bounded storage only works when the consumer releases what it read
        // (setConsumedBefore:), which an app has to do on purpose.
        _allowsBoundedStorage = NO;
        _storageReserve = ptbounded::kDefaultReserveBytes;
        self.session = [PTTorrentsSession sharedSession];
        [self setupSession];
    }
    return self;
}

- (PTSize *)fileSize {
    return [PTSize sizeWithLongLong:_requiredSpace];
}

- (PTSize *)totalDownloaded {
    return [PTSize sizeWithLongLong:_totalDownloaded];
}


+ (NSString *)downloadDirectory {
    NSString *downloadDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"Downloads"];

    if (![[NSFileManager defaultManager] fileExistsAtPath:downloadDirectory]) {
        NSError *error;
        [[NSFileManager defaultManager] createDirectoryAtPath:downloadDirectory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&error];
        if (error) return nil;
    }

    return downloadDirectory;
}

- (void)setupSession {
    _torrentHandle = libtorrent::torrent_handle();
    firstPiece = libtorrent::piece_index_t(-1);
    endPiece = libtorrent::piece_index_t(0);
    lastFilePiece = libtorrent::piece_index_t(0);

    self.status = torrent_status();
    if(self.mediaServer == nil)self.mediaServer = [[GCDWebServer alloc] init];

}

- (std::shared_ptr<ptbounded::StreamController>)controller {
    return std::atomic_load(&_controller);
}

- (void)startStreamingFromMultiTorrentFileOrMagnetLink:(NSString *)filePathOrMagnetLink
                                  progress:(PTTorrentStreamerProgress)progress
                               readyToPlay:(PTTorrentStreamerReadyToPlay)readyToPlay
                                   failure:(PTTorrentStreamerFailure)failure
                                    selectFileToStream:(PTTorrentStreamerSelection)callback{
    self.selectionBlock = callback;
    [self startStreamingFromFileOrMagnetLink:filePathOrMagnetLink
                               directoryName:nil
                                    progress:progress
                                 readyToPlay:readyToPlay
                                     failure:failure];

}

- (void)startStreamingFromFileOrMagnetLink:(NSString *)filePathOrMagnetLink
                             directoryName:(NSString * _Nullable)directoryName
                                  progress:(PTTorrentStreamerProgress)progress
                               readyToPlay:(PTTorrentStreamerReadyToPlay)readyToPlay
                                   failure:(PTTorrentStreamerFailure)failure {


    [self startStreamingFromFileOrMagnetLink:filePathOrMagnetLink
                               directoryName:directoryName
                                    progress:progress
                                 readyToPlay:readyToPlay
                                     failure:failure
                                  fastResume:true];
}

- (void)startStreamingFromFileOrMagnetLink:(NSString *)filePathOrMagnetLink
                             directoryName:(NSString * _Nullable)directoryName
                                  progress:(PTTorrentStreamerProgress)progress
                               readyToPlay:(PTTorrentStreamerReadyToPlay)readyToPlay
                                   failure:(PTTorrentStreamerFailure)failure
                                fastResume:(Boolean)fastResume {

    self.progressBlock = progress;
    self.readyToPlayBlock = readyToPlay;
    self.failureBlock = failure;
    // A new stream: its clock, no metadata yet, and a new monitor generation.
    _startUptime = [NSProcessInfo processInfo].systemUptime;
    _hasMetadata = false;
    ++_monitorGeneration;

    error_code ec;
    add_torrent_params tp;

    NSString *MD5String = nil;

    if ([filePathOrMagnetLink hasPrefix:@"magnet"]) {
        NSString *magnetLink = [[filePathOrMagnetLink stringByRemovingPercentEncoding] stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];

        tp = parse_magnet_uri(std::string([magnetLink UTF8String]));//std::string([magnetLink UTF8String]);

        MD5String = [CocoaSecurity md5:magnetLink].hexLower;
    } else {
        NSString *filePath = filePathOrMagnetLink;
        NSError *error;

        if ([[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
            NSData *fileData = [NSData dataWithContentsOfFile:filePath];
            MD5String = [CocoaSecurity md5WithData:fileData].hexLower;
            std::shared_ptr<torrent_info> ti1 = std::make_shared<torrent_info>([filePathOrMagnetLink UTF8String], ec);
            tp.ti = ti1;
            if (ec) {
                error = [[NSError alloc] initWithDomain:PTTorrentStreamerErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithCString:ec.message().c_str() encoding:NSUTF8StringEncoding]}];
            } else {
                int index = [self selectedFileIndexInTorrentWithTorrentInfo:tp.ti];
                if (index == PTTorrentStreamerNoFileIndex) {
                    // None of its files is the one wanted: the torrent is not even added.
                    _noFileReported = true;
                    error = [self noFileSelectedError];
                } else {
                    MIN_PIECES = ((tp.ti->files().file_size(libtorrent::file_index_t(index)) * 0.03)/tp.ti->piece_length());
                }
            }
        } else {
            error = [[NSError alloc] initWithDomain:PTTorrentStreamerErrorDomain code:-2 userInfo:@{NSLocalizedDescriptionKey: [NSString localizedStringWithFormat:@"File doesn't exist at path: %@".localizedString, filePath]}];
        }

        if (error) {
            if (failure) failure(error);
            return [self cancelStreamingAndDeleteData:NO];
        }
    }

    //construct the folder path for downloads
    NSString *pathComponent = directoryName != nil ? directoryName : [self folderNameForTorrentNamed:[MD5String substringToIndex:16]];

    NSString *basePath = self.downloadDirectoryOverride ?: [[self class] downloadDirectory];
    if (self.downloadDirectoryOverride) {
        [[NSFileManager defaultManager] createDirectoryAtPath:basePath withIntermediateDirectories:YES attributes:nil error:nil];
    }

    if (!basePath) {
        NSError *error = [NSError errorWithDomain:PTTorrentStreamerErrorDomain code:-412 userInfo:@{NSLocalizedDescriptionKey: @"Could not create download directory".localizedString}];
        if (failure) failure(error);
        return [self cancelStreamingAndDeleteData:NO];
    }

    Boolean didTryFastResume = false;
    BOOL createdDirectory = NO;

    _savePath = [basePath stringByAppendingPathComponent:pathComponent];
    //create folder for torrents
    if (![[NSFileManager defaultManager] fileExistsAtPath:_savePath]) {
        createdDirectory = YES;
        NSError *error;
        [[NSFileManager defaultManager] createDirectoryAtPath:self.savePath
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&error];
        //if we cannot create folder clear all data and exit
        if (error) {
            if (failure) failure(error);
            return [self cancelStreamingAndDeleteData:NO];
        }
    } else if ([filePathOrMagnetLink hasPrefix:@"magnet"] && fastResume){
        //if folder exists already and we are loading a magnet search for resume file
        [self.session tryToResumeTorrentParams:&tp atPath:_savePath];
        didTryFastResume = true;
    }

    tp.save_path = std::string([self.savePath UTF8String]);
    // tp.storage_mode = storage_mode_allocate;

    // One controller per stream: piece availability for the HTTP server and the
    // app, the download window, and bounded storage when the file does not fit.
    // Added after the resume data was read, which replaces the whole params.
    auto controller = std::make_shared<ptbounded::StreamController>();
    __weak __typeof__(self) weakController = self;
    controller->setAvailabilityHandler([weakController]() {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakController evaluateReadiness];
        });
    });
    std::atomic_store(&_controller, controller);
    tp.extensions.push_back(ptbounded::makeStreamPluginFactory(controller));

    NSError *error;
    _torrentHandle = [self.session addTorrent:self params:tp error:&error];

    // The torrent is already in the session: an offline download in progress (or a stream
    // in full mode). Join it: read its file, no second download, no second session.
    if (error && error.code == -2) {
        error = nil;
        _torrentHandle = [self.session joinTorrent:self params:tp error:&error];
        if (!error) {
            _guest = YES;
            NSString *ownDirectory = _savePath;
            _savePath = [self.session ownerOfGuest:self].savePath ?: _savePath;
            if (createdDirectory && ![ownDirectory isEqualToString:_savePath]) {
                [[NSFileManager defaultManager] removeItemAtPath:ownDirectory error:nil];
            }
            NSLog(@"PopcornTorrent: %@ is already in the session, this stream reads its file in %@", filePathOrMagnetLink.lastPathComponent, _savePath);
        }
    }

    if (error) {
        if (didTryFastResume) {
            // retry streaming without fast resume, aka start from scratch
            [[NSFileManager defaultManager] removeItemAtPath:self.savePath error:nil];
            [self cancelStreamingAndDeleteData:YES];
            [self startStreamingFromFileOrMagnetLink:filePathOrMagnetLink
                                       directoryName:directoryName
                                            progress:progress
                                         readyToPlay:readyToPlay
                                             failure:failure];
        } else {

            if (failure) failure(error);
            [self cancelStreamingAndDeleteData:NO];
        }
        return;
    }

    if (![filePathOrMagnetLink hasPrefix:@"magnet"] || _torrentHandle.status().has_metadata) {
        [self metadataReceivedAlert:_torrentHandle];
    } else if ([self publishesStatusBeforeMetadata]) {
        // A magnet resolving its metadata: peers, seeds and rate every 0.5 s from now on
        // (buffering 0), not a silence until the metadata comes (or never, from a dead swarm).
        // The metadata (alerts thread) joins this loop instead of starting another one.
        [self updateAndMonitorTorrentProgress];
    }
}

/// Whether a status read for `generation` may still be posted: that stream still runs (not
/// cancelled or restarted since). An alert handled on the alerts thread just after a cancel
/// reads the new generation: no stream runs then (`_startUptime` 0).
- (BOOL)isStreamOfGeneration:(uint64_t)generation {
    return _monitorGeneration.load() == generation && _startUptime.load() > 0;
}

- (BOOL)publishesStatusBeforeMetadata {
    return !_guest;
}

- (BOOL)wantsSequentialDownload {
    return YES;
}

- (BOOL)hasMetadata {
    return _hasMetadata.load();
}

- (NSTimeInterval)timeSinceStart {
    double const start = _startUptime.load();
    return start > 0 ? MAX(0, [NSProcessInfo processInfo].systemUptime - start) : 0;
}

- (void)handleTorrentError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.failureBlock) self.failureBlock(error);
        [self cancelStreamingAndDeleteData:NO];
    });
}

- (void)fileErrorAlert:(NSString *)description diskFull:(BOOL)diskFull {
    auto controller = [self controller];
    if (controller) controller->noteFileError(diskFull);
    if (diskFull && self.storageMode == PTStorageModeBounded) {
        // libtorrent switched to upload mode; the controller frees space and resumes
        // the download. The stream itself goes on.
        NSLog(@"PopcornTorrent: disk full in bounded mode, recovering (%@)", description);
        return;
    }
    PTTorrentStreamerError const code = diskFull ? PTTorrentStreamerErrorNotEnoughSpace : PTTorrentStreamerErrorFile;
    NSError *error = [[NSError alloc] initWithDomain:PTTorrentStreamerErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: description}];
    [self handleTorrentError:error];
}

- (void)cancelStreamingAndDeleteData:(BOOL)deleteData {
    auto controller = std::atomic_exchange(&_controller, std::shared_ptr<ptbounded::StreamController>());
    // The monitor loop of this stream stops at its next tick; no stream, no loading state.
    ++_monitorGeneration;
    _startUptime = 0;
    _hasMetadata = false;
    BOOL const bounded = self.storageMode == PTStorageModeBounded;
    BOOL const guest = _guest;
    // Whether the files are this streamer's to delete.
    BOOL ownsFiles = !guest;
    if (guest) {
        // The torrent and its files belong to the streamer this stream joined (a download):
        // never removed, paused or deleted here. Our window stops driving the torrent and
        // the one before ours (the download's) drives it again.
        _guest = NO;
        auto next = [self.session leaveTorrent:self];
        if (controller) controller->detach(next);
        else if (next) next->resumePlanning();
        if (controller) controller->cancel();
    } else {
        // A file with deleted pieces cannot be resumed: bounded mode always deletes it.
        if (bounded) deleteData = YES;
        BOOL const handedOver = [self.session removeTorrent:self deleteFiles:deleteData saveResumeData:!bounded];
        if (handedOver) {
            // Streams joined this (full-mode) stream: the oldest one now owns the torrent and
            // its files. Only our plugin goes.
            ownsFiles = NO;
            if (controller) controller->detach(nullptr);
        }
        if (controller) controller->cancel();
    }
    _torrentHandle = libtorrent::torrent_handle();

    required_pieces.clear();
    required_pieces.shrink_to_fit();

    self.status = torrent_status();

    self.progressBlock = nil;
    self.readyToPlayBlock = nil;
    self.failureBlock = nil;

    if (self.mediaServer.isRunning) [self.mediaServer stop];
    [self.mediaServer removeAllHandlers];

    firstPiece = libtorrent::piece_index_t(-1);
    endPiece = libtorrent::piece_index_t(0);

    self.streaming = NO;
    _torrentStatus = (PTTorrentStatus){0, 0, 0, 0, 0, 0};
    _isFinished = false;
    @synchronized (self) {
        _storageMode = PTStorageModeUndetermined;
    }

    if (deleteData || !ownsFiles) {
        // delete whole directory
        if (deleteData && ownsFiles) [[NSFileManager defaultManager] removeItemAtPath:self.savePath error:nil];
        _savePath = nil;
        _fileName = nil;
        _requiredSpace = 0;
        _totalDownloaded = 0;
        selectedFileIndex = -1;
        _noFileReported = false;
        [self setupSession];
    }
}

- (void)prioritizeNextPieces:(torrent_handle)th {
    // The window now follows the read position (see PTStreamController); only ask
    // for a new plan.
    auto controller = [self controller];
    if (controller) controller->requestUpdate();
}

- (void)processTorrent:(torrent_handle)th {
    self.status = th.status();
    dispatch_async(dispatch_get_main_queue(), ^{
        [self evaluateReadiness];
    });
}

/// Main queue. Starts the server and calls readyToPlay once the first pieces
/// and the last ones are on disk (written, not only downloaded).
- (void)evaluateReadiness {
    if ([self isStreaming] || !self.readyToPlayBlock) return;
    auto controller = [self controller];
    if (!controller || !controller->isConfigured()) return;
    auto const progress = controller->requiredProgress();
    if (progress.first < progress.second) return;
    self.streaming = YES;
    [self startWebServerAndPlay];
}

- (void)startWebServerAndPlay {
    __block NSURL *fileURL = [NSURL fileURLWithPath:[self.savePath stringByAppendingPathComponent:_fileName]];
    __weak __typeof__(self) weakSelf = self;
    NSString *fileName = _fileName ?: @"";
    NSLog(@"file to be streamed is %@",[self.savePath stringByAppendingPathComponent:_fileName]);
    [self.mediaServer addDefaultHandlerForMethod:@"GET" requestClass:[GCDWebServerRequest class] asyncProcessBlock:^(GCDWebServerRequest *request, GCDWebServerCompletionBlock completionBlock) {
        // Served only from pieces on disk: missing ones are waited for (and the
        // window moves to them), deleted ones fail at once. Never zeros.
        GCDWebServerResponse *response = [PTGatedFileResponse responseForRequest:request
                                                                      controller:[weakSelf controller]
                                                                        fileName:fileName];
        [response setValue:@"*" forAdditionalHeader:@"Access-Control-Allow-Origin"];
        [response setValue:@"Content-Type" forAdditionalHeader:@"Access-Control-Expose-Headers"];
        completionBlock(response);
    }];

    NSMutableDictionary* options = [NSMutableDictionary dictionary];
    NSInteger port = 50321;
    [options setObject:[NSNumber numberWithInteger:port] forKey:GCDWebServerOption_Port];
    NSError *error;

    while (![self.mediaServer startWithOptions:options error:&error]) {
        port++;
        [options setObject:[NSNumber numberWithInteger:port] forKey:GCDWebServerOption_Port];

        /// failed to start webserver
        if (port > 50341) {
            if (_failureBlock) _failureBlock(error);
            [self cancelStreamingAndDeleteData:NO];
            return;
        }
    }

    __block NSURL *serverURL = nil; // ios now requires permission to access local network// self.mediaServer.serverURL;

    if (serverURL == nil) // `nil` when device is on cellular network.
    {
        serverURL = [NSURL URLWithString:[NSString stringWithFormat:@"http://0.0.0.0:%i/", (int)self.mediaServer.port]];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (weakSelf.readyToPlayBlock) weakSelf.readyToPlayBlock(serverURL, fileURL);
    });
}


- (NSString *)folderNameForTorrentNamed:(NSString *)name {
    return name;
}

- (int)selectedFileIndexInTorrent:(torrent_handle)th {
    std::shared_ptr<const torrent_info> ti = th.torrent_file();
    return [self selectedFileIndexInTorrentWithTorrentInfo:ti];
}

/// The file the selection block chose, kept for the stream; `PTTorrentStreamerNoFileIndex`
/// when it chose none (any index out of range): nothing is kept then, the callers fail the
/// stream (`noFileSelectedError`).
- (int)selectedFileIndexInTorrentWithTorrentInfo:(std::shared_ptr<const torrent_info>)ti {
    if (selectedFileIndex != -1) {
        return selectedFileIndex;
    }

    auto files = ti->files();
    NSMutableArray* file_names = [[NSMutableArray alloc] init];
    NSMutableArray* file_sizes = [[NSMutableArray alloc] init];
    for (int i=0; i<ti->num_files(); i++) {
        // Each file's path inside the torrent, folders included ("Show.S01.1080p/Season 1/
        // 01 - Title.mkv"): the selection reads the season of a pack numbered by folders, and a
        // Sample folder, from them (file_name is the last component alone). UTF-8, as torrents
        // name their files ("%s" read them in the system encoding: "Сезон 1", "Capítulo"
        // garbled); the old reading for a name that isn't UTF-8.
        std::string const name = files.file_path(file_index_t(i));
        [file_names addObject:[NSString stringWithUTF8String:name.c_str()] ?: [NSString stringWithFormat:@"%s", name.c_str()]];
        [file_sizes addObject:[NSNumber numberWithLong: files.file_size(file_index_t(i))]];
    }

    int const index = self.selectionBlock([file_names copy], [file_sizes copy]);
    if (index < 0 || index >= ti->num_files()) {
        NSLog(@"PopcornTorrent: the selection chose no file of the torrent (%d, %d files)", index, ti->num_files());
        return PTTorrentStreamerNoFileIndex;
    }
    selectedFileIndex = index;
    return selectedFileIndex;
}

/// The failure of a stream whose selection chose no file (`PTTorrentStreamerErrorNoFileSelected`).
- (NSError *)noFileSelectedError {
    NSString *description = @"This torrent does not contain the requested episode. Please choose another source.".localizedString;
    return [NSError errorWithDomain:PTTorrentStreamerErrorDomain code:PTTorrentStreamerErrorNoFileSelected userInfo:@{NSLocalizedDescriptionKey: description}];
}

#pragma mark - Storage

/// `path`, or its nearest parent that exists: a folder that is not there (yet, or any more) is
/// judged by its volume, not as "unlimited space, no hole punching", which let a film that does
/// not fit stream in full mode.
+ (NSString *)nearestExistingPath:(NSString *)path {
    NSString *existing = path;
    while (existing.length > 1 && ![[NSFileManager defaultManager] fileExistsAtPath:existing]) {
        existing = existing.stringByDeletingLastPathComponent;
    }
    return existing.length > 0 ? existing : path;
}

/// Free space of the volume holding `path`, read on a fresh URL (a reused
/// NSURL caches its resource values).
- (long long)availableSpaceAtPath:(NSString *)path {
    NSURL *url = [NSURL fileURLWithPath:[PTTorrentStreamer nearestExistingPath:path] isDirectory:YES];
    [url removeAllCachedResourceValues];
    NSDictionary *results = [url resourceValuesForKeys:@[NSURLVolumeAvailableCapacityKey] error:nil];
    NSNumber *availableSpace = results[NSURLVolumeAvailableCapacityKey];
    return availableSpace ? availableSpace.longLongValue : LLONG_MAX;
}

/// Bounded storage gives space back by punching holes in the file (APFS), and tells written
/// blocks from unwritten ones with SEEK_HOLE: both are checked on a scratch file once per volume
/// and process (`holeSupportReportForDirectory:passed:`, logged). Where they misbehave, bounded
/// storage would serve zeros or never give space back: the stream is refused instead, as a film
/// that does not fit always was (verify-storage F3a: a stream alone cannot tell).
- (BOOL)volumeSupportsHolesAtPath:(NSString *)path {
    NSString *existing = [PTTorrentStreamer nearestExistingPath:path];
    if (pathconf(existing.fileSystemRepresentation, _PC_MIN_HOLE_SIZE) <= 0) return NO;
    struct ::statfs volume;
    if (::statfs(existing.fileSystemRepresentation, &volume) != 0) return NO;
    NSString *key = [NSString stringWithFormat:@"%d:%d", volume.f_fsid.val[0], volume.f_fsid.val[1]];
    static NSMutableDictionary<NSString *, NSNumber *> *checked;
    static std::mutex checkedLock;
    {
        std::lock_guard<std::mutex> lock(checkedLock);
        if (!checked) checked = [NSMutableDictionary dictionary];
        NSNumber *known = checked[key];
        if (known) return known.boolValue;
    }
    BOOL passed = NO;
    NSString *report = [PTTorrentStreamer holeSupportReportForDirectory:path passed:&passed];
    NSLog(@"PopcornTorrent: %@", report);
    std::lock_guard<std::mutex> lock(checkedLock);
    checked[key] = @(passed);
    return passed;
}

+ (NSString *)holeSupportReportForDirectory:(NSString *)directory passed:(BOOL *)passed {
    if (passed) *passed = NO;
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    char const *dir = directory.fileSystemRepresentation;
    long const minHole = pathconf(dir, _PC_MIN_HOLE_SIZE);
    struct ::statfs volume = {};
    bool const haveVolume = ::statfs(dir, &volume) == 0;
    NSString *where = [NSString stringWithFormat:@"hole self-test in %@ (%s, _PC_MIN_HOLE_SIZE %ld, block %u, free %.1f MiB)",
                       directory, haveVolume ? volume.f_fstypename : "?", minHole, haveVolume ? volume.f_bsize : 0,
                       haveVolume ? double(volume.f_bavail) * double(volume.f_bsize) / 1048576.0 : -1.0];
    if (minHole <= 0) return [where stringByAppendingString:@": FAIL, no holes on this volume"];

    constexpr off_t kMiBytes = 1 << 20;
    NSString *file = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@".pt-hole-selftest-%d-%u", getpid(), arc4random()]];
    int const fd = open(file.fileSystemRepresentation, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0) return [where stringByAppendingFormat:@": FAIL, cannot create a file (errno %d)", errno];
    NSString *failure = nil;
    off_t hole = -2, dataAfterHole = -2, dataAfterPunch = -2;
    long long blocksWritten = -1, blocksPunched = -1;
    struct ::stat info;
    std::vector<uint8_t> buffer(size_t(kMiBytes), 0xA5);
    if (ftruncate(fd, 2 * kMiBytes) != 0) {
        failure = [NSString stringWithFormat:@"ftruncate (errno %d)", errno];
    } else if (pwrite(fd, buffer.data(), buffer.size(), 0) != ssize_t(buffer.size())) {
        failure = [NSString stringWithFormat:@"write (errno %d)", errno];
    } else {
        // What the stream controller does after libtorrent writes a piece: no fsync.
        hole = lseek(fd, 0, SEEK_HOLE);
        dataAfterHole = lseek(fd, kMiBytes, SEEK_DATA);
        int const dataError = dataAfterHole < 0 ? errno : 0;
        if (::fstat(fd, &info) == 0) blocksWritten = (long long)info.st_blocks * 512;
        if (hole != kMiBytes) {
            failure = [NSString stringWithFormat:@"SEEK_HOLE found %lld, not the hole at 1 MiB", (long long)hole];
        } else if (!(dataAfterHole < 0 && dataError == ENXIO)) {
            failure = [NSString stringWithFormat:@"SEEK_DATA after the data found %lld (errno %d), not ENXIO", (long long)dataAfterHole, dataError];
        } else {
            fpunchhole_t punch = {0, 0, 0, kMiBytes / 2};
            if (fcntl(fd, F_PUNCHHOLE, &punch) != 0) {
                failure = [NSString stringWithFormat:@"F_PUNCHHOLE (errno %d)", errno];
            } else {
                dataAfterPunch = lseek(fd, 0, SEEK_DATA);
                if (::fstat(fd, &info) == 0) blocksPunched = (long long)info.st_blocks * 512;
                std::vector<uint8_t> back(size_t(kMiBytes), 0xFF);
                ssize_t const count = pread(fd, back.data(), back.size(), 0);
                bool zeros = count == ssize_t(back.size());
                for (size_t i = 0; zeros && i < size_t(kMiBytes / 2); ++i) zeros = back[i] == 0;
                bool kept = count == ssize_t(back.size());
                for (size_t i = size_t(kMiBytes / 2); kept && i < back.size(); ++i) kept = back[i] == 0xA5;
                if (!zeros || !kept) {
                    failure = [NSString stringWithFormat:@"the punched range does not read as zeros (%d) or the rest changed (%d)", int(zeros), int(kept)];
                } else if (dataAfterPunch != kMiBytes / 2) {
                    failure = [NSString stringWithFormat:@"SEEK_DATA after the punch found %lld, not 512 KiB", (long long)dataAfterPunch];
                }
            }
        }
    }
    close(fd);
    unlink(file.fileSystemRepresentation);
    NSString *figures = [NSString stringWithFormat:@"SEEK_HOLE %lld, SEEK_DATA %lld after the punch, allocated %lld -> %lld KiB",
                         (long long)hole, (long long)dataAfterPunch, blocksWritten / 1024, blocksPunched / 1024];
    if (failure) return [where stringByAppendingFormat:@": FAIL, %@ (%@); bounded storage disabled there", failure, figures];
    if (passed) *passed = YES;
    return [where stringByAppendingFormat:@": PASS (%@)", figures];
}

#pragma mark - Alerts

- (void)metadataReceivedAlert:(torrent_handle)th {
    auto controller = [self controller];
    // The alert and the direct call at start (metadata already there) may both come.
    if (controller && controller->isConfigured()) return;
    if (_guest) {
        [self guestMetadataReceivedAlert:th];
        return;
    }
    int selectedIndex = [self selectedFileIndexInTorrent:th];
    if (selectedIndex == PTTorrentStreamerNoFileIndex) {
        // None of its files is wanted: none downloads, and the stream fails (once).
        auto file_priorities = th.get_file_priorities();
        std::fill(file_priorities.begin(), file_priorities.end(), dont_download);
        th.prioritize_files(file_priorities);
        if (!_noFileReported.exchange(true)) [self handleTorrentError:[self noFileSelectedError]];
        return;
    }
    file_index_t file_index = file_index_t(selectedIndex);

    // Only the selected file is wanted (the window planner never touches other files).
    auto file_priorities = th.get_file_priorities();
    std::fill(file_priorities.begin(), file_priorities.end(), dont_download);
    file_priorities[selectedIndex] = top_priority;
    th.prioritize_files(file_priorities);

    auto ti = th.torrent_file();
    int64_t file_size = ti->files().file_size(file_index);
    _requiredSpace = file_size;
    std::string path = ti->files().file_path(file_index);
    _fileName = [NSString stringWithCString:path.c_str() encoding:NSUTF8StringEncoding];
    NSString *filePath = [self.savePath stringByAppendingPathComponent:_fileName];

    // check if file already downloaded to ignore used space, so it will not be downloaded again from scratch
    ptbounded::BudgetInput input;
    struct ::stat info;
    if (::stat(filePath.fileSystemRepresentation, &info) == 0) {
        input.existingLogicalBytes = info.st_size;
        input.heldBytes = int64_t(info.st_blocks) * 512;
    }
    input.freeBytes = [self availableSpaceAtPath:self.savePath];
    input.fileSize = file_size;
    input.pieceLength = ti->piece_length();
    input.reserveBytes = self.storageReserve;
    input.requestedBudget = self.storageBudget;
    input.durationSeconds = self.mediaDurationHint;
    input.allowBounded = self.allowsBoundedStorage;
    input.appWorkingSetSeconds = self.appWorkingSetSeconds;
    input.pendingExternalBytes = self.pendingExternalBytes;
    if (input.allowBounded && ![self volumeSupportsHolesAtPath:self.savePath]) {
        NSLog(@"PopcornTorrent: no hole punching on the volume of %@, bounded storage disabled", self.savePath);
        input.allowBounded = false;
    }
    ptbounded::BudgetPlan const plan = ptbounded::planBudget(input);

    if (plan.decision == ptbounded::StorageDecision::Refuse) {
        NSError *error;
        if (!input.allowBounded) {
            PTSize *fileSize = [PTSize sizeWithLongLong: file_size];
            NSString *description = [NSString localizedStringWithFormat:@"There is not enough space to download the torrent. Please clear at least %@ and try again.".localizedString, fileSize.stringValue];
            error = [[NSError alloc] initWithDomain:PTTorrentStreamerErrorDomain code:PTTorrentStreamerErrorNotEnoughSpace userInfo:@{NSLocalizedDescriptionKey: description}];
        } else {
            int64_t const usableFree = MAX(0, input.freeBytes - input.pendingExternalBytes);
            PTSize *needed = [PTSize sizeWithLongLong:MAX(0, plan.minimumFreeBytes - usableFree - input.heldBytes)];
            NSString *description = [NSString localizedStringWithFormat:@"There is not enough space to stream this video, even with limited storage. Please clear at least %@ and try again.".localizedString, needed.stringValue];
            error = [[NSError alloc] initWithDomain:PTTorrentStreamerErrorDomain code:PTTorrentStreamerErrorNotEnoughSpaceForBoundedStorage userInfo:@{NSLocalizedDescriptionKey: description}];
        }
        [self handleTorrentError:error];
        return;
    }
    BOOL const bounded = plan.decision == ptbounded::StorageDecision::Bounded;
    @synchronized (self) {
        _storageMode = bounded ? PTStorageModeBounded : PTStorageModeFull;
    }
    _minimumFreeBytes = plan.minimumFreeBytes;
    _starvationReported = NO;
    if (bounded) {
        NSLog(@"PopcornTorrent: bounded storage for %@ (%lld bytes, %lld free, torrent budget %lld, reserve %lld)",
              _fileName, file_size, input.freeBytes, plan.torrentBudget, input.reserveBytes);
    }

    [self configureController:controller torrent:th fileIndex:file_index filePath:filePath bounded:bounded
                         plan:plan reserveBytes:input.reserveBytes fileExisted:input.heldBytes > 0 sharedTorrent:NO];
    if (controller && input.requestedBudget > 0) controller->setTorrentBudget(input.requestedBudget);
    if (controller && input.pendingExternalBytes > 0) controller->setPendingExternalBytes(input.pendingExternalBytes);
    _hasMetadata = true;

    [self updateAndMonitorTorrentProgress];

    // file already downloaded
    if (_isFinished) {
        [self torrentFinishedAlert:th];
        return;
    }
}

/// A stream that joined a torrent another streamer added (an offline download): it reads
/// that streamer's file, in full mode (the download keeps the whole file anyway: no space
/// check), with its own window, piece states and verification (its own plugin).
- (void)guestMetadataReceivedAlert:(torrent_handle)th {
    auto controller = [self controller];
    if (!controller || !_guest) return;
    PTTorrentStreamer *owner = [self.session ownerOfGuest:self];
    int const ownerIndex = owner ? owner->selectedFileIndex : -1;
    if (owner && ownerIndex < 0) {
        // The owner has not processed this metadata yet (it gets the alert first): look again.
        __weak __typeof__(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __typeof__(self) strongSelf = weakSelf;
            if (strongSelf && strongSelf->_torrentHandle.is_valid()) [strongSelf metadataReceivedAlert:strongSelf->_torrentHandle];
        });
        return;
    }
    int const selectedIndex = [self selectedFileIndexInTorrent:th];
    if (selectedIndex == PTTorrentStreamerNoFileIndex) {
        // Not the owner's file nor any other: the owner's priorities stay as they are.
        if (!_noFileReported.exchange(true)) [self handleTorrentError:[self noFileSelectedError]];
        return;
    }
    if (owner == nil || ownerIndex != selectedIndex) {
        // Another file of the torrent: its priorities are the owner's (one file per torrent).
        // Another episode of a season pack a download is fetching says so: "this video" would
        // be wrong.
        BOOL const otherEpisode = owner != nil && ownerIndex >= 0 && [owner isKindOfClass:[PTTorrentDownload class]];
        NSString *description = otherEpisode
            ? @"Another episode of this torrent is being downloaded. Try again once that download is finished, or delete it.".localizedString
            : @"This video is already being played or downloaded. Stop the other playback or the download, then try again.".localizedString;
        [self handleTorrentError:[NSError errorWithDomain:PTTorrentStreamerErrorDomain code:PTTorrentStreamerErrorTorrentInUse userInfo:@{NSLocalizedDescriptionKey: description}]];
        return;
    }
    file_index_t const file_index = file_index_t(selectedIndex);
    auto ti = th.torrent_file();
    _requiredSpace = ti->files().file_size(file_index);
    _fileName = [NSString stringWithCString:ti->files().file_path(file_index).c_str() encoding:NSUTF8StringEncoding];
    if (owner.savePath) _savePath = owner.savePath;
    NSString *filePath = [self.savePath stringByAppendingPathComponent:_fileName];
    @synchronized (self) {
        _storageMode = PTStorageModeFull;
    }
    ptbounded::BudgetPlan plan;
    plan.decision = ptbounded::StorageDecision::Full;
    [self configureController:controller torrent:th fileIndex:file_index filePath:filePath bounded:NO
                         plan:plan reserveBytes:self.storageReserve fileExisted:YES sharedTorrent:YES];
    th.add_extension(ptbounded::makeStreamPluginFactory(controller));
    _hasMetadata = true;

    [self updateAndMonitorTorrentProgress];
    if (_isFinished) [self torrentFinishedAlert:th];
}

/// The controller of this stream: window, pins, pieces needed before it is ready, hashes.
- (void)configureController:(std::shared_ptr<ptbounded::StreamController> const &)controller
                    torrent:(torrent_handle const &)th
                  fileIndex:(file_index_t)file_index
                   filePath:(NSString *)filePath
                    bounded:(BOOL)bounded
                       plan:(ptbounded::BudgetPlan const &)plan
               reserveBytes:(int64_t)reserveBytes
                fileExisted:(BOOL)fileExisted
              sharedTorrent:(BOOL)sharedTorrent {
    auto ti = th.torrent_file();
    int64_t const file_size = ti->files().file_size(file_index);

    // download first pieces
    MIN_PIECES = (ti->files().file_size(file_index) * 0.03) / ti->piece_length();
    MIN_PIECES = std::max(1, std::min(MIN_PIECES, 20));
    int const maxEndPieces = MIN_PIECES <= 6 ? 1 : 2;

    ptbounded::StreamConfig config;
    config.geometry.fileOffset = ti->files().file_offset(file_index);
    config.geometry.fileSize = file_size;
    config.geometry.pieceLength = ti->piece_length();
    config.budget = plan;
    config.bounded = bounded;
    config.reserveBytes = reserveBytes;
    config.filePath = std::string(filePath.fileSystemRepresentation);
    config.directoryPath = std::string(self.savePath.fileSystemRepresentation);
    config.fileExisted = fileExisted;
    config.sharedTorrent = sharedTorrent;
    // The tail a player reads at open (MKV Cues, an MP4 moov stored at the end) is pinned at
    // top priority: at least kTailPinBytes in whole pieces (at most 10 pieces), never fewer
    // pieces than before. The stream still waits only for the last 1 or 2 of them, as before
    // (full mode: only those get deadlines; the rest come right after the head window).
    int const tailPieces = ptbounded::tailPinPieces(config.geometry, bounded ? ptbounded::kTailPinPieces : maxEndPieces);
    config.urgentTailPieces = bounded ? 0 : maxEndPieces;
    if (bounded) {
        // A window of at least 32 MiB at top priority, fetched first by the sequential
        // picker. No libtorrent deadlines here: while time-critical pieces exist it keeps
        // one normal request per peer and, in the offline tests, kept filling the disk
        // with pieces far ahead while the window starved.
        int64_t const pieceLength = ti->piece_length();
        int window = std::max<int>(MIN_PIECES, int((32 * ptbounded::kMiB + pieceLength - 1) / pieceLength));
        window = std::min<int>(window, int(std::max<int64_t>(2, plan.minAhead / pieceLength / 2)));
        config.windowPieces = std::max(2, std::min(window, 32));
        config.tailPieces = tailPieces;
        config.deadlineFirstMs = PIECE_DEADLINE_MILLIS;
        config.deadlineStepMs = 20;
        config.useDeadlines = false;
    } else {
        // The MIN_PIECES pieces from the read position: their first 8 MiB (2 pieces at least)
        // at top priority, the rest at 6, then the rest of the file, all in file order
        // (sequential picker), at full speed; a gap a seek or a resume left behind the reader
        // only once the window is on disk (planWindow, holdGap). No deadline ahead of time:
        // while any piece of a torrent has one, libtorrent holds every peer to one request at
        // a time (see planWindow); a piece a reader waits for gets one only once it is late
        // (lateAfterMs, at least two pieces' time at the current rate), and the requests slow
        // peers hold for it are taken back (StreamController::rescueLatePieces).
        int64_t const pieceLength = ti->piece_length();
        config.windowPieces = MIN_PIECES;
        config.topPriorityPieces = std::min(MIN_PIECES, std::max(2, int((8 * ptbounded::kMiB + pieceLength - 1) / pieceLength)));
        config.deadlineHorizonPieces = -1;
        config.lateAfterMs = 1000;
        config.tailPieces = tailPieces;
        config.deadlineFirstMs = PIECE_DEADLINE_MILLIS;
        config.deadlineStepMs = 0;
    }

    // Pieces needed before the stream is ready. Bounded: no more than the window, so they
    // are all fetched at once and unthrottled (beyond it they would be paced like any
    // data ahead, at the floor rate when the minimum working set is tight).
    int const headPieces = bounded ? std::min(MIN_PIECES, config.windowPieces) : MIN_PIECES;
    piece_index_t first_piece = ti->map_file(file_index, 0, 0).piece;
    mtx.lock();
    required_pieces.clear();
    for (int i = 0; i < headPieces; i++) {
        required_pieces.push_back(first_piece);
        first_piece++;
    }

    // download last pieces
    piece_index_t last_piece = ti->map_file(file_index, file_size - 1, 0).piece;
    lastFilePiece = last_piece;
    for (int i = 0; i < maxEndPieces; i++) {
        required_pieces.push_back(last_piece);
        last_piece--;
    }
    mtx.unlock();

    for (piece_index_t piece : required_pieces) {
        int32_t const index = int32_t(static_cast<int>(piece));
        if (std::find(config.requiredPieces.begin(), config.requiredPieces.end(), index) == config.requiredPieces.end()) {
            config.requiredPieces.push_back(index);
        }
    }
    // Hashes of the pieces wholly inside the file: a piece that may land over stale
    // bytes is verified by its content (see StreamController::verify).
    int32_t const filePieces = config.geometry.pieceCount();
    config.pieceHashes.assign(size_t(filePieces) * 20, '\0');
    int64_t const fileEnd = config.geometry.fileOffset + file_size;
    for (int32_t i = 0; i < filePieces; ++i) {
        piece_index_t const piece(config.geometry.firstPiece() + i);
        int64_t const pieceStart = int64_t(static_cast<int>(piece)) * ti->piece_length();
        if (pieceStart < config.geometry.fileOffset || pieceStart + ti->piece_size(piece) > fileEnd) continue;
        sha1_hash const hash = ti->hash_for_piece(piece);
        std::memcpy(&config.pieceHashes[size_t(i) * 20], hash.data(), 20);
    }
    if (controller) controller->configure(config);
}

/// Status shared by the 0.5 s monitor and the piece / finished alerts.
- (void)refreshTorrentStatus:(torrent_status const &)status {
    auto controller = [self controller];
    float bufferingProgress = _torrentStatus.bufferingProgress;
    float totalProgress = status.progress;
    long long downloaded = status.total_wanted_done;
    bool finished = status.is_finished;
    if (controller && controller->isConfigured()) {
        if (![self isStreaming]) {
            auto const progress = controller->requiredProgress();
            bufferingProgress = progress.second > 0 ? float(progress.first) / float(progress.second) : 0;
        } else {
            bufferingProgress = controller->windowProgress();
        }
        if (controller->isBounded()) {
            // Deleted pieces are not "wanted" any more: libtorrent's progress would reach 1.
            downloaded = controller->everDownloadedBytes();
            finished = controller->isFileComplete();
            totalProgress = finished ? 1 : std::min(0.999f, float(double(downloaded) / double(MAX(1LL, _requiredSpace))));
        }
    }
    _torrentStatus = {
        bufferingProgress,
        totalProgress,
        status.download_rate,
        status.upload_rate,
        status.num_seeds,
        status.num_peers
    };
    _totalDownloaded = downloaded;
    _isFinished = finished;
}

/// Publishes the status now and makes sure the 0.5 s loop runs. Called when the torrent is
/// added (a stream resolving a magnet's metadata) and at the metadata (alerts thread, or the
/// start for a `.torrent` file): one loop per stream, whichever comes first starts it. Before,
/// the loop started at the metadata only, and a second call started a second loop.
- (void)updateAndMonitorTorrentProgress {
    if (![self publishTorrentProgress]) return;
    uint64_t const generation = _monitorGeneration.load();
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_monitorGeneration.load() != generation || self->_monitorLoopGeneration == generation) return;
        self->_monitorLoopGeneration = generation;
        [self scheduleMonitorTick:generation];
    });
}

/// Main queue: the next tick of the loop of `generation`, in 0.5 s. The loop stops when its
/// stream was cancelled or restarted, or when there is nothing to publish (no progress block,
/// no torrent, a finished full-mode torrent, a starved bounded start).
- (void)scheduleMonitorTick:(uint64_t)generation {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (self->_monitorGeneration.load() != generation || ![self publishTorrentProgress]) {
            if (self->_monitorLoopGeneration == generation) self->_monitorLoopGeneration = 0;
            return;
        }
        [self scheduleMonitorTick:generation];
    });
}

/// Reads the torrent's status and posts it (progress block, PTTorrentStatusDidChangeNotification)
/// on the main queue. Before the metadata: seeds, peers and rates, buffering 0. `NO` when
/// there is nothing to publish.
- (BOOL)publishTorrentProgress {
    BOOL const bounded = self.storageMode == PTStorageModeBounded;
    if (!_progressBlock || !_torrentHandle.is_valid() || (self.status.is_finished && !bounded)) {
        return NO;
    }
    if (bounded && [self failStarvedStart]) return NO;

    torrent_status const status = _torrentHandle.status();
    self.status = status;
    [self refreshTorrentStatus:status];

    uint64_t const generation = _monitorGeneration.load();
    dispatch_async(dispatch_get_main_queue(), ^{
        // Not for a stream cancelled (or restarted) in the meantime.
        if (![self isStreamOfGeneration:generation]) return;
        if (_progressBlock) _progressBlock(_torrentStatus);
        [[NSNotificationCenter defaultCenter] postNotificationName:PTTorrentStatusDidChangeNotification object:self];
    });
    return YES;
}

/// Main queue. Bounded mode: a stream that is not ready yet while the volume has stayed too full
/// for the download to go on for kStartStarvationSeconds fails with
/// NotEnoughSpaceForBoundedStorage (before: it loaded forever, e2e B1). A ready stream never
/// fails this way: its reader waits for the space to come back. YES if it failed.
- (BOOL)failStarvedStart {
    if (_starvationReported || [self isStreaming]) return NO;
    auto controller = [self controller];
    if (!controller || !controller->isBounded()) return NO;
    double const starved = controller->diskStarvedSeconds();
    if (!ptbounded::startStarvationExpired(false, starved)) return NO;
    _starvationReported = YES;
    int64_t const freeBytes = controller->freeBytes();
    int64_t const held = controller->bytesOnDisk();
    int64_t const needed = ptbounded::bytesToFreeAfterStarvation(_minimumFreeBytes, freeBytes, held);
    NSLog(@"PopcornTorrent bounded: the volume stayed too full for %.0f s before the stream was ready "
          "(free %lld MiB, the file holds %lld MiB, to free %lld MiB): stream failed", starved,
          freeBytes / ptbounded::kMiB, held / ptbounded::kMiB, needed / ptbounded::kMiB);
    NSString *description;
    if (needed > 0) {
        PTSize *amount = [PTSize sizeWithLongLong:needed];
        description = [NSString localizedStringWithFormat:@"There is not enough space to stream this video, even with limited storage. Please clear at least %@ and try again.".localizedString, amount.stringValue];
    } else {
        description = @"There is not enough free space to start this video. Please clear some space and try again.".localizedString;
    }
    [self handleTorrentError:[NSError errorWithDomain:PTTorrentStreamerErrorDomain
                                                 code:PTTorrentStreamerErrorNotEnoughSpaceForBoundedStorage
                                             userInfo:@{NSLocalizedDescriptionKey: description}]];
    return YES;
}

- (void)pieceFinishedAlert:(torrent_handle)th forPieceIndex:(piece_index_t)index {
    torrent_status const status = th.status();
    self.status = status;
    [self refreshTorrentStatus:status];

    uint64_t const generation = _monitorGeneration.load();
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self isStreamOfGeneration:generation]) return; // cancelled or restarted since
        if (_progressBlock) _progressBlock(_torrentStatus);
        [[NSNotificationCenter defaultCenter] postNotificationName:PTTorrentStatusDidChangeNotification object:self];
        [self evaluateReadiness];
    });
}

- (void)torrentFinishedAlert:(torrent_handle)th {
    [self processTorrent:th];
    torrent_status const status = self.status;

    if (self.storageMode == PTStorageModeBounded) {
        // Every wanted piece is here, but the reader may still seek into a gap:
        // keep the torrent running. It is removed at cancel.
        [self refreshTorrentStatus:status];
        uint64_t const generation = _monitorGeneration.load();
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self isStreamOfGeneration:generation]) return; // cancelled or restarted since
            if (_progressBlock) _progressBlock(_torrentStatus);
            [[NSNotificationCenter defaultCenter] postNotificationName:PTTorrentStatusDidChangeNotification object:self];
        });
        return;
    }

    _torrentStatus = {
        1, 1,
        status.download_rate,
        status.upload_rate,
        status.num_seeds,
        status.num_peers
    };

    _totalDownloaded = status.total_wanted_done;
    _isFinished = status.is_finished;

    uint64_t const generation = _monitorGeneration.load();
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self isStreamOfGeneration:generation]) return; // cancelled or restarted since
        if (_progressBlock) _progressBlock(_torrentStatus);
        [[NSNotificationCenter defaultCenter] postNotificationName:PTTorrentStatusDidChangeNotification object:self];
    });

    // Stop the finished torrent (no seeding); it is removed from the session at cancel.
    // A stream that joined a download's torrent leaves that to the download.
    if (!_guest) [self.session finishTorrent:self];
}

#pragma mark - Shared torrents

- (BOOL)isGuest {
    return _guest;
}

- (BOOL)canJoinSharedTorrent {
    return YES;
}

- (BOOL)canShareTorrentWithGuests {
    if (_guest) return NO;
    // A bounded stream deletes what its reader consumed: nobody else can read its file.
    PTStorageMode const mode = self.storageMode;
    return mode == PTStorageModeFull || (mode == PTStorageModeUndetermined && !self.allowsBoundedStorage);
}

- (BOOL)handsTorrentOverToGuests {
    // A stream gives its torrent (and its files) to the streams that joined it; a download
    // keeps its own (PTTorrentDownload).
    return YES;
}

- (void)sharedTorrentWillGainGuests {}

- (void)sharedTorrentDidLoseGuests {}

- (void)sharedTorrentBecameOwned {
    // The streamer this stream joined left and handed its torrent over: from now on this
    // stream owns it (and its files), as if it had added it.
    _guest = NO;
}

- (void)sharedTorrentRemovedByOwner:(BOOL)deletedFiles {
    if (!_guest) return;
    // The torrent is gone: nothing to drive or query any more.
    _torrentHandle = libtorrent::torrent_handle();
    auto controller = [self controller];
    if (!deletedFiles && controller && controller->allPiecesHaveData()) {
        // The download finished: the whole file is there, keep reading it.
        _isFinished = true;
        _torrentStatus.bufferingProgress = 1;
        _torrentStatus.totalProgress = 1;
        _totalDownloaded = _requiredSpace;
        if (_progressBlock) _progressBlock(_torrentStatus);
        [[NSNotificationCenter defaultCenter] postNotificationName:PTTorrentStatusDidChangeNotification object:self];
        return;
    }
    NSString *description = @"This video was playing from its download, and the download was stopped.".localizedString;
    [self handleTorrentError:[NSError errorWithDomain:PTTorrentStreamerErrorDomain code:PTTorrentStreamerErrorSharedTorrentRemoved userInfo:@{NSLocalizedDescriptionKey: description}]];
}

@synthesize status = _status;

- (torrent_status)status {
    std::lock_guard<std::mutex> lock(_statusMutex);
    return _status;
}

- (void)setStatus:(torrent_status)status {
    std::lock_guard<std::mutex> lock(_statusMutex);
    _status = std::move(status);
}

#pragma mark - Bounded storage

- (BOOL)allowsBoundedStorage {
    @synchronized (self) { return _allowsBoundedStorage; }
}

- (void)setAllowsBoundedStorage:(BOOL)allowsBoundedStorage {
    @synchronized (self) { _allowsBoundedStorage = allowsBoundedStorage; }
}

- (int64_t)storageReserve {
    @synchronized (self) { return _storageReserve; }
}

- (void)setStorageReserve:(int64_t)storageReserve {
    @synchronized (self) { _storageReserve = MAX(0, storageReserve); }
}

- (int64_t)storageBudget {
    @synchronized (self) { return _storageBudget; }
}

- (void)setStorageBudget:(int64_t)storageBudget {
    @synchronized (self) { _storageBudget = MAX(0, storageBudget); }
    auto controller = [self controller];
    if (controller && controller->isConfigured()) controller->setTorrentBudget(MAX(0, storageBudget));
}

- (NSTimeInterval)mediaDurationHint {
    @synchronized (self) { return _mediaDurationHint; }
}

- (void)setMediaDurationHint:(NSTimeInterval)mediaDurationHint {
    @synchronized (self) { _mediaDurationHint = MAX(0, mediaDurationHint); }
}

- (NSTimeInterval)appWorkingSetSeconds {
    @synchronized (self) { return _appWorkingSetSeconds; }
}

- (void)setAppWorkingSetSeconds:(NSTimeInterval)appWorkingSetSeconds {
    @synchronized (self) { _appWorkingSetSeconds = MAX(0, appWorkingSetSeconds); }
}

- (int64_t)pendingExternalBytes {
    @synchronized (self) { return _pendingExternalBytes; }
}

- (void)setPendingExternalBytes:(int64_t)pendingExternalBytes {
    @synchronized (self) { _pendingExternalBytes = MAX(0, pendingExternalBytes); }
    auto controller = [self controller];
    if (controller) controller->setPendingExternalBytes(MAX(0, pendingExternalBytes));
}

- (PTStorageMode)storageMode {
    @synchronized (self) { return _storageMode; }
}

- (BOOL)isStorageBounded {
    return self.storageMode == PTStorageModeBounded;
}

- (void)setReadPosition:(int64_t)fileOffset {
    auto controller = [self controller];
    if (controller) controller->setReadPosition(fileOffset);
}

- (void)setConsumedBefore:(int64_t)fileOffset {
    auto controller = [self controller];
    if (controller) controller->setConsumedBefore(fileOffset);
}

- (int64_t)readPosition {
    auto controller = [self controller];
    return controller ? controller->readPosition() : 0;
}

- (int64_t)consumedBefore {
    auto controller = [self controller];
    return controller ? controller->consumedBefore() : 0;
}

- (int64_t)lowestAvailableOffset {
    auto controller = [self controller];
    return controller ? controller->lowestAvailableOffset() : 0;
}

- (int64_t)servedOffset {
    auto controller = [self controller];
    return controller ? controller->servedOffset() : 0;
}

- (int64_t)firstMissingOffsetFrom:(int64_t)fileOffset {
    auto controller = [self controller];
    return controller ? controller->firstMissingOffset(fileOffset) : MAX(0, fileOffset);
}

- (BOOL)isRangeAvailable:(int64_t)fileOffset length:(int64_t)length {
    auto controller = [self controller];
    return controller ? controller->isRangeOnDisk(fileOffset, length) : NO;
}

- (int64_t)contiguousAvailableOffsetBefore:(int64_t)fileOffset {
    auto controller = [self controller];
    return controller ? controller->contiguousAvailableStart(fileOffset) : MAX(0, fileOffset);
}

- (BOOL)isFileComplete {
    auto controller = [self controller];
    return controller ? controller->isFileComplete() : NO;
}

- (int64_t)bytesOnDisk {
    auto controller = [self controller];
    return controller ? controller->bytesOnDisk() : 0;
}

- (NSDictionary<NSString *, NSNumber *> *)storageStatistics {
    auto controller = [self controller];
    if (!controller || !controller->isConfigured()) return @{};
    ptbounded::StreamStatistics const s = controller->statistics();
    return @{
        @"bounded": @(s.bounded),
        @"fileSize": @(s.fileSize),
        @"pieceLength": @(s.pieceLength),
        @"torrentBudget": @(s.torrentBudget),
        @"aheadBudget": @(s.aheadBudget),
        @"aheadBytes": @(s.aheadBytes),
        @"behindBytes": @(s.behindBytes),
        @"pinnedBytes": @(s.pinnedBytes),
        @"dataBytes": @(s.dataBytes),
        @"bytesOnDisk": @(controller->bytesOnDisk()),
        @"freeBytes": @(s.freeBytes == INT64_MAX ? -1 : s.freeBytes),
        @"reserveBytes": @(s.reserveBytes),
        @"readPosition": @(s.readPosition),
        @"consumedBefore": @(s.consumedBefore),
        @"lowestAvailableOffset": @(s.lowestAvailableOffset),
        @"servedOffset": @(s.servedOffset),
        @"headPinEnd": @(s.headPinEnd),
        @"tailPinStart": @(s.tailPinStart),
        @"everDownloaded": @(s.everDownloaded),
        @"freedPieces": @(s.freedPieces),
        @"droppedPieces": @(s.droppedPieces),
        @"punchedBytes": @(s.punchedBytes),
        @"punchErrors": @(s.punchErrors),
        @"diskFullEvents": @(s.diskFullEvents),
        @"fileErrors": @(s.fileErrors),
        @"dontHaveSent": @(s.dontHaveSent),
        @"rescuedBlocks": @(s.rescuedBlocks),
        @"partialPiecesPunched": @(s.partialPunched),
        @"reclaimedBytes": @(s.reclaimedBytes),
        @"presized": @(s.presized),
        @"stuckPiecesRestored": @(s.stuckPiecesRestored),
        @"diskStarvedSeconds": @(s.diskStarvedSeconds),
        @"waitingReads": @(s.waiters),
        @"downloadLimit": @(s.downloadLimit),
        @"paceState": @(s.paceState),
        @"consumeRate": @(s.consumeRate),
    };
}

@end
