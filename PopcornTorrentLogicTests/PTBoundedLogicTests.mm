//
//  PTBoundedLogicTests.mm
//  PopcornTorrentLogicTests
//
//  Unit tests of the bounded-storage pure logic: budget split, window planner,
//  pace controller and container head parser. Offline, no torrent involved.
//

#import <XCTest/XCTest.h>

#include <algorithm>
#include <cstring>
#include <vector>

#include "../PopcornTorrent/Sources/Bounded/PTBoundedLogic.hpp"

using namespace ptbounded;

namespace {

constexpr int64_t kGB = 1000LL * 1000 * 1000;

FileGeometry geometry(int64_t fileOffset, int64_t fileSize, int64_t pieceLength) {
    FileGeometry geo;
    geo.fileOffset = fileOffset;
    geo.fileSize = fileSize;
    geo.pieceLength = pieceLength;
    return geo;
}

void appendBytes(std::vector<uint8_t>& out, std::initializer_list<int> bytes) {
    for (int b : bytes) out.push_back(uint8_t(b));
}

void appendFill(std::vector<uint8_t>& out, size_t count) {
    out.insert(out.end(), count, uint8_t(0x5A));
}

void appendBE32(std::vector<uint8_t>& out, uint32_t value) {
    appendBytes(out, {int(value >> 24) & 0xFF, int(value >> 16) & 0xFF, int(value >> 8) & 0xFF, int(value) & 0xFF});
}

ReadAt memoryReader(std::vector<uint8_t> const& data, int64_t available) {
    return [&data, available](int64_t offset, uint8_t* buffer, size_t length) -> bool {
        if (offset < 0 || offset + int64_t(length) > available || offset + int64_t(length) > int64_t(data.size())) return false;
        std::memcpy(buffer, data.data() + offset, length);
        return true;
    };
}

} // namespace

@interface PTBoundedLogicTests : XCTestCase
@end

@implementation PTBoundedLogicTests

#pragma mark - Geometry

- (void)testGeometryOfAFileInsideAMultiFileTorrent {
    FileGeometry const geo = geometry(3 * kMiB + 100, 10 * kMiB, 2 * kMiB);
    XCTAssertEqual(geo.firstPiece(), 1);
    XCTAssertEqual(geo.lastPiece(), 6); // (3 MiB + 100 + 10 MiB - 1) / 2 MiB
    XCTAssertEqual(geo.pieceCount(), 6);
    XCTAssertEqual(geo.pieceBegin(1), 0);
    XCTAssertEqual(geo.pieceEnd(1), 1 * kMiB - 100);
    XCTAssertEqual(geo.pieceBegin(2), 1 * kMiB - 100);
    XCTAssertEqual(geo.pieceEnd(6), 10 * kMiB);
    XCTAssertEqual(geo.pieceAt(0), 1);
    XCTAssertEqual(geo.pieceAt(-5), 1);
    XCTAssertEqual(geo.pieceAt(20 * kMiB), 6);
}

#pragma mark - Budget split

- (void)testFileThatFitsWithTheReserveStaysFull {
    BudgetInput input;
    input.fileSize = 13 * kGB;
    input.pieceLength = 8 * kMiB;
    input.freeBytes = 13 * kGB + kDefaultReserveBytes;
    XCTAssertTrue(planBudget(input).decision == StorageDecision::Full);
    input.freeBytes -= 1;
    XCTAssertTrue(planBudget(input).decision == StorageDecision::Bounded);
}

- (void)testThirteenGigabytesThroughThreeGigabytesIsBounded {
    BudgetInput input;
    input.fileSize = 13 * kGB;
    input.pieceLength = 8 * kMiB;
    input.freeBytes = 2800 * kMiB;
    input.durationSeconds = 130 * 60;
    BudgetPlan const plan = planBudget(input);
    XCTAssertTrue(plan.decision == StorageDecision::Bounded);
    // About 1.25 GiB at this bitrate (1.67 MB/s).
    XCTAssertGreaterThan(plan.minimumFreeBytes, 1100 * kMiB);
    XCTAssertLessThan(plan.minimumFreeBytes, 1400 * kMiB);
    XCTAssertGreaterThanOrEqual(plan.torrentBudget, plan.pinBudget + plan.minAhead + plan.inflightAllowance);
    XCTAssertLessThanOrEqual(plan.torrentBudget, input.freeBytes - input.reserveBytes);
    XCTAssertEqual(plan.minAhead % input.pieceLength, 0);
    XCTAssertGreaterThanOrEqual(plan.minAhead, 256 * kMiB);
}

- (void)testBelowTheMinimumWorkingSetIsRefused {
    BudgetInput input;
    input.fileSize = 13 * kGB;
    input.pieceLength = 8 * kMiB;
    input.freeBytes = 1 * kGiB;
    BudgetPlan const plan = planBudget(input);
    XCTAssertTrue(plan.decision == StorageDecision::Refuse);
    XCTAssertGreaterThan(plan.minimumFreeBytes, input.freeBytes);
}

