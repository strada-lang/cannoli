#!/bin/bash
# CGI mode (cannoli --cgi): one request from the environment and standard
# input, the response on standard output. Checked directly and under a real
# CGI host (python3 -m http.server --cgi), with a compiled library, an
# interpreted application and the built-in routes.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${BIN:-$ROOT/cannoli}"
STRADA="${STRADA:-strada}"
for tool in curl python3 xxd; do command -v $tool >/dev/null || { echo "SKIP: $tool not installed"; exit 0; }; done
P=$(( 20000 + RANDOM % 20000 ))
S="$(mktemp -d)"
HPID=""
cleanup() { [ -n "$HPID" ] && kill "$HPID" 2>/dev/null; rm -rf "$S"; }
trap cleanup EXIT
FAILS=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAILS=$((FAILS+1)); }

cat > "$S/app.strada" <<'APP'
func cannoli_dispatch(scalar $c) str {
    my str $p = $c->path();
    if ($p eq "/") { $c->render_text("root script=" . $c->script_name()); return $c->done(); }
    if ($p eq "/hello") { $c->render_text("Hello, " . $c->param("name") . "!"); return $c->done(); }
    if ($p eq "/json") { $c->status(201); $c->set_cookie("a", "1", "/"); $c->set_cookie("b", "2", "/"); $c->render_json({"n" => 3}); return $c->done(); }
    if ($p eq "/post") {
        my int $sum = 0;
        my str $b = $c->body();
        my int $i = 0;
        while ($i < core::byte_length($b)) { $sum = $sum + (core::get_byte($b, $i) % 256); $i = $i + 1; }
        $c->render_text($c->method() . " " . core::byte_length($b) . " " . $sum . " " . $c->header("X-Test") . " " . $c->param("f"));
        return $c->done();
    }
    if ($p eq "/meta") { $c->render_text($c->remote_addr() . " " . $c->scheme() . " " . $c->header("Host")); return $c->done(); }
    if ($p eq "/bin") { $c->content_type("application/octet-stream"); $c->write_body(core::byte(0) . "A" . core::byte(255) . core::byte(0) . "Z"); return $c->done(); }
    if ($p eq "/redirect") { $c->redirect($c->script_name() . "/hello?name=again", 0); return $c->done(); }
    if ($p eq "/boom") { throw "kaboom in cgi"; }
    if ($p eq "/echo") { return $c->param("q"); }
    if ($p eq "/stream") {
        $c->content_type("text/plain");
        $c->start_chunked();
        my int $i = 1;
        while ($i <= 3) { $c->write_chunk("line " . $i . "\n"); $i = $i + 1; }
        $c->end_chunked();
        return $c->done();
    }
    return "";
}
APP
( cd "$S" && "$STRADA" --shared app.strada -o app.so >/dev/null 2>&1 ) || { echo "SKIP: could not build the test library"; exit 0; }

# run one CGI request by hand: cgi METHOD PATH_INFO QUERY [extra env...] -- cannoli args...
cgi() {
  local m="$1" pi="$2" qs="$3"; shift 3
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  env -i PATH="$PATH" HOME="$HOME" GATEWAY_INTERFACE=CGI/1.1 SERVER_PROTOCOL=HTTP/1.1 REMOTE_ADDR=10.1.2.3 \
    SCRIPT_NAME=/cgi-bin/app.cgi HTTP_HOST=example.test REQUEST_METHOD="$m" PATH_INFO="$pi" QUERY_STRING="$qs" "${envs[@]}" "$BIN" "$@"
}

