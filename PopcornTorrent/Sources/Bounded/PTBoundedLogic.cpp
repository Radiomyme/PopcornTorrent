//
//  PTBoundedLogic.cpp
//  PopcornTorrent
//

#include "PTBoundedLogic.hpp"

#include <algorithm>
#include <climits>
#include <cstring>

namespace ptbounded {

namespace {

int64_t roundUp(int64_t value, int64_t unit) {
    if (unit <= 0) return value;
    return ((value + unit - 1) / unit) * unit;
}

int64_t clampValue(int64_t value, int64_t low, int64_t high) {
    return std::max(low, std::min(value, high));
}

} // namespace

#pragma mark - FileGeometry

int32_t FileGeometry::pieceAt(int64_t offset) const {
    if (!valid()) return 0;
    offset = clampValue(offset, 0, fileSize - 1);
    return int32_t((fileOffset + offset) / pieceLength);
}

int64_t FileGeometry::pieceBegin(int32_t piece) const {
    int64_t const begin = int64_t(piece) * pieceLength - fileOffset;
    return clampValue(begin, 0, fileSize);
}

int64_t FileGeometry::pieceEnd(int32_t piece) const {
    int64_t const end = (int64_t(piece) + 1) * pieceLength - fileOffset;
    return clampValue(end, 0, fileSize);
}

int tailPinPieces(FileGeometry const& geo, int minimumPieces) {
    if (!geo.valid()) return std::max(1, minimumPieces);
    int const minimum = std::max(1, minimumPieces);
    int64_t const forBytes = (kTailPinBytes + geo.pieceLength - 1) / geo.pieceLength;
    int64_t pieces = std::max<int64_t>(minimum, std::min<int64_t>(forBytes, kTailPinMaxPieces));
    return int(std::min<int64_t>(pieces, geo.pieceCount()));
}

#pragma mark - Budget split

BudgetPlan planBudget(BudgetInput const& in) {
    BudgetPlan plan;
    double const duration = in.durationSeconds > 0 ? in.durationSeconds : kAssumedDurationSeconds;
    plan.bytesPerSecond = in.fileSize > 0 ? double(in.fileSize) / duration : 0;

    if (!in.allowBounded) {
        // Legacy check, unchanged: the logical size of an existing file counts as downloaded.
        int64_t const required = in.fileSize - in.existingLogicalBytes;
        plan.decision = required > in.freeBytes ? StorageDecision::Refuse : StorageDecision::Full;
        plan.minimumFreeBytes = std::max<int64_t>(0, required);
        return plan;
    }

    // Space other writers of the volume (offline downloads in progress) will still take.
    int64_t const free = std::max<int64_t>(0, in.freeBytes - std::max<int64_t>(0, in.pendingExternalBytes));
    int64_t const remaining = std::max<int64_t>(0, in.fileSize - in.heldBytes);
    // Full mode keeps the whole file: it must leave room for the app's own copy next to it
    // (the HLS segments a remux keeps around the playhead), or the two fill the volume and
    // the download fails with ENOSPC late in the film.
    int64_t const appWorkingSet = int64_t(std::max(0.0, in.appWorkingSetSeconds) * plan.bytesPerSecond);
    if (remaining + in.reserveBytes + appWorkingSet <= free) {
        plan.decision = StorageDecision::Full;
        plan.minimumFreeBytes = remaining + appWorkingSet;
        return plan;
    }

    int64_t const pieceLength = std::max<int64_t>(in.pieceLength, 16 * kKiB);
    double const bps = plan.bytesPerSecond;
    FileGeometry whole;
    whole.fileSize = in.fileSize;
    whole.pieceLength = pieceLength;
    plan.pinBudget = kHeadPinLimit + tailPinPieces(whole, kTailPinPieces) * pieceLength;
    plan.minAhead = roundUp(std::max<int64_t>(256 * kMiB, int64_t(60 * bps)), pieceLength);
    plan.inflightAllowance = std::max<int64_t>(32 * kMiB, 4 * pieceLength);
    // The app's own copy (HLS segments): 180 s of lookahead plus 60 s of rewind at least,
    // and its headroom (the segment being written).
    int64_t const appMinimum = int64_t(240 * bps) + std::max<int64_t>(kAppHeadroomBytes, int64_t(kAppHeadroomSeconds * bps));
    int64_t const torrentMinimum = plan.pinBudget + plan.minAhead + plan.inflightAllowance;
    plan.minimumFreeBytes = in.reserveBytes + torrentMinimum + appMinimum;

    int64_t const usable = free + in.heldBytes;
    if (usable < plan.minimumFreeBytes) {
        plan.decision = StorageDecision::Refuse;
        return plan;
    }

    int64_t const ceiling = std::max(torrentMinimum, usable - in.reserveBytes);
    if (in.requestedBudget > 0) {
        plan.torrentBudget = clampValue(in.requestedBudget, torrentMinimum, ceiling);
    } else {
        // About 5 min ahead of the reader and 3 min between the playhead and the reader,
        // leaving the rest to the app's copy.
        int64_t const target = plan.pinBudget + plan.inflightAllowance
            + clampValue(int64_t(300 * bps), plan.minAhead, kGiB) + int64_t(180 * bps);
        plan.torrentBudget = clampValue(target, torrentMinimum, std::max(torrentMinimum, ceiling - appMinimum));
    }
    plan.decision = StorageDecision::Bounded;
    return plan;
}

int64_t aheadBudget(BudgetPlan const& plan, int64_t pieceLength, int64_t pinnedBytes,
                    int64_t behindBytes, double shrink) {
    int64_t const raw = plan.torrentBudget - pinnedBytes - behindBytes - plan.inflightAllowance;
    int64_t value = std::max(plan.minAhead, raw);
    if (shrink > 0 && shrink < 1) value = int64_t(double(value) * shrink);
    return std::max(value, 2 * std::max<int64_t>(pieceLength, 16 * kKiB));
}

#pragma mark - Window planner

bool isPinned(FileGeometry const& geometry, PinSet const& pins, int32_t piece) {
    if (piece == pins.extraPiece) return true;
    if (pins.headEnd > 0 && geometry.pieceBegin(piece) < pins.headEnd) return true;
    if (pins.tailStart >= 0 && geometry.pieceEnd(piece) > pins.tailStart) return true;
    return false;
}

bool onDiskToTheEnd(FileGeometry const& geometry, std::vector<uint8_t> const& states, int32_t fromPiece) {
    if (!geometry.valid() || int32_t(states.size()) < geometry.pieceCount()) return false;
    int32_t const first = geometry.firstPiece();
    for (int32_t piece = std::max(fromPiece, first); piece <= geometry.lastPiece(); ++piece) {
        if (states[size_t(piece - first)] != PieceOnDisk) return false;
    }
    return true;
}

bool isConsumed(FileGeometry const& geometry, int32_t piece, int64_t consumedBefore) {
    // One whole piece is kept below the consumed offset as a guard.
    return geometry.pieceEnd(piece) + geometry.pieceLength <= consumedBefore;
}

bool isGone(FileGeometry const& geometry, PinSet const& pins, uint8_t state, int32_t piece,
            int64_t consumedBefore) {
    if (state == PieceFreed) return true;
    if (state != PieceMissing && state != PieceDropping) return false; // on disk, or soon
    return !isPinned(geometry, pins, piece) && isConsumed(geometry, piece, consumedBefore);
}

int64_t consumedFloor(FileGeometry const& geo, PinSet const& pins, int64_t consumedBefore) {
    if (!geo.valid() || consumedBefore <= 0) return 0;
    // The highest consumed piece is the one just below pieceAt(consumedBefore) minus the guard;
    // pinned pieces (tail, MP4 moov) are skipped.
    for (int32_t piece = geo.pieceAt(consumedBefore); piece >= geo.firstPiece(); --piece) {
        if (!isConsumed(geo, piece, consumedBefore)) continue;
        if (isPinned(geo, pins, piece)) {
            if (pins.headEnd > 0 && geo.pieceBegin(piece) < pins.headEnd) return 0; // down to the head pin
            continue;
        }
        return geo.pieceEnd(piece);
    }
    return 0;
}

int64_t contiguousAvailableStart(FileGeometry const& geo, std::vector<uint8_t> const& states,
                                 PinSet const& pins, bool bounded, int64_t consumedBefore, int64_t offset) {
    if (!geo.valid() || int32_t(states.size()) < geo.pieceCount()) return std::max<int64_t>(0, offset);
    offset = clampValue(offset, 0, geo.fileSize);
    if (offset == 0) return 0;
    int32_t const first = geo.firstPiece();
    auto available = [&](int32_t piece) {
        if (states[size_t(piece - first)] != PieceOnDisk) return false;
        return !bounded || isPinned(geo, pins, piece) || !isConsumed(geo, piece, consumedBefore);
    };
    int32_t piece = geo.pieceAt(offset - 1);
    while (piece >= first && available(piece)) --piece;
    return piece < first ? 0 : std::min(offset, geo.pieceEnd(piece));
}

PlanOutput planWindow(PlanInput const& in) {
    PlanOutput out;
    FileGeometry const& geo = in.geometry;
    int32_t const count = geo.pieceCount();
    if (count <= 0 || in.states == nullptr || int32_t(in.states->size()) < count) return out;

    int32_t const first = geo.firstPiece();
    int32_t const last = geo.lastPiece();
    int const windowPieces = std::max(1, in.deadlinePieces);
    int64_t const consumed = in.bounded ? in.consumedBefore : 0;

    out.priorities.assign(size_t(count), 0);
    out.readPiece = geo.pieceAt(in.readPosition);
    out.windowEndPiece = std::min(last + 1, out.readPiece + windowPieces);

    int deadlineIndex = 0;
    int32_t lastDeadlinePiece = out.readPiece - 1;
    std::vector<int32_t> missingPins;
    int64_t lowest = 0;

    for (int32_t i = 0; i < count; ++i) {
        int32_t const piece = first + i;
        uint8_t const state = (*in.states)[size_t(i)];
        bool const data = pieceHasData(state);
        int64_t const bytes = geo.pieceBytes(piece);
        bool const pinned = isPinned(geo, in.pins, piece);
        if (data) out.dataBytes += bytes;

        if (state == PieceFreed || state == PieceDropping) {
            if (state == PieceFreed && !pinned) lowest = std::max(lowest, geo.pieceEnd(piece));
            continue; // priority 0: never fetched again (Dropping: until punched)
        }

        if (pinned) {
            out.priorities[size_t(i)] = 7;
            bool const headPinned = in.pins.headEnd > 0 && geo.pieceBegin(piece) < in.pins.headEnd;
            bool const lazyTail = in.urgentTailStart >= 0 && !headPinned && piece != in.pins.extraPiece
                && geo.pieceEnd(piece) <= in.urgentTailStart;
            if (data) out.pinnedBytes += bytes;
            else if (!lazyTail) missingPins.push_back(piece);
            continue;
        }

        if (in.bounded && isConsumed(geo, piece, consumed)) {
            // Only pieces confirmed on disk are freed: a piece still being verified may
            // have blocks in libtorrent's cache, written after the hole is punched.
            if (state == PieceOnDisk) out.toFree.push_back(piece);
            lowest = std::max(lowest, geo.pieceEnd(piece));
            continue; // priority 0
        }

        if (piece < out.readPiece) {
            if (data) {
                out.priorities[size_t(i)] = 1;
                out.behindBytes += bytes;
            } else {
                // Bounded: gaps behind the reader (skipped by a seek) are not fetched.
                out.priorities[size_t(i)] = in.bounded ? 0 : 1;
            }
            continue;
        }

        if (data) {
            out.priorities[size_t(i)] = 1;
            out.aheadBytes += bytes;
            continue;
        }

        bool const inWindow = in.bounded ? piece < out.windowEndPiece : deadlineIndex < windowPieces;
        if (inWindow) {
            int const step = in.bounded ? int(piece - out.readPiece) : deadlineIndex;
            // Bounded: 6 (kBoundedWindowPriority), not 7. libtorrent's sequential picker takes the
            // top-priority (7) pieces in a random order (its priority buckets are shuffled), and
            // the other wanted pieces in index order from the first one missing: with the whole
            // window at 7 the read piece came in among the last of its 80 MiB window after a seek
            // (7.1 s with a 12 MB/s seed, against 1.07 s in full mode: part-3 coverage md4, mc3).
            // At 6 the window comes in file order, after the pins and the pieces a reader waits for
            // (7: the read piece itself after a seek, see urgentPieces below).
            out.priorities[size_t(i)] = in.bounded ? kBoundedWindowPriority : 7;
            out.deadlines.emplace_back(piece, in.deadlineFirstMs + step * in.deadlineStepMs);
            ++deadlineIndex;
            lastDeadlinePiece = piece;
        } else {
            out.priorities[size_t(i)] = 1;
        }
    }

    if (!in.bounded) out.windowEndPiece = std::max(out.readPiece, lastDeadlinePiece + 1);

    for (int32_t piece : in.urgentPieces) {
        if (piece < first || piece > last) continue;
        size_t const i = size_t(piece - first);
        if ((*in.states)[i] != PieceMissing) continue;
        bool const consumedPiece = in.bounded && !isPinned(geo, in.pins, piece) && isConsumed(geo, piece, consumed);
        if (consumedPiece) continue;
        bool const scheduled = out.priorities[i] == 7 && std::any_of(out.deadlines.begin(), out.deadlines.end(),
            [piece](std::pair<int32_t, int> const& d) { return d.first == piece; });
        out.priorities[i] = 7;
        if (!scheduled) out.deadlines.emplace_back(piece, in.deadlineFirstMs);
        out.urgent = true;
    }


    int const pinMs = in.deadlineFirstMs + windowPieces * in.deadlineStepMs;
    for (int32_t piece : missingPins) out.deadlines.emplace_back(piece, pinMs);
    out.urgent = !out.deadlines.empty();

    // A piece the reader needs is late: until it is here, nothing beyond the ahead
    // budget is wanted. Back to priority 1 afterwards.
    // One missing piece beyond the cap stays wanted (the sentinel): otherwise the late
    // piece can be the last wanted one, and libtorrent marks the torrent finished the
    // moment it arrives, before the next plan wants the rest again. The sentinel is the
    // next piece the window needs anyway, and it is kept for the whole late episode:
    // once it is downloaded no other one is chosen, so at most one extra piece comes in.
    if (in.bounded && out.urgent && in.aheadLimitPieces > 0) {
        int32_t const capPiece = out.readPiece + std::max(in.aheadLimitPieces, windowPieces);
        int32_t sentinel = -1;
        bool spent = false;
        if (in.capSentinel >= first && in.capSentinel <= last) {
            size_t const i = size_t(in.capSentinel - first);
            if ((*in.states)[i] != PieceMissing) spent = true;
            else if (out.priorities[i] > 0) sentinel = in.capSentinel; // still wanted (a seek may have left it behind)
        }
        for (int32_t piece = std::max(capPiece, first); piece <= last; ++piece) {
            size_t const i = size_t(piece - first);
            if ((*in.states)[i] != PieceMissing || out.priorities[i] != 1) continue;
            if (sentinel < 0 && !spent) sentinel = piece;
            if (piece != sentinel) out.priorities[i] = 0;
        }
        out.capSentinel = spent ? in.capSentinel : sentinel;
    }

    out.lowestAvailableOffset = in.bounded ? std::min(lowest, geo.fileSize) : 0;
    return out;
}

std::vector<int32_t> piecesToDrop(PlanInput const& in, PlanOutput const& plan, int64_t needBytes) {
    std::vector<int32_t> result;
    FileGeometry const& geo = in.geometry;
    if (needBytes <= 0 || in.states == nullptr || geo.pieceCount() <= 0) return result;
    // The rest of the file is all here: the reader may take it as final, never drop it.
    if (onDiskToTheEnd(geo, *in.states, plan.readPiece)) return result;
    int32_t const first = geo.firstPiece();
    int64_t freed = 0;
    for (int32_t piece = geo.lastPiece(); piece >= std::max(plan.windowEndPiece, first) && freed < needBytes; --piece) {
        uint8_t const state = (*in.states)[size_t(piece - first)];
        if (!pieceHasData(state) || isPinned(geo, in.pins, piece)) continue;
        result.push_back(piece);
        freed += geo.pieceBytes(piece);
    }
    return result;
}

int64_t consumedBetween(FileGeometry const& geo, std::vector<uint8_t> const& states,
                        int64_t from, int64_t to, int64_t cap) {
    if (!geo.valid() || to <= from || from < 0) return 0;
    int32_t const first = geo.firstPiece();
    if (int32_t(states.size()) < geo.pieceCount()) return 0;
    for (int32_t piece = geo.pieceAt(from); piece <= geo.pieceAt(to - 1); ++piece) {
        uint8_t const state = states[size_t(piece - first)];
        // Freed and dropped pieces were on disk when the reader went through them.
        if (state == PieceMissing || state == PieceVerifying) return 0;
    }
    return std::min(to - from, std::max<int64_t>(0, cap));
}

#pragma mark - Pace controller

PaceOutput pace(PaceInput const& in) {
    PaceOutput out;
    if (in.urgent) {
        // The reader waits: the pieces it needs come first (priority 7), so the rate is
        // not what fills the disk. Only a disk below half the reserve slows them down.
        bool const critical = in.freeBytes < in.reserveBytes / 2;
        out.downloadLimit = critical ? in.floorRate : 0;
        out.state = critical ? PaceState::Emergency : PaceState::Open;
        return out;
    }
    if (in.freeBytes < in.reserveBytes) {
        out.downloadLimit = in.trickleRate;
        out.state = PaceState::Emergency;
        return out;
    }
    if (in.aheadBudget <= 0) {
        out.downloadLimit = in.floorRate;
        out.state = PaceState::Floor;
        return out;
    }
    double const fill = double(in.aheadBytes) / double(in.aheadBudget);
    if (fill < 0.75) {
        out.downloadLimit = 0;
        out.state = PaceState::Open;
    } else if (fill < 1.0) {
        // From twice the consumption rate at 75 % down to the consumption rate at 100 %.
        double const rate = std::max(double(in.floorRate), in.consumeRate * (1.0 + 4.0 * (1.0 - fill)));
        out.downloadLimit = int(std::min(rate, double(INT_MAX - 1)));
        out.state = PaceState::Proportional;
    } else if (fill < 1.125) {
        out.downloadLimit = in.floorRate;
        out.state = PaceState::Floor;
    } else {
        out.downloadLimit = in.trickleRate;
        out.state = PaceState::Trickle;
    }
    return out;
}

int64_t excessAheadBytes(PaceInput const& in, int64_t pieceLength) {
    if (in.urgent) return 0;
    int64_t excess = 0;
    int64_t const band = std::max(std::max<int64_t>(pieceLength, 16 * kKiB), in.aheadBudget / 8);
    if (in.aheadBudget > 0 && in.aheadBytes > in.aheadBudget + band) excess = in.aheadBytes - in.aheadBudget;
    if (in.freeBytes != INT64_MAX && in.freeBytes < in.reserveBytes) {
        excess = std::max(excess, in.reserveBytes - in.freeBytes);
    }
    return excess;
}

#pragma mark - Container head parser

namespace {

uint32_t readBE32(uint8_t const* p) {
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | uint32_t(p[3]);
}

uint64_t readBE64(uint8_t const* p) {
    return (uint64_t(readBE32(p)) << 32) | uint64_t(readBE32(p + 4));
}

int vintLength(uint8_t firstByte) {
    for (int i = 0; i < 8; ++i) {
        if (firstByte & (0x80 >> i)) return i + 1;
    }
    return 0;
}

struct EbmlHeader {
    uint32_t id = 0;
    int64_t size = 0;
    bool unknownSize = false;
    int headerLength = 0;
};

// Parses an EBML element header (ID with its marker bits, then the size).
bool parseEbmlHeader(uint8_t const* p, size_t available, EbmlHeader& out) {
    if (available < 2) return false;
    int const idLength = vintLength(p[0]);
    if (idLength < 1 || idLength > 4 || size_t(idLength) >= available) return false;
    uint32_t id = 0;
    for (int i = 0; i < idLength; ++i) id = (id << 8) | p[i];
    int const sizeLength = vintLength(p[idLength]);
    if (sizeLength < 1 || size_t(idLength + sizeLength) > available) return false;
    uint64_t value = p[idLength] & (0xFF >> sizeLength);
    bool allOnes = value == uint64_t(0xFF >> sizeLength);
    for (int i = 1; i < sizeLength; ++i) {
        uint8_t const byte = p[idLength + i];
        value = (value << 8) | byte;
        allOnes = allOnes && byte == 0xFF;
    }
    out.id = id;
    out.size = int64_t(value);
    out.unknownSize = allOnes;
    out.headerLength = idLength + sizeLength;
    return true;
}

bool isKnownBoxType(uint8_t const* type) {
    static char const* const types[] = {"ftyp", "styp", "moov", "free", "skip", "mdat", "wide", "pdin", "uuid", "sidx", "moof"};
    for (char const* known : types) {
        if (std::memcmp(type, known, 4) == 0) return true;
    }
    return false;
}

HeadPins done(int64_t headPinEnd, int64_t tailPinStart, char const* format) {
    HeadPins result;
    result.status = HeadPins::Done;
    result.headPinEnd = std::max<int64_t>(1, headPinEnd);
    result.tailPinStart = tailPinStart;
    result.format = format;
    return result;
}

HeadPins needMore(int64_t offset) {
    HeadPins result;
    result.status = HeadPins::NeedMore;
    result.needOffset = offset;
    return result;
}

HeadPins parseMatroska(ReadAt const& read, int64_t fileSize, int64_t headLimit, int64_t fallback) {
    uint8_t buffer[12];
    auto element = [&](int64_t offset, EbmlHeader& header) -> int { // 1 ok, 0 need more, -1 invalid
        size_t const length = size_t(std::min<int64_t>(sizeof(buffer), fileSize - offset));
        if (length < 2) return -1;
        if (!read(offset, buffer, length)) return 0;
        return parseEbmlHeader(buffer, length, header) ? 1 : -1;
    };
    HeadPins const unknown = done(std::min(fallback, fileSize), -1, "unknown");

    EbmlHeader header;
    int status = element(0, header);
    if (status == 0) return needMore(0);
    if (status < 0 || header.id != 0x1A45DFA3 || header.unknownSize) return unknown;
    int64_t position = header.headerLength + header.size;

    status = element(position, header);
    if (status == 0) return needMore(position);
    if (status < 0 || header.id != 0x18538067) return unknown;
    position += header.headerLength; // first child of the Segment

    for (int count = 0; count < 100000; ++count) {
        if (position >= headLimit) return done(headLimit, -1, "mkv");
        if (position >= fileSize) return unknown;
        status = element(position, header);
        if (status == 0) return needMore(position);
        if (status < 0) return unknown;
        if (header.id == 0x1F43B675) {
            // First Cluster. A player opening the file again (VLC after a hand-off) also
            // reads the first clusters and prefetches before its first seek takes effect.
            int64_t const opening = std::min(headLimit, kMatroskaHeadPinBytes);
            return done(std::min(fileSize, std::max(position, opening)), -1, "mkv");
        }
        if (header.unknownSize) return unknown;
        position += header.headerLength + header.size;
    }
    return unknown;
}

HeadPins parseMP4(ReadAt const& read, int64_t fileSize, int64_t headLimit, int64_t fallback) {
    uint8_t buffer[16];
    HeadPins const unknown = done(std::min(fallback, fileSize), -1, "unknown");
    int64_t position = 0;
    int64_t mdatPayload = -1;

    for (int count = 0; count < 10000; ++count) {
        if (position >= fileSize) return unknown; // no moov found
        size_t const length = size_t(std::min<int64_t>(sizeof(buffer), fileSize - position));
        if (length < 8) return unknown;
        if (!read(position, buffer, length)) return needMore(position);
        uint64_t size = readBE32(buffer);
        int64_t headerLength = 8;
        if (size == 1) {
            if (length < 16) return unknown;
            size = readBE64(buffer + 8);
            headerLength = 16;
        } else if (size == 0) {
            size = uint64_t(fileSize - position);
        }
        if (size < uint64_t(headerLength) || size > uint64_t(fileSize - position)) return unknown;

        if (std::memcmp(buffer + 4, "moov", 4) == 0) {
            if (mdatPayload < 0) return done(std::min<int64_t>(position + int64_t(size), headLimit), -1, "mp4");
            // moov after mdat: pin it with the tail, and the boxes before mdat with the head.
            int64_t const tailStart = std::max(position, fileSize - headLimit);
            return done(std::min(mdatPayload, headLimit), tailStart, "mp4");
        }
        if (std::memcmp(buffer + 4, "mdat", 4) == 0 && mdatPayload < 0) mdatPayload = position + headerLength;
        position += int64_t(size);
    }
    return unknown;
}

} // namespace

bool isDiskStarved(int64_t freeBytes, int64_t reserveBytes, bool uploadMode) {
    if (uploadMode) return true;
    return freeBytes != INT64_MAX && freeBytes < reserveBytes / 2;
}

bool startStarvationExpired(bool ready, double starvedSeconds) {
    return !ready && starvedSeconds >= kStartStarvationSeconds;
}

int64_t bytesToFreeAfterStarvation(int64_t minimumFreeBytes, int64_t freeBytes, int64_t heldBytes) {
    int64_t const available = std::max<int64_t>(0, freeBytes == INT64_MAX ? 0 : freeBytes) + std::max<int64_t>(0, heldBytes);
    return std::max<int64_t>(0, minimumFreeBytes - available);
}

HeadPins parseHeadPins(ReadAt const& read, int64_t fileSize, int64_t headLimit, int64_t fallback) {
    if (fileSize < 16) return done(std::max<int64_t>(1, fileSize), -1, "unknown");
    uint8_t magic[8];
    if (!read(0, magic, sizeof(magic))) return needMore(0);
    if (magic[0] == 0x1A && magic[1] == 0x45 && magic[2] == 0xDF && magic[3] == 0xA3) {
        return parseMatroska(read, fileSize, headLimit, fallback);
    }
    if (isKnownBoxType(magic + 4)) return parseMP4(read, fileSize, headLimit, fallback);
    return done(std::min(fallback, fileSize), -1, "unknown");
}

} // namespace ptbounded
