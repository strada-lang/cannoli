#!/bin/bash
# Malformed-request fuzzing against live classic and loop-worker servers:
# the server must keep answering and no worker may crash.
# CANNOLI_FUZZ_SECONDS (default 10) per mode.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${BIN:-$ROOT/cannoli}"
command -v python3 >/dev/null || { echo "SKIP: python3 not installed"; exit 0; }
SECS="${CANNOLI_FUZZ_SECONDS:-10}"
S="$(mktemp -d)"; MPID=""
cleanup() { [ -n "$MPID" ] && kill -9 "$MPID" 2>/dev/null; rm -rf "$S"; }
trap cleanup EXIT
FAILS=0
for LOOP in 0 1; do
  PORT=$(( 20000 + RANDOM % 20000 ))
  printf '[server]\nhost = 127.0.0.1\nport = %s\nworkers = 4\nloop_workers = %s\nheader_timeout = 3\ntimeout = 3\nmax_requests = 0\n' $PORT $LOOP > "$S/f.conf"
  "$BIN" --config "$S/f.conf" --demo > "$S/server.log" 2>&1 &
  MPID=$!
  for _ in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && break; sleep 0.1; done
  python3 "$ROOT/tools/fuzz_http.py" 127.0.0.1 $PORT "$SECS" $((LOOP + 1)) 16 || FAILS=$((FAILS+1))
  if grep -qE "respawning|Uncaught|Segmentation" "$S/server.log"; then
    echo "FAIL (loop=$LOOP): worker crashed:"; grep -E "respawning|Uncaught|Segmentation" "$S/server.log" | head -5; FAILS=$((FAILS+1))
  else
    echo "loop=$LOOP: no worker crashed"
  fi
  kill -TERM $MPID; wait $MPID 2>/dev/null; MPID=""
done
[ $FAILS -eq 0 ] && echo "All network fuzz tests passed!" || { echo "$FAILS failure(s)"; exit 1; }
