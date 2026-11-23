#!/bin/bash
# Live tests for the fixes from the code review: what a library's return
# value may do, the stuck-worker watchdog, streaming to a client that stops
# reading, keep-alive fairness, logging of rejected requests, equivalent
# path spellings and inline config comments.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${BIN:-$ROOT/cannoli}"
STRADA="${STRADA:-strada}"
for tool in curl python3 nc; do command -v $tool >/dev/null || { echo "SKIP: $tool not installed"; exit 0; }; done
P=$(( 20000 + RANDOM % 20000 ))
S="$(mktemp -d)"
stop() { for pid in $(ss -ltnpH "sport = :$1" 2>/dev/null | grep -o "pid=[0-9]*" | cut -d= -f2 | sort -u); do kill -9 "$pid" 2>/dev/null; done; }
cleanup() { for port in $P $((P+1)) $((P+2)) $((P+3)) $((P+4)); do stop $port; done; rm -rf "$S"; }
trap cleanup EXIT
trap "" PIPE
FAILS=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAILS=$((FAILS+1)); }
wait_up() { for _ in $(seq 1 60); do curl -s -o /dev/null "http://127.0.0.1:$1/up" && return 0; sleep 0.1; done; return 1; }

cat > "$S/lib.strada" <<'LIB'
func cannoli_dispatch(scalar $c) str {
    my str $p = $c->path();
    if ($p eq "/up") { return "up"; }
    if ($p eq "/echo") { return $c->param("q"); }
    if ($p eq "/c-json") { $c->status(201); $c->render_json({"ok" => 1}); return $c->done(); }
    if ($p eq "/c-redirect") { $c->redirect("/next", 0); return $c->done(); }
    if ($p eq "/c-html") { $c->content_type("text/html"); return "<b>page</b>"; }
    if ($p eq "/c-cookies") { $c->set_cookie("a", "1", ""); $c->set_cookie("b", "2", ""); $c->render_text("ok"); return $c->done(); }
    if ($p eq "/c-empty") { $c->status(204); return $c->done(); }
    if ($p eq "/framed") { return $c->framed_response("RESPONSE:202:10:X-Lib:yes\n:framed body"); }
    if ($p eq "/body") {
        my str $f = $c->body_file();
        my int $fsz = 0;
        if (length($f) > 0) { my hash %st = core::stat($f); $fsz = $st{"size"}; }
        my int $sum = 0;
        my str $b = $c->body();
        my int $n = core::byte_length($b);
        my int $k = 0;
        while ($k < $n) { $sum = $sum + (core::get_byte($b, $k) % 256); $k = $k + 4099; }
        return "mem=" . $n . " sum=" . $sum . " file=" . $fsz . " path=" . $f;
    }
    if ($p eq "/hang") { core::sleep(600); return "late"; }
    if ($p eq "/slow") { core::sleep(6); return "slow done"; }
    if ($p eq "/stream") {
        $c->content_type("text/plain");
        $c->start_chunked();
        my int $i = 0;
        my str $block = "0123456789012345678901234567890123456789012345678901234567890123456789\n" x 200;
        while ($i < 4000) { if ($c->write_chunk($block) < 0) { last; } $i = $i + 1; }
        $c->end_chunked();
        return $c->done();
    }
    if ($p eq "/stream-small") {
        $c->content_type("text/plain");
        $c->start_chunked();
        $c->write_chunk("part one\n");
        $c->write_chunk("part two\n");
        $c->end_chunked();
        return $c->done();
    }
    return "";
}
LIB
( cd "$S" && "$STRADA" --shared lib.strada -o lib.so >/dev/null 2>&1 ) || { echo "SKIP: could not build the test library"; exit 0; }
U="http://127.0.0.1:$P"

