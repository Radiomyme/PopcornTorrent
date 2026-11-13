

#import "PTTorrentDownload.h"
#import "PTSize.h"
#import "PTTorrentStreamer+Protected.h"
#import "PTTorrentsSession+Protected.h"
#import "PTTorrentDownloadManagerListener.h"
#import "../Security/CocoaSecurity.h"
#import <MediaPlayer/MPMediaItem.h>
#if TARGET_OS_IOS || TARGET_OS_TV
#import <UIKit/UIApplication.h>
#endif

NSString * const PTTorrentItemPropertyDownloadStatus = @"downloadStatus";
NSString * const MPMediaItemPropertyPathOrLink = @"filePathOrLink";
NSString * const PTTorrentItemPropertyTorrentProgress = @"progress";
NSString * const MPMediaItemPropertySelectedFileIndex = @"selectedFileIndex";
/// The chosen file's path in the download's folder (its path inside the torrent), saved with the
/// index: a download reloaded from its plist plays that file, not the first video file of its
/// folder (another episode, in a folder two episodes of one season pack share).
static NSString * const PTTorrentItemPropertySelectedFilePath = @"selectedFilePath";

using namespace libtorrent;

@implementation PTTorrentDownload {
    PTTorrentDownloadStatus _downloadStatus;
    NSString *_loadedPlistName; // the plist this download was loaded from (initFromPlist:)
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
    NSString *fileName;
    // The file it chose, when saved (since 5.2.0); else the first video file of its folder.
    id const stored = [dictionary objectForKey:PTTorrentItemPropertySelectedFilePath];
    if ([stored isKindOfClass:[NSString class]] && [(NSString *)stored length] > 0
        && [[NSFileManager defaultManager] fileExistsAtPath:[savePath stringByAppendingPathComponent:stored]]) {
        fileName = stored;
    }
    NSDirectoryEnumerator *enumerator = fileName ? nil : [[NSFileManager defaultManager] enumeratorAtPath:savePath];
    
    NSArray *supportedFiles = @[@"mp4", @"mkv", @"avi"];
    while (enumerator && (fileName = [enumerator nextObject])) {
        NSString *pathExtension = [fileName pathExtension];
        if ([supportedFiles containsObject:pathExtension]) break;
    }
    
    long long requiredSpace = [[[[NSFileManager defaultManager] attributesOfItemAtPath:[savePath stringByAppendingPathComponent:fileName] error:nil] objectForKey:NSFileSize] longLongValue];
    
    if (dictionary != nil && savePath != nil && fileName != nil) {
        @try {
            self = [self initWithMediaMetadata:dictionary downloadStatus:downloadStatus];
            _savePath = savePath;
            _fileName = fileName;
            _loadedPlistName = pathToPlist.lastPathComponent;
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
        BOOL const chosen = index >= 0 && index < (int)torrentsAvailable.count;
        
        NSMutableDictionary *copy = weakSelf.mediaMetadata.mutableCopy;
        copy[MPMediaItemPropertySelectedFileIndex] = @(index);
        if (chosen) copy[PTTorrentItemPropertySelectedFilePath] = torrentsAvailable[(NSUInteger)index];
        weakSelf.mediaMetadata = copy;

        // Saved once a file is chosen. A selection that chose none (a season pack without the
        // episode) fails: no plist, nothing listed again at the next launch.
        if (chosen) [weakSelf save];
        
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

/// The folder of a new download: the torrent's (`name`), then its media's own suffix. Two
/// episodes downloaded from one season pack get a folder each: in a shared one, a reloaded
/// download played the first video file of the folder (the other episode), and deleting or
/// stopping one deleted the other (libtorrent's delete_files removes every file of the torrent).
- (NSString *)folderNameForTorrentNamed:(NSString *)name {
    id const media = _mediaMetadata[MPMediaItemPropertyPersistentID];
    NSString *key = [media isKindOfClass:[NSString class]] ? media : [media description];
    if (key.length == 0) return name;
    return [NSString stringWithFormat:@"%@-%@", name, [[CocoaSecurity md5:key].hexLower substringToIndex:8]];
}

/// This download's plist names: the one `save` writes, and the one it was loaded from.
- (NSSet<NSString *> *)ownPlistNames {
    NSMutableSet<NSString *> *names = [NSMutableSet setWithObject:[self plistName]];
    if (_loadedPlistName.length > 0) [names addObject:_loadedPlistName];
    return names;
}

/// The plists of other downloads in this download's folder: a folder two episodes of one season
/// pack share (downloads made before each got its own folder). Its other files are theirs.
- (NSArray<NSString *> *)otherDownloadPlists {
    if (_savePath.length == 0) return @[];
    NSSet<NSString *> *own = [self ownPlistNames];
    NSMutableArray<NSString *> *others = [NSMutableArray array];
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:_savePath error:nil]) {
        if ([name hasPrefix:@"Metadata"] && [name.pathExtension isEqualToString:@"plist"] && ![own containsObject:name]) {
            [others addObject:name];
        }
    }
    return others;
}

/// Removes this download's own file and plists only (a folder another download shares).
- (BOOL)removeOwnFilesFromFolder:(NSString *)folder fileName:(nullable NSString *)fileName plists:(NSSet<NSString *> *)plists {
    BOOL removed = YES;
    if (folder.length == 0) return NO;
    if (fileName.length > 0) {
        NSString *file = [folder stringByAppendingPathComponent:fileName];
        if ([[NSFileManager defaultManager] fileExistsAtPath:file]) removed = [[NSFileManager defaultManager] removeItemAtPath:file error:nil];
    }
    for (NSString *name in plists) [[NSFileManager defaultManager] removeItemAtPath:[folder stringByAppendingPathComponent:name] error:nil];
    return removed;
}

/// The file a download loaded from its plist was downloading, among the torrent's
/// (`names`: file names, `sizes`): its stored index, else the file named like the one in its
/// folder (`fileName`, a path relative to it), else the largest file. A download whose
/// selection chose no file (`PTTorrentStreamerNoFileIndex` stored: the episode is not in the
/// pack) chooses none again: resumed, it fails the same way instead of downloading another file.
+ (int)indexOfDownloadedFile:(nullable NSString *)fileName storedIndex:(nullable NSNumber *)storedIndex
                       names:(NSArray<NSString *> *)names sizes:(NSArray<NSNumber *> *)sizes {
    if (storedIndex != nil && storedIndex.intValue == PTTorrentStreamerNoFileIndex) return PTTorrentStreamerNoFileIndex;
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
    if ([self otherDownloadPlists].count > 0) {
        // Its folder holds another download's episode: libtorrent's delete_files would delete it
        // too (every file of the torrent). Only this download's file and plist go.
        NSString *folder = _savePath, *fileName = _fileName;
        NSSet<NSString *> *plists = [self ownPlistNames];
        [super cancelStreamingAndDeleteData:NO];
        [self removeOwnFilesFromFolder:folder fileName:fileName plists:plists];
        // Writes still queued on libtorrent's disk thread may create the file again: once more
        // when they are done.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (fileName.length > 0) [[NSFileManager defaultManager] removeItemAtPath:[folder stringByAppendingPathComponent:fileName] error:nil];
        });
    } else {
        [super cancelStreamingAndDeleteData:YES];
    }
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
    [self updateSequentialDownload];
}

