//
//  PTOfflineStreamingTests.mm
//  PopcornTorrent-Tests
//
//  The streamer end to end, offline, in a few seconds: a generated multi-file payload
//  (a "season pack"), its torrent, a libtorrent seeder on 127.0.0.1 and the streamer's
//  shared session made loopback-only (+prepareSharedSessionForLoopbackTestingOnPort:, no
//  tracker, DHT, LSD, UPnP or NAT-PMP). The torrents have no trackers: the test hands the
//  seeder's address to the streamer's torrent (connect_peer), as a tracker would.
//
//  Covers what the internet tests (PopcornTorrentInternetTests) check against public
//  swarms: a .torrent file and a magnet link, a file chosen in a multi-file torrent,
//  resuming from the data kept on disk; and more: the bytes served over HTTP equal the
//  source, file names reach the selection block in UTF-8, a selection of no file fails
//  with PTTorrentStreamerErrorNoFileSelected before anything is downloaded, and a cancel
//  with deleteData deletes the data.
//

#import <XCTest/XCTest.h>
#import <Foundation/Foundation.h>
#import "PTTorrentStreamer.h"
#import "PTTorrentStreamer+Protected.h"
#import "PTTorrentsSession.h"
#import "PTTorrentsSession+Testing.h"
#include <libtorrent/session.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/bencode.hpp>
#include <libtorrent/address.hpp>
#include <libtorrent/hex.hpp>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

namespace lt = libtorrent;

namespace {

int64_t const kKiB = 1024;
int64_t const kMiB = 1024 * 1024;

/// One file of the generated pack.
struct PackFile {
    NSString *name;
    int64_t size;
};

/// The pack: three episodes (odd sizes: pieces straddle files), one with a non-ASCII name.
std::vector<PackFile> packFiles() {
    return {
        {@"Offline.Show.S01E01.1080p.mkv", 3 * kMiB + 123},
        {@"Offline.Show.S01E02.1080p.mkv", 2 * kMiB + 4567},
        {@"Offline Show S01E03 Épisode spécial.mkv", 1 * kMiB + 89},
    };
}

/// Deterministic bytes, different for every file.
void fillPattern(std::vector<char>& buffer, uint64_t seed) {
    uint64_t state = seed * 0x9E3779B97F4A7C15ULL + 1;
    for (char& c : buffer) {
        state = state * 6364136223846793005ULL + 1442695040888963407ULL;
        c = char(state >> 56);
    }
}

/// Names compared in one Unicode form: a torrent made from files on an APFS disk holds
/// decomposed names (E + U+0301), one made elsewhere usually precomposed ones.
NSString *nfc(NSString *name) { return name.precomposedStringWithCanonicalMapping; }

/// The index of `name` among the torrent's names (any normalization), else out of range.
int indexOfName(NSArray<NSString *> *names, NSString *name) {
    for (NSUInteger i = 0; i < names.count; i++) {
        if ([nfc(names[i]) isEqualToString:nfc(name)]) return (int)i;
    }
    return (int)names.count;
}

void spin(double seconds, BOOL (^until)(void)) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([end timeIntervalSinceNow] > 0) {
        if (until && until()) return;
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
}

/// The regular files under `folder` (none when it is gone).
NSArray<NSString *> *filesUnder(NSString *folder) {
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    for (NSString *sub in [[NSFileManager defaultManager] enumeratorAtPath:folder]) {
        BOOL directory = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:[folder stringByAppendingPathComponent:sub] isDirectory:&directory] && !directory)
            [files addObject:sub];
    }
    return files;
}

lt::tcp::endpoint loopback(int port) {
    return lt::tcp::endpoint(lt::make_address("127.0.0.1"), (unsigned short)port);
}

/// What a stream reported.
struct StreamResult {
    __strong NSURL *serverURL = nil;
    __strong NSURL *fileURL = nil;
    __strong NSError *error = nil;
    __strong NSArray<NSString *> *names = nil;
    __strong NSArray<NSNumber *> *sizes = nil;
    BOOL ready = NO;
};

} // namespace

/// A localhost-only seeder (its own libtorrent session).
@interface PTOfflineSeeder : NSObject
@property (nonatomic, readonly) int port;
- (void)seedTorrent:(NSString *)torrentPath savePath:(NSString *)savePath;
- (int64_t)uploadedBytes;
@end

