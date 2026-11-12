# Bounded storage

Streaming a file larger than the free space: a 13 GB film on an Apple TV with
about 3 GB free. Only a window of the selected file is kept on disk; the pieces
the consumer is done with are deleted (APFS holes) and never served again.

## When it switches on

At metadata time (`metadataReceivedAlert`), `planBudget` (`Sources/Bounded/PTBoundedLogic.cpp`) decides:

| Situation | Mode |
|---|---|
| selected file (minus what is already allocated on disk) + `storageReserve` + `appWorkingSetSeconds` of the bitrate ≤ free space | **Full**: legacy behaviour, the whole file is downloaded and kept |
| otherwise, free space ≥ minimum working set | **Bounded** |
| otherwise | **Refused**: error `PTTorrentStreamerErrorNotEnoughSpaceForBoundedStorage` (-5), localized message with the space to clear |
| `allowsBoundedStorage == NO` (the default; always for `PTTorrentDownload`), or a volume without holes (not APFS: `pathconf(_PC_MIN_HOLE_SIZE)`), or one where the hole self-test fails (below) | legacy check, unchanged: refused with -4 when the file does not fit |

**Hole self-test.** The first time a stream could go bounded on a volume (per process),
`volumeSupportsHolesAtPath:` checks the primitives bounded storage relies on, on a scratch
file in the stream's folder: a 2 MiB file created as a hole with its first MiB written
(`SEEK_HOLE` from 0 must find 1 MiB, `SEEK_DATA` from 1 MiB must fail with ENXIO), then
`F_PUNCHHOLE` of its first 512 KiB (it must succeed, the range must read as zeros, the rest
must be intact and `SEEK_DATA` from 0 must find 512 KiB). No fsync, as the controller does.
One console line: `PopcornTorrent: hole self-test in <folder> (<fs>, _PC_MIN_HOLE_SIZE …,
block …, free … MiB): PASS (SEEK_HOLE …, SEEK_DATA … after the punch, allocated … -> … KiB)`,
or `FAIL, <reason>`: bounded storage is then refused there (-4, as a film that does not fit
always was) instead of serving zeros or never giving space back. A stream alone could not
tell a `SEEK_HOLE` that never reports holes from a correct one (verify-storage F3a).
`+holeSupportReportForDirectory:passed:` runs the same test (the app's debug pre-flight).

Bounded storage is **opt-in**: it only works when the consumer releases what it
read (`setConsumedBefore:`) and, if it does not read through the HTTP server,
reports its position (`setReadPosition:`). A client that does neither would get
a window stuck at the start of the file that fills its budget and stalls, instead
of today's clear refusal.

Free space is `NSURLVolumeAvailableCapacityKey` read on a fresh URL (a reused
`NSURL` caches its values), minus `pendingExternalBytes` (what offline downloads in
progress will still write: their files are sparse, the free space does not show it
yet). The minimum working set is
`reserve + pins (64 MiB + the tail pin) + max(256 MiB, 60 s) + inflight (max(32 MiB, 4 pieces)) + 240 s + max(32 MiB, 20 s)`
of the bitrate (the app's HLS copy: 180 s ahead, 60 s behind, and its headroom: the
segment being written). The bitrate is `fileSize / mediaDurationHint`, or
`fileSize / 2 h` when the duration is unknown. About 1.26 GiB for a 13 GB 2 h 10 film,
2.76 GiB for a 60 GB 4K film at 7 MB/s.

`appWorkingSetSeconds` (default 0) is what the app keeps next to the WHOLE file in
full mode (the PopcornTimeTV remux: 400 s of HLS around the playhead, which no disk
budget deletes): without it a film that fits only by itself streams in full mode and
the sparse download and the HLS copy fill the volume together late in the film
(ENOSPC → -4). With it such a film streams bounded.

## API (PTTorrentStreamer.h)

```objc
@property (atomic, copy, nullable) NSString *downloadDirectoryOverride; // set before starting
@property (atomic) BOOL allowsBoundedStorage;        // default NO: opt-in (always NO for PTTorrentDownload)
@property (atomic) int64_t storageReserve;           // default 512 MiB, never used
@property (atomic) int64_t storageBudget;            // torrent's share; 0 = automatic; any time
@property (atomic) NSTimeInterval mediaDurationHint; // seconds, 0 = unknown
@property (atomic) NSTimeInterval appWorkingSetSeconds; // media the app keeps next to a full file (0)
@property (atomic) int64_t pendingExternalBytes;     // other writers' bytes to come: not free; any time
@property (atomic, readonly) PTStorageMode storageMode;  // Undetermined / Full / Bounded
@property (atomic, readonly, getter=isStorageBounded) BOOL storageBounded;
@property (atomic) int64_t readPosition;             // setReadPosition: next byte the consumer needs
@property (atomic) int64_t consumedBefore;           // setConsumedBefore: bytes below are never read again
@property (atomic, readonly) int64_t lowestAvailableOffset; // block rewinds before it
@property (atomic, readonly) int64_t servedOffset;   // HTTP server's read position
- (int64_t)firstMissingOffsetFrom:(int64_t)fileOffset;
- (BOOL)isRangeAvailable:(int64_t)fileOffset length:(int64_t)length;
- (int64_t)contiguousAvailableOffsetBefore:(int64_t)fileOffset; // rewind floor (see Rewinds)
@property (atomic, readonly, getter=isFileComplete) BOOL fileComplete;
@property (atomic, readonly) int64_t bytesOnDisk;    // st_blocks of the file, fresh
@property (atomic, readonly) NSDictionary<NSString *, NSNumber *> *storageStatistics;
+ (NSString *)holeSupportReportForDirectory:(NSString *)directory passed:(BOOL *)passed; // see When it switches on
@property (atomic, readonly) BOOL hasMetadata;      // the metadata is in, the file chosen (see Loading status)
@property (atomic, readonly) NSTimeInterval timeSinceStart; // seconds since startStreaming…, 0: no stream
```

Error codes (`PTTorrentStreamerErrorDomain`): -4 not enough space (legacy
refusal, or disk full in full mode), -5 below the minimum working set of bounded
storage (at metadata time; or, before the stream is ready, the volume stayed too full
for the download to go on for 30 s: see Disk full), -6 any other file error (I/O, permissions; before, it was reported as -4),
-7 the torrent is already used in a way that cannot be shared (see Torrents in the
session), -8 a stream was reading an offline download's file and the download was
stopped before the file was complete. All have a localized description.

Everything else is unchanged and source-compatible (Mac app). Semantics that
changed on purpose:
- `fileSize` is the selected file's size (it was the whole torrent before the
  file priorities were applied).
- Bounded mode: `torrentStatus.totalProgress` is the share of the file
  downloaded once and reaches 1 only when the whole file is on disk;
  `totalDownloaded` only grows (freed pieces stay counted).
