//
//  PTStreamController.h
//  PopcornTorrent
//
//  Per-stream controller shared by `PTTorrentStreamer` (any thread), its HTTP
//  responses (GCD queues) and a libtorrent torrent plugin (network thread).
//  It owns the piece availability map, plans the download window, paces the
//  download and, in bounded mode, deletes the pieces the consumer is done with.
//

#pragma once

#import <Foundation/Foundation.h>

#include <atomic>
#include <chrono>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <shared_mutex>
#include <string>
#include <vector>

#include "PTBoundedLogic.hpp"

namespace libtorrent {
struct torrent;
struct torrent_plugin;
struct torrent_handle;
}

namespace ptbounded {

class PeerPlugin;

struct StreamConfig {
    FileGeometry geometry;
    BudgetPlan budget;
    bool bounded = false;
    int64_t reserveBytes = kDefaultReserveBytes;
    int windowPieces = 1;                // deadline window (MIN_PIECES in full mode)
    int tailPieces = kTailPinPieces;     // pinned pieces at the end of the file
    int deadlineFirstMs = 100;
    int deadlineStepMs = 0;
    bool useDeadlines = true;            // libtorrent piece deadlines (time-critical pieces)
    std::string filePath;                // absolute path of the selected file
    std::string directoryPath;           // existing directory on the same volume
    std::vector<int32_t> requiredPieces; // must be on disk before the stream is ready
};

enum ReadResult : int {
    ReadOK = 0,
    ReadFreed = 1,     // the range was deleted (bounded mode); it will never come back
    ReadCancelled = 2,
    ReadIOError = 3,
    ReadTimedOut = 4,
    ReadUnwanted = 5,  // the reader was superseded and the piece is no longer downloaded
};

struct StreamStatistics {
    bool bounded = false;
    int64_t fileSize = 0;
    int64_t pieceLength = 0;
    int64_t torrentBudget = 0;
    int64_t aheadBudget = 0;
    int64_t aheadBytes = 0;
    int64_t behindBytes = 0;
    int64_t pinnedBytes = 0;
    int64_t dataBytes = 0;
    int64_t freeBytes = 0;
    int64_t reserveBytes = 0;
    int64_t readPosition = 0;
    int64_t consumedBefore = 0;
    int64_t lowestAvailableOffset = 0;
    int64_t servedOffset = 0;
    int64_t headPinEnd = 0;
    int64_t tailPinStart = 0;
    int64_t everDownloaded = 0;
    int64_t freedPieces = 0;
    int64_t droppedPieces = 0;
    int64_t punchedBytes = 0;
    int64_t punchErrors = 0;
    int64_t diskFullEvents = 0;
    int64_t fileErrors = 0;
    int64_t dontHaveSent = 0;
    int64_t waiters = 0;
    int downloadLimit = 0;
    int paceState = 0;
    double consumeRate = 0;
};

class StreamController : public std::enable_shared_from_this<StreamController> {
public:
    using ReadCallback = std::function<void(NSData *data, int result)>;

    StreamController();
    ~StreamController();
    StreamController(StreamController const&) = delete;
    StreamController& operator=(StreamController const&) = delete;

    // Any thread.
    void configure(StreamConfig const& config);
    bool isConfigured() const { return m_configured.load(); }
    bool isBounded() const { return m_bounded.load(); }
    int64_t fileSize() const { return m_configured ? m_config.geometry.fileSize : 0; }
    void setReadPosition(int64_t offset);
    void setConsumedBefore(int64_t offset);
    void setTorrentBudget(int64_t bytes);
    int64_t readPosition() const { return m_readPosition.load(); }
    int64_t consumedBefore() const { return m_consumedBefore.load(); }
    int64_t lowestAvailableOffset() const { return m_lowestAvailable.load(); }
    int64_t servedOffset() const { return m_servedOffset.load(); }
    int64_t everDownloadedBytes() const { return m_everDownloaded.load(); }
    int64_t firstMissingOffset(int64_t from) const;
    bool isRangeOnDisk(int64_t offset, int64_t length) const;
    bool isOffsetFreed(int64_t offset) const;
    bool isFileComplete() const;
    int64_t bytesOnDisk() const;
    int64_t freeBytes() const;
    std::pair<int, int> requiredProgress() const;
    float windowProgress() const;
    StreamStatistics statistics() const;
    /// HTTP readers. The primary reader (the one streaming) drives the read
    /// position; pieces any reader waits for are fetched first.
    int64_t openReader(int64_t start);
    void closeReader(int64_t reader);
    /// Reads up to `maxLength` bytes at `offset` once they are on disk.
    void readAsync(int64_t reader, int64_t offset, int64_t maxLength, ReadCallback callback);
    void noteFileError(bool diskFull);
    void setAvailabilityHandler(std::function<void()> handler);
    void cancel();
    void requestUpdate();