- (void)testMinimumWorkingSetScalesWithTheBitrate {
    BudgetInput hd;
    hd.fileSize = 13 * kGB;
    hd.pieceLength = 8 * kMiB;
    hd.freeBytes = 2800 * kMiB;
    hd.durationSeconds = 130 * 60;
    BudgetInput uhd = hd;
    uhd.fileSize = 60 * kGB;
    uhd.pieceLength = 16 * kMiB;
    uhd.durationSeconds = 60 * kGB / 7e6; // 7 MB/s
    BudgetPlan const hdPlan = planBudget(hd);
    BudgetPlan const uhdPlan = planBudget(uhd);
    XCTAssertGreaterThan(uhdPlan.minimumFreeBytes, hdPlan.minimumFreeBytes);
    // A 60 GB 4K film (7 MB/s) needs a little more than 2.8 GiB once the app's headroom
    // (20 s of the bitrate) is counted: refused there, bounded with 2.9 GiB.
    XCTAssertTrue(uhdPlan.decision == StorageDecision::Refuse);
    XCTAssertLessThan(uhdPlan.minimumFreeBytes, 2900 * kMiB);
    uhd.freeBytes = 2900 * kMiB;
    XCTAssertTrue(planBudget(uhd).decision == StorageDecision::Bounded);
    // Unknown duration: estimated from the size over two hours.
    BudgetInput unknown = hd;
    unknown.durationSeconds = 0;
    XCTAssertEqualWithAccuracy(planBudget(unknown).bytesPerSecond, 13 * kGB / 7200.0, 1.0);
}

- (void)testMinimumWorkingSetCountsTheAppHeadroom {
    BudgetInput hd;
    hd.fileSize = 13 * kGB;
    hd.pieceLength = 8 * kMiB;
    hd.freeBytes = 2800 * kMiB;
    hd.durationSeconds = 130 * 60;
    BudgetPlan const plan = planBudget(hd);
    double const bps = 13 * kGB / (130 * 60.0);
    int64_t const app = int64_t(240 * bps) + std::max<int64_t>(kAppHeadroomBytes, int64_t(kAppHeadroomSeconds * bps));
    XCTAssertEqual(plan.minimumFreeBytes, hd.reserveBytes + plan.pinBudget + plan.minAhead + plan.inflightAllowance + app);
}

- (void)testFullModeLeavesRoomForTheAppCopy {
    BudgetInput input;
    input.fileSize = 13 * kGB;
    input.pieceLength = 8 * kMiB;
    input.durationSeconds = 130 * 60;
    input.freeBytes = 13 * kGB + kDefaultReserveBytes;
    XCTAssertTrue(planBudget(input).decision == StorageDecision::Full);
    // The app keeps 400 s of HLS next to the whole file: that no longer fits.
    input.appWorkingSetSeconds = 400;
    BudgetPlan const tight = planBudget(input);
    XCTAssertTrue(tight.decision == StorageDecision::Bounded);
    int64_t const appBytes = int64_t(400 * tight.bytesPerSecond);
    input.freeBytes = 13 * kGB + kDefaultReserveBytes + appBytes;
    BudgetPlan const roomy = planBudget(input);
    XCTAssertTrue(roomy.decision == StorageDecision::Full);
    XCTAssertEqual(roomy.minimumFreeBytes, 13 * kGB + appBytes);
    // Not allowed to be bounded: the legacy check, unchanged.
    input.allowBounded = false;
    input.freeBytes = 13 * kGB;
    XCTAssertTrue(planBudget(input).decision == StorageDecision::Full);
}

- (void)testPendingExternalBytesAreNotFree {
    BudgetInput input;
    input.fileSize = 4 * kGiB;
    input.pieceLength = 4 * kMiB;
    input.freeBytes = 4 * kGiB + kDefaultReserveBytes;
    XCTAssertTrue(planBudget(input).decision == StorageDecision::Full);
    // An offline download will still write 1.5 GiB: bounded, with less room.
    input.pendingExternalBytes = 3 * kGiB / 2;
    BudgetPlan const plan = planBudget(input);
    XCTAssertTrue(plan.decision == StorageDecision::Bounded);
    XCTAssertLessThanOrEqual(plan.torrentBudget, input.freeBytes - input.pendingExternalBytes - input.reserveBytes);
    // So much pending that even the minimum does not fit.
    input.pendingExternalBytes = 4 * kGiB;
    XCTAssertTrue(planBudget(input).decision == StorageDecision::Refuse);
}

- (void)testRequestedBudgetIsClamped {
    BudgetInput input;
    input.fileSize = 13 * kGB;
    input.pieceLength = 8 * kMiB;
    input.freeBytes = 2800 * kMiB;
    input.requestedBudget = 100 * kMiB;
    BudgetPlan plan = planBudget(input);
    XCTAssertEqual(plan.torrentBudget, plan.pinBudget + plan.minAhead + plan.inflightAllowance);
    input.requestedBudget = 10 * kGiB;
    plan = planBudget(input);
    XCTAssertEqual(plan.torrentBudget, input.freeBytes - input.reserveBytes);
}

- (void)testDataAlreadyOnDiskCounts {
    BudgetInput input;
    input.fileSize = 4 * kGiB;
    input.pieceLength = 4 * kMiB;
    input.freeBytes = 2 * kGiB;
    XCTAssertTrue(planBudget(input).decision == StorageDecision::Bounded);
    input.heldBytes = 3 * kGiB; // allocated bytes of an existing file
    XCTAssertTrue(planBudget(input).decision == StorageDecision::Full);
}

- (void)testLegacyCheckWhenBoundedStorageIsNotAllowed {
    BudgetInput input;
    input.allowBounded = false;
    input.fileSize = 13 * kGB;
    input.pieceLength = 8 * kMiB;
    input.freeBytes = 2800 * kMiB;
    XCTAssertTrue(planBudget(input).decision == StorageDecision::Refuse);
    input.freeBytes = 13 * kGB; // the old check had no reserve
    XCTAssertTrue(planBudget(input).decision == StorageDecision::Full);
    input.freeBytes = 1 * kGB;
    input.existingLogicalBytes = 12 * kGB + 1; // the old check used the logical size
    XCTAssertTrue(planBudget(input).decision == StorageDecision::Full);
}

