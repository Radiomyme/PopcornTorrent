//
//  PTStreamController.mm
//  PopcornTorrent
//

#import "PTStreamController.h"

#include <fcntl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>

#include <libtorrent/torrent.hpp>
#include <libtorrent/extensions.hpp>
#include <libtorrent/peer_connection.hpp>
#include <libtorrent/peer_connection_handle.hpp>
#include <libtorrent/peer_info.hpp>
#include <libtorrent/bdecode.hpp>
#include <libtorrent/piece_picker.hpp>
#include <libtorrent/disk_interface.hpp>
#include <libtorrent/hasher.hpp>
#include <libtorrent/aux_/session_interface.hpp>
#include <boost/asio/post.hpp>

namespace lt = libtorrent;

namespace ptbounded {

namespace {

constexpr int64_t kBlock = 4096;            // APFS hole granularity (f_bsize, _PC_MIN_HOLE_SIZE)
constexpr int64_t kMaxReadChunk = 1 * kMiB; // largest chunk handed to one HTTP write
// Bounded mode: a waiting read of a reader that is not the streaming one (a prefetch, an
// abandoned request) gives up after this, so it does not keep its piece urgent forever.
constexpr auto kWaiterTimeout = std::chrono::seconds(120);
// A primary HTTP reader silent for this long hands the read position to another one.
constexpr auto kPrimaryReaderSilence = std::chrono::milliseconds(2000);
// Pieces are freed in batches behind one disk fence (async_clear_piece blocks the storage).
constexpr int64_t kFreeBatchBytes = 32 * kMiB;
// Retry delay of a verification by content (it reads the whole piece back).
constexpr int64_t kContentRetryNanos = 200 * NSEC_PER_MSEC;

int64_t alignUp(int64_t value) { return (value + kBlock - 1) / kBlock * kBlock; }

// Set PT_BOUNDED_DEBUG=1 in the environment to trace the controller once a second.
bool debugTrace() {
    static bool const enabled = getenv("PT_BOUNDED_DEBUG") != nullptr;
    return enabled;
}
int64_t alignDown(int64_t value) { return value / kBlock * kBlock; }

} // namespace

#pragma mark - Peer plugin (lt_donthave)

/// Remembers the peer's lt_donthave message id so freed pieces can be withdrawn,
/// the same message libtorrent sends itself (bt_peer_connection::write_dont_have).
class PeerPlugin final : public lt::peer_plugin {
public:
    explicit PeerPlugin(lt::peer_connection_handle const& connection) : m_connection(connection) {}

    bool on_extension_handshake(lt::bdecode_node const& handshake) override {
        if (handshake.type() != lt::bdecode_node::dict_t) return true;
        lt::bdecode_node const messages = handshake.dict_find_dict("m");
        if (messages) m_dontHaveId = int(messages.dict_find_int_value("lt_donthave", 0));
        return true;
    }

    bool sendDontHave(int32_t piece) {
        if (m_dontHaveId <= 0 || m_dontHaveId > 255 || m_connection.is_disconnecting()) return false;
        char message[10] = {0, 0, 0, 6, 20, char(m_dontHaveId),
            char(piece >> 24), char(piece >> 16), char(piece >> 8), char(piece)};
        m_connection.send_buffer(message, int(sizeof(message)));
        return true;
    }

private:
    lt::peer_connection_handle m_connection;
    int m_dontHaveId = 0;
};

#pragma mark - Torrent plugin

namespace {

class StreamPlugin final : public lt::torrent_plugin {
public:
    StreamPlugin(lt::torrent& torrent, std::shared_ptr<StreamController> controller)
        : m_torrent(torrent), m_controller(std::move(controller)) {}

    std::shared_ptr<lt::peer_plugin> new_connection(lt::peer_connection_handle const& connection) override {
        if (connection.type() != lt::connection_type::bittorrent) return nullptr;
        auto peer = std::make_shared<PeerPlugin>(connection);
        m_controller->addPeer(peer);
        return peer;
    }

    void on_piece_pass(lt::piece_index_t piece) override {
        m_controller->onPiecePassed(m_torrent, int32_t(static_cast<int>(piece)));
    }

    void on_piece_failed(lt::piece_index_t piece) override {
        m_controller->onPieceFailed(int32_t(static_cast<int>(piece)));
    }

    void on_files_checked() override { m_controller->requestUpdate(); }