@implementation PTOfflineSeeder {
    std::unique_ptr<lt::session> _session;
    std::vector<lt::torrent_handle> _handles;
}

- (instancetype)init {
    if ((self = [super init])) {
        lt::settings_pack pack;
        pack.set_str(lt::settings_pack::listen_interfaces, "127.0.0.1:0");
        pack.set_bool(lt::settings_pack::enable_dht, false);
        pack.set_bool(lt::settings_pack::enable_lsd, false);
        pack.set_bool(lt::settings_pack::enable_upnp, false);
        pack.set_bool(lt::settings_pack::enable_natpmp, false);
        pack.set_str(lt::settings_pack::dht_bootstrap_nodes, "");
        pack.set_bool(lt::settings_pack::allow_multiple_connections_per_ip, true);
        pack.set_int(lt::settings_pack::alert_mask, 0);
        pack.set_int(lt::settings_pack::min_reconnect_time, 1);
        _session.reset(new lt::session(lt::session_params(std::move(pack))));
        for (int i = 0; i < 250 && _session->listen_port() == 0; i++) usleep(20000);
        _port = _session->listen_port();
    }
    return self;
}

- (void)seedTorrent:(NSString *)torrentPath savePath:(NSString *)savePath {
    lt::add_torrent_params params;
    params.ti = std::make_shared<lt::torrent_info>(std::string(torrentPath.fileSystemRepresentation));
    params.save_path = savePath.fileSystemRepresentation;
    params.flags |= lt::torrent_flags::seed_mode;
    params.flags &= ~lt::torrent_flags::auto_managed;
    params.flags &= ~lt::torrent_flags::paused;
    _handles.push_back(_session->add_torrent(params));
}

- (int64_t)uploadedBytes {
    int64_t total = 0;
    for (auto const& handle : _handles) total += handle.status().total_payload_upload;
    return total;
}

- (void)dealloc {
    _handles.clear();
    _session.reset();
}

@end

@interface PTOfflineStreamingTests : XCTestCase
@end

static NSString *gWork = nil;           // everything the tests write
static NSString *gPackDir = nil;        // the seeder's copy of the pack
static NSString *gPrivateTorrent = nil; // private (no metadata exchange), for .torrent streams
static NSString *gPublicMagnet = nil;   // the same files in a public torrent, for the magnet test
static PTOfflineSeeder *gSeeder = nil;

@implementation PTOfflineStreamingTests

#pragma mark - Fixture

+ (NSString *)makeTorrentOf:(NSString *)packDir private:(BOOL)isPrivate name:(NSString *)name {
    lt::file_storage storage;
    lt::add_files(storage, packDir.fileSystemRepresentation);
    lt::create_torrent creator(storage, int(64 * kKiB));
    creator.set_priv(isPrivate);
    if (!isPrivate) creator.set_comment("public: metadata exchange for the magnet test");
    lt::set_piece_hashes(creator, packDir.stringByDeletingLastPathComponent.fileSystemRepresentation);
    std::vector<char> bytes;
    lt::bencode(std::back_inserter(bytes), creator.generate());
    NSString *path = [gWork stringByAppendingPathComponent:name];
    std::ofstream out(path.fileSystemRepresentation, std::ios::binary);
    out.write(bytes.data(), (std::streamsize)bytes.size());
    return path;
}