- (void)testAheadBudgetGivesWayToDataKeptBehind {
    BudgetPlan plan;
    plan.torrentBudget = 1 * kGiB;
    plan.minAhead = 256 * kMiB;
    plan.inflightAllowance = 32 * kMiB;
    XCTAssertEqual(aheadBudget(plan, 4 * kMiB, 64 * kMiB, 128 * kMiB, 1.0), 1 * kGiB - 224 * kMiB);
    XCTAssertEqual(aheadBudget(plan, 4 * kMiB, 64 * kMiB, 900 * kMiB, 1.0), 256 * kMiB);
    XCTAssertEqual(aheadBudget(plan, 4 * kMiB, 64 * kMiB, 900 * kMiB, 0.5), 128 * kMiB);
}

#pragma mark - Window planner

- (void)testBoundedPlanFreesConsumedPiecesAndKeepsPins {
    FileGeometry const geo = geometry(0, 100 * kMiB, kMiB);
    std::vector<uint8_t> states(100, PieceMissing);
    for (int i = 0; i <= 60; ++i) states[size_t(i)] = PieceOnDisk;
    states[45] = PieceMissing; // gap behind the reader (skipped by a seek)

    PlanInput input;
    input.geometry = geo;
    input.bounded = true;
    input.readPosition = 50 * kMiB + 10;
    input.consumedBefore = 40 * kMiB;
    input.pins.headEnd = 4 * kMiB;
    input.pins.tailStart = 98 * kMiB;
    input.deadlinePieces = 16;
    input.deadlineFirstMs = 100;
    input.deadlineStepMs = 50;
    input.states = &states;
    PlanOutput const plan = planWindow(input);

    XCTAssertEqual(plan.readPiece, 50);
    XCTAssertEqual(plan.windowEndPiece, 66);
    // Pieces 4..38 are entirely below 40 MiB minus the one-piece guard.
    XCTAssertEqual(plan.toFree.size(), size_t(35));
    XCTAssertEqual(plan.toFree.front(), 4);
    XCTAssertEqual(plan.toFree.back(), 38);
    for (int i = 0; i < 4; ++i) XCTAssertEqual(plan.priorities[size_t(i)], 7); // head pin
    for (int i = 4; i <= 38; ++i) XCTAssertEqual(plan.priorities[size_t(i)], 0);
    XCTAssertEqual(plan.priorities[39], 1);
    XCTAssertEqual(plan.priorities[45], 0); // gap behind the reader is not fetched
    XCTAssertEqual(plan.priorities[60], 1);
    XCTAssertEqual(plan.priorities[61], 7);
    XCTAssertEqual(plan.priorities[65], 7);
    XCTAssertEqual(plan.priorities[66], 1); // beyond the window: wanted, paced
    XCTAssertEqual(plan.priorities[98], 7);
    XCTAssertEqual(plan.priorities[99], 7);
    XCTAssertEqual(plan.lowestAvailableOffset, 39 * kMiB);
    XCTAssertEqual(plan.aheadBytes, 11 * kMiB);   // 50..60
    XCTAssertEqual(plan.behindBytes, 10 * kMiB);  // 39..49 without 45
    XCTAssertEqual(plan.pinnedBytes, 4 * kMiB);
    // Deadlines: 61..65 staggered by their distance to the reader, then the missing tail pins.
    XCTAssertEqual(plan.deadlines.size(), size_t(7));
    XCTAssertEqual(plan.deadlines[0].first, 61);
    XCTAssertEqual(plan.deadlines[0].second, 100 + 11 * 50);
    XCTAssertEqual(plan.deadlines[5].first, 98);
}

- (void)testFreedPiecesStayUnwanted {
    FileGeometry const geo = geometry(0, 20 * kMiB, kMiB);
    std::vector<uint8_t> states(20, PieceOnDisk);
    for (int i = 2; i < 8; ++i) states[size_t(i)] = PieceFreed;
    PlanInput input;
    input.geometry = geo;
    input.bounded = true;
    input.readPosition = 0; // a reader asking for freed data does not bring it back
    input.pins.headEnd = 2 * kMiB;
    input.states = &states;
    PlanOutput const plan = planWindow(input);
    for (int i = 2; i < 8; ++i) XCTAssertEqual(plan.priorities[size_t(i)], 0);
    XCTAssertEqual(plan.lowestAvailableOffset, 8 * kMiB);
    XCTAssertTrue(plan.toFree.empty());
}

- (void)testPiecesReadersWaitForAreFetchedFirst {
    FileGeometry const geo = geometry(0, 100 * kMiB, kMiB);
    std::vector<uint8_t> states(100, PieceMissing);
    for (int i = 0; i <= 60; ++i) states[size_t(i)] = PieceOnDisk;
    states[20] = PieceFreed;
    states[45] = PieceMissing;
    PlanInput input;
    input.geometry = geo;
    input.bounded = true;
    input.readPosition = 50 * kMiB;
    input.consumedBefore = 30 * kMiB;
    input.pins.headEnd = 2 * kMiB;
    input.deadlinePieces = 4;
    input.deadlineFirstMs = 100;
    input.deadlineStepMs = 50;
    input.states = &states;
    // A gap behind the reader, a piece far ahead, a freed piece and a consumed one.
    input.urgentPieces = {45, 90, 20, 10};
    states[10] = PieceMissing;
    PlanOutput const plan = planWindow(input);
    XCTAssertEqual(plan.priorities[45], 7);
    XCTAssertEqual(plan.priorities[90], 7);
    XCTAssertEqual(plan.priorities[20], 0);
    XCTAssertEqual(plan.priorities[10], 0);
    int found = 0;
    for (auto const& d : plan.deadlines) {
        if (d.first == 45 || d.first == 90) { ++found; XCTAssertEqual(d.second, 100); }
        XCTAssertNotEqual(d.first, 20);
        XCTAssertNotEqual(d.first, 10);
    }
    XCTAssertEqual(found, 2);
}