- `cancelStreamingAndDeleteData:` removes the torrent from the session (before:
  paused, and libtorrent's auto-manager could resume it). In bounded mode the
  data is always deleted. A stream that joined an offline download's torrent never
  removes, pauses or deletes anything of it.
- No torrent is auto-managed: libtorrent never queues a stream nor resumes a
  paused download.
- The HTTP server never serves bytes that are not on disk (see below).

Swift:

```swift
let streamer = PTTorrentStreamer()
streamer.allowsBoundedStorage = true              // only where the pump below runs
streamer.storageBudget = Int64(torrentShare)      // what the HLS copy leaves
streamer.mediaDurationHint = runtimeSeconds
streamer.startStreaming(fromMultiTorrentFileOrMagnetLink: link, progress: { _ in }, readyToPlay: { url, path in
    // ...
}, failure: { error in
    // (error as NSError).code == PTTorrentStreamerError.notEnoughSpaceForBoundedStorage.rawValue
}, selectFileToStream: { names, sizes in Int32(index) })

// remux pump (reads the file directly):
streamer.readPosition = reader.offset          // also on every seek
streamer.consumedBefore = reader.offset        // the remux never reads behind itself
// rewind policy (the reader then reads forward from `target` up to where it is):
if target < streamer.contiguousAvailableOffset(before: streamer.readPosition) { /* block */ }
```

### Thread safety

All of the section above can be used from any thread. `allowsBoundedStorage`,
`storageReserve`, `mediaDurationHint` and `downloadDirectoryOverride` are read
when the metadata arrives: set them before starting. `storageBudget`,
`readPosition` and `consumedBefore` can change at any time; they are atomics
read by the libtorrent network thread. The state lives in a C++
`ptbounded::StreamController` (`Sources/Bounded/PTStreamController.mm`) shared
by the streamer (atomic `shared_ptr`), the HTTP responses (GCD queues) and a
libtorrent `torrent_plugin` (network thread). Libtorrent internals are only
touched on the network thread (`tick()`, `on_piece_pass()`, or work posted to the
session's `io_context`).

### Reading the file directly

A piece counts as available once it passed its hash check **and** its bytes are
verified as written to the file: `lseek(SEEK_HOLE)` finds no hole in it (its
region was a hole before it was downloaded). Where that proof does not hold, the
piece is read back after libtorrent's flush and its SHA-1 compared with the
torrent's hash: a piece that failed a hash check earlier in the stream (its bad
blocks may be in the file), any piece downloaded into a file that already held
data, and every piece on a volume without holes (full mode only). A piece that
is not wholly inside the selected file (multi-file torrents) cannot be hashed
from it: libtorrent's flush is trusted then. The remux, which reads the file with a
`FileHandle`, must only read ranges for which `isRangeAvailable` is `YES`, and
must only release (`consumedBefore`) what it will never read again.

## Loading status (before the metadata)

A stream's progress block and `PTTorrentStatusDidChangeNotification` used to start only
when the metadata was in (`metadataReceivedAlert` started the 0.5 s monitor): a magnet
resolving its metadata, or a swarm that never answers, gave the app nothing at all (the
Apple TV's loading screen: a spinner, no information, no way to tell a slow start from a
dead source). Now:

- A stream that adds its torrent starts the monitor at once: every 0.5 s the progress block
  and the notification carry seeds, peers and the download rate (the metadata exchange
  counts: protocol bytes), `bufferingProgress` 0 and `totalProgress` 0 until the metadata is
  in. A `.torrent` file (or a magnet whose metadata is already known) goes through the
  metadata at once, as before.
- `hasMetadata` (any thread): `YES` once the metadata is processed and the file chosen
  (`fileName`, `fileSize`, `storageMode` are set from then on); `NO` before and when no stream
  runs. `timeSinceStart` (any thread): seconds since `startStreaming…` on the system-uptime
  clock, 0 when no stream runs. Both reset at cancel.
- One monitor loop per stream: the loop started before the metadata goes on after it (the
  metadata publishes once and joins it). Before, every call of the monitor started a loop of
  its own. A generation counter (bumped at every start and cancel) stops the loop of a
  cancelled or restarted stream at its next tick.
- No status after a cancel: a status read before the cancel, or by an alert handled on the
  alerts thread right after it, is dropped on the main queue (before: one more
  notification could follow a cancel; the progress block was already nil).
- Unchanged: `PTTorrentDownload` (its progress block turns it "Downloading": it stays
  "Processing" until the metadata, as before) and a stream that joined a torrent already in
  the session (`publishesStatusBeforeMetadata` returns `NO` for both); full and bounded
  modes after the metadata.

```swift
streamer.startStreaming(fromMultiTorrentFileOrMagnetLink: magnet, progress: { status in
    // from the first 0.5 s: status.peers, status.seeds, status.downloadSpeed
    let phase = streamer.hasMetadata ? "buffering \(status.bufferingProgress)" : "getting the details"
    // streamer.timeSinceStart: how long this has been going on
}, readyToPlay: { _, _ in }, failure: { _ in }, selectFileToStream: { _, _ in 0 })
```

## Rewinds (what is on disk, for the app)

The user's choice: a rewind further back than what is still on disk is blocked
(no download again). Exact semantics, all cheap reads of the controller's piece
states (atomics), usable from any thread, valid at the moment of the call:

| Accessor | Meaning |
|---|---|
| `lowestAvailableOffset` | Bounded: end of the highest consumed piece, a piece being consumed when it lies entirely below `consumedBefore` minus one guard piece, pinned pieces excepted. Below it (apart from the pinned head) data is deleted or about to be (freed in batches within a second) and never comes back. It follows `setConsumedBefore:` at once and never decreases. 0 in full mode. It says nothing about data above it: a gap left by a forward seek is not on disk either. |
| `isRangeAvailable:length:` | Every piece overlapping the range is on disk now (passed its hash check and verified as written). `NO` for an empty range or one outside the file. A snapshot: consumed pieces still on disk count until they are freed; a piece ahead of the reader can be dropped when the disk is full (it is downloaded again). |
| `firstMissingOffsetFrom:` | First offset at or after the argument whose piece is not on disk now (the argument itself if its piece is missing), or the file size. |
| `contiguousAvailableOffsetBefore:` | Backward counterpart: the lowest `start` such that every byte of `[start, offset)` is on disk now and stays there (pinned, or not consumed). The argument itself when the byte before it is not available. |

Rewind check for a reader at `readPosition` that reads forward again from the
target (VLC over HTTP, or the remux restarted at a segment):
`target >= contiguousAvailableOffsetBefore(readPosition)`. A gap left by a forward
seek, or deleted data, between the target and the reader blocks it, as it should:
the reader would hit a 410 there. A rewind into the app's own HLS copy does not need
the torrent at all. Rewinding to the very start is only allowed while everything
from 0 to the reader is still on disk (the pinned head alone is not enough).

## How it works

### Window (PTBoundedLogic.cpp `planWindow`, applied in PTStreamController.mm `apply`)

Only pieces of the selected file are ever wanted (fixes the old
`prioritizeNextPieces`, which reset every piece of every file to priority 1).

| Pieces | Priority |
|---|---|
| other files | 0 |
| pinned head: MKV up to the first Cluster and at least 64 MiB (`kMatroskaHeadPinBytes`: what a player opening the file again reads before its first seek lands — VLCKit 4 over HTTP read 20-30 MB of the first clusters and prefetch), end of the MP4 `moov` (parsed from the file, `parseHeadPins`), 32 MiB if unknown, at most 64 MiB; 64 MiB until parsed | 7 |
| pinned tail: at least 8 MiB in whole pieces (`tailPinPieces`: 2 pieces of 4 MiB or more, at most 10 small pieces, never fewer than before) + an MP4 `moov` stored after `mdat` | 7 |
| a piece the head parser waits for | 7 |
| window: `[read piece, +N)` with N ≥ 32 MiB | bounded 6 (`kBoundedWindowPriority`), full 7 |
| pieces an HTTP reader waits for ("urgent") | 7 |
| ahead of the reader | 1 (paced) |
| behind the reader, on disk | 1 |
| behind the reader, missing (skipped by a seek), bounded | 0 |
| consumed (below `consumedBefore` minus one guard piece), bounded | 0, then freed (once confirmed on disk) |
| consumed while missing (a gap skipped by a seek), bounded | 0, forever: "gone", like freed data |
| freed | 0, forever |

Full mode keeps today's window: the next MIN_PIECES missing pieces at or after
the read position with 100 ms deadlines, every piece of the file wanted. The tail
pin is the same byte-sized one (MKV Cues, an MP4 `moov` at the end are there at
open), but the stream still waits only for the last 1 or 2 pieces, as before: only
those get deadlines (`urgentTailStart`), the rest of the tail comes at priority 7
right after the head window. (Gating readiness on the whole tail was tried: in the
session harness, with 256 KiB pieces at 256 KiB/s, a stream became ready in 15.5 s
instead of 8 s.)

Piece priorities are compared with libtorrent's own on every update (not with a
cache): `prioritize_files()` takes a disk-thread round trip and then rewrites every
piece of the selected file to 7, after the first plan.

