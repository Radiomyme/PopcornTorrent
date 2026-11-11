//
//  PTBoundedLogic.hpp
//  PopcornTorrent
//
//  Pure logic of the bounded-storage mode: budget split, download window
//  planner, pace controller and container head parser. No libtorrent, no
//  Foundation: everything here is deterministic and unit-tested
//  (PopcornTorrentLogicTests).
//

#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <utility>
#include <vector>

namespace ptbounded {

constexpr int64_t kKiB = 1024;
constexpr int64_t kMiB = 1024 * kKiB;
constexpr int64_t kGiB = 1024 * kMiB;

/// Free space bounded mode never uses (tvOS + libtorrent headroom).
constexpr int64_t kDefaultReserveBytes = 512 * kMiB;
/// Largest head pin (start of the file up to the first MKV Cluster / end of an MP4 moov).
constexpr int64_t kHeadPinLimit = 64 * kMiB;
/// Head pin used when the container cannot be parsed (AVI, unknown, damaged).
constexpr int64_t kHeadPinFallback = 32 * kMiB;
/// Number of pieces pinned at the end of the file (MKV Cues, MP4 moov at the end).
constexpr int kTailPinPieces = 2;
/// Runtime assumed when the app gives no duration (to estimate the bitrate from the size).
constexpr double kAssumedDurationSeconds = 2 * 3600;
/// Most bytes the head parser reads at one offset (an EBML element header, an MP4 box header).
constexpr int64_t kHeadParserLookahead = 16;

/// Piece states as seen by the streamer. This is not libtorrent's view: a piece
/// is only `OnDisk` once its bytes are verified as written to the file.
enum PieceState : uint8_t {
    PieceMissing = 0,   // not on disk (never downloaded, or dropped to be fetched again)
    PieceOnDisk = 1,    // passed the hash check and is readable from the file
    PieceFreed = 2,     // consumed and deleted from disk; never downloaded again in this session
    PieceVerifying = 3, // passed the hash check, write to the file not confirmed yet
    PieceDropping = 4,  // deleted ahead of the reader (disk full); downloadable again once punched
};

inline bool pieceHasData(uint8_t state) { return state == PieceOnDisk || state == PieceVerifying; }

/// Where the selected file sits in the torrent's piece space.
struct FileGeometry {
    int64_t fileOffset = 0;   // offset of the selected file in the torrent's byte space
    int64_t fileSize = 0;
    int64_t pieceLength = 0;

