

#import "PTTorrentDownload.h"
#import "PTSize.h"
#import "PTTorrentStreamer+Protected.h"
#import "PTTorrentsSession+Protected.h"
#import "PTTorrentDownloadManagerListener.h"
#import <MediaPlayer/MPMediaItem.h>
#if TARGET_OS_IOS || TARGET_OS_TV
#import <UIKit/UIApplication.h>
#endif

NSString * const PTTorrentItemPropertyDownloadStatus = @"downloadStatus";
NSString * const MPMediaItemPropertyPathOrLink = @"filePathOrLink";
NSString * const PTTorrentItemPropertyTorrentProgress = @"progress";
NSString * const MPMediaItemPropertySelectedFileIndex = @"selectedFileIndex";

using namespace libtorrent;

@implementation PTTorrentDownload {
    PTTorrentDownloadStatus _downloadStatus;
}

- (PTTorrentDownloadStatus)downloadStatus {
    return _downloadStatus;
}

+ (NSString *)downloadDirectory {
    NSURL *URL;
    
#if TARGET_OS_IOS
    URL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
#elif TARGET_OS_TV
    URL = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] lastObject];
#elif TARGET_OS_MAC
    URL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
#endif
    
    NSString *downloadDirectory =  [[URL path] stringByAppendingPathComponent:@"Downloads"];
    
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

- (instancetype)initFromPlist:(NSString *)pathToPlist {
    NSDictionary<NSString *, id> *dictionary = [NSDictionary dictionaryWithContentsOfFile:pathToPlist];
    
    PTTorrentDownloadStatus downloadStatus = (PTTorrentDownloadStatus)[[dictionary objectForKey:PTTorrentItemPropertyDownloadStatus] integerValue];
    // no downloading in progress yet
    if (downloadStatus == PTTorrentDownloadStatusProcessing || downloadStatus == PTTorrentDownloadStatusDownloading) {
        downloadStatus = PTTorrentDownloadStatusPaused;
    }
    
    float progress = [[dictionary objectForKey:PTTorrentItemPropertyTorrentProgress] floatValue];
    
    NSString *savePath = [pathToPlist stringByDeletingLastPathComponent];
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtPath:savePath];
    NSString *fileName;
    
    NSArray *supportedFiles = @[@"mp4", @"mkv", @"avi"];
    while (fileName = [enumerator nextObject]) {
        NSString *pathExtension = [fileName pathExtension];
        if ([supportedFiles containsObject:pathExtension]) break;
    }
    
    long long requiredSpace = [[[[NSFileManager defaultManager] attributesOfItemAtPath:[savePath stringByAppendingPathComponent:fileName] error:nil] objectForKey:NSFileSize] longLongValue];
    
    if (dictionary != nil && savePath != nil && fileName != nil) {
        @try {
            self = [self initWithMediaMetadata:dictionary downloadStatus:downloadStatus];
            _savePath = savePath;
            _fileName = fileName;
            _requiredSpace = requiredSpace;
            _totalDownloaded = requiredSpace;
            self.isFinished = downloadStatus == PTTorrentDownloadStatusFinished;
            self.torrentStatus = {0, progress, 0, 0, 0, 0};
            return self;
        } @catch (NSException *exception) {
            return nil;
        }
    }
    return nil;
}

- (instancetype)initWithMediaMetadata:(NSDictionary<NSString *, id> *)mediaMetadata downloadStatus:(PTTorrentDownloadStatus)downloadStatus {
    NSAssert([mediaMetadata objectForKey: MPMediaItemPropertyPersistentID] != nil, @"MPMediaItemPropertyPersistentID property must be set.");
    
    for (id value in [mediaMetadata allValues]) {
        NSArray *validClasses = @[[NSData class], [NSDate class], [NSNumber class], [NSString class], [NSArray class], [NSDictionary class]];
        
        BOOL isSubclass = NO;
        
        for (id validClass in validClasses) {
            if ([[value class] isSubclassOfClass:validClass]) {
                isSubclass = YES;
                break;
            }
        }
        
        NSAssert(isSubclass, @"All mediaMetadata values must be instances of NSData, NSDate, NSNumber, NSString, NSArray, or NSDictionary for a valid property list file to be created. %@ is not.", value);
    }
    
    self = [super init];
    if (self) {
        _downloadStatus = downloadStatus;
        _mediaMetadata = mediaMetadata;
        // A download keeps the whole file: never bounded storage.
        self.allowsBoundedStorage = NO;
    }
    return self;
}