Bounded mode uses **no libtorrent deadlines**. While time-critical pieces exist,
libtorrent keeps a single normal request per peer and only asks time-critical
pieces due within about a second; in the offline tests a deadline window starved
for tens of seconds while pieces far ahead kept arriving. Priority 6 with
sequential download fetches the window first, in file order: libtorrent's
sequential picker takes the top-priority (7) pieces first but in a random order
(its priority buckets are shuffled), then every other wanted piece in index order
from the first one missing. With the whole window at 7 (until part 3) the read
piece came in among the last of its 80 MiB window after a seek: 7.1 s with a
12 MB/s seed, against 1.07 s in full mode (app runs md4, mc3). Only the pins and the
pieces a reader waits for (the read piece itself after a seek) stay at 7. While a piece the reader needs is
missing, pieces beyond the ahead budget (minus freed data whose hole is not
punched yet, e.g. the old window right after a seek) are temporarily not wanted
(priority 0, back to 1 once it arrives), so a late piece cannot let the rest of
the file fill the disk. One missing piece beyond that cap stays wanted (the
sentinel, kept for the whole late episode, so at most one extra piece comes in):
otherwise the late piece could be the last wanted one, and libtorrent marks the
torrent finished the moment it arrives.

A torrent can still be "finished" for a while: the window reached the end of the
file, or the sentinel arrived before the late piece. libtorrent then disconnects
its seeds (`close_redundant_connections`, kept at its default). Turning that
setting off was tried and rejected: the connection then survives libtorrent's
upload mode after an ENOSPC (choked, hundreds of cancelled requests outstanding),
was dropped a few seconds after recovery, and in 2 of 4 forced-ENOSPC runs left a
piece that libtorrent never requested again (the stream stopped for good). With
the default, the seed is disconnected in upload mode and reconnected at once when
it ends (`set_upload_mode(false)` resets `last_connected`).

In bounded mode the pieces needed before `readyToPlay` are at most the window
(plus the tail pins), so they are all fetched at top priority and unthrottled:
beyond the window they would be paced like any data ahead, down to the floor
rate when the minimum working set is tight.

### Pace (`pace`)

`aheadBudget = storageBudget − pinned − kept behind − inflight` (at least
`minAhead`), and never more than the free space above the reserve allows. The
ahead bytes are measured on the real allocation (`st_blocks`), so partially
downloaded pieces and holes not punched yet count.

The consumption rate is a moving average of the read position, sampled once a
second (`consumedBetween`): a move over data that was never on disk is a seek
and counts as nothing, and a sample is capped at max(2× the current rate,
4× the bitrate, 16 MiB), so a forward seek does not open the pace controller
wide.

| Fill of the ahead budget | Download limit (`torrent::set_download_limit`) |
|---|---|
| < 75 % | unlimited |
| 75–100 % | 2× → 1× the consumption rate (≥ 64 KiB/s) |
| 100–112.5 % | 64 KiB/s floor |
| ≥ 112.5 % | 8 KiB/s |
| free < reserve | 8 KiB/s |
| reader waits for a piece | unlimited (64 KiB/s if free < reserve / 2) |

The session is never paused: peers stay connected. Since the floor and trickle
rates keep bringing data in, disk use is kept flat over a pause of any length:
while the reader does not wait, data ahead beyond the budget plus the floor band
(12.5 %, at least one piece) is dropped back down to the budget, and so is
whatever eats into the reserve (`excessAheadBytes`; dropped pieces are fetched
again later, at the trickle rate).

### Freeing (`releasePieces`, `punch`)

For every consumed piece confirmed on disk (a piece still being verified may have
blocks in libtorrent's cache, written after the punch: it is freed on a later
plan), on the network thread, in batches (32 MiB, a tick, or the disk below the
reserve):
1. state `Freed` in the controller's map (HTTP reads re-check it after `pread`);
2. `set_piece_priority(0)`;
3. `picker().we_dont_have()` + `update_gauge()` — what libtorrent does itself for
   unfinished resume pieces; `has_piece_passed()` is now false, so queued peer
   requests are rejected by `peer_connection::fill_send_buffer` and the piece is
   left out of new bitfields (`peer_connection::reject_piece` is not used: its
   loop erases from a vector while iterating with a cached end iterator);
4. `lt_donthave` to peers that support it (a small `peer_plugin` records their
   message id from the extension handshake, the message is the one
   `bt_peer_connection::write_dont_have` sends);
5. `async_clear_piece` on the last piece of the batch: a disk fence (every read
   or write already queued completes) that also evicts it from the cache;
6. in its handler, on a GCD queue, `fcntl(F_PUNCHHOLE)` on the piece's range of
   the file, rounded inward to 4 KiB (to the end of the file for the last piece);
   a 4 KiB block shared with a neighbour piece that is freed too is punched as
   well (files of multi-file torrents do not start on a block boundary).

