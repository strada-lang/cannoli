#!/bin/bash
# Regression tests: prefork worker lifecycle (2026-11).
#  - respawn: workers that exit after max_requests must be replaced. The master
#    used core::waitpid's return value as a pid, but it is the exit STATUS (0
#    for a clean exit), so recycled workers were never respawned and the
#    server ran out of workers.
#  - shutdown: Ctrl-C/SIGTERM must not wait out the 30s timeout. The shutdown
#    loop made the same mistake and never saw its workers exit.
CANNOLI_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$CANNOLI_DIR/cannoli"
PORT=$(( 20000 + RANDOM % 20000 ))
TMP="$(mktemp -d)"
MPID=""
cleanup() { [ -n "$MPID" ] && kill -9 "$MPID" 2>/dev/null; pkill -9 -P "$MPID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

echo "=== Cannoli Lifecycle Tests ==="
[ -x "$BIN" ] || { echo "  FAIL: $BIN not built"; exit 1; }
cat > "$TMP/c.conf" <<CONF
[server]
host = 127.0.0.1
port = $PORT
workers = 2
max_requests = 2
keep_alive = 0
CONF

# One HTTP/1.0 request over bash's /dev/tcp; prints the status line.
req() {
    timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT && printf 'GET / HTTP/1.0\r\nHost: test\r\n\r\n' >&3 && head -1 <&3" 2>/dev/null
}

"$BIN" --config "$TMP/c.conf" > "$TMP/server.log" 2>&1 &
MPID=$!
for _ in $(seq 1 100); do req | grep -q HTTP && break; sleep 0.1; done

FAIL=0
echo "Testing workers are respawned after max_requests..."
OK=0
for _ in $(seq 1 20); do req | grep -q "^HTTP/" && OK=$((OK + 1)); done
sleep 0.5
WORKERS=$(pgrep -P "$MPID" | wc -l)
if [ "$OK" -eq 20 ] && [ "$WORKERS" -eq 2 ]; then
    echo "  PASS"
else
    echo "  FAIL: $OK/20 requests answered, $WORKERS/2 workers alive"
    FAIL=1
fi

echo "Testing shutdown does not wait out the timeout..."
START=$(date +%s%N)
kill -INT "$MPID"
for _ in $(seq 1 100); do kill -0 "$MPID" 2>/dev/null || break; sleep 0.05; done
if kill -0 "$MPID" 2>/dev/null; then
    echo "  FAIL: master still running 5s after SIGINT"
    FAIL=1
else
    MS=$(( ($(date +%s%N) - START) / 1000000 ))
    if pgrep -P "$MPID" >/dev/null 2>&1; then echo "  FAIL: workers left behind"; FAIL=1; else echo "  PASS (${MS}ms)"; fi
    MPID=""
fi

if [ "$FAIL" -eq 0 ]; then echo "All lifecycle tests passed!"; exit 0; fi
echo "--- server log"; tail -20 "$TMP/server.log"
exit 1
