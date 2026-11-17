#!/bin/bash
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/cannoli"
PORT=$(( 20000 + RANDOM % 20000 ))
TMP="$(mktemp -d)"
MPID=""
cleanup() { [ -n "$MPID" ] && kill -TERM "$MPID" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

cat > "$TMP/c.conf" <<CONF
[server]
host = 127.0.0.1
port = $PORT
workers = 1
keep_alive = 0
CONF

"$BIN" --config "$TMP/c.conf" > "$TMP/server.log" 2>&1 &
MPID=$!
for _ in $(seq 1 100); do
    timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT" 2>/dev/null && break
    sleep 0.05
done

raw_status() {
    local request=$1
    timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT; printf '%b' \"$request\" >&3; IFS= read -r line <&3 || true; printf '%s\n' \"\$line\"" 2>/dev/null
}

echo "=== Cannoli Chunked Request Integration Tests ==="
VALID=$(raw_status 'POST / HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n')
echo "$VALID" | grep -Eq '^HTTP/1.1 404 '

CONFLICT=$(raw_status 'POST / HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: chunked\r\nContent-Length: 4\r\nConnection: close\r\n\r\n0\r\n\r\n')
echo "$CONFLICT" | grep -Eq '^HTTP/1.1 400 '

MALFORMED=$(raw_status 'POST / HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\nz\r\nnope\r\n')
echo "$MALFORMED" | grep -Eq '^HTTP/1.1 400 '

BADLINE=$(raw_status 'GARBAGE\r\n\r\n')
echo "$BADLINE" | grep -Eq '^HTTP/1.1 400 '

kill -TERM "$MPID"
wait "$MPID"
MPID=""

# Verify HEAD responses strip body on the wire while keeping Content-Length
"$BIN" --demo -h 127.0.0.1 -p "$PORT" -w 1 > "$TMP/demo.log" 2>&1 &
MPID=$!
for _ in $(seq 1 100); do
    timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT" 2>/dev/null && break
    sleep 0.05
done

HEAD_RESP=$(timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT; printf 'HEAD /hello HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n' >&3; cat <&3" 2>/dev/null | tr -d '\r')
echo "$HEAD_RESP" | grep -Eq '^HTTP/1.1 200 OK$'
echo "$HEAD_RESP" | grep -Eq '^Content-Length: 13$'
if echo "$HEAD_RESP" | grep -Eq 'Hello, World!'; then
    echo "FAIL: HEAD response included message body on the wire"
    exit 1
fi

kill -TERM "$MPID"
wait "$MPID"
MPID=""
echo "All chunked request integration tests passed!"
