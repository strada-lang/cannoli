#!/bin/bash
# Applications run by the built-in Strada VM (--library app.strada): the
# same interface as a compiled library, reload on change, errors, loop
# workers, memory.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${BIN:-$ROOT/cannoli}"
for tool in curl python3; do command -v $tool >/dev/null || { echo "SKIP: $tool not installed"; exit 0; }; done
P=$(( 20000 + RANDOM % 20000 ))
S="$(mktemp -d)"
stop() { for pid in $(ss -ltnpH "sport = :$1" 2>/dev/null | grep -o "pid=[0-9]*" | cut -d= -f2 | sort -u); do kill -9 "$pid" 2>/dev/null; done; }
cleanup() { for port in $P $((P+1)) $((P+2)) $((P+3)) $((P+4)); do stop $port; done; rm -rf "$S"; }
trap cleanup EXIT
trap "" PIPE
FAILS=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAILS=$((FAILS+1)); }
wait_up() { for _ in $(seq 1 80); do curl -s -o /dev/null "http://127.0.0.1:$1/up" && return 0; sleep 0.1; done; return 1; }

write_app() {   # $1 = version text
cat > "$S/app.strada" <<APP
package App;
my int \$g_hits = 0;
func version() str { return "$1"; }
func bump() int { \$g_hits = \$g_hits + 1; return \$g_hits; }

package main;
my str \$g_opt = "";

func cannoli_init(str \$config) int {
    foreach my str \$part (split(";", \$config)) {
        if (length(\$part) > 4 && substr(\$part, 0, 4) eq "opt=") { \$g_opt = substr(\$part, 4, length(\$part) - 4); }
    }
    return \$g_opt eq "refuse" ? 0 : 1;
}

func cannoli_after_request(scalar \$c, int \$ms) void {
    if (\$c->path() eq "/mark") { spew("$S/after.txt", "after " . \$c->path()); }
}

func cannoli_dispatch(scalar \$c) str {
    my str \$p = \$c->path_info();
    if (length(\$p) == 0) { \$p = \$c->path(); }
    if (\$p eq "/up") { return "up"; }
    if (\$p eq "/version") { \$c->render_text(App::version() . " opt=" . \$g_opt); return \$c->done(); }
    if (\$p eq "/count") { \$c->render_text("" . App::bump()); return \$c->done(); }
    if (\$p eq "/echo") { return \$c->param("q"); }
    if (\$p eq "/json") { \$c->status(201); \$c->set_cookie("a", "1", "/"); \$c->render_json({"name" => \$c->param("name"), "n" => 3}); return \$c->done(); }
    if (\$p eq "/post") { \$c->render_text(\$c->method() . ":" . core::byte_length(\$c->body()) . ":" . \$c->header("X-T")); return \$c->done(); }
    if (\$p eq "/redirect") { \$c->redirect("/version", 0); return \$c->done(); }
    if (\$p eq "/boom") { throw "kaboom in the script"; }
    if (\$p eq "/mark") { return "marked"; }
    if (\$p eq "/esc") { \$c->render_html("<p>" . \$c->html_escape(\$c->param("q")) . "</p>"); return \$c->done(); }
    if (\$p eq "/stream") {
        \$c->content_type("text/plain");
        \$c->start_chunked();
        my int \$i = 0;
        my str \$block = "0123456789012345678901234567890123456789012345678901234567890123456789\n" x 200;
        while (\$i < 400) { if (\$c->write_chunk(\$block) < 0) { last; } \$i = \$i + 1; }
        \$c->end_chunked();
        return \$c->done();
    }
    return "";
}
APP
}
write_app one
U="http://127.0.0.1:$P"
"$BIN" -h 127.0.0.1 -p $P -w 1 --max-requests 0 -l "$S/app.strada:opt=hello;reload=1" > "$S/server.log" 2>&1 &
disown
wait_up $P || { fail "server did not start: $(tail -5 "$S/server.log")"; echo "$FAILS failure(s)"; exit 1; }
grep -q "cannoli_dispatch (interpreted)" "$S/server.log" && pass "the .strada file is loaded into the VM" || fail "not reported as interpreted"