    void tick() override { m_controller->onTick(m_torrent); }

private:
    lt::torrent& m_torrent;
    std::shared_ptr<StreamController> m_controller;
};

} // namespace

std::function<std::shared_ptr<lt::torrent_plugin>(lt::torrent_handle const&, void *)>
makeStreamPluginFactory(std::shared_ptr<StreamController> const& controller) {
    std::weak_ptr<StreamController> weak = controller;
    return [weak](lt::torrent_handle const& handle, void *) -> std::shared_ptr<lt::torrent_plugin> {
        auto controller = weak.lock();
        auto torrent = handle.native_handle();
        if (!controller || !torrent) return nullptr;
        auto plugin = std::make_shared<StreamPlugin>(*torrent, controller);
        controller->attach(*torrent, plugin);
        return plugin;
    };
}

#pragma mark - StreamController

StreamController::StreamController() {
    m_ioQueue = dispatch_queue_create("com.popcorntimetv.popcorntorrent.bounded.io", DISPATCH_QUEUE_SERIAL);
    m_readQueue = dispatch_queue_create("com.popcorntimetv.popcorntorrent.bounded.read", DISPATCH_QUEUE_CONCURRENT);
}

StreamController::~StreamController() {
    std::unique_lock<std::shared_mutex> lock(m_fdLock);
    if (m_fd >= 0) close(m_fd);
    m_fd = -1;
}

void StreamController::configure(StreamConfig const& config) {
    if (m_configured.load() || !config.geometry.valid()) return;
    m_config = config;
    m_first = config.geometry.firstPiece();
    m_count = config.geometry.pieceCount();
    m_states.reset(new std::atomic<uint8_t>[size_t(m_count)]);
    m_suspect.reset(new std::atomic<bool>[size_t(m_count)]);
    for (int32_t i = 0; i < m_count; ++i) {
        m_states[size_t(i)].store(PieceMissing);
        m_suspect[size_t(i)].store(false);
    }
    // Without holes (HFS+, exFAT) SEEK_HOLE cannot tell written blocks from unwritten ones.
    m_holesSupported = !config.directoryPath.empty() && pathconf(config.directoryPath.c_str(), _PC_MIN_HOLE_SIZE) > 0;
    m_bounded.store(config.bounded);
    m_headPinEnd.store(config.bounded ? kHeadPinLimit : 0);
    m_lastFreeBytes.store(freeBytes());
    m_configured.store(true);
    requestUpdate();
}

std::atomic<uint8_t>& StreamController::slot(int32_t piece) const {
    return m_states[size_t(piece - m_first)];
}

bool StreamController::inFile(int32_t piece) const {
    return m_configured.load() && piece >= m_first && piece < m_first + m_count;
}

uint8_t StreamController::stateOf(int32_t piece) const {
    return inFile(piece) ? slot(piece).load() : uint8_t(PieceMissing);
}

PinSet StreamController::pins() const {
    PinSet pins;
    FileGeometry const& geo = m_config.geometry;
    int32_t const tailFirst = std::max(geo.firstPiece(), geo.lastPiece() - std::max(1, m_config.tailPieces) + 1);
    pins.tailStart = geo.pieceBegin(tailFirst);
    if (m_bounded.load()) {
        pins.headEnd = m_headPinEnd.load();
        int64_t const parsedTail = m_parsedTailStart.load();
        if (parsedTail >= 0) pins.tailStart = std::min(pins.tailStart, parsedTail);
        pins.extraPiece = m_parserNeedPiece.load();
    }
    return pins;
}

#pragma mark Positions

void StreamController::setReadPosition(int64_t offset) {
    m_readPosition.store(std::max<int64_t>(0, offset));
    if (!m_configured.load()) return;
    if (m_config.geometry.pieceAt(offset) != m_plannedReadPiece.load()) requestUpdate();
}

void StreamController::setConsumedBefore(int64_t offset) {
    int64_t current = m_consumedBefore.load();
    while (offset > current && !m_consumedBefore.compare_exchange_weak(current, offset)) {}
    if (!m_configured.load() || !m_bounded.load()) return;
    if (m_config.geometry.pieceAt(offset) != m_plannedConsumedPiece.load()) requestUpdate();
}

void StreamController::setTorrentBudget(int64_t bytes) {
    m_requestedBudget.store(std::max<int64_t>(0, bytes));
    requestUpdate();
}

void StreamController::moveReadPosition(int64_t offset) {
    m_readPosition.store(std::max<int64_t>(0, offset));
    if (m_config.geometry.pieceAt(offset) != m_plannedReadPiece.load()) requestUpdate();
}

#pragma mark Availability queries

int64_t StreamController::firstMissingOffset(int64_t from) const {
    if (!m_configured.load()) return std::max<int64_t>(0, from);
    FileGeometry const& geo = m_config.geometry;
    if (from >= geo.fileSize) return geo.fileSize;
    from = std::max<int64_t>(0, from);
    for (int32_t piece = geo.pieceAt(from); piece <= geo.lastPiece(); ++piece) {
        if (stateOf(piece) != PieceOnDisk) return std::max(from, geo.pieceBegin(piece));
    }
    return geo.fileSize;
}

bool StreamController::isRangeOnDisk(int64_t offset, int64_t length) const {
    if (!m_configured.load() || length <= 0) return false;
    FileGeometry const& geo = m_config.geometry;
    if (offset < 0 || offset + length > geo.fileSize) return false;
    for (int32_t piece = geo.pieceAt(offset); piece <= geo.pieceAt(offset + length - 1); ++piece) {
        if (stateOf(piece) != PieceOnDisk) return false;
    }
    return true;
}

bool StreamController::isOffsetFreed(int64_t offset) const {
    if (!m_configured.load()) return false;
    return stateOf(m_config.geometry.pieceAt(offset)) == PieceFreed;
}

bool StreamController::isOffsetGone(int64_t offset) const {
    if (!m_configured.load() || !m_bounded.load()) return false;
    int32_t const piece = m_config.geometry.pieceAt(offset);
    return isGone(m_config.geometry, pins(), stateOf(piece), piece, m_consumedBefore.load());
}

int64_t StreamController::lowestAvailableOffset() const {
    if (!m_configured.load() || !m_bounded.load()) return 0;
    // The plan's value lags the consumer by one plan; the consumed floor does not.
    int64_t const floor = consumedFloor(m_config.geometry, pins(), m_consumedBefore.load());
    return std::min(m_config.geometry.fileSize, std::max(m_lowestAvailable.load(), floor));
}

int64_t StreamController::contiguousAvailableStart(int64_t offset) const {
    if (!m_configured.load()) return std::max<int64_t>(0, offset);
    return ptbounded::contiguousAvailableStart(m_config.geometry, snapshotStates(), pins(), m_bounded.load(),
                                               m_consumedBefore.load(), offset);
}

bool StreamController::allPiecesHaveData() const {
    if (!m_configured.load()) return false;
    for (int32_t i = 0; i < m_count; ++i) {
        if (!pieceHasData(m_states[size_t(i)].load())) return false;
    }
    return true;
}

bool StreamController::isFileComplete() const {
    if (!m_configured.load()) return false;
    for (int32_t i = 0; i < m_count; ++i) {
        if (m_states[size_t(i)].load() != PieceOnDisk) return false;
    }
    return true;
}

int64_t StreamController::bytesOnDisk() const {
    if (!m_configured.load()) return 0;
    struct stat info;
    if (stat(m_config.filePath.c_str(), &info) != 0) return 0;
    return int64_t(info.st_blocks) * 512;
}

int64_t StreamController::freeBytes() const {
    struct statfs info;
    if (m_config.directoryPath.empty() || statfs(m_config.directoryPath.c_str(), &info) != 0) return INT64_MAX;
    return int64_t(info.f_bavail) * int64_t(info.f_bsize);
}

std::pair<int, int> StreamController::requiredProgress() const {
    if (!m_configured.load()) return {0, 0};
    int done = 0;
    for (int32_t piece : m_config.requiredPieces) {
        if (stateOf(piece) == PieceOnDisk) ++done;
    }
    return {done, int(m_config.requiredPieces.size())};
}

float StreamController::windowProgress() const {
    int const total = m_windowTotal.load();
    return total > 0 ? float(m_windowOnDisk.load()) / float(total) : 1.0f;
}

StreamStatistics StreamController::statistics() const {
    StreamStatistics s;
    s.bounded = m_bounded.load();
    if (m_configured.load()) {
        s.fileSize = m_config.geometry.fileSize;
        s.pieceLength = m_config.geometry.pieceLength;
        s.torrentBudget = m_requestedBudget.load() > 0 ? m_requestedBudget.load() : m_config.budget.torrentBudget;
        s.reserveBytes = m_config.reserveBytes;
        PinSet const pinSet = pins();
        s.headPinEnd = pinSet.headEnd;
        s.tailPinStart = pinSet.tailStart;
    }
    s.aheadBudget = m_aheadBudget.load();
    s.aheadBytes = m_aheadBytes.load();
    s.behindBytes = m_behindBytes.load();
    s.pinnedBytes = m_pinnedBytes.load();
    s.dataBytes = m_dataBytes.load();
    s.freeBytes = m_lastFreeBytes.load();
    s.readPosition = m_readPosition.load();
    s.consumedBefore = m_consumedBefore.load();
    s.lowestAvailableOffset = lowestAvailableOffset();
    s.servedOffset = m_servedOffset.load();
    s.everDownloaded = m_everDownloaded.load();
    s.freedPieces = m_freedPieces.load();
    s.droppedPieces = m_droppedPieces.load();
    s.punchedBytes = m_punchedBytes.load();
    s.punchErrors = m_punchErrors.load();
    s.diskFullEvents = m_diskFullEvents.load();
    s.fileErrors = m_fileErrors.load();
    s.dontHaveSent = m_dontHaveSent.load();
    s.partialPunched = m_partialPunched.load();
    s.downloadLimit = m_downloadLimit.load();
    s.paceState = m_paceState.load();
    s.consumeRate = m_consumeRate.load();
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        s.waiters = int64_t(m_waiters.size());
    }
    return s;
}

void StreamController::setAvailabilityHandler(std::function<void()> handler) {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_availabilityHandler = std::move(handler);
}

void StreamController::notifyAvailability() {
    std::function<void()> handler;
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        handler = m_availabilityHandler;
    }
    if (handler) handler();
}

#pragma mark Errors and cancellation

void StreamController::noteFileError(bool diskFull) {
    m_fileErrors.fetch_add(1);
    if (!diskFull || !m_bounded.load()) return;
    m_diskFullEvents.fetch_add(1);
    // Keep less ahead of the reader for the rest of the stream, then free space and resume.
    int shrink = m_shrinkPercent.load();
    m_shrinkPercent.store(std::max(50, shrink * 3 / 4));
    m_diskFullPending.store(true);
    requestUpdate();
}

