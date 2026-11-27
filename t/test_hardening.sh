#!/bin/bash
# Connection hardening against a 1-worker server with short timeouts:
# slowloris (headers and body), slow readers, request smuggling inputs,
# 100-continue, standard headers, trusted proxies, pid file.
# Usage: t/test_hardening.sh            (classic workers)
#        EXTRA="loop_workers = 1" t/test_hardening.sh
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for tool in curl python3 bc nc; do command -v $tool >/dev/null || { echo "SKIP: $tool not installed"; exit 0; }; done
BIN="${BIN:-$ROOT/cannoli}"
PORT=${PORT:-$(( 20000 + RANDOM % 20000 ))}
S="$(mktemp -d)"
cleanup() { [ -n "$MPID" ] && kill -9 "$MPID" 2>/dev/null; rm -rf "$S"; }
trap cleanup EXIT
cd $S
cat > hard.conf <<EOF
[server]
host = 127.0.0.1
port = $PORT
workers = 1
timeout = 2
header_timeout = 3
write_timeout = 2
body_min_rate = 1000
trusted_proxies = 127.0.0.1
pid_file = $S/cannoli.pid
$EXTRA
[headers]
X-Content-Type-Options = nosniff
EOF
$BIN --config hard.conf --demo > hard.log 2>&1 &
MPID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null http://127.0.0.1:$PORT/hello && break; sleep 0.1; done
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAILS=$((FAILS+1)); }
FAILS=0
trap "" PIPE

echo "pid file"
[ "$(cat cannoli.pid 2>/dev/null)" = "$MPID" ] && pass "pid file = master pid" || fail "pid file '$(cat cannoli.pid 2>/dev/null)' != $MPID"