echo "requests"
[ "$(curl -s -m 5 "$U/version")" = "one opt=hello" ] && pass "cannoli_init receives the options; package functions work" || fail "version: $(curl -s -m 5 "$U/version")"
H=$(curl -s -m 5 -D - "$U/json?name=Ada" | tr -d '\r')
echo "$H" | grep -q "^HTTP/1.1 201" && echo "$H" | grep -qi "^content-type: application/json" && echo "$H" | grep -q "^Set-Cookie: a=1" && echo "$H" | grep -q '"name":"Ada"' \
  && pass "status, cookie and JSON through \$c" || fail "json: $(echo "$H" | head -3 | tr '\n' ' ')"
[ "$(curl -s -m 5 -H 'X-T: hv' -d 'abcde' "$U/post")" = "POST:5:hv" ] && pass "method, body and headers" || fail "post: $(curl -s -m 5 -H 'X-T: hv' -d 'abcde' "$U/post")"
[ "$(curl -s -m 5 -o /dev/null -w '%{http_code} %{redirect_url}' "$U/redirect")" = "302 $U/version" ] && pass "redirect" || fail "redirect"
[ "$(curl -s -m 5 "$U/esc?q=%3Cb%3E")" = "<p>&lt;b&gt;</p>" ] && pass "\$c->html_escape" || fail "esc: $(curl -s -m 5 "$U/esc?q=%3Cb%3E")"
H=$(curl -s -m 5 -D - "$U/echo?q=REDIRECT:https://evil.example/" | tr -d '\r')
echo "$H" | grep -q "^HTTP/1.1 200" && ! echo "$H" | grep -qi "^location:" && pass "a returned string is only a body, as for compiled libraries" || fail "echo steerable: $(echo "$H" | head -1)"
[ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$U/nope")" = 404 ] && pass "an empty return declines (404)" || fail "decline"
A=$(curl -s -m 5 "$U/count"); B=$(curl -s -m 5 "$U/count")
[ "$B" = $((A + 1)) ] && pass "script state is kept between requests ($A, $B)" || fail "state: $A $B"
[ "$(curl -s -m 10 "$U/stream" | wc -c)" = 5680000 ] && pass "chunked stream (5.7 MB)" || fail "stream length $(curl -s -m 10 "$U/stream" | wc -c)"
curl -s -m 5 -o /dev/null "$U/mark"; sleep 0.3
[ "$(cat "$S/after.txt" 2>/dev/null)" = "after /mark" ] && pass "cannoli_after_request runs" || fail "after hook did not run"

echo "errors"
C=$(curl -s -m 5 -o "$S/boom" -w '%{http_code}' "$U/boom")
[ "$C" = 500 ] && ! grep -q "kaboom" "$S/boom" && grep -q "kaboom in the script" "$S/server.log" && pass "throw -> 500, message in the log only" || fail "boom: $C"
[ "$(curl -s -m 5 "$U/version")" = "one opt=hello" ] && ! grep -q "exited, respawning" "$S/server.log" && pass "the worker survives" || fail "worker died after a throw"

echo "reload"
sleep 1.1; write_app two; sleep 1.2
[ "$(curl -s -m 5 "$U/version")" = "two opt=hello" ] && pass "an edited script is picked up (reload=1)" || fail "after edit: $(curl -s -m 5 "$U/version")"
sleep 1.1; echo "func broken( {" >> "$S/app.strada"; sleep 1.2
[ "$(curl -s -m 5 "$U/version")" = "two opt=hello" ] && grep -q "reload of .* failed, keeping the previous version" "$S/server.log" \
  && pass "a script that no longer compiles keeps the last good version (and is logged)" || fail "broken edit: $(curl -s -m 5 "$U/version") / $(grep -c 'reload of' "$S/server.log")"
sleep 1.1; write_app three; sleep 1.2
[ "$(curl -s -m 5 "$U/version")" = "three opt=hello" ] && pass "and recovers when fixed" || fail "after fix: $(curl -s -m 5 "$U/version")"

echo "memory"
WPID=$(pgrep -P "$(ss -ltnpH "sport = :$P" | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -n | head -1)" | head -1)
drive() { python3 - "$P" "$1" <<'PY'
import http.client, sys
c = http.client.HTTPConnection("127.0.0.1", int(sys.argv[1]))
for i in range(int(sys.argv[2])):
    c.request("GET", "/json?name=Ada")
    r = c.getresponse(); r.read()
    if r.getheader("Connection", "").lower() == "close":
        c.close(); c = http.client.HTTPConnection("127.0.0.1", int(sys.argv[1]))
PY
}
drive 30000; R1=$(awk '/VmRSS/{print $2}' /proc/$WPID/status 2>/dev/null)
drive 30000; R2=$(awk '/VmRSS/{print $2}' /proc/$WPID/status 2>/dev/null)
[ -n "$R1" ] && [ -n "$R2" ] && [ $((R2 - R1)) -lt 3072 ] && pass "worker RSS ${R1} kB -> ${R2} kB over 30,000 more requests" || fail "worker RSS grew ${R1} kB -> ${R2} kB over 30,000 requests"
stop $P