void StreamController::cancel() {
    if (m_cancelled.exchange(true)) return;
    std::multimap<int32_t, Waiter> waiters;
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        waiters.swap(m_waiters);
        m_availabilityHandler = nullptr;
    }
    for (auto& entry : waiters) entry.second.resume(ReadCancelled);
    // Close the descriptor now so the space of a deleted file is given back at once.
    std::unique_lock<std::shared_mutex> lock(m_fdLock);
    if (m_fd >= 0) close(m_fd);
    m_fd = -1;
}

int StreamController::fileDescriptor() {
    {
        std::shared_lock<std::shared_mutex> lock(m_fdLock);
        if (m_fd >= 0 || m_cancelled.load()) return m_fd;
    }
    std::unique_lock<std::shared_mutex> lock(m_fdLock);
    if (m_fd < 0 && !m_cancelled.load() && !m_config.filePath.empty()) {
        // libtorrent creates the file on its first write; never create it here.
        m_fd = open(m_config.filePath.c_str(), O_RDWR | O_CLOEXEC);
    }
    return m_fd;
}

#pragma mark Updates (any thread -> network thread)

void StreamController::requestUpdate() {
    if (m_cancelled.load()) return;
    void *io = m_io.load(std::memory_order_acquire);
    if (io == nullptr || m_updatePosted.exchange(true)) return;
    std::weak_ptr<StreamController> weak = weak_from_this();
    std::weak_ptr<lt::torrent> weakTorrent = m_torrent;
    boost::asio::post(*static_cast<lt::io_service *>(io), [weak, weakTorrent] {
        auto self = weak.lock();
        if (!self) return;
        self->m_updatePosted.store(false);
        if (auto torrent = weakTorrent.lock()) self->apply(*torrent, false);
    });
}

void StreamController::attach(lt::torrent& torrent, std::weak_ptr<lt::torrent_plugin> const& plugin) {
    m_torrent = torrent.shared_from_this();
    m_plugin = plugin;
    m_io.store(&torrent.session().get_io_service(), std::memory_order_release);
}

#pragma mark Shared torrents (a stream joined a download's torrent)

void StreamController::suspendPlanning() {
    m_suspended.store(true);
    void *io = m_io.load(std::memory_order_acquire);
    if (io == nullptr) return;
    auto self = shared_from_this();
    std::weak_ptr<lt::torrent> weakTorrent = m_torrent;
    // Deadlines are per piece, not per controller: drop ours before the next controller sets its own.
    boost::asio::post(*static_cast<lt::io_service *>(io), [self, weakTorrent] {
        auto torrent = weakTorrent.lock();
        if (torrent && !torrent->is_aborted() && self->m_suspended.load()) self->resetDeadlines(*torrent);
    });
}

void StreamController::resumePlanning() {
    void *io = m_io.load(std::memory_order_acquire);
    if (io == nullptr) { m_suspended.store(false); return; }
    auto self = shared_from_this();
    std::weak_ptr<lt::torrent> weakTorrent = m_torrent;
    // Cleared on the network thread: an update already queued still sees the suspension.
    boost::asio::post(*static_cast<lt::io_service *>(io), [self, weakTorrent] {
        self->m_suspended.store(false);
        auto torrent = weakTorrent.lock();
        if (torrent) self->apply(*torrent, false);
    });
}

void StreamController::detach(std::shared_ptr<StreamController> const& next) {
    void *io = m_io.load(std::memory_order_acquire);
    if (io == nullptr) {
        // Never attached to the torrent: nothing of ours to undo.
        if (next) next->resumePlanning();
        return;
    }
    auto self = shared_from_this();
    std::weak_ptr<lt::torrent> weakTorrent = m_torrent;
    boost::asio::post(*static_cast<lt::io_service *>(io), [self, next, weakTorrent] {
        auto torrent = weakTorrent.lock();
        if (torrent && !torrent->is_aborted()) {
            self->resetDeadlines(*torrent);
            if (auto plugin = self->m_plugin.lock()) torrent->remove_extension(plugin);
        }
        self->m_plugin.reset();
        if (next) {
            next->m_suspended.store(false);
            auto nextTorrent = next->m_torrent.lock();
            if (nextTorrent) next->apply(*nextTorrent, false);
        }
    });
}

void StreamController::resetDeadlines(lt::torrent& torrent) {
    for (auto const& entry : m_appliedDeadlines) torrent.reset_piece_deadline(lt::piece_index_t(entry.first));
    m_appliedDeadlines.clear();
}

void StreamController::addPeer(std::shared_ptr<PeerPlugin> const& peer) {
    m_peers.erase(std::remove_if(m_peers.begin(), m_peers.end(),
                                 [](std::weak_ptr<PeerPlugin> const& p) { return p.expired(); }), m_peers.end());
    m_peers.push_back(peer);
}

void StreamController::onPiecePassed(lt::torrent& torrent, int32_t piece) {
    if (!inFile(piece) || m_cancelled.load()) return;
    uint8_t expected = PieceMissing;
    if (!slot(piece).compare_exchange_strong(expected, PieceVerifying)) {
        if (debugTrace()) NSLog(@"PopcornTorrent bounded: piece %d passed in state %d", piece, int(expected));
        return;
    }
    m_everDownloaded.fetch_add(m_config.geometry.pieceBytes(piece));
    // A piece downloaded in this session into a file that already held data may land
    // over stale bytes, and a volume without holes (HFS+, exFAT) cannot tell written
    // blocks from unwritten ones: no hole check then, the content is verified instead.
    if (m_config.fileExisted || !m_holesSupported) m_suspect[size_t(piece - m_first)].store(true);
    // libtorrent already asked its cache to write the piece (torrent::piece_passed);
    // verify the file once that flush is done, and right away in case it already is.
    scheduleVerify(piece, 0, false);
    if (torrent.has_storage()) {
        std::weak_ptr<StreamController> weak = weak_from_this();
        torrent.session().disk_thread().async_flush_piece(torrent.storage(), lt::piece_index_t(piece), [weak, piece] {
            if (auto self = weak.lock()) self->scheduleVerify(piece, 0, true);
        });
    } else {
        scheduleVerify(piece, 0, true);
    }
    requestUpdate();
}

void StreamController::onPieceFailed(int32_t piece) {
    // The failed blocks may already be in the file: the next download of this piece
    // writes over them, so it is verified by content.
    if (inFile(piece)) m_suspect[size_t(piece - m_first)].store(true);
}

void StreamController::requestFlush(int32_t piece) {
    void *io = m_io.load(std::memory_order_acquire);
    if (io == nullptr || m_cancelled.load()) return;
    std::weak_ptr<lt::torrent> weakTorrent = m_torrent;
    boost::asio::post(*static_cast<lt::io_service *>(io), [weakTorrent, piece] {
        auto torrent = weakTorrent.lock();
        if (torrent && torrent->has_storage()) {
            torrent->session().disk_thread().async_flush_piece(torrent->storage(), lt::piece_index_t(piece));
        }
    });
}