echo "slowloris: header trickle bounded by header_timeout"
( trap "" PIPE; exec 3<>/dev/tcp/127.0.0.1/$PORT; printf 'GET / HTTP/1.1\r\n' >&3; for i in $(seq 1 8); do sleep 1; printf 'X: y\r\n' >&3 2>/dev/null || break; done; head -1 <&3 > $S/trickle.out ) &
TP=$!
sleep 0.3
T0=$(date +%s.%N); CODE=$(curl -s -m 15 -o /dev/null -w "%{http_code}" http://127.0.0.1:$PORT/hello); T1=$(date +%s.%N)
W=$(echo "$T1 - $T0" | bc)
[ "$CODE" = 200 ] && (( $(echo "$W < 5" | bc) )) && pass "concurrent request served after ${W}s" || fail "code=$CODE waited ${W}s"
wait $TP 2>/dev/null
grep -q "408" $S/trickle.out && pass "trickler got 408" || fail "trickler got: $(cat $S/trickle.out)"

echo "body trickle bounded by timeout + min rate"
( trap "" PIPE; exec 3<>/dev/tcp/127.0.0.1/$PORT; printf 'POST /submit HTTP/1.1\r\nHost: t\r\nContent-Length: 100000\r\n\r\n' >&3; for i in $(seq 1 10); do sleep 0.5; printf 'xxxxxxxxxx' >&3 2>/dev/null || break; done; head -1 <&3 > $S/btrickle.out ) &
TP=$!
sleep 0.3
T0=$(date +%s.%N); CODE=$(curl -s -m 15 -o /dev/null -w "%{http_code}" http://127.0.0.1:$PORT/hello); T1=$(date +%s.%N)
W=$(echo "$T1 - $T0" | bc)
[ "$CODE" = 200 ] && (( $(echo "$W < 4" | bc) )) && pass "concurrent request served after ${W}s" || fail "code=$CODE waited ${W}s"
wait $TP 2>/dev/null
grep -q "408" $S/btrickle.out && pass "body trickler got 408" || fail "body trickler got: $(cat $S/btrickle.out)"

echo "standard headers"
H=$(curl -s -D - -o /dev/null http://127.0.0.1:$PORT/hello | tr -d '\r')
echo "$H" | grep -q "^Date: .* GMT$" && pass "Date" || fail "no Date"
echo "$H" | grep -q "^X-Content-Type-Options: nosniff$" && pass "[headers] applied" || fail "no extra header"
echo "$H" | grep -q "^X-Request-Id: " && pass "X-Request-Id generated" || fail "no request id"

echo "trusted proxy"
H=$(curl -s -H "X-Forwarded-For: 1.2.3.4, 127.0.0.1" -H "X-Request-Id: abc-123" -D - -o /dev/null http://127.0.0.1:$PORT/hello | tr -d '\r')
echo "$H" | grep -q "^X-Request-Id: abc-123$" && pass "request id propagated from trusted proxy" || fail "request id: $(echo "$H" | grep -i request-id)"

echo "100-continue"
T0=$(date +%s.%N); OUT=$(head -c 3000 /dev/zero | tr '\0' a | curl -s -X POST --data-binary @- -o - http://127.0.0.1:$PORT/submit); T1=$(date +%s.%N)
W=$(echo "$T1 - $T0" | bc)
echo "$OUT" | grep -q '"body_length":"3000"' && (( $(echo "$W < 0.9" | bc) )) && pass "curl body sent without 1s Expect stall (${W}s)" || fail "out=$OUT w=$W"
R=$(printf 'POST /submit HTTP/1.1\r\nHost: t\r\nExpect: something\r\nContent-Length: 1\r\nConnection: close\r\n\r\nx' | timeout 3 nc 127.0.0.1 $PORT | head -1 | tr -d '\r')
[ "$R" = "HTTP/1.1 417 Expectation Failed" ] && pass "417 for unknown expectation" || fail "got $R"

echo "smuggling / strictness (expect 400)"
check400() {
  local name=$1 req=$2
  R=$(printf "$req" | timeout 3 nc 127.0.0.1 $PORT | head -1 | tr -d '\r')
  [ "$R" = "HTTP/1.1 400 Bad Request" ] && pass "$name" || fail "$name -> '$R'"
}
check400 "space before colon (CL)" 'POST /submit HTTP/1.1\r\nHost: t\r\nContent-Length : 5\r\n\r\nhello'
check400 "space before colon (TE)" 'POST /submit HTTP/1.1\r\nHost: t\r\nTransfer-Encoding : chunked\r\n\r\n0\r\n\r\n'
check400 "bare LF in header" 'GET /hello HTTP/1.1\r\nHost: t\r\nX: a\nTransfer-Encoding: chunked\r\n\r\n'
check400 "obs-fold" 'GET /hello HTTP/1.1\r\nHost: t\r\nX: a\r\n b\r\n\r\n'
check400 "duplicate Host" 'GET /hello HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n'
check400 "missing Host (1.1)" 'GET /hello HTTP/1.1\r\nX: y\r\n\r\n'
check400 "TE + CL" 'POST /submit HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\nContent-Length: 3\r\n\r\n0\r\n\r\n'
check400 "chunk-ext bare LF" 'POST /submit HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n2;\nxx\r\nhi\r\n0\r\n\r\n'
check400 "double space in request line" 'GET  /hello HTTP/1.1\r\nHost: t\r\n\r\n'
check400 "conflicting CL" 'POST /submit HTTP/1.1\r\nHost: t\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nxx'
R=$(printf 'GET /hello HTTP/1.0\r\n\r\n' | timeout 3 nc 127.0.0.1 $PORT | head -1 | tr -d '\r')
[ "$R" = "HTTP/1.1 200 OK" ] && pass "HTTP/1.0 without Host ok" || fail "1.0 -> $R"
R=$(printf 'GET http://example.com/hello HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n' | timeout 3 nc 127.0.0.1 $PORT | head -1 | tr -d '\r')
[ "$R" = "HTTP/1.1 200 OK" ] && pass "absolute-form target routed" || fail "absolute-form -> $R"
R=$(printf '\r\nGET /hello HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n' | timeout 3 nc 127.0.0.1 $PORT | head -1 | tr -d '\r')
[ "$R" = "HTTP/1.1 200 OK" ] && pass "leading CRLF ignored" || fail "leading CRLF -> $R"

echo "chunked decoding is linear"
python3 - $PORT <<'PY'
import socket, sys, time
port = int(sys.argv[1])
n = 200000
body = b"1\r\nx\r\n" * n + b"0\r\n\r\n"
s = socket.create_connection(("127.0.0.1", port))
t = time.time()
s.sendall(b"POST /submit HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
for i in range(0, len(body), 65536):
    s.sendall(body[i:i+65536])
data = b""
while True:
    d = s.recv(65536)
    if not d: break
    data += d
el = time.time() - t
ok = b'"body_length":"200000"' in data
print(("  PASS" if ok and el < 3 else "  FAIL") + ": 200000 one-byte chunks in %.2fs" % el)
PY

echo "pipelining after chunked body"
R=$(printf 'POST /submit HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\nX-T: 1\r\n\r\nGET /hello HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n' | timeout 3 nc 127.0.0.1 $PORT | grep -ao "HTTP/1.1 200" | wc -l)
[ "$R" = 2 ] && pass "two responses" || fail "got $R responses"

echo "slow reader bounded by write_timeout (static file the client never reads)"
mkdir -p www; head -c 50000000 /dev/zero > www/big.bin; echo hi > www/small.txt
SPORT=$((PORT + 1))
printf '[server]\nhost = 127.0.0.1\nport = %s\nworkers = 1\ntimeout = 2\nwrite_timeout = 2\n' $SPORT > static.conf
$BIN --config $S/static.conf --static $S/www > static.log 2>&1 &
SPID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null http://127.0.0.1:$SPORT/small.txt && break; sleep 0.1; done
python3 - $SPORT <<'PY'
import socket, sys, time
port = int(sys.argv[1])
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096); s.connect(("127.0.0.1", port))
s.sendall(b"GET /big.bin HTTP/1.1\r\nHost: t\r\n\r\n")
time.sleep(0.5)
t = time.time()
c = socket.create_connection(("127.0.0.1", port)); c.settimeout(20)
c.sendall(b"GET /small.txt HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n")
try:
    d = c.recv(100)
except Exception:
    d = b""
el = time.time() - t
ok = d.startswith(b"HTTP/1.1 200") and el < 10
print(("  PASS" if ok else "  FAIL") + ": concurrent request served after %.2fs while a client refused to read" % el)
sys.exit(0 if ok else 1)
PY
[ $? -eq 0 ] || FAILS=$((FAILS+1))
echo "large static files are streamed intact"
head -c 3000000 /dev/urandom > www/rand.bin
A=$(sha256sum < www/rand.bin | cut -c1-16); B=$(curl -s http://127.0.0.1:$SPORT/rand.bin | sha256sum | cut -c1-16)
[ "$A" = "$B" ] && pass "3MB file" || fail "3MB file checksum"
A=$(tail -c +1000001 www/rand.bin | head -c 1500000 | sha256sum | cut -c1-16); B=$(curl -s -r 1000000-2499999 http://127.0.0.1:$SPORT/rand.bin | sha256sum | cut -c1-16)
[ "$A" = "$B" ] && pass "streamed range" || fail "streamed range checksum"
C=$(curl -s -o /dev/null -w '%{http_code}' -H "If-Modified-Since: $(date -u -d '+1 day' '+%a, %d %b %Y %H:%M:%S GMT')" http://127.0.0.1:$SPORT/small.txt)
[ "$C" = 304 ] && pass "If-Modified-Since compared as a date" || fail "IMS -> $C"
echo "static compression"
python3 -c "print('compress me ' * 3000)" > www/app.js
cp www/app.js www/pre.css; gzip -9 -k www/pre.css; touch www/pre.css.gz
curl -s -D hdr.txt -o body.gz -H 'Accept-Encoding: gzip' http://127.0.0.1:$SPORT/app.js
grep -qi '^Content-Encoding: gzip' hdr.txt && gunzip -c body.gz | cmp -s - www/app.js && pass "gzip on the fly" || fail "on-the-fly gzip"
grep -qi '^Vary: Accept-Encoding' hdr.txt && pass "Vary: Accept-Encoding" || fail "no Vary"
curl -s -o body2.gz -H 'Accept-Encoding: gzip' http://127.0.0.1:$SPORT/pre.css
cmp -s body2.gz www/pre.css.gz && pass "precompressed .gz served" || fail "precompressed file not served"
H=$(curl -s -D - -o /dev/null -H 'Accept-Encoding: gzip;q=0' http://127.0.0.1:$SPORT/app.js | tr -d '\r')
echo "$H" | grep -qi '^Content-Encoding' && fail "gzip;q=0 ignored" || pass "gzip;q=0 respected"
kill -TERM $SPID 2>/dev/null; wait $SPID 2>/dev/null

echo "a library that throws costs one 500, not the worker"
printf 'func cannoli_dispatch(scalar $c) str {\n    if ($c->path() eq "/boom") { throw "kaboom"; }\n    if ($c->path() eq "/ok") { return "fine"; }\n    return "";\n}\n' > boom.strada
if strada --shared boom.strada -o boom.so > boom_build.log 2>&1; then
  LPORT=$((PORT + 2))
  $BIN -h 127.0.0.1 -p $LPORT -w 1 -l $S/boom.so > boom.log 2>&1 &
  LPID=$!
  for _ in $(seq 1 150); do curl -s -o /dev/null http://127.0.0.1:$LPORT/ok && break; sleep 0.1; done
  W1=$(pgrep -P $LPID)
  C1=$(curl -s -m 5 -o /dev/null -w "%{http_code}" http://127.0.0.1:$LPORT/boom)
  C2=$(curl -s -m 5 http://127.0.0.1:$LPORT/ok)
  W2=$(pgrep -P $LPID)
  [ "$C1" = 500 ] && [ "$C2" = fine ] && [ "$W1" = "$W2" ] && pass "500, same worker keeps serving" || fail "boom=$C1 ok=$C2 worker $W1 -> $W2"
  grep -q "kaboom" boom.log && pass "error logged" || fail "error not in log"
  kill -TERM $LPID 2>/dev/null; wait $LPID 2>/dev/null
else
  echo "  SKIP: could not build test library"
fi

echo "SIGTERM removes pid file"
kill -TERM $MPID; for _ in $(seq 1 100); do kill -0 $MPID 2>/dev/null || break; sleep 0.05; done
[ ! -e cannoli.pid ] && pass "pid file removed" || fail "pid file left behind"
kill -0 $MPID 2>/dev/null && fail "master still running after SIGTERM"
MPID=""
[ "$FAILS" -eq 0 ] && echo "All hardening integration tests passed!" || { echo "$FAILS failure(s)"; exit 1; }
