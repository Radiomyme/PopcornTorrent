# Bounded storage

Streaming a file larger than the free space: a 13 GB film on an Apple TV with
about 3 GB free. Only a window of the selected file is kept on disk; the pieces
the consumer is done with are deleted (APFS holes) and never served again.

## When it switches on

At metadata time (`metadataReceivedAlert`), `planBudget` (`Sources/Bounded/PTBoundedLogic.cpp`) decides:

| Situation | Mode |
|---|---|
| selected file (minus what is already allocated on disk) + `storageReserve` ≤ free space | **Full**: legacy behaviour, the whole file is downloaded and kept |
| otherwise, free space ≥ minimum working set | **Bounded** |
| otherwise | **Refused**: error `PTTorrentStreamerErrorNotEnoughSpaceForBoundedStorage` (-5), localized message with the space to clear |
| `allowsBoundedStorage == NO` (always for `PTTorrentDownload`) | legacy check, unchanged: refused with -4 when the file does not fit |

Free space is `NSURLVolumeAvailableCapacityKey` read on a fresh URL (a reused
`NSURL` caches its values). The minimum working set is
`reserve + pins (64 MiB + 2 pieces) + max(256 MiB, 60 s) + inflight (max(32 MiB, 4 pieces)) + 240 s`
of the bitrate (the app's HLS copy: 180 s ahead, 60 s behind). The bitrate is
`fileSize / mediaDurationHint`, or `fileSize / 2 h` when the duration is unknown.
About 1.25 GiB for a 13 GB 2 h film, 2.6 GiB for a 60 GB 4K film at 7 MB/s.

## API (PTTorrentStreamer.h)

```objc
@property (atomic, copy, nullable) NSString *downloadDirectoryOverride; // set before starting
@property (atomic) BOOL allowsBoundedStorage;        // default YES (NO for PTTorrentDownload)
@property (atomic) int64_t storageReserve;           // default 512 MiB, never used
@property (atomic) int64_t storageBudget;            // torrent's share; 0 = automatic; any time
@property (atomic) NSTimeInterval mediaDurationHint; // seconds, 0 = unknown
@property (atomic, readonly) PTStorageMode storageMode;  // Undetermined / Full / Bounded
@property (atomic, readonly, getter=isStorageBounded) BOOL storageBounded;
@property (atomic) int64_t readPosition;             // setReadPosition: next byte the consumer needs
@property (atomic) int64_t consumedBefore;           // setConsumedBefore: bytes below are never read again
@property (atomic, readonly) int64_t lowestAvailableOffset; // block rewinds before it
@property (atomic, readonly) int64_t servedOffset;   // HTTP server's read position
- (int64_t)firstMissingOffsetFrom:(int64_t)fileOffset;
- (BOOL)isRangeAvailable:(int64_t)fileOffset length:(int64_t)length;
@property (atomic, readonly, getter=isFileComplete) BOOL fileComplete;
@property (atomic, readonly) int64_t bytesOnDisk;    // st_blocks of the file, fresh
@property (atomic, readonly) NSDictionary<NSString *, NSNumber *> *storageStatistics;
```

Everything else is unchanged and source-compatible (Mac app). Semantics that
changed on purpose:
- `fileSize` is the selected file's size (it was the whole torrent before the
  file priorities were applied).
- Bounded mode: `torrentStatus.totalProgress` is the share of the file
  downloaded once and reaches 1 only when the whole file is on disk;
  `totalDownloaded` only grows (freed pieces stay counted).
