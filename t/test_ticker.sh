#!/bin/bash
# The ticker: a library exporting cannoli_tick() gets one extra process
# that calls it every server.tick_interval seconds. It must keep ticking,
# be respawned if it dies, and stop with the server.
CANNOLI_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$CANNOLI_DIR/cannoli"
STRADA="${STRADA:-strada}"
PORT=$(( 20000 + RANDOM % 20000 ))
TMP="$(mktemp -d)"
MPID=""
cleanup() { [ -n "$MPID" ] && kill -9 "$MPID" 2>/dev/null; pkill -9 -P "$MPID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

echo "=== Cannoli Ticker Tests ==="
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
if ! "$STRADA" --shared "$TMP/ticklib.strada" -o "$TMP/ticklib.so" > "$TMP/build.log" 2>&1; then
    echo "  FAIL: could not build the test library"; cat "$TMP/build.log"; exit 1
fi
cat > "$TMP/c.conf" <<CONF
[server]
host = 127.0.0.1
port = $PORT
workers = 1
tick_interval = 1
[app]
library = $TMP/ticklib.so
CONF
"$BIN" --config "$TMP/c.conf" > "$TMP/server.log" 2>&1 &
MPID=$!
FAIL=0

echo "Testing the ticker calls cannoli_tick on schedule..."
sleep 3.5
N=$(wc -l < "$TMP/ticks" 2>/dev/null || echo 0)
if [ "$N" -ge 3 ] && [ "$N" -le 5 ]; then echo "  PASS ($N ticks in 3.5s)"; else echo "  FAIL: $N ticks in 3.5s"; FAIL=1; fi

echo "Testing a dead ticker is respawned..."
TPID=$(tail -1 "$TMP/ticks")
kill -9 "$TPID" 2>/dev/null
sleep 2.5
NEW=$(tail -1 "$TMP/ticks")
if [ -n "$NEW" ] && [ "$NEW" != "$TPID" ]; then echo "  PASS"; else echo "  FAIL: no new ticker (last pid $NEW)"; FAIL=1; fi

echo "Testing shutdown stops the ticker..."
kill -INT "$MPID"
for _ in $(seq 1 100); do kill -0 "$MPID" 2>/dev/null || break; sleep 0.05; done
if kill -0 "$MPID" 2>/dev/null || kill -0 "$NEW" 2>/dev/null; then echo "  FAIL: still running"; FAIL=1; else echo "  PASS"; MPID=""; fi

if [ "$FAIL" -eq 0 ]; then echo "All ticker tests passed!"; exit 0; fi
echo "--- server log"; tail -20 "$TMP/server.log"
exit 1
