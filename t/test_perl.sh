#!/bin/bash
# The Perl dispatch library (lib/perl): request and response through the
# embedded interpreter, binary safety, errors, exit(), cookies, memory.
# Skipped when lib/perl/cannoli_perl.so has not been built (cd lib/perl && make).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${BIN:-$ROOT/cannoli}"
LIB="${PERL_LIB:-$ROOT/lib/perl/cannoli_perl.so}"
[ -f "$LIB" ] || { echo "SKIP: $LIB not built (cd lib/perl && make)"; exit 0; }
for tool in curl python3 xxd; do command -v $tool >/dev/null || { echo "SKIP: $tool not installed"; exit 0; }; done
P=$(( 20000 + RANDOM % 20000 ))
S="$(mktemp -d)"
stop() { for pid in $(ss -ltnpH "sport = :$1" 2>/dev/null | grep -o "pid=[0-9]*" | cut -d= -f2 | sort -u); do kill -9 "$pid" 2>/dev/null; done; }
cleanup() { stop $P; stop $((P+1)); rm -rf "$S"; }
trap cleanup EXIT
FAILS=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAILS=$((FAILS+1)); }
U="http://127.0.0.1:$P"

cat > "$S/app.pl" <<'PL'
package T;
use strict; use warnings;
our $n = 0;
our $loaded_pid = $$;
our $child_pid = 0;
our $first_rand = rand();          # drawn in the master, before the workers fork
sub child_init { $child_pid = $$; }
sub handle {
    my ($c) = @_;
    my $p = $c->path;
    $n++;
    if ($p eq '/up') { $c->render_text("up"); }
    elsif ($p eq '/echo') { $c->render_text($c->param('q') // ''); }
    elsif ($p eq '/len') { $c->render_text(length($c->body)); }
    elsif ($p eq '/sum') { my $t = 0; $t += ord($_) for split //, $c->body; $c->render_text($t); }
    elsif ($p eq '/bin') { $c->content_type('application/octet-stream'); $c->write("AB\0CD\0EF\xff\xfe"); }
    elsif ($p eq '/die') { die "secret path /etc/app/db.conf password=hunter2\n"; }
    elsif ($p eq '/exit') { $c->render_text("before exit"); exit(3); }
    elsif ($p eq '/hdr') { $c->render_text(join(",", map { "$_=" . $c->header($_) } sort keys %{$c->headers})); }
    elsif ($p eq '/cookies') { $c->set_cookie('a', '1'); $c->set_cookie('b', '2', path => '/'); $c->render_text('ok'); }
    elsif ($p eq '/empty') { $c->status(200); }
    elsif ($p eq '/nocontent') { $c->status(204); }
    elsif ($p eq '/utf') { $c->render_text("caf\x{e9} \x{263a}"); }
    elsif ($p eq '/json') { $c->render_json({ got => $c->json }); }
    elsif ($p eq '/redir') { $c->set_cookie('s', '1'); $c->redirect('/next', 303); }
    elsif ($p eq '/inject') { $c->set_header('X-A', "v\r\nSet-Cookie: admin=1"); $c->render_text('ok'); }
    elsif ($p eq '/colon') { $c->set_header('X-Odd', 'ends:'); $c->write(':starts with a colon'); }
    elsif ($p eq '/fork') {
        my $kid = fork();
        if (defined $kid && $kid == 0) { if (open(my $fh, '>', $c->param('f'))) { print $fh "child $$\n"; close $fh; } exit 0; }
        waitpid($kid, 0);
        $c->render_text("forked " . ($? >> 8));
    }
    elsif ($p eq '/pids') { $c->render_text("$loaded_pid $$ $child_pid"); }
    elsif ($p eq '/rand') { $c->render_text(rand()); }
    elsif ($p eq '/meta') { $c->render_text(join(" ", $c->scheme, length($c->request_id) ? 'id' : 'noid', $c->remote_addr)); }
    elsif ($p eq '/html') { $c->render_html('<b>hi</b>'); }
    elsif ($p eq '/decline') { $c->set_header('X-Never', '1'); $c->decline; }
    return "REDIRECT:https://evil.example/";     # the return value is not a response
}
1;
PL

"$BIN" -h 127.0.0.1 -p $P -w 1 --max-requests 0 -l "$LIB:script=$S/app.pl;handler=T::handle" > "$S/server.log" 2>&1 &
disown
for _ in $(seq 1 80); do curl -s -o /dev/null "$U/up" && break; sleep 0.1; done
curl -s -o /dev/null "$U/up" || { fail "server did not start: $(tail -5 "$S/server.log")"; echo "$FAILS failure(s)"; exit 1; }
hdrs() { curl -s -m 5 -D - -o "$S/body" "$@" | tr -d '\r'; }

echo "requests and responses"
H=$(hdrs "$U/echo?q=REDIRECT:https://evil.example/")
echo "$H" | grep -q "^HTTP/1.1 200" && ! echo "$H" | grep -qi "^location:" && [ "$(cat "$S/body")" = "REDIRECT:https://evil.example/" ] \
  && pass "an echoed REDIRECT: is text" || fail "echoed REDIRECT: -> $(echo "$H" | head -1) $(echo "$H" | grep -i location)"
H=$(hdrs "$U/echo?q=%3Cb%3E")
echo "$H" | grep -qi "^content-type: text/plain" && pass "render_text stays text/plain for <...>" || fail "type: $(echo "$H" | grep -i content-type)"
H=$(hdrs "$U/html")
echo "$H" | grep -qi "^content-type: text/html" && pass "render_html" || fail "html type: $(echo "$H" | grep -i content-type)"
H=$(hdrs "$U/cookies")
[ "$(echo "$H" | grep -ci '^set-cookie:')" = 2 ] && echo "$H" | grep -q "^Set-Cookie: a=1" && echo "$H" | grep -q "^Set-Cookie: b=2; Path=/" \
  && pass "two cookies, two Set-Cookie headers" || fail "cookies: $(echo "$H" | grep -i set-cookie | tr '\n' '|')"
H=$(hdrs "$U/redir")
echo "$H" | grep -q "^HTTP/1.1 303" && echo "$H" | grep -qi "^location: /next" && echo "$H" | grep -q "^Set-Cookie: s=1" \
  && pass "redirect keeps its status and cookie" || fail "redirect: $(echo "$H" | head -1) $(echo "$H" | grep -iE 'location|cookie' | tr '\n' '|')"
H=$(hdrs "$U/empty")
echo "$H" | grep -q "^HTTP/1.1 200" && [ ! -s "$S/body" ] && pass "status(200) with an empty body is a 200, not a 404" || fail "empty -> $(echo "$H" | head -1)"
H=$(hdrs "$U/nocontent")
echo "$H" | grep -q "^HTTP/1.1 204" && pass "204" || fail "nocontent -> $(echo "$H" | head -1)"
H=$(hdrs "$U/decline")
echo "$H" | grep -q "^HTTP/1.1 404" && ! echo "$H" | grep -qi "^x-never" && pass "decline() falls through to the 404" || fail "decline -> $(echo "$H" | head -1)"
H=$(hdrs "$U/nosuchpath")
echo "$H" | grep -q "^HTTP/1.1 404" && pass "a handler that sets nothing declines" || fail "untouched -> $(echo "$H" | head -1)"
H=$(hdrs "$U/inject")
! echo "$H" | grep -qi "^set-cookie" && pass "a header value with CR LF is dropped, not split" || fail "header injection: $(echo "$H" | grep -i cookie)"
H=$(hdrs "$U/colon")
echo "$H" | grep -q "^X-Odd: ends:$" && [ "$(cat "$S/body")" = ":starts with a colon" ] && pass "colons at the header/body boundary" || fail "colon framing: $(echo "$H" | grep -i x-odd) / $(cat "$S/body")"
[ "$(curl -s -m 5 "$U/meta")" = "http id 127.0.0.1" ] && pass "scheme, request_id, remote_addr" || fail "meta: $(curl -s -m 5 "$U/meta")"
[ "$(curl -s -m 5 -H 'X-A: 1' "$U/hdr" | tr ',' '\n' | grep '^x-a=')" = "x-a=1" ] && pass "request headers" || fail "request headers: $(curl -s -m 5 -H 'X-A: 1' "$U/hdr")"
R=$(curl -s -m 5 -H "Content-Type: application/json" -d '{"a":[1,"x"],"b":{"c":null}}' "$U/json")
[ "$R" = '{"got":{"a":[1,"x"],"b":{"c":null}}}' ] && pass "JSON in and out" || fail "json: $R"

echo "binary safety"
[ "$(curl -s -m 5 "$U/bin" | xxd -p)" = "4142004344004546fffe" ] && pass "response with NUL and high bytes" || fail "binary response: $(curl -s -m 5 "$U/bin" | xxd -p)"
R=$(printf 'AB\0CD\0EFG' | curl -s -m 5 --data-binary @- -H "Content-Type: application/octet-stream" "$U/len")
[ "$R" = 9 ] && pass "request body with NUL bytes arrives whole (9 bytes)" || fail "body length seen by Perl: $R"
head -c 300000 /dev/urandom > "$S/rand.bin"
WANT=$(python3 -c "import sys; print(sum(open(sys.argv[1],'rb').read()))" "$S/rand.bin")
R=$(curl -s -m 10 --data-binary @"$S/rand.bin" -H "Content-Type: application/octet-stream" "$U/sum")
[ "$R" = "$WANT" ] && pass "300 KB of random bytes arrive unchanged" || fail "byte sum $R, expected $WANT"
[ "$(curl -s -m 5 "$U/utf" | xxd -p)" = "636166c3a920e298ba" ] && pass "wide characters go out as UTF-8" || fail "utf: $(curl -s -m 5 "$U/utf" | xxd -p)"

echo "errors"
H=$(hdrs "$U/die")
echo "$H" | grep -q "^HTTP/1.1 500" && ! grep -q "hunter2\|db.conf" "$S/body" && pass "die -> 500 without the message" || fail "die: $(echo "$H" | head -1) body: $(head -c 120 "$S/body")"
grep -q "hunter2" "$S/server.log" && pass "the message is in the server log" || fail "die message not logged"
H=$(hdrs "$U/exit")
echo "$H" | grep -q "^HTTP/1.1 200" && [ "$(cat "$S/body")" = "before exit" ] && pass "exit() ends the request with the response built so far" || fail "exit -> $(echo "$H" | head -1) $(cat "$S/body")"
sleep 0.3
! grep -q "exited, respawning" "$S/server.log" && pass "exit() did not kill the worker" || fail "worker died on exit()"

echo "fork"
R=$(curl -s -m 5 "$U/fork?f=$S/forked")
sleep 0.3
LISTENERS=$(ss -ltnpH "sport = :$P" | grep -o "pid=[0-9]*" | sort -u | wc -l)
[ "$R" = "forked 0" ] && grep -q "^child " "$S/forked" && pass "a child forked by a handler runs and exit()s" || fail "fork in handler: '$R' $(cat "$S/forked" 2>/dev/null)"
[ "$LISTENERS" = 2 ] && pass "the forked child did not stay behind as an extra server ($LISTENERS processes on the port: master + worker)" || fail "$LISTENERS processes hold the listening socket after fork+exit"
read -r LOADED NOW CHILD <<< "$(curl -s -m 5 "$U/pids")"
[ -n "$LOADED" ] && [ "$LOADED" != "$NOW" ] && pass "script compiled once in the master ($LOADED), served by worker $NOW" || fail "pids: $LOADED $NOW"
[ "$CHILD" = "$NOW" ] && pass "child_init ran in the worker" || fail "child_init pid $CHILD, worker $NOW"

echo "memory"
WPID=$NOW
head -c 8192 /dev/zero | tr '\0' 'x' > "$S/body8k"
python3 - "$P" "$S/body8k" <<'PY'
import http.client, sys
body = open(sys.argv[2], "rb").read()
c = http.client.HTTPConnection("127.0.0.1", int(sys.argv[1]))
for i in range(20000):
    c.request("POST", "/len", body, {"Content-Type": "text/plain"})
    r = c.getresponse(); r.read()
    if r.getheader("Connection", "").lower() == "close":
        c.close(); c = http.client.HTTPConnection("127.0.0.1", int(sys.argv[1]))
PY
R1=$(awk '/VmRSS/{print $2}' /proc/$WPID/status 2>/dev/null)
python3 - "$P" "$S/body8k" <<'PY'
import http.client, sys
body = open(sys.argv[2], "rb").read()
c = http.client.HTTPConnection("127.0.0.1", int(sys.argv[1]))
for i in range(20000):
    c.request("POST", "/len", body, {"Content-Type": "text/plain"})
    r = c.getresponse(); r.read()
    if r.getheader("Connection", "").lower() == "close":
        c.close(); c = http.client.HTTPConnection("127.0.0.1", int(sys.argv[1]))
PY
R2=$(awk '/VmRSS/{print $2}' /proc/$WPID/status 2>/dev/null)
[ -n "$R1" ] && [ -n "$R2" ] && [ $((R2 - R1)) -lt 4096 ] && pass "worker RSS ${R1} kB -> ${R2} kB over 20,000 more requests with 8 KB bodies" || fail "worker RSS grew ${R1} kB -> ${R2} kB"
stop $P

echo "different seeds per worker"
"$BIN" -h 127.0.0.1 -p $((P+1)) -w 4 -l "$LIB:script=$S/app.pl;handler=T::handle" > "$S/server2.log" 2>&1 &
disown
for _ in $(seq 1 80); do curl -s -o /dev/null "http://127.0.0.1:$((P+1))/up" && break; sleep 0.1; done
: > "$S/rands"
for i in $(seq 1 24); do curl -s -m 5 -H "Connection: close" "http://127.0.0.1:$((P+1))/rand" >> "$S/rands"; echo >> "$S/rands"; done
[ "$(sort -u "$S/rands" | wc -l)" = 24 ] && pass "24 rand() values from 4 workers, all different" || fail "repeated rand() values: $(sort "$S/rands" | uniq -d | head -3 | tr '\n' ' ')"
stop $((P+1))

echo "startup errors"
OUT=$(timeout 5 "$BIN" -h 127.0.0.1 -p $((P+1)) -w 1 -l "$LIB:script=$S/missing.pl;handler=T::handle" 2>&1); RC=$?
echo "$OUT" | grep -q "cannot read" && [ $RC -ne 124 ] && pass "a missing script stops startup: $(echo "$OUT" | grep 'cannoli_perl' | head -1)" || fail "missing script: rc=$RC $(echo "$OUT" | tail -2)"
stop $((P+1))
OUT=$(timeout 5 "$BIN" -h 127.0.0.1 -p $((P+1)) -w 1 -l "$LIB:script=$S/app.pl;handler=T::nosuch" 2>&1); RC=$?
echo "$OUT" | grep -q "handler T::nosuch is not defined" && [ $RC -ne 124 ] && pass "an undefined handler stops startup" || fail "undefined handler: rc=$RC $(echo "$OUT" | tail -2)"
stop $((P+1))
printf 'package B; sub handle { ; \n' > "$S/broken.pl"
OUT=$(timeout 5 "$BIN" -h 127.0.0.1 -p $((P+1)) -w 1 -l "$LIB:script=$S/broken.pl;handler=B::handle" 2>&1); RC=$?
echo "$OUT" | grep -qi "syntax error\|Missing right curly" && [ $RC -ne 124 ] && pass "a script that does not compile stops startup" || fail "broken script: rc=$RC $(echo "$OUT" | tail -2)"
stop $((P+1))

[ $FAILS -eq 0 ] && echo "All Perl library tests passed!" || { echo "$FAILS failure(s)"; exit 1; }