echo "loop workers"
printf '[server]\nhost = 127.0.0.1\nport = %s\nworkers = 1\nloop_workers = 1\nwrite_timeout = 20\n' $((P+1)) > "$S/loop.conf"
"$BIN" -c "$S/loop.conf" -l "$S/app.strada" > "$S/server2.log" 2>&1 &
disown
wait_up $((P+1)) || fail "loop server did not start: $(tail -3 "$S/server2.log")"
python3 - $((P+1)) > "$S/loop.out" 2>&1 <<'PY'
import socket, sys, time, threading, urllib.request
port = int(sys.argv[1])
# Two streams and twenty short requests at once. The VM takes one handler
# at a time, so they queue; none may be lost or mixed up.
totals = []
def stream():
    s = socket.create_connection(("127.0.0.1", port)); s.settimeout(30)
    s.sendall(b"GET /stream HTTP/1.1\r\nHost: x\r\n\r\n")
    n = 0
    try:
        while True:
            d = s.recv(65536)
            if not d: break
            n += len(d)
    except Exception: n = -1
    totals.append(n)
ts = [threading.Thread(target=stream) for _ in range(2)]
[t.start() for t in ts]
ok = 0
for i in range(20):
    try:
        if urllib.request.urlopen("http://127.0.0.1:%d/version" % port, timeout=30).read().startswith(b"three"): ok += 1
    except Exception as e: print("ERR", e)
[t.join() for t in ts]
print("OTHER", ok)
print("STREAMS", sorted(totals))
PY
grep -q "^OTHER 20$" "$S/loop.out" && pass "20 requests answered correctly alongside two streams" || fail "loop concurrency: $(head -3 "$S/loop.out")"
python3 -c "
import sys
l=[x for x in open(sys.argv[1]) if x.startswith('STREAMS')]
t=eval(l[0].split(' ',1)[1]) if l else []
sys.exit(0 if len(t)==2 and min(t) > 5680000 else 1)" "$S/loop.out" && pass "both streams arrive complete" || fail "streams: $(grep STREAMS "$S/loop.out")"
! grep -q "exited, respawning" "$S/server2.log" && pass "no worker crash" || fail "loop worker crashed: $(grep -i 'error\|exited' "$S/server2.log" | head -2)"
stop $((P+1))

