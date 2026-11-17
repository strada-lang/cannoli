#!/bin/bash
# Soak test: sustained load against classic and loop workers with worker
# recycling disabled (max_requests = 0), sampling each worker's RSS every
# 10s. Reports failed requests and memory growth per mode.
#   tools/soak.sh [SECONDS_PER_MODE=120] [CONCURRENCY=32]
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${BIN:-$ROOT/cannoli}"
SECS="${1:-120}"; CONC="${2:-32}"
command -v ab >/dev/null || { echo "soak.sh needs ab (apache2-utils)"; exit 1; }
S="$(mktemp -d)"; MPID=""
cleanup() { [ -n "$MPID" ] && kill -9 "$MPID" 2>/dev/null; rm -rf "$S"; }
trap cleanup EXIT
rss_kb() { local t=0; for p in $(pgrep -P "$1"); do t=$((t + $(awk '/VmRSS/{print $2}' /proc/$p/status 2>/dev/null || echo 0))); done; echo $t; }
STATUS=0
for LOOP in 0 1; do
  PORT=$(( 20000 + RANDOM % 20000 ))
  printf '[server]\nhost = 127.0.0.1\nport = %s\nworkers = 4\nloop_workers = %s\nmax_requests = 0\nkeep_alive_timeout = 2\n[admin]\nenabled = 1\n' $PORT $LOOP > "$S/soak.conf"
  "$BIN" --config "$S/soak.conf" --demo > "$S/server.log" 2>&1 &
  MPID=$!
  for _ in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && break; sleep 0.1; done
  ab -q -n 2000 -c 8 http://127.0.0.1:$PORT/json >/dev/null 2>&1    # warm up
  START=$(rss_kb $MPID)
  END_T=$(( $(date +%s) + SECS ))
  ROUNDS=0; FAILED=0; SAMPLES="$START"
  while [ "$(date +%s)" -lt "$END_T" ]; do
    for URL in /json /hello "/echo?message=soak" /headers; do
      F=$(ab -q -t 2 -n 1000000 -c "$CONC" "http://127.0.0.1:$PORT$URL" 2>/dev/null | awk '/^Failed requests/{print $3}')
      FAILED=$((FAILED + ${F:-0}))
    done
    F=$(ab -q -k -t 2 -n 1000000 -c 4 http://127.0.0.1:$PORT/json 2>/dev/null | awk '/^Failed requests/{print $3}')
    FAILED=$((FAILED + ${F:-0}))
    ROUNDS=$((ROUNDS + 1))
    SAMPLES="$SAMPLES $(rss_kb $MPID)"
  done
  END=$(rss_kb $MPID)
  REQS=$(curl -s http://127.0.0.1:$PORT/__admin/metrics | awk '/^cannoli_request_duration_seconds_count/{print $2}')
  CRASH=$(grep -cE "respawning|Uncaught" "$S/server.log")
  echo "loop=$LOOP: ${REQS} requests in ${SECS}s, ${FAILED} failed (ab), ${CRASH} worker crashes"
  echo "  worker RSS (KB, 4 workers): start ${START} -> end ${END}; samples: ${SAMPLES}"
  GROW=$(( END - START ))
  if [ "$CRASH" -gt 0 ] || [ "$GROW" -gt $(( START / 2 + 8192 )) ]; then STATUS=1; echo "  WARNING: crash or memory growth"; fi
  kill -TERM $MPID; wait $MPID 2>/dev/null; MPID=""
done
exit $STATUS
