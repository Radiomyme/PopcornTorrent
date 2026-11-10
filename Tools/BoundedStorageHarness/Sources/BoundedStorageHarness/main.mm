//
//  main.mm
//  BoundedStorageHarness
//
//  Offline end-to-end test of PTTorrentStreamer's bounded storage:
//  1. generates a file of patterned pseudo-random data (real hashes) with an
//     MKV head, and a private torrent for it (no trackers);
//  2. seeds it from a libtorrent session on 127.0.0.1 (no DHT, LSD, UPnP,
//     NAT-PMP) and streams it with PTTorrentStreamer (loopback-only session);
//  3. a consumer reads the file through the streamer's HTTP server at a steady
//     rate, checks every byte against the source, advances consumedBefore,
//     pauses, and probes the server and the BitTorrent side (a raw peer that
//     requests freed pieces);
//  4. cancels and checks the space is given back.
//  The streamer writes into <volume>/tmp/Downloads (downloadDirectoryOverride);
//  run_harness.sh mounts a fresh APFS sparse image there.
//

#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>

#import "PTTorrentStreamer.h"
#import "PTTorrentsSession.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdarg>
#include <cstring>
#include <map>
#include <mutex>
#include <set>
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
#include <libtorrent/alert_types.hpp>

namespace lt = libtorrent;
using Clock = std::chrono::steady_clock;

static constexpr int64_t MiB = 1024 * 1024;
static constexpr int64_t GiB = 1024 * MiB;

#pragma mark - Logging and results

static Clock::time_point gStart = Clock::now();
static std::mutex gLogMutex;
static int gFailures = 0;

static double since(Clock::time_point t) { return std::chrono::duration<double>(Clock::now() - t).count(); }

static void logLine(const char *format, ...) {
    std::lock_guard<std::mutex> lock(gLogMutex);
    va_list args;
    va_start(args, format);
    fprintf(stdout, "[%7.1f] ", since(gStart));
    vfprintf(stdout, format, args);
    fprintf(stdout, "\n");
    fflush(stdout);
    va_end(args);
}

static void check(bool ok, const char *name, const char *format, ...) {
    char detail[512];
    va_list args;
    va_start(args, format);
    vsnprintf(detail, sizeof(detail), format, args);
    va_end(args);
    if (!ok) ++gFailures;
    logLine("ASSERT %-4s %s: %s", ok ? "PASS" : "FAIL", name, detail);
}

#pragma mark - Options

struct Options {
    std::string mode = "bounded";   // bounded | full
    std::string workdir;            // source file + torrent (not on the volume under test)
    std::string volume;             // volume under test (TMPDIR points inside it)
    int64_t size = 6 * GiB;
    int64_t pieceLength = 4 * MiB;
    double rate = 40e6;             // consumer bytes/s
    int64_t budget = 0;             // storageBudget, 0 = automatic
    int64_t keepBehind = 32 * MiB;  // consumer: data kept below its read offset
    double pauseSeconds = 60;
    double pauseAt = 0.40;          // fraction of the file
    double probeAt = 0.50;          // before the window reaches the end (the torrent then
                                    // "finishes" and libtorrent drops its connections)
    double checksAt = 0.70;
    int64_t ballast = 0;            // bytes written on the volume between 35 % and 55 % (stress)
    double ballastHold = 0;         // > 0: the ballast is removed after this many seconds instead
    bool ballastGreedy = false;     // the ballast takes every byte freed while it is held (forces ENOSPC)
};

static Options parseOptions(int argc, const char *argv[]) {
    Options o;
    for (int i = 1; i + 1 < argc; i += 2) {
        std::string key = argv[i];
        std::string value = argv[i + 1];
        if (key == "--mode") o.mode = value;
        else if (key == "--workdir") o.workdir = value;
        else if (key == "--volume") o.volume = value;
        else if (key == "--size-mib") o.size = std::stoll(value) * MiB;
        else if (key == "--piece-kib") o.pieceLength = std::stoll(value) * 1024;
        else if (key == "--rate-mbs") o.rate = std::stod(value) * 1e6;
        else if (key == "--budget-mib") o.budget = std::stoll(value) * MiB;
        else if (key == "--keep-behind-mib") o.keepBehind = std::stoll(value) * MiB;
        else if (key == "--pause-seconds") o.pauseSeconds = std::stod(value);
        else if (key == "--ballast-mib") o.ballast = std::stoll(value) * MiB;
        else if (key == "--ballast-hold-seconds") o.ballastHold = std::stod(value);
        else if (key == "--ballast-greedy") o.ballastGreedy = value == "1";
    }
    return o;
}

static int64_t volumeFree(const std::string& path) {
    struct statfs info;
    if (statfs(path.c_str(), &info) != 0) return -1;
    return int64_t(info.f_bavail) * int64_t(info.f_bsize);
}

#pragma mark - Source file

static uint64_t splitmix(uint64_t x) {
    x += 0x9E3779B97F4A7C15ULL;
    x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ULL;
    x = (x ^ (x >> 27)) * 0x94D049BB133111EBULL;
    return x ^ (x >> 31);
}

/// Deterministic content of 1 MiB block `index` (xorshift64* seeded per block).
static void fillBlock(uint64_t index, uint8_t *out, size_t length) {
    uint64_t state = splitmix(index + 1) | 1;
    size_t i = 0;
    for (; i + 8 <= length; i += 8) {
        state ^= state >> 12; state ^= state << 25; state ^= state >> 27;
        uint64_t const value = state * 0x2545F4914F6CDD1DULL;
        memcpy(out + i, &value, 8);
    }
    for (; i < length; ++i) out[i] = uint8_t(splitmix(index * 131 + i));
}

