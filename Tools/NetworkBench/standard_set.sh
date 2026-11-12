#!/bin/zsh
# The NetworkBench standard set, offline (127.0.0.1 only, inside localhost-only.sb):
#
#   standard_set.sh <NetworkBench binary> <work dir> [label prefix]
#
# One run of each swarm; one RESULT line per run on stdout, the logs in <work dir>/logs.
#   s1      8 peers x 1.5 MB/s, RTT 30-100 ms: a stream (512 MiB) and an offline download
#   s1seek  the same stream read at 3 MB/s, a forward seek from 15 % to 90 % of the file
#   s2      6 peers x 6 MB/s, RTT 40-140 ms: a stream of 1 GiB
#   h       8 peers x 1.5 MB/s, RTT 1.2-1.5 s (distant peers, bloated uplinks): a download of
#           256 MiB. The request queue must cover a peer's round trip (request_queue_time):
#           at 1 s it never completed (13 % in 3 min)
#   x       4 near peers (40-100 ms) and 4 far ones (1.0-1.6 s), 1.5 MB/s each: a download
# Each run takes from 30 s to 2 min; the set about 7 min.
set -u
bench=$1; work=$2; prefix=${3:-std}
here=${0:A:h}
mkdir -p "$work/logs"
S1="30:1.5,40:1.5,50:1.5,60:1.5,70:1.5,80:1.5,90:1.5,100:1.5"
S2="40:6,60:6,80:6,100:6,120:6,140:6"
H="1200:1.5,1300:1.5,1400:1.5,1500:1.5,1200:1.5,1300:1.5,1400:1.5,1500:1.5"
X="40:1.5,60:1.5,80:1.5,100:1.5,1000:1.5,1200:1.5,1400:1.5,1600:1.5"
run() {
  local label=$prefix-$1; shift
  zsh "$here/run_bench.sh" "$bench" "$@" > "$work/logs/$label.log" 2>&1
  echo "$label $(grep RESULT "$work/logs/$label.log" | sed 's/.*RESULT //')"
}
run s1-full     full     "$work" $prefix-s1-full     --size-mib 512 --peers $S1 --timeout 300
run s1-download download "$work" $prefix-s1-download --size-mib 512 --peers $S1 --timeout 300
run s1seek      full     "$work" $prefix-s1seek      --size-mib 512 --peers $S1 --read-mbs 3 --seek-at 0.15 --seek-to 0.9 --read-mib 490 --timeout 300
run s2-full     full     "$work" $prefix-s2-full     --size-mib 1024 --peers $S2 --timeout 300
run h-download  download "$work" $prefix-h-download  --size-mib 256 --peers $H --timeout 300
run x-download  download "$work" $prefix-x-download  --size-mib 256 --peers $X --timeout 300
