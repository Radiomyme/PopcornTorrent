//
//  main.mm
//  NetworkBench
//
//  Offline download benchmark of the fork's session settings, never on the internet:
//  1. generates a file of pseudo-random data and a private torrent for it (no trackers);
//  2. seeds it from N libtorrent sessions on 127.0.0.1, each behind its own userspace TCP
//     proxy (also on 127.0.0.1) that delays both directions by half a round-trip time and
//     caps what the seeder sends (a token bucket with a bottleneck buffer of about 250 ms):
//     the request pipeline has a bandwidth-delay product to fill, like a real swarm;
//  3. downloads it with the fork, in one of these modes:
//       full      PTTorrentStreamer, the file fits (full storage)
//       bounded   PTTorrentStreamer, the file does not fit the volume (bounded storage;
//                 run it on a small disk image, see run_bench.sh)
//       download  PTTorrentDownload (an offline download)
//     A stream has a consumer reading through the streamer's HTTP server: at --read-mbs
//     MB/s (0: as fast as it comes), --read-mib MiB at most, releasing what it read
//     (consumedBefore) like the app;
//  4. prints the times: ready to play (streams), first MiB read, all read, file complete,
//     and the download rate every second.
//  The client is the streamer's shared session made loopback-only before its creation
//  (PTTorrentsSession+Testing.h): the production settings, without DHT, LSD, UPnP, NAT-PMP.
//  Run it under sandbox-exec with ../BoundedStorageHarness/localhost-only.sb.
//
//    NetworkBench --workdir DIR --volume DIR --mode full|bounded|download
//                 [--peers 40:1.5,60:1.5,...  (RTT ms : cap MB/s, 0 = no cap)]
//                 [--size-mib 1024] [--piece-kib 2048] [--read-mbs 0] [--read-mib 0 = all]
//                 [--timeout 600] [--profile tv|ios|mac] [--label NAME]
//

#import <Foundation/Foundation.h>
#import <MediaPlayer/MPMediaItem.h>
#import <objc/message.h>

#import "PTTorrentStreamer.h"
#import "PTTorrentStreamer+Protected.h"
#import "PTTorrentsSession.h"
#import "PTTorrentsSession+Testing.h"
#import "PTTorrentDownload.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdarg>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <libtorrent/session.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/bencode.hpp>
#include <libtorrent/hex.hpp>
#include <libtorrent/peer_info.hpp>

namespace lt = libtorrent;
using Clock = std::chrono::steady_clock;

static constexpr int64_t MiB = 1024 * 1024;

static Clock::time_point gStart = Clock::now();
static std::mutex gLogMutex;

static double since(Clock::time_point t) { return std::chrono::duration<double>(Clock::now() - t).count(); }

static void logLine(const char *format, ...) {
    std::lock_guard<std::mutex> lock(gLogMutex);
    va_list args;
    va_start(args, format);
    fprintf(stdout, "[%7.2f] ", since(gStart));
    vfprintf(stdout, format, args);
    fprintf(stdout, "\n");
    fflush(stdout);
    va_end(args);
}

#pragma mark - Options

struct PeerSpec { double rttMs; double rate; }; // rate in bytes/s, 0 = unlimited

struct Options {
    std::string mode = "full";
    std::string workdir;
    std::string volume;
    std::string label = "run";
    std::string profile;
    int64_t size = 1024 * MiB;
    int64_t pieceLength = 2 * MiB;
    double readRate = 0;      // bytes/s, 0 = as fast as it comes
    int64_t readBytes = 0;    // 0 = the whole file
    double timeout = 600;
    double seekAt = 0;        // streams: the consumer seeks when it reaches this fraction (0: never)
    double seekTo = 0;        // ... to this fraction of the file
    std::vector<PeerSpec> peers;
};

static std::vector<PeerSpec> parsePeers(std::string const& value) {
    std::vector<PeerSpec> peers;
    size_t start = 0;
    while (start < value.size()) {
        size_t const end = value.find(',', start);
        std::string const item = value.substr(start, end == std::string::npos ? std::string::npos : end - start);
        size_t const colon = item.find(':');
        PeerSpec spec;
        spec.rttMs = std::stod(item.substr(0, colon));
        spec.rate = colon == std::string::npos ? 0 : std::stod(item.substr(colon + 1)) * 1e6;
        peers.push_back(spec);
        if (end == std::string::npos) break;
        start = end + 1;
    }
    return peers;
}