+ (void)setUp {
    [super setUp];
    // Before the first +sharedSession: the streamer's session listens on 127.0.0.1 only.
    [PTTorrentsSession prepareSharedSessionForLoopbackTestingOnPort:0];

    gWork = [NSTemporaryDirectory() stringByAppendingPathComponent:
             [NSString stringWithFormat:@"PopcornTorrentTests-%d", getpid()]];
    [[NSFileManager defaultManager] removeItemAtPath:gWork error:nil];
    gPackDir = [gWork stringByAppendingPathComponent:@"seed/Offline.Show.S01.COMPLETE"];
    [[NSFileManager defaultManager] createDirectoryAtPath:gPackDir withIntermediateDirectories:YES attributes:nil error:nil];
    uint64_t seed = 1;
    for (PackFile const& file : packFiles()) {
        std::vector<char> bytes((size_t)file.size);
        fillPattern(bytes, seed++);
        NSString *path = [gPackDir stringByAppendingPathComponent:file.name];
        std::ofstream out(path.fileSystemRepresentation, std::ios::binary);
        out.write(bytes.data(), (std::streamsize)bytes.size());
    }
    gPrivateTorrent = [self makeTorrentOf:gPackDir private:YES name:@"pack-private.torrent"];
    NSString *publicTorrent = [self makeTorrentOf:gPackDir private:NO name:@"pack-public.torrent"];
    lt::torrent_info publicInfo(std::string(publicTorrent.fileSystemRepresentation));
    std::string const hex = lt::aux::to_hex(publicInfo.info_hash());
    // No tracker: the peer is handed over by the test (connect_peer).
    gPublicMagnet = [NSString stringWithFormat:@"magnet:?xt=urn:btih:%s&dn=Offline.Show.S01.COMPLETE", hex.c_str()];

    gSeeder = [[PTOfflineSeeder alloc] init];
    NSString *seedRoot = gPackDir.stringByDeletingLastPathComponent;
    [gSeeder seedTorrent:gPrivateTorrent savePath:seedRoot];
    [gSeeder seedTorrent:publicTorrent savePath:seedRoot];
}

+ (void)tearDown {
    gSeeder = nil;
    [[NSFileManager defaultManager] removeItemAtPath:gWork error:nil];
    [super tearDown];
}

- (void)setUp {
    [super setUp];
    self.continueAfterFailure = NO;
    XCTAssertGreaterThan(gSeeder.port, 0, @"the seeder listens on 127.0.0.1");
}

#pragma mark - Helpers

- (NSString *)streamDirectory {
    NSString *name = [self.name stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"-[]"]];
    name = [name stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    return [gWork stringByAppendingPathComponent:[@"streams/" stringByAppendingString:name]];
}

/// Starts a stream; `choose` picks the file from the names the streamer hands over.
- (PTTorrentStreamer *)stream:(NSString *)torrentOrMagnet
                    directory:(NSString *)directory
                       result:(std::shared_ptr<StreamResult>)result
                       choose:(int (^)(NSArray<NSString *> *names))choose {
    PTTorrentStreamer *streamer = [[PTTorrentStreamer alloc] init];
    streamer.downloadDirectoryOverride = directory;
    [streamer startStreamingFromMultiTorrentFileOrMagnetLink:torrentOrMagnet
        progress:^(PTTorrentStatus status) {}
        readyToPlay:^(NSURL *serverURL, NSURL *fileURL) {
            result->serverURL = serverURL;
            result->fileURL = fileURL;
            result->ready = YES;
        }
        failure:^(NSError *error) { result->error = error; }
        selectFileToStream:^int(NSArray<NSString *> *names, NSArray<NSNumber *> *sizes) {
            result->names = names;
            result->sizes = sizes;
            return choose(names);
        }];
    return streamer;
}

/// Spins until the stream is ready or failed, telling its torrent about the seeder.
- (void)waitFor:(PTTorrentStreamer *)streamer result:(std::shared_ptr<StreamResult>)result seconds:(double)seconds {
    int const port = gSeeder.port;
    spin(seconds, ^BOOL {
        lt::torrent_handle handle = streamer.torrentHandle;
        if (handle.is_valid() && handle.status().num_peers == 0) handle.connect_peer(loopback(port));
        return result->ready || result->error != nil;
    });
}

- (NSData *)sourceBytesOf:(NSString *)name offset:(int64_t)offset length:(int64_t)length {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:[gPackDir stringByAppendingPathComponent:name]];
    [handle seekToFileOffset:(unsigned long long)offset];
    NSData *data = [handle readDataOfLength:(NSUInteger)length];
    [handle closeFile];
    return data;
}