/// MKV-like head: EBML header, Segment of unknown size, a Void element up to
/// the first Cluster at `clusterOffset`. The rest is pseudo-random payload.
static void writeMatroskaHead(uint8_t *block, int64_t clusterOffset) {
    size_t p = 0;
    const uint8_t ebml[] = {0x1A, 0x45, 0xDF, 0xA3, 0x84, 0x42, 0x86, 0x81, 0x01};
    memcpy(block + p, ebml, sizeof(ebml)); p += sizeof(ebml);
    const uint8_t segment[] = {0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};
    memcpy(block + p, segment, sizeof(segment)); p += sizeof(segment);
    uint64_t const voidSize = uint64_t(clusterOffset) - p - 9;
    block[p++] = 0xEC;
    block[p++] = 0x01;
    for (int i = 6; i >= 0; --i) block[p++] = uint8_t(voidSize >> (8 * i));
    // Void payload stays pseudo-random; the Cluster header is written by the caller.
}

static bool prepareSource(Options const& o, std::string const& path, std::string& sha) {
    std::string const shaPath = path + ".sha256";
    struct stat info;
    if (stat(path.c_str(), &info) == 0 && info.st_size == o.size) {
        FILE *f = fopen(shaPath.c_str(), "r");
        char buffer[80] = {0};
        if (f && fgets(buffer, sizeof(buffer), f)) {
            sha = std::string(buffer, 64);
            fclose(f);
            logLine("source: reusing %s (%lld bytes, sha256 %s)", path.c_str(), o.size, sha.c_str());
            return true;
        }
        if (f) fclose(f);
    }
    logLine("source: generating %lld bytes", o.size);
    int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return false;
    std::vector<uint8_t> block(static_cast<size_t>(MiB));
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    int64_t const clusterOffset = 5 * MiB + 123;
    for (int64_t offset = 0; offset < o.size; offset += MiB) {
        size_t const length = size_t(std::min<int64_t>(MiB, o.size - offset));
        uint64_t const index = uint64_t(offset / MiB);
        fillBlock(index, block.data(), length);
        if (index == 0) writeMatroskaHead(block.data(), clusterOffset);
        if (offset <= clusterOffset && clusterOffset < offset + int64_t(length)) {
            const uint8_t cluster[] = {0x1F, 0x43, 0xB6, 0x75, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};
            size_t const at = size_t(clusterOffset - offset);
            memcpy(block.data() + at, cluster, std::min(sizeof(cluster), length - at));
        }
        if (write(fd, block.data(), length) != ssize_t(length)) { close(fd); return false; }
        CC_SHA256_Update(&ctx, block.data(), CC_LONG(length));
    }
    close(fd);
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    char hex[65];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) snprintf(hex + 2 * i, 3, "%02x", digest[i]);
    sha = hex;
    FILE *f = fopen(shaPath.c_str(), "w");
    if (f) { fprintf(f, "%s\n", hex); fclose(f); }
    logLine("source: done, sha256 %s", hex);
    return true;
}

static std::shared_ptr<lt::torrent_info> prepareTorrent(Options const& o, std::string const& sourcePath, std::string const& torrentPath) {
    lt::error_code ec;
    struct stat info;
    if (stat(torrentPath.c_str(), &info) == 0) {
        auto ti = std::make_shared<lt::torrent_info>(torrentPath, ec);
        if (!ec && ti->total_size() == o.size && ti->piece_length() == o.pieceLength) {
            logLine("torrent: reusing %s (%d pieces of %d bytes)", torrentPath.c_str(), ti->num_pieces(), ti->piece_length());
            return ti;
        }
    }
    logLine("torrent: hashing %s", sourcePath.c_str());
    lt::file_storage fs;
    lt::add_files(fs, sourcePath);
    lt::create_torrent ct(fs, int(o.pieceLength));
    ct.set_priv(true); // no DHT / PEX for this torrent either
    ct.set_creator("PopcornTorrent bounded storage harness");
    std::string const parent = sourcePath.substr(0, sourcePath.find_last_of('/'));
    lt::set_piece_hashes(ct, parent, ec);
    if (ec) { logLine("torrent: hashing failed: %s", ec.message().c_str()); return nullptr; }
    std::vector<char> buffer;
    lt::bencode(std::back_inserter(buffer), ct.generate());
    FILE *f = fopen(torrentPath.c_str(), "wb");
    if (!f) return nullptr;
    fwrite(buffer.data(), 1, buffer.size(), f);
    fclose(f);
    auto ti = std::make_shared<lt::torrent_info>(torrentPath, ec);
    if (ec) return nullptr;
    logLine("torrent: %d pieces of %d bytes, info hash %s", ti->num_pieces(), ti->piece_length(),
            lt::aux::to_hex(ti->info_hash()).c_str());
    return ti;
}

#pragma mark - HTTP client

struct HttpStream {
    int fd = -1;
    int status = 0;
    int64_t contentLength = -1;
    std::vector<uint8_t> pending;
    size_t pendingOffset = 0;

    bool open(int port, int64_t start, int64_t endInclusive, int receiveBuffer, double timeoutSeconds) {
        fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return false;
        if (receiveBuffer > 0) setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, sizeof(receiveBuffer));
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
        if (endInclusive >= 0) {
            snprintf(request, sizeof(request), "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=%lld-%lld\r\nConnection: close\r\n\r\n", start, endInclusive);
        } else {
            snprintf(request, sizeof(request), "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=%lld-\r\nConnection: close\r\n\r\n", start);
        }
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
        header.resize(end);
        sscanf(header.c_str(), "HTTP/1.%*d %d", &status);
        std::string lower = header;
        std::transform(lower.begin(), lower.end(), lower.begin(), ::tolower);
        size_t const at = lower.find("content-length:");
        if (at != std::string::npos) contentLength = std::stoll(lower.substr(at + 15));
        return true;
    }

    /// Reads exactly `length` bytes unless the stream ends or fails.
    int64_t readFull(uint8_t *out, int64_t length) {
        int64_t done = 0;
        while (done < length && pendingOffset < pending.size()) out[done++] = pending[pendingOffset++];
        while (done < length) {
            ssize_t const n = recv(fd, out + done, size_t(length - done), 0);
            if (n <= 0) break;
            done += n;
        }
        return done;
    }

    void close() {
        if (fd >= 0) ::close(fd);
        fd = -1;
    }
};

