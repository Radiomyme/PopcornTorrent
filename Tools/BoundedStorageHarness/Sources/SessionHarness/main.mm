//
//  main.mm
//  SessionHarness
//
//  Offline checks of the torrent session lifecycle:
//   SessionHarness zombie <work>      cancelled streams stop; a replay of the same torrent (also
//                                     right after a cancel with deleteData) is ready, right bytes
//   SessionHarness starve <work>      3 cancelled streams then a 4th; 3 active downloads then a
//                                     stream; a paused download stays paused; resume works
//   SessionHarness guest <work>       a stream of a torrent an offline download is downloading
//                                     joins it (see PTTorrentsSession joinTorrent:)
//   SessionHarness background <work>  the tvOS "long background" network reopen during a stream
// Generated payloads (random bytes), private torrents without trackers, a seeder on 127.0.0.1,
// the streamer's shared session loopback-only (no DHT, LSD, UPnP, NAT-PMP). Run it under
// sandbox-exec with localhost-only.sb. Every stream and download writes under <work>.
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <MediaPlayer/MPMediaItem.h>
#import "PTTorrentStreamer.h"
#import "PTTorrentStreamer+Protected.h"
#import "PTTorrentsSession.h"
#import "PTTorrentsSession+Protected.h"
#import "PTTorrentsSession+Testing.h"
#import "PTTorrentDownload.h"
#include <libtorrent/session.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/bencode.hpp>
#include <libtorrent/address.hpp>
#include <libtorrent/peer_info.hpp>
#include <sys/stat.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fstream>
#include <memory>
#include <vector>

namespace lt = libtorrent;

static int gFailures = 0;
static int gPasses = 0;

static void logf(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void logf(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    static NSDate *t0; if (!t0) t0 = [NSDate date];
    printf("[%6.1f] %s\n", -[t0 timeIntervalSinceNow], s.UTF8String);
    fflush(stdout);
}

static void check(BOOL ok, NSString *name, NSString *detail) {
    logf(@"ASSERT %@ %@: %@", ok ? @"PASS" : @"FAIL", name, detail);
    if (ok) gPasses++; else gFailures++;
}

static void spin(double seconds, BOOL (^until)(void)) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([end timeIntervalSinceNow] > 0) {
        if (until && until()) return;
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
}

static long long allocatedBytes(NSString *dir) {
    BOOL isDir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:dir isDirectory:&isDir]) return -1;
    if (!isDir) {
        struct ::stat st;
        return ::stat(dir.fileSystemRepresentation, &st) == 0 ? (long long)st.st_blocks * 512 : -1;
    }
    long long total = 0;
    for (NSString *sub in [[NSFileManager defaultManager] enumeratorAtPath:dir]) {
        struct ::stat st;
        if (::lstat([[dir stringByAppendingPathComponent:sub] fileSystemRepresentation], &st) == 0 && S_ISREG(st.st_mode))
            total += (long long)st.st_blocks * 512;
    }
    return total;
}

static NSString *sha256OfFile(NSString *path) {
    NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!h) return @"(missing)";
    CC_SHA256_CTX ctx; CC_SHA256_Init(&ctx);
    while (true) {
        @autoreleasepool {
            NSData *d = [h readDataOfLength:8 << 20];
            if (d.length == 0) break;
            CC_SHA256_Update(&ctx, d.bytes, (CC_LONG)d.length);
        }
    }
    unsigned char md[32]; CC_SHA256_Final(md, &ctx);
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < 32; i++) [s appendFormat:@"%02x", md[i]];
    return s;
}

/// A generated payload and its private torrent (no trackers).
struct Payload {
    NSString *dir;
    NSString *path;
    NSString *torrent;
    int64_t size = 0;
    std::shared_ptr<lt::torrent_info> ti;
};

static Payload makePayload(NSString *work, NSString *name, int64_t size, int pieceLength) {
    Payload p;
    p.dir = [work stringByAppendingPathComponent:[@"seed-" stringByAppendingString:name]];
    [[NSFileManager defaultManager] createDirectoryAtPath:p.dir withIntermediateDirectories:YES attributes:nil error:nil];
    p.path = [p.dir stringByAppendingPathComponent:[name stringByAppendingString:@".mkv"]];
    p.size = size;
    {
        std::ofstream out(p.path.fileSystemRepresentation, std::ios::binary);
        std::vector<char> buf(1 << 20);
        for (int64_t done = 0; done < size; done += (int64_t)buf.size()) {
            arc4random_buf(buf.data(), buf.size());
            out.write(buf.data(), (std::streamsize)std::min<int64_t>((int64_t)buf.size(), size - done));
        }
    }
    p.torrent = [work stringByAppendingPathComponent:[name stringByAppendingString:@".torrent"]];
    lt::file_storage fs;
    lt::add_files(fs, p.path.fileSystemRepresentation);
    lt::create_torrent ct(fs, pieceLength);
    ct.set_priv(true);
    lt::set_piece_hashes(ct, p.dir.fileSystemRepresentation);
    std::vector<char> bytes;
    lt::bencode(std::back_inserter(bytes), ct.generate());
    std::ofstream t(p.torrent.fileSystemRepresentation, std::ios::binary);
    t.write(bytes.data(), (std::streamsize)bytes.size());
    t.close();
    p.ti = std::make_shared<lt::torrent_info>(std::string(p.torrent.fileSystemRepresentation));
    return p;
}

static NSData *payloadRange(Payload const& p, int64_t offset, int64_t length) {
    NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:p.path];
    [h seekToFileOffset:(unsigned long long)offset];
    return [h readDataOfLength:(NSUInteger)length];
}