cat > "$S/a.conf" <<CONF
[server]
host = 127.0.0.1   # loopback only
port = $P          # inline comment
workers = 2
handler_timeout = 2
[log]
access_file = $S/access.log    # rejected requests land here too
[headers]
X-Marker = a#b   # the value keeps its own hash sign
CONF
"$BIN" -t -c "$S/a.conf" > "$S/t.log" 2>&1 && pass "config with inline comments validates" || fail "config rejected: $(cat "$S/t.log")"
"$BIN" -c "$S/a.conf" -l "$S/lib.so" > "$S/server.log" 2>&1 &
disown
wait_up $P || { fail "server did not start: $(tail -5 "$S/server.log")"; echo "$FAILS failure(s)"; exit 1; }

echo "library return values"
hdrs() { curl -s -m 5 -D - -o "$S/body" "$1" | tr -d '\r'; }
H=$(hdrs "$U/echo?q=REDIRECT:https://evil.example/")
echo "$H" | grep -q "^HTTP/1.1 200" && ! echo "$H" | grep -qi "^location:" && [ "$(cat "$S/body")" = "REDIRECT:https://evil.example/" ] \
  && pass "an echoed REDIRECT: is text, not a redirect" || fail "echoed REDIRECT: -> $(echo "$H" | head -3 | tr '\n' ' ')"
H=$(hdrs "$U/echo?q=STATUS:500:boom")
echo "$H" | grep -q "^HTTP/1.1 200" && pass "an echoed STATUS: does not set the status" || fail "echoed STATUS: -> $(echo "$H" | head -1)"
H=$(hdrs "$U/echo?q=RESPONSE:200:18:Set-Cookie:admin=1:hi")
! echo "$H" | grep -qi "^set-cookie" && pass "an echoed RESPONSE: adds no headers" || fail "echoed RESPONSE: set a cookie"
H=$(hdrs "$U/echo?q=%3Cscript%3Ealert(1)%3C/script%3E")
echo "$H" | grep -qi "^content-type: text/plain" && echo "$H" | grep -qi "^x-content-type-options: nosniff" \
  && pass "an echoed <script> is text/plain + nosniff" || fail "echoed <script> -> $(echo "$H" | grep -i content-type)"
H=$(hdrs "$U/echo?q=%7B%22a%22:1%7D")
echo "$H" | grep -qi "^content-type: application/json" && pass "a returned JSON document is application/json" || fail "JSON -> $(echo "$H" | grep -i content-type)"
H=$(hdrs "$U/c-json")
echo "$H" | grep -q "^HTTP/1.1 201" && echo "$H" | grep -qi "^content-type: application/json" && grep -q '"ok":1' "$S/body" \
  && pass "response set on \$c (status, type, body)" || fail "\$c response -> $(echo "$H" | head -2 | tr '\n' ' ') $(cat "$S/body")"
H=$(hdrs "$U/c-redirect")
echo "$H" | grep -q "^HTTP/1.1 302" && echo "$H" | grep -qi "^location: /next" && pass "\$c->redirect" || fail "\$c->redirect -> $(echo "$H" | head -1)"
H=$(hdrs "$U/c-html")
echo "$H" | grep -qi "^content-type: text/html" && [ "$(cat "$S/body")" = "<b>page</b>" ] && pass "content type on \$c + returned body" || fail "c-html -> $(echo "$H" | grep -i content-type) $(cat "$S/body")"
H=$(hdrs "$U/c-cookies")
[ "$(echo "$H" | grep -ci "^set-cookie:")" = 2 ] && pass "two Set-Cookie headers" || fail "cookies -> $(echo "$H" | grep -i set-cookie | tr '\n' ' ')"
H=$(hdrs "$U/c-empty")
echo "$H" | grep -q "^HTTP/1.1 204" && [ ! -s "$S/body" ] && pass "204 with no body" || fail "c-empty -> $(echo "$H" | head -1)"
H=$(hdrs "$U/framed")
echo "$H" | grep -q "^HTTP/1.1 202" && echo "$H" | grep -qi "^x-lib: yes" && [ "$(cat "$S/body")" = "framed body" ] && pass "\$c->framed_response" || fail "framed -> $(echo "$H" | head -1) $(cat "$S/body")"
echo "$H" | grep -q "^X-Marker: a#b$" && pass "[headers] value keeps its # (comment after it dropped)" || fail "X-Marker: $(echo "$H" | grep -i x-marker)"