- (BOOL)isEqual:(id)object {
    if ([object isKindOfClass:[PTTorrentDownload class]]) {
        return [((PTTorrentDownload *)object).mediaMetadata[MPMediaItemPropertyPersistentID] isEqualToString:self.mediaMetadata[MPMediaItemPropertyPersistentID]];
    }
    return NO;
}

- (NSUInteger)hash {
    return [_mediaMetadata[MPMediaItemPropertyPersistentID] hash];
}


- (void)startDownloadingFromFileOrMagnetLink:(NSString *)filePathOrMagnetLink selectFileTDownload:(PTTorrentStreamerSelection)callback {
    [self startDownloadingFromFileOrMagnetLink:filePathOrMagnetLink directoryName:nil selectFileTDownload:callback];
}

/// `directoryName`: the folder of the download directory to download into (nil: named after
/// the torrent, as for every new download).
- (void)startDownloadingFromFileOrMagnetLink:(NSString *)filePathOrMagnetLink
                               directoryName:(nullable NSString *)directoryName
                         selectFileTDownload:(PTTorrentStreamerSelection)callback {
    __weak __typeof__(self) weakSelf = self;
    
    NSMutableDictionary *copy = _mediaMetadata.mutableCopy;
    copy[MPMediaItemPropertyPathOrLink] = filePathOrMagnetLink;
    _mediaMetadata = copy;
    
    self.selectionBlock = ^int(NSArray<NSString *> * _Nonnull torrentsAvailable, NSArray<NSNumber *> * _Nonnull fileSizes) {
        int index = callback(torrentsAvailable, fileSizes);
        
        NSMutableDictionary *copy = weakSelf.mediaMetadata.mutableCopy;
        copy[MPMediaItemPropertySelectedFileIndex] = @(index);
        weakSelf.mediaMetadata = copy;

        [weakSelf save];
        
        return index;
    };
    [self startStreamingFromFileOrMagnetLink:filePathOrMagnetLink
                               directoryName:directoryName
                                    progress:^(PTTorrentStatus status) {
        if (weakSelf.downloadStatus == PTTorrentDownloadStatusPaused) return;
        PTTorrentDownloadStatus downloadStatus = status.totalProgress < 1 ? PTTorrentDownloadStatusDownloading : PTTorrentDownloadStatusFinished;
        
        [weakSelf setDownloadStatus:downloadStatus];
        [weakSelf setTorrentStatus:status];
        
        if (downloadStatus == PTTorrentDownloadStatusFinished) {
            [weakSelf cancelStreamingAndDeleteData:NO];
        }
    } readyToPlay: {
        
    } failure:^(NSError * _Nonnull error) {
        id<PTTorrentDownloadManagerListener> delegate = weakSelf.delegate;
        
        [weakSelf setDownloadStatus:PTTorrentDownloadStatusFailed];
        
        if (delegate && [delegate respondsToSelector:@selector(downloadDidFail:withError:)]) {
            [delegate downloadDidFail:weakSelf withError:error];
        }
    }];
}