/// Localhost-only seeder session.
struct Seeder {
    std::unique_ptr<lt::session> session;
    std::vector<lt::torrent_handle> handles;
    int port = 0;
    Seeder() {
        lt::settings_pack sp;
        sp.set_str(lt::settings_pack::listen_interfaces, "127.0.0.1:0");
        sp.set_bool(lt::settings_pack::enable_dht, false);
        sp.set_bool(lt::settings_pack::enable_lsd, false);
        sp.set_bool(lt::settings_pack::enable_upnp, false);
        sp.set_bool(lt::settings_pack::enable_natpmp, false);
        sp.set_str(lt::settings_pack::dht_bootstrap_nodes, "");
        sp.set_bool(lt::settings_pack::allow_multiple_connections_per_ip, true);
        sp.set_int(lt::settings_pack::alert_mask, 0);
        sp.set_int(lt::settings_pack::min_reconnect_time, 1);
        session.reset(new lt::session(lt::session_params(std::move(sp))));
        for (int i = 0; i < 500 && session->listen_port() == 0; i++) usleep(20000);
        port = session->listen_port();
        logf(@"seeder listening on 127.0.0.1:%d", port);
    }
    lt::torrent_handle seed(Payload const& p, int uploadLimit) {
        lt::add_torrent_params a;
        a.ti = p.ti;
        a.save_path = p.dir.fileSystemRepresentation;
        a.flags |= lt::torrent_flags::seed_mode;
        a.flags &= ~lt::torrent_flags::auto_managed;
        a.flags &= ~lt::torrent_flags::paused;
        lt::torrent_handle h = session->add_torrent(a);
        if (uploadLimit > 0) h.set_upload_limit(uploadLimit);
        handles.push_back(h);
        return h;
    }
};

static lt::tcp::endpoint loopback(int port) {
    return lt::tcp::endpoint(lt::make_address("127.0.0.1"), (unsigned short)port);
}

/// Stands in for trackers / DHT: the streamer's torrent is told about the seeder.
static void nudge(PTTorrentStreamer *s, int seederPort) {
    lt::torrent_handle h = s.torrentHandle;
    if (h.is_valid()) h.connect_peer(loopback(seederPort));
}

static NSString *describe(PTTorrentStreamer *s) {
    lt::torrent_handle h = s.torrentHandle;
    if (!h.is_valid()) return @"(no handle)";
    lt::torrent_status st = h.status();
    std::vector<lt::peer_info> peers;
    h.get_peer_info(peers);
    int utp = 0;
    for (auto const& peer : peers) utp += (peer.flags & lt::peer_info::utp_socket) ? 1 : 0;
    return [NSString stringWithFormat:@"state %d paused %d auto_managed %d peers %d (uTP %d) have %d rate %d B/s finished %d",
            (int)st.state, (int)(bool)(st.flags & lt::torrent_flags::paused),
            (int)(bool)(st.flags & lt::torrent_flags::auto_managed), st.num_peers, utp, st.num_pieces,
            st.download_payload_rate, (int)st.is_finished];
}

/// GET with a Range header through the streamer's HTTP server (synchronous, run loop spun).
static NSData *httpGet(int port, NSString *file, int64_t offset, int64_t length, NSInteger *status, double timeout) {
    NSString *url = [NSString stringWithFormat:@"http://127.0.0.1:%d/%@", port, [file stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [req setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", offset, offset + length - 1] forHTTPHeaderField:@"Range"];
    req.timeoutInterval = timeout;
    __block NSData *result = nil;
    __block NSInteger code = 0;
    __block BOOL done = NO;
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.connectionProxyDictionary = @{};
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        code = error ? -1 : ((NSHTTPURLResponse *)response).statusCode;
        result = data;
        done = YES;
    }] resume];
    spin(timeout + 5, ^BOOL { return done; });
    [session invalidateAndCancel];
    if (status) *status = code;
    return result;
}

struct StreamResult {
    __strong NSURL *url;
    __strong NSString *failure;
    NSInteger failureCode = 0;
    BOOL ready = NO;
};

static void startStream(PTTorrentStreamer *s, NSString *torrent, std::shared_ptr<StreamResult> const& r, NSString *label) {
    [s startStreamingFromMultiTorrentFileOrMagnetLink:torrent
        progress:^(PTTorrentStatus status) {}
        readyToPlay:^(NSURL *url, NSURL *file) { r->url = url; r->ready = YES; logf(@"%@ readyToPlay %@ -> %@", label, url, file.path); }
        failure:^(NSError *error) { r->failure = error.localizedDescription; r->failureCode = error.code; logf(@"%@ failure %ld: %@", label, (long)error.code, error.localizedDescription); }
        selectFileToStream:^int(NSArray<NSString *> *names, NSArray<NSNumber *> *sizes) { return 0; }];
}

static BOOL waitReady(PTTorrentStreamer *s, std::shared_ptr<StreamResult> const& r, int seederPort, double seconds) {
    spin(seconds, ^BOOL { nudge(s, seederPort); return r->ready || r->failure != nil; });
    return r->ready;
}

static PTTorrentDownload *makeDownload(NSString *torrent, NSString *dir, NSString *idTag) {
    PTTorrentDownload *d = [[PTTorrentDownload alloc] initWithMediaMetadata:@{MPMediaItemPropertyPersistentID: idTag}
                                                             downloadStatus:PTTorrentDownloadStatusProcessing];
    d.downloadDirectoryOverride = dir;
    [d startDownloadingFromFileOrMagnetLink:torrent selectFileTDownload:^int(NSArray<NSString *> *n, NSArray<NSNumber *> *z) { return 0; }];
    return d;
}

static long long uploaded(lt::torrent_handle const& h) { return h.status().total_payload_upload; }

#pragma mark - zombie