A forward seek leaves partially downloaded pieces behind: their priority drops
to 0 but blocks already requested still arrive and are written. Once consumed,
and once no block of theirs is requested any more (libtorrent's download queue),
they get an `async_clear_piece` fence and are punched too
(`punchPartialPieces`, statistics key `partialPiecesPunched`).

Freed pieces are never downloaded again in this stream (the user's choice:
rewinding further back than what is on disk is blocked).

### Disk full

Nothing is ever dropped once every piece from the read piece to the end of the file is
on disk (`onDiskToTheEnd`): nothing more is downloaded then, and the consumer may take
the rest of the file as final (the app's remux marks its input complete there, cuts
its last segment, and reads zeros as data from then on).

**No write ever extends the file** (bounded mode, and full mode on a volume with holes).
The controller creates the file (and
its directory) at its final size, as a hole (`presizeFile`: `open(O_CREAT)` + `ftruncate`),
on the network thread as soon as the files are checked, before its first plan wants any
piece; libtorrent then opens the existing file as is (its size is the expected one: no
truncation, and sparse mode never preallocates). Why (the allocation runaway, e2e B1,
found in part 3):

- On APFS, a write that starts beyond the end of the file while the file's last appends
  are still dirty in the buffer cache makes the kernel write zeros over the whole gap,
  from the old end of the file to the write, before the write returns. libtorrent's
  sparse storage does exactly that at start-up: it appends the head window (256 KiB
  write-cache lines) and writes the tail pins gigabytes further at the same time.
- In-app trace (a DYLD interposer around every syscall on the file, `Tools/AllocationProbe/ptft.c`):
  one `pwritev` of 256 KiB at 4,844,421,120 on a file of 83,886,080 bytes took 2.04 s;
  meanwhile the allocation grew from 27.5 MiB to 2826 MiB (the whole 3 GiB volume) with
  st_size unchanged, which jumped when the call returned (successfully). The two next tail
  writes waited behind it. The volume filled up, every other write failed with ENOSPC
  and libtorrent went into upload mode.
- Reproduced without libtorrent (`Tools/AllocationProbe/zerofill_probe.c`, 3 appending
  threads then one far write, fresh 3 GiB sparse image): 33 of 88 far writes (38 %) zero-fill
  the gap, for gaps of 1 GiB, 2 GiB, 4.4 GiB and 12 GiB alike; the host's sparse image grew
  by 2.9 GB (zeros really written, ~1 GB/s). 0 of 38 after `fsync`, 6 of 38 after a 1 s
  pause (the dirty data is written back on the kernel's schedule), 0 of 105 when the file
  already had its size (`ftruncate` right after the first append, or right after the burst
  with the dirty data still there): `ftruncate` itself never allocates.
- The first mitigation (c4ce94ab) sized the file only once libtorrent had created it, on
  the next plan: usually before the tail pins, but not by construction.

`PT_BOUNDED_NO_PRESIZE=1` in the environment turns the presize off (diagnostics only: it
brings the runaway back).

Full mode does the same since the part-3 final round, on volumes with holes only (on HFS+
or exFAT, extending a file can write its zeros at once). There the zeros cost no space (the
file fits), but APFS still wrote them at the first tail write, up to 13 GB at ~1 GB/s with
libtorrent's disk thread blocked behind the call (e2e imf1: 61 -> 4628 MiB allocated in 4 s),
where the CocoaPods PopcornTorrent the tvOS app shipped created its files at their size
(`storage_mode_allocate`). Console: `PopcornTorrent full mode: file created at … up front`.

Backstop, allocation runaway (`reclaimAllocatedHoles`), should the file ever hold far more
blocks than its data anyway: while free space is below the reserve and the file holds more
than its data, its pieces' partial downloads, the pending holes and the in-flight
allowance plus max(64 MiB, 4 pieces), every missing piece libtorrent has no block of
(not in its download queue) is punched back to a hole, on the network thread (no block
can be requested meanwhile), in 64 MiB steps (a failed step is tried again in 4 MiB
steps, then logged with its errno), at most every 2 s. One `F_PUNCHHOLE` over gigabytes
of zero-filled blocks fails with ENOSPC on a full volume (probe: 2 of 2 right after a
runaway, while a 64 MiB step on the same file succeeded; the first backstop punched each
range in one call and freed nothing in the e2e run fmb2, errno not logged then). With 64 MiB
steps and the presize turned off, the backstop gave back 2.3-2.7 GB in every
runaway of part 3 and the stream started (see Results, part 3). Statistics key `reclaimedBytes`; the
`PT_BOUNDED_DEBUG` trace and the console log `allocation runaway`.

**A start never loads forever for lack of space.** The controller tracks how long the
download has been unable to go on for lack of space (free space below half the reserve,
or libtorrent in upload mode after ENOSPC; statistics key `diskStarvedSeconds`). A
bounded stream that is not ready yet and has been starved for 30 s
(`kStartStarvationSeconds`) fails with -5 (`NotEnoughSpaceForBoundedStorage`): its
localized message gives the space to clear (the minimum working set minus the free space
and what this stream's own file holds, which its cancel gives back), or asks to clear some
space when deleting the stream's file is enough. A ready stream never fails this way: its
reader waits for the space to come back, as before.

In bounded mode a `file_error_alert` with ENOSPC/EDQUOT does not end the stream:
the controller shrinks the ahead budget by 25 % (down to 50 %), drops on-disk
pieces farthest ahead of the reader (they are punched, then wanted again; never
pinned, never in the window; only pieces confirmed on disk that libtorrent has, see below)
until the reserve is back, and calls
`set_upload_mode(false)` (libtorrent's reaction to ENOSPC is upload mode) once
free ≥ reserve / 2. The same drop runs whenever free < reserve / 2, once the
holes already queued have landed (and, while the reader does not wait, whenever
free < reserve: see Pace). The ahead budget never exceeds the free space above the
reserve, so dropped data is not fetched again until there is room. Any other file
error ends the stream as before, now with code -6.

**Drops take only pieces fully written** (`piecesToDrop`: `PieceOnDisk`; `releasePieces`:
`PieceOnDisk` and `torrent.have_piece`). A piece that passed its hash check while blocks of
it were still in libtorrent's write cache (`Verifying` here, "passed, not have" there) lost
its download entry in `we_dont_have`; the `async_clear_piece` fence then flushed those
blocks, and each write completion (`torrent::on_disk_write_complete` → `mark_as_finished`)
re-created the entry with the block "finished"; the punch zeroed them. With every block
pending, libtorrent held the piece as "finished = all, passed 0, requested 0" for good: a
hash check only starts when a block arrives (`peer_connection::incoming_piece`) or a piece
is added (`torrent::add_piece`), so it was never requested nor checked again, and the reader
waited for it forever (verify-storage F1: 3 of 3 harness runs with 256 KiB pieces and a
ballast; integrate run h1; part 2's fix-enospc). With some blocks pending, the rest was
downloaded again and the hash failed on the punched zeros, putting the seed on parole.
Backstop (`restoreStuckPieces`, every tick, bounded mode): a wanted piece the controller
has as missing whose picker entry is "every block finished, none requested or being written,
not passed, not locked" for 10 s (longer than any hash job) goes through
`piece_picker::restore_piece` and is downloaded again; console `piece N was held as written
but never verified: downloaded again`, statistics key `stuckPiecesRestored`.

### HTTP server (`PTGatedFileResponse`)

`GCDWebServerFileResponse` (zeros for missing data, one parked request at a
time) is replaced by a streamed response:
- each chunk (≤ 512 KiB) is read only from pieces on disk; a missing piece is
  waited for (no thread blocked), a freed one fails the response;
- a request that starts in data that is gone (freed, or consumed before it was
  ever downloaded, i.e. skipped by a seek) gets **410** at once; outside the
  file **416**; a waiting read whose piece becomes gone fails at once;
- reads of the streaming request wait as long as needed; in bounded mode a waiting
  read of another request (a prefetch, an abandoned request) gives up after 120 s
  so it does not keep its piece urgent; in full mode reads always wait;
- any number of concurrent requests;
- the streaming request (the "primary reader") drives `readPosition`; requests
  in the pinned head and tail (headers, indexes) never do; a new request becomes
  primary when the previous one has been silent for 2 s (a player's seek);
  pieces any reader waits for are fetched first;
- `servedOffset` is the primary reader's position.

### Cancel

`cancelStreamingAndDeleteData:` fails the waiting reads, closes the
controller's descriptor, and calls `session::remove_torrent` (with `delete_files`
when deleting), then removes the directory as before. libtorrent deletes files by
path on its disk thread, after the jobs already queued for the torrent: the same
torrent added again right away (a replay, the disk-full retry) waits for that
deletion (`torrent_deleted_alert`, at most 5 s; the replay's start returned in
0.45 s in the session harness) so it is not
deleted under the new stream. A second cancel never touches a newer torrent of the
same info-hash (libtorrent's `remove_torrent` finds torrents by info-hash).

## Torrents in the session

All streams and downloads share `PTTorrentsSession.sharedSession`.

**Never auto-managed.** Torrents are added without `auto_managed` and not paused:
libtorrent's auto-manager (3 active downloads by default) used to queue a stream
started next to 3 active downloads (0 peers, never ready) and resumed paused
downloads about 30 s later. Streams always run; downloads run until paused, and
`PTTorrentDownload pause`/`resume` are explicit. Every download runs at once, as
with the CocoaPods pod (one session per download, so never queued).

**A stream of a torrent that is already in the session** (the -2 path, which used
to create a new, never freed `PTTorrentsSession` per stream and to flag both
streamers `deleteOnlyDownloadedFile`) joins it (`joinTorrent:`):

| Already there | New | Result |
|---|---|---|
| an offline download (`PTTorrentDownload`), any state | a stream | joins as a guest: reads the download's file (no second copy, no second download), full mode always (the download keeps the whole file: no space check), its own controller and plugin (`torrent_handle::add_extension`); the newest guest drives the torrent's priorities and deadlines (the download's controller is suspended: state kept, nothing planned), so the stream's window is fetched first; a paused download runs while a stream reads it and is paused again when the last one leaves |
| a stream in full mode (or not decided yet and not allowed to be bounded) | a stream | joins as a guest the same way (two players of one film on the Mac) |
| a stream that is or may be bounded | a stream | refused, -7 |
| anything | a download | refused, -7 (a download keeps its own copy) |
| another file of the same torrent | a stream | refused, -7, at metadata time |

A guest's cancel never removes, pauses or deletes anything of the torrent it joined,
whatever `deleteData` is: it resets its deadlines, removes its plugin from the torrent
(`torrent::remove_extension`, on the network thread) and hands the torrent back to the
previous guest or the owner, which plans again from libtorrent's actual priorities. A
guest's initial piece states are trusted only after the torrent's write cache was
flushed (`async_release_files`), since a piece libtorrent has may not be written yet.

When the owner goes first: a download that finishes removes its torrent and the
guests keep reading the complete file (their own descriptor); a download stopped or
removed before the file is complete ends its guests with -8. A stream that is
cancelled hands its torrent and its files over to its oldest guest, which owns them
from then on (its own cancel removes and deletes them).

**tvOS, back from more than 5 minutes in the background.** The fork used to create
a new session for the next torrents (the "torrents not starting after sleep"
workaround): the old session leaked (its threads, sockets, DHT) and the streams and
downloads already running stayed on it, with the sockets that had stopped working,
so an active stream could stall for good. Now the same session reopens its network
(`reopenNetwork`): no listen socket (nor DHT), then the configured ones again, so
sockets the system reclaimed while the app was suspended are recreated
(`reopen_network_sockets` keeps sockets that look the same, and libtorrent stops
reading from a socket after a fatal error but keeps it), then every torrent
re-announces (trackers, DHT). uTP connections ran over the old UDP sockets: nothing
tells them, and one that does not send hangs until its timeout (about a minute; seen
in the harness), so they are dropped on the network thread. libtorrent retries a lost
peer only after `min_reconnect_time` (60 s): for 30 s after a reopen it is 1 s, so
dropped peers, and peers lost while the app was suspended, come back at once.

### Other fork fixes

- `PTTorrentsSession addTorrent:` returns the handle (`return th;` was missing).
- Upstream d331ae80 (tvOS memory crash): no `alert_when_available` deadlines.
- The session is constructed with its settings (no split second of defaults).
- Finished torrents (full mode) are paused with `auto_managed` unset (no
  background seeding), and removed at cancel.
- The resume data path is taken from the alert (the torrent may be removed).
- `localizedString` falls back to the package's own `.lproj` (fr added).
- No torrent is auto-managed (see Torrents in the session).
- The loopback testing hook is no longer in the public header: it is declared in
  `Sources/Client/PTTorrentsSession+Testing.h`, which the harness imports.
- The alerts loop drains its autorelease pool every round: it had one pool around its
  endless loop, and every streamer an alert handler touched
  (`streamersForTorrentHandle:` returns an autoreleased array) stayed alive for the life of
  the process (verify-playback: 15 streams closed, 15 `PTTorrentStreamer` left).
- A download of the CocoaPods version, in progress when the app was updated: its plist
  (`<PersistentID>/Metadata.plist`) has no file index and its folder is not named after
  the torrent. `resume` now starts it into its own folder (`directoryName`: the plist's
  folder) on its own file (the stored index, else the torrent file named like the one in
  its folder, else the largest), so libtorrent finds and checks what it had; the old plist
  is removed once the new one is written (before: a new download from zero into another
  folder, maybe of file #0 of a multi-file torrent, listed twice).

## Statistics and tracing

`storageStatistics` keys: `bounded, fileSize, pieceLength, torrentBudget,
aheadBudget, aheadBytes, behindBytes, pinnedBytes, dataBytes, bytesOnDisk,
freeBytes, reserveBytes, readPosition, consumedBefore, lowestAvailableOffset,
servedOffset, headPinEnd, tailPinStart, everDownloaded, freedPieces,
droppedPieces, punchedBytes, punchErrors, diskFullEvents, fileErrors,
dontHaveSent, partialPiecesPunched, reclaimedBytes, presized, stuckPiecesRestored, diskStarvedSeconds,
waitingReads, downloadLimit, paceState (0 open, 1 proportional, 2 floor, 3 trickle,
4 emergency), consumeRate`.

`PT_BOUNDED_DEBUG=1` in the environment (Xcode scheme) logs the controller's
state once a second: read position, piece states, ahead/budget, allocation,
pending holes, limit, peers (choked, snubbed, queues), waiting reads,
libtorrent's view of the first missing piece, drops, and passes of pieces that
were not missing.

`Tools/AllocationProbe` (diagnostics, not built with the package): `zerofill_probe.c`
reproduces the APFS zero-fill offline (`zsh run_probe.sh [trials]`: every mode on a fresh
sparse image); `ptft.c` is the syscall tracer used to find it (a dylib for
`DYLD_INSERT_LIBRARIES` into a DEBUG app: every open/write/read/ftruncate/fcntl/lseek/mmap
on the torrent's file with st_size and allocated bytes before and after, the duration and
the thread, and a 10 ms sampler that logs the calls in flight whenever the allocation jumps).

## Tests

Unit tests (pure logic, no network):

```
xcodebuild test -scheme PopcornTorrent -destination "platform=macOS,arch=arm64" -only-testing:PopcornTorrentLogicTests
```

Do not run the whole scheme: `PopcornTorrent-Tests` streams public torrents.

Run the offline harnesses inside the sandbox profile
`Tools/BoundedStorageHarness/localhost-only.sb` (`sandbox-exec -f localhost-only.sb ...`):
it blocks every connection that is not on 127.0.0.1.

Session lifecycle harness (`SessionHarness`, same package): generated payloads,
private torrents, a seeder on 127.0.0.1, everything written under the work directory.

```
SessionHarness zombie <work>      # cancelled streams stop downloading; replay; replay right after a delete
SessionHarness starve <work>      # 3 cancelled streams then a 4th; 3 active downloads then a stream; pause/resume
SessionHarness guest <work>       # a stream joins a download's torrent (5 scenarios)
SessionHarness background <work>  # the tvOS network reopen during a stream
SessionHarness legacy <work>      # a CocoaPods-era download (Metadata.plist, no file index) resumed
SessionHarness premetadata <work> # a magnet's status before its metadata: a late seeder, one loop, nothing after a cancel
```

Offline end-to-end harness (`Tools/BoundedStorageHarness`): generates a file of
patterned pseudo-random data with an MKV head, a private torrent for it (no
trackers), seeds it from a libtorrent session on 127.0.0.1 and streams it with
`PTTorrentStreamer`, whose shared session is made loopback-only with
`+[PTTorrentsSession prepareSharedSessionForLoopbackTestingOnPort:]`
(`PTTorrentsSession+Testing.h`; no DHT, LSD, UPnP, NAT-PMP), into a fresh APFS
sparse disk image:

```
cd Tools/BoundedStorageHarness && swift build -c release --scratch-path <build>
zsh run_harness.sh <build>/release/BoundedStorageHarness bounded 3g <work> <mount> \
    --size-mib 6144 --rate-mbs 40 --pause-seconds 60 --budget-mib 2048
zsh run_harness.sh <build>/release/BoundedStorageHarness full 8g <work> <mount> --size-mib 6144
```

A consumer reads the whole file through the HTTP server at a steady rate,
compares every byte with the source and its SHA-256, advances
`consumedBefore` (32 MiB behind), pauses, reads ahead of the download, reads the
pinned head and tail and freed data, runs concurrent requests, and a raw
BitTorrent peer (fast extension + lt_donthave) requests a freed piece and a kept
one. Then it cancels and checks the space comes back, and that nothing is left
allocated below `lowestAvailableOffset` apart from the head pin. Options:
`--ballast-mib N` fills the volume with another file between 35 % and 55 % of
the file (`--ballast-hold-seconds S --ballast-greedy 1`: keeps it full for S
seconds, forcing ENOSPC); `--seek-at F --seek-to G --seeks N` makes the consumer
seek forward (from F to G of the file, then as far again), checks the bytes of
the ranges read and that a skipped, consumed range gets 410;
`--seed-rate-mbs R` caps the seeder (pieces stay in flight longer, so a seek
leaves partial pieces behind); `--piece-kib N`, `--budget-mib N`.

### Results (Mac, 2026-11-11, part 2: sessions, shared torrents, tail pin, rewinds)

All runs inside `localhost-only.sb`. The four SessionHarness modes also pass in an
AddressSanitizer build (`swift build --sanitize=address`), with no report.

| Run | Result |
|---|---|
| unit tests (`PopcornTorrentLogicTests`) | 27/27 |
| SessionHarness zombie | 8/8: after a cancel with `deleteData`, 0 KiB more from the seeder over 20 s and the folder stays deleted; the same torrent streamed again is ready and serves the right bytes (head, and 40 MiB in, waited for); started again right after a cancel with delete, its start returned in 0.44 s (waiting for the deletion) and its file survives; a second cancel touches nothing |
| SessionHarness starve | 8/8: three streams cancelled, their uploads stop; a 4th stream ready in 8.0 s (before: never, 0 peers, queued); with 3 active downloads a stream is ready in 7.1 s; a paused download gets 0 KiB over 35 s (before: resumed after about 30 s), and downloads again after `resume` |
| SessionHarness guest | 16/16: a stream of a paused download in progress joins it (same folder and handle, no second copy, one connection to the seeder); the download runs while it plays; 4 MiB at 100 MiB read in 2.6 s with the download at 17 %; cancel with `deleteData` keeps the download's file and pause, and the download then completes with the right hash; download stopped under a stream: -8; download finished under a stream: the stream reads all 48 MiB; two streams of one torrent: the first one's cancel hands it to the second, the last one deletes the folder; a download of a torrent a stream plays: -7 |
| SessionHarness background | 5/5: reopen during a stream: same session, new listen port, torrent kept; the stream's uTP peer is dropped and reconnected, 16 MiB in 7.5 s (8 s at the seeder's rate; without the uTP drop, 3 of 6 runs stalled about 60 s); connections lost "while suspended" come back 1.0 s after the reopen; the new listen socket accepts connections |
| bounded, 6 GiB, 3 GiB image, budget 2 GiB, 60 s pause | 21/21: at most 2066 MiB on disk, 1908-2066 MiB while 2.4 GiB went through; free never below 793 MiB; pause 2064 -> 2066 MiB over 55 s; same hash, 0 stall; 1518 pieces freed, 0 punch errors; freed range 410; probe peer refused a freed piece; nothing allocated below `lowestAvailableOffset` apart from the head pin; cancel gives the space back |
| full, 6 GiB, 8 GiB image | 14/14: full mode, whole file kept (6144 MiB), nothing freed, same hash, cancel gives the 6 GiB back |
| bounded, 3 GiB, 2 GiB image, 2 forward seeks | 23/23 (with a 60 s pause): at most 441 MiB on disk against a 436 MiB budget, skipped and consumed range 410 in 2 ms, bytes of the ranges read equal to the source |
| same, 16 MiB pieces, seeder capped at 60 MB/s | 23/23: at most 455 MiB against 492 MiB, 3 partial pieces punched, nothing allocated below `lowestAvailableOffset` apart from the head pin |

### Results (Mac, 2026-11-11, after the review fixes)

6 GiB file with 4 MiB pieces (1536 pieces) unless stated; 40 MB/s consumer.

| Run | Volume | Result |
|---|---|---|
| bounded, 60 s pause, budget 2 GiB | 3 GiB image (2.79 GiB free) | 21/21: ready in 3.0 s; 6 GiB read, SHA-256 equal, 0 wrong bytes, 0 stall; on disk at most 2058 MiB, 1911–2058 MiB while 2.4 GiB went through; free never below 801 MiB (reserve 512); pause: 1986 → 2057 MiB in the first 2 s (the budget share released by the last consumed batch), then 2057 → 2058 MiB over 55 s; 1522 pieces freed, 0 punch error, 2218 lt_donthave; freed range: 410 in 1 ms; freed piece rejected to the probe peer and withdrawn, kept piece served with real data; nothing allocated below `lowestAvailableOffset` apart from the head pin; cancel: free back to 2860 MiB |
| full (file fits, bounded allowed) | 8 GiB image | 14/14: full mode, whole file kept (6144 MiB), nothing freed, same hash, cancel gives the 6 GiB back |
| bounded + 900 MiB ballast (35–55 %), 60 MB/s | 3 GiB image | 21/21: the ballast filled the volume to 33 MiB free; 45 ENOSPC writes handled as disk full (no failure, 0 stall, same hash); far-ahead data dropped and fetched again (seed uploaded 1.15× the file) |
| bounded + ballast keeping the volume full for 30 s (3 runs) | 3 GiB image | 19/21 each: 31–48 ENOSPC handled, one 26.5–26.9 s stall while the volume had no free byte, then the whole file read with the same hash. The 2 probe-peer checks fail: the probe gets no answer after libtorrent's upload-mode episode (as before the fixes) |
| 3 GiB file, 2 forward seeks of 768 MiB, automatic budget | 2 GiB image | 22/22: torrent at most 407 MiB on disk against a 436 MiB budget (before the fixes: 695 MiB); bytes of the ranges read equal to the source; a skipped and consumed range gets 410 in 2 ms (before: 206, then an abort) |
| same with 16 MiB pieces and the seeder capped at 60 MB/s | 2 GiB image | 22/22: 2 partial pieces left behind by the seeks punched, 0 KiB allocated below `lowestAvailableOffset` apart from the head pin; at most 439 MiB on disk against 492 MiB |

Previous results (2026-11-10, before the review fixes): bounded 24/24 by the
older check list, full 13/13, ballast 23/24 (pause check), forced ENOSPC 22/24
(probe checks).

### VLC after a hand-off (app side, measured with VLCKit 4.0.0a21)

VLC's own Matroska demuxer does not seek through the Cues over HTTP: it reads every
byte from the last cluster it has seen up to the target (on a local file it uses the
Cues). In bounded mode those bytes are deleted (410: VLC stalls) or would be downloaded
whole. libavformat's demuxer (`:demux=avformat`) seeks through the Cues at once; over a
test server answering 410 past 64 MiB it read the head (≤ 30 MB), the Cues, then the
target, and played. The app opens a bounded Matroska stream with it when VLC starts at a
position; its subtitle tracks of the file and track names are not available then.

### Results (Mac, 2026-11-11, part 2 fixes)

| Run | Result |
|---|---|
| unit tests (`PopcornTorrentLogicTests`) | 31/31 (4 new: no drop once the rest of the file is on disk, app headroom in the minimum, full mode leaves room for the app's copy, pending external bytes; the Matroska head pin test extended) |

### Results (Mac + tvOS simulator, 2026-11-11, part 3: allocation runaway)

Offline starts of the app (DEBUG builds) with its remux film of 4.5 GiB (4 MiB pieces) on a fresh
3 GiB APFS sparse image each, seeded at 12 MB/s on 127.0.0.1, ~75 s each (the start, then 60 s of
playback). Runaway: the backstop fired, or the file held more than 1.4 GiB (its window is ~0.8 GiB).

| Build | Starts | Runaways | Peak allocated (1 s monitor) | Ready after the metadata |
|---|---|---|---|---|
| c4ce94ab, presize swallowed by the tracer (`ptft`) | 9 Mac | 5 (2.4-2.8 GB, the whole volume; trace) | 715-2708 MiB | 8.2-14.7 s |
| this fix, `PT_BOUNDED_NO_PRESIZE=1`, no tracer | 10 Mac | 4 | 769-2682 MiB | 8.3-13.8 s |
| this fix | 22 Mac | 0 | 753-765 MiB (median 762) | 8.1-9.3 s (median 8.3) |
| this fix | 4 tvOS 26.5 simulator | 0 | 756-764 MiB | 8.6-9.4 s |

In every runaway the backstop gave the space back (2.3-2.7 GB in 64 MiB steps, 0 punch error)
and the stream started, up to 6 s later than a clean start (11.9-14.7 s against 8.1-9.4 s;
once the runaway came after the start). Every fixed start logs "file created at
… bytes up front (a hole; it held 0)": the file exists at its size before libtorrent writes.

Start starvation (the volume filled up by a ballast 2 s after the file was created, 85 MiB left,
seeder at 1 MB/s so the stream is not ready): Mac, "too full to download" 5 s after the metadata,
the stream failed with -5 30.5 s later ("to free 1194 MiB"); tvOS simulator, the same after 30.0 s,
then the app's disk-full flow (caches wiped, one retry refused at metadata with -5) shows its alert
"Pas assez d'espace libre pour lire cette vidéo, même en mode stockage limité. Libérez au moins 1,4 Go".

| Run | Result |
|---|---|
| unit tests (`PopcornTorrentLogicTests`) | 35/35 (4 new: starvation, start expiry, space to free, reclaim steps) |
| SessionHarness zombie / starve / guest / background | 8/8, 8/8, 16/16, 5/5 |
| bounded, 6 GiB, 3 GiB image, budget 2 GiB, 60 s pause | 21/21: at most 2068 MiB on disk, free never below 791 MiB, 0 stall |
| full, 6 GiB, 8 GiB image | 14/14 |
| bounded, 3 GiB, 2 GiB image, 2 forward seeks | 23/23: at most 429 MiB against 436 MiB |
| bounded + 900 MiB ballast, automatic budget | 21/21 (the ballast did not reach the reserve) |
| bounded + 900 MiB ballast, budget 2 GiB (free down to 34-360 MiB) | 4 runs: 19/21 three times (the 2 probe-peer checks fail, exactly as with the previous commit c4ce94ab, 19/21 in its 2 runs); once 17/21: the main read also waited 120 s for a piece at 4.0 GiB (164 pieces dropped and fetched again in that run; see Limits) |
| bounded + ballast keeping the volume full for 30 s | 19/21: 149 ENOSPC handled, one 28.1 s stall while the volume was full, same hash, no failure (the stream was ready); the 2 probe-peer checks fail, as before |
| builds macOS, tvOS, tvOS Simulator, iOS | 0 errors (the 2 existing iOS deprecation warnings) |

### Results (Mac, 2026-11-11, part 3 final round: drop guard, hole self-test, full-mode presize)

Harness and app runs on d7d04e85, all offline (localhost-only sandbox, private torrents, APFS
sparse images):

| Run | Result |
|---|---|
| unit tests (`PopcornTorrentLogicTests`) | 37/37 (1 new: pieces being verified are never dropped) |
| bounded + 900 MiB ballast, budget 2 GiB, **256 KiB pieces** (verify-storage's F1 repro, `PT_BOUNDED_DEBUG=1`) | 3 runs: 21/21 each, 0 stall, 0 `stuckPiecesRestored` (before the fix: 3 of 3 failed, a 120 s wait on a dropped piece) |
| forced ENOSPC with 256 KiB pieces | 21/21 (before: 12/15, a 132 s stuck piece then a 120 s stall) |
| bounded, 6 GiB, 3 GiB image, budget 2 GiB, 60 s pause | 21/21 |
| full, 6 GiB, 8 GiB image | 14/14 (the file is created at its size up front) |
| bounded, 2 forward seeks | 23/23 |
| bounded + 900 MiB ballast, automatic budget | 21/21 |
| bounded + 900 MiB ballast, budget 2 GiB | 2 runs: 21/21 both (19/21 in every earlier run: the 2 probe-peer checks now pass) |
| forced ENOSPC (900 MiB ballast held 30 s) | 3 runs: whole file read with the right hash in all 3; 21/21 once, 19/21 twice (the 2 probe-peer checks) |
| SessionHarness zombie / starve / guest / background / legacy | 8/8, 8/8, 16/16, 5/5, 6/6 (legacy is new: a CocoaPods-era download resumes in its folder, on file #1 of 2, the seed sends 24 of 48 MiB, one plist left) |
| hole self-test | PASS on the Mac (APFS sparse image) and in the tvOS 26.5 simulator's sandbox |
| app, Mac, full mode (10 GiB image, a 4.5 GiB film) | `full mode: file created at … up front`; no allocation jump > 200 MiB in 4 s (before: 61 → 4628 MiB in 4 s at the first tail write); the same player events as before |

### Results (Mac, 2026-11-12, status before the metadata)

All offline (localhost-only sandbox; `premetadata` uses a public torrent without trackers:
private torrents do not exchange metadata), on the Mac:

| Run | Result |
|---|---|
| unit tests (`PopcornTorrentLogicTests`) | 37/37 (the change is not pure logic: covered by the harness) |
| SessionHarness premetadata | 12/12, twice: a magnet with nobody to connect to reports every 0.5 s from the start (12 callbacks and 12 notifications in 6 s, all 0 peers, 0 %, `hasMetadata` NO; before: none until the metadata); `timeSinceStart` equals the harness clock (6.00 s); a seeder started at 6 s (upload capped at 8 KiB/s: a 64 MiB file in 16 KiB pieces, about 80 KiB of metadata) shows before the metadata in 29 callbacks with 1 peer, 27 with a download rate (max 9.6 KB/s); metadata at 21.7 s: `hasMetadata`, the file and full mode; one loop after it (8 callbacks in 4 s with no piece coming; two loops: about 16); ready, the right bytes; nothing after a cancel (0 callbacks, 0 notifications in 2 s; before the fix one notification could follow); a `.torrent` file has its metadata right after the start; a download of a magnet nobody answers stays Processing |
| SessionHarness zombie / starve / guest / background / legacy | 8/8, 8/8, 16/16, 5/5, 6/6 |
| `xcodebuild build` macOS, tvOS, tvOS Simulator, iOS | succeeded, no new warning |

## Limits and open points

- tvOS on device is untested: `F_PUNCHHOLE` and `SEEK_HOLE` in the app sandbox,
  free-space keys, purging near a full disk, flash timings. `F_PUNCHHOLE` needs
  APFS: on a volume without holes bounded storage is not used (legacy refusal).
- Real swarms are untested: many peers, slow peers, peers dropping us under the
  64 KiB/s floor.
- A rewind into a gap left by a forward seek (not freed, never downloaded) is
  downloaded on demand while the gap is not consumed (once consumed it is gone:
  410), but after the window reached the end of the file the torrent is
  "finished" and libtorrent has dropped its seeds: it waits for a reconnection
  (up to `min_reconnect_time`, 60 s). Use `isRangeAvailable` before allowing such
  a rewind.
- Fast resume is never saved in bounded mode, and the files are deleted at cancel.
- The tvOS network reopen is tested on the Mac only (a forced reopen during a
  stream): socket reclaiming by a suspended tvOS app, and how long real peers take
  to come back, need the device.
- Shared torrents: a guest of a download in progress verifies by content (SHA-1 read
  back) every piece that passes while it is attached (the file already held data).
- After a real ENOSPC the reader waits as long as the volume stays full; in the
  harness it resumed 1–2 s after space came back (one earlier run waited about
  35 s: requests libtorrent cancelled when it entered upload mode stayed
  outstanding on the seed until their timeout).
- If the sentinel piece arrives before the late piece, the torrent can still be
  "finished" for a moment and libtorrent drops its seeds (default
  `close_redundant_connections`, see Window).
- Not exercised by the harness: the content verification of suspect pieces (no
  hash failure, no pre-existing file offline), and a pause long enough for the
  floor band to fill (the over-budget drop is unit-tested; the harness pause is
  60 s).
- Full mode now sizes the file up front too (volumes with holes). A full-mode stream restarted
  on a file a previous stream kept, without resume data, makes libtorrent hash every piece of
  it (holes read as zeros): what the CocoaPods version's allocate mode did as well.
- The APFS behaviour was measured on macOS 27.2 (and the tvOS 26.5 simulator, which writes
  through the host's kernel). tvOS on device is expected to behave the same, untested; the
  presize does not depend on it.
- The 120 s waits for a piece "never fetched again after the drops" (part 2 fix-enospc,
  part 3 runs s2-ballast2 and h1) were the dropped-while-verifying piece above (fixed in the
  part-3 final round). The 2 probe-peer checks (a raw BitTorrent peer gets no block of a kept
  tail piece, and no explicit reject for a freed one: it gets no data either, and the piece
  is withdrawn by lt_donthave) still fail in 2 of 3 forced-ENOSPC runs; they now pass in the
  ballast run with a 2 GiB budget (2 of 2), where they failed in every earlier run. Not
  investigated: no player uses that path.
- The time-critical (deadline) path of libtorrent misbehaved with one very fast
  local seed (a window starved, cancels left requests outstanding until the
  request timeout); bounded mode avoids it, full mode keeps it as before.