/// The file a download loaded from its plist was downloading, among the torrent's
/// (`names`: file names, `sizes`): its stored index, else the file named like the one in its
/// folder (`fileName`, a path relative to it), else the largest file.
+ (int)indexOfDownloadedFile:(nullable NSString *)fileName storedIndex:(nullable NSNumber *)storedIndex
                       names:(NSArray<NSString *> *)names sizes:(NSArray<NSNumber *> *)sizes {
    if (storedIndex != nil && storedIndex.intValue >= 0 && storedIndex.intValue < (int)names.count) return storedIndex.intValue;
    NSString *wanted = fileName.lastPathComponent;
    if (wanted.length > 0) {
        for (NSUInteger i = 0; i < names.count; ++i) {
            if ([names[i].lastPathComponent isEqualToString:wanted]) return (int)i;
        }
    }
    int largest = 0;
    for (NSUInteger i = 1; i < sizes.count; ++i) {
        if (sizes[i].longLongValue > sizes[(NSUInteger)largest].longLongValue) largest = (int)i;
    }
    return largest;
}


- (void)setTorrentStatus:(PTTorrentStatus)torrentStatus {
    _torrentStatus = torrentStatus;
    
    if (_delegate && [_delegate respondsToSelector:@selector(torrentStatusDidChange:forDownload:)]) {
        [_delegate torrentStatusDidChange:torrentStatus forDownload:self];
    }
}

- (void)setDownloadStatus:(PTTorrentDownloadStatus)downloadStatus {
    if (downloadStatus == _downloadStatus) return;
    
    _downloadStatus = downloadStatus;
    
    if (_delegate && [_delegate respondsToSelector:@selector(downloadStatusDidChange:forDownload:)]) {
        [_delegate downloadStatusDidChange:downloadStatus forDownload:self];
    }
}

- (void)stop {
    [super cancelStreamingAndDeleteData:YES];
    [self setDownloadStatus:PTTorrentDownloadStatusFailed];
}

- (void)pause {
    if (_downloadStatus != PTTorrentDownloadStatusDownloading) return;
    
    // A stream reading this download's file keeps the torrent running: it is paused when the
    // last such stream stops (sharedTorrentDidLoseGuests).
    if (![self.session hasGuests:self]) [self pauseTorrent];
    [self setDownloadStatus:PTTorrentDownloadStatusPaused];
}

- (void)pauseTorrent {
    if (!self.torrentHandle.is_valid()) return;
    // Never auto-managed (libtorrent's auto-manager would resume the paused download).
    self.torrentHandle.unset_flags(torrent_flags::auto_managed);
    self.torrentHandle.pause(torrent_handle::graceful_pause);
}

- (void)resume {
    if (_downloadStatus != PTTorrentDownloadStatusPaused) return;
    
    if (self.torrentHandle.is_valid()) {
        self.torrentHandle.resume();
    } else {
        /// Torrent was in the middle of downloading and app was exited. Download has been loaded from disk and is now being resumed. Fetch torrent metadata instead of just resuming.
        // Into the folder its file is in, on that file: a download of the CocoaPods
        // PopcornTorrent sits in <PersistentID>/ (not in the folder named after the torrent that
        // this fork gives new downloads) and its plist has no file index. Started elsewhere, it
        // would download again from zero next to its partial file, maybe another file of the
        // torrent, and be listed twice (verify-regressions 3).
        NSString *directory = _savePath.lastPathComponent.length > 0 ? _savePath.lastPathComponent : nil;
        NSNumber *storedIndex = _mediaMetadata[MPMediaItemPropertySelectedFileIndex];
        NSString *fileName = _fileName;
        [self startDownloadingFromFileOrMagnetLink:_mediaMetadata[MPMediaItemPropertyPathOrLink] directoryName:directory selectFileTDownload:^int(NSArray<NSString *> * _Nonnull torrentsAvailable, NSArray<NSNumber *> * _Nonnull fileSizes) {
            return [PTTorrentDownload indexOfDownloadedFile:fileName storedIndex:storedIndex names:torrentsAvailable sizes:fileSizes];
        }];
        return [self setDownloadStatus:PTTorrentDownloadStatusProcessing];
    }

    [self setDownloadStatus:PTTorrentDownloadStatusDownloading];
}

#pragma mark - Shared torrent (a stream of the same torrent reads this download's file)