echo "equivalent path spellings"
for p in //echo /./echo /x/../echo /%65cho; do
  C=$(curl -s -m 5 -o /dev/null -w '%{http_code}' --path-as-is "$U$p?q=hi")
  [ "$C" = 200 ] && pass "$p routes like /echo" || fail "$p -> $C"
done
for p in /echo/ "/echo%3Fq=1" "/ech%6F%2Fx"; do
  C=$(curl -s -m 5 -o /dev/null -w '%{http_code}' --path-as-is "$U$p")
  [ "$C" = 404 ] && pass "$p stays a different path" || fail "$p -> $C"
done

echo "rejected requests are logged"
R=$(printf 'GET / HTTP/1.1\r\nHost : x\r\n\r\n' | timeout 3 nc 127.0.0.1 $P | head -1 | tr -d '\r')
sleep 0.3
[ "$R" = "HTTP/1.1 400 Bad Request" ] && grep -q '" 400 ' "$S/access.log" && pass "400 in the access log: $(grep '" 400 ' "$S/access.log" | tail -1 | cut -c1-90)" || fail "400 not logged ($R)"
grep -q "rejected request from 127.0.0.1" "$S/server.log" && pass "and in the error log" || fail "no error-log line for the rejected request"

echo "stuck handler (2 workers, handler_timeout 2s)"
curl -s -m 20 -o /dev/null "$U/hang" & H1=$!
curl -s -m 20 -o /dev/null "$U/hang" & H2=$!
sleep 0.5
T0=$(date +%s)
C=$(curl -s -m 15 -o /dev/null -w '%{http_code}' "$U/echo?q=hi")
T1=$(date +%s)
[ "$C" = 200 ] && [ $((T1 - T0)) -le 8 ] && pass "a third request is served after $((T1 - T0))s (both workers were stuck)" || fail "third request -> $C after $((T1 - T0))s"
grep -q "made no progress for 2s" "$S/server.log" && pass "the master logged and replaced the stuck workers" || fail "no watchdog message in the log"
wait $H1 $H2 2>/dev/null
sleep 1
C=$(curl -s -m 15 "$U/slow")
[ "$C" = "slow done" ] && fail "a 6s handler outlived handler_timeout=2" || pass "a handler slower than handler_timeout is cut off"
stop $P