- `cancelStreamingAndDeleteData:` removes the torrent from the session (before:
  paused, and libtorrent's auto-manager could resume it). In bounded mode the
  data is always deleted.
- The HTTP server never serves bytes that are not on disk (see below).

Swift:

```swift
let streamer = PTTorrentStreamer()
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
// rewind policy:
if target < streamer.lowestAvailableOffset || !streamer.isRangeAvailable(target, length: 1) { /* block */ }
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
verified as written to the file (`lseek(SEEK_HOLE)` finds no hole in it after
libtorrent flushed its cache). The remux, which reads the file with a
`FileHandle`, must only read ranges for which `isRangeAvailable` is `YES`, and
must only release (`consumedBefore`) what it will never read again.

## How it works

### Window (PTBoundedLogic.cpp `planWindow`, applied in PTStreamController.mm `apply`)

Only pieces of the selected file are ever wanted (fixes the old
`prioritizeNextPieces`, which reset every piece of every file to priority 1).

| Pieces | Priority |
|---|---|
| other files | 0 |
| pinned head: up to the first MKV Cluster / end of the MP4 `moov` (parsed from the file, `parseHeadPins`), 32 MiB if unknown, at most 64 MiB; 64 MiB until parsed | 7 |
| pinned tail: last 2 pieces (+ an MP4 `moov` stored after `mdat`) | 7 |
| a piece the head parser waits for | 7 |
| window: `[read piece, +N)` with N ≥ 32 MiB | 7 |
| pieces an HTTP reader waits for ("urgent") | 7 |
| ahead of the reader | 1 (paced) |
| behind the reader, on disk | 1 |
| behind the reader, missing (skipped by a seek), bounded | 0 |
| consumed (below `consumedBefore` minus one guard piece), bounded | 0, then freed |
| freed | 0, forever |

Full mode keeps today's window: the next MIN_PIECES missing pieces at or after
the read position with 100 ms deadlines, every piece of the file wanted.

Piece priorities are compared with libtorrent's own on every update (not with a
cache): `prioritize_files()` takes a disk-thread round trip and then rewrites every
piece of the selected file to 7, after the first plan.

Bounded mode uses **no libtorrent deadlines**. While time-critical pieces exist,
libtorrent keeps a single normal request per peer and only asks time-critical
pieces due within about a second; in the offline tests a deadline window starved
for tens of seconds while pieces far ahead kept arriving. Priority 7 with
sequential download fetches the window first. While a piece the reader needs is
missing, pieces beyond the ahead budget are temporarily not wanted (priority 0,
back to 1 once it arrives), so a late piece cannot let the rest of the file fill
the disk. Since the late piece is still wanted, the torrent never "finishes"
early (libtorrent disconnects seeds when it finishes).

### Pace (`pace`)

`aheadBudget = storageBudget − pinned − kept behind − inflight` (at least
`minAhead`), and never more than the free space above the reserve allows. The
ahead bytes are measured on the real allocation (`st_blocks`), so partially
downloaded pieces and holes not punched yet count.

| Fill of the ahead budget | Download limit (`torrent::set_download_limit`) |
|---|---|
| < 75 % | unlimited |
| 75–100 % | 2× → 1× the consumption rate (≥ 64 KiB/s) |
| 100–112.5 % | 64 KiB/s floor |
| ≥ 112.5 % | 8 KiB/s |
| free < reserve | 8 KiB/s |
| reader waits for a piece | unlimited (64 KiB/s if free < reserve / 2) |

The session is never paused: peers stay connected.

### Freeing (`releasePieces`, `punch`)

For every consumed piece, on the network thread, in batches (32 MiB, a tick, or
the disk below the reserve):
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
   the file, rounded inward to 4 KiB (to the end of the file for the last piece).

Freed pieces are never downloaded again in this stream (the user's choice:
rewinding further back than what is on disk is blocked).

### Disk full

In bounded mode a `file_error_alert` with ENOSPC/EDQUOT does not end the stream:
the controller shrinks the ahead budget by 25 % (down to 50 %), drops on-disk
pieces farthest ahead of the reader (they are punched, then wanted again; never
pinned, never in the window) until the reserve is back, and calls
`set_upload_mode(false)` (libtorrent's reaction to ENOSPC is upload mode) once
free ≥ reserve / 2. The same drop runs whenever free < reserve / 2, once the
holes already queued have landed. The ahead budget never exceeds the free space
above the reserve, so dropped data is not fetched again until there is room.

### HTTP server (`PTGatedFileResponse`)

`GCDWebServerFileResponse` (zeros for missing data, one parked request at a
time) is replaced by a streamed response:
- each chunk (≤ 512 KiB) is read only from pieces on disk; a missing piece is
  waited for (no thread blocked), a freed one fails the response;
- a request that starts in freed data gets **410** at once; outside the file **416**;
- any number of concurrent requests;
- the streaming request (the "primary reader") drives `readPosition`; requests
  in the pinned head and tail (headers, indexes) never do; a new request becomes
  primary when the previous one has been silent for 2 s (a player's seek);
  pieces any reader waits for are fetched first;
- `servedOffset` is the primary reader's position.

### Cancel

`cancelStreamingAndDeleteData:` fails the waiting reads, closes the
controller's descriptor, unsets `auto_managed`, and calls
`session::remove_torrent` (with `delete_files` when deleting, never when another
session shares the files), then removes the directory as before.

### Other fork fixes

- `PTTorrentsSession addTorrent:` returns the handle (`return th;` was missing).
- Upstream d331ae80 (tvOS memory crash): no `alert_when_available` deadlines.
- The session is constructed with its settings (no split second of defaults).
- Finished torrents (full mode) are paused with `auto_managed` unset (no
  background seeding), and removed at cancel.
- The resume data path is taken from the alert (the torrent may be removed).
- `localizedString` falls back to the package's own `.lproj` (fr added).

## Statistics and tracing

`storageStatistics` keys: `bounded, fileSize, pieceLength, torrentBudget,
aheadBudget, aheadBytes, behindBytes, pinnedBytes, dataBytes, bytesOnDisk,
freeBytes, reserveBytes, readPosition, consumedBefore, lowestAvailableOffset,
servedOffset, headPinEnd, tailPinStart, everDownloaded, freedPieces,
droppedPieces, punchedBytes, punchErrors, diskFullEvents, fileErrors,
dontHaveSent, waitingReads, downloadLimit, paceState (0 open, 1 proportional,
2 floor, 3 trickle, 4 emergency), consumeRate`.

`PT_BOUNDED_DEBUG=1` in the environment (Xcode scheme) logs the controller's
state once a second: read position, piece states, ahead/budget, allocation,
pending holes, limit, peers (choked, snubbed, queues), waiting reads.

## Tests

Unit tests (pure logic, no network):

```
xcodebuild test -scheme PopcornTorrent -destination "platform=macOS,arch=arm64" -only-testing:PopcornTorrentLogicTests
```

Do not run the whole scheme: `PopcornTorrent-Tests` streams public torrents.

Offline end-to-end harness (`Tools/BoundedStorageHarness`): generates a file of
patterned pseudo-random data with an MKV head, a private torrent for it (no
trackers), seeds it from a libtorrent session on 127.0.0.1 and streams it with
`PTTorrentStreamer`, whose shared session is made loopback-only with
`+[PTTorrentsSession prepareSharedSessionForLoopbackTestingOnPort:]` (no DHT,
LSD, UPnP, NAT-PMP), into a fresh APFS sparse disk image:

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
one. Then it cancels and checks the space comes back. Options: `--ballast-mib N`
fills the volume with another file between 35 % and 55 % of the file.

### Results (Mac, 2026-11-10, 6 GiB file, 4 MiB pieces, 1536 pieces)

| Run | Volume | Result |
|---|---|---|
| bounded, 40 MB/s, 60 s pause, budget 2 GiB | 3 GiB image (2.79 GiB free) | 24/24: ready in 3.0 s; 6 GiB read, SHA-256 equal, 0 wrong bytes, 0 stall; on disk at most 2065 MiB, 1929–2065 MiB while 2.4 GiB went through; free never below 795 MiB (reserve 512); pause: +2 MiB in 64 s once the window was full; 1523 pieces freed, 5.95 GiB punched, 0 punch error, 2235 lt_donthave; freed range: 410 in 1 ms; freed piece rejected to the probe peer and withdrawn, kept piece served with real data; cancel: free back to 2860 MiB |
| full, same consumer | 8 GiB image | 13/13: ready in 3.5 s, whole file kept (6144 MiB), nothing freed, same hash, cancel gives the 6 GiB back |
| bounded + 900 MiB ballast (35–55 %) | 3 GiB image | 23/24: free fell to 205 MiB because of the ballast; far-ahead data dropped and fetched again (seed uploaded 1.09× the file); no ENOSPC, no stall, same hash. The pause check failed only because the pause fell inside the ballast window (+19 MiB in 23 s while refilling) |
| bounded + ballast keeping the volume full for 30 s | 3 GiB image | 22/24: 31 ENOSPC write errors handled as disk full, no failure, same hash, 27 s stall (the volume had no free byte for 30 s), cancel gives everything back. The probe peer was disconnected by libtorrent during upload mode, so its 2 checks could not run |

## Limits and open points

- tvOS on device is untested: `F_PUNCHHOLE` and `SEEK_HOLE` in the app sandbox,
  free-space keys, purging near a full disk, flash timings. `F_PUNCHHOLE` needs
  APFS; on another file system the punch fails (`punchErrors`) and the space is
  not given back.
- Real swarms are untested: many peers, slow peers, peers dropping us under the
  64 KiB/s floor.
- A rewind into a gap left by a forward seek (not freed, never downloaded) is
  downloaded on demand, but after the window reached the end of the file the
  torrent is "finished" and libtorrent has dropped its seeds: it waits for a
  reconnection. Use `isRangeAvailable` before allowing such a rewind.
- Fast resume is never saved in bounded mode, and the files are deleted at cancel.
- After a real ENOSPC, requests libtorrent cancelled when it entered upload mode
  stayed outstanding on the (libtorrent) seed until its request timeout: the
  reader waited about 35 s after space came back in the harness.
- The time-critical (deadline) path of libtorrent misbehaved with one very fast
  local seed (a window starved, cancels left requests outstanding until the
  request timeout); bounded mode avoids it, full mode keeps it as before.