/// GET with a Range header through the streamer's HTTP server (run loop spun).
- (NSData *)get:(NSURL *)serverURL offset:(int64_t)offset length:(int64_t)length status:(NSInteger *)status {
    NSString *url = [NSString stringWithFormat:@"http://127.0.0.1:%@/video", serverURL.port];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [request setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", offset, offset + length - 1] forHTTPHeaderField:@"Range"];
    request.timeoutInterval = 10;
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.connectionProxyDictionary = @{};
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    __block NSData *body = nil;
    __block NSInteger code = 0;
    __block BOOL done = NO;
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        code = error ? -1 : ((NSHTTPURLResponse *)response).statusCode;
        body = data;
        done = YES;
    }] resume];
    spin(15, ^BOOL { return done; });
    [session invalidateAndCancel];
    if (status) *status = code;
    return body;
}

/// The head, a range across two pieces in the middle and the tail, compared with the source.
- (void)checkServedBytesOf:(NSString *)name size:(int64_t)size server:(NSURL *)serverURL {
    int64_t const middle = size / 2 - 1000;
    int64_t const ranges[3][2] = {{0, 64 * kKiB}, {middle, 70 * kKiB}, {size - 5000, 5000}};
    for (auto const& range : ranges) {
        NSInteger status = 0;
        NSData *served = [self get:serverURL offset:range[0] length:range[1] status:&status];
        XCTAssertEqual(status, 206, @"%@ [%lld, +%lld): HTTP %ld", name, range[0], range[1], (long)status);
        XCTAssertEqualObjects(served, [self sourceBytesOf:name offset:range[0] length:range[1]],
                              @"%@ [%lld, +%lld): the bytes served are the source's", name, range[0], range[1]);
    }
}

- (void)cancel:(PTTorrentStreamer *)streamer deleteData:(BOOL)deleteData {
    [streamer cancelStreamingAndDeleteData:deleteData];
    spin(0.3, nil); // the deletion runs on the session's queue
}

#pragma mark - Tests

/// A .torrent file of a season pack: the episode chosen is the one streamed, with its bytes.
- (void)testTorrentFileStreamsTheChosenFileOfAPack {
    auto result = std::make_shared<StreamResult>();
    NSString *directory = [self streamDirectory];
    NSString *wanted = packFiles()[1].name;
    PTTorrentStreamer *streamer = [self stream:gPrivateTorrent directory:directory result:result
                                        choose:^int(NSArray<NSString *> *names) { return indexOfName(names, wanted); }];
    [self waitFor:streamer result:result seconds:20];
    XCTAssertNil(result->error, @"failure: %@", result->error);
    XCTAssertTrue(result->ready, @"ready to play within 20 s");

    XCTAssertEqual(result->names.count, packFiles().size(), @"every file of the pack: %@", result->names);
    for (PackFile const& file : packFiles()) {
        int const index = indexOfName(result->names, file.name);
        XCTAssertLessThan(index, (int)result->names.count, @"%@ among %@ (UTF-8 names)", file.name, result->names);
        XCTAssertEqual(result->sizes[index].longLongValue, file.size, @"%@: its size", file.name);
    }
    XCTAssertEqualObjects(nfc(result->fileURL.lastPathComponent), nfc(wanted), @"the chosen file is streamed");
    // The file's path in the torrent: the pack's folder, then the episode.
    XCTAssertEqualObjects(nfc(streamer.fileName), nfc([@"Offline.Show.S01.COMPLETE/" stringByAppendingString:wanted]));
    [self checkServedBytesOf:wanted size:packFiles()[1].size server:result->serverURL];

    NSString *folder = streamer.savePath;
    XCTAssertGreaterThan(filesUnder(folder).count, 0u);
    [self cancel:streamer deleteData:YES];
    spin(5, ^BOOL { return filesUnder(folder).count == 0; });
    // Nothing of the torrent is left. (The folder itself can stay behind, empty: the
    // streamer removes it while libtorrent may still be writing into it.)
    XCTAssertEqual(filesUnder(folder).count, 0u, @"cancel with deleteData deletes the data; left: %@", filesUnder(folder));
}