echo "prefix mount and a compiled library side by side"
printf '[server]\nhost = 127.0.0.1\nport = %s\nworkers = 1\n[library]\n/vm = %s\n' $((P+2)) "$S/app.strada:opt=mounted" > "$S/m.conf"
"$BIN" -c "$S/m.conf" > "$S/server3.log" 2>&1 &
disown
for _ in $(seq 1 60); do curl -s -o /dev/null "http://127.0.0.1:$((P+2))/vm/up" && break; sleep 0.1; done
[ "$(curl -s -m 5 "http://127.0.0.1:$((P+2))/vm/version")" = "three opt=mounted" ] && pass "mounted under /vm (path_info)" || fail "mount: $(curl -s -m 5 "http://127.0.0.1:$((P+2))/vm/version")"
[ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$((P+2))/version")" = 404 ] && pass "not served outside its prefix" || fail "served outside the prefix"
stop $((P+2))

echo "the script's own modules"
mkdir -p "$S/lib"
printf 'package Greeter;\nfunc hello(str $who) str { return "hi " . $who; }\n' > "$S/lib/Greeter.strada"
printf 'use Greeter;\nfunc cannoli_dispatch(scalar $c) str {\n    if ($c->path() eq "/up") { return "up"; }\n    return Greeter::hello($c->param("who"));\n}\n' > "$S/mod.strada"
"$BIN" -h 127.0.0.1 -p $((P+3)) -w 1 -l "$S/mod.strada:lib=$S/lib" > "$S/server5.log" 2>&1 &
disown
wait_up $((P+3)) || fail "module server did not start: $(tail -3 "$S/server5.log")"
[ "$(curl -s -m 5 "http://127.0.0.1:$((P+3))/x?who=there")" = "hi there" ] && pass "use of a module found through lib=DIR" || fail "module: $(curl -s -m 5 "http://127.0.0.1:$((P+3))/x?who=there")"
stop $((P+3)); sleep 0.3
if [ -f /usr/local/lib/strada/lib/JSON.strada ] && command -v gcc >/dev/null; then
  printf 'use JSON;\nfunc cannoli_dispatch(scalar $c) str {\n    if ($c->path() eq "/up") { return "up"; }\n    my scalar $d = JSON::decode($c->body());\n    return JSON::encode({"second" => $d->{"k"}->[1]});\n}\n' > "$S/json.strada"
  env -u STRADA_HOME "$BIN" -h 127.0.0.1 -p $((P+3)) -w 1 -l "$S/json.strada" > "$S/server6.log" 2>&1 &
  disown
  for _ in $(seq 1 150); do curl -s -o /dev/null "http://127.0.0.1:$((P+3))/up" && break; sleep 0.2; done
  R=$(curl -s -m 5 -d '{"k":[10,20]}' "http://127.0.0.1:$((P+3))/x")
  [ "$R" = '{"second":20}' ] && pass "a module with inline C (JSON) loads and works" || fail "JSON module: $R / $(grep -m1 'error' "$S/server6.log")"
  stop $((P+3)); sleep 0.3
else
  echo "  SKIP: Strada's JSON module or gcc not available"
fi

echo "startup errors"
OUT=$(timeout 8 "$BIN" -h 127.0.0.1 -p $((P+3)) -w 1 -l "$S/app.strada:opt=refuse" 2>&1); RC=$?
echo "$OUT" | grep -q "cannoli_init returned 0" && [ $RC -ne 124 ] && pass "cannoli_init returning 0 stops startup" || fail "refusing init: rc=$RC $(echo "$OUT" | tail -2)"
echo 'func cannoli_dispatch(scalar $c) str { return $undeclared; }' > "$S/bad.strada"
OUT=$(timeout 8 "$BIN" -h 127.0.0.1 -p $((P+3)) -w 1 -l "$S/bad.strada" 2>&1); RC=$?
echo "$OUT" | grep -q "bad.strada:1: undeclared variable" && [ $RC -ne 124 ] && pass "a script error stops startup, with file and line" || fail "bad script: rc=$RC $(echo "$OUT" | tail -2)"
echo 'func other() int { return 1; }' > "$S/nodispatch.strada"
OUT=$(timeout 8 "$BIN" -h 127.0.0.1 -p $((P+3)) -w 1 -l "$S/nodispatch.strada" 2>&1); RC=$?
echo "$OUT" | grep -q "does not define cannoli_dispatch" && [ $RC -ne 124 ] && pass "a script without cannoli_dispatch is refused" || fail "no dispatch: rc=$RC"
OUT=$(timeout 8 "$BIN" -h 127.0.0.1 -p $((P+3)) -w 1 -l "$S/missing.strada" 2>&1); RC=$?
echo "$OUT" | grep -q "cannot read" && [ $RC -ne 124 ] && pass "a missing script is refused" || fail "missing: rc=$RC"

echo "the example runs both ways"
"$BIN" -h 127.0.0.1 -p $((P+4)) -w 1 -l "$ROOT/examples/myapp.strada:greeting=Ciao" > "$S/server4.log" 2>&1 &
disown
for _ in $(seq 1 60); do curl -s -o /dev/null "http://127.0.0.1:$((P+4))/" && break; sleep 0.1; done
[ "$(curl -s -m 5 "http://127.0.0.1:$((P+4))/hello?name=Ada")" = "Ciao, Ada!" ] && [ "$(curl -s -m 5 "http://127.0.0.1:$((P+4))/stream" | wc -l)" = 5 ] \
  && pass "examples/myapp.strada interpreted" || fail "example interpreted: $(curl -s -m 5 "http://127.0.0.1:$((P+4))/hello?name=Ada") / $(tail -4 "$S/server4.log" | tr '\n' '|')"
stop $((P+4))

[ $FAILS -eq 0 ] && echo "All VM application tests passed!" || { echo "$FAILS failure(s)"; exit 1; }