void StreamController::onTick(lt::torrent& torrent) {
    if (!m_configured.load() || m_cancelled.load()) return;
    int64_t const position = m_readPosition.load();
    if (m_lastTickReadPosition >= 0) {
        // Once a second (torrent_plugin::tick). A seek over data that was never on disk
        // is not consumption: it would open the pace controller wide (see consumedBetween).
        double const rate = m_consumeRate.load();
        int64_t const cap = std::max<int64_t>({int64_t(2 * rate), int64_t(4 * m_config.budget.bytesPerSecond), 16 * kMiB});
        int64_t const sample = consumedBetween(m_config.geometry, snapshotStates(), m_lastTickReadPosition, position, cap);
        m_consumeRate.store(0.7 * rate + 0.3 * double(sample));
    }
    m_lastTickReadPosition = position;
    if (debugTrace()) {
        int missing = 0, verifying = 0, onDisk = 0, freed = 0;
        for (int32_t i = 0; i < m_count; ++i) {
            switch (m_states[size_t(i)].load()) {
            case PieceMissing: ++missing; break;
            case PieceVerifying: ++verifying; break;
            case PieceOnDisk: ++onDisk; break;
            case PieceFreed: ++freed; break;
            default: break;
            }
        }
        lt::torrent_status status;
        torrent.status(&status, {});
        size_t waiters;
        std::string waiting;
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            waiters = m_waiters.size();
            for (auto const& waiter : m_waiters) waiting += std::to_string(waiter.first) + "(" + std::to_string(int(stateOf(waiter.first))) + ") ";
        }
        if (!waiting.empty()) NSLog(@"PopcornTorrent bounded: waiting for pieces (state) %s", waiting.c_str());
        std::string deadlinePieces;
        for (auto const& entry : m_appliedDeadlines) {
            if (deadlinePieces.size() > 120) break;
            deadlinePieces += std::to_string(entry.first) + "(" + std::to_string(int(stateOf(entry.first))) + "/"
                + std::to_string(int(static_cast<std::uint8_t>(torrent.piece_priority(lt::piece_index_t(entry.first))))) + ") ";
        }
        if (!deadlinePieces.empty()) NSLog(@"PopcornTorrent bounded: deadline pieces (state/priority) %s", deadlinePieces.c_str());
        std::string missingRequired;
        for (int32_t piece : m_config.requiredPieces) {
            if (stateOf(piece) != PieceOnDisk) {
                missingRequired += std::to_string(piece) + "(" + std::to_string(int(stateOf(piece))) + "/"
                    + std::to_string(int(static_cast<std::uint8_t>(torrent.piece_priority(lt::piece_index_t(piece))))) + ") ";
            }
        }
        std::string firstMissing;
        int32_t firstMissingPiece = -1;
        for (int32_t piece = m_plannedReadPiece.load(); piece >= 0 && piece < m_first + m_count && firstMissing.size() < 80; ++piece) {
            if (stateOf(piece) == PieceMissing) {
                if (firstMissingPiece < 0) firstMissingPiece = piece;
                firstMissing += std::to_string(piece) + "/" + std::to_string(int(static_cast<std::uint8_t>(torrent.piece_priority(lt::piece_index_t(piece))))) + " ";
            }
        }
        if (firstMissingPiece >= 0 && torrent.has_picker()) {
            // libtorrent's view of the first missing piece: had, and its downloading entry.
            std::string picker = "have " + std::to_string(int(torrent.have_piece(lt::piece_index_t(firstMissingPiece))));
            for (auto const& d : torrent.picker().get_download_queue()) {
                if (int32_t(static_cast<int>(d.index)) != firstMissingPiece) continue;
                picker += " finished " + std::to_string(int(d.finished)) + " writing " + std::to_string(int(d.writing))
                    + " requested " + std::to_string(int(d.requested)) + " locked " + std::to_string(int(d.locked))
                    + " passed " + std::to_string(int(d.passed_hash_check));
            }
            NSLog(@"PopcornTorrent bounded: piece %d in libtorrent: %s", firstMissingPiece, picker.c_str());
        }
        NSLog(@"PopcornTorrent bounded: required missing %s | first missing from the reader %s", missingRequired.c_str(), firstMissing.c_str());
        std::string peers;
        for (lt::peer_connection* connection : torrent) {
            lt::peer_info info;
            connection->get_peer_info(info);
            peers += std::to_string(info.ip.port()) + (info.flags & lt::peer_info::choked ? " choked" : "")
                + (info.flags & lt::peer_info::interesting ? " interesting" : "") + (info.flags & lt::peer_info::snubbed ? " snubbed" : "")
                + (info.flags & lt::peer_info::seed ? " seed" : "") + (info.flags & lt::peer_info::on_parole ? " parole" : "")
                + " dlq " + std::to_string(info.download_queue_length) + " target " + std::to_string(info.target_dl_queue_length)
                + " down " + std::to_string(info.down_speed) + " read-state " + std::to_string(int(static_cast<std::uint8_t>(info.read_state)))
                + " disk " + std::to_string(info.pending_disk_read_bytes) + "/" + std::to_string(info.pending_disk_bytes)
                + " rq " + std::to_string(info.requests_in_buffer) + " busy " + std::to_string(info.busy_requests)
                + (info.flags & lt::peer_info::remote_interested ? " remote-interested" : "")
                + " up " + std::to_string(info.up_speed) + " upq " + std::to_string(connection->upload_queue().size())
                + " sendbuf " + std::to_string(info.used_send_buffer) + "; ";
        }
        NSLog(@"PopcornTorrent bounded: peers %s", peers.c_str());
        NSLog(@"PopcornTorrent bounded: read %lld (piece %d) consumed %lld | on disk %d verifying %d missing %d freed %d | "
              "ahead %lld/%lld alloc %lld punch-pending %lld limit %d pace %d | %s peers %d rate %d upload-mode %d | waiters %zu deadlines %zu",
              position, m_plannedReadPiece.load(), m_consumedBefore.load(), onDisk, verifying, missing, freed,
              m_aheadBytes.load() / kMiB, m_aheadBudget.load() / kMiB, m_allocatedBytes.load() / kMiB, m_pendingPunches.load(),
              m_downloadLimit.load(), m_paceState.load(),
              status.is_finished ? "finished" : "downloading", status.num_peers, status.download_rate,
              int(torrent.upload_mode()), waiters, m_appliedDeadlines.size());
    }
    m_peers.erase(std::remove_if(m_peers.begin(), m_peers.end(),
                                 [](std::weak_ptr<PeerPlugin> const& p) { return p.expired(); }), m_peers.end());
    if (m_bounded.load() && !m_suspended.load()) punchPartialPieces(torrent);
    apply(torrent, true);
}

std::vector<uint8_t> StreamController::snapshotStates() const {
    std::vector<uint8_t> states(static_cast<size_t>(m_count));
    for (int32_t i = 0; i < m_count; ++i) states[size_t(i)] = m_states[size_t(i)].load();
    return states;
}

#pragma mark Planning (network thread)