    bool valid() const { return fileSize > 0 && pieceLength > 0 && fileOffset >= 0; }
    int32_t firstPiece() const { return int32_t(fileOffset / pieceLength); }
    int32_t lastPiece() const { return int32_t((fileOffset + fileSize - 1) / pieceLength); }
    int32_t pieceCount() const { return valid() ? lastPiece() - firstPiece() + 1 : 0; }
    /// Piece holding the byte at `offset` (file coordinates), clamped to the file.
    int32_t pieceAt(int64_t offset) const;
    /// Part of piece `piece` that belongs to the file, in file coordinates [begin, end).
    int64_t pieceBegin(int32_t piece) const;
    int64_t pieceEnd(int32_t piece) const;
    int64_t pieceBytes(int32_t piece) const { return pieceEnd(piece) - pieceBegin(piece); }
};

#pragma mark - Budget split

enum class StorageDecision { Full, Bounded, Refuse };

struct BudgetInput {
    int64_t freeBytes = 0;          // free space on the volume, read fresh
    int64_t heldBytes = 0;          // bytes of the selected file already allocated on disk
    int64_t existingLogicalBytes = 0; // logical size of an existing file (legacy check only)
    int64_t fileSize = 0;
    int64_t pieceLength = 0;
    int64_t reserveBytes = kDefaultReserveBytes;
    int64_t requestedBudget = 0;    // the app's share for the torrent, 0 = automatic
    double durationSeconds = 0;     // media duration, 0 = unknown
    bool allowBounded = true;
};

struct BudgetPlan {
    StorageDecision decision = StorageDecision::Full;
    double bytesPerSecond = 0;      // known or estimated bitrate
    int64_t minimumFreeBytes = 0;   // free space bounded mode needs to start (refusal threshold)
    int64_t torrentBudget = 0;      // bounded: bytes the torrent may keep on disk
    int64_t pinBudget = 0;          // upper bound of the head + tail pins
    int64_t minAhead = 0;           // the window ahead of the reader never shrinks below this
    int64_t inflightAllowance = 0;  // partially downloaded pieces
};

/// Decides between the legacy full download, bounded mode and a refusal, and
/// splits the space. Full mode is chosen exactly when the file (minus what is
/// already on disk) plus the reserve fits in the free space.
BudgetPlan planBudget(BudgetInput const& input);

/// Bytes the window ahead of the reader may hold right now.
int64_t aheadBudget(BudgetPlan const& plan, int64_t pieceLength, int64_t pinnedBytes,
                    int64_t behindBytes, double shrink);

#pragma mark - Window planner

struct PinSet {
    int64_t headEnd = 0;     // pieces overlapping [0, headEnd) are pinned
    int64_t tailStart = -1;  // pieces overlapping [tailStart, fileSize) are pinned, -1 = none
    int32_t extraPiece = -1; // a piece the head parser waits for (pinned too), -1 = none
};

struct PlanInput {
    FileGeometry geometry;
    bool bounded = false;
    int64_t readPosition = 0;       // next byte the consumer needs (file offset)
    int64_t consumedBefore = 0;     // bytes below are never read again (bounded only)
    PinSet pins;
    int deadlinePieces = 1;         // size of the deadline window
    int deadlineFirstMs = 0;        // deadline of the first window piece
    int deadlineStepMs = 0;         // added for each further piece (0 = flat)
    std::vector<uint8_t> const* states = nullptr; // pieceCount() entries, index = piece - firstPiece
    std::vector<int32_t> urgentPieces; // pieces a reader waits for: fetched first wherever they are,
                                       // unless freed or already consumed
    int aheadLimitPieces = 0;       // bounded: while pieces the reader needs are missing, pieces
                                    // further than this from the read piece are not wanted, so a
                                    // late piece does not let the rest of the file fill the disk
                                    // (0 = no cap)
    int32_t capSentinel = -1;       // `capSentinel` of the previous plan (-1 = none)
};

struct PlanOutput {
    std::vector<uint8_t> priorities;                // pieceCount() entries, libtorrent priorities 0-7
    std::vector<std::pair<int32_t, int>> deadlines; // (piece, milliseconds)
    std::vector<int32_t> toFree;                    // pieces with data that are now consumed
    int32_t readPiece = 0;
    int32_t windowEndPiece = 0;     // first piece after the deadline window
    bool urgent = false;            // pieces the reader needs now are missing (window, pins, waits)
    int64_t aheadBytes = 0;         // data at or after the read piece (pins excluded)
    int64_t behindBytes = 0;        // data before the read piece still kept (pins excluded)
    int64_t pinnedBytes = 0;        // data in pinned pieces
    int64_t dataBytes = 0;          // all data of the file on disk (or being verified)
    int64_t lowestAvailableOffset = 0; // bounded: below this (apart from the head pin) data is gone
    int32_t capSentinel = -1;       // bounded, late window: the one missing piece beyond the cap
                                    // that stays wanted (see planWindow), -1 = cap not applied
};

bool isPinned(FileGeometry const& geometry, PinSet const& pins, int32_t piece);

/// Bounded: the piece lies entirely below `consumedBefore` minus one guard piece.
bool isConsumed(FileGeometry const& geometry, int32_t piece, int64_t consumedBefore);

/// Bounded: the piece will never be readable again in this stream: freed, or consumed
/// while it was not on disk (a gap skipped by a forward seek). Pins are never gone.
bool isGone(FileGeometry const& geometry, PinSet const& pins, uint8_t state, int32_t piece,
            int64_t consumedBefore);

/// Plans priorities, deadlines and the pieces to free. Unbounded mode keeps
/// today's behaviour: every piece of the file stays wanted and the deadline
/// window slides over the next missing pieces.
PlanOutput planWindow(PlanInput const& input);

/// Pieces with data to drop when the disk is full: farthest from the reader
/// first, never pinned, never inside the deadline window.
std::vector<int32_t> piecesToDrop(PlanInput const& input, PlanOutput const& plan, int64_t needBytes);

/// Bytes the reader consumed between two samples of its position (`from` -> `to`), for
/// the consumption rate. A move over data that was never on disk is a seek, not
/// consumption (0): a reader only goes through pieces it could read. A sample is also
/// capped at `cap`, so a jump inside the window cannot inflate the rate.
/// `states` holds pieceCount() entries.
int64_t consumedBetween(FileGeometry const& geometry, std::vector<uint8_t> const& states,
                        int64_t from, int64_t to, int64_t cap);

#pragma mark - Pace controller

enum class PaceState : int { Open = 0, Proportional = 1, Floor = 2, Trickle = 3, Emergency = 4 };

struct PaceInput {
    int64_t aheadBytes = 0;
    int64_t aheadBudget = 0;
    double consumeRate = 0;        // bytes/s the reader advances, 0 if paused or unknown
    int64_t freeBytes = INT64_MAX; // volume free space now
    int64_t reserveBytes = 0;
    int floorRate = 64 * 1024;     // keeps peers busy while the window is full
    int trickleRate = 8 * 1024;    // window overfull or disk below the reserve
    bool urgent = false;           // pieces the reader needs now are missing (deadline window,
                                   // pins, waited pieces): never throttle then
};

struct PaceOutput {
    int downloadLimit = 0;         // bytes/s for torrent::set_download_limit, 0 = unlimited
    PaceState state = PaceState::Open;
};

/// Never pauses: it only ever lowers the rate to a small floor so peers stay connected.
/// While libtorrent has time-critical pieces it keeps one normal request per peer, so
/// the overshoot of an unthrottled urgent phase stays within the deadline window.
PaceOutput pace(PaceInput const& input);

/// Bytes ahead of the reader to drop so disk use stays flat while the reader does not
/// move (a pause of any length): the floor and trickle rates keep bringing data in.
/// Non-zero once the ahead data exceeds its budget by the floor band (12.5 %, at least
/// one piece; then down to the budget), or the volume is below the reserve. Never while
/// the reader waits for a piece.
int64_t excessAheadBytes(PaceInput const& input, int64_t pieceLength);

#pragma mark - Container head parser

/// Reads `length` bytes at `offset` of the file; false when they are not on disk yet.
using ReadAt = std::function<bool(int64_t offset, uint8_t* buffer, size_t length)>;

struct HeadPins {
    enum Status { NeedMore, Done } status = NeedMore;
    int64_t headPinEnd = 0;    // Done: [0, headPinEnd) must stay on disk
    int64_t tailPinStart = -1; // Done: start of an MP4 moov stored after mdat, -1 = default tail
    int64_t needOffset = 0;    // NeedMore: the parser waits for this byte
    const char* format = "unknown";
};

/// Finds how much of the head (and, for MP4 with moov at the end, of the tail)
/// a player needs to open the file again: MKV up to the first Cluster, MP4 up
/// to the end of moov. Unknown or damaged containers get kHeadPinFallback.
HeadPins parseHeadPins(ReadAt const& read, int64_t fileSize,
                       int64_t headLimit = kHeadPinLimit, int64_t fallback = kHeadPinFallback);

} // namespace ptbounded