- (void)testLatePiecesCapTheRestOfTheFile {
    FileGeometry const geo = geometry(0, 100 * kMiB, kMiB);
    std::vector<uint8_t> states(100, PieceMissing);
    for (int i = 20; i < 40; ++i) states[size_t(i)] = PieceOnDisk; // arrived before the window
    PlanInput input;
    input.geometry = geo;
    input.bounded = true;
    input.readPosition = 0;
    input.pins.headEnd = 1 * kMiB;
    input.pins.tailStart = 99 * kMiB;
    input.deadlinePieces = 4;
    input.aheadLimitPieces = 30;
    input.states = &states;
    PlanOutput plan = planWindow(input);
    XCTAssertTrue(plan.urgent);
    XCTAssertEqual(plan.priorities[2], 7);   // window
    XCTAssertEqual(plan.priorities[10], 1);  // within the ahead budget
    XCTAssertEqual(plan.priorities[30], 1);  // on disk: unchanged
    XCTAssertEqual(plan.priorities[45], 0);  // beyond it: not wanted while the window is late
    XCTAssertEqual(plan.priorities[99], 7);  // pinned tail
    // One missing piece beyond the cap stays wanted, so the late piece is never the last
    // wanted one (libtorrent would mark the torrent finished and drop its seeds).
    XCTAssertEqual(plan.capSentinel, 40);
    XCTAssertEqual(plan.priorities[40], 1);
    XCTAssertEqual(plan.priorities[41], 0);
    // The same sentinel for the whole late episode...
    input.capSentinel = plan.capSentinel;
    plan = planWindow(input);
    XCTAssertEqual(plan.capSentinel, 40);
    XCTAssertEqual(plan.priorities[40], 1);
    // ... and once it arrived, no other one: at most one extra piece per episode.
    states[40] = PieceOnDisk;
    input.capSentinel = plan.capSentinel;
    plan = planWindow(input);
    XCTAssertEqual(plan.capSentinel, 40);
    XCTAssertEqual(plan.priorities[41], 0);
    // Window on disk: everything ahead is wanted again (paced instead).
    for (int i = 0; i < 4; ++i) states[size_t(i)] = PieceOnDisk;
    states[99] = PieceOnDisk;
    input.capSentinel = plan.capSentinel;
    plan = planWindow(input);
    XCTAssertFalse(plan.urgent);
    XCTAssertEqual(plan.priorities[45], 1);
    XCTAssertEqual(plan.capSentinel, -1);
    // Full mode is never capped.
    input.bounded = false;
    states[2] = PieceMissing;
    plan = planWindow(input);
    XCTAssertEqual(plan.priorities[45], 1);
}

- (void)testUnboundedPlanKeepsTheWholeFileWanted {
    FileGeometry const geo = geometry(0, 100 * kMiB, kMiB);
    std::vector<uint8_t> states(100, PieceMissing);
    for (int i = 0; i <= 60; ++i) states[size_t(i)] = PieceOnDisk;
    states[30] = PieceMissing;
    PlanInput input;
    input.geometry = geo;
    input.bounded = false;
    input.readPosition = 50 * kMiB;
    input.consumedBefore = 40 * kMiB; // ignored in full mode
    input.pins.tailStart = 99 * kMiB;
    input.deadlinePieces = 3;
    input.deadlineFirstMs = 100;
    input.states = &states;
    PlanOutput const plan = planWindow(input);
    XCTAssertTrue(plan.toFree.empty());
    XCTAssertEqual(plan.lowestAvailableOffset, 0);
    for (int i = 0; i < 100; ++i) XCTAssertGreaterThanOrEqual(plan.priorities[size_t(i)], 1);
    // The window slides over the pieces already there, like the old chained windows.
    XCTAssertEqual(plan.deadlines.size(), size_t(4));
    XCTAssertEqual(plan.deadlines[0].first, 61);
    XCTAssertEqual(plan.deadlines[2].first, 63);
    XCTAssertEqual(plan.deadlines[2].second, 100);
    XCTAssertEqual(plan.deadlines[3].first, 99); // missing tail pin
    XCTAssertEqual(plan.windowEndPiece, 64);
}

- (void)testPiecesToDropAreFarAheadAndNeverPinned {
    FileGeometry const geo = geometry(0, 100 * kMiB, kMiB);
    std::vector<uint8_t> states(100, PieceOnDisk);
    states[12] = PieceMissing; // the window is still being downloaded
    PlanInput input;
    input.geometry = geo;
    input.bounded = true;
    input.readPosition = 10 * kMiB;
    input.pins.headEnd = 4 * kMiB;
    input.pins.tailStart = 98 * kMiB;
    input.deadlinePieces = 8;
    input.states = &states;
    PlanOutput const plan = planWindow(input);
    std::vector<int32_t> const drop = piecesToDrop(input, plan, 3 * kMiB);
    XCTAssertEqual(drop.size(), size_t(3));
    XCTAssertEqual(drop[0], 97);
    XCTAssertEqual(drop[2], 95);
    std::vector<int32_t> const all = piecesToDrop(input, plan, 1000 * kMiB);
    XCTAssertEqual(all.back(), plan.windowEndPiece);
}

