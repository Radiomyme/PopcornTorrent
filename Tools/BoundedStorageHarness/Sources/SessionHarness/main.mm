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
//   SessionHarness premetadata <work> a magnet's status before its metadata: its only peer, a
//                                     seeder that starts late, shows in the progress block
//   SessionHarness network <work> [tv|ios|mac]  the network settings of a profile, the default
//                                     trackers, streams in file order, downloads rarest first
//   SessionHarness nofile <work>      a download of a pack magnet without the episode wanted:
//                                     fails once, and its folder (plist, early pieces) goes;
//                                     another episode's finished download of that pack stays
//                                     (its own folder, and in a folder they share)
//   SessionHarness packs <work>       two episodes downloaded from one season pack: a folder
//                                     each; reloaded from their plists, each plays its own file;
//                                     deleting or stopping one keeps the other (also in a folder
//                                     shared before 5.2.0)
//   SessionHarness trackers <work>    the default trackers (here two on 127.0.0.1 nobody answers):
//                                     a plain magnet gets them at once, a magnet with a keyed
//                                     tracker once its metadata says it is public, a private
//                                     torrent never; UPnP / NAT-PMP / LSD of each profile
//   SessionHarness restart <work>     a stream cancelled with deleteData and started again at
//                                     once keeps its folder and decides its storage (bounded,
//                                     refused) as one started later
//   SessionHarness finish <work>      full mode: libtorrent's "finished" with pieces of the file
//                                     missing (the gap behind the reader) is not a finish; the
//                                     progress follows the file's own pieces
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
#import "PTSize.h"
#include <libtorrent/session.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/bencode.hpp>
#include <libtorrent/address.hpp>
#include <libtorrent/peer_info.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/announce_entry.hpp>
#include <sys/stat.h>
#include <sys/resource.h>
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