static Options parseOptions(int argc, const char *argv[]) {
    Options o;
    for (int i = 1; i + 1 < argc; i += 2) {
        std::string const key = argv[i];
        std::string const value = argv[i + 1];
        if (key == "--mode") o.mode = value;
        else if (key == "--workdir") o.workdir = value;
        else if (key == "--volume") o.volume = value;
        else if (key == "--label") o.label = value;
        else if (key == "--profile") o.profile = value;
        else if (key == "--size-mib") o.size = std::stoll(value) * MiB;
        else if (key == "--piece-kib") o.pieceLength = std::stoll(value) * 1024;
        else if (key == "--read-mbs") o.readRate = std::stod(value) * 1e6;
        else if (key == "--read-mib") o.readBytes = std::stoll(value) * MiB;
        else if (key == "--timeout") o.timeout = std::stod(value);
        else if (key == "--peers") o.peers = parsePeers(value);
        else if (key == "--seek-at") o.seekAt = std::stod(value);
        else if (key == "--seek-to") o.seekTo = std::stod(value);
    }
    if (o.peers.empty()) o.peers = parsePeers("30:1.5,40:1.5,50:1.5,60:1.5,70:1.5,80:1.5,90:1.5,100:1.5");
    return o;
}

#pragma mark - Source file and torrent

static uint64_t splitmix(uint64_t x) {
    x += 0x9E3779B97F4A7C15ULL;
    x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ULL;
    x = (x ^ (x >> 27)) * 0x94D049BB133111EBULL;
    return x ^ (x >> 31);
}

static void fillBlock(uint64_t index, uint8_t *out, size_t length) {
    uint64_t state = splitmix(index + 7) | 1;
    size_t i = 0;
    for (; i + 8 <= length; i += 8) {
        state ^= state >> 12; state ^= state << 25; state ^= state >> 27;
        uint64_t const value = state * 0x2545F4914F6CDD1DULL;
        memcpy(out + i, &value, 8);
    }
    for (; i < length; ++i) out[i] = uint8_t(splitmix(index * 131 + i));
}

static bool prepareSource(Options const& o, std::string const& path) {
    struct stat info;
    if (stat(path.c_str(), &info) == 0 && info.st_size == o.size) return true;
    logLine("source: generating %lld MiB", o.size / MiB);
    int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return false;
    std::vector<uint8_t> block(static_cast<size_t>(MiB));
    for (int64_t offset = 0; offset < o.size; offset += MiB) {
        size_t const length = size_t(std::min<int64_t>(MiB, o.size - offset));
        fillBlock(uint64_t(offset / MiB), block.data(), length);
        if (write(fd, block.data(), length) != ssize_t(length)) { close(fd); return false; }
    }
    close(fd);
    return true;
}

static std::shared_ptr<lt::torrent_info> prepareTorrent(Options const& o, std::string const& sourcePath, std::string const& torrentPath) {
    lt::error_code ec;
    struct stat info;
    if (stat(torrentPath.c_str(), &info) == 0) {
        auto ti = std::make_shared<lt::torrent_info>(torrentPath, ec);
        if (!ec && ti->total_size() == o.size && ti->piece_length() == o.pieceLength) return ti;
    }
    logLine("torrent: hashing %s", sourcePath.c_str());
    lt::file_storage fs;
    lt::add_files(fs, sourcePath);
    lt::create_torrent ct(fs, int(o.pieceLength));
    ct.set_priv(true); // no DHT / PEX
    ct.set_creator("PopcornTorrent network bench");
    std::string const parent = sourcePath.substr(0, sourcePath.find_last_of('/'));
    lt::set_piece_hashes(ct, parent, ec);
    if (ec) return nullptr;
    std::vector<char> buffer;
    lt::bencode(std::back_inserter(buffer), ct.generate());
    FILE *f = fopen(torrentPath.c_str(), "wb");
    if (!f) return nullptr;
    fwrite(buffer.data(), 1, buffer.size(), f);
    fclose(f);
    auto ti = std::make_shared<lt::torrent_info>(torrentPath, ec);
    return ec ? nullptr : ti;
}

#pragma mark - Delay / rate proxy