echo "streaming to a client that stops reading (loop worker)"
cat > "$S/b.conf" <<CONF
[server]
host = 127.0.0.1
port = $((P+1))
workers = 1
loop_workers = 1
write_timeout = 2
CONF
"$BIN" -c "$S/b.conf" -l "$S/lib.so" > "$S/server2.log" 2>&1 &
disown
wait_up $((P+1)) || fail "loop server did not start"
python3 - $((P+1)) <<'PY' > "$S/stream.out" 2>&1
import socket, sys, time
port = int(sys.argv[1])
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096); s.connect(("127.0.0.1", port))
s.sendall(b"GET /stream HTTP/1.1\r\nHost: x\r\n\r\n")
time.sleep(1.0)
t = time.time()
c = socket.create_connection(("127.0.0.1", port)); c.settimeout(5)
c.sendall(b"GET /echo?q=hi HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
try:
    d = c.recv(200)
    print("ANSWERED %.2f" % (time.time() - t) if d.startswith(b"HTTP/1.1 200") else "BAD %r" % d[:40])
except Exception as e:
    print("BLOCKED", e)
# the stalled stream itself must be dropped after write_timeout
time.sleep(4)
s.settimeout(10)
total = 0
try:
    while True:
        d = s.recv(65536)
        if not d: break
        total += len(d)
    print("STREAM_CLOSED", total)
except Exception as e:
    print("STREAM_OPEN", e)
PY
grep -q "^ANSWERED" "$S/stream.out" && pass "another request is served while the stream is stalled ($(grep ANSWERED "$S/stream.out" | cut -d' ' -f2)s)" || fail "worker blocked by the stalled stream: $(cat "$S/stream.out")"
grep -q "^STREAM_CLOSED" "$S/stream.out" && pass "the stalled stream was closed after write_timeout" || fail "stalled stream still open: $(cat "$S/stream.out")"
H=$(curl -s -m 5 -D - "http://127.0.0.1:$((P+1))/stream-small" | tr -d '\r')
echo "$H" | grep -qi "^date:" && echo "$H" | grep -qi "^x-request-id:" && echo "$H" | grep -q "^part two$" && pass "a streamed response has Date and X-Request-Id" || fail "streamed headers: $(echo "$H" | head -6 | tr '\n' ' ')"
stop $((P+1))

echo "streaming in a classic worker"
"$BIN" -h 127.0.0.1 -p $((P+2)) -w 1 -l "$S/lib.so" > "$S/server3.log" 2>&1 &
disown
wait_up $((P+2)) || fail "classic server did not start"
N=$(curl -s -m 20 "http://127.0.0.1:$((P+2))/stream" | wc -c)
[ "$N" = 56800000 ] && pass "a 56 MB stream arrives complete" || fail "stream length $N"
stop $((P+2))

echo "streaming over TLS"
if command -v openssl >/dev/null; then
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$S/key.pem" -out "$S/cert.pem" -days 2 -subj /CN=localhost >/dev/null 2>&1
  for mode in classic loop; do
    stop $((P+2))
    printf '[server]\nhost = 127.0.0.1\nport = %s\nworkers = 1\nloop_workers = %s\nwrite_timeout = 2\n[ssl]\nenabled = 1\nonly = 1\nport = %s\ncert = %s\nkey = %s\n' \
      $((P+3)) $([ $mode = loop ] && echo 1 || echo 0) $((P+2)) "$S/cert.pem" "$S/key.pem" > "$S/tls.conf"
    "$BIN" -c "$S/tls.conf" -l "$S/lib.so" > "$S/server_tls.log" 2>&1 &
    disown
    for _ in $(seq 1 60); do curl -sk -o /dev/null "https://127.0.0.1:$((P+2))/up" && break; sleep 0.1; done
    N=$(curl -sk -m 30 "https://127.0.0.1:$((P+2))/stream" | wc -c)
    [ "$N" = 56800000 ] && pass "$mode worker: a 56 MB stream arrives complete over TLS" || fail "$mode worker: TLS stream length $N"
    H=$(curl -sk -m 5 -D - "https://127.0.0.1:$((P+2))/stream-small" | tr -d '\r')
    echo "$H" | grep -qi "^date:" && echo "$H" | grep -q "^part two$" && pass "$mode worker: small TLS stream with standard headers" || fail "$mode worker: small TLS stream: $(echo "$H" | head -4 | tr '\n' ' ')"
    # a TLS client that stops reading must not hold the stream open forever
    R=$(python3 - $((P+2)) <<'PY'
import socket, ssl, sys, time
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
raw = socket.socket(); raw.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096); raw.connect(("127.0.0.1", int(sys.argv[1])))
s = ctx.wrap_socket(raw)
s.sendall(b"GET /stream HTTP/1.1\r\nHost: x\r\n\r\n")
time.sleep(5)
s.settimeout(10); total = 0
try:
    while True:
        d = s.recv(65536)
        if not d: break
        total += len(d)
    print("CLOSED")
except ssl.SSLError: print("CLOSED")
except ConnectionError: print("CLOSED")
except Exception as e: print("OPEN", type(e).__name__)
PY
)
    [ "$R" = CLOSED ] && pass "$mode worker: a stalled TLS stream is dropped after write_timeout" || fail "$mode worker: stalled TLS stream: $R"
    C=$(curl -sk -m 5 -o /dev/null -w '%{http_code}' "https://127.0.0.1:$((P+2))/echo?q=hi")
    [ "$C" = 200 ] && pass "$mode worker: still serving afterwards" || fail "$mode worker: after the stalled stream -> $C"
  done
  stop $((P+2))
else
  echo "  SKIP: openssl not installed"
fi