static Payload makePayload(NSString *work, NSString *name, int64_t size, int pieceLength, bool priv = true) {
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
    // Private by default; a magnet test needs a public one (no metadata exchange otherwise).
    ct.set_priv(priv);
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
    // B's deletion removes its folder once done (rmdir, when empty): not the one C created
    // while it waited for that deletion (same folder).
    BOOL const folderAtStart = [[NSFileManager defaultManager] fileExistsAtPath:c.savePath];
    spin(1, nil);
    BOOL const folderLater = [[NSFileManager defaultManager] fileExistsAtPath:c.savePath];
    check(folderAtStart && folderLater, @"immediate replay keeps its folder",
          [NSString stringWithFormat:@"at start %d, 1 s later %d", folderAtStart, folderLater]);
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

#pragma mark - premetadata

/// One progress callback of a stream, with the streamer's loading state at that moment.
struct StatusSample {
    double t = 0;          // seconds since the stream started (harness clock)
    float buffering = 0;
    int rate = 0;          // download rate, bytes/s
    int seeds = 0;
    int peers = 0;
    bool hasMetadata = false;
    double sinceStart = 0; // the streamer's timeSinceStart
};

static NSString *magnetFor(Payload const& p) {
    return [NSString stringWithUTF8String:lt::make_magnet_uri(*p.ti).c_str()];
}

/// A magnet's status before its metadata (PTTorrentStreamer.h, Loading): the progress block and
/// the status notification start when the torrent is added, with 0 peers while nobody answers;
/// a seeder that starts late (the only peer) then shows as peers and download rate while the
/// metadata comes in (slowly: 8 KiB/s); one monitor loop per stream (2 callbacks a second, also
/// after the metadata); nothing after a cancel; a `.torrent` file has its metadata at once; a
/// download of a magnet stays "Processing" (no status before its metadata, as before).
static int runPreMetadata(NSString *work) {
    NSString *downloads = [work stringByAppendingPathComponent:@"streams"];
    // 64 MiB in 16 KiB pieces: 4096 hashes, an info dictionary of about 80 KiB, served at
    // 8 KiB/s: about 10 s of metadata exchange. Public: private torrents do not serve metadata.
    Payload p = makePayload(work, @"premeta", 64LL << 20, 16 << 10, false);
    NSData *head = payloadRange(p, 0, 65536);
    NSString *magnet = magnetFor(p);
    Seeder seeder;
    int const seederPort = seeder.port;
    logf(@"payload 64 MiB, %d pieces, magnet %@", p.ti->num_pieces(), magnet);

    __block std::vector<StatusSample> samples;
    __block int notifications = 0;
    auto r = std::make_shared<StreamResult>();
    PTTorrentStreamer *s = [PTTorrentStreamer new];
    s.downloadDirectoryOverride = downloads;
    __weak PTTorrentStreamer *weakS = s;
    check(!s.hasMetadata && s.timeSinceStart == 0, @"idle streamer: no metadata, no clock",
          [NSString stringWithFormat:@"hasMetadata %d, timeSinceStart %.3f", s.hasMetadata, s.timeSinceStart]);
    id observer = [[NSNotificationCenter defaultCenter] addObserverForName:PTTorrentStatusDidChangeNotification object:s queue:nil
                                                                usingBlock:^(NSNotification *note) { notifications++; }];
    NSDate *t0 = [NSDate date];
    [s startStreamingFromMultiTorrentFileOrMagnetLink:magnet
        progress:^(PTTorrentStatus st) {
            StatusSample x;
            x.t = -[t0 timeIntervalSinceNow];
            x.buffering = st.bufferingProgress; x.rate = st.downloadSpeed; x.seeds = st.seeds; x.peers = st.peers;
            x.hasMetadata = weakS.hasMetadata; x.sinceStart = weakS.timeSinceStart;
            samples.push_back(x);
        }
        readyToPlay:^(NSURL *url, NSURL *file) { r->url = url; r->ready = YES; logf(@"readyToPlay %@ -> %@", url, file.lastPathComponent); }
        failure:^(NSError *error) { r->failure = error.localizedDescription; r->failureCode = error.code; logf(@"failure %ld: %@", (long)error.code, error.localizedDescription); }
        selectFileToStream:^int(NSArray<NSString *> *names, NSArray<NSNumber *> *sizes) { return 0; }];
    check(!s.hasMetadata && s.storageMode == PTStorageModeUndetermined, @"a magnet starts without metadata",
          [NSString stringWithFormat:@"hasMetadata %d, mode %ld", s.hasMetadata, (long)s.storageMode]);

    // 1. Nobody to connect to for 6 s (the seeder has not added the torrent, nobody is told).
    spin(6, nil);
    size_t const before = samples.size();
    BOOL allEmpty = YES;
    for (auto const& x : samples) allEmpty = allEmpty && x.peers == 0 && x.seeds == 0 && x.buffering == 0 && !x.hasMetadata;
    double const clock = s.timeSinceStart, harnessClock = -[t0 timeIntervalSinceNow];
    check(before >= 10 && before <= 14 && allEmpty, @"status every 0.5 s before the metadata, 0 peers",
          [NSString stringWithFormat:@"%zu callbacks and %d notifications in 6 s (before: none until the metadata), all 0 peers / 0 %% / no metadata: %d",
           before, notifications, allEmpty]);
    check(!s.hasMetadata && fabs(clock - harnessClock) < 0.5 && samples.size() > 1 && samples.back().sinceStart > 5,
          @"timeSinceStart follows the stream's clock",
          [NSString stringWithFormat:@"timeSinceStart %.2f s, harness %.2f s, last callback's %.2f s", clock, harnessClock,
           samples.empty() ? 0.0 : samples.back().sinceStart]);

    // 2. The seeder starts (late), its upload capped at 8 KiB/s, and the stream is told about it.
    lt::torrent_handle seed = seeder.seed(p, 8 << 10);
    double const seederAt = -[t0 timeIntervalSinceNow];
    spin(60, ^BOOL { nudge(s, seederPort); return s.hasMetadata || r->failure != nil; });
    double const metadataAt = -[t0 timeIntervalSinceNow];
    int withPeers = 0, withRate = 0, maxPeers = 0, maxRate = 0;
    for (size_t i = before; i < samples.size(); ++i) {
        auto const& x = samples[i];
        if (x.hasMetadata) continue;
        if (x.peers > 0) { withPeers++; maxPeers = std::max(maxPeers, x.peers); }
        if (x.peers > 0 && x.rate > 0) { withRate++; maxRate = std::max(maxRate, x.rate); }
    }
    check(s.hasMetadata && withPeers >= 2 && withRate >= 1, @"the late seeder shows before the metadata",
          [NSString stringWithFormat:@"seeder at %.1f s, metadata at %.1f s; %d callbacks before it with peers (max %d), %d with a download rate (max %d B/s)",
           seederAt, metadataAt, withPeers, maxPeers, withRate, maxRate]);
    check(s.hasMetadata && s.fileName.length > 0 && s.storageMode == PTStorageModeFull, @"hasMetadata: the file is chosen",
          [NSString stringWithFormat:@"%@, %lld bytes, mode %ld", s.fileName, s.fileSize.longLongValue, (long)s.storageMode]);

    // 3. One loop: with the seeder at 1 B/s (no piece, no piece alert; still connected) 2
    // callbacks a second, not 4.
    seed.set_upload_limit(1);
    spin(1, nil);
    size_t const pausedFrom = samples.size();
    spin(4, nil);
    size_t const pausedCount = samples.size() - pausedFrom;
    check(pausedCount >= 6 && pausedCount <= 10, @"one monitor loop after the metadata",
          [NSString stringWithFormat:@"%zu callbacks in 4 s with no piece coming (two loops: about 16)", pausedCount]);

    // 4. The seeder, unlimited: ready, the right bytes.
    seed.set_upload_limit(0);
    BOOL ready = waitReady(s, r, seederPort, 60);
    check(ready && r->failure == nil, @"ready after the metadata", describe(s));
    if (ready) {
        NSInteger status = 0;
        NSData *httpHead = httpGet(r->url.port.intValue, s.fileName, 0, 65536, &status, 30);
        check([httpHead isEqualToData:head], @"serves the right bytes", [NSString stringWithFormat:@"HTTP %ld, head matches %d", (long)status, [httpHead isEqualToData:head]]);
    }

    // 5. Cancel: no more status, no loading state.
    [s cancelStreamingAndDeleteData:YES];
    size_t const atCancel = samples.size();
    int const notesAtCancel = notifications;
    spin(2, nil);
    check(samples.size() == atCancel && notifications == notesAtCancel && !s.hasMetadata && s.timeSinceStart == 0,
          @"nothing after a cancel", [NSString stringWithFormat:@"%zu callbacks and %d notifications in 2 s; hasMetadata %d, timeSinceStart %.2f",
                                       samples.size() - atCancel, notifications - notesAtCancel, s.hasMetadata, s.timeSinceStart]);
    [[NSNotificationCenter defaultCenter] removeObserver:observer];

    // 6. The same torrent from its .torrent file: metadata at once; status as before.
    auto r2 = std::make_shared<StreamResult>();
    __block int fileCallbacks = 0;
    PTTorrentStreamer *f = [PTTorrentStreamer new];
    f.downloadDirectoryOverride = downloads;
    [f startStreamingFromMultiTorrentFileOrMagnetLink:p.torrent
        progress:^(PTTorrentStatus st) { fileCallbacks++; }
        readyToPlay:^(NSURL *url, NSURL *file) { r2->ready = YES; }
        failure:^(NSError *error) { r2->failure = error.localizedDescription; }
        selectFileToStream:^int(NSArray<NSString *> *names, NSArray<NSNumber *> *sizes) { return 0; }];
    BOOL const fileMetadata = f.hasMetadata;
    BOOL const fileReady = waitReady(f, r2, seederPort, 60);
    check(fileMetadata && fileReady && fileCallbacks > 0, @"a .torrent file has its metadata at start",
          [NSString stringWithFormat:@"hasMetadata right after start %d, ready %d, %d callbacks", fileMetadata, fileReady, fileCallbacks]);
    [f cancelStreamingAndDeleteData:YES];

    // 7. A download of a magnet nobody answers: no status before its metadata, as before.
    Payload lone = makePayload(work, @"premeta-lone", 1LL << 20, 16 << 10, false);
    PTTorrentDownload *d = makeDownload(magnetFor(lone), [work stringByAppendingPathComponent:@"offline"], @"tt0000002");
    spin(3, nil);
    check(d.downloadStatus == PTTorrentDownloadStatusProcessing && d.torrentStatus.totalProgress == 0 && !d.hasMetadata,
          @"a download of a magnet stays Processing before its metadata",
          [NSString stringWithFormat:@"status %ld after 3 s (Processing = %ld)", (long)d.downloadStatus, (long)PTTorrentDownloadStatusProcessing]);
    [d stop];
    spin(1, nil);
    return 0;
}

/// The network settings of a profile (see PTNetworkTuning in PTtorrentsSession.mm), the default
/// trackers, and the piece order: streams in order, an offline download rarest first until a
/// stream joins it. `profile`: "tv", "ios", "mac" or nil (this Mac).
static int runNetwork(NSString *work, NSString *profile) {
    NSString *expected = profile ?: @"mac";
    NSDictionary<NSString *, NSNumber *> *net = [[PTTorrentsSession sharedSession] networkSettingsForTesting];
    logf(@"profile %@: %@", expected, [[net description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "]);
    NSDictionary<NSString *, NSArray<NSNumber *> *> *values = @{
        // torrent_connections, connections_limit, connection_speed, torrent_connect_boost, max_queued_disk_bytes, max_out_request_queue
        @"tv":  @[@100, @200, @40, @40, @(4 << 20), @500],
        @"ios": @[@80, @160, @30, @30, @(2 << 20), @500],
        @"mac": @[@100, @400, @50, @50, @(16 << 20), @1000],
    };
    NSArray<NSNumber *> *v = values[expected];
    // libtorrent caps connections_limit at 80 % of (open files - 20) when the session is
    // created: the fork raises the soft limit to 4096 (or the hard limit) first, so a run under
    // `ulimit -S -n 256` (an app launched from the Finder) gets the profile's value; under a
    // hard limit of 256, the cap.
    long long const files = [net[@"open_files_limit"] longLongValue];
    struct rlimit rl;
    getrlimit(RLIMIT_NOFILE, &rl);
    long long const hard = rl.rlim_max == RLIM_INFINITY ? LLONG_MAX : (long long)rl.rlim_max;
    check(files >= std::min(4096LL, hard), @"open files limit raised", [NSString stringWithFormat:@"soft %lld, hard %lld", files, hard]);
    long long const cap = std::max(5LL, (std::min(files, (long long)INT_MAX) - 20) * 8 / 10);
    NSNumber *expectedLimit = @(std::min([v[1] longLongValue], cap));
    BOOL const tuned = [net[@"torrent_connections"] isEqual:v[0]] && [net[@"connections_limit"] isEqual:expectedLimit]
        && [net[@"connection_speed"] isEqual:v[2]] && [net[@"torrent_connect_boost"] isEqual:v[3]]
        && [net[@"max_queued_disk_bytes"] isEqual:v[4]] && [net[@"max_out_request_queue"] isEqual:v[5]];
    check(tuned, [NSString stringWithFormat:@"%@ profile limits", expected],
          [NSString stringWithFormat:@"peers %@/torrent, %@ in all, %@ connects/s, boost %@, disk queue %@, request queue %@",
           net[@"torrent_connections"], net[@"connections_limit"], net[@"connection_speed"], net[@"torrent_connect_boost"],
           net[@"max_queued_disk_bytes"], net[@"max_out_request_queue"]]);
    check([net[@"announce_to_all_tiers"] boolValue] && [net[@"announce_to_all_trackers"] boolValue]
          && [net[@"peer_connect_timeout"] intValue] == 10 && [net[@"utp_connect_timeout"] intValue] == 1500 && [net[@"file_pool_size"] intValue] == 8
          && [net[@"request_queue_time"] intValue] == 2 && [net[@"whole_pieces_threshold"] intValue] == 0,
          @"common settings", @"every tracker and tier, 10 s connect timeout, uTP 1.5 s, 8 open files, 2 s request queue, no whole pieces");
    // Loopback testing: nothing leaves 127.0.0.1, whatever the profile.
    check(![net[@"enable_upnp"] boolValue] && ![net[@"enable_natpmp"] boolValue] && ![net[@"enable_lsd"] boolValue] && ![net[@"enable_dht"] boolValue],
          @"offline session: no UPnP, NAT-PMP, LSD, DHT", @"");

    NSArray<NSString *> *trackers = [PTTorrentsSession trackersForTesting:@[@"udp://tracker.example.org:1337/announce", @"UDP://tracker.opentrackr.org:1337/announce/"]];
    check(trackers.count == 2 + 13 - 1 && [trackers[0] isEqualToString:@"udp://tracker.example.org:1337/announce"]
          && ![trackers containsObject:@"udp://tracker.opentrackr.org:1337/announce"] && [trackers containsObject:@"udp://open.demonii.com:1337/announce"],
          @"default trackers after the torrent's own, no duplicate", [NSString stringWithFormat:@"%lu trackers: %@", (unsigned long)trackers.count,
                                                                     [trackers componentsJoinedByString:@" "]]);

    NSDictionary<NSString *, NSNumber *> *keyed = @{
        @"udp://tracker.opentrackr.org:1337/announce": @NO, @"http://tracker.example.org:80/announce/": @NO,
        @"udp://tracker.example.org:6969": @NO, @"https://tracker.example.org/announce.php": @NO,
        @"https://tracker.example.org/announce.php?passkey=0123456789abcdef": @YES,
        @"https://tracker.example.org/0123456789abcdef0123456789abcdef/announce": @YES,
        @"http://tracker.example.org/announce?uk=abc": @YES,
    };
    NSMutableArray<NSString *> *wrongKeyed = [NSMutableArray array];
    for (NSString *url in keyed) {
        if ([PTTorrentsSession trackerLooksKeyedForTesting:url] != keyed[url].boolValue) [wrongKeyed addObject:url];
    }
    check(wrongKeyed.count == 0, @"magnets with a keyed tracker get the default trackers only after their metadata",
          wrongKeyed.count ? [wrongKeyed componentsJoinedByString:@" "] : @"plain /announce trackers: at once; passkeys in path or query: after");

    NSString *streams = [work stringByAppendingPathComponent:@"streams"];
    NSString *offline = [work stringByAppendingPathComponent:@"offline"];
    Seeder seeder;
    int const seederPort = seeder.port;
    Payload p = makePayload(work, @"net", 48LL << 20, 1 << 20);
    (void)seeder.seed(p, 1 << 20); // 1 MiB/s: still downloading during the checks

    PTTorrentDownload *d = makeDownload(p.torrent, offline, @"net-dl");
    spin(30, ^BOOL { nudge(d, seederPort); return d.torrentStatus.totalProgress > 0.05; });
    lt::torrent_status st = d.torrentHandle.status();
    std::vector<lt::announce_entry> const dlTrackers = d.torrentHandle.trackers();
    check(!(st.flags & lt::torrent_flags::sequential_download) && d.torrentHandle.max_connections() == [net[@"torrent_connections"] intValue]
          && dlTrackers.empty(),
          @"download: rarest first, peers per torrent, no tracker added (private, offline)",
          [NSString stringWithFormat:@"sequential %d, max connections %d, trackers %zu, %@", (int)(bool)(st.flags & lt::torrent_flags::sequential_download),
           d.torrentHandle.max_connections(), dlTrackers.size(), describe(d)]);

    auto rg = std::make_shared<StreamResult>();
    PTTorrentStreamer *g = [PTTorrentStreamer new];
    g.downloadDirectoryOverride = streams;
    startStream(g, p.torrent, rg, @"G");
    BOOL const ready = waitReady(g, rg, seederPort, 60);
    spin(1, nil);
    st = d.torrentHandle.status();
    check(ready && g.isGuest && (st.flags & lt::torrent_flags::sequential_download), @"a stream joins the download: in file order",
          [NSString stringWithFormat:@"ready %d, guest %d, sequential %d", ready, g.isGuest, (int)(bool)(st.flags & lt::torrent_flags::sequential_download)]);
    [g cancelStreamingAndDeleteData:YES];
    spin(1, nil);
    st = d.torrentHandle.status();
    check(!(st.flags & lt::torrent_flags::sequential_download) && d.downloadStatus != PTTorrentDownloadStatusFailed,
          @"the stream leaves: rarest first again", describe(d));
    [d stop];

    Payload p2 = makePayload(work, @"net2", 24LL << 20, 1 << 20);
    (void)seeder.seed(p2, 4 << 20);
    auto rs = std::make_shared<StreamResult>();
    PTTorrentStreamer *s = [PTTorrentStreamer new];
    s.downloadDirectoryOverride = streams;
    startStream(s, p2.torrent, rs, @"S");
    BOOL const readyS = waitReady(s, rs, seederPort, 60);
    st = s.torrentHandle.status();
    check(readyS && (st.flags & lt::torrent_flags::sequential_download) && s.torrentHandle.max_connections() == [net[@"torrent_connections"] intValue],
          @"stream: in file order, peers per torrent",
          [NSString stringWithFormat:@"ready %d, sequential %d, max connections %d", readyS, (int)(bool)(st.flags & lt::torrent_flags::sequential_download),
           s.torrentHandle.max_connections()]);
    if (readyS) {
        NSString *detail = nil;
        check(readAndCompare(rs->url.port.intValue, s.fileName, p2, 0, p2.size, 60, &detail), @"stream reads the whole file", detail);
    }
    [s cancelStreamingAndDeleteData:YES];
    spin(1, nil);
    return 0;
}

#pragma mark - nofile

/// A public season pack (a magnet: its metadata comes from the seeder), 8 MiB per episode in
/// Show.S01.PACK/, and its seeder.
static Payload makePack(NSString *work, NSArray<NSString *> *names) {
    NSString *seedRoot = [work stringByAppendingPathComponent:@"seed-pack"];
    NSString *pack = [seedRoot stringByAppendingPathComponent:@"Show.S01.PACK"];
    [[NSFileManager defaultManager] createDirectoryAtPath:pack withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *name in names) {
        std::vector<char> buf(8 << 20);
        arc4random_buf(buf.data(), buf.size());
        std::ofstream out([pack stringByAppendingPathComponent:name].fileSystemRepresentation, std::ios::binary);
        out.write(buf.data(), (std::streamsize)buf.size());
    }
    lt::file_storage fs;
    lt::add_files(fs, pack.fileSystemRepresentation);
    lt::create_torrent ct(fs, 256 << 10);
    ct.set_priv(false); // a magnet: its metadata comes from the seeder
    lt::set_piece_hashes(ct, seedRoot.fileSystemRepresentation);
    std::vector<char> bytes;
    lt::bencode(std::back_inserter(bytes), ct.generate());
    Payload p;
    p.dir = seedRoot;
    p.ti = std::make_shared<lt::torrent_info>(bytes.data(), (int)bytes.size());
    return p;
}

/// The index of the file whose path ends with `name`, -1 when none.
static int packIndex(Payload const& p, NSString *name) {
    for (int i = 0; i < p.ti->num_files(); ++i) {
        NSString *path = [NSString stringWithUTF8String:p.ti->files().file_path(lt::file_index_t(i)).c_str()];
        if ([path.lastPathComponent isEqualToString:name]) return i;
    }
    return -1;
}

static NSArray<NSString *> *listing(NSString *dir) {
    return [[[NSFileManager defaultManager] subpathsOfDirectoryAtPath:dir error:nil] ?: @[] sortedArrayUsingSelector:@selector(compare:)];
}

static BOOL exists(NSString *path) { return [[NSFileManager defaultManager] fileExistsAtPath:path]; }

/// The variant that names the folder (what `resume` uses): here, to put two downloads in one
/// folder, as before downloads got their own.
@interface PTTorrentDownload (HarnessFolder)
- (void)startDownloadingFromFileOrMagnetLink:(NSString *)filePathOrMagnetLink directoryName:(nullable NSString *)directoryName
                         selectFileTDownload:(PTTorrentStreamerSelection)callback;
@end

/// A download of `index` (an episode's file) from `magnet`, into `folder` (nil: its own), run to
/// the end and saved as PTTorrentDownloadManager does when it finishes.
static PTTorrentDownload *downloadEpisode(NSString *magnet, NSString *downloads, NSString *folder, NSString *media,
                                          int index, int seederPort) {
    PTTorrentDownload *d = [[PTTorrentDownload alloc] initWithMediaMetadata:@{MPMediaItemPropertyPersistentID: media}
                                                             downloadStatus:PTTorrentDownloadStatusProcessing];
    d.downloadDirectoryOverride = downloads;
    [d startDownloadingFromFileOrMagnetLink:magnet directoryName:folder
                        selectFileTDownload:^int(NSArray<NSString *> *n, NSArray<NSNumber *> *z) { return index; }];
    spin(60, ^BOOL { nudge(d, seederPort); return d.downloadStatus == PTTorrentDownloadStatusFinished || d.downloadStatus == PTTorrentDownloadStatusFailed; });
    spin(1, nil);
    [d save];
    logf(@"download %@ (file %d): status %ld, %@ in %@", media, index, (long)d.downloadStatus, d.fileName, d.savePath.lastPathComponent);
    return d;
}

/// A download of `magnet` whose selection chooses no file, into `folder` (nil: its own): the
/// number of failures and the error code once it failed.
static int failNoFile(NSString *magnet, NSString *downloads, NSString *folder, NSString *media, int seederPort,
                      NSInteger *code, NSString **savePath) {
    PTTorrentDownload *d = [[PTTorrentDownload alloc] initWithMediaMetadata:@{MPMediaItemPropertyPersistentID: media}
                                                             downloadStatus:PTTorrentDownloadStatusProcessing];
    d.downloadDirectoryOverride = downloads;
    __block int failures = 0;
    __block NSInteger failureCode = 0;
    [d startDownloadingFromFileOrMagnetLink:magnet directoryName:folder
                        selectFileTDownload:^int(NSArray<NSString *> *n, NSArray<NSNumber *> *z) { return PTTorrentStreamerNoFileIndex; }];
    NSString *startPath = d.savePath;
    if (savePath) *savePath = startPath;
    PTTorrentStreamerFailure const inner = d.failureBlock;
    d.failureBlock = ^(NSError *error) { failures++; failureCode = error.code; if (inner) inner(error); };
    spin(20, ^BOOL { nudge(d, seederPort); return failures > 0; });
    spin(3, nil); // libtorrent's deletion of what the early pieces wrote
    // Its own folder goes with it: later under load (every mode of the harness at once).
    if (folder == nil && startPath) spin(10, ^BOOL { return !exists(startPath); });
    if (code) *code = failureCode;
    return failures;
}

/// A download of a public two-episode pack, by magnet, whose selection chooses no file (the
/// episode is not in the pack): it fails once with PTTorrentStreamerErrorNoFileSelected, and
/// nothing of it stays in the download directory (before: a plist saved while it was
/// Processing, with the first pieces of the other episodes, listed again at the next launch
/// as a paused download that could never complete).
static int runNoFile(NSString *work) {
    NSString *seedRoot = [work stringByAppendingPathComponent:@"seed-pack"];
    NSString *pack = [seedRoot stringByAppendingPathComponent:@"Show.S01.PACK"];
    [[NSFileManager defaultManager] createDirectoryAtPath:pack withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *name in @[@"Show.S01E01.mkv", @"Show.S01E02.mkv"]) {
        std::vector<char> buf(8 << 20);
        arc4random_buf(buf.data(), buf.size());
        std::ofstream out([pack stringByAppendingPathComponent:name].fileSystemRepresentation, std::ios::binary);
        out.write(buf.data(), (std::streamsize)buf.size());
    }
    lt::file_storage fs;
    lt::add_files(fs, pack.fileSystemRepresentation);
    lt::create_torrent ct(fs, 256 << 10);
    ct.set_priv(false); // a magnet: its metadata comes from the seeder
    lt::set_piece_hashes(ct, seedRoot.fileSystemRepresentation);
    std::vector<char> bytes;
    lt::bencode(std::back_inserter(bytes), ct.generate());
    Payload p;
    p.dir = seedRoot;
    p.ti = std::make_shared<lt::torrent_info>(bytes.data(), (int)bytes.size());
    Seeder seeder;
    int const seederPort = seeder.port;
    (void)seeder.seed(p, 0);

    NSString *downloads = [work stringByAppendingPathComponent:@"offline"];
    PTTorrentDownload *d = [[PTTorrentDownload alloc] initWithMediaMetadata:@{MPMediaItemPropertyPersistentID: @"nofile"}
                                                             downloadStatus:PTTorrentDownloadStatusProcessing];
    d.downloadDirectoryOverride = downloads;
    __block int failures = 0;
    __block NSInteger code = 0;
    __block int selections = 0;
    [d startDownloadingFromFileOrMagnetLink:magnetFor(p) selectFileTDownload:^int(NSArray<NSString *> *n, NSArray<NSNumber *> *z) {
        selections++;
        return PTTorrentStreamerNoFileIndex;
    }];
    // The failure block is the streamer's: wrap it to count (it reaches the manager's delegate).
    PTTorrentStreamerFailure const inner = d.failureBlock;
    d.failureBlock = ^(NSError *error) { failures++; code = error.code; if (inner) inner(error); };
    spin(20, ^BOOL { nudge(d, seederPort); return failures > 0; });
    spin(3, nil); // libtorrent's deletion of what the early pieces wrote
    NSArray<NSString *> *left = [[NSFileManager defaultManager] subpathsOfDirectoryAtPath:downloads error:nil] ?: @[];
    check(failures == 1 && code == PTTorrentStreamerErrorNoFileSelected && selections == 1 && d.downloadStatus == PTTorrentDownloadStatusFailed,
          @"a pack without the episode: the download fails once",
          [NSString stringWithFormat:@"%d failures, code %ld, %d selections, status %ld", failures, (long)code, selections, (long)d.downloadStatus]);
    check(left.count == 0, @"nothing of it stays (no plist to list at the next launch)",
          left.count ? [left componentsJoinedByString:@", "] : @"download directory empty");

    // Another episode of the same pack, downloaded before (E01, finished), then the pack chosen
    // for an episode it lacks: the failure deletes nothing of E01.
    NSString *magnet = magnetFor(p);
    int const i1 = packIndex(p, @"Show.S01E01.mkv");
    NSString *plistName = [NSString stringWithFormat:@"Metadata-file-%d.plist", i1];
    PTTorrentDownload *e01 = downloadEpisode(magnet, downloads, nil, @"show-s01e01", i1, seederPort);
    NSString *e01Folder = e01.savePath;
    NSString *e01File = [e01Folder stringByAppendingPathComponent:@"Show.S01.PACK/Show.S01E01.mkv"];
    NSString *e01Plist = [e01Folder stringByAppendingPathComponent:plistName];
    NSInteger otherCode = 0;
    NSString *otherFolder = nil;
    int const otherFailures = failNoFile(magnet, downloads, nil, @"show-s01e09", seederPort, &otherCode, &otherFolder);
    check(otherFailures == 1 && otherCode == PTTorrentStreamerErrorNoFileSelected && ![otherFolder isEqualToString:e01Folder]
          && exists(e01File) && exists(e01Plist) && !exists(otherFolder),
          @"a finished episode of the pack stays when the pack lacks another one (a folder each)",
          [NSString stringWithFormat:@"%d failures, code %ld; E01 folder %@, failed download's %@ (gone %d); E01 file %d plist %d",
           otherFailures, (long)otherCode, e01Folder.lastPathComponent, otherFolder.lastPathComponent, !exists(otherFolder),
           exists(e01File), exists(e01Plist)]);

    // The same in a folder both share (downloads made before each had its own): no file of the
    // torrent is deleted (libtorrent's delete_files would delete E01 too), no plist is written.
    NSString *shared = @"shared-before-5.2";
    PTTorrentDownload *s01 = downloadEpisode(magnet, downloads, shared, @"legacy-s01e01", i1, seederPort);
    NSString *sharedFolder = s01.savePath;
    NSString *sharedFile = [sharedFolder stringByAppendingPathComponent:@"Show.S01.PACK/Show.S01E01.mkv"];
    NSString *sharedPlist = [sharedFolder stringByAppendingPathComponent:plistName];
    int const sharedFailures = failNoFile(magnet, downloads, shared, @"legacy-s01e09", seederPort, &otherCode, nil);
    NSArray<NSString *> *sharedLeft = listing(sharedFolder);
    check(sharedFailures == 1 && exists(sharedFile) && exists(sharedPlist)
          && ![sharedLeft containsObject:@"Metadata-file--1.plist"] && s01.downloadStatus == PTTorrentDownloadStatusFinished,
          @"in a shared folder too: the finished episode and its plist stay, no plist for the failed one",
          [NSString stringWithFormat:@"%d failures; E01 file %d plist %d; folder: %@", sharedFailures, exists(sharedFile), exists(sharedPlist),
           [sharedLeft componentsJoinedByString:@", "]]);
    return 0;
}

#pragma mark - packs

/// Two episodes of one season pack downloaded one after the other (E03, then E01, which sorts
/// first in a folder): with a folder each, and in one folder (downloads made before 5.2.0).
/// Reloaded from its plist (the next launch), each plays its own episode; deleting one, or
/// stopping one still downloading, keeps the other.
static int runPacks(NSString *work) {
    Payload p = makePack(work, @[@"Show.S01E01.mkv", @"Show.S01E02.mkv", @"Show.S01E03.mkv"]);
    Seeder seeder;
    int const seederPort = seeder.port;
    (void)seeder.seed(p, 2 << 20); // 2 MiB/s: E02 is stopped while it downloads
    NSString *magnet = magnetFor(p);
    int const i1 = packIndex(p, @"Show.S01E01.mkv"), i2 = packIndex(p, @"Show.S01E02.mkv"), i3 = packIndex(p, @"Show.S01E03.mkv");
    NSString *downloads = [work stringByAppendingPathComponent:@"offline"];

    for (NSString *shared in @[@"", @"shared-before-5.2"]) {
        NSString *how = shared.length ? @"shared folder" : @"a folder each";
        NSString *folder = shared.length ? shared : nil;
        NSString *tag = shared.length ? @"legacy-" : @"";
        PTTorrentDownload *e03 = downloadEpisode(magnet, downloads, folder, [tag stringByAppendingString:@"show-s01e03"], i3, seederPort);
        PTTorrentDownload *e01 = downloadEpisode(magnet, downloads, folder, [tag stringByAppendingString:@"show-s01e01"], i1, seederPort);
        NSString *plist03 = [e03.savePath stringByAppendingPathComponent:[NSString stringWithFormat:@"Metadata-file-%d.plist", i3]];
        NSString *plist01 = [e01.savePath stringByAppendingPathComponent:[NSString stringWithFormat:@"Metadata-file-%d.plist", i1]];
        // Their bytes, not only their files: a download that took libtorrent's "finished" for
        // its own was kept as finished with its file a hole (in the shared folder, E01 started
        // finished: the folder's resume data wanted E03 alone).
        NSString *source03 = sha256OfFile([p.dir stringByAppendingPathComponent:@"Show.S01.PACK/Show.S01E03.mkv"]);
        NSString *source01 = sha256OfFile([p.dir stringByAppendingPathComponent:@"Show.S01.PACK/Show.S01E01.mkv"]);
        BOOL const bytes03 = [sha256OfFile([e03.savePath stringByAppendingPathComponent:@"Show.S01.PACK/Show.S01E03.mkv"]) isEqualToString:source03];
        BOOL const bytes01 = [sha256OfFile([e01.savePath stringByAppendingPathComponent:@"Show.S01.PACK/Show.S01E01.mkv"]) isEqualToString:source01];
        check(e03.downloadStatus == PTTorrentDownloadStatusFinished && e01.downloadStatus == PTTorrentDownloadStatusFinished
              && bytes03 && bytes01 && ([e03.savePath isEqualToString:e01.savePath] == (shared.length > 0)),
              [NSString stringWithFormat:@"%@: both episodes downloaded, with their bytes", how],
              [NSString stringWithFormat:@"E03 %@ in %@: %@; E01 %@ in %@: %@", bytes03 ? @"right bytes" : @"WRONG BYTES", e03.savePath.lastPathComponent,
               [listing(e03.savePath) componentsJoinedByString:@", "], bytes01 ? @"right bytes" : @"WRONG BYTES",
               e01.savePath.lastPathComponent, [listing(e01.savePath) componentsJoinedByString:@", "]]);

        // The next launch: one download per plist.
        PTTorrentDownload *r03 = [[PTTorrentDownload alloc] initFromPlist:plist03];
        PTTorrentDownload *r01 = [[PTTorrentDownload alloc] initFromPlist:plist01];
        check([r03.fileName.lastPathComponent isEqualToString:@"Show.S01E03.mkv"] && [r01.fileName.lastPathComponent isEqualToString:@"Show.S01E01.mkv"]
              && r03.downloadStatus == PTTorrentDownloadStatusFinished && r01.downloadStatus == PTTorrentDownloadStatusFinished,
              [NSString stringWithFormat:@"%@: reloaded from its plist, each download plays its own episode", how],
              [NSString stringWithFormat:@"E03 plist -> %@, E01 plist -> %@", r03.fileName, r01.fileName]);

        // The user deletes E01 (PTTorrentDownloadManager deleteDownload: -> delete).
        BOOL const deleted = [r01 delete];
        NSString *file03 = [e03.savePath stringByAppendingPathComponent:@"Show.S01.PACK/Show.S01E03.mkv"];
        NSString *file01 = [e01.savePath stringByAppendingPathComponent:@"Show.S01.PACK/Show.S01E01.mkv"];
        check(deleted && exists(file03) && exists(plist03) && !exists(file01) && !exists(plist01),
              [NSString stringWithFormat:@"%@: deleting E01 keeps E03, and deletes E01", how],
              [NSString stringWithFormat:@"delete %d; E03 file %d plist %d; E01 file %d plist %d; left: %@", deleted, exists(file03), exists(plist03),
               exists(file01), exists(plist01), [listing(e03.savePath) componentsJoinedByString:@", "]]);

        // E02 starts downloading next to E03 and is stopped (PTTorrentDownloadManager stopDownload:).
        PTTorrentDownload *e02 = [[PTTorrentDownload alloc] initWithMediaMetadata:@{MPMediaItemPropertyPersistentID: [tag stringByAppendingString:@"show-s01e02"]}
                                                                   downloadStatus:PTTorrentDownloadStatusProcessing];
        e02.downloadDirectoryOverride = downloads;
        [e02 startDownloadingFromFileOrMagnetLink:magnet directoryName:folder
                              selectFileTDownload:^int(NSArray<NSString *> *n, NSArray<NSNumber *> *z) { return i2; }];
        spin(30, ^BOOL { nudge(e02, seederPort); return e02.fileName != nil && e02.torrentStatus.totalProgress > 0.2; });
        NSString *folder02 = e02.savePath;
        BOOL const stoppedWhileDownloading = e02.downloadStatus == PTTorrentDownloadStatusDownloading;
        [e02 stop];
        spin(3, nil); // libtorrent's deletion, and the writes in flight
        check(stoppedWhileDownloading && exists(file03) && exists(plist03) && !exists([folder02 stringByAppendingPathComponent:@"Show.S01.PACK/Show.S01E02.mkv"])
              && (shared.length > 0 || !exists(folder02)),
              [NSString stringWithFormat:@"%@: stopping E02 keeps E03, and deletes E02", how],
              [NSString stringWithFormat:@"stopped while downloading %d; E03 file %d plist %d; E02 folder %@ (exists %d): %@", stoppedWhileDownloading,
               exists(file03), exists(plist03), folder02.lastPathComponent, exists(folder02), [listing(folder02) componentsJoinedByString:@", "]]);

        // E03 deleted last: its folder goes.
        BOOL const deleted03 = [r03 delete];
        check(deleted03 && !exists(e03.savePath), [NSString stringWithFormat:@"%@: the last download deleted takes its folder", how],
              [NSString stringWithFormat:@"delete %d, folder %@ exists %d: %@", deleted03, e03.savePath.lastPathComponent, exists(e03.savePath),
               [listing(e03.savePath) componentsJoinedByString:@", "]]);
    }
    return 0;
}

#pragma mark - trackers

static NSArray<NSString *> *trackerURLs(PTTorrentStreamer *s) {
    NSMutableArray<NSString *> *urls = [NSMutableArray array];
    lt::torrent_handle h = s.torrentHandle;
    if (!h.is_valid()) return urls;
    for (lt::announce_entry const& entry : h.trackers()) [urls addObject:[NSString stringWithUTF8String:entry.url.c_str()]];
    return urls;
}

/// The default trackers as a real session adds them, here loopback ones nobody answers (the
/// session announces to 127.0.0.1:9 only): a plain magnet gets them at once; a magnet whose
/// tracker carries a key only once its metadata says the torrent is public; a private torrent
/// never (BEP 27). Then UPnP, NAT-PMP and LSD of each profile, before the loopback override.
static int runTrackers(NSString *work) {
    NSArray<NSString *> *defaults = [PTTorrentsSession setDefaultTrackersForTesting:@[
        @"http://127.0.0.1:9/announce", @"udp://127.0.0.1:9/announce", @"udp://tracker.example.org:1337/announce"]];
    check(defaults.count == 2, @"only loopback default trackers are accepted in tests", [defaults componentsJoinedByString:@", "]);
    NSString *downloads = [work stringByAppendingPathComponent:@"streams"];
    Payload p = makePayload(work, @"public", 8LL << 20, 256 << 10, false);
    Seeder seeder;
    int const seederPort = seeder.port;
    (void)seeder.seed(p, 0);
    NSString *keyed = @"http://127.0.0.1:9/0123456789abcdef0123456789abcdef/announce";
    auto hasDefaults = ^BOOL(NSArray<NSString *> *urls) {
        for (NSString *url in defaults) if (![urls containsObject:url]) return NO;
        return YES;
    };

    // A plain magnet (no tracker that carries a key): the default trackers at once.
    auto ra = std::make_shared<StreamResult>();
    PTTorrentStreamer *a = [PTTorrentStreamer new];
    a.downloadDirectoryOverride = downloads;
    startStream(a, magnetFor(p), ra, @"A");
    NSArray<NSString *> *atStart = trackerURLs(a);
    BOOL const readyA = waitReady(a, ra, seederPort, 30);
    check(readyA && hasDefaults(atStart), @"a plain magnet gets the default trackers at once",
          [NSString stringWithFormat:@"ready %d, trackers at start: %@", readyA, [atStart componentsJoinedByString:@", "]]);
    [a cancelStreamingAndDeleteData:YES];

    // The same public torrent from a magnet with a keyed tracker: its own tracker only, until
    // its metadata; then the default ones after it.
    NSString *keyedMagnet = [magnetFor(p) stringByAppendingFormat:@"&tr=%@",
                             [keyed stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet]];
    auto rb = std::make_shared<StreamResult>();
    PTTorrentStreamer *b = [PTTorrentStreamer new];
    b.downloadDirectoryOverride = downloads;
    startStream(b, keyedMagnet, rb, @"B");
    NSArray<NSString *> *beforeMetadata = trackerURLs(b);
    BOOL const readyB = waitReady(b, rb, seederPort, 30);
    spin(1, nil); // add_tracker runs on libtorrent's network thread
    NSArray<NSString *> *afterMetadata = trackerURLs(b);
    check(readyB && [beforeMetadata isEqualToArray:@[keyed]] && afterMetadata.count == 1 + defaults.count
          && [afterMetadata.firstObject isEqualToString:keyed] && hasDefaults(afterMetadata),
          @"a magnet with a keyed tracker gets the default trackers once its metadata says it is public",
          [NSString stringWithFormat:@"ready %d; before the metadata: %@; after: %@", readyB,
           [beforeMetadata componentsJoinedByString:@", "], [afterMetadata componentsJoinedByString:@", "]]);
    [b cancelStreamingAndDeleteData:YES];

    // A private .torrent with that tracker: never the default ones.
    Payload q = makePayload(work, @"private", 8LL << 20, 256 << 10, true);
    {
        lt::file_storage fs;
        lt::add_files(fs, q.path.fileSystemRepresentation);
        lt::create_torrent ct(fs, 256 << 10);
        ct.set_priv(true);
        ct.add_tracker(keyed.UTF8String);
        lt::set_piece_hashes(ct, q.dir.fileSystemRepresentation);
        std::vector<char> bytes;
        lt::bencode(std::back_inserter(bytes), ct.generate());
        std::ofstream t(q.torrent.fileSystemRepresentation, std::ios::binary | std::ios::trunc);
        t.write(bytes.data(), (std::streamsize)bytes.size());
        t.close();
        q.ti = std::make_shared<lt::torrent_info>(std::string(q.torrent.fileSystemRepresentation));
    }
    (void)seeder.seed(q, 0);
    auto rc = std::make_shared<StreamResult>();
    PTTorrentStreamer *c = [PTTorrentStreamer new];
    c.downloadDirectoryOverride = downloads;
    startStream(c, q.torrent, rc, @"C");
    BOOL const readyC = waitReady(c, rc, seederPort, 30);
    spin(1, nil);
    NSArray<NSString *> *privateTrackers = trackerURLs(c);
    check(readyC && [privateTrackers isEqualToArray:@[keyed]], @"a private torrent never gets the default trackers",
          [NSString stringWithFormat:@"ready %d, trackers: %@", readyC, [privateTrackers componentsJoinedByString:@", "]]);
    [c cancelStreamingAndDeleteData:YES];
    [PTTorrentsSession setDefaultTrackersForTesting:@[]];

    // UPnP / NAT-PMP / LSD per profile: the Apple TV and the Mac open their port on the router
    // and look for peers on the local network; iOS does neither (no local network prompt).
    NSDictionary<NSString *, NSNumber *> *expected = @{@"tv": @YES, @"ios": @NO, @"mac": @YES};
    for (NSString *profile in @[@"tv", @"ios", @"mac"]) {
        NSDictionary<NSString *, NSNumber *> *settings = [PTTorrentsSession localNetworkSettingsForTesting:profile];
        BOOL const on = expected[profile].boolValue;
        check([settings[@"enable_upnp"] boolValue] == on && [settings[@"enable_natpmp"] boolValue] == on && [settings[@"enable_lsd"] boolValue] == on,
              [NSString stringWithFormat:@"%@ profile: port mapping and local discovery %@", profile, on ? @"on" : @"off"],
              settings.description);
    }
    return 0;
}

#pragma mark - restart

/// A stream cancelled with deleteData:YES and the same torrent started again at once (the
/// disk-full retry; on tvOS, playing the same pack again right after a close): libtorrent's
/// deletion of the first one's files ends with an rmdir of their folder, the folder the new
/// stream created while it waited. The new stream must keep it, and decide its storage as one
/// started later: here bounded storage allowed, with a reserve the 64 MiB file does not fit in.
static int runRestart(NSString *work) {
    NSString *downloads = [work stringByAppendingPathComponent:@"streams"];
    Payload p = makePayload(work, @"restart", 64LL << 20, 1 << 20);
    Seeder seeder;
    int const seederPort = seeder.port;
    (void)seeder.seed(p, 0);
    NSURL *workURL = [NSURL fileURLWithPath:work isDirectory:YES];
    NSNumber *freeNumber = nil;
    [workURL getResourceValue:&freeNumber forKey:NSURLVolumeAvailableCapacityKey error:nil];
    int64_t const reserve = std::max<int64_t>(0, freeNumber.longLongValue - (48LL << 20));
    auto configure = ^(PTTorrentStreamer *s) {
        s.downloadDirectoryOverride = downloads;
        s.allowsBoundedStorage = YES;
        s.storageReserve = reserve;
    };
    for (int round = 0; round < 3; ++round) {
        auto ra = std::make_shared<StreamResult>();
        PTTorrentStreamer *a = [PTTorrentStreamer new];
        a.downloadDirectoryOverride = downloads;
        startStream(a, p.torrent, ra, @"A");
        BOOL const readyA = waitReady(a, ra, seederPort, 60);
        [a cancelStreamingAndDeleteData:YES];
        auto rb = std::make_shared<StreamResult>();
        PTTorrentStreamer *b = [PTTorrentStreamer new];
        configure(b);
        startStream(b, p.torrent, rb, @"B");
        BOOL const folderB = exists(b.savePath);
        PTStorageMode const modeB = b.storageMode; // decided at once (a .torrent file has its metadata)
        NSString *savePathB = b.savePath;
        spin(1, nil);
        NSInteger const codeB = rb->failureCode;   // the failure block runs on the main queue
        BOOL const folderB1 = savePathB != nil && exists(savePathB);
        [b cancelStreamingAndDeleteData:YES];
        spin(3, nil);
        auto rc = std::make_shared<StreamResult>();
        PTTorrentStreamer *c = [PTTorrentStreamer new];
        configure(c);
        startStream(c, p.torrent, rc, @"C");
        PTStorageMode const modeC = c.storageMode;
        spin(1, nil);
        NSInteger const codeC = rc->failureCode;
        [c cancelStreamingAndDeleteData:YES];
        spin(3, nil);
        // C, started once the deletion is done, is refused: the file does not fit even bounded.
        check(readyA && folderB && modeB == modeC && codeB == codeC && codeC == PTTorrentStreamerErrorNotEnoughSpaceForBoundedStorage,
              [NSString stringWithFormat:@"round %d: a stream started again at once keeps its folder and decides its storage as a later one", round],
              [NSString stringWithFormat:@"B (at once) folder %d (1 s later %d) mode %ld code %ld | C (3 s later) mode %ld code %ld",
               folderB, folderB1, (long)modeB, (long)codeB, (long)modeC, (long)codeC]);
    }
    return 0;
}

#pragma mark - finish

/// Full mode: libtorrent's "finished" with pieces of the file missing. The gap a forward seek
/// (or a resume) leaves behind the reader is at priority 0 while the window ahead has missing
/// pieces (planWindow, holdGap); when the last wanted pieces pass before the stream's next
/// plan, libtorrent turns the torrent finished with the gap missing (and drops its seeds),
/// then back to downloading at that plan. Made here at once: every missing piece of the file
/// at priority 0. Not a finish: the torrent is never stopped with pieces missing, the file
/// completes with the right bytes, and the progress the stream reports never goes back and
/// reaches 1 only with the whole file (before: 1 at once, then the torrent paused for good).
static int runFinish(NSString *work) {
    NSString *downloads = [work stringByAppendingPathComponent:@"streams"];
    Payload p = makePayload(work, @"finish", 48LL << 20, 1 << 20);
    int const pieces = p.ti->num_pieces();
    Seeder seeder;
    int const seederPort = seeder.port;
    (void)seeder.seed(p, 4 << 20); // 4 MiB/s: about 12 s for the file
    auto r = std::make_shared<StreamResult>();
    PTTorrentStreamer *s = [PTTorrentStreamer new];
    s.downloadDirectoryOverride = downloads;
    // Every totalProgress the progress block gets (main queue), and whether 1 came early.
    NSMutableArray<NSNumber *> *published = [NSMutableArray array];
    __block BOOL oneWithPiecesMissing = NO;
    __weak PTTorrentStreamer *weakStreamer = s;
    [s startStreamingFromMultiTorrentFileOrMagnetLink:p.torrent
        progress:^(PTTorrentStatus status) {
            [published addObject:@(status.totalProgress)];
            lt::torrent_handle h = weakStreamer.torrentHandle;
            if (status.totalProgress >= 1 && h.is_valid() && h.status().num_pieces < pieces) oneWithPiecesMissing = YES;
        }
        readyToPlay:^(NSURL *url, NSURL *file) { r->url = url; r->ready = YES; logf(@"readyToPlay %@", url); }
        failure:^(NSError *error) { r->failure = error.localizedDescription; logf(@"failure %ld: %@", (long)error.code, error.localizedDescription); }
        selectFileToStream:^int(NSArray<NSString *> *names, NSArray<NSNumber *> *sizes) { return 0; }];
    BOOL const ready = waitReady(s, r, seederPort, 60);
    check(ready && s.storageMode == PTStorageModeFull, @"the stream is ready, in full mode", describe(s));
    lt::torrent_handle h = s.torrentHandle;

    // A third of the file missing: all of it at priority 0 at once.
    spin(60, ^BOOL { nudge(s, seederPort); return h.status().num_pieces >= pieces * 2 / 3; });
    lt::torrent_status before = h.status();
    std::vector<std::pair<lt::piece_index_t, lt::download_priority_t>> unwanted;
    for (int i = 0; i < pieces; ++i) {
        if (!before.pieces.get_bit(lt::piece_index_t(i))) unwanted.push_back({lt::piece_index_t(i), lt::dont_download});
    }
    float const progressBefore = s.torrentStatus.totalProgress;
    h.prioritize_pieces(unwanted);
    logf(@"%zu of %d pieces missing, set to priority 0 (progress %.3f)", unwanted.size(), pieces, progressBefore);

    // Until the file is complete: never paused with pieces missing.
    __block BOOL pausedMissing = NO;
    __block BOOL sawFinished = NO;
    spin(90, ^BOOL {
        lt::torrent_status const st = h.status();
        if (st.is_finished && st.num_pieces < pieces) sawFinished = YES;
        if ((st.flags & lt::torrent_flags::paused) && st.num_pieces < pieces) pausedMissing = YES;
        if (!pausedMissing) nudge(s, seederPort); // the finish dropped the seeder
        return st.num_pieces == pieces || pausedMissing;
    });
    spin(2, nil); // the last alerts and progress
    lt::torrent_status const after = h.status();
    long long const early = [s.storageStatistics[@"earlyFinishes"] longLongValue];
    check(!unwanted.empty() && early >= 1, @"libtorrent's finish with pieces missing is seen as not a finish",
          [NSString stringWithFormat:@"%zu pieces at 0, earlyFinishes %lld (finished with pieces missing seen by the harness: %d)",
           unwanted.size(), early, sawFinished]);
    check(!pausedMissing && after.num_pieces == pieces, @"the torrent is never stopped with pieces missing, and the file completes",
          [NSString stringWithFormat:@"paused with pieces missing %d; %@", pausedMissing, describe(s)]);
    check(after.num_pieces == pieces && (bool)(after.flags & lt::torrent_flags::paused) && s.torrentStatus.totalProgress == 1,
          @"complete, the stream stops its torrent (no seeding) and reports 1", describe(s));

    float lowest = 1, highest = 0, drop = 0;
    for (NSNumber *value in published) {
        float const v = value.floatValue;
        highest = std::max(highest, v);
        drop = std::max(drop, highest - v);
        lowest = std::min(lowest, v);
    }
    check(published.count > 0 && drop < 1e-6f && !oneWithPiecesMissing && published.lastObject.floatValue == 1,
          @"the progress never goes back, and reaches 1 only with every piece",
          [NSString stringWithFormat:@"%lu values from %.3f to %.3f, largest drop %.3f, 1 with pieces missing %d, before the priorities %.3f",
           (unsigned long)published.count, lowest, published.lastObject.floatValue, drop, oneWithPiecesMissing, progressBefore]);

    // The pieces that were missing, served with the right bytes.
    int64_t const from = unwanted.empty() ? 0 : int64_t(static_cast<int>(unwanted.front().first)) << 20;
    NSString *detail = nil;
    BOOL const bytes = r->url && readAndCompare(r->url.port.intValue, s.fileName, p, from, p.size - from, 30, &detail);
    check(bytes, @"the pieces that were missing are served with the right bytes", detail ?: @"");
    [s cancelStreamingAndDeleteData:YES];
    spin(2, nil);
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr, "usage: SessionHarness zombie|starve|guest|background|legacy|premetadata|network|nofile|packs|restart|trackers|finish <workdir> [tv|ios|mac]\n"); return 2; }
        NSString *mode = [NSString stringWithUTF8String:argv[1]];
        NSString *work = [NSString stringWithUTF8String:argv[2]];
        [[NSFileManager defaultManager] removeItemAtPath:work error:nil];
        [[NSFileManager defaultManager] createDirectoryAtPath:work withIntermediateDirectories:YES attributes:nil error:nil];
        [PTTorrentsSession prepareSharedSessionForLoopbackTestingOnPort:0];
        NSString *profile = argc > 3 ? [NSString stringWithUTF8String:argv[3]] : nil;
        if (profile) [PTTorrentsSession setNetworkProfileForTesting:profile];
        int rc = 2;
        if ([mode isEqualToString:@"zombie"]) rc = runZombie(work);
        else if ([mode isEqualToString:@"starve"]) rc = runStarve(work);
        else if ([mode isEqualToString:@"guest"]) rc = runGuest(work);
        else if ([mode isEqualToString:@"background"]) rc = runBackground(work);
        else if ([mode isEqualToString:@"legacy"]) rc = runLegacy(work);
        else if ([mode isEqualToString:@"premetadata"]) rc = runPreMetadata(work);
        else if ([mode isEqualToString:@"network"]) rc = runNetwork(work, profile);
        else if ([mode isEqualToString:@"nofile"]) rc = runNoFile(work);
        else if ([mode isEqualToString:@"packs"]) rc = runPacks(work);
        else if ([mode isEqualToString:@"restart"]) rc = runRestart(work);
        else if ([mode isEqualToString:@"trackers"]) rc = runTrackers(work);
        else if ([mode isEqualToString:@"finish"]) rc = runFinish(work);
        logf(@"RESULT %@: %d passed, %d failed (rc %d)", mode, gPasses, gFailures, rc);
        [[NSFileManager defaultManager] removeItemAtPath:work error:nil];
        return gFailures > 0 ? 1 : rc;
    }
}