static int runZombie(NSString *work) {
    NSString *downloads = [work stringByAppendingPathComponent:@"streams"];
    Payload p = makePayload(work, @"zombie", 96LL << 20, 1 << 20);
    NSData *head = payloadRange(p, 0, 65536);
    Seeder seeder;
    int const seederPort = seeder.port;
    lt::torrent_handle seed = seeder.seed(p, 1 << 20); // 1 MiB/s: the whole payload takes ~96 s
    logf(@"payload 96 MiB, seeder on 127.0.0.1:%d", seederPort);

    // 1. A, then cancel with deleteData:YES (tvOS player close).
    auto ra = std::make_shared<StreamResult>();
    PTTorrentStreamer *a = [PTTorrentStreamer new];
    a.downloadDirectoryOverride = downloads;
    startStream(a, p.torrent, ra, @"A");
    BOOL readyA = waitReady(a, ra, seederPort, 60);
    check(readyA, @"A ready", describe(a));
    NSString *folderA = a.savePath;
    long long seededAtCancel = uploaded(seed);
    [a cancelStreamingAndDeleteData:YES];
    check(allocatedBytes(folderA) < 0, @"A cancel deletes the folder", folderA.lastPathComponent);
    spin(3, nil);
    long long afterSettle = uploaded(seed);
    spin(20, nil);
    long long after20 = uploaded(seed);
    check(after20 - afterSettle == 0 && allocatedBytes(folderA) < 0 && seed.status().num_peers == 0,
          @"cancelled stream stops downloading",
          [NSString stringWithFormat:@"seeded %lld KiB in the 3 s after cancel (in flight), then %lld KiB over 20 s; folder exists %d; seeder peers %d",
           (afterSettle - seededAtCancel) >> 10, (after20 - afterSettle) >> 10, allocatedBytes(folderA) >= 0, seed.status().num_peers]);

    // 2. B: replay the same torrent in the same launch.
    auto rb = std::make_shared<StreamResult>();
    PTTorrentStreamer *b = [PTTorrentStreamer new];
    b.downloadDirectoryOverride = downloads;
    startStream(b, p.torrent, rb, @"B");
    BOOL readyB = waitReady(b, rb, seederPort, 60);
    check(readyB && rb->failure == nil, @"replay of the same torrent is ready", describe(b));
    if (readyB) {
        NSInteger status = 0;
        NSData *httpHead = httpGet(rb->url.port.intValue, b.fileName, 0, 65536, &status, 30);
        NSData *fileHead = [[NSFileHandle fileHandleForReadingAtPath:[b.savePath stringByAppendingPathComponent:b.fileName]] readDataOfLength:65536];
        NSData *httpMid = httpGet(rb->url.port.intValue, b.fileName, 40LL << 20, 1 << 20, &status, 60);
        check([httpHead isEqualToData:head] && [fileHead isEqualToData:head] && [httpMid isEqualToData:payloadRange(p, 40LL << 20, 1 << 20)],
              @"replay serves the right bytes", [NSString stringWithFormat:@"HTTP head %d, file head %d, HTTP 40 MiB (waited for) %d, status %ld",
                                                  [httpHead isEqualToData:head], [fileHead isEqualToData:head],
                                                  [httpMid isEqualToData:payloadRange(p, 40LL << 20, 1 << 20)], (long)status]);
    }

    // 3. Cancel B with deleteData:YES and start C of the same torrent at once (disk-full retry).
    NSString *folderB = b.savePath;
    [b cancelStreamingAndDeleteData:YES];
    auto rc = std::make_shared<StreamResult>();
    PTTorrentStreamer *c = [PTTorrentStreamer new];
    c.downloadDirectoryOverride = downloads;
    NSDate *cStart = [NSDate date];
    startStream(c, p.torrent, rc, @"C");
    double addSeconds = -[cStart timeIntervalSinceNow];
    BOOL readyC = waitReady(c, rc, seederPort, 60);
    check(readyC && rc->failure == nil && [c.savePath isEqualToString:folderB], @"immediate replay after a delete is ready",
          [NSString stringWithFormat:@"start returned in %.3f s (waits for the previous deletion), %@", addSeconds, describe(c)]);
    if (readyC) {
        spin(2, nil); // libtorrent's deletion of B's files is done: C's file must still be there
        NSInteger status = 0;
        NSData *httpHead = httpGet(rc->url.port.intValue, c.fileName, 0, 65536, &status, 30);
        NSString *cFile = [c.savePath stringByAppendingPathComponent:c.fileName];
        check([httpHead isEqualToData:head] && allocatedBytes(cFile) > 0, @"immediate replay keeps its file",
              [NSString stringWithFormat:@"HTTP head matches %d, file allocated %lld KiB", [httpHead isEqualToData:head], allocatedBytes(cFile) >> 10]);
    }
    [c cancelStreamingAndDeleteData:YES];
    // A second cancel is harmless, and must not touch a newer torrent.
    [c cancelStreamingAndDeleteData:YES];
    [a cancelStreamingAndDeleteData:YES];
    spin(5, nil);
    check(allocatedBytes(downloads) <= 0, @"nothing left after the cancels", [NSString stringWithFormat:@"streams dir allocated %lld", allocatedBytes(downloads)]);
    return 0;
}

#pragma mark - starve