echo "a compiled library, by hand"
OUT=$(cgi GET /hello name=Ada -- --cgi -l "$S/app.so" 2>"$S/err" | tr -d '\r')
[ "$(echo "$OUT" | head -1)" = "Status: 200 OK" ] && pass "response starts with a Status line" || fail "first line: $(echo "$OUT" | head -1)"
[ "$(echo "$OUT" | tail -1)" = "Hello, Ada!" ] && pass "body after the blank line" || fail "body: $(echo "$OUT" | tail -1)"
echo "$OUT" | grep -q "^Content-Type: text/plain" && ! echo "$OUT" | grep -qiE "^(Connection|Keep-Alive|Transfer-Encoding|Server):" && pass "headers, without connection headers" || fail "headers: $(echo "$OUT" | head -8 | tr '\n' '|')"
grep -q "Loading library" "$S/err" && ! echo "$OUT" | grep -q "Loading library" && pass "startup messages go to standard error, not into the response" || fail "startup output leaked into the response"
OUT=$(cgi GET /json "" -- --cgi -l "$S/app.so" 2>/dev/null | tr -d '\r')
[ "$(echo "$OUT" | head -1)" = "Status: 201 Created" ] && [ "$(echo "$OUT" | grep -c '^Set-Cookie:')" = 2 ] && echo "$OUT" | grep -q '{"n":3}' && pass "status, two cookies, JSON" || fail "json: $(echo "$OUT" | tr '\n' '|')"
OUT=$(printf 'f=v1&g=2' | cgi POST /post "" CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH=8 HTTP_X_TEST=hv -- --cgi -l "$S/app.so" 2>/dev/null | tr -d '\r' | tail -1)
[ "$OUT" = "POST 8 582 hv v1" ] && pass "POST body from standard input, form field, request header" || fail "post: $OUT"
head -c 200000 /dev/urandom > "$S/blob"
WANT=$(python3 -c "import sys; print(sum(open(sys.argv[1],'rb').read()))" "$S/blob")
OUT=$(cgi POST /post "" CONTENT_TYPE=application/octet-stream CONTENT_LENGTH=200000 -- --cgi -l "$S/app.so" < "$S/blob" 2>/dev/null | tr -d '\r' | tail -1)
[ "$(echo "$OUT" | cut -d' ' -f2,3)" = "200000 $WANT" ] && pass "200 KB binary body arrives intact" || fail "binary body: $OUT (want sum $WANT)"
OUT=$(cgi GET /bin "" -- --cgi -l "$S/app.so" 2>/dev/null | python3 -c "import sys; d=sys.stdin.buffer.read(); print(d.split(b'\r\n\r\n',1)[1].hex())")
[ "$OUT" = "0041ff005a" ] && pass "binary response body" || fail "binary response: $OUT"
[ "$(cgi GET /meta "" HTTPS=on -- --cgi -l "$S/app.so" 2>/dev/null | tr -d '\r' | tail -1)" = "10.1.2.3 https example.test" ] && pass "REMOTE_ADDR, HTTPS and Host" || fail "meta"
[ "$(cgi GET "" "" -- --cgi -l "$S/app.so" 2>/dev/null | tr -d '\r' | tail -1)" = "root script=/cgi-bin/app.cgi" ] && pass "no PATH_INFO is /, script_name available" || fail "root: $(cgi GET "" "" -- --cgi -l "$S/app.so" 2>/dev/null | tail -1)"
[ "$(cgi GET /nope "" -- --cgi -l "$S/app.so" 2>/dev/null | head -1 | tr -d '\r')" = "Status: 404 Not Found" ] && pass "404" || fail "404"
OUT=$(cgi GET /boom "" -- --cgi -l "$S/app.so" 2>"$S/err" | tr -d '\r')
[ "$(echo "$OUT" | head -1)" = "Status: 500 Internal Server Error" ] && ! echo "$OUT" | grep -q kaboom && grep -q "kaboom in cgi" "$S/err" && pass "a handler that throws: 500, message on standard error only" || fail "boom: $(echo "$OUT" | head -1)"
OUT=$(cgi GET /echo "q=REDIRECT:https://evil.example/" -- --cgi -l "$S/app.so" 2>/dev/null | tr -d '\r')
[ "$(echo "$OUT" | head -1)" = "Status: 200 OK" ] && ! echo "$OUT" | grep -qi "^Location:" && pass "a returned string is only a body" || fail "echo steerable"
OUT=$(cgi GET /stream "" -- --cgi -l "$S/app.so" 2>/dev/null | tr -d '\r')
[ "$(echo "$OUT" | head -1)" = "Status: 200 OK" ] && [ "$(echo "$OUT" | grep -c '^line ')" = 3 ] && ! echo "$OUT" | grep -q "^[0-9a-f]\+$" && pass "a streamed response is plain bytes (no chunk framing)" || fail "stream: $(echo "$OUT" | tr '\n' '|')"
printf '[server]\nmax_body_size = 1000\n' > "$S/small.conf"
OUT=$(head -c 5000 /dev/zero | cgi POST /post "" CONTENT_LENGTH=5000 -- --cgi -c "$S/small.conf" -l "$S/app.so" 2>/dev/null | head -1 | tr -d '\r')
[ "$OUT" = "Status: 413 Payload Too Large" ] || [ "$OUT" = "Status: 413 Content Too Large" ] && pass "a body over max_body_size is refused (413)" || fail "413: $OUT"
OUT=$(cgi GET /hello name=x -- --cgi -l "$S/missing.so" 2>/dev/null | head -1 | tr -d '\r')
[ "$OUT" = "Status: 500 Internal Server Error" ] && pass "a library that does not load is a 500, not an empty reply" || fail "missing library: $OUT"