/// A magnet link without trackers: the metadata comes from the peer, then the chosen file.
- (void)testMagnetLinkGetsTheMetadataFromThePeer {
    auto result = std::make_shared<StreamResult>();
    NSString *wanted = packFiles()[2].name; // the non-ASCII name
    PTTorrentStreamer *streamer = [self stream:gPublicMagnet directory:[self streamDirectory] result:result
                                        choose:^int(NSArray<NSString *> *names) { return indexOfName(names, wanted); }];
    [self waitFor:streamer result:result seconds:20];
    XCTAssertNil(result->error, @"failure: %@", result->error);
    XCTAssertTrue(result->ready, @"ready to play within 20 s");
    XCTAssertTrue(streamer.hasMetadata);
    XCTAssertEqual(result->names.count, packFiles().size());
    XCTAssertEqualObjects(nfc(result->fileURL.lastPathComponent), nfc(wanted));
    [self checkServedBytesOf:wanted size:packFiles()[2].size server:result->serverURL];
    [self cancel:streamer deleteData:YES];
}

/// Stopped without deleting, the same episode streamed again starts from the data on disk.
- (void)testAStreamStartedAgainResumesFromTheDataKept {
    NSString *directory = [self streamDirectory];
    NSString *wanted = packFiles()[0].name;
    int (^choose)(NSArray<NSString *> *) = ^int(NSArray<NSString *> *names) { return indexOfName(names, wanted); };

    auto first = std::make_shared<StreamResult>();
    PTTorrentStreamer *streamer = [self stream:gPrivateTorrent directory:directory result:first choose:choose];
    [self waitFor:streamer result:first seconds:20];
    XCTAssertTrue(first->ready, @"first stream ready: %@", first->error);
    // The whole episode on disk before stopping (a few MiB over loopback).
    spin(10, ^BOOL { return streamer.isFileComplete; });
    XCTAssertTrue(streamer.isFileComplete, @"the episode downloaded in full");
    [self cancel:streamer deleteData:NO];
    int64_t const uploadedBefore = [gSeeder uploadedBytes];

    auto second = std::make_shared<StreamResult>();
    PTTorrentStreamer *again = [self stream:gPrivateTorrent directory:directory result:second choose:choose];
    // No connect_peer this time: the data on disk must be enough.
    spin(20, ^BOOL { return second->ready || second->error != nil; });
    XCTAssertNil(second->error, @"failure: %@", second->error);
    XCTAssertTrue(second->ready, @"ready again from the data kept, without a peer");
    XCTAssertEqualObjects(nfc(second->fileURL.lastPathComponent), nfc(wanted));
    XCTAssertLessThan([gSeeder uploadedBytes] - uploadedBefore, 64 * kKiB, @"nothing downloaded again");
    [self checkServedBytesOf:wanted size:packFiles()[0].size server:second->serverURL];
    [self cancel:again deleteData:YES];
}

/// A pack without the episode wanted: the selection chooses no file, the stream fails at
/// once with PTTorrentStreamerErrorNoFileSelected and nothing is downloaded.
- (void)testChoosingNoFileFailsBeforeDownloading {
    auto result = std::make_shared<StreamResult>();
    int64_t const uploadedBefore = [gSeeder uploadedBytes];
    PTTorrentStreamer *streamer = [self stream:gPrivateTorrent directory:[self streamDirectory] result:result
                                        choose:^int(NSArray<NSString *> *names) { return PTTorrentStreamerNoFileIndex; }];
    [self waitFor:streamer result:result seconds:10];
    XCTAssertFalse(result->ready);
    XCTAssertEqualObjects(result->error.domain, PTTorrentStreamerErrorDomain);
    XCTAssertEqual(result->error.code, PTTorrentStreamerErrorNoFileSelected, @"%@", result->error);
    XCTAssertGreaterThan(result->error.localizedDescription.length, 0u);
    spin(1, nil);
    XCTAssertEqual([gSeeder uploadedBytes] - uploadedBefore, 0, @"nothing downloaded");
    [self cancel:streamer deleteData:YES];

    // Any index out of range is "no file" too.
    auto outOfRange = std::make_shared<StreamResult>();
    PTTorrentStreamer *other = [self stream:gPrivateTorrent directory:[self streamDirectory] result:outOfRange
                                     choose:^int(NSArray<NSString *> *names) { return (int)names.count; }];
    [self waitFor:other result:outOfRange seconds:10];
    XCTAssertEqual(outOfRange->error.code, PTTorrentStreamerErrorNoFileSelected, @"%@", outOfRange->error);
    [self cancel:other deleteData:YES];
}

@end