- (void)testNothingIsDroppedOnceTheRestOfTheFileIsOnDisk {
    FileGeometry const geo = geometry(0, 100 * kMiB, kMiB);
    std::vector<uint8_t> states(100, PieceFreed);
    for (int i = 0; i < 4; ++i) states[size_t(i)] = PieceOnDisk;   // head pin
    for (int i = 60; i < 100; ++i) states[size_t(i)] = PieceOnDisk; // reader to the end
    PlanInput input;
    input.geometry = geo;
    input.bounded = true;
    input.readPosition = 61 * kMiB;
    input.consumedBefore = 59 * kMiB;
    input.pins.headEnd = 4 * kMiB;
    input.pins.tailStart = 98 * kMiB;
    input.deadlinePieces = 8;
    input.states = &states;
    PlanOutput const plan = planWindow(input);
    XCTAssertTrue(onDiskToTheEnd(geo, states, plan.readPiece));
    // Disk full, or over the budget: the rest of the file is final, nothing goes.
    XCTAssertTrue(piecesToDrop(input, plan, 20 * kMiB).empty());
    // One piece ahead still missing: the farthest data ahead can go again.
    states[80] = PieceMissing;
    PlanOutput const missing = planWindow(input);
    XCTAssertFalse(onDiskToTheEnd(geo, states, missing.readPiece));
    std::vector<int32_t> const drop = piecesToDrop(input, missing, 2 * kMiB);
    XCTAssertEqual(drop.size(), size_t(2));
    XCTAssertEqual(drop[0], 97);
}

- (void)testConsumedPiecesStillBeingVerifiedAreFreedLater {
    FileGeometry const geo = geometry(0, 20 * kMiB, kMiB);
    std::vector<uint8_t> states(20, PieceOnDisk);
    states[5] = PieceVerifying; // passed the hash check, write not confirmed yet
    PlanInput input;
    input.geometry = geo;
    input.bounded = true;
    input.readPosition = 12 * kMiB;
    input.consumedBefore = 10 * kMiB;
    input.pins.headEnd = 1 * kMiB;
    input.states = &states;
    PlanOutput const plan = planWindow(input);
    XCTAssertEqual(plan.toFree.size(), size_t(7)); // 1..8 without 5
    XCTAssertTrue(std::find(plan.toFree.begin(), plan.toFree.end(), 5) == plan.toFree.end());
    XCTAssertEqual(plan.priorities[5], 0);
    XCTAssertEqual(plan.lowestAvailableOffset, 9 * kMiB);
}

- (void)testConsumedGapsAreGone {
    FileGeometry const geo = geometry(0, 100 * kMiB, kMiB);
    PinSet pins;
    pins.headEnd = 4 * kMiB;
    pins.tailStart = 98 * kMiB;
    int64_t const consumed = 50 * kMiB; // pieces 0..48 are consumed (one guard piece)
    XCTAssertTrue(isGone(geo, pins, PieceFreed, 20, consumed));
    XCTAssertTrue(isGone(geo, pins, PieceMissing, 20, consumed));   // skipped by a seek
    XCTAssertTrue(isGone(geo, pins, PieceDropping, 20, consumed));
    XCTAssertFalse(isGone(geo, pins, PieceOnDisk, 20, consumed));   // readable until freed
    XCTAssertFalse(isGone(geo, pins, PieceVerifying, 20, consumed));
    XCTAssertFalse(isGone(geo, pins, PieceMissing, 2, consumed));   // pinned head
    XCTAssertFalse(isGone(geo, pins, PieceMissing, 49, consumed));  // guard piece
    XCTAssertFalse(isGone(geo, pins, PieceMissing, 60, consumed));  // ahead
}

- (void)testTailPinIsByteSized {
    // Pieces of 4 MiB and more: the 1 or 2 pieces of before cover the 8 MiB already.
    XCTAssertEqual(tailPinPieces(geometry(0, 13 * kGB, 16 * kMiB), 2), 2);
    XCTAssertEqual(tailPinPieces(geometry(0, 13 * kGB, 4 * kMiB), 2), 2);
    XCTAssertEqual(tailPinPieces(geometry(0, 13 * kGB, 8 * kMiB), 1), 1);
    // Small pieces: enough whole pieces for 8 MiB (MKV Cues, an MP4 moov at the end)...
    XCTAssertEqual(tailPinPieces(geometry(0, 2 * kGB, 2 * kMiB), 2), 4);
    XCTAssertEqual(tailPinPieces(geometry(0, 2 * kGB, 1 * kMiB), 1), 8);
    // ... at most 10 of them, and never more than the file has.
    XCTAssertEqual(tailPinPieces(geometry(0, 2 * kGB, 256 * kKiB), 2), kTailPinMaxPieces);
    XCTAssertEqual(tailPinPieces(geometry(0, 3 * kMiB, 1 * kMiB), 2), 3);
    // A file inside a multi-file torrent counts its own pieces.
    XCTAssertEqual(tailPinPieces(geometry(5 * kMiB + 7, 3 * kMiB, 1 * kMiB), 1), 4);
    // The bounded budget pins what the streamer pins.
    BudgetInput input;
    input.fileSize = 13 * kGB;
    input.pieceLength = 1 * kMiB;
    input.freeBytes = 3 * kGB;
    BudgetPlan const plan = planBudget(input);
    XCTAssertEqual(plan.decision, StorageDecision::Bounded);
    XCTAssertEqual(plan.pinBudget, kHeadPinLimit + 8 * kMiB);
}

- (void)testFullModeWaitsOnlyForTheLastTailPieces {
    // 1 MiB pieces: 8 tail pieces pinned, the stream waits for the last 2 (as before).
    FileGeometry const geo = geometry(0, 100 * kMiB, kMiB);
    std::vector<uint8_t> states(100, PieceMissing);
    for (int i = 0; i < 5; ++i) states[size_t(i)] = PieceOnDisk;
    PlanInput input;
    input.geometry = geo;
    input.readPosition = 0;
    input.pins.tailStart = 92 * kMiB;
    input.urgentTailStart = 98 * kMiB;
    input.deadlinePieces = 4;
    input.deadlineFirstMs = 100;
    input.states = &states;
    PlanOutput const plan = planWindow(input);
    for (int i = 92; i < 100; ++i) XCTAssertEqual(plan.priorities[size_t(i)], 7);
    std::vector<int32_t> deadlinePieces;
    for (auto const& d : plan.deadlines) deadlinePieces.push_back(d.first);
    XCTAssertEqual(deadlinePieces, (std::vector<int32_t>{5, 6, 7, 8, 98, 99}));
    // Without the split every missing pin is time-critical.
    input.urgentTailStart = -1;
    XCTAssertEqual(planWindow(input).deadlines.size(), size_t(4 + 8));
}