echo "idle connections"
printf '[server]\nhost = 127.0.0.1\nport = %s\nworkers = 1\nheader_timeout = 1\ntimeout = 1\n' $((P+2)) > "$S/idle.conf"
"$BIN" -c "$S/idle.conf" -l "$S/lib.so" > "$S/server_idle.log" 2>&1 &
disown
wait_up $((P+2)) || fail "idle-test server did not start"
( exec 3<>/dev/tcp/127.0.0.1/$((P+2)); sleep 3 ) 2>/dev/null
sleep 0.3
N=$(grep -c "rejected request" "$S/server_idle.log")
[ "$N" = 0 ] && pass "a connection that sends nothing is closed without an error-log line" || fail "idle connection logged $N rejection(s): $(grep 'rejected request' "$S/server_idle.log" | head -1)"
( exec 3<>/dev/tcp/127.0.0.1/$((P+2)); printf 'GET /up HTTP/1.1\r\nHost: x\r\n' >&3; sleep 3 ) 2>/dev/null
sleep 0.3
N=$(grep -c "rejected request.*timeout" "$S/server_idle.log")
[ "$N" = 1 ] && pass "a request that stalls half-way is logged as a timeout" || fail "stalled request logged $N time(s)"
stop $((P+2))

echo "large request bodies are spooled to disk"
head -c 3000000 /dev/urandom > "$S/big.bin"
WANT=$(python3 -c "
import sys
d = open(sys.argv[1], 'rb').read()
print(sum(d[i] for i in range(0, len(d), 4099)))" "$S/big.bin")
mkdir -p "$S/spool"
for inmem in 1 0; do
  stop $((P+2))
  printf '[server]\nhost = 127.0.0.1\nport = %s\nworkers = 1\nmax_body_size = 8000000\nbody_spool_size = 100000\nbody_spool_dir = %s\nbody_in_memory = %s\n' $((P+2)) "$S/spool" $inmem > "$S/spool.conf"
  "$BIN" -c "$S/spool.conf" -l "$S/lib.so" > "$S/server_spool.log" 2>&1 &
  disown
  wait_up $((P+2)) || fail "spool server did not start"
  R=$(curl -s -m 20 --data-binary @"$S/big.bin" -H "Content-Type: application/octet-stream" "http://127.0.0.1:$((P+2))/body")
  if [ $inmem = 1 ]; then
    [ "$R" = "mem=3000000 sum=$WANT file=0 path=" ] && pass "3 MB body spooled, then given to the handler intact" || fail "spooled body (in memory): $R (want sum=$WANT)"
  else
    echo "$R" | grep -q "^mem=0 sum=0 file=3000000 path=$S/spool/cannoli-body-" && pass "body_in_memory = 0: the handler gets a 3 MB file and no body in memory" || fail "spooled body (file): $R"
  fi
  sleep 0.2
  [ -z "$(ls "$S/spool")" ] && pass "the spool file is removed after the request" || fail "spool files left: $(ls "$S/spool")"
  R=$(curl -s -m 5 -d "small=1" "http://127.0.0.1:$((P+2))/body")
  echo "$R" | grep -q "^mem=7 .* file=0 path=$" && pass "a small body stays in memory" || fail "small body: $R"
  # two requests on one connection: bytes after a spooled body belong to the next request
  R=$(python3 - $((P+2)) "$S/big.bin" <<'PY'
import socket, sys
body = open(sys.argv[2], "rb").read()[:400000]
s = socket.create_connection(("127.0.0.1", int(sys.argv[1]))); s.settimeout(10)
s.sendall(b"POST /body HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n" % len(body) + body + b"GET /echo?q=second HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
out = b""
try:
    while True:
        d = s.recv(65536)
        if not d: break
        out += d
except Exception: pass
print(out.count(b"HTTP/1.1 200"), b"second" in out)
PY
)
  [ "$R" = "2 True" ] && pass "a pipelined request after a spooled body is served" || fail "pipelined after spool: $R"
  # a client that stops half-way leaves no file behind
  ( exec 3<>/dev/tcp/127.0.0.1/$((P+2)); printf 'POST /body HTTP/1.1\r\nHost: x\r\nContent-Length: 2000000\r\n\r\n' >&3; head -c 300000 /dev/zero >&3; sleep 0.5 ) 2>/dev/null
  sleep 0.5
  [ -z "$(ls "$S/spool")" ] && pass "an abandoned upload leaves no spool file" || fail "spool file left by an abandoned upload"
done
stop $((P+2))

echo "the example library"
if ( cd "$ROOT" && "$STRADA" --shared examples/myapp.strada -o "$S/myapp.so" >"$S/myapp.build" 2>&1 ); then
  "$BIN" -h 127.0.0.1 -p $((P+2)) -w 1 -l "$S/myapp.so:greeting=Ciao" > "$S/server_ex.log" 2>&1 &
  disown
  for _ in $(seq 1 60); do curl -s -o /dev/null "http://127.0.0.1:$((P+2))/" && break; sleep 0.1; done
  E="http://127.0.0.1:$((P+2))"
  [ "$(curl -s -m 5 "$E/hello?name=Ada")" = "Ciao, Ada!" ] && pass "text route and init option" || fail "example /hello: $(curl -s -m 5 "$E/hello?name=Ada")"
  curl -s -m 5 -D - "$E/" | tr -d '\r' | grep -qi "^content-type: text/html" && pass "HTML page" || fail "example / is not HTML"
  curl -s -m 5 "$E/user/42" | grep -q '"name":"User 42"' && pass "path parameter" || fail "example /user/42: $(curl -s -m 5 "$E/user/42")"
  [ "$(curl -s -m 5 -o /dev/null -w '%{http_code} %{redirect_url}' "$E/old-page")" = "302 $E/hello?name=redirected" ] && pass "redirect" || fail "example redirect: $(curl -s -m 5 -o /dev/null -w '%{http_code} %{redirect_url}' "$E/old-page")"
  [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d '{"a":1}' "$E/api/echo")" = 201 ] && pass "POST with status 201" || fail "example POST"
  [ "$(curl -s -m 5 "$E/stream" | wc -l)" = 5 ] && pass "chunked stream" || fail "example stream"
  [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$E/nope")" = 404 ] && pass "unknown path declined (404)" || fail "example 404"
  stop $((P+2))
else
  fail "examples/myapp.strada does not build: $(tail -3 "$S/myapp.build")"
fi

echo "keep-alive with more clients than workers"
if command -v ab >/dev/null; then
  "$BIN" --demo -h 127.0.0.1 -p $((P+3)) -w 4 > "$S/server4.log" 2>&1 &
disown
  for _ in $(seq 1 60); do curl -s -o /dev/null "http://127.0.0.1:$((P+3))/hello" && break; sleep 0.1; done
  ab -k -n 20000 -c 50 "http://127.0.0.1:$((P+3))/hello" > "$S/ab.out" 2>&1
  F=$(grep "^Failed requests" "$S/ab.out" | awk '{print $3}')
  L=$(grep "longest request" "$S/ab.out" | awk '{print $2}')
  [ "$F" = 0 ] && pass "no failed requests" || fail "failed requests: $F ($(grep -A1 '^Failed' "$S/ab.out" | tail -1))"
  [ -n "$L" ] && [ "$L" -lt 3000 ] && pass "slowest request ${L} ms (clients take turns)" || fail "slowest request ${L} ms"
  stop $((P+3))
else
  echo "  SKIP: ab not installed"
fi

echo "app.library_prefixes = 1 (old interface)"
printf '[server]\nhost = 127.0.0.1\nport = %s\nworkers = 1\n[app]\nlibrary_prefixes = 1\n' $((P+4)) > "$S/c.conf"
"$BIN" -c "$S/c.conf" -l "$S/lib.so" > "$S/server5.log" 2>&1 &
disown
wait_up $((P+4)) || fail "legacy server did not start"
C=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$((P+4))/echo?q=STATUS:418:teapot")
[ "$C" = 418 ] && pass "prefixes honoured when asked for" || fail "legacy STATUS: -> $C"
stop $((P+4))

[ $FAILS -eq 0 ] && echo "All review tests passed!" || { echo "$FAILS failure(s)"; exit 1; }
