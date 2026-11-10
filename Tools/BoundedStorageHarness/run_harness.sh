#!/bin/zsh
# Runs BoundedStorageHarness against a fresh APFS sparse disk image.
#
#   run_harness.sh <harness binary> <bounded|full> <image size, e.g. 3g> <work dir> <mount point> [harness options]
#
# The source file and the torrent live in <work dir> (outside the image); the
# streamer writes into <mount point>/tmp/Downloads. The image is detached
# and deleted at the end. Everything stays on 127.0.0.1.
set -u
harness=$1; mode=$2; size=$3; work=$4; mountpoint=$5
shift 5
image="$work/volume-$mode.sparseimage"
mkdir -p "$work" "$mountpoint"
rm -f "$image"
hdiutil create -quiet -size "$size" -fs APFS -type SPARSE -volname "PTBounded" "$image" || exit 3
hdiutil attach -quiet -nobrowse -mountpoint "$mountpoint" "$image" || { rm -f "$image"; exit 3; }
mkdir -p "$mountpoint/tmp"
echo "volume: $(df -h "$mountpoint" | tail -1)"
"$harness" --mode "$mode" --workdir "$work" --volume "$mountpoint" "$@"
result=$?
hdiutil detach -quiet "$mountpoint" || hdiutil detach -quiet -force "$mountpoint"
rm -f "$image"
exit $result