echo "other kinds of application"
[ "$(cgi GET /hello name=VM -- -l "$S/app.strada" 2>/dev/null | tr -d '\r' | tail -1)" = "Hello, VM!" ] && pass "an interpreted .strada application, CGI detected from the environment (no --cgi)" || fail "interpreted: $(cgi GET /hello name=VM -- -l "$S/app.strada" 2>&1 | tail -2)"
[ "$(cgi GET /hello "" -- --cgi --demo 2>/dev/null | tr -d '\r' | tail -1)" = "Hello, World!" ] && pass "the built-in routes" || fail "demo routes"

# python3 -m http.server --cgi is a minimal host: it always answers "200
# Script output follows" and hands the script's headers through as they
# are, and it passes only a fixed set of request headers. So the status is
# checked in the Status header it relays.
echo "under a real CGI host"
mkdir -p "$S/www/cgi-bin"
printf '#!/bin/sh\nexec "%s" --cgi --library "%s"\n' "$BIN" "$S/app.so" > "$S/www/cgi-bin/app.cgi"
printf '#!/bin/sh\nexec "%s" --library "%s"\n' "$BIN" "$S/app.strada" > "$S/www/cgi-bin/vm.cgi"
chmod +x "$S/www/cgi-bin/app.cgi" "$S/www/cgi-bin/vm.cgi"
( cd "$S/www" && exec python3 -m http.server --cgi --bind 127.0.0.1 $P > "$S/host.log" 2>&1 ) &
HPID=$!
U="http://127.0.0.1:$P/cgi-bin"
for _ in $(seq 1 60); do curl -s -o /dev/null "$U/app.cgi/hello?name=up" && break; sleep 0.1; done
[ "$(curl -s -m 10 "$U/app.cgi/hello?name=Ada")" = "Hello, Ada!" ] && pass "GET through the web server" || fail "host GET: $(curl -s -m 10 "$U/app.cgi/hello?name=Ada" | head -2)"
H=$(curl -s -m 10 -D - -o "$S/body" "$U/app.cgi/json" | tr -d '\r')
echo "$H" | grep -q "^Status: 201 Created" && [ "$(echo "$H" | grep -c '^Set-Cookie:')" = 2 ] && grep -q '{"n":3}' "$S/body" && pass "status and headers reach the client" || fail "host json: $(echo "$H" | head -4 | tr '\n' '|')"
[ "$(curl -s -m 10 -d 'f=v1&g=2' "$U/app.cgi/post")" = "POST 8 582  v1" ] && pass "POST through the web server" || fail "host POST: $(curl -s -m 10 -d 'f=v1&g=2' "$U/app.cgi/post")"
[ "$(curl -s -m 10 --data-binary @"$S/blob" -H 'Content-Type: application/octet-stream' "$U/app.cgi/post" | cut -d' ' -f2,3)" = "200000 $WANT" ] && pass "200 KB upload through the web server" || fail "host upload"
curl -s -m 10 -D - -o /dev/null "$U/app.cgi/nope" | tr -d '\r' | grep -q "^Status: 404 Not Found" && pass "404 through the web server" || fail "host 404"
[ "$(curl -s -m 10 "$U/app.cgi/stream" | grep -c '^line ')" = 3 ] && pass "streamed response through the web server" || fail "host stream"
[ "$(curl -s -m 15 "$U/vm.cgi/hello?name=VM")" = "Hello, VM!" ] && pass "interpreted application through the web server" || fail "host vm: $(curl -s -m 15 "$U/vm.cgi/hello?name=VM" | head -2)"
T0=$(date +%s%N); for i in 1 2 3 4 5 6 7 8 9 10; do curl -s -m 10 -o /dev/null "$U/app.cgi/hello?name=t"; done; T1=$(date +%s%N)
echo "  INFO: $(( (T1 - T0) / 10000000 )) ms per CGI request (process start + library load each time)"

[ $FAILS -eq 0 ] && echo "All CGI tests passed!" || { echo "$FAILS failure(s)"; exit 1; }