static int runStarve(NSString *work) {
    NSString *downloads = [work stringByAppendingPathComponent:@"streams"];
    NSString *offline = [work stringByAppendingPathComponent:@"offline"];
    Seeder seeder;
    int const seederPort = seeder.port;
    std::vector<Payload> payloads;
    std::vector<lt::torrent_handle> seeds;
    for (int i = 0; i < 8; i++) {
        payloads.push_back(makePayload(work, [NSString stringWithFormat:@"starve-%d", i], 32LL << 20, 256 << 10));
        seeds.push_back(seeder.seed(payloads.back(), 256 << 10)); // slow but active
    }
    auto uploads = [&]() {
        NSMutableString *m = [NSMutableString string];
        for (auto& h : seeds) [m appendFormat:@"%lld ", uploaded(h) >> 10];
        return m;
    };

    // 1. Three streams, each cancelled with deleteData:YES, then a fourth.
    NSMutableArray<NSString *> *folders = [NSMutableArray array];
    for (int i = 0; i < 3; i++) {
        auto r = std::make_shared<StreamResult>();
        PTTorrentStreamer *s = [PTTorrentStreamer new];
        s.downloadDirectoryOverride = downloads;
        startStream(s, payloads[size_t(i)].torrent, r, [NSString stringWithFormat:@"S%d", i]);
        BOOL ready = waitReady(s, r, seederPort, 60);
        logf(@"S%d ready=%d %@ -> cancelStreamingAndDeleteData:YES", i, ready, describe(s));
        [folders addObject:s.savePath ?: @""];
        [s cancelStreamingAndDeleteData:YES];
    }
    spin(2, nil);
    NSString *before = uploads();
    spin(10, nil);
    NSString *after = uploads();
    check([[before componentsSeparatedByString:@" "] subarrayWithRange:NSMakeRange(0, 3)].count == 3
          && [[[before componentsSeparatedByString:@" "] subarrayWithRange:NSMakeRange(0, 3)] isEqualToArray:[[after componentsSeparatedByString:@" "] subarrayWithRange:NSMakeRange(0, 3)]],
          @"three cancelled streams stopped", [NSString stringWithFormat:@"KiB uploaded per torrent %@-> %@", before, after]);
    auto r3 = std::make_shared<StreamResult>();
    PTTorrentStreamer *s3 = [PTTorrentStreamer new];
    s3.downloadDirectoryOverride = downloads;
    NSDate *t3 = [NSDate date];
    startStream(s3, payloads[3].torrent, r3, @"S3");
    BOOL ready3 = waitReady(s3, r3, seederPort, 60);
    check(ready3, @"4th stream after 3 cancelled ones starts", [NSString stringWithFormat:@"ready in %.1f s, %@", -[t3 timeIntervalSinceNow], describe(s3)]);
    [s3 cancelStreamingAndDeleteData:YES];
    BOOL leftover = NO;
    for (NSString *f in folders) leftover = leftover || [[NSFileManager defaultManager] fileExistsAtPath:f];
    check(!leftover, @"no leftover folders", @"");

    // 2. Three active offline downloads, then a stream (gap A: the auto-manager queued it).
    NSMutableArray<PTTorrentDownload *> *dls = [NSMutableArray array];
    for (int i = 4; i < 7; i++) [dls addObject:makeDownload(payloads[size_t(i)].torrent, offline, [NSString stringWithFormat:@"dl-%d", i])];
    spin(8, ^BOOL { for (PTTorrentDownload *d in dls) nudge(d, seederPort); return NO; });
    NSMutableString *dlState = [NSMutableString string];
    BOOL allRunning = YES;
    for (PTTorrentDownload *d in dls) {
        lt::torrent_status st = d.torrentHandle.status();
        allRunning = allRunning && !(st.flags & lt::torrent_flags::paused) && !(st.flags & lt::torrent_flags::auto_managed) && st.num_pieces > 0;
        [dlState appendFormat:@"[%@] ", describe(d)];
    }
    check(allRunning, @"three downloads run, not auto-managed", dlState);
    auto r7 = std::make_shared<StreamResult>();
    PTTorrentStreamer *s7 = [PTTorrentStreamer new];
    s7.downloadDirectoryOverride = downloads;
    NSDate *t7 = [NSDate date];
    startStream(s7, payloads[7].torrent, r7, @"S7");
    BOOL ready7 = NO;
    for (int i = 0; i < 600 && !ready7 && !r7->failure; i++) {
        spin(0.1, nil);
        nudge(s7, seederPort);
        for (PTTorrentDownload *d in dls) nudge(d, seederPort);
        ready7 = r7->ready;
    }
    lt::torrent_status st7 = s7.torrentHandle.status();
    check(ready7 && !(st7.flags & lt::torrent_flags::auto_managed), @"a stream starts while 3 downloads are active",
          [NSString stringWithFormat:@"ready in %.1f s, %@", -[t7 timeIntervalSinceNow], describe(s7)]);
    [s7 cancelStreamingAndDeleteData:YES];

    // 3. Gap B: a paused download stays paused past the auto-manager's interval (30 s).
    PTTorrentDownload *d0 = dls[0];
    [d0 pause];
    spin(3, nil);
    long long pausedAt = uploaded(seeds[4]);
    spin(35, ^BOOL { for (PTTorrentDownload *d in dls) if (d != d0) nudge(d, seederPort); return NO; });
    long long pausedEnd = uploaded(seeds[4]);
    lt::torrent_status st0 = d0.torrentHandle.status();
    check(pausedEnd == pausedAt && (st0.flags & lt::torrent_flags::paused) && d0.downloadStatus == PTTorrentDownloadStatusPaused,
          @"a paused download stays paused", [NSString stringWithFormat:@"%lld KiB over 35 s, %@", (pausedEnd - pausedAt) >> 10, describe(d0)]);
    [d0 resume];
    spin(8, ^BOOL { nudge(d0, seederPort); return NO; });
    check(uploaded(seeds[4]) > pausedEnd && d0.downloadStatus != PTTorrentDownloadStatusPaused, @"resume downloads again",
          [NSString stringWithFormat:@"+%lld KiB, %@", (uploaded(seeds[4]) - pausedEnd) >> 10, describe(d0)]);
    for (PTTorrentDownload *d in dls) [d stop];
    spin(3, nil);
    check(allocatedBytes(offline) <= 0 && allocatedBytes(downloads) <= 0, @"stopped downloads and streams leave nothing",
          [NSString stringWithFormat:@"offline %lld, streams %lld", allocatedBytes(offline), allocatedBytes(downloads)]);
    return 0;
}

