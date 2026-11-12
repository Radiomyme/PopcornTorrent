#!/bin/zsh
# Runs NetworkBench offline, inside the localhost-only sandbox profile.
#
#   run_bench.sh <NetworkBench binary> <full|bounded|download> <work dir> <label> [bench options]
#
# The source file and its torrent are generated once in <work dir> (reused by later runs).
# full / download: the client writes into <work dir>/vol. bounded: into a fresh APFS sparse
# image of IMAGE_SIZE (default 1400m: a 1 GiB file does not fit with the 512 MiB reserve),
# detached and deleted at the end. Nothing leaves 127.0.0.1.
set -u
bench=$1; mode=$2; work=$3; label=$4
shift 4
here=${0:A:h}
profile=$here/../BoundedStorageHarness/localhost-only.sb
mkdir -p "$work"
if [[ $mode == bounded ]]; then
  image="$work/vol-$label.sparseimage"; volume="$work/mnt-$label"
  rm -f "$image"; mkdir -p "$volume"
  hdiutil create -quiet -size "${IMAGE_SIZE:-1400m}" -fs APFS -type SPARSE -volname "PTNet$label" "$image" || exit 3
  hdiutil attach -quiet -nobrowse -mountpoint "$volume" "$image" || { rm -f "$image"; exit 3; }
else
  volume="$work/vol"; mkdir -p "$volume"
fi
sandbox-exec -f "$profile" "$bench" --mode "$mode" --workdir "$work" --volume "$volume" --label "$label" "$@"
result=$?
if [[ $mode == bounded ]]; then
  hdiutil detach -quiet "$volume" || hdiutil detach -quiet -force "$volume"
  rm -f "$image"; rmdir "$volume" 2>/dev/null
fi
exit $result