void StreamController::apply(lt::torrent& torrent, bool fromTick) {
    if (!m_configured.load() || m_cancelled.load()) return;
    if (torrent.is_aborted() || !torrent.valid_metadata()) return;

    auto const state = torrent.state();
    bool const checking = state == lt::torrent_status::checking_files
        || state == lt::torrent_status::checking_resume_data;
    if (!m_initialSynced && !checking && m_config.sharedTorrent && !m_cacheFlushed.load()) {
        // A torrent this stream joined: pieces it already has may still be in libtorrent's
        // write cache, over stale bytes of the file. Trust them once the cache is written out
        // (pieces passing from now on come through onPiecePassed).
        if (!m_cacheFlushRequested && torrent.has_storage()) {
            m_cacheFlushRequested = true;
            std::weak_ptr<StreamController> weak = weak_from_this();
            torrent.session().disk_thread().async_release_files(torrent.storage(), [weak] {
                if (auto self = weak.lock()) {
                    self->m_cacheFlushed.store(true);
                    self->requestUpdate();
                }
            });
        }
    } else if (!m_initialSynced && !checking) {
        // Pieces libtorrent already had (existing file, resume data) never pass again.
        m_initialSynced = true;
        for (int32_t piece = m_first; piece < m_first + m_count; ++piece) {
            if (!torrent.have_piece(lt::piece_index_t(piece))) continue;
            uint8_t expected = PieceMissing;
            if (slot(piece).compare_exchange_strong(expected, PieceVerifying)) {
                m_everDownloaded.fetch_add(m_config.geometry.pieceBytes(piece));
                scheduleVerify(piece, 0, true); // already in the file before the stream started
            }
        }
    }

    std::vector<uint8_t> states = snapshotStates();

    bool const bounded = m_bounded.load();
    PlanInput input;
    input.geometry = m_config.geometry;
    input.bounded = bounded;
    input.readPosition = m_readPosition.load();
    input.consumedBefore = m_consumedBefore.load();
    input.pins = pins();
    input.deadlinePieces = m_config.windowPieces;
    input.deadlineFirstMs = m_config.deadlineFirstMs;
    input.deadlineStepMs = m_config.deadlineStepMs;
    input.states = &states;
    input.capSentinel = m_capSentinel;
    if (!bounded && m_config.urgentTailPieces > 0 && m_config.urgentTailPieces < m_config.tailPieces) {
        FileGeometry const& geo = m_config.geometry;
        input.urgentTailStart = geo.pieceBegin(std::max(geo.firstPiece(), geo.lastPiece() - m_config.urgentTailPieces + 1));
    }
    {
        // Data freed but not punched yet still takes its space (right after a seek, the
        // whole old window): a late window may only fill what is left.
        int64_t const pieceLength = m_config.geometry.pieceLength;
        int64_t ahead = m_aheadBudget.load();
        if (ahead <= 0) ahead = m_config.budget.minAhead;
        ahead -= m_pendingPunchBytes.load();
        input.aheadLimitPieces = int(std::max<int64_t>(pieceLength, ahead) / pieceLength);
    }
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        for (auto const& waiter : m_waiters) {
            if (input.urgentPieces.empty() || input.urgentPieces.back() != waiter.first) input.urgentPieces.push_back(waiter.first);
        }
    }
    PlanOutput const plan = planWindow(input);
    m_capSentinel = plan.capSentinel;

    m_plannedReadPiece.store(plan.readPiece);
    m_plannedConsumedPiece.store(m_config.geometry.pieceAt(input.consumedBefore));

    // Shared torrent driven by another controller: keep the state, plan nothing.
    bool const suspended = m_suspended.load();
    if (!checking && !suspended) {
        applyPriorities(torrent, plan.priorities);
        applyDeadlines(torrent, m_config.useDeadlines ? plan.deadlines : std::vector<std::pair<int32_t, int>>());
    }

    if (bounded && !suspended && !plan.toFree.empty()) {
        int64_t bytes = 0;
        for (int32_t piece : plan.toFree) bytes += m_config.geometry.pieceBytes(piece);
        if (fromTick || bytes >= kFreeBatchBytes || m_lastFreeBytes.load() < m_config.reserveBytes) {
            releasePieces(torrent, plan.toFree, PieceFreed);
            m_freedPieces.fetch_add(int64_t(plan.toFree.size()));
        }
    }
    if (bounded) {
        int64_t lowest = m_lowestAvailable.load();
        while (plan.lowestAvailableOffset > lowest
               && !m_lowestAvailable.compare_exchange_weak(lowest, plan.lowestAvailableOffset)) {}
    }

    int windowTotal = 0, windowOnDisk = 0;
    for (int32_t piece = plan.readPiece; piece < plan.windowEndPiece; ++piece) {
        ++windowTotal;
        if (states[size_t(piece - m_first)] == PieceOnDisk) ++windowOnDisk;
    }
    m_windowTotal.store(windowTotal);
    m_windowOnDisk.store(windowOnDisk);
    m_aheadBytes.store(plan.aheadBytes);
    m_allocatedBytes.store(bytesOnDisk());
    m_behindBytes.store(plan.behindBytes);
    m_pinnedBytes.store(plan.pinnedBytes);
    m_dataBytes.store(plan.dataBytes);
    m_lastPlanPriorities = plan.priorities;

    if (!bounded || suspended) {
        if (fromTick) sweepWaiters(plan);
        return;
    }

    // Pace the download so the window ahead of the reader stays within its budget.
    int64_t const free = freeBytes();
    m_lastFreeBytes.store(free);
    BudgetPlan budget = m_config.budget;
    int64_t const requested = m_requestedBudget.load();
    if (requested > 0) budget.torrentBudget = std::max(requested, budget.pinBudget + budget.minAhead + budget.inflightAllowance);
    int64_t allowedAhead = aheadBudget(budget, m_config.geometry.pieceLength, plan.pinnedBytes,
                                       plan.behindBytes, m_shrinkPercent.load() / 100.0);

    // The real allocation also counts partially downloaded pieces and freed pieces
    // whose holes are not punched yet.
    int64_t const allocated = bytesOnDisk();
    int64_t const aheadOnDisk = std::max(plan.aheadBytes, allocated - plan.pinnedBytes - plan.behindBytes);
    // Never plan to hold more than the free space above the reserve allows (the app's own
    // copy, or anything else, may be using the volume too).
    if (free != INT64_MAX) {
        int64_t const room = aheadOnDisk + (free - m_config.reserveBytes);
        allowedAhead = std::max(2 * m_config.geometry.pieceLength, std::min(allowedAhead, room));
    }
    m_aheadBudget.store(allowedAhead);
    PaceInput paceInput;
    paceInput.aheadBytes = aheadOnDisk;
    paceInput.aheadBudget = allowedAhead;
    paceInput.consumeRate = m_consumeRate.load();
    paceInput.freeBytes = free;
    paceInput.reserveBytes = m_config.reserveBytes;
    paceInput.urgent = plan.urgent;
    PaceOutput const paced = pace(paceInput);
    if (paced.downloadLimit != m_appliedLimit) {
        torrent.set_download_limit(paced.downloadLimit);
        m_appliedLimit = paced.downloadLimit;
    }
    m_downloadLimit.store(paced.downloadLimit);
    m_paceState.store(int(paced.state));

    // Disk full (ENOSPC) or below half the reserve: drop data far ahead of the reader.
    // It is downloaded again later; the stream itself never stops.
    // Otherwise, while the reader does not wait, the floor and trickle rates must not
    // make disk use grow over a long pause: data beyond the ahead budget (past the
    // floor band) or eating into the reserve is dropped the same way.
    // Holes already queued give space back first: never drop again before they land.
    bool const diskFull = m_diskFullPending.load();
    int64_t need = 0;
    if (diskFull || free < m_config.reserveBytes / 2) {
        need = std::max<int64_t>(m_config.reserveBytes - free, 0) + m_config.geometry.pieceLength;
    } else {
        need = excessAheadBytes(paceInput, m_config.geometry.pieceLength);
    }
    if (need > 0 && m_pendingPunches.load() == 0) {
        std::vector<int32_t> const drop = piecesToDrop(input, plan, need);
        if (debugTrace() && !drop.empty()) {
            NSLog(@"PopcornTorrent bounded: dropping %zu pieces (%d..%d) for %lld bytes, disk full %d, free %lld",
                  drop.size(), drop.back(), drop.front(), need, int(diskFull), free);
        }
        releasePieces(torrent, drop, PieceDropping);
        if (!drop.empty()) m_droppedPieces.fetch_add(int64_t(drop.size()));
    }
    if (torrent.upload_mode() && free >= m_config.reserveBytes / 2) {
        torrent.set_upload_mode(false); // libtorrent's own reaction to ENOSPC
        m_diskFullPending.store(false);
    } else if (diskFull && !torrent.upload_mode()) {
        m_diskFullPending.store(false);
    }

    if (fromTick) sweepWaiters(plan);
}