#pragma mark - guest

/// Reads [offset, offset + length) through the stream's server in 4 MiB requests and compares.
static BOOL readAndCompare(int port, NSString *file, Payload const& p, int64_t offset, int64_t length, double timeoutPerChunk, NSString **detail) {
    int64_t const chunk = 4LL << 20;
    for (int64_t at = offset; at < offset + length; at += chunk) {
        int64_t const n = std::min(chunk, offset + length - at);
        NSInteger status = 0;
        NSData *got = httpGet(port, file, at, n, &status, timeoutPerChunk);
        if (![got isEqualToData:payloadRange(p, at, n)]) {
            if (detail) *detail = [NSString stringWithFormat:@"mismatch at %lld (status %ld, %lu bytes)", at, (long)status, (unsigned long)got.length];
            return NO;
        }
    }
    if (detail) *detail = [NSString stringWithFormat:@"%lld MiB match", length >> 20];
    return YES;
}

static int runGuest(NSString *work) {
    NSString *streams = [work stringByAppendingPathComponent:@"streams"];
    NSString *offline = [work stringByAppendingPathComponent:@"offline"];
    Seeder seeder;
    int const seederPort = seeder.port;

    // 1. A download in progress, paused; a stream of the same torrent joins it.
    Payload p = makePayload(work, @"guest", 128LL << 20, 1 << 20);
    lt::torrent_handle seed = seeder.seed(p, 2 << 20); // 2 MiB/s
    PTTorrentDownload *d = makeDownload(p.torrent, offline, @"guest-dl");
    spin(60, ^BOOL { nudge(d, seederPort); return d.torrentStatus.totalProgress > 0.08; });
    logf(@"download: progress %.3f, %@", d.torrentStatus.totalProgress, describe(d));
    [d pause];
    spin(3, nil);
    long long pausedAt = uploaded(seed);
    spin(4, nil);
    check(uploaded(seed) == pausedAt && d.downloadStatus == PTTorrentDownloadStatusPaused, @"download paused", describe(d));

    auto rg = std::make_shared<StreamResult>();
    PTTorrentStreamer *g = [PTTorrentStreamer new];
    g.downloadDirectoryOverride = streams;
    g.allowsBoundedStorage = YES; // as the tvOS app: the guest is full mode anyway
    NSDate *tg = [NSDate date];
    startStream(g, p.torrent, rg, @"G");
    BOOL readyG = waitReady(g, rg, seederPort, 60);
    check(readyG && g.isGuest && g.storageMode == PTStorageModeFull && [g.savePath isEqualToString:d.savePath]
          && d.torrentHandle == g.torrentHandle,
          @"stream joins the download's torrent",
          [NSString stringWithFormat:@"ready %d in %.1f s, guest %d, mode %ld, same folder %d, same handle %d", readyG, -[tg timeIntervalSinceNow],
           g.isGuest, (long)g.storageMode, [g.savePath isEqualToString:d.savePath], d.torrentHandle == g.torrentHandle]);
    check(allocatedBytes(streams) <= 0, @"no second copy",
          [NSString stringWithFormat:@"stream folder allocated %lld (none expected)", allocatedBytes(streams)]);
    check(seed.status().num_peers == 1, @"one session, one connection", [NSString stringWithFormat:@"seeder peers %d", seed.status().num_peers]);
    spin(3, ^BOOL { nudge(g, seederPort); return NO; });
    check(uploaded(seed) > pausedAt, @"paused download runs while a stream reads it", [NSString stringWithFormat:@"+%lld KiB", (uploaded(seed) - pausedAt) >> 10]);
    if (readyG) {
        NSString *detail = nil;
        BOOL headOK = readAndCompare(rg->url.port.intValue, g.fileName, p, 0, 8LL << 20, 30, &detail);
        check(headOK, @"guest head bytes", detail);
        // Far ahead of the download's sequential order: the guest's window drives the torrent.
        NSDate *t = [NSDate date];
        BOOL farOK = readAndCompare(rg->url.port.intValue, g.fileName, p, 100LL << 20, 4LL << 20, 60, &detail);
        check(farOK, @"guest window drives the torrent", [NSString stringWithFormat:@"%@ at 100 MiB in %.1f s (download at %.0f %%)",
                                                          detail, -[t timeIntervalSinceNow], d.torrentStatus.totalProgress * 100]);
    }
    NSString *dlFile = [d.savePath stringByAppendingPathComponent:d.fileName];
    long long dlBefore = allocatedBytes(dlFile);
    [g cancelStreamingAndDeleteData:YES];
    spin(3, nil);
    long long reAt = uploaded(seed);
    spin(4, nil);
    check(allocatedBytes(dlFile) >= dlBefore && [[NSFileManager defaultManager] fileExistsAtPath:d.savePath]
          && uploaded(seed) == reAt && d.downloadStatus == PTTorrentDownloadStatusPaused && (d.torrentHandle.status().flags & lt::torrent_flags::paused),
          @"stream cancel keeps the download's data and pause",
          [NSString stringWithFormat:@"file %lld -> %lld KiB, uploads after cancel %lld KiB, %@", dlBefore >> 10, allocatedBytes(dlFile) >> 10,
           (uploaded(seed) - reAt) >> 10, describe(d)]);
    [d resume];
    spin(120, ^BOOL { nudge(d, seederPort); return d.downloadStatus == PTTorrentDownloadStatusFinished; });
    spin(2, nil);
    NSString *dlHash = sha256OfFile([d.savePath stringByAppendingPathComponent:d.fileName]);
    check(d.downloadStatus == PTTorrentDownloadStatusFinished && [dlHash isEqualToString:sha256OfFile(p.path)], @"download completes after the stream",
          [NSString stringWithFormat:@"status %ld, hash equal %d", (long)d.downloadStatus, [dlHash isEqualToString:sha256OfFile(p.path)]]);

    // 2. The download is stopped (deleted) while a stream reads it, file incomplete: the stream fails.
    Payload p2 = makePayload(work, @"guest2", 64LL << 20, 1 << 20);
    lt::torrent_handle seed2 = seeder.seed(p2, 1 << 20);
    PTTorrentDownload *d2 = makeDownload(p2.torrent, offline, @"guest-dl2");
    spin(30, ^BOOL { nudge(d2, seederPort); return d2.torrentStatus.totalProgress > 0.1; });
    auto rg2 = std::make_shared<StreamResult>();
    PTTorrentStreamer *g2 = [PTTorrentStreamer new];
    g2.downloadDirectoryOverride = streams;
    startStream(g2, p2.torrent, rg2, @"G2");
    BOOL ready2 = waitReady(g2, rg2, seederPort, 60);
    [d2 stop];
    spin(5, nil);
    check(ready2 && rg2->failureCode == PTTorrentStreamerErrorSharedTorrentRemoved, @"stopping the download ends the stream that read it",
          [NSString stringWithFormat:@"ready %d, failure code %ld (%@)", ready2, (long)rg2->failureCode, rg2->failure]);
    [g2 cancelStreamingAndDeleteData:YES];
    (void)seed2;

    // 3. The download finishes while a stream reads it: the stream goes on to the end.
    Payload p3 = makePayload(work, @"guest3", 48LL << 20, 1 << 20);
    lt::torrent_handle seed3 = seeder.seed(p3, 4 << 20);
    PTTorrentDownload *d3 = makeDownload(p3.torrent, offline, @"guest-dl3");
    spin(20, ^BOOL { nudge(d3, seederPort); return d3.torrentStatus.totalProgress > 0.05; });
    auto rg3 = std::make_shared<StreamResult>();
    PTTorrentStreamer *g3 = [PTTorrentStreamer new];
    g3.downloadDirectoryOverride = streams;
    startStream(g3, p3.torrent, rg3, @"G3");
    BOOL ready3 = waitReady(g3, rg3, seederPort, 60);
    spin(60, ^BOOL { nudge(d3, seederPort); return d3.downloadStatus == PTTorrentDownloadStatusFinished; });
    spin(2, nil);
    NSString *detail3 = nil;
    BOOL whole3 = ready3 && readAndCompare(rg3->url.port.intValue, g3.fileName, p3, 0, p3.size, 30, &detail3);
    check(d3.downloadStatus == PTTorrentDownloadStatusFinished && whole3 && rg3->failure == nil && g3.torrentStatus.totalProgress >= 1,
          @"download finishing under a stream: the stream reads the whole file",
          [NSString stringWithFormat:@"download %ld, %@, failure %@, progress %.2f", (long)d3.downloadStatus, detail3, rg3->failure, g3.torrentStatus.totalProgress]);
    [g3 cancelStreamingAndDeleteData:YES];
    spin(2, nil);
    check([sha256OfFile([d3.savePath stringByAppendingPathComponent:d3.fileName]) isEqualToString:sha256OfFile(p3.path)],
          @"finished download intact after the stream's cancel", @"");
    (void)seed3;

    // 4. Two streams of one torrent (full mode): the first one's cancel hands it to the second.
    Payload p4 = makePayload(work, @"guest4", 48LL << 20, 1 << 20);
    seeder.seed(p4, 4 << 20);
    auto r41 = std::make_shared<StreamResult>();
    PTTorrentStreamer *s41 = [PTTorrentStreamer new];
    s41.downloadDirectoryOverride = streams;
    startStream(s41, p4.torrent, r41, @"S4a");
    BOOL ready41 = waitReady(s41, r41, seederPort, 60);
    auto r42 = std::make_shared<StreamResult>();
    PTTorrentStreamer *s42 = [PTTorrentStreamer new];
    s42.downloadDirectoryOverride = streams;
    startStream(s42, p4.torrent, r42, @"S4b");
    BOOL ready42 = waitReady(s42, r42, seederPort, 60);
    NSString *folder4 = s41.savePath;
    [s41 cancelStreamingAndDeleteData:YES];
    spin(1, nil);
    NSString *detail4 = nil;
    BOOL whole4 = ready42 && readAndCompare(r42->url.port.intValue, s42.fileName, p4, 0, p4.size, 60, &detail4);
    check(ready41 && whole4 && !s42.isGuest && [[NSFileManager defaultManager] fileExistsAtPath:folder4],
          @"the first stream's cancel hands the torrent to the second",
          [NSString stringWithFormat:@"%@, second now owner %d, folder kept %d", detail4, !s42.isGuest, [[NSFileManager defaultManager] fileExistsAtPath:folder4]]);
    [s42 cancelStreamingAndDeleteData:YES];
    spin(3, nil);
    check(![[NSFileManager defaultManager] fileExistsAtPath:folder4], @"the last stream's cancel deletes the folder", @"");

    // 5. A download of a torrent a stream is playing is refused (it keeps its own copy).
    Payload p5 = makePayload(work, @"guest5", 16LL << 20, 1 << 20);
    seeder.seed(p5, 4 << 20);
    auto r5 = std::make_shared<StreamResult>();
    PTTorrentStreamer *s5 = [PTTorrentStreamer new];
    s5.downloadDirectoryOverride = streams;
    startStream(s5, p5.torrent, r5, @"S5");
    waitReady(s5, r5, seederPort, 60);
    __block NSInteger refused = 0;
    PTTorrentDownload *d5 = [[PTTorrentDownload alloc] initWithMediaMetadata:@{MPMediaItemPropertyPersistentID: @"guest-dl5"} downloadStatus:PTTorrentDownloadStatusProcessing];
    d5.downloadDirectoryOverride = offline;
    [d5 startStreamingFromMultiTorrentFileOrMagnetLink:p5.torrent progress:^(PTTorrentStatus s) {} readyToPlay:^(NSURL *a, NSURL *b) {}
        failure:^(NSError *error) { refused = error.code; } selectFileToStream:^int(NSArray<NSString *> *n, NSArray<NSNumber *> *z) { return 0; }];
    spin(2, ^BOOL { return refused != 0; });
    check(refused == PTTorrentStreamerErrorTorrentInUse && r5->failure == nil, @"a download of a torrent in use is refused",
          [NSString stringWithFormat:@"code %ld", (long)refused]);
    [s5 cancelStreamingAndDeleteData:YES];
    spin(3, nil);
    check(allocatedBytes(streams) <= 0, @"streams leave nothing", [NSString stringWithFormat:@"%lld", allocatedBytes(streams)]);
    return 0;
}