- (BOOL)canJoinSharedTorrent {
    return NO; // a download keeps its own copy of the file
}

- (BOOL)handsTorrentOverToGuests {
    return NO; // finished or stopped, the download removes its torrent; its file stays its own
}

- (void)sharedTorrentWillGainGuests {
    // A paused download runs while a stream reads it.
    if (_downloadStatus == PTTorrentDownloadStatusPaused && self.torrentHandle.is_valid()) self.torrentHandle.resume();
}

- (void)sharedTorrentDidLoseGuests {
    if (_downloadStatus == PTTorrentDownloadStatusPaused) [self pauseTorrent];
}

- (BOOL)delete {
    NSAssert(_downloadStatus != PTTorrentDownloadStatusPaused && _downloadStatus != PTTorrentDownloadStatusDownloading, @"This method should not be used to stop downloads, only to delete a pre-existing download.");
    return [[NSFileManager defaultManager] removeItemAtPath:_savePath error:nil];
}

- (BOOL)save {
    NSString *index = _mediaMetadata[MPMediaItemPropertySelectedFileIndex] ? [_mediaMetadata[MPMediaItemPropertySelectedFileIndex] stringValue] : @"";
    NSString *fileName = [NSString stringWithFormat:@"Metadata-file-%@.plist", index];
    NSString *filePath = [_savePath stringByAppendingPathComponent:fileName];
    NSMutableDictionary *copy = _mediaMetadata.mutableCopy;
    [copy setObject:@(_downloadStatus) forKey:PTTorrentItemPropertyDownloadStatus];
    [copy setObject:@(_torrentStatus.totalProgress) forKey:PTTorrentItemPropertyTorrentProgress];
    BOOL const saved = [copy writeToFile:filePath atomically:YES];
    // A CocoaPods PopcornTorrent download resumed here (see resume): its own plist goes once
    // this one is written, or the download manager would load it as a second download of
    // the same media at the next launch. This fork never writes that name.
    NSString *legacyPlist = [_savePath stringByAppendingPathComponent:@"Metadata.plist"];
    if (saved && ![legacyPlist isEqualToString:filePath] && [[NSFileManager defaultManager] fileExistsAtPath:legacyPlist]) {
        [[NSFileManager defaultManager] removeItemAtPath:legacyPlist error:nil];
    }
    return saved;
}

- (void)playWithHandler:(PTTorrentStreamerReadyToPlay)handler {
    if (_downloadStatus == PTTorrentDownloadStatusDownloading) {
        self.readyToPlayBlock = handler;
        // start player
        if (self.torrentStatus.totalProgress > 0.03) {
            self.streaming = YES;
            [self startWebServerAndPlay];
        }
    } else if (_downloadStatus == PTTorrentDownloadStatusFinished) {
        NSURL *fileURL = [NSURL fileURLWithPath:[self.savePath stringByAppendingPathComponent:_fileName]];
        handler(fileURL, fileURL);
    }
}

- (BOOL)publishesStatusBeforeMetadata {
    // The progress block turns a download "Downloading" (totalProgress < 1): it starts with the
    // metadata, as before (the download stays "Processing" while a magnet resolves).
    return NO;
}

- (void)cancelStreamingAndDeleteData:(BOOL)deleteData {
    if (self.isStreaming && _downloadStatus == PTTorrentDownloadStatusDownloading) {
        self.readyToPlayBlock = nil;
        self.streaming = FALSE;
        if (self.mediaServer.isRunning) [self.mediaServer stop];
        [self.mediaServer removeAllHandlers];
        self.mediaServer = [[GCDWebServer alloc] init];
    } else {
        [super cancelStreamingAndDeleteData:deleteData];
    }
}

// - (void)prioritizeNextPieces:(torrent_handle)th {
//     if (self.isStreaming) {
//         [super prioritizeNextPieces:th];
//     } else {
//         auto piece_priorities = th.get_piece_priorities();
//         std::fill(piece_priorities.begin(), piece_priorities.end(), low_priority);
//     }
// }

@end