void StreamController::applyPriorities(lt::torrent& torrent, std::vector<uint8_t> const& priorities) {
    // Compared with libtorrent's own priorities every time, not with what was applied
    // last: prioritize_files() takes a disk-thread round trip and then rewrites every
    // piece of the file (to 7 for the selected file) after our first plan.
    std::vector<int32_t> changed;
    for (int32_t i = 0; i < m_count; ++i) {
        auto const actual = static_cast<std::uint8_t>(torrent.piece_priority(lt::piece_index_t(m_first + i)));
        if (actual != priorities[size_t(i)]) changed.push_back(i);
    }
    if (changed.empty()) return;
    if (changed.size() > 64) {
        int const pieceCount = torrent.torrent_file().num_pieces();
        lt::aux::vector<lt::download_priority_t, lt::piece_index_t> all(size_t(pieceCount), lt::dont_download);
        for (int32_t i = 0; i < m_count; ++i) {
            all[lt::piece_index_t(m_first + i)] = lt::download_priority_t(priorities[size_t(i)]);
        }
        torrent.prioritize_pieces(all);
    } else {
        for (int32_t i : changed) {
            torrent.set_piece_priority(lt::piece_index_t(m_first + i), lt::download_priority_t(priorities[size_t(i)]));
        }
    }
    m_appliedPriorities = priorities;
}

void StreamController::applyDeadlines(lt::torrent& torrent, std::vector<std::pair<int32_t, int>> const& deadlines) {
    std::map<int32_t, int> wanted(deadlines.begin(), deadlines.end());
    for (auto it = m_appliedDeadlines.begin(); it != m_appliedDeadlines.end();) {
        if (wanted.count(it->first) == 0) {
            torrent.reset_piece_deadline(lt::piece_index_t(it->first));
            it = m_appliedDeadlines.erase(it);
        } else {
            ++it;
        }
    }
    for (auto const& entry : wanted) {
        if (m_appliedDeadlines.count(entry.first)) continue;
        // No alert_when_available: libtorrent would read every piece back into RAM.
        torrent.set_piece_deadline(lt::piece_index_t(entry.first), entry.second, {});
        m_appliedDeadlines[entry.first] = entry.second;
    }
}

void StreamController::releasePieces(lt::torrent& torrent, std::vector<int32_t> const& pieces, uint8_t newState) {
    std::vector<int32_t> released;
    for (int32_t piece : pieces) {
        std::atomic<uint8_t>& state = slot(piece);
        uint8_t previous = state.load();
        // Freed: only pieces confirmed on disk (nothing of theirs left in the cache to write).
        bool const releasable = newState == PieceFreed ? previous == PieceOnDisk : pieceHasData(previous);
        if (!releasable || !state.compare_exchange_strong(previous, newState)) continue;
        released.push_back(piece);

        lt::piece_index_t const index(piece);
        // 1. never pick it again (Dropping: until the hole is punched).
        torrent.set_piece_priority(index, lt::dont_download);
        if (m_appliedPriorities.size() == size_t(m_count)) m_appliedPriorities[size_t(piece - m_first)] = 0;
        // 2. un-have it, the way libtorrent does itself (torrent.cpp, unfinished resume pieces).
        //    From now on has_piece_passed() is false: peers' requests are rejected
        //    (peer_connection::fill_send_buffer) and it is left out of new bitfields.
        if (!torrent.has_picker()) torrent.need_picker();
        lt::piece_picker& picker = torrent.picker();
        if (picker.have_piece(index) || picker.has_piece_passed(index)) {
            picker.we_dont_have(index);
            torrent.update_gauge();
        }
        // 3. withdraw it from the peers that understand lt_donthave.
        for (auto const& weak : m_peers) {
            if (auto peer = weak.lock()) {
                if (peer->sendDontHave(piece)) m_dontHaveSent.fetch_add(1);
            }
        }
    }
    if (released.empty()) return;
    torrent.state_updated();
    m_pendingPunches.fetch_add(int64_t(released.size()));
    for (int32_t piece : released) m_pendingPunchBytes.fetch_add(m_config.geometry.pieceBytes(piece));

    // 4. one fence for the batch: every read or write already queued on this storage
    //    completes, and the cache forgets the last piece, before the holes are punched.
    //    No new job can touch these pieces: they are neither wanted nor had.
    std::weak_ptr<StreamController> weak = weak_from_this();
    auto punchAll = [weak, released, newState] {
        if (auto self = weak.lock()) {
            dispatch_async(self->m_ioQueue, ^{
                for (int32_t piece : released) self->punch(piece, newState);
            });
        }
    };
    if (torrent.has_storage()) {
        auto& disk = torrent.session().disk_thread();
        // Dropped pieces are downloaded again later: none of their blocks may stay in
        // the cache. Freed pieces are never read by libtorrent again (not had): their
        // stale cache entries only age out.
        for (size_t i = 0; newState == PieceDropping && i + 1 < released.size(); ++i) {
            disk.async_clear_piece(torrent.storage(), lt::piece_index_t(released[i]), [](lt::piece_index_t) {});
        }
        disk.async_clear_piece(torrent.storage(), lt::piece_index_t(released.back()), [punchAll](lt::piece_index_t) { punchAll(); });
    } else {
        punchAll();
    }
}

void StreamController::punchPartialPieces(lt::torrent& torrent) {
    // A forward seek leaves partially downloaded pieces behind: their priority drops to 0,
    // but blocks already requested still arrive and are written. Once consumed, nothing
    // reads them again: punch them when no block of theirs is on its way any more.
    int64_t const consumed = m_consumedBefore.load();
    if (consumed <= 0 || !torrent.has_picker() || !torrent.has_storage()) return;
    PinSet const pinSet = pins();
    std::vector<int32_t> pieces;
    for (auto const& downloading : torrent.picker().get_download_queue()) {
        int32_t const piece = int32_t(static_cast<int>(downloading.index));
        if (!inFile(piece) || stateOf(piece) != PieceMissing) continue;
        if (!isGone(m_config.geometry, pinSet, PieceMissing, piece, consumed)) continue;
        // Nothing requested any more, nothing still in libtorrent's write cache (it would be
        // written after the punch): only finished blocks, already in the file.
        if (downloading.requested > 0 || downloading.writing > 0 || downloading.finished == 0) continue;
        if (!m_partialPunchedPieces.insert(piece).second) continue;
        pieces.push_back(piece);
    }
    if (pieces.empty()) return;
    m_pendingPunches.fetch_add(int64_t(pieces.size()));
    for (int32_t piece : pieces) m_pendingPunchBytes.fetch_add(m_config.geometry.pieceBytes(piece));
    m_partialPunched.fetch_add(int64_t(pieces.size()));
    std::weak_ptr<StreamController> weak = weak_from_this();
    auto& disk = torrent.session().disk_thread();
    for (int32_t piece : pieces) {
        // A fence (writes already queued complete) that also evicts its cached blocks.
        disk.async_clear_piece(torrent.storage(), lt::piece_index_t(piece), [weak, piece](lt::piece_index_t) {
            if (auto self = weak.lock()) {
                dispatch_async(self->m_ioQueue, ^{ self->punch(piece, PieceMissing); });
            }
        });
    }
}

void StreamController::sweepWaiters(PlanOutput const& plan) {
    auto const now = std::chrono::steady_clock::now();
    bool const bounded = m_bounded.load();
    PinSet const pinSet = pins();
    int64_t const consumed = m_consumedBefore.load();
    std::vector<std::pair<std::function<void(int)>, int>> failed;
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        for (auto it = m_waiters.begin(); it != m_waiters.end();) {
            int32_t const piece = it->first;
            int result = ReadOK;
            if (!bounded || !inFile(piece)) {
                // Full mode: every piece of the file comes eventually, reads wait for it.
            } else if (isGone(m_config.geometry, pinSet, stateOf(piece), piece, consumed)) {
                result = ReadFreed; // consumed while not on disk: it never comes
            } else if (it->second.reader != m_primaryReader && now - it->second.since > kWaiterTimeout) {
                result = ReadTimedOut;
            } else if (stateOf(piece) == PieceMissing && plan.priorities.size() == size_t(m_count)
                       && plan.priorities[size_t(piece - m_first)] == 0) {
                result = ReadUnwanted; // superseded reader behind the read position
            }
            if (result != ReadOK) {
                failed.emplace_back(std::move(it->second.resume), result);
                it = m_waiters.erase(it);
            } else {
                ++it;
            }
        }
    }
    for (auto& entry : failed) entry.first(entry.second);
}