- (void)sharedTorrentDidLoseGuests {
    if (_downloadStatus == PTTorrentDownloadStatusPaused) [self pauseTorrent];
    [self updateSequentialDownload];
}

#pragma mark - Piece order

- (BOOL)wantsSequentialDownload {
    // Nobody plays it: the rarest pieces first, like any BitTorrent client (no wait at the end
    // on pieces only a few peers have, and a healthier swarm). Played here (playWithHandler:)
    // or by a stream that joined it: in file order, the stream's window first.
    return self.isStreaming || [self.session hasGuests:self];
}

- (void)updateSequentialDownload {
    if (!self.torrentHandle.is_valid()) return;
    if ([self wantsSequentialDownload]) self.torrentHandle.set_flags(torrent_flags::sequential_download);
    else self.torrentHandle.unset_flags(torrent_flags::sequential_download);
}

- (BOOL)delete {
    NSAssert(_downloadStatus != PTTorrentDownloadStatusPaused && _downloadStatus != PTTorrentDownloadStatusDownloading, @"This method should not be used to stop downloads, only to delete a pre-existing download.");
    if ([self otherDownloadPlists].count > 0) {
        // Another download's episode is in this folder: only this download's file and plist go.
        return [self removeOwnFilesFromFolder:_savePath fileName:_fileName plists:[self ownPlistNames]];
    }
    return [[NSFileManager defaultManager] removeItemAtPath:_savePath error:nil];
}

/// The name of the plist `save` writes: Metadata-file-<file index>.plist.
- (NSString *)plistName {
    NSString *index = _mediaMetadata[MPMediaItemPropertySelectedFileIndex] ? [_mediaMetadata[MPMediaItemPropertySelectedFileIndex] stringValue] : @"";
    return [NSString stringWithFormat:@"Metadata-file-%@.plist", index];
}

- (BOOL)save {
    NSString *fileName = [self plistName];
    NSString *filePath = [_savePath stringByAppendingPathComponent:fileName];
    NSMutableDictionary *copy = _mediaMetadata.mutableCopy;
    // The file it streams, once known (also saved by the selection, before the metadata path).
    if (_fileName.length > 0) [copy setObject:_fileName forKey:PTTorrentItemPropertySelectedFilePath];
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
            [self updateSequentialDownload];
            [self startWebServerAndPlay];
        }
    } else if (_downloadStatus == PTTorrentDownloadStatusFinished) {
        NSURL *fileURL = [NSURL fileURLWithPath:[self.savePath stringByAppendingPathComponent:_fileName]];
        handler(fileURL, fileURL);
    }
}

/// A download whose selection chose no file (a season pack without the episode): it fails as
/// any stream does, saves no plist (startDownloadingFromFileOrMagnetLink:), and its folder
/// goes with the first pieces of other files fetched before the priorities applied. Unless
/// another download keeps its episode in that folder (a folder shared before downloads got
/// their own): then only the torrent goes, without deleting any file (libtorrent's
/// delete_files would delete that episode too).
- (void)handleTorrentError:(NSError *)error {
    if (![error.domain isEqualToString:PTTorrentStreamerErrorDomain] || error.code != PTTorrentStreamerErrorNoFileSelected) {
        return [super handleTorrentError:error];
    }
    __weak __typeof__(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.failureBlock) strongSelf.failureBlock(error);
        // Removed with its files (libtorrent deletes them once the writes in flight are done)
        // and its folder, when no other download keeps an episode there.
        BOOL const shared = [strongSelf otherDownloadPlists].count > 0;
        [strongSelf cancelStreamingAndDeleteData:!shared];
    });
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
        [self updateSequentialDownload];
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
