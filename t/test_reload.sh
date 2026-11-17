#!/bin/bash
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/cannoli"
PORT=$(( 20000 + RANDOM % 20000 ))
TMP="$(mktemp -d)"
MPID=""
cleanup() {
    [ -n "$MPID" ] && kill -9 "$MPID" 2>/dev/null || true
    [ -n "$MPID" ] && pkill -9 -P "$MPID" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

cat > "$TMP/c.conf" <<CONF
[server]
host = 127.0.0.1
port = $PORT
workers = 2
max_requests = 10000
keep_alive = 0
CONF

req() {
    timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT && printf 'GET / HTTP/1.0\r\nHost: test\r\n\r\n' >&3 && head -1 <&3" 2>/dev/null
}

echo "=== Cannoli SIGHUP Reload Tests ==="
"$BIN" --config "$TMP/c.conf" > "$TMP/server.log" 2>&1 &
MPID=$!
for _ in $(seq 1 100); do req | grep -Eq '^HTTP/' && break; sleep 0.05; done

mapfile -t OLD < <(pgrep -P "$MPID" | sort -n)
if [ "${#OLD[@]}" -ne 2 ]; then
    echo "FAIL: expected 2 initial workers, found ${#OLD[@]}"
    exit 1
fi

kill -HUP "$MPID"

OK=0
for _ in $(seq 1 200); do
    req | grep -Eq '^HTTP/' && OK=$((OK + 1)) || true
    mapfile -t NOW < <(pgrep -P "$MPID" | sort -n)
    OLD_ALIVE=0
    for old in "${OLD[@]}"; do
        for now in "${NOW[@]}"; do [ "$old" = "$now" ] && OLD_ALIVE=1; done
    done
    [ "${#NOW[@]}" -eq 2 ] && [ "$OLD_ALIVE" -eq 0 ] && break
    sleep 0.025
done

mapfile -t NEW < <(pgrep -P "$MPID" | sort -n)
if [ "${#NEW[@]}" -ne 2 ]; then
    echo "FAIL: expected 2 replacement workers, found ${#NEW[@]}"
    tail -40 "$TMP/server.log"
    exit 1
fi
for old in "${OLD[@]}"; do
    for new in "${NEW[@]}"; do
        if [ "$old" = "$new" ]; then
            echo "FAIL: old worker $old was not replaced"
            exit 1
        fi
    done
done
if [ "$OK" -lt 1 ]; then
    echo "FAIL: no requests succeeded during rotation"
    exit 1
fi

kill -TERM "$MPID"
for _ in $(seq 1 100); do kill -0 "$MPID" 2>/dev/null || break; sleep 0.05; done
if kill -0 "$MPID" 2>/dev/null; then
    echo "FAIL: master did not stop"
    exit 1
fi
MPID=""

echo "All SIGHUP reload tests passed!"