#pragma mark File work (I/O queue)

void StreamController::scheduleVerify(int32_t piece, int attempt, bool flushed) {
    if (m_cancelled.load()) return;
    std::weak_ptr<StreamController> weak = weak_from_this();
    if (attempt == 0) {
        dispatch_async(m_ioQueue, ^{ if (auto self = weak.lock()) self->verify(piece, attempt, flushed); });
        return;
    }
    int64_t const delay = isSuspect(piece) ? kContentRetryNanos : attempt < 20 ? 10 * NSEC_PER_MSEC : 200 * NSEC_PER_MSEC;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay), m_ioQueue, ^{
        if (auto self = weak.lock()) self->verify(piece, attempt, flushed);
    });
}

bool StreamController::isSuspect(int32_t piece) const {
    return inFile(piece) && m_suspect[size_t(piece - m_first)].load();
}

bool StreamController::hasPieceHash(int32_t piece) const {
    size_t const at = size_t(piece - m_first) * 20;
    if (!inFile(piece) || m_config.pieceHashes.size() < at + 20) return false;
    char const* hash = m_config.pieceHashes.data() + at;
    return std::any_of(hash, hash + 20, [](char c) { return c != 0; });
}

bool StreamController::contentMatches(int32_t piece) {
    FileGeometry const& geo = m_config.geometry;
    int64_t const begin = geo.pieceBegin(piece);
    int64_t const end = geo.pieceEnd(piece);
    std::vector<char> buffer(size_t(std::min<int64_t>(kMaxReadChunk, end - begin)));
    lt::hasher hasher;
    int const fd = fileDescriptor();
    std::shared_lock<std::shared_mutex> lock(m_fdLock);
    if (fd < 0 || fd != m_fd) return false;
    for (int64_t offset = begin; offset < end;) {
        size_t const length = size_t(std::min<int64_t>(int64_t(buffer.size()), end - offset));
        ssize_t const count = pread(fd, buffer.data(), length, off_t(offset));
        if (count != ssize_t(length)) return false;
        hasher.update(buffer.data(), int(count));
        offset += count;
    }
    lt::sha1_hash const digest = hasher.final();
    return std::memcmp(digest.data(), m_config.pieceHashes.data() + size_t(piece - m_first) * 20, 20) == 0;
}

void StreamController::verify(int32_t piece, int attempt, bool flushed) {
    if (m_cancelled.load() || stateOf(piece) != PieceVerifying) return;
    FileGeometry const& geo = m_config.geometry;

    bool written = false;
    if (isSuspect(piece)) {
        // Stale bytes, or no holes on this volume: a piece is written once its content
        // in the file matches its hash. Checked after libtorrent's flush only (it reads the
        // whole piece back). A piece that is not wholly inside the file (multi-file
        // torrents) cannot be hashed from it: libtorrent's flush is trusted then.
        if (!flushed) return; // the flush callback starts its own verification
        written = hasPieceHash(piece) ? contentMatches(piece) : true;
    } else {
        int64_t const begin = geo.pieceBegin(piece);
        int64_t const end = geo.pieceEnd(piece);
        int64_t const alignedBegin = alignUp(begin);
        int64_t const alignedEnd = end == geo.fileSize ? end : alignDown(end);
        int const fd = fileDescriptor();
        std::shared_lock<std::shared_mutex> lock(m_fdLock);
        if (fd >= 0 && fd == m_fd) {
            if (alignedEnd <= alignedBegin) {
                written = true; // too small to hold a whole block: trust the flush
            } else {
                // The region was a hole: a hole left inside the piece means libtorrent's
                // cache has not written it yet. (Without hole support, only pieces already
                // in the file when the stream started come here: SEEK_HOLE finds the end
                // of the file, or fails.)
                off_t const hole = lseek(fd, off_t(alignedBegin), SEEK_HOLE);
                if (hole >= 0) written = int64_t(hole) >= alignedEnd;
                else written = errno != ENXIO; // no hole support: trust libtorrent
            }
        }
    }
    if (written) {
        uint8_t expected = PieceVerifying;
        if (slot(piece).compare_exchange_strong(expected, PieceOnDisk)) markOnDisk(piece);
        return;
    }
    if (attempt % 10 == 9) requestFlush(piece);
    scheduleVerify(piece, attempt + 1, flushed);
}

void StreamController::markOnDisk(int32_t piece) {
    std::vector<std::function<void(int)>> resumed;
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        auto const range = m_waiters.equal_range(piece);
        for (auto it = range.first; it != range.second; ++it) resumed.push_back(std::move(it->second.resume));
        m_waiters.erase(range.first, range.second);
    }
    for (auto& resume : resumed) {
        auto block = std::move(resume);
        dispatch_async(m_readQueue, ^{ block(ReadOK); });
    }
    if (m_bounded.load() && !m_headParsed.load()) {
        int32_t const need = m_parserNeedPiece.load();
        if (need < 0 || need == piece) scheduleHeadParse();
    }
    notifyAvailability();
}

void StreamController::failWaiters(int32_t piece, int result) {
    std::vector<std::function<void(int)>> failed;
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        auto const range = m_waiters.equal_range(piece);
        for (auto it = range.first; it != range.second; ++it) failed.push_back(std::move(it->second.resume));
        m_waiters.erase(range.first, range.second);
    }
    for (auto& resume : failed) resume(result);
}

void StreamController::punch(int32_t piece, uint8_t newState) {
    FileGeometry const& geo = m_config.geometry;
    int64_t const pieceBegin = geo.pieceBegin(piece);
    int64_t const pieceEnd = geo.pieceEnd(piece);
    // Rounded inward to whole 4 KiB blocks, but a block shared with a neighbour piece
    // that is freed too is punched as well (pieces that do not start on a block
    // boundary: a file inside a multi-file torrent).
    auto freedNeighbour = [&](int32_t neighbour) {
        return newState == PieceFreed && inFile(neighbour) && stateOf(neighbour) == PieceFreed;
    };
    int64_t begin = alignUp(pieceBegin);
    if (begin != pieceBegin && freedNeighbour(piece - 1)) begin = alignDown(pieceBegin);
    int64_t end = pieceEnd == geo.fileSize ? pieceEnd : alignDown(pieceEnd);
    if (end != pieceEnd && freedNeighbour(piece + 1)) end = std::min(alignUp(pieceEnd), geo.fileSize);
    if (end > begin && !m_cancelled.load()) {
        int const fd = fileDescriptor();
        std::shared_lock<std::shared_mutex> lock(m_fdLock);
        if (fd >= 0 && fd == m_fd) {
            fpunchhole_t hole = {0, 0, off_t(begin), off_t(end - begin)};
            if (fcntl(fd, F_PUNCHHOLE, &hole) == 0) {
                m_punchedBytes.fetch_add(end - begin);
            } else {
                m_punchErrors.fetch_add(1);
                NSLog(@"PopcornTorrent: F_PUNCHHOLE failed for piece %d (errno %d)", piece, errno);
            }
        }
    }
    m_pendingPunches.fetch_sub(1);
    m_pendingPunchBytes.fetch_sub(geo.pieceBytes(piece));
    if (newState == PieceDropping) {
        uint8_t expected = PieceDropping;
        slot(piece).compare_exchange_strong(expected, PieceMissing); // downloadable again
        requestUpdate();
    } else if (newState == PieceFreed) {
        failWaiters(piece, ReadFreed);
    } else {
        return; // a consumed partial piece (punchPartialPieces): its state does not change
    }
    notifyAvailability();
}