    // libtorrent network thread only (called by the plugin).
    void attach(libtorrent::torrent& torrent);
    void addPeer(std::shared_ptr<PeerPlugin> const& peer);
    void onPiecePassed(libtorrent::torrent& torrent, int32_t piece);
    void onTick(libtorrent::torrent& torrent);

private:
    std::atomic<uint8_t>& slot(int32_t piece) const;
    uint8_t stateOf(int32_t piece) const;
    bool inFile(int32_t piece) const;
    PinSet pins() const;
    void apply(libtorrent::torrent& torrent, bool fromTick);
    void applyPriorities(libtorrent::torrent& torrent, std::vector<uint8_t> const& priorities);
    void applyDeadlines(libtorrent::torrent& torrent, std::vector<std::pair<int32_t, int>> const& deadlines);
    void releasePieces(libtorrent::torrent& torrent, std::vector<int32_t> const& pieces, uint8_t newState);
    bool isPinnedOffset(int64_t offset) const;
    void sweepWaiters(PlanOutput const& plan);
    void scheduleVerify(int32_t piece, int attempt);
    void verify(int32_t piece, int attempt);
    void punch(int32_t piece, uint8_t newState);
    void markOnDisk(int32_t piece);
    void scheduleHeadParse();
    void parseHead();
    void performRead(int64_t reader, int64_t offset, int64_t maxLength, ReadCallback callback);
    void noteServed(int64_t reader, int64_t offset, int64_t end);
    void moveReadPosition(int64_t offset);
    void requestFlush(int32_t piece);
    void failWaiters(int32_t piece, int result);
    void notifyAvailability();
    int fileDescriptor();

    StreamConfig m_config;
    std::atomic<bool> m_configured{false};
    std::atomic<bool> m_bounded{false};
    std::atomic<bool> m_cancelled{false};
    std::unique_ptr<std::atomic<uint8_t>[]> m_states;
    int32_t m_count = 0;
    int32_t m_first = 0;

    std::atomic<int64_t> m_readPosition{0};
    std::atomic<int64_t> m_consumedBefore{0};
    std::atomic<int64_t> m_lowestAvailable{0};
    std::atomic<int64_t> m_servedOffset{0};
    std::atomic<int64_t> m_everDownloaded{0};
    std::atomic<int64_t> m_requestedBudget{0};
    std::atomic<int32_t> m_plannedReadPiece{-1};
    std::atomic<int32_t> m_plannedConsumedPiece{-1};

    // Head pins (bounded mode).
    std::atomic<int64_t> m_headPinEnd{kHeadPinLimit};
    std::atomic<int64_t> m_parsedTailStart{-1};
    std::atomic<bool> m_headParsed{false};
    std::atomic<bool> m_headParseScheduled{false};
    std::atomic<int32_t> m_parserNeedPiece{-1};

    // Statistics.
    std::atomic<int64_t> m_aheadBytes{0}, m_behindBytes{0}, m_pinnedBytes{0}, m_dataBytes{0};
    std::atomic<int64_t> m_aheadBudget{0}, m_lastFreeBytes{0};
    std::atomic<int64_t> m_freedPieces{0}, m_droppedPieces{0}, m_punchedBytes{0}, m_punchErrors{0};
    std::atomic<int64_t> m_diskFullEvents{0}, m_fileErrors{0}, m_dontHaveSent{0};
    std::atomic<int64_t> m_pendingPunches{0}, m_allocatedBytes{0};
    std::atomic<int> m_downloadLimit{0}, m_paceState{0};
    std::atomic<int> m_windowTotal{0}, m_windowOnDisk{0};
    std::atomic<double> m_consumeRate{0};
    std::atomic<int> m_shrinkPercent{100};
    std::atomic<bool> m_diskFullPending{false};

    // Network thread.
    std::weak_ptr<libtorrent::torrent> m_torrent;
    std::atomic<void *> m_io{nullptr};
    std::atomic<bool> m_updatePosted{false};
    std::vector<uint8_t> m_appliedPriorities;
    std::map<int32_t, int> m_appliedDeadlines;
    bool m_initialSynced = false;
    int m_appliedLimit = -1;
    int64_t m_lastTickReadPosition = -1;
    std::vector<std::weak_ptr<PeerPlugin>> m_peers;
    std::vector<uint8_t> m_lastPlanPriorities;

    // HTTP readers waiting for a piece (guarded by m_mutex).
    struct Waiter {
        std::chrono::steady_clock::time_point since;
        std::function<void(int)> resume;
    };
    struct Reader {
        int64_t end = 0;
        int64_t served = 0;
        std::chrono::steady_clock::time_point lastServed;
    };
    mutable std::mutex m_mutex;
    std::multimap<int32_t, Waiter> m_waiters;
    std::map<int64_t, Reader> m_readers;
    int64_t m_nextReader = 0;
    int64_t m_primaryReader = -1;
    std::function<void()> m_availabilityHandler;

    // File access: one O_RDWR descriptor shared by reads and hole punching.
    mutable std::shared_mutex m_fdLock;
    int m_fd = -1;
    dispatch_queue_t m_ioQueue;
    dispatch_queue_t m_readQueue;
};

/// Factory for `add_torrent_params::extensions`.
std::function<std::shared_ptr<libtorrent::torrent_plugin>(libtorrent::torrent_handle const&, void *)>
makeStreamPluginFactory(std::shared_ptr<StreamController> const& controller);

} // namespace ptbounded