static int gServerPort = 0;

/// One-shot range request: status, latency and the bytes compared with the source.
struct RangeResult { int status = 0; double seconds = 0; int64_t bytes = 0; bool matches = false; };

static RangeResult fetchRange(int sourceFd, int64_t start, int64_t length, double timeout = 60) {
    RangeResult result;
    Clock::time_point const t = Clock::now();
    HttpStream http;
    if (!http.open(gServerPort, start, start + length - 1, 0, timeout)) { result.seconds = since(t); return result; }
    result.status = http.status;
    if (http.status == 206 || http.status == 200) {
        std::vector<uint8_t> data(static_cast<size_t>(length)), expected(static_cast<size_t>(length));
        result.bytes = http.readFull(data.data(), length);
        pread(sourceFd, expected.data(), size_t(length), start);
        result.matches = result.bytes == length && memcmp(data.data(), expected.data(), size_t(length)) == 0;
    }
    http.close();
    result.seconds = since(t);
    return result;
}

#pragma mark - BitTorrent probe peer

/// A raw BitTorrent peer (fast extension + lt_donthave) connected to the
/// streamer. It records what the streamer advertises and what it answers to
/// requests, to prove freed pieces are withdrawn and never uploaded.
struct BtProbe {
    int fd = -1;
    std::thread reader;
    std::mutex mutex;
    std::set<int> advertised;
    std::set<int> withdrawn;     // lt_donthave received
    std::set<int> rejected;
    std::map<int, std::vector<uint8_t>> blocks; // piece -> first block received
    std::atomic<bool> unchoked{false};
    std::atomic<bool> running{false};
    std::atomic<bool> handshaken{false};
    std::atomic<int> messages{0};
    std::atomic<int64_t> lastMessageMs{0};
    int numPieces = 0;

    static void put32(std::string& s, uint32_t v) {
        s.push_back(char(v >> 24)); s.push_back(char(v >> 16)); s.push_back(char(v >> 8)); s.push_back(char(v));
    }
    static uint32_t get32(const uint8_t *p) { return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | p[3]; }

    bool readExact(uint8_t *out, size_t length) {
        size_t done = 0;
        while (done < length) {
            ssize_t const n = recv(fd, out + done, length - done, 0);
            if (n <= 0) return false;
            done += size_t(n);
        }
        return true;
    }

    void sendMessage(std::string const& payload) {
        std::string message;
        put32(message, uint32_t(payload.size()));
        message += payload;
        send(fd, message.data(), message.size(), 0);
    }

    bool connectTo(int port, lt::sha1_hash const& infoHash, int pieces) {
        numPieces = pieces;
        fd = socket(AF_INET, SOCK_STREAM, 0);
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        sockaddr_in address = {};
        address.sin_family = AF_INET;
        address.sin_port = htons(uint16_t(port));
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (connect(fd, (sockaddr *)&address, sizeof(address)) != 0) return false;
        std::string handshake;
        handshake.push_back(19);
        handshake += "BitTorrent protocol";
        char reserved[8] = {0, 0, 0, 0, 0, 0x10, 0, 0x04}; // extension protocol, fast extension
        handshake.append(reserved, 8);
        handshake.append(infoHash.data(), 20);
        handshake += "-PB0001-boundedprobe";
        send(fd, handshake.data(), handshake.size(), 0);
        uint8_t answer[68];
        if (!readExact(answer, sizeof(answer))) return false;
        if (memcmp(answer + 28, infoHash.data(), 20) != 0) return false;
        handshaken = true;
        std::string extended;
        extended.push_back(20);
        extended.push_back(0);
        extended += "d1:md11:lt_donthavei7eee";
        sendMessage(extended);
        sendMessage(std::string(1, char(15))); // have none
        sendMessage(std::string(1, char(2)));  // interested
        running = true;
        reader = std::thread([this] { readLoop(); });
        return true;
    }

    void readLoop() {
        std::vector<uint8_t> payload;
        while (running) {
            uint8_t header[4];
            if (!readExact(header, 4)) break;
            uint32_t const length = get32(header);
            if (length == 0) continue;
            payload.resize(length);
            if (!readExact(payload.data(), length)) break;
            uint8_t const id = payload[0];
            ++messages;
            lastMessageMs = int64_t(since(gStart) * 1000);
            std::lock_guard<std::mutex> lock(mutex);
            switch (id) {
            case 1: unchoked = true; break;
            case 0: unchoked = false; break;
            case 4: advertised.insert(int(get32(&payload[1]))); break;
            case 5:
                for (uint32_t i = 0; i + 1 < length; ++i) {
                    for (int bit = 0; bit < 8; ++bit) {
                        if (payload[1 + i] & (0x80 >> bit)) advertised.insert(int(i * 8 + uint32_t(bit)));
                    }
                }
                break;
            case 14: for (int p = 0; p < numPieces; ++p) advertised.insert(p); break;
            case 7: {
                int const piece = int(get32(&payload[1]));
                if (!blocks.count(piece)) blocks[piece] = std::vector<uint8_t>(payload.begin() + 9, payload.end());
                break;
            }
            case 16: rejected.insert(int(get32(&payload[1]))); break;
            case 20:
                if (length >= 6 && payload[1] == 7) {
                    int const piece = int(get32(&payload[2]));
                    withdrawn.insert(piece);
                    advertised.erase(piece);
                }
                break;
            default: break;
            }
        }
        running = false;
    }

    void request(int piece) {
        std::string message;
        message.push_back(6);
        put32(message, uint32_t(piece));
        put32(message, 0);
        put32(message, 16384);
        sendMessage(message);
    }

    void keepAlive() { std::string empty; std::string m; put32(m, 0); send(fd, m.data(), m.size(), 0); }

    void stop() {
        running = false;
        if (fd >= 0) { shutdown(fd, SHUT_RDWR); ::close(fd); }
        if (reader.joinable()) reader.join();
        fd = -1;
    }
};