- (void)testLowestAvailableOffsetFollowsTheConsumerAtOnce {
    FileGeometry const geo = geometry(0, 100 * kMiB, kMiB);
    PinSet pins;
    pins.headEnd = 4 * kMiB;
    pins.tailStart = 98 * kMiB;
    XCTAssertEqual(consumedFloor(geo, pins, 0), 0);
    XCTAssertEqual(consumedFloor(geo, pins, 5 * kMiB), 0);          // only the head pin and the guard
    XCTAssertEqual(consumedFloor(geo, pins, 6 * kMiB), 5 * kMiB);   // piece 4 is consumed
    XCTAssertEqual(consumedFloor(geo, pins, 40 * kMiB), 39 * kMiB); // what planWindow reports
    XCTAssertEqual(consumedFloor(geo, pins, 40 * kMiB + 1), 39 * kMiB);
    // The pinned tail is never consumed.
    XCTAssertEqual(consumedFloor(geo, pins, 100 * kMiB), 98 * kMiB);
    std::vector<uint8_t> states(100, PieceOnDisk);
    PlanInput input;
    input.geometry = geo;
    input.bounded = true;
    input.readPosition = 50 * kMiB;
    input.consumedBefore = 40 * kMiB;
    input.pins = pins;
    input.states = &states;
    XCTAssertEqual(planWindow(input).lowestAvailableOffset, consumedFloor(geo, pins, 40 * kMiB));
}

- (void)testContiguousAvailableStartForRewinds {
    FileGeometry const geo = geometry(0, 100 * kMiB, kMiB);
    PinSet pins;
    pins.headEnd = 4 * kMiB;
    pins.tailStart = 98 * kMiB;
    std::vector<uint8_t> states(100, PieceMissing);
    for (int i = 0; i < 4; ++i) states[size_t(i)] = PieceOnDisk;    // head pin
    for (int i = 4; i < 20; ++i) states[size_t(i)] = PieceFreed;
    for (int i = 20; i <= 60; ++i) states[size_t(i)] = PieceOnDisk;
    states[45] = PieceMissing;                                      // gap left by a forward seek
    states[30] = PieceVerifying;                                    // passed, not confirmed written
    int64_t const consumed = 25 * kMiB;                             // pieces 20..23 consumed, not freed yet
    // From the reader at 58.5 MiB back to the gap: 46..58 are on disk.
    XCTAssertEqual(contiguousAvailableStart(geo, states, pins, true, consumed, 58 * kMiB + kMiB / 2), 46 * kMiB);
    // Below the gap: back to the piece being verified.
    XCTAssertEqual(contiguousAvailableStart(geo, states, pins, true, consumed, 44 * kMiB), 31 * kMiB);
    // Consumed pieces still on disk do not count (they are deleted within a second)...
    XCTAssertEqual(contiguousAvailableStart(geo, states, pins, true, consumed, 30 * kMiB), 24 * kMiB);
    // ... in full mode they do.
    XCTAssertEqual(contiguousAvailableStart(geo, states, pins, false, consumed, 30 * kMiB), 20 * kMiB);
    // The pinned head is always readable.
    XCTAssertEqual(contiguousAvailableStart(geo, states, pins, true, consumed, 3 * kMiB + 5), 0);
    // A byte whose predecessor is missing: nothing before it.
    XCTAssertEqual(contiguousAvailableStart(geo, states, pins, true, consumed, 46 * kMiB), 46 * kMiB);
    XCTAssertEqual(contiguousAvailableStart(geo, states, pins, true, consumed, 0), 0);
    // Clamped to the file.
    XCTAssertEqual(contiguousAvailableStart(geo, states, pins, true, consumed, 200 * kMiB), 100 * kMiB);
}

- (void)testSeeksAreNotConsumption {
    FileGeometry const geo = geometry(0, 100 * kMiB, kMiB);
    std::vector<uint8_t> states(100, PieceMissing);
    for (int i = 0; i <= 10; ++i) states[size_t(i)] = PieceOnDisk;
    for (int i = 20; i <= 30; ++i) states[size_t(i)] = PieceOnDisk;
    states[3] = PieceFreed;   // read, then released
    states[4] = PieceDropping;
    int64_t const noCap = 1 * kGiB;
    XCTAssertEqual(consumedBetween(geo, states, 0, 8 * kMiB, noCap), 8 * kMiB);
    XCTAssertEqual(consumedBetween(geo, states, 2 * kMiB, 11 * kMiB, noCap), 9 * kMiB);
    // A forward seek over pieces that were never on disk.
    XCTAssertEqual(consumedBetween(geo, states, 8 * kMiB, 25 * kMiB, noCap), 0);
    XCTAssertEqual(consumedBetween(geo, states, 8 * kMiB, 8 * kMiB, noCap), 0);
    XCTAssertEqual(consumedBetween(geo, states, 25 * kMiB, 8 * kMiB, noCap), 0); // rewind
    // A jump inside data that is on disk only counts up to the cap.
    XCTAssertEqual(consumedBetween(geo, states, 20 * kMiB, 30 * kMiB, 4 * kMiB), 4 * kMiB);
}

