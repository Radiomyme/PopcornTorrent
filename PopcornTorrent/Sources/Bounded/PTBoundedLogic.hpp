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
/// Least head pin of a Matroska file, past its first Cluster: what a player that opens the
/// file again reads before its first seek can take effect (VLCKit 4 over HTTP: its prefetch
/// and the first clusters it demuxes, 20-30 MB measured at 1.67 MB/s), so a hand-off to VLC
/// does not run into freed data right after the header (HTTP 410). Capped by the head limit.
constexpr int64_t kMatroskaHeadPinBytes = 64 * kMiB;
/// What the app keeps next to the file in bounded mode besides its share of the HLS copy
/// (the segment being written, rounding): added to the minimum working set, at least this,
/// at least 20 s of the bitrate.
constexpr int64_t kAppHeadroomBytes = 32 * kMiB;
constexpr double kAppHeadroomSeconds = 20;
/// Fewest pieces pinned at the end of the file in bounded mode (MKV Cues, MP4 moov at the end).
constexpr int kTailPinPieces = 2;
/// Bytes the tail pin covers at least (MKV Cues, an MP4 moov stored at the end: a few MiB
/// for a 2 h film), in whole pieces: see tailPinPieces.
constexpr int64_t kTailPinBytes = 8 * kMiB;
/// Most pieces of a tail pin made of small pieces (what the CocoaPods PopcornTorrent fetched).
constexpr int kTailPinMaxPieces = 10;
/// Runtime assumed when the app gives no duration (to estimate the bitrate from the size).
constexpr double kAssumedDurationSeconds = 2 * 3600;
/// Most bytes the head parser reads at one offset (an EBML element header, an MP4 box header).
constexpr int64_t kHeadParserLookahead = 16;
/// Bounded mode, before the stream is ready: how long the volume may stay too full for the
/// download to go on (see isDiskStarved) before the stream fails with
/// NotEnoughSpaceForBoundedStorage instead of loading forever.
constexpr double kStartStarvationSeconds = 30;
/// Hole punching of an allocation runaway, in steps of this size: APFS refuses one
/// F_PUNCHHOLE over gigabytes of zero-filled blocks on a full volume (ENOSPC, measured),
/// while each 64 MiB step gives its space back before the next one.
constexpr int64_t kReclaimStepBytes = 64 * kMiB;
/// Smaller step tried when a reclaim step fails with ENOSPC.
constexpr int64_t kReclaimSmallStepBytes = 4 * kMiB;

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

/// Pieces pinned at the end of the file (kept, fetched at top priority): enough
/// whole pieces for kTailPinBytes, at least `minimumPieces`, at most kTailPinMaxPieces
/// (unless `minimumPieces` is larger) and at most the file's pieces.
int tailPinPieces(FileGeometry const& geometry, int minimumPieces);

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
    double appWorkingSetSeconds = 0; // media the app keeps next to the whole file in full mode
                                     // (its HLS copy), at the file's bitrate: full mode only when
                                     // the file, the reserve and this fit (0 = the file alone)
    int64_t pendingExternalBytes = 0; // bytes other writers (offline downloads) will still add to
                                      // the volume: not counted as free
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
    int64_t urgentTailStart = -1;   // missing tail pins entirely below this offset get priority 7
                                    // without a deadline (full mode: the byte-sized extension of
                                    // the tail the stream does not wait for); -1 = every pin urgent
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

/// Every piece from `fromPiece` to the end of the file is on disk (PieceOnDisk).
bool onDiskToTheEnd(FileGeometry const& geometry, std::vector<uint8_t> const& states, int32_t fromPiece);

/// Bounded: the piece lies entirely below `consumedBefore` minus one guard piece.
bool isConsumed(FileGeometry const& geometry, int32_t piece, int64_t consumedBefore);

/// Bounded: the piece will never be readable again in this stream: freed, or consumed
/// while it was not on disk (a gap skipped by a forward seek). Pins are never gone.
bool isGone(FileGeometry const& geometry, PinSet const& pins, uint8_t state, int32_t piece,
            int64_t consumedBefore);

/// Bounded: end of the highest piece that is consumed and not pinned (0 if none): data
/// below it, apart from the pinned head, is deleted or about to be. Exact at call time
/// (PlanOutput::lowestAvailableOffset lags until the next plan).
int64_t consumedFloor(FileGeometry const& geometry, PinSet const& pins, int64_t consumedBefore);

/// Lowest offset `start` <= `offset` such that every piece overlapping [start, offset) is
/// readable and stays so: on disk and, in bounded mode, pinned or not consumed (consumed
/// pieces are deleted within a second). `offset` itself when the byte before it is not.
/// `states` holds pieceCount() entries.
int64_t contiguousAvailableStart(FileGeometry const& geometry, std::vector<uint8_t> const& states,
                                 PinSet const& pins, bool bounded, int64_t consumedBefore, int64_t offset);

/// Plans priorities, deadlines and the pieces to free. Unbounded mode keeps
/// today's behaviour: every piece of the file stays wanted and the deadline
/// window slides over the next missing pieces.
PlanOutput planWindow(PlanInput const& input);

/// Pieces with data to drop when the disk is full: farthest from the reader
/// first, never pinned, never inside the deadline window. None once every piece
/// from the read piece to the end of the file is on disk: nothing more is downloaded
/// then, and the consumer may take the rest of the file as final (the app's remux
/// marks its input complete and reads zeros as data from then on).
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

/// The download cannot go on for lack of space: the free space is below half the reserve
/// (INT64_MAX: unknown, never starved by it), or libtorrent is in upload mode (its reaction
/// to ENOSPC).
bool isDiskStarved(int64_t freeBytes, int64_t reserveBytes, bool uploadMode);

/// Bounded mode: a stream that is not ready yet and has been starved of space for at least
/// kStartStarvationSeconds fails (NotEnoughSpaceForBoundedStorage). A ready stream never does:
/// its reader waits as long as the volume stays full.
bool startStarvationExpired(bool ready, double starvedSeconds);

/// What to free so that bounded storage can start again once this stream is gone: its file
/// (`heldBytes`) is deleted at cancel. 0 when that alone is enough.
int64_t bytesToFreeAfterStarvation(int64_t minimumFreeBytes, int64_t freeBytes, int64_t heldBytes);

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
/// a player needs to open the file again: MKV up to the first Cluster and at least
/// kMatroskaHeadPinBytes (a player's opening reads), MP4 up to the end of moov.
/// Unknown or damaged containers get kHeadPinFallback. Never past `headLimit`.
HeadPins parseHeadPins(ReadAt const& read, int64_t fileSize,
                       int64_t headLimit = kHeadPinLimit, int64_t fallback = kHeadPinFallback);

} // namespace ptbounded