#pragma mark - Sampling

struct Sample {
    double t;
    int64_t free;
    int64_t onDisk;
    int64_t consumer;
    int pace;
    int limit;
};

#pragma mark - Test

static int runTest(Options o) {
    bool const bounded = o.mode == "bounded";
    std::string const sourceDir = o.workdir + "/source";
    mkdir(sourceDir.c_str(), 0755);
    std::string const sourcePath = sourceDir + "/BoundedHarness.mkv";
    std::string const torrentPath = o.workdir + "/BoundedHarness.torrent";
    std::string sourceSha;
    if (!prepareSource(o, sourcePath, sourceSha)) { logLine("cannot create the source file"); return 1; }
    auto ti = prepareTorrent(o, sourcePath, torrentPath);
    if (!ti) return 1;
    int const sourceFd = open(sourcePath.c_str(), O_RDONLY);

    NSString *downloads = [[NSString stringWithUTF8String:o.volume.c_str()] stringByAppendingPathComponent:@"tmp/Downloads"];
    logLine("mode %s, downloads %s, free %lld bytes", o.mode.c_str(), downloads.UTF8String, volumeFree(o.volume));
    // Leftovers of an earlier run would count as data already on disk.
    [[NSFileManager defaultManager] removeItemAtPath:downloads error:nil];
    int64_t const baselineFree = volumeFree(o.volume);

    // Seeder: loopback only.
    lt::settings_pack seederPack;
    seederPack.set_str(lt::settings_pack::listen_interfaces, "127.0.0.1:0");
    seederPack.set_bool(lt::settings_pack::enable_dht, false);
    seederPack.set_bool(lt::settings_pack::enable_lsd, false);
    seederPack.set_bool(lt::settings_pack::enable_upnp, false);
    seederPack.set_bool(lt::settings_pack::enable_natpmp, false);
    seederPack.set_str(lt::settings_pack::dht_bootstrap_nodes, "");
    seederPack.set_bool(lt::settings_pack::allow_multiple_connections_per_ip, true);
    seederPack.set_int(lt::settings_pack::alert_mask, lt::alert::error_notification);
    seederPack.set_int(lt::settings_pack::min_reconnect_time, 1);
    lt::session seeder{lt::session_params(std::move(seederPack))};
    lt::add_torrent_params seed;
    seed.ti = ti;
    seed.save_path = sourceDir;
    seed.flags &= ~lt::torrent_flags::auto_managed;
    seed.flags &= ~lt::torrent_flags::paused;
    lt::torrent_handle seedHandle = seeder.add_torrent(seed);
    // A full check (not seed_mode): every piece is verified before the stream starts.
    Clock::time_point const checkStart = Clock::now();
    while (!seedHandle.status().is_seeding && since(checkStart) < 300) std::this_thread::sleep_for(std::chrono::milliseconds(200));
    logLine("seeder checked the file in %.1f s (seeding %d), listening on 127.0.0.1:%d", since(checkStart),
            int(seedHandle.status().is_seeding), int(seeder.listen_port()));

    // Streamer: the shared session made loopback-only before its creation.
    [PTTorrentsSession prepareSharedSessionForLoopbackTestingOnPort:0];
    PTTorrentsSession *session = [PTTorrentsSession sharedSession];
    PTTorrentStreamer *streamer = [[PTTorrentStreamer alloc] init];
    streamer.storageBudget = o.budget;
    streamer.downloadDirectoryOverride = downloads; // the volume under test
    static std::atomic<bool> ready{false};
    static std::atomic<bool> failed{false};
    static NSString *failure = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        [streamer startStreamingFromMultiTorrentFileOrMagnetLink:[NSString stringWithUTF8String:torrentPath.c_str()]
                                                        progress:^(PTTorrentStatus status) {}
                                                     readyToPlay:^(NSURL *videoFileURL, NSURL *videoFilePath) {
            gServerPort = videoFileURL.port.intValue;
            ready = true;
        } failure:^(NSError *error) {
            failure = error.localizedDescription;
            failed = true;
        } selectFileToStream:^int(NSArray<NSString *> *names, NSArray<NSNumber *> *sizes) {
            return 0;
        }];
    });

    Clock::time_point const startTime = Clock::now();
    // Connect once the streamer has added the torrent (a refused attempt costs a reconnect delay).
    while ((session.listenPort == 0 || streamer.storageMode == PTStorageModeUndetermined) && !failed && since(startTime) < 30) {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    int const clientPort = session.listenPort;
    logLine("streamer session listening on 127.0.0.1:%d", clientPort);
    lt::tcp::endpoint const client(boost::asio::ip::make_address_v4("127.0.0.1"), uint16_t(clientPort));
    seedHandle.connect_peer(client);

    while (!ready && !failed && since(startTime) < 120) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        if (seedHandle.status().num_peers == 0 && int(since(startTime) * 10) % 20 == 0) seedHandle.connect_peer(client);
    }
    if (!ready) {
        logLine("stream not ready: %s", failure ? failure.UTF8String : "timeout");
        return 1;
    }
    PTStorageMode const mode = streamer.storageMode;
    check(mode == (bounded ? PTStorageModeBounded : PTStorageModeFull), "storage mode",
          "mode %ld after %.1f s, server port %d", long(mode), since(startTime), gServerPort);
    NSDictionary *startStats = streamer.storageStatistics;
    logLine("start: %s", [[startStats description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "].UTF8String);

    // Sampler.
    std::atomic<bool> sampling{true};
    std::atomic<int64_t> consumerOffset{0};
    std::vector<Sample> samples;
    std::mutex samplesMutex;
    std::thread sampler([&] {
        while (sampling) {
            NSDictionary *stats = streamer.storageStatistics;
            Sample s;
            s.t = since(startTime);
            s.free = volumeFree(o.volume);
            s.onDisk = streamer.bytesOnDisk;
            s.consumer = consumerOffset.load();
            s.pace = [stats[@"paceState"] intValue];
            s.limit = [stats[@"downloadLimit"] intValue];
            {
                std::lock_guard<std::mutex> lock(samplesMutex);
                samples.push_back(s);
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(250));
        }
    });

    // Probe peer: connects now, requests at the checks.
    BtProbe probe;
    bool const probeConnected = probe.connectTo(clientPort, ti->info_hash(), ti->num_pieces());
    logLine("probe peer connected: %d", int(probeConnected));
    std::atomic<bool> keepingAlive{true};
    std::thread probeKeepAlive([&] {
        while (keepingAlive) {
            for (int i = 0; i < 100 && keepingAlive; ++i) std::this_thread::sleep_for(std::chrono::milliseconds(200));
            if (keepingAlive && probe.running) probe.keepAlive();
        }
    });
    int probeWatchPiece = -1; // a piece on disk now, freed later

    // Consumer.
    int64_t const size = o.size;
    HttpStream http;
    bool const opened = http.open(gServerPort, 0, -1, int(1 * MiB), 120);
    check(opened && (http.status == 206 || http.status == 200), "main request", "status %d, content-length %lld", http.status, http.contentLength);
    std::vector<uint8_t> chunk(static_cast<size_t>(MiB)), expected(static_cast<size_t>(MiB));
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    int64_t offset = 0;
    int64_t mismatches = 0, zeroChunks = 0;
    double stall = 0, pausedTime = 0;
    bool paused = false, checksDone = false, probeDone = false, ballastWritten = false, ballastRemoved = false;
    int64_t pauseStartDisk = 0, pauseSettledDisk = 0, pauseEndDisk = 0, pauseStartFree = 0, pauseEndFree = 0;
    double pauseStartT = -1, pauseEndT = -1;
    std::string ballastPath = o.volume + "/ballast.bin";
    Clock::time_point const consumeStart = Clock::now();
    Clock::time_point nextRead = consumeStart;
    std::atomic<bool> concurrentRunning{false};
    std::atomic<int> concurrentOk{0}, concurrentBad{0};
    std::thread concurrent;
    RangeResult waitingRead, freedRead, headRead, tailRead;
    int64_t freedOffset = -1;

    while (opened && offset < size) {
        // Pause: the consumer stops; disk use must stay flat.
        if (!paused && offset >= int64_t(double(size) * o.pauseAt) && o.pauseSeconds > 0) {
            paused = true;
            pauseStartDisk = streamer.bytesOnDisk;
            pauseStartFree = volumeFree(o.volume);
            logLine("pause %.0f s at %lld (on disk %lld, free %lld)", o.pauseSeconds, offset, pauseStartDisk, pauseStartFree);
            Clock::time_point const p = Clock::now();
            pauseStartT = since(startTime);
            std::this_thread::sleep_for(std::chrono::seconds(5));
            pauseSettledDisk = streamer.bytesOnDisk;
            while (since(p) < o.pauseSeconds) {
                std::this_thread::sleep_for(std::chrono::seconds(10));
                probe.keepAlive();
            }
            pauseEndDisk = streamer.bytesOnDisk;
            pauseEndFree = volumeFree(o.volume);
            pausedTime += since(p);
            pauseEndT = since(startTime);
            logLine("resume (on disk %lld -> %lld after the first 5 s -> %lld, free %lld)", pauseStartDisk, pauseSettledDisk, pauseEndDisk, pauseEndFree);
        }

        // Stress: something else fills the volume for a while (the app's own copy).
        if (o.ballast > 0 && !ballastWritten && offset >= int64_t(double(size) * 0.35)) {
            ballastWritten = true;
            int fd = open(ballastPath.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
            std::vector<uint8_t> junk(size_t(MiB), 0xA5);
            int64_t written = 0;
            for (; written < o.ballast; written += MiB) {
                if (write(fd, junk.data(), junk.size()) != ssize_t(junk.size())) break;
            }
            close(fd);
            logLine("ballast: wrote %lld bytes, free now %lld", written, volumeFree(o.volume));
            if (o.ballastHold > 0) {
                // Timed removal: the reader may be starved while the volume is full.
                std::thread([ballastPath, hold = o.ballastHold, volume = o.volume, greedy = o.ballastGreedy] {
                    Clock::time_point const held = Clock::now();
                    if (greedy) {
                        // Keep the volume full: every byte the streamer frees is taken again.
                        int fd = open(ballastPath.c_str(), O_WRONLY | O_APPEND);
                        std::vector<uint8_t> junk(static_cast<size_t>(256 * 1024), 0x5A);
                        int64_t taken = 0;
                        while (fd >= 0 && since(held) < hold) {
                            if (write(fd, junk.data(), junk.size()) == ssize_t(junk.size())) taken += int64_t(junk.size());
                            else std::this_thread::sleep_for(std::chrono::milliseconds(20));
                        }
                        if (fd >= 0) close(fd);
                        logLine("ballast: took %lld more bytes while held", taken);
                    } else {
                        std::this_thread::sleep_for(std::chrono::duration<double>(hold));
                    }
                    unlink(ballastPath.c_str());
                    logLine("ballast: removed after %.0f s, free now %lld", hold, volumeFree(volume));
                }).detach();
                ballastRemoved = true;
            }
        }
        if (o.ballast > 0 && ballastWritten && !ballastRemoved && offset >= int64_t(double(size) * 0.55)) {
            ballastRemoved = true;
            unlink(ballastPath.c_str());
            logLine("ballast: removed, free now %lld", volumeFree(o.volume));
        }

        if (probeConnected && probeWatchPiece < 0 && offset >= int64_t(double(size) * 0.15)) {
            // A piece on disk right now that the consumer will release before the checks.
            int64_t const watchOffset = std::min<int64_t>(offset + 64 * MiB, size - 1);
            if ([streamer isRangeAvailable:watchOffset length:1]) probeWatchPiece = int(watchOffset / ti->piece_length());
            std::lock_guard<std::mutex> lock(probe.mutex);
            logLine("probe: watching piece %d (advertised %d pieces so far, watch advertised %d)", probeWatchPiece,
                    int(probe.advertised.size()), int(probe.advertised.count(probeWatchPiece)));
        }

        // A read just ahead of the download frontier waits for the piece (no zeros).
        if (waitingRead.status == 0 && offset >= int64_t(double(size) * 0.30)) {
            int64_t const missing = [streamer firstMissingOffsetFrom:offset];
            if (missing < size - 8 * MiB) {
                int64_t const start = std::min(missing + 1 * MiB, size - 4 * MiB);
                waitingRead = fetchRange(sourceFd, start, 256 * 1024);
                check(waitingRead.status == 206 && waitingRead.matches, "read ahead of the download waits",
                      "offset %lld (first missing %lld), status %d, %.2f s, bytes match %d", start, missing,
                      waitingRead.status, waitingRead.seconds, int(waitingRead.matches));
            } else {
                waitingRead.status = -1;
            }
        }

        // Concurrent requests: head and tail (pinned) and recent data, while the main stream goes on.
        if (!concurrentRunning && !concurrent.joinable() && offset >= int64_t(double(size) * 0.60)) {
            concurrentRunning = true;
            concurrent = std::thread([&] {
                int64_t const piece = ti->piece_length();
                for (int i = 0; i < 12 && concurrentRunning; ++i) {
                    int64_t start;
                    switch (i % 3) {
                    case 0: start = 0; break;
                    case 1: start = size - 1 * MiB; break;
                    default: start = std::max<int64_t>(0, consumerOffset.load() - 8 * MiB) / piece * piece; break;
                    }
                    RangeResult r = fetchRange(sourceFd, start, 1 * MiB);
                    if ((r.status == 206) && r.matches) ++concurrentOk; else {
                        ++concurrentBad;
                        logLine("concurrent read at %lld: status %d match %d", start, r.status, int(r.matches));
                    }
                    std::this_thread::sleep_for(std::chrono::milliseconds(500));
                }
                concurrentRunning = false;
            });
        }

        // Full mode finishes (and pauses, dropping its peers) as soon as the file is
        // downloaded: probe right away there.
        if (!probeDone && offset >= int64_t(double(size) * (bounded ? o.probeAt : 0.01))) {
            probeDone = true;
            // Probe peer: ask for a freed piece and a pinned tail piece.
            if (probeConnected) {
                Clock::time_point const w = Clock::now();
                while (!probe.unchoked && probe.running && since(w) < 45) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(200));
                }
                int const tailPiece = ti->num_pieces() - 1;
                int const freedPiece = probeWatchPiece;
                int const before = probe.messages.load();
                probe.request(tailPiece);
                if (freedPiece >= 0) probe.request(freedPiece);
                Clock::time_point const asked = Clock::now();
                while (since(asked) < 10) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(200));
                    std::lock_guard<std::mutex> lock(probe.mutex);
                    if (probe.blocks.count(tailPiece) && (freedPiece < 0 || probe.rejected.count(freedPiece) || probe.blocks.count(freedPiece))) break;
                }
                logLine("probe: %d messages since the requests (%.1f s), connection open %d, last message at %.1f s",
                        probe.messages.load() - before, since(asked), int(probe.running.load()), probe.lastMessageMs.load() / 1000.0);
                std::lock_guard<std::mutex> lock(probe.mutex);
                bool const tailOk = probe.blocks.count(tailPiece) && probe.blocks[tailPiece].size() >= 16384 &&
                    [&] {
                        std::vector<uint8_t> source(16384);
                        pread(sourceFd, source.data(), 16384, int64_t(tailPiece) * ti->piece_length());
                        return memcmp(source.data(), probe.blocks[tailPiece].data(), 16384) == 0;
                    }();
                check(probe.unchoked && tailOk, "probe gets real data for a kept piece", "unchoked %d, tail piece %d block ok %d",
                      int(probe.unchoked.load()), tailPiece, int(tailOk));
                if (bounded) {
                    bool const freedNow = freedPiece >= 0 && ![streamer isRangeAvailable:int64_t(freedPiece) * ti->piece_length() length:1];
                    check(freedPiece >= 0 && freedNow && probe.rejected.count(freedPiece) && !probe.blocks.count(freedPiece)
                          && !probe.advertised.count(freedPiece),
                          "freed piece refused to the peer",
                          "piece %d: freed %d, rejected %d, data received %d, withdrawn by lt_donthave %d, still advertised %d",
                          freedPiece, int(freedNow), int(probe.rejected.count(freedPiece)), int(probe.blocks.count(freedPiece)),
                          int(probe.withdrawn.count(freedPiece)), int(probe.advertised.count(freedPiece)));
                    logLine("probe: %d pieces advertised now, %d lt_donthave received, %d rejects",
                            int(probe.advertised.size()), int(probe.withdrawn.size()), int(probe.rejected.size()));
                }
            }
        }

        if (!checksDone && offset >= int64_t(double(size) * o.checksAt)) {
            checksDone = true;
            headRead = fetchRange(sourceFd, 0, 1 * MiB);
            check(headRead.status == 206 && headRead.matches, "head still readable", "status %d, match %d", headRead.status, int(headRead.matches));
            tailRead = fetchRange(sourceFd, size - 1 * MiB, 1 * MiB);
            check(tailRead.status == 206 && tailRead.matches, "tail still readable", "status %d, match %d", tailRead.status, int(tailRead.matches));
            int64_t const lowest = streamer.lowestAvailableOffset;
            NSDictionary *stats = streamer.storageStatistics;
            int64_t const headPin = [stats[@"headPinEnd"] longLongValue];
            if (bounded) {
                // lowestAvailableOffset also covers consumed pieces queued for the next
                // batch (up to 32 MiB or 1 s): probe well below it.
                freedOffset = (lowest - 64 * MiB) / ti->piece_length() * ti->piece_length() + 4096;
                bool const inFreedRange = freedOffset > headPin + ti->piece_length();
                freedRead = fetchRange(sourceFd, freedOffset, 64 * 1024, 10);
                check(inFreedRange && freedRead.status == 410 && freedRead.seconds < 0.5, "freed range fails fast",
                      "offset %lld (lowest available %lld, head pin %lld): status %d in %.3f s", freedOffset, lowest, headPin,
                      freedRead.status, freedRead.seconds);
                BOOL const available = [streamer isRangeAvailable:freedOffset length:1];
                int64_t const firstMissing = [streamer firstMissingOffsetFrom:freedOffset];
                check(!available && firstMissing == freedOffset && lowest > freedOffset, "availability API",
                      "isRangeAvailable %d, firstMissing %lld, lowest %lld", int(available), firstMissing, lowest);
            } else {
                RangeResult early = fetchRange(sourceFd, 64 * MiB, 1 * MiB);
                check(early.status == 206 && early.matches, "full mode keeps everything", "rewind read status %d match %d", early.status, int(early.matches));
            }

        }

        int64_t const want = std::min<int64_t>(MiB, size - offset);
        Clock::time_point const r = Clock::now();
        int64_t const got = http.readFull(chunk.data(), want);
        double const waited = since(r);
        if (waited > 0.2) {
            stall += waited;
            if (waited > 1.0) logLine("stall: %.1f s waiting at %lld (first missing from there %lld)", waited, offset, [streamer firstMissingOffsetFrom:offset]);
        }
        if (got != want) {
            logLine("main stream ended early at %lld (got %lld of %lld)", offset, got, want);
            break;
        }
        pread(sourceFd, expected.data(), size_t(want), offset);
        if (memcmp(chunk.data(), expected.data(), size_t(want)) != 0) {
            ++mismatches;
            bool zero = true;
            for (int64_t i = 0; i < want && zero; ++i) zero = chunk[size_t(i)] == 0;
            if (zero) ++zeroChunks;
            if (mismatches < 5) logLine("MISMATCH at %lld (zeros %d)", offset, int(zero));
        }
        CC_SHA256_Update(&ctx, chunk.data(), CC_LONG(want));
        offset += want;
        consumerOffset = offset;
        streamer.consumedBefore = std::max<int64_t>(0, offset - o.keepBehind);

        if (offset % (512 * MiB) == 0) {
            NSDictionary *stats = streamer.storageStatistics;
            logLine("read %lld MiB, on disk %lld MiB, free %lld MiB, ahead %lld MiB / %lld, pace %d limit %d, freed %d, lowest %lld",
                    offset / MiB, streamer.bytesOnDisk / MiB, volumeFree(o.volume) / MiB, [stats[@"aheadBytes"] longLongValue] / MiB,
                    [stats[@"aheadBudget"] longLongValue] / MiB, [stats[@"paceState"] intValue], [stats[@"downloadLimit"] intValue],
                    [stats[@"freedPieces"] intValue], [stats[@"lowestAvailableOffset"] longLongValue]);
        }
        // Steady rate without catch-up bursts after a wait.
        nextRead = std::max(nextRead, Clock::now()) + std::chrono::microseconds(int64_t(double(want) / o.rate * 1e6));
        std::this_thread::sleep_until(nextRead);
    }
    http.close();
    concurrentRunning = false;
    if (concurrent.joinable()) concurrent.join();
    double const consumeSeconds = since(consumeStart);

    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    char hex[65];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) snprintf(hex + 2 * i, 3, "%02x", digest[i]);
    NSDictionary *endStats = streamer.storageStatistics;
    logLine("end: %s", [[endStats description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "].UTF8String);

    check(offset == size, "whole file read", "%lld of %lld bytes in %.1f s (%.1f s paused, %.1f s stalled)", offset, size, consumeSeconds, pausedTime, stall);
    check(sourceSha == hex, "content hash", "sha256 read %s, source %s", hex, sourceSha.c_str());
    check(mismatches == 0 && zeroChunks == 0, "no wrong bytes", "%lld mismatching MiB, %lld all-zero MiB", mismatches, zeroChunks);
    // With a ballast that fills the volume, ENOSPC is expected: it must not end the stream.
    int const fileErrors = [endStats[@"fileErrors"] intValue];
    int const diskFullEvents = [endStats[@"diskFullEvents"] intValue];
    check(!failed && (o.ballastHold > 0 ? fileErrors == diskFullEvents : fileErrors == 0), "no file error",
          "fileErrors %d, diskFull %d, failure block %d", fileErrors, diskFullEvents, int(failed.load()));
    check(concurrentBad == 0 && concurrentOk > 0, "concurrent requests", "%d ok, %d bad", concurrentOk.load(), concurrentBad.load());

    // Space accounting from the samples.
    sampling = false;
    sampler.join();
    int64_t const reserve = [endStats[@"reserveBytes"] longLongValue];
    int64_t const budget = [endStats[@"torrentBudget"] longLongValue];
    // Plateau: from a quarter of the file until the window ahead reaches the end of the file.
    int64_t const plateauEnd = size - budget - 128 * MiB;
    int64_t minFree = INT64_MAX, maxOnDisk = 0, minFreeOutsideBallast = INT64_MAX;
    std::vector<Sample> plateau, pause;
    std::map<int, int> paceHistogram;
    for (Sample const& s : samples) {
        minFree = std::min(minFree, s.free);
        maxOnDisk = std::max(maxOnDisk, s.onDisk);
        paceHistogram[s.pace]++;
        bool const inBallast = o.ballast > 0 && s.consumer >= int64_t(double(size) * 0.33) && s.consumer <= int64_t(double(size) * 0.57);
        if (!inBallast) minFreeOutsideBallast = std::min(minFreeOutsideBallast, s.free);
        if (s.consumer >= size / 4 && s.consumer <= plateauEnd && !inBallast) plateau.push_back(s);
        if (pauseStartT >= 0 && s.t >= pauseStartT && s.t <= pauseEndT) pause.push_back(s);
    }
    auto mean = [](std::vector<Sample>::const_iterator b, std::vector<Sample>::const_iterator e) {
        double sum = 0; int n = 0;
        for (auto it = b; it != e; ++it) { sum += double(it->onDisk); ++n; }
        return n ? sum / n : 0.0;
    };
    int64_t plateauMin = INT64_MAX, plateauMax = 0;
    for (Sample const& s : plateau) { plateauMin = std::min(plateauMin, s.onDisk); plateauMax = std::max(plateauMax, s.onDisk); }
    double const firstHalf = mean(plateau.begin(), plateau.begin() + long(plateau.size() / 2));
    double const secondHalf = mean(plateau.begin() + long(plateau.size() / 2), plateau.end());
    logLine("samples %zu: min free %lld MiB (outside ballast %lld MiB), max on disk %lld MiB, budget %lld MiB, reserve %lld MiB",
            samples.size(), minFree / MiB, minFreeOutsideBallast / MiB, maxOnDisk / MiB, budget / MiB, reserve / MiB);
    logLine("plateau (%zu samples, read offset %lld..%lld MiB): on disk %lld..%lld MiB, mean %.0f MiB then %.0f MiB",
            plateau.size(), size / 4 / MiB, plateauEnd / MiB, plateau.empty() ? 0 : plateauMin / MiB, plateauMax / MiB,
            firstHalf / MiB, secondHalf / MiB);
    std::string histogram;
    for (auto const& entry : paceHistogram) histogram += std::to_string(entry.first) + ":" + std::to_string(entry.second) + " ";
    logLine("pace states (0 open, 1 proportional, 2 floor, 3 trickle, 4 emergency) in samples: %s", histogram.c_str());
    if (bounded) {
        check(minFreeOutsideBallast >= reserve, "free space never below the reserve", "min free %lld MiB, reserve %lld MiB",
              minFreeOutsideBallast / MiB, reserve / MiB);
        check(maxOnDisk <= budget + 64 * MiB, "torrent stays within its budget", "max on disk %lld MiB, budget %lld MiB",
              maxOnDisk / MiB, budget / MiB);
        check(!plateau.empty() && plateauMax <= budget + 64 * MiB && secondHalf - firstHalf <= 0.1 * double(budget),
              "disk use flat once the window is full", "%lld..%lld MiB while %lld MiB went through, mean %.0f then %.0f MiB",
              plateauMin / MiB, plateauMax / MiB, (plateauEnd - size / 4) / MiB, firstHalf / MiB, secondHalf / MiB);
        if (!pause.empty()) {
            size_t full = 0;
            while (full < pause.size() && pause[full].pace < 2) ++full;
            if (full == pause.size()) full = pause.size() - 1;
            double const flatSeconds = pause.back().t - pause[full].t;
            int64_t const growth = pause.back().onDisk - pause[full].onDisk;
            check(growth <= int64_t(64 * 1024 * flatSeconds) + 16 * MiB, "disk flat during the pause",
                  "window full %.0f s into the %.0f s pause; then on disk %lld -> %lld MiB over %.0f s (%.1f KiB/s), free %lld -> %lld MiB",
                  pause[full].t - pause.front().t, pauseEndT - pauseStartT, pause[full].onDisk / MiB, pause.back().onDisk / MiB,
                  flatSeconds, flatSeconds > 0 ? double(growth) / 1024 / flatSeconds : 0.0, pause.front().free / MiB, pause.back().free / MiB);
        }
        check([endStats[@"freedPieces"] intValue] > 0 && [endStats[@"punchErrors"] intValue] == 0, "pieces freed by punching holes",
              "%d pieces freed, %lld bytes punched, %d punch errors, %d lt_donthave sent",
              [endStats[@"freedPieces"] intValue], [endStats[@"punchedBytes"] longLongValue], [endStats[@"punchErrors"] intValue],
              [endStats[@"dontHaveSent"] intValue]);
    } else {
        check(streamer.bytesOnDisk >= size, "full mode keeps the whole file", "on disk %lld of %lld", streamer.bytesOnDisk, size);
        check([endStats[@"freedPieces"] intValue] == 0, "full mode frees nothing", "%d freed", [endStats[@"freedPieces"] intValue]);
    }

    // Cancel: everything is given back.
    NSString *savePath = streamer.savePath;
    int64_t const beforeCancel = volumeFree(o.volume);
    dispatch_sync(dispatch_get_main_queue(), ^{
        [streamer cancelStreamingAndDeleteData:YES];
    });
    std::this_thread::sleep_for(std::chrono::seconds(5));
    int64_t const afterCancel = volumeFree(o.volume);
    bool const gone = savePath == nil || ![[NSFileManager defaultManager] fileExistsAtPath:savePath];
    check(gone && afterCancel >= baselineFree - 16 * MiB, "cancel frees all space",
          "free before start %lld MiB, before cancel %lld MiB, 5 s after cancel %lld MiB, directory removed %d",
          baselineFree / MiB, beforeCancel / MiB, afterCancel / MiB, int(gone));

    lt::torrent_status const seedStatus = seedHandle.status();
    logLine("seeder uploaded %lld bytes (%.2f x the file)", seedStatus.total_upload, double(seedStatus.total_upload) / double(size));
    keepingAlive = false;
    probeKeepAlive.join();
    probe.stop();
    close(sourceFd);
    logLine("RESULT %s: %d failure(s)", o.mode.c_str(), gFailures);
    return gFailures;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        Options const options = parseOptions(argc, argv);
        if (options.workdir.empty() || options.volume.empty()) {
            fprintf(stderr, "usage: BoundedStorageHarness --workdir DIR --volume MOUNT [--mode bounded|full] [--size-mib N] "
                            "[--piece-kib N] [--rate-mbs N] [--budget-mib N] [--pause-seconds N] [--ballast-mib N]\n");
            return 2;
        }
        std::thread test([options] {
            int const result = runTest(options);
            exit(result);
        });
        test.detach();
        CFRunLoopRun(); // the streamer and GCDWebServer use the main queue
    }
    return 0;
}
