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

    int64_t const remaining = std::max<int64_t>(0, in.fileSize - in.heldBytes);
    if (remaining + in.reserveBytes <= in.freeBytes) {
        plan.decision = StorageDecision::Full;
        plan.minimumFreeBytes = remaining;
        return plan;
    }

    int64_t const pieceLength = std::max<int64_t>(in.pieceLength, 16 * kKiB);
    double const bps = plan.bytesPerSecond;
    plan.pinBudget = kHeadPinLimit + kTailPinPieces * pieceLength;
    plan.minAhead = roundUp(std::max<int64_t>(256 * kMiB, int64_t(60 * bps)), pieceLength);
    plan.inflightAllowance = std::max<int64_t>(32 * kMiB, 4 * pieceLength);
    // The app's own copy (HLS segments): 180 s of lookahead plus 60 s of rewind at least.
    int64_t const appMinimum = int64_t(240 * bps);
    int64_t const torrentMinimum = plan.pinBudget + plan.minAhead + plan.inflightAllowance;
    plan.minimumFreeBytes = in.reserveBytes + torrentMinimum + appMinimum;

    int64_t const usable = in.freeBytes + in.heldBytes;
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

PlanOutput planWindow(PlanInput const& in) {
    PlanOutput out;
    FileGeometry const& geo = in.geometry;
    int32_t const count = geo.pieceCount();
    if (count <= 0 || in.states == nullptr || int32_t(in.states->size()) < count) return out;

    int32_t const first = geo.firstPiece();
    int32_t const last = geo.lastPiece();
    int const windowPieces = std::max(1, in.deadlinePieces);
    int64_t const consumed = in.bounded ? in.consumedBefore : 0;
    // One whole piece is kept below the consumed offset as a guard.
    int64_t const guardBytes = geo.pieceLength;

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
            if (data) out.pinnedBytes += bytes;
            else missingPins.push_back(piece);
            continue;
        }

        if (in.bounded && geo.pieceEnd(piece) + guardBytes <= consumed) {
            if (data) out.toFree.push_back(piece);
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
            out.priorities[size_t(i)] = 7;
            out.deadlines.emplace_back(piece, in.deadlineFirstMs + step * in.deadlineStepMs);
            ++deadlineIndex;
            lastDeadlinePiece = piece;
        } else {
            out.priorities[size_t(i)] = 1;
        }
    }

    if (!in.bounded) out.windowEndPiece = std::max(out.readPiece, lastDeadlinePiece + 1);

    int const pinMs = in.deadlineFirstMs + windowPieces * in.deadlineStepMs;
    for (int32_t piece : missingPins) out.deadlines.emplace_back(piece, pinMs);

    out.lowestAvailableOffset = in.bounded ? std::min(lowest, geo.fileSize) : 0;
    return out;
}

std::vector<int32_t> piecesToDrop(PlanInput const& in, PlanOutput const& plan, int64_t needBytes) {
    std::vector<int32_t> result;
    FileGeometry const& geo = in.geometry;
    if (needBytes <= 0 || in.states == nullptr || geo.pieceCount() <= 0) return result;
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

#pragma mark - Pace controller

PaceOutput pace(PaceInput const& in) {
    PaceOutput out;
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
        if (header.id == 0x1F43B675) return done(position, -1, "mkv"); // first Cluster
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