- (void)testExcessAheadKeepsDiskFlatDuringALongPause {
    PaceInput input;
    input.aheadBudget = 100 * kMiB;
    input.freeBytes = 2 * kGiB;
    input.reserveBytes = 512 * kMiB;
    input.aheadBytes = 110 * kMiB; // within the floor band (12.5 %)
    XCTAssertEqual(excessAheadBytes(input, 4 * kMiB), 0);
    input.aheadBytes = 120 * kMiB; // past it: back down to the budget
    XCTAssertEqual(excessAheadBytes(input, 4 * kMiB), 20 * kMiB);
    input.aheadBytes = 104 * kMiB; // small budgets: the band is at least one piece
    input.aheadBudget = 8 * kMiB;
    XCTAssertEqual(excessAheadBytes(input, 16 * kMiB), 96 * kMiB);
    input.aheadBudget = 100 * kMiB;
    input.aheadBytes = 50 * kMiB;
    input.freeBytes = 400 * kMiB; // below the reserve
    XCTAssertEqual(excessAheadBytes(input, 4 * kMiB), 112 * kMiB);
    input.urgent = true;          // the reader waits: never
    XCTAssertEqual(excessAheadBytes(input, 4 * kMiB), 0);
}

#pragma mark - Pace controller

- (void)testPaceNeverPausesAndFollowsTheFill {
    PaceInput input;
    input.aheadBudget = 100 * kMiB;
    input.consumeRate = 10e6;
    input.freeBytes = 2 * kGiB;
    input.reserveBytes = 512 * kMiB;

    input.aheadBytes = 50 * kMiB;
    XCTAssertTrue(pace(input).state == PaceState::Open);
    XCTAssertEqual(pace(input).downloadLimit, 0);

    input.aheadBytes = 80 * kMiB; // fill 0.8: 1.8 x the consumption rate
    PaceOutput out = pace(input);
    XCTAssertTrue(out.state == PaceState::Proportional);
    XCTAssertEqualWithAccuracy(out.downloadLimit, 18e6, 1e3);

    input.consumeRate = 0; // paused reader
    XCTAssertEqual(pace(input).downloadLimit, input.floorRate);

    input.aheadBytes = 100 * kMiB;
    out = pace(input);
    XCTAssertTrue(out.state == PaceState::Floor);
    XCTAssertEqual(out.downloadLimit, 64 * 1024);

    input.aheadBytes = 120 * kMiB;
    out = pace(input);
    XCTAssertTrue(out.state == PaceState::Trickle);
    XCTAssertGreaterThan(out.downloadLimit, 0); // a limit of 0 would mean unlimited

    input.urgent = true; // the reader waits for a piece: not throttled
    out = pace(input);
    XCTAssertTrue(out.state == PaceState::Open);
    XCTAssertEqual(out.downloadLimit, 0);
    input.freeBytes = 200 * kMiB; // ... unless the disk is below half the reserve
    out = pace(input);
    XCTAssertTrue(out.state == PaceState::Emergency);
    XCTAssertEqual(out.downloadLimit, input.floorRate);
    input.freeBytes = 2 * kGiB;
    input.urgent = false;

    input.aheadBytes = 10 * kMiB;
    input.freeBytes = 100 * kMiB;
    out = pace(input);
    XCTAssertTrue(out.state == PaceState::Emergency);
    XCTAssertGreaterThan(out.downloadLimit, 0);
}

#pragma mark - Container head parser

- (void)testMatroskaHeadPinCoversTheFirstClustersAPlayerReads {
    std::vector<uint8_t> mkv;
    appendBytes(mkv, {0x1A, 0x45, 0xDF, 0xA3, 0x80 | 0x10}); // EBML header, 16 bytes
    appendFill(mkv, 0x10);
    appendBytes(mkv, {0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}); // Segment, unknown size
    appendBytes(mkv, {0x11, 0x4D, 0x9B, 0x74, 0x40, 0x20}); // SeekHead, 32 bytes
    appendFill(mkv, 32);
    appendBytes(mkv, {0x15, 0x49, 0xA9, 0x66, 0x88}); // Info, 8 bytes
    appendFill(mkv, 8);
    appendBytes(mkv, {0x16, 0x54, 0xAE, 0x6B, 0x10, 0x00, 0x10, 0x00}); // Tracks, 4096 bytes
    appendFill(mkv, 4096);
    appendBytes(mkv, {0xEC, 0x82}); // Void, 2 bytes
    appendFill(mkv, 2);
    int64_t const cluster = int64_t(mkv.size());
    appendBytes(mkv, {0x1F, 0x43, 0xB6, 0x75, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF});
    appendFill(mkv, 1000);
    int64_t const fileSize = 1 * kGiB;

    // Past the first Cluster: what a player reads at open before its first seek (VLC's
    // prefetch and first clusters), kMatroskaHeadPinBytes.
    HeadPins result = parseHeadPins(memoryReader(mkv, int64_t(mkv.size())), fileSize);
    XCTAssertEqual(result.status, HeadPins::Done);
    XCTAssertEqual(result.headPinEnd, kMatroskaHeadPinBytes);
    XCTAssertGreaterThan(result.headPinEnd, cluster);
    XCTAssertEqual(result.tailPinStart, -1);
    XCTAssertEqual(std::string(result.format), std::string("mkv"));

    // Only the first 90 bytes on disk: the parser asks for the Tracks header.
    result = parseHeadPins(memoryReader(mkv, 90), fileSize);
    XCTAssertEqual(result.status, HeadPins::NeedMore);
    XCTAssertEqual(result.needOffset, 16 + 5 + 12 + 6 + 32 + 5 + 8);

    // Clusters beyond the head limit: the pin is capped.
    result = parseHeadPins(memoryReader(mkv, int64_t(mkv.size())), fileSize, 2048, kHeadPinFallback);
    XCTAssertEqual(result.status, HeadPins::Done);
    XCTAssertEqual(result.headPinEnd, 2048);

    // A first Cluster past the opening reads but within the limit: up to it.
    result = parseHeadPins(memoryReader(mkv, int64_t(mkv.size())), fileSize, 1 * kGiB, kHeadPinFallback);
    XCTAssertEqual(result.headPinEnd, kMatroskaHeadPinBytes);
    // A file smaller than the opening reads: all of it.
    result = parseHeadPins(memoryReader(mkv, int64_t(mkv.size())), 10 * kMiB);
    XCTAssertEqual(result.headPinEnd, 10 * kMiB);
}