/// One direction of a proxied connection: a reader thread timestamps what it receives, a
/// writer thread sends it `delay` seconds later, at most `rate` bytes/s (0: no cap), in
/// 16 KiB slices. At most `bufferCap` bytes wait in between (the bottleneck buffer): beyond
/// it the reader stops reading and TCP pushes back on the sender.
struct Pipe {
    struct Chunk { std::vector<uint8_t> data; Clock::time_point at; };
    int from = -1, to = -1;
    double delay = 0, rate = 0;
    size_t bufferCap = 4 * MiB;
    std::mutex mutex;
    std::condition_variable cv;
    std::deque<Chunk> queue;
    size_t queued = 0;
    bool eof = false;
    std::atomic<bool> dead{false};

    void kill() {
        dead = true;
        shutdown(from, SHUT_RDWR);
        shutdown(to, SHUT_RDWR);
        cv.notify_all();
    }

    void readLoop() {
        std::vector<uint8_t> buffer(64 * 1024);
        while (!dead) {
            ssize_t const n = recv(from, buffer.data(), buffer.size(), 0);
            std::unique_lock<std::mutex> lock(mutex);
            if (n <= 0) { eof = true; cv.notify_all(); break; }
            cv.wait(lock, [&] { return queued < bufferCap || dead; });
            if (dead) break;
            queue.push_back({std::vector<uint8_t>(buffer.begin(), buffer.begin() + n), Clock::now()});
            queued += size_t(n);
            cv.notify_all();
        }
    }

    void writeLoop() {
        Clock::time_point nextFree = Clock::now();
        while (!dead) {
            Chunk chunk;
            {
                std::unique_lock<std::mutex> lock(mutex);
                cv.wait(lock, [&] { return !queue.empty() || eof || dead; });
                if (dead) break;
                if (queue.empty()) { shutdown(to, SHUT_WR); break; } // eof, all sent
                chunk = std::move(queue.front());
                queue.pop_front();
            }
            std::this_thread::sleep_until(chunk.at + std::chrono::microseconds(int64_t(delay * 1e6)));
            size_t sent = 0;
            while (sent < chunk.data.size() && !dead) {
                size_t const slice = std::min<size_t>(16 * 1024, chunk.data.size() - sent);
                if (rate > 0) {
                    Clock::time_point const now = Clock::now();
                    if (nextFree > now) std::this_thread::sleep_until(nextFree);
                    nextFree = std::max(nextFree, now) + std::chrono::microseconds(int64_t(double(slice) / rate * 1e6));
                }
                ssize_t const n = send(to, chunk.data.data() + sent, slice, 0);
                if (n <= 0) { kill(); break; }
                sent += size_t(n);
            }
            {
                // Released once sent: the bytes waited in the bottleneck until then.
                std::lock_guard<std::mutex> lock(mutex);
                queued -= chunk.data.size();
                cv.notify_all();
            }
        }
    }
};

struct Proxy {
    int listenFd = -1;
    int port = 0;
    int upstreamPort = 0;
    PeerSpec spec;
    std::atomic<int64_t> downBytes{0};

