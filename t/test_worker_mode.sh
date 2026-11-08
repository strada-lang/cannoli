#!/bin/bash
# server.http = 0 with server.tickers = N: a background-job server. No
# listening socket, no request workers, N ticker processes calling
# cannoli_tick, each respawned if it dies, all stopped with the server.
CANNOLI_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$CANNOLI_DIR/cannoli"
STRADA="${STRADA:-strada}"
PORT=$(( 20000 + RANDOM % 20000 ))
TMP="$(mktemp -d)"
MPID=""
cleanup() { [ -n "$MPID" ] && kill -9 "$MPID" 2>/dev/null; pkill -9 -P "$MPID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

echo "=== Cannoli Worker Mode Tests ==="
[ -x "$BIN" ] || { echo "  FAIL: $BIN not built"; exit 1; }
cat > "$TMP/ticklib.strada" <<SRC
package main;
func cannoli_dispatch(scalar \$c) str { return "ok"; }
func cannoli_tick() void {
    my scalar \$fh = core::open("$TMP/ticks", "a");
    core::spew_fh(\$fh, core::getpid() . "\n");
    core::close(\$fh);
}
SRC
"$STRADA" --shared "$TMP/ticklib.strada" -o "$TMP/ticklib.so" > "$TMP/build.log" 2>&1 || { echo "  FAIL: build"; cat "$TMP/build.log"; exit 1; }
cat > "$TMP/c.conf" <<CONF
[server]
host = 127.0.0.1
port = $PORT
http = 0
tickers = 3
tick_interval = 1
[app]
library = $TMP/ticklib.so
CONF
"$BIN" --config "$TMP/c.conf" > "$TMP/server.log" 2>&1 &
MPID=$!
FAIL=0
sleep 3
echo "Testing nothing listens..."
if timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT" 2>/dev/null; then echo "  FAIL: port $PORT is open"; FAIL=1; else echo "  PASS"; fi
echo "Testing three tickers tick..."
N=$(sort -u "$TMP/ticks" 2>/dev/null | wc -l)
KIDS=$(pgrep -P "$MPID" | wc -l)
if [ "$N" -eq 3 ] && [ "$KIDS" -eq 3 ]; then echo "  PASS"; else echo "  FAIL: $N ticking pids, $KIDS children"; FAIL=1; fi
echo "Testing a dead ticker is replaced..."
VICTIM=$(sort -u "$TMP/ticks" | head -1); kill -9 "$VICTIM"; sleep 2.5
KIDS=$(pgrep -P "$MPID" | wc -l); N=$(sort -u "$TMP/ticks" | wc -l)
if [ "$KIDS" -eq 3 ] && [ "$N" -eq 4 ]; then echo "  PASS"; else echo "  FAIL: $KIDS children, $N pids seen"; FAIL=1; fi
echo "Testing shutdown..."
kill -INT "$MPID"
for _ in $(seq 1 100); do kill -0 "$MPID" 2>/dev/null || break; sleep 0.05; done
if kill -0 "$MPID" 2>/dev/null; then echo "  FAIL: still running"; FAIL=1; else MPID=""; echo "  PASS"; fi
if [ "$FAIL" -eq 0 ]; then echo "All worker mode tests passed!"; exit 0; fi
tail -20 "$TMP/server.log"; exit 1