- (void)testMP4HeadAndTailPins {
    std::vector<uint8_t> front;
    appendBE32(front, 24); front.insert(front.end(), {'f', 't', 'y', 'p'}); appendFill(front, 16);
    appendBE32(front, 1000); front.insert(front.end(), {'m', 'o', 'o', 'v'}); appendFill(front, 992);
    appendBE32(front, 0); front.insert(front.end(), {'m', 'd', 'a', 't'}); appendFill(front, 64);
    HeadPins result = parseHeadPins(memoryReader(front, int64_t(front.size())), 1 * kGiB);
    XCTAssertEqual(result.status, HeadPins::Done);
    XCTAssertEqual(result.headPinEnd, 1024);
    XCTAssertEqual(result.tailPinStart, -1);

    // moov after a 64-bit mdat: pinned with the tail.
    int64_t const mdatSize = 100000;
    std::vector<uint8_t> back;
    appendBE32(back, 24); back.insert(back.end(), {'f', 't', 'y', 'p'}); appendFill(back, 16);
    appendBE32(back, 1); back.insert(back.end(), {'m', 'd', 'a', 't'});
    appendBE32(back, 0); appendBE32(back, uint32_t(mdatSize));
    appendFill(back, size_t(mdatSize - 16));
    appendBE32(back, 2000); back.insert(back.end(), {'m', 'o', 'o', 'v'}); appendFill(back, 1992);
    int64_t const fileSize = int64_t(back.size());
    result = parseHeadPins(memoryReader(back, fileSize), fileSize);
    XCTAssertEqual(result.status, HeadPins::Done);
    XCTAssertEqual(result.headPinEnd, 40);
    XCTAssertEqual(result.tailPinStart, 24 + mdatSize);
    // The moov box header is not on disk yet.
    result = parseHeadPins(memoryReader(back, 4096), fileSize);
    XCTAssertEqual(result.status, HeadPins::NeedMore);
    XCTAssertEqual(result.needOffset, 24 + mdatSize);
}

- (void)testUnknownContainerGetsTheFallbackPin {
    std::vector<uint8_t> avi;
    avi.insert(avi.end(), {'R', 'I', 'F', 'F'});
    appendBE32(avi, 1234);
    avi.insert(avi.end(), {'A', 'V', 'I', ' '});
    appendFill(avi, 100);
    HeadPins const result = parseHeadPins(memoryReader(avi, int64_t(avi.size())), 1 * kGiB);
    XCTAssertEqual(result.status, HeadPins::Done);
    XCTAssertEqual(result.headPinEnd, kHeadPinFallback);
}

#pragma mark - Start starvation (the volume stays too full before the stream is ready)

- (void)testDiskStarvedBelowHalfTheReserveOrInUploadMode {
    int64_t const reserve = 512 * kMiB;
    XCTAssertFalse(isDiskStarved(2 * kGiB, reserve, false));
    XCTAssertFalse(isDiskStarved(reserve / 2, reserve, false));  // exactly half: still downloading
    XCTAssertTrue(isDiskStarved(reserve / 2 - 1, reserve, false));
    XCTAssertTrue(isDiskStarved(0, reserve, false));
    XCTAssertTrue(isDiskStarved(2 * kGiB, reserve, true));       // libtorrent's ENOSPC reaction
    XCTAssertFalse(isDiskStarved(INT64_MAX, reserve, false));     // free space unknown
}

- (void)testStartStarvationFailsOnlyAStreamThatIsNotReady {
    XCTAssertFalse(startStarvationExpired(false, 0));
    XCTAssertFalse(startStarvationExpired(false, kStartStarvationSeconds - 0.5));
    XCTAssertTrue(startStarvationExpired(false, kStartStarvationSeconds));
    XCTAssertTrue(startStarvationExpired(false, 600));
    XCTAssertFalse(startStarvationExpired(true, 600));             // a ready stream waits for space
    XCTAssertLessThanOrEqual(kStartStarvationSeconds, 60);         // bounded: no endless loading
}

- (void)testBytesToFreeAfterStarvationCountsTheStreamsOwnFile {
    int64_t const minimum = 1300 * kMiB;
    // Another app filled the volume: what is missing beyond this stream's own data.
    XCTAssertEqual(bytesToFreeAfterStarvation(minimum, 20 * kMiB, 100 * kMiB), minimum - 120 * kMiB);
    // The stream's own file holds the space (an allocation runaway): nothing to free.
    XCTAssertEqual(bytesToFreeAfterStarvation(minimum, 20 * kMiB, 2800 * kMiB), 0);
    XCTAssertEqual(bytesToFreeAfterStarvation(minimum, INT64_MAX, 0), minimum);
    XCTAssertEqual(bytesToFreeAfterStarvation(minimum, -5, -5), minimum);
}

- (void)testReclaimStepsStaySmallEnoughForAFullVolume {
    // One F_PUNCHHOLE over gigabytes of zero-filled blocks fails with ENOSPC on a full APFS volume.
    XCTAssertLessThanOrEqual(kReclaimStepBytes, 64 * kMiB);
    XCTAssertLessThan(kReclaimSmallStepBytes, kReclaimStepBytes);
    XCTAssertEqual(kReclaimStepBytes % 4096, 0);
    XCTAssertEqual(kReclaimSmallStepBytes % 4096, 0);
}

@end