#pragma mark - background

static int runBackground(NSString *work) {
    NSString *streams = [work stringByAppendingPathComponent:@"streams"];
    Seeder seeder;
    int const seederPort = seeder.port;
    Payload p = makePayload(work, @"background", 64LL << 20, 1 << 20);
    lt::torrent_handle seed = seeder.seed(p, 2 << 20);
    PTTorrentsSession *session = [PTTorrentsSession sharedSession];
    auto r = std::make_shared<StreamResult>();
    PTTorrentStreamer *s = [PTTorrentStreamer new];
    s.downloadDirectoryOverride = streams;
    startStream(s, p.torrent, r, @"BG");
    BOOL ready = waitReady(s, r, seederPort, 60);
    check(ready, @"stream ready", describe(s));
    if (!ready) return 1;
    int const portBefore = session.listenPort;
    NSString *detail = nil;
    BOOL firstPart = readAndCompare(r->url.port.intValue, s.fileName, p, 0, 16LL << 20, 60, &detail);
    // What the tvOS app does after more than 5 min in the background.
    [session reopenNetworkForTesting];
    spin(2, nil);
    int const portAfter = session.listenPort;
    check(firstPart && portAfter != 0 && [PTTorrentsSession sharedSession] == session && s.torrentHandle.is_valid(),
          @"network reopened in the same session, torrent kept",
          [NSString stringWithFormat:@"listen port %d -> %d, %@", portBefore, portAfter, describe(s)]);
    // The stream goes on (a uTP connection ran over the closed UDP socket: it is dropped and
    // retried at once).
    NSDate *t2 = [NSDate date];
    BOOL secondPart = readAndCompare(r->url.port.intValue, s.fileName, p, 16LL << 20, 16LL << 20, 60, &detail);
    double const second = -[t2 timeIntervalSinceNow];
    check(secondPart && second < 20, @"stream goes on after the reopen", [NSString stringWithFormat:@"%@ in %.1f s (8 s at the seeder's rate), %@", detail, second, describe(s)]);
    // Connections lost while suspended (the seeder drops us), then the app becomes active
    // (reopen); nothing nudges the streamer. Lost peers are retried at once for 30 s after a
    // reopen (else after min_reconnect_time, 60 s).
    seed.pause();
    spin(2, nil);
    [session reopenNetworkForTesting];
    seed.resume();
    NSDate *t = [NSDate date];
    spin(30, ^BOOL { return seed.status().num_peers >= 1; });
    double const reconnect = -[t timeIntervalSinceNow];
    BOOL thirdPart = readAndCompare(r->url.port.intValue, s.fileName, p, 32LL << 20, 32LL << 20, 90, &detail);
    check(thirdPart && reconnect < 10, @"a dropped peer is reconnected at once after the reopen",
          [NSString stringWithFormat:@"reconnected after %.1f s, then %@", reconnect, detail]);
    // The new listen socket accepts connections.
    int const fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)session.listenPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    BOOL const listening = connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0;
    close(fd);
    check(listening, @"the reopened listen socket accepts connections", [NSString stringWithFormat:@"127.0.0.1:%d", session.listenPort]);
    [s cancelStreamingAndDeleteData:YES];
    spin(2, nil);
    return 0;
}

