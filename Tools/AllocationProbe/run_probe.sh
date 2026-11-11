#!/bin/zsh
# Runs zerofill_probe in every mode on a fresh 3 GiB APFS sparse disk image (detached and deleted at the end).
#   zsh run_probe.sh [trials per mode, default 10] [work dir, default a new temporary directory]
# Measured on APFS (macOS 27.2, 2026-11, all runs of part 3): plain 33/88 RUNAWAY, fsync 0/38,
# pause 6/38 (the dirty data is written back on the kernel's schedule), presize + late 0/105.
#
# The tracer: clang -O1 -dynamiclib -o ptft.dylib ptft.c, then run a DEBUG app (not hardened) with
#   DYLD_INSERT_LIBRARIES=<path>/ptft.dylib PTFT_LOG=<trace file> PTFT_MATCH=<part of the torrent's path>
# (PTFT_SKIP_PRESIZE=1 swallows a growing ftruncate of the traced file; PTFT_READS=1 logs every read).
set -u
here=${0:A:h}
trials=${1:-10}
work=${2:-$(mktemp -d)}
mkdir -p $work
clang -O1 -o $work/zerofill_probe $here/zerofill_probe.c || exit 1
image=$work/probe.sparseimage; mountpoint=$work/volume
rm -f $image; mkdir -p $mountpoint
hdiutil create -quiet -size 3g -fs APFS -type SPARSE -volname ZeroFillProbe $image || exit 3
hdiutil attach -quiet -nobrowse -mountpoint $mountpoint $image || { rm -f $image; exit 3; }
for mode in plain fsync pause presize late; do
  $work/zerofill_probe $mountpoint $mode $trials | tail -1
done
echo "sparse image on the host after all modes: $(du -k $image | cut -f1) KiB (zeros really written)"
hdiutil detach -quiet $mountpoint || hdiutil detach -quiet -force $mountpoint
rm -f $image