void StreamController::scheduleHeadParse() {
    if (m_headParseScheduled.exchange(true)) return;
    std::weak_ptr<StreamController> weak = weak_from_this();
    dispatch_async(m_ioQueue, ^{
        if (auto self = weak.lock()) {
            self->m_headParseScheduled.store(false);
            self->parseHead();
        }
    });
}

void StreamController::parseHead() {
    if (m_headParsed.load() || m_cancelled.load()) return;
    int const fd = fileDescriptor();
    if (fd < 0) return;
    ReadAt const read = [this, fd](int64_t offset, uint8_t *buffer, size_t length) -> bool {
        if (!isRangeOnDisk(offset, int64_t(length))) return false;
        std::shared_lock<std::shared_mutex> lock(m_fdLock);
        if (fd != m_fd) return false;
        return pread(fd, buffer, length, off_t(offset)) == ssize_t(length);
    };
    FileGeometry const& geo = m_config.geometry;
    HeadPins const result = parseHeadPins(read, geo.fileSize);
    if (result.status == HeadPins::NeedMore) {
        // The bytes it needs may straddle two pieces: wait for the first of them not on
        // disk yet (markOnDisk parses again when it arrives). All on disk (a read error):
        // parse again on the next piece.
        int64_t const missing = firstMissingOffset(result.needOffset);
        int32_t const need = missing < std::min(result.needOffset + kHeadParserLookahead, geo.fileSize) ? geo.pieceAt(missing) : -1;
        if (m_parserNeedPiece.exchange(need) != need) requestUpdate();
        return;
    }
    m_headPinEnd.store(result.headPinEnd);
    m_parsedTailStart.store(result.tailPinStart);
    m_parserNeedPiece.store(-1);
    m_headParsed.store(true);
    NSLog(@"PopcornTorrent: bounded storage head pin %lld bytes (%s), tail pin from %lld",
          result.headPinEnd, result.format, result.tailPinStart);
    requestUpdate();
}

#pragma mark HTTP reads

bool StreamController::isPinnedOffset(int64_t offset) const {
    if (!m_configured.load()) return false;
    return isPinned(m_config.geometry, pins(), m_config.geometry.pieceAt(offset));
}

int64_t StreamController::openReader(int64_t start) {
    bool takeOver = false;
    int64_t id;
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        id = ++m_nextReader;
        auto const now = std::chrono::steady_clock::now();
        Reader reader;
        reader.end = start;
        reader.lastServed = now;
        m_readers[id] = reader;
        // A new request while the streaming one is silent is a seek: it becomes
        // the read position. Requests next to an active stream (an index, the
        // head, a prefetch) only get their pieces fetched first.
        auto const primary = m_readers.find(m_primaryReader);
        bool const eligible = !isPinnedOffset(start);
        if (eligible && (primary == m_readers.end() || now - primary->second.lastServed > kPrimaryReaderSilence)) {
            m_primaryReader = id;
            takeOver = true;
        }
    }
    if (takeOver && m_configured.load()) moveReadPosition(start);
    return id;
}

void StreamController::closeReader(int64_t reader) {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_readers.erase(reader);
    if (m_primaryReader == reader) m_primaryReader = -1;
}

void StreamController::readAsync(int64_t reader, int64_t offset, int64_t maxLength, ReadCallback callback) {
    if (m_cancelled.load()) { callback(nil, ReadCancelled); return; }
    if (!m_configured.load()) { callback(nil, ReadIOError); return; }
    FileGeometry const& geo = m_config.geometry;
    if (offset >= geo.fileSize || maxLength <= 0) { callback([NSData data], ReadOK); return; }

    int32_t const piece = geo.pieceAt(offset);
    uint8_t state = stateOf(piece);
    if (isOffsetGone(offset)) { callback(nil, ReadFreed); return; }

    auto self = shared_from_this();
    if (state == PieceOnDisk) {
        dispatch_async(m_readQueue, ^{ self->performRead(reader, offset, maxLength, callback); });
        return;
    }

    // Not on disk yet: the piece becomes urgent (see apply), and if this is the
    // streaming reader the window moves to it.
    bool primary;
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        primary = m_primaryReader == reader;
    }
    if (primary && !isPinned(geo, pins(), piece)) moveReadPosition(offset);
    {
        std::unique_lock<std::mutex> lock(m_mutex);
        state = stateOf(piece);
        if (state != PieceOnDisk && !isOffsetGone(offset)) {
            m_waiters.emplace(piece, Waiter{std::chrono::steady_clock::now(), reader, [self, reader, offset, maxLength, callback](int result) {
                if (result != ReadOK) callback(nil, result);
                else self->readAsync(reader, offset, maxLength, callback);
            }});
            lock.unlock();
            requestUpdate();
            return;
        }
    }
    readAsync(reader, offset, maxLength, callback); // became available meanwhile
}

void StreamController::performRead(int64_t reader, int64_t offset, int64_t maxLength, ReadCallback callback) {
    if (m_cancelled.load()) { callback(nil, ReadCancelled); return; }
    FileGeometry const& geo = m_config.geometry;
    int64_t const limit = std::min({offset + maxLength, offset + kMaxReadChunk, geo.fileSize});
    int64_t end = offset;
    for (int32_t piece = geo.pieceAt(offset); end < limit && piece <= geo.lastPiece(); ++piece) {
        if (stateOf(piece) != PieceOnDisk) break;
        end = std::min(limit, geo.pieceEnd(piece));
    }
    if (end <= offset) { readAsync(reader, offset, maxLength, callback); return; }

    NSMutableData *data = [NSMutableData dataWithLength:NSUInteger(end - offset)];
    ssize_t count = -1;
    {
        int const fd = fileDescriptor();
        std::shared_lock<std::shared_mutex> lock(m_fdLock);
        if (fd >= 0 && fd == m_fd) count = pread(fd, data.mutableBytes, size_t(end - offset), off_t(offset));
    }
    if (count != ssize_t(end - offset)) {
        callback(nil, m_cancelled.load() ? ReadCancelled : ReadIOError);
        return;
    }
    // A piece freed (or dropped) while it was read may have been punched under us.
    for (int32_t piece = geo.pieceAt(offset); piece <= geo.pieceAt(end - 1); ++piece) {
        uint8_t const state = stateOf(piece);
        if (state == PieceFreed) { callback(nil, ReadFreed); return; }
        if (state != PieceOnDisk) { readAsync(reader, offset, maxLength, callback); return; }
    }
    noteServed(reader, offset, end);
    callback(data, ReadOK);
}

void StreamController::noteServed(int64_t reader, int64_t offset, int64_t end) {
    bool primary = false;
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        auto const now = std::chrono::steady_clock::now();
        auto const it = m_readers.find(reader);
        if (it != m_readers.end()) {
            it->second.end = end;
            it->second.served += end - offset;
            it->second.lastServed = now;
        }
        // Reads in the pinned head and tail (headers, indexes) never drive the window.
        auto const current = m_readers.find(m_primaryReader);
        if (!isPinnedOffset(offset) && (current == m_readers.end() || now - current->second.lastServed > kPrimaryReaderSilence)) {
            m_primaryReader = reader;
        }
        primary = m_primaryReader == reader;
    }
    if (!primary) return;
    // The streaming reader is the read position, and its offset is the server's.
    m_servedOffset.store(end);
    moveReadPosition(end);
}

} // namespace ptbounded