#pragma mark - legacy

/// A download of the CocoaPods PopcornTorrent, in progress when the app was updated to this
/// fork: its folder is named after the media (<PersistentID>/), its Metadata.plist has no file
/// index, its file is partial. Resumed, it must go on in that folder, on that file (not file #0
/// of a multi-file torrent), from what it had, and leave one plist (verify-regressions 3).
static int runLegacy(NSString *work) {
    NSString *offline = [work stringByAppendingPathComponent:@"offline"];
    NSFileManager *fm = [NSFileManager defaultManager];
    Seeder seeder;
    int const seederPort = seeder.port;

    // Two files: a sample listed first, the movie (48 MiB, 256 KiB pieces).
    NSString *seedRoot = [work stringByAppendingPathComponent:@"seed-legacy"];
    NSString *content = [seedRoot stringByAppendingPathComponent:@"Film"];
    [fm createDirectoryAtPath:content withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *sample = [content stringByAppendingPathComponent:@"0-sample.mkv"];
    NSString *movie = [content stringByAppendingPathComponent:@"Film.mkv"];
    int64_t const movieSize = 48LL << 20;
    for (NSString *file in @[sample, movie]) {
        int64_t const size = file == movie ? movieSize : (4LL << 20);
        std::ofstream out(file.fileSystemRepresentation, std::ios::binary);
        std::vector<char> buf(1 << 20);
        for (int64_t done = 0; done < size; done += (int64_t)buf.size()) {
            arc4random_buf(buf.data(), buf.size());
            out.write(buf.data(), (std::streamsize)std::min<int64_t>((int64_t)buf.size(), size - done));
        }
    }
    lt::file_storage fs;
    lt::add_files(fs, content.fileSystemRepresentation);
    lt::create_torrent ct(fs, 256 << 10);
    ct.set_priv(true);
    lt::set_piece_hashes(ct, seedRoot.fileSystemRepresentation);
    std::vector<char> bytes;
    lt::bencode(std::back_inserter(bytes), ct.generate());
    NSString *torrent = [work stringByAppendingPathComponent:@"legacy.torrent"];
    {
        std::ofstream t(torrent.fileSystemRepresentation, std::ios::binary);
        t.write(bytes.data(), (std::streamsize)bytes.size());
    }
    Payload p;
    p.dir = seedRoot;
    p.path = movie;
    p.size = movieSize;
    p.torrent = torrent;
    p.ti = std::make_shared<lt::torrent_info>(std::string(torrent.fileSystemRepresentation));
    int movieIndex = -1;
    for (int i = 0; i < p.ti->num_files(); ++i) {
        if (p.ti->files().file_name(lt::file_index_t(i)).to_string() == "Film.mkv") movieIndex = i;
    }
    logf(@"torrent: %d files, the movie is #%d", p.ti->num_files(), movieIndex);
    lt::torrent_handle seed = seeder.seed(p, 0);

    // The pod's layout: <download dir>/<PersistentID>/<torrent path>, Metadata.plist, half the movie.
    NSString *legacyFolder = [offline stringByAppendingPathComponent:@"tt0000001"];
    NSString *legacyMovie = [legacyFolder stringByAppendingPathComponent:@"Film/Film.mkv"];
    [fm createDirectoryAtPath:[legacyMovie stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    {
        NSData *half = payloadRange(p, 0, movieSize / 2);
        [half writeToFile:legacyMovie atomically:NO];
    }
    NSString *legacyPlist = [legacyFolder stringByAppendingPathComponent:@"Metadata.plist"];
    NSDictionary *metadata = @{MPMediaItemPropertyPersistentID: @"tt0000001",
                               @"filePathOrLink": torrent,
                               @"downloadStatus": @(PTTorrentDownloadStatusPaused),
                               @"progress": @(0.5f)};
    [metadata writeToFile:legacyPlist atomically:YES];

    PTTorrentDownload *d = [[PTTorrentDownload alloc] initFromPlist:legacyPlist];
    check(d != nil && d.downloadStatus == PTTorrentDownloadStatusPaused, @"legacy plist loads", [NSString stringWithFormat:@"status %ld", (long)d.downloadStatus]);
    d.downloadDirectoryOverride = offline;
    [d resume];
    spin(120, ^BOOL { nudge(d, seederPort); return d.downloadStatus == PTTorrentDownloadStatusFinished || d.downloadStatus == PTTorrentDownloadStatusFailed; });
    spin(2, nil);
    NSNumber *index = d.mediaMetadata[@"selectedFileIndex"];
    NSString *finishedFile = [d.savePath stringByAppendingPathComponent:d.fileName ?: @""];
    BOOL const sameFolder = [d.savePath isEqualToString:legacyFolder];
    check(sameFolder, @"resumes in its own folder", [NSString stringWithFormat:@"savePath %@ (expected %@)", d.savePath, legacyFolder]);
    check(index != nil && index.intValue == movieIndex, @"resumes on its file", [NSString stringWithFormat:@"index %@ (the movie is #%d)", index, movieIndex]);
    BOOL const complete = d.downloadStatus == PTTorrentDownloadStatusFinished
        && [sha256OfFile(legacyMovie) isEqualToString:sha256OfFile(movie)];
    check(complete, @"completes the partial file", [NSString stringWithFormat:@"status %ld, %@ == source %d", (long)d.downloadStatus, finishedFile,
                                                    [sha256OfFile(legacyMovie) isEqualToString:sha256OfFile(movie)]]);
    long long const sent = uploaded(seed);
    check(sent > 0 && sent < movieSize * 3 / 4, @"keeps what it had",
          [NSString stringWithFormat:@"seeder sent %lld MiB of %lld", sent >> 20, movieSize >> 20]);
    NSArray *folders = [fm contentsOfDirectoryAtPath:offline error:nil];
    NSArray *plists = [[fm contentsOfDirectoryAtPath:legacyFolder error:nil] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self ENDSWITH '.plist'"]];
    check(folders.count == 1 && plists.count == 1 && ![fm fileExistsAtPath:legacyPlist], @"one folder, one plist",
          [NSString stringWithFormat:@"folders %@, plists %@", folders, plists]);
    [d stop];
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr, "usage: SessionHarness zombie|starve|guest|background|legacy <workdir>\n"); return 2; }
        NSString *mode = [NSString stringWithUTF8String:argv[1]];
        NSString *work = [NSString stringWithUTF8String:argv[2]];
        [[NSFileManager defaultManager] removeItemAtPath:work error:nil];
        [[NSFileManager defaultManager] createDirectoryAtPath:work withIntermediateDirectories:YES attributes:nil error:nil];
        [PTTorrentsSession prepareSharedSessionForLoopbackTestingOnPort:0];
        int rc = 2;
        if ([mode isEqualToString:@"zombie"]) rc = runZombie(work);
        else if ([mode isEqualToString:@"starve"]) rc = runStarve(work);
        else if ([mode isEqualToString:@"guest"]) rc = runGuest(work);
        else if ([mode isEqualToString:@"background"]) rc = runBackground(work);
        else if ([mode isEqualToString:@"legacy"]) rc = runLegacy(work);
        logf(@"RESULT %@: %d passed, %d failed (rc %d)", mode, gPasses, gFailures, rc);
        [[NSFileManager defaultManager] removeItemAtPath:work error:nil];
        return gFailures > 0 ? 1 : rc;
    }
}