    bool start(int upstream, PeerSpec s) {
        upstreamPort = upstream;
        spec = s;
        listenFd = socket(AF_INET, SOCK_STREAM, 0);
        int one = 1;
        setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        sockaddr_in address = {};
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(listenFd, (sockaddr *)&address, sizeof(address)) != 0) return false;
        if (listen(listenFd, 16) != 0) return false;
        socklen_t length = sizeof(address);
        getsockname(listenFd, (sockaddr *)&address, &length);
        port = ntohs(address.sin_port);
        std::thread([this] { acceptLoop(); }).detach();
        return true;
    }

    void acceptLoop() {
        while (true) {
            int const client = accept(listenFd, nullptr, nullptr);
            if (client < 0) return;
            int const upstream = socket(AF_INET, SOCK_STREAM, 0);
            sockaddr_in address = {};
            address.sin_family = AF_INET;
            address.sin_port = htons(uint16_t(upstreamPort));
            address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            if (connect(upstream, (sockaddr *)&address, sizeof(address)) != 0) { close(client); close(upstream); continue; }
            int one = 1;
            setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
            setsockopt(upstream, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
            setsockopt(upstream, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
            double const oneWay = spec.rttMs / 2000.0;
            auto up = std::make_shared<Pipe>();      // client -> seeder: requests
            up->from = client; up->to = upstream; up->delay = oneWay; up->rate = 0;
            auto down = std::make_shared<Pipe>();    // seeder -> client: blocks, capped
            down->from = upstream; down->to = client; down->delay = oneWay; down->rate = spec.rate;
            // Bottleneck buffer: about 250 ms at the cap (at least 256 KiB).
            down->bufferCap = spec.rate > 0 ? std::max<size_t>(256 * 1024, size_t(spec.rate * 0.25)) : 4 * MiB;
            std::thread([up] { up->readLoop(); }).detach();
            std::thread([up, down] { up->writeLoop(); if (up->dead) down->kill(); }).detach();
            std::thread([down] { down->readLoop(); }).detach();
            std::thread([up, down, client, upstream] {
                down->writeLoop();
                if (down->dead) up->kill();
                // Give the other direction a moment, then close both sockets.
                std::this_thread::sleep_for(std::chrono::seconds(2));
                up->kill();
                close(client);
                close(upstream);
            }).detach();
        }
    }
};

#pragma mark - HTTP consumer

struct HttpStream {
    int fd = -1;
    int status = 0;
    std::vector<uint8_t> pending;
    size_t pendingOffset = 0;

    bool open(int port, int64_t start, double timeoutSeconds) {
        fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return false;
        struct timeval tv = {long(timeoutSeconds), 0};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        sockaddr_in address = {};
        address.sin_family = AF_INET;
        address.sin_port = htons(uint16_t(port));
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (connect(fd, (sockaddr *)&address, sizeof(address)) != 0) { close(); return false; }
        char request[256];
        snprintf(request, sizeof(request), "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=%lld-\r\nConnection: close\r\n\r\n", start);
        if (send(fd, request, strlen(request), 0) != ssize_t(strlen(request))) { close(); return false; }
        std::string header;
        uint8_t buffer[8192];
        while (header.find("\r\n\r\n") == std::string::npos) {
            ssize_t const n = recv(fd, buffer, sizeof(buffer), 0);
            if (n <= 0) { close(); return false; }
            header.append((char *)buffer, size_t(n));
            if (header.size() > 65536) { close(); return false; }
        }
        size_t const end = header.find("\r\n\r\n") + 4;
        pending.assign(header.begin() + long(end), header.end());
        sscanf(header.c_str(), "HTTP/1.%*d %d", &status);
        return true;
    }

    int64_t readSome(uint8_t *out, int64_t length) {
        if (pendingOffset < pending.size()) {
            int64_t const n = std::min<int64_t>(length, int64_t(pending.size() - pendingOffset));
            memcpy(out, pending.data() + pendingOffset, size_t(n));
            pendingOffset += size_t(n);
            return n;
        }
        ssize_t const n = recv(fd, out, size_t(length), 0);
        return n;
    }

    void close() { if (fd >= 0) ::close(fd); fd = -1; }
};

#pragma mark - Run

static int gServerPort = 0;
static PTTorrentStreamer *gStreamer = nil;     // the stream, or the download
static PTTorrentDownload *gDownload = nil;
static lt::torrent_handle gHandle;

static int run(Options o) {
    std::string const sourceDir = o.workdir + "/source";
    mkdir(o.workdir.c_str(), 0755);
    mkdir(sourceDir.c_str(), 0755);
    char name[64];
    snprintf(name, sizeof(name), "bench-%lld-%lld", o.size / MiB, o.pieceLength / 1024);
    std::string const sourcePath = sourceDir + "/" + name + ".mkv";
    std::string const torrentPath = o.workdir + "/" + name + ".torrent";
    if (!prepareSource(o, sourcePath)) { logLine("cannot create the source"); return 1; }
    auto ti = prepareTorrent(o, sourcePath, torrentPath);
    if (!ti) { logLine("cannot create the torrent"); return 1; }

    // Seeders, one session each (one peer each), and their proxies.
    std::vector<std::unique_ptr<lt::session>> seeders;
    std::vector<lt::torrent_handle> seeds;
    std::vector<std::unique_ptr<Proxy>> proxies;
    for (PeerSpec const& spec : o.peers) {
        lt::settings_pack pack;
        pack.set_str(lt::settings_pack::listen_interfaces, "127.0.0.1:0");
        pack.set_bool(lt::settings_pack::enable_dht, false);
        pack.set_bool(lt::settings_pack::enable_lsd, false);
        pack.set_bool(lt::settings_pack::enable_upnp, false);
        pack.set_bool(lt::settings_pack::enable_natpmp, false);
        pack.set_str(lt::settings_pack::dht_bootstrap_nodes, "");
        pack.set_bool(lt::settings_pack::allow_multiple_connections_per_ip, true);
        pack.set_int(lt::settings_pack::alert_mask, lt::alert::error_notification);
        auto session = std::make_unique<lt::session>(lt::session_params(std::move(pack)));
        lt::add_torrent_params seed;
        seed.ti = ti;
        seed.save_path = sourceDir;
        seed.flags &= ~lt::torrent_flags::auto_managed;
        seed.flags &= ~lt::torrent_flags::paused;
        seed.flags |= lt::torrent_flags::seed_mode; // the file is ours: no check
        seeds.push_back(session->add_torrent(seed));
        auto proxy = std::make_unique<Proxy>();
        int listenPort = 0;
        for (int i = 0; i < 100 && (listenPort = session->listen_port()) == 0; ++i) std::this_thread::sleep_for(std::chrono::milliseconds(20));
        if (!proxy->start(listenPort, spec)) { logLine("proxy failed"); return 1; }
        logLine("peer %zu: seeder 127.0.0.1:%d behind proxy :%d, RTT %.0f ms, cap %.2f MB/s",
                proxies.size(), listenPort, proxy->port, spec.rttMs, spec.rate / 1e6);
        proxies.push_back(std::move(proxy));
        seeders.push_back(std::move(session));
    }

    // Client: the shared session, loopback-only.
    [PTTorrentsSession prepareSharedSessionForLoopbackTestingOnPort:0];
    if (!o.profile.empty()) {
        SEL selector = NSSelectorFromString(@"setNetworkProfileForTesting:");
        if ([PTTorrentsSession respondsToSelector:selector]) {
            ((void (*)(id, SEL, NSString *))objc_msgSend)([PTTorrentsSession class], selector, [NSString stringWithUTF8String:o.profile.c_str()]);
            logLine("network profile %s", o.profile.c_str());
        } else {
            logLine("network profile %s: not supported by this fork (baseline)", o.profile.c_str());
        }
    }
    (void)[PTTorrentsSession sharedSession];

    NSString *downloads = [[NSString stringWithUTF8String:o.volume.c_str()] stringByAppendingPathComponent:@"bench-downloads"];
    [[NSFileManager defaultManager] removeItemAtPath:downloads error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:downloads withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *torrent = [NSString stringWithUTF8String:torrentPath.c_str()];

    bool const isDownload = o.mode == "download";
    static std::atomic<bool> ready{false};
    static std::atomic<bool> failed{false};
    static std::atomic<double> readyAt{-1};
    Clock::time_point const startTime = Clock::now();
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (isDownload) {
            gDownload = [[PTTorrentDownload alloc] initWithMediaMetadata:@{MPMediaItemPropertyPersistentID: @"network-bench"}
                                                         downloadStatus:PTTorrentDownloadStatusProcessing];
            gDownload.downloadDirectoryOverride = downloads;
            [gDownload startDownloadingFromFileOrMagnetLink:torrent selectFileTDownload:^int(NSArray<NSString *> *names, NSArray<NSNumber *> *sizes) {
                return 0;
            }];
            gStreamer = gDownload;
        } else {
            gStreamer = [[PTTorrentStreamer alloc] init];
            gStreamer.allowsBoundedStorage = YES;
            gStreamer.downloadDirectoryOverride = downloads;
            [gStreamer startStreamingFromMultiTorrentFileOrMagnetLink:torrent progress:^(PTTorrentStatus status) {}
                                                         readyToPlay:^(NSURL *videoFileURL, NSURL *videoFilePath) {
                gServerPort = videoFileURL.port.intValue;
                readyAt = since(startTime);
                ready = true;
            } failure:^(NSError *error) {
                logLine("failure: %s", error.localizedDescription.UTF8String);
                failed = true;
            } selectFileToStream:^int(NSArray<NSString *> *names, NSArray<NSNumber *> *sizes) {
                return 0;
            }];
        }
    });

    dispatch_sync(dispatch_get_main_queue(), ^{ gHandle = gStreamer.torrentHandle; });
    lt::torrent_handle const handle = gHandle;
    if (!handle.is_valid()) { logLine("no torrent handle"); return 1; }
    // The client dials every proxy (TCP: the proxies carry no uTP).
    auto connectAll = [&] {
        for (auto const& proxy : proxies) {
            lt::tcp::endpoint const ep(boost::asio::ip::make_address_v4("127.0.0.1"), uint16_t(proxy->port));
            handle.connect_peer(ep, {}, lt::pex_encryption);
        }
    };
    connectAll();

    std::atomic<bool> done{false};
    std::atomic<double> completeAt{-1}, firstByteAt{-1}, firstMiBReadAt{-1}, readDoneAt{-1};
    std::atomic<int64_t> readBytes{0};
    std::atomic<double> stallSeconds{0};
    std::atomic<double> seekLatency{-1};

    // Sampler: rate every second, completion.
    std::vector<double> rates;
    std::mutex ratesMutex;
    int maxPeers = 0;
    std::thread sampler([&] {
        int64_t lastDone = 0;
        Clock::time_point lastT = Clock::now();
        int tick = 0;
        while (!done) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            lt::torrent_status st;
            bool valid = handle.is_valid();
            if (valid) st = handle.status();
            int64_t const wantedDone = valid ? st.total_wanted_done : lastDone;
            if (valid && st.total_wanted > 0 && firstByteAt < 0 && st.total_wanted_done > 0) firstByteAt = since(startTime);
            bool const finished = (valid && st.total_wanted > 0 && st.total_wanted_done >= st.total_wanted)
                || (isDownload && gDownload.downloadStatus == PTTorrentDownloadStatusFinished);
            if (finished && completeAt < 0) completeAt = since(startTime);
            if (valid) maxPeers = std::max(maxPeers, st.num_peers);
            if (getenv("BENCH_TRACE") && valid && since(startTime) < 12) {
                logLine("trace state %d peers %d connections %d candidates %d list %d paused %d seq %d",
                        int(st.state), st.num_peers, st.num_connections, st.connect_candidates, st.list_peers,
                        int(bool(st.flags & lt::torrent_flags::paused)), int(bool(st.flags & lt::torrent_flags::sequential_download)));
            }
            if (++tick % 10 == 0) {
                double const dt = std::chrono::duration<double>(Clock::now() - lastT).count();
                double const rate = double(wantedDone - lastDone) / dt;
                lastDone = wantedDone;
                lastT = Clock::now();
                std::lock_guard<std::mutex> lock(ratesMutex);
                rates.push_back(rate);
                logLine("t %5.1f  %6.2f MB/s  done %5.1f%%  peers %d  read %lld MiB", since(startTime), rate / 1e6,
                        valid && st.total_wanted > 0 ? 100.0 * double(st.total_wanted_done) / double(st.total_wanted) : 100.0,
                        valid ? st.num_peers : 0, readBytes.load() / MiB);
                if (valid && st.num_peers < int(proxies.size())) connectAll();
            }
        }
    });

    // Consumer (streams).
    std::thread consumer;
    if (!isDownload) {
        while (!ready && !failed && since(startTime) < o.timeout) std::this_thread::sleep_for(std::chrono::milliseconds(20));
        if (!ready) { logLine("not ready"); done = true; sampler.join(); return 1; }
        logLine("ready to play after %.2f s (mode %ld)", readyAt.load(), long(gStreamer.storageMode));
        int64_t const toRead = o.readBytes > 0 ? std::min(o.readBytes, o.size) : o.size;
        consumer = std::thread([&, toRead] {
            HttpStream http;
            if (!http.open(gServerPort, 0, 120)) { logLine("consumer: open failed"); return; }
            std::vector<uint8_t> buffer(static_cast<size_t>(256 * 1024));
            Clock::time_point t0 = Clock::now();
            int64_t offset = 0;
            int64_t consumed = 0; // bytes read (the pace), whatever the seeks
            bool seeked = false;
            while (offset < toRead && !done) {
                if (o.seekAt > 0 && !seeked && offset >= int64_t(double(o.size) * o.seekAt)) {
                    // A forward seek beyond what is downloaded: time to the first MiB there.
                    seeked = true;
                    int64_t const target = int64_t(double(o.size) * o.seekTo) / MiB * MiB;
                    http.close();
                    Clock::time_point const t = Clock::now();
                    if (!http.open(gServerPort, target, 120)) { logLine("consumer: seek open failed"); break; }
                    int64_t got = 0;
                    while (got < MiB) {
                        int64_t const n = http.readSome(buffer.data(), std::min<int64_t>(int64_t(buffer.size()), MiB - got));
                        if (n <= 0) break;
                        got += n;
                    }
                    seekLatency = since(t);
                    logLine("seek %lld MiB -> %lld MiB: first MiB in %.2f s", offset / MiB, target / MiB, seekLatency.load());
                    offset = target + got;
                    consumed += got;
                    readBytes = offset;
                    // The player buffered meanwhile: the pace restarts from here.
                    t0 = Clock::now() - std::chrono::microseconds(int64_t(double(consumed) / o.readRate * 1e6));
                    gStreamer.consumedBefore = std::max<int64_t>(0, target - 32 * MiB);
                    continue;
                }
                if (o.readRate > 0) {
                    Clock::time_point const due = t0 + std::chrono::microseconds(int64_t(double(consumed) / o.readRate * 1e6));
                    if (due > Clock::now()) std::this_thread::sleep_until(due);
                }
                Clock::time_point const before = Clock::now();
                int64_t const n = http.readSome(buffer.data(), std::min<int64_t>(int64_t(buffer.size()), toRead - offset));
                if (n <= 0) { logLine("consumer: read ended at %lld", offset); break; }
                double const waited = since(before);
                if (o.readRate > 0 && waited > 0.25) stallSeconds = stallSeconds + waited;
                offset += n;
                consumed += n;
                readBytes = offset;
                if (offset >= MiB && firstMiBReadAt < 0) firstMiBReadAt = since(startTime);
                // Like the app: what was read is released, 32 MiB kept behind.
                if (offset > 32 * MiB) gStreamer.consumedBefore = offset - 32 * MiB;
            }
            if (offset >= toRead) readDoneAt = since(startTime);
            http.close();
        });
    }

    // Until the file is complete (and the consumer is done) or the timeout.
    while (since(startTime) < o.timeout) {
        bool const consumerDone = isDownload || readDoneAt >= 0 || failed;
        bool const fileDone = completeAt >= 0 || o.mode == "bounded";
        if (consumerDone && fileDone) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    done = true;
    if (consumer.joinable()) consumer.join();
    sampler.join();

    __block long long rescued = 0;
    dispatch_sync(dispatch_get_main_queue(), ^{ rescued = [gStreamer.storageStatistics[@"rescuedBlocks"] longLongValue]; });
    // Seeder side: what was sent (all of it went through the proxies).
    int64_t uploaded = 0;
    for (auto const& seed : seeds) uploaded += seed.status().total_payload_upload;
    double const complete = completeAt.load();
    double const first = firstByteAt.load();
    double const avg = complete > 0 && first >= 0 ? double(o.size) / (complete - first) / 1e6 : -1;
    double peak = 0;
    for (double r : rates) peak = std::max(peak, r);
    double const readDone = readDoneAt.load();
    int64_t const readTotal = readBytes.load();
    double const readRate = readDone > 0 && readyAt > 0 ? double(readTotal) / (readDone - readyAt) / 1e6 : -1;
    logLine("RESULT label=%s mode=%s profile=%s peers=%zu ready=%.2f firstMiB=%.2f readDone=%.2f readMBs=%.2f complete=%.2f avgMBs=%.2f peakMBs=%.2f stall=%.1f seek=%.2f rescued=%lld uploadedMiB=%lld maxPeers=%d",
            o.label.c_str(), o.mode.c_str(), o.profile.empty() ? "-" : o.profile.c_str(), proxies.size(), readyAt.load(), firstMiBReadAt.load(),
            readDone, readRate, complete, avg, peak / 1e6, stallSeconds.load(), seekLatency.load(), rescued, uploaded / MiB, maxPeers);

    dispatch_sync(dispatch_get_main_queue(), ^{
        if (isDownload) [gDownload stop];
        else [gStreamer cancelStreamingAndDeleteData:YES];
    });
    [[NSFileManager defaultManager] removeItemAtPath:downloads error:nil];
    return complete > 0 || o.mode == "bounded" ? 0 : 1;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        Options const options = parseOptions(argc, argv);
        if (options.workdir.empty() || options.volume.empty()) {
            fprintf(stderr, "usage: NetworkBench --workdir DIR --volume DIR --mode full|bounded|download [--peers RTT:MBs,...] "
                            "[--size-mib N] [--piece-kib N] [--read-mbs N] [--read-mib N] [--profile tv|ios|mac] [--label NAME]\n");
            return 2;
        }
        std::thread test([options] {
            int const result = run(options);
            exit(result);
        });
        test.detach();
        CFRunLoopRun(); // the streamer and GCDWebServer use the main queue
    }
    return 0;
}
