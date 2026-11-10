

#import "PTTorrentStreamer.h"
#import <Foundation/Foundation.h>
#import <string>
#import <sys/stat.h>
#import <mutex>
#import <libtorrent/bencode.hpp>
#import "../Security/CocoaSecurity.h"
#import "../Resources/NSString+Localization.h"
#import "PTTorrentStreamer+Protected.h"
#import <GCDWebServer.h>
#import "PTTorrentsSession.h"
#import "PTTorrentsSession+Protected.h"
#import "PTSize.h"
#import "../Bounded/PTStreamController.h"
#import "../Bounded/PTGatedFileResponse.h"

#define PIECE_DEADLINE_MILLIS 100

NSNotificationName const PTTorrentStatusDidChangeNotification = @"com.popcorntimetv.popcorntorrent.status.change";
NSErrorDomain const PTTorrentStreamerErrorDomain = @"com.popcorntimetv.popcorntorrent.error";


using namespace libtorrent;

@implementation PTTorrentStreamer {
    BOOL _allowsBoundedStorage;
    int64_t _storageReserve;
    int64_t _storageBudget;
    NSTimeInterval _mediaDurationHint;
    PTStorageMode _storageMode;
    // _status holds strings: it is written from the alerts queue and the main queue.
    std::mutex _statusMutex;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        selectedFileIndex = -1;
        _allowsBoundedStorage = YES;
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
                MIN_PIECES = ((tp.ti->files().file_size(libtorrent::file_index_t(index)) * 0.03)/tp.ti->piece_length());
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
    NSString *pathComponent = directoryName != nil ? directoryName : [MD5String substringToIndex:16];

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

    _savePath = [basePath stringByAppendingPathComponent:pathComponent];
    //create folder for torrents
    if (![[NSFileManager defaultManager] fileExistsAtPath:_savePath]) {
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

    // torrent exists, give it a new session, so there is no interference
    if (error && error.code == -2) {
        error = nil;
        self.session = [[PTTorrentsSession alloc] init];
        self.deleteOnlyDownloadedFile = YES;
        PTTorrentStreamer *existing = [[PTTorrentsSession sharedSession] torrentStreamerForTorrentHandle:_torrentHandle];
        existing.deleteOnlyDownloadedFile = YES;
        _torrentHandle = [self.session addTorrent:self params:tp error:&error];
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
    }
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
    NSError *error = [[NSError alloc] initWithDomain:PTTorrentStreamerErrorDomain code:-4 userInfo:@{NSLocalizedDescriptionKey: description}];
    [self handleTorrentError:error];
}

- (void)cancelStreamingAndDeleteData:(BOOL)deleteData {
    auto controller = std::atomic_exchange(&_controller, std::shared_ptr<ptbounded::StreamController>());
    BOOL const bounded = self.storageMode == PTStorageModeBounded;
    if (controller) controller->cancel();
    // A file with deleted pieces cannot be resumed: bounded mode always deletes it.
    if (bounded) deleteData = YES;

    [self.session removeTorrent:self
                    deleteFiles:deleteData && !self.deleteOnlyDownloadedFile
                 saveResumeData:!bounded];

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

    if (deleteData) {
        if (self.deleteOnlyDownloadedFile) {
            NSString *filePath = [self.savePath stringByAppendingPathComponent:_fileName];
            [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
        } else {
            // delete whole directory
            [[NSFileManager defaultManager] removeItemAtPath:self.savePath error:nil];
        }
        _savePath = nil;
        _fileName = nil;
        _requiredSpace = 0;
        _totalDownloaded = 0;
        selectedFileIndex = -1;
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


- (int)selectedFileIndexInTorrent:(torrent_handle)th {
    std::shared_ptr<const torrent_info> ti = th.torrent_file();
    return [self selectedFileIndexInTorrentWithTorrentInfo:ti];
}

- (int)selectedFileIndexInTorrentWithTorrentInfo:(std::shared_ptr<const torrent_info>)ti {
    if (selectedFileIndex != -1) {
        return selectedFileIndex;
    }

    auto files = ti->files();
    NSMutableArray* file_names = [[NSMutableArray alloc] init];
    NSMutableArray* file_sizes = [[NSMutableArray alloc] init];
    for (int i=0; i<ti->num_files(); i++) {
        [file_names addObject:[NSString stringWithFormat:@"%s", files.file_name(file_index_t(i)).to_string().c_str()]];
        [file_sizes addObject:[NSNumber numberWithLong: files.file_size(file_index_t(i))]];
    }

    selectedFileIndex = self.selectionBlock([file_names copy], [file_sizes copy]);
    return selectedFileIndex;
}

#pragma mark - Storage

/// Free space of the volume holding `path`, read on a fresh URL (a reused
/// NSURL caches its resource values).
- (long long)availableSpaceAtPath:(NSString *)path {
    NSURL *url = [NSURL fileURLWithPath:path isDirectory:YES];
    [url removeAllCachedResourceValues];
    NSDictionary *results = [url resourceValuesForKeys:@[NSURLVolumeAvailableCapacityKey] error:nil];
    NSNumber *availableSpace = results[NSURLVolumeAvailableCapacityKey];
    return availableSpace ? availableSpace.longLongValue : LLONG_MAX;
}

#pragma mark - Alerts

- (void)metadataReceivedAlert:(torrent_handle)th {
    auto controller = [self controller];
    int selectedIndex = [self selectedFileIndexInTorrent:th];
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
    ptbounded::BudgetPlan const plan = ptbounded::planBudget(input);

    if (plan.decision == ptbounded::StorageDecision::Refuse) {
        NSError *error;
        if (!input.allowBounded) {
            PTSize *fileSize = [PTSize sizeWithLongLong: file_size];
            NSString *description = [NSString localizedStringWithFormat:@"There is not enough space to download the torrent. Please clear at least %@ and try again.".localizedString, fileSize.stringValue];
            error = [[NSError alloc] initWithDomain:PTTorrentStreamerErrorDomain code:PTTorrentStreamerErrorNotEnoughSpace userInfo:@{NSLocalizedDescriptionKey: description}];
        } else {
            PTSize *needed = [PTSize sizeWithLongLong:MAX(0, plan.minimumFreeBytes - input.freeBytes)];
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

    // download first pieces
    MIN_PIECES = (ti->files().file_size(file_index) * 0.03) / ti->piece_length();
    MIN_PIECES = std::max(1, std::min(MIN_PIECES, 20));
    piece_index_t first_piece = ti->map_file(file_index, 0, 0).piece;
    mtx.lock();
    required_pieces.clear();
    for (int i = 0; i < MIN_PIECES; i++) {
        required_pieces.push_back(first_piece);
        first_piece++;
    }

    // download last pieces
    piece_index_t last_piece = ti->map_file(file_index, file_size - 1, 0).piece;
    lastFilePiece = last_piece;
    int maxEndPieces = MIN_PIECES <= 6 ? 1 : 2;
    for (int i = 0; i < maxEndPieces; i++) {
        required_pieces.push_back(last_piece);
        last_piece--;
    }
    mtx.unlock();

    ptbounded::StreamConfig config;
    config.geometry.fileOffset = ti->files().file_offset(file_index);
    config.geometry.fileSize = file_size;
    config.geometry.pieceLength = ti->piece_length();
    config.budget = plan;
    config.bounded = bounded;
    config.reserveBytes = input.reserveBytes;
    config.filePath = std::string(filePath.fileSystemRepresentation);
    config.directoryPath = std::string(self.savePath.fileSystemRepresentation);
    for (piece_index_t piece : required_pieces) {
        int32_t const index = int32_t(static_cast<int>(piece));
        if (std::find(config.requiredPieces.begin(), config.requiredPieces.end(), index) == config.requiredPieces.end()) {
            config.requiredPieces.push_back(index);
        }
    }
    if (bounded) {
        // A window of at least 32 MiB at top priority, fetched first by the sequential
        // picker. No libtorrent deadlines here: while time-critical pieces exist it keeps
        // one normal request per peer and, in the offline tests, kept filling the disk
        // with pieces far ahead while the window starved.
        int64_t const pieceLength = ti->piece_length();
        int window = std::max<int>(MIN_PIECES, int((32 * ptbounded::kMiB + pieceLength - 1) / pieceLength));
        window = std::min<int>(window, int(std::max<int64_t>(2, plan.minAhead / pieceLength / 2)));
        config.windowPieces = std::max(2, std::min(window, 32));
        config.tailPieces = ptbounded::kTailPinPieces;
        config.deadlineFirstMs = PIECE_DEADLINE_MILLIS;
        config.deadlineStepMs = 20;
        config.useDeadlines = false;
        NSLog(@"PopcornTorrent: bounded storage for %@ (%lld bytes, %lld free, torrent budget %lld, reserve %lld)",
              _fileName, file_size, input.freeBytes, plan.torrentBudget, input.reserveBytes);
    } else {
        // Same window as before: the next MIN_PIECES missing pieces, 100 ms deadlines,
        // the last pieces at top priority.
        config.windowPieces = MIN_PIECES;
        config.tailPieces = maxEndPieces;
        config.deadlineFirstMs = PIECE_DEADLINE_MILLIS;
        config.deadlineStepMs = 0;
    }
    if (controller) {
        controller->configure(config);
        if (input.requestedBudget > 0) controller->setTorrentBudget(input.requestedBudget);
    }

    [self updateAndMonitorTorrentProgress];

    // file already downloaded
    if (_isFinished) {
        [self torrentFinishedAlert:th];
        return;
    }
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

- (void)updateAndMonitorTorrentProgress {
    BOOL const bounded = self.storageMode == PTStorageModeBounded;
    if (!_progressBlock || !_torrentHandle.is_valid() || (self.status.is_finished && !bounded)) {
        return;
    }

    torrent_status const status = _torrentHandle.status();
    self.status = status;
    [self refreshTorrentStatus:status];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (_progressBlock) _progressBlock(_torrentStatus);
        [[NSNotificationCenter defaultCenter] postNotificationName:PTTorrentStatusDidChangeNotification object:self];
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self updateAndMonitorTorrentProgress];
    });
}

- (void)pieceFinishedAlert:(torrent_handle)th forPieceIndex:(piece_index_t)index {
    torrent_status const status = th.status();
    self.status = status;
    [self refreshTorrentStatus:status];

    dispatch_async(dispatch_get_main_queue(), ^{
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
        dispatch_async(dispatch_get_main_queue(), ^{
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

    dispatch_async(dispatch_get_main_queue(), ^{
        if (_progressBlock) _progressBlock(_torrentStatus);
        [[NSNotificationCenter defaultCenter] postNotificationName:PTTorrentStatusDidChangeNotification object:self];
    });

    // Stop the finished torrent (no seeding); it is removed from the session at cancel.
    [self.session finishTorrent:self];
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
        @"waitingReads": @(s.waiters),
        @"downloadLimit": @(s.downloadLimit),
        @"paceState": @(s.paceState),
        @"consumeRate": @(s.consumeRate),
    };
}

@end
