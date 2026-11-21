#!/bin/bash
# End-to-end tests: loop and classic workers, HTTP and HTTPS, password and
# password-hash logins. Uses a throwaway state directory.
HERE="$(cd "$(dirname "$0")/.." && pwd)"
for tool in python3 openssl; do command -v $tool >/dev/null || { echo "SKIP: $tool not installed"; exit 0; }; done
[ -f "$HERE/terminale.so" ] || "$HERE/build.sh" --fast >/dev/null
S="$(mktemp -d)"; MPID=""
cleanup() {
    [ -n "$MPID" ] && kill "$MPID" 2>/dev/null
    for sock in "$S"/state*/sessions/*.sock; do [ -S "$sock" ] && python3 -c "
import socket,sys
s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(b'K\0\0\0\0')" "$sock" 2>/dev/null; done
    sleep 0.3; rm -rf "$S"
    [ -n "$P" ] && for n in 0 1 2 5; do rm -f "${TMPDIR:-/tmp}/terminale-$(id -u)-$((P+n)).conf"; done
}
trap cleanup EXIT
mkdir -p "$S/home"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$S/key.pem" -out "$S/cert.pem" -days 2 -subj /CN=localhost >/dev/null 2>&1
HASH=$(openssl passwd -6 'hashed pass;word')
FAILS=0
run() {   # name, base url, password, start.sh args...
    local name="$1" url="$2" pass="$3"; shift 3
    echo "== $name"
    "$HERE/start.sh" "$@" > "$S/server.log" 2>&1 &
    MPID=$!
    for _ in $(seq 1 60); do curl -sk -o /dev/null "$url" && break; sleep 0.1; done
    python3 "$HERE/t/client.py" "$url" tester "$pass" || FAILS=$((FAILS+1))
    grep -E "respawning|Uncaught" "$S/server.log" && { echo "  FAIL: worker crashed"; FAILS=$((FAILS+1)); }
    kill -TERM $MPID; wait $MPID 2>/dev/null; MPID=""
}
P=$(( 20000 + RANDOM % 20000 ))
printf 'user = tester\npassword = "plain;pw:1"\ndir = %s/state1\n' "$S" > "$S/a.conf"
run "loop workers, HTTP, config-file password" "http://127.0.0.1:$P/" 'plain;pw:1' -c "$S/a.conf" -p $P
printf 'user = tester\npassword_hash = %s\ndir = %s/state2\n' "$HASH" "$S" > "$S/b.conf"
run "loop workers, HTTPS, password hash" "https://127.0.0.1:$((P+1))/" 'hashed pass;word' -c "$S/b.conf" -p $((P+1)) --tls "$S/cert.pem" "$S/key.pem"
printf 'dir = %s/state3\n' "$S" > "$S/c.conf"
HOME="$S/home" TERMINALE_USER=tester TERMINALE_PASSWORD='env-pw' run "environment login, --ssl (self-signed HTTPS)" "https://127.0.0.1:$((P+2))/" 'env-pw' -c "$S/c.conf" -p $((P+2)) --ssl
SANS=$(openssl x509 -in "$S/home/.terminale/tls/cert.pem" -noout -ext subjectAltName 2>/dev/null)
echo "$SANS" | grep -q "DNS:localhost" && echo "$SANS" | grep -q "IP Address:127.0.0.1" && [ "$(stat -c %a "$S/home/.terminale/tls/key.pem")" = 600 ] \
    && echo "  PASS: self-signed certificate generated (localhost + 127.0.0.1, private key 0600)" || { echo "  FAIL: self-signed certificate: $SANS"; FAILS=$((FAILS+1)); }
grep -q "SHA-256 " "$S/server.log" && echo "  PASS: fingerprint printed at start" || { echo "  FAIL: no fingerprint in the start output"; FAILS=$((FAILS+1)); }
echo "== classic workers, login on the -l line"
"$HERE/../cannoli" -h 127.0.0.1 -p $((P+3)) -w 4 -l "$HERE/terminale.so:static=$HERE/static;user=tester;password=param-pw;dir=$S/state4" > "$S/server.log" 2>&1 &
MPID=$!
for _ in $(seq 1 60); do curl -s -o /dev/null "http://127.0.0.1:$((P+3))/" && break; sleep 0.1; done
python3 "$HERE/t/client.py" "http://127.0.0.1:$((P+3))/" tester param-pw || FAILS=$((FAILS+1))
kill -TERM $MPID; wait $MPID 2>/dev/null; MPID=""
echo "== two-factor sign-in"
SECRET=JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP
printf 'user = tester\npassword = pw\ntotp_secret = %s\ndir = %s/state6\n' "$SECRET" "$S" > "$S/t.conf"
"$HERE/start.sh" -c "$S/t.conf" -p $((P+5)) > "$S/server.log" 2>&1 &
MPID=$!
for _ in $(seq 1 60); do curl -s -o /dev/null "http://127.0.0.1:$((P+5))/" && break; sleep 0.1; done
python3 - "$((P+5))" "$SECRET" <<'PY' || FAILS=$((FAILS+1))
import base64, hashlib, hmac, http.client, struct, sys, time, urllib.parse
port, secret = int(sys.argv[1]), sys.argv[2]
def code(offset=0):
    key = base64.b32decode(secret)
    mac = hmac.new(key, struct.pack(">Q", int(time.time()) // 30 + offset), hashlib.sha1).digest()
    o = mac[-1] & 15
    return "%06d" % ((struct.unpack(">I", mac[o:o + 4])[0] & 0x7fffffff) % 1000000)
def login(**f):
    c = http.client.HTTPConnection("127.0.0.1", port)
    c.request("POST", "/login", urllib.parse.urlencode(f), {"Content-Type": "application/x-www-form-urlencoded"})
    r = c.getresponse(); r.read(); c.close()
    return r.status
fails = 0
def check(ok, name):
    global fails
    print(("  PASS: " if ok else "  FAIL: ") + name)
    fails += 0 if ok else 1
c = http.client.HTTPConnection("127.0.0.1", port); c.request("GET", "/"); page = c.getresponse().read().decode(); c.close()
check('id="code"' in page and 'maxlength="6" autocomplete="one-time-code" hidden' not in page, "login page asks for a code")
check(login(username="tester", password="pw") == 401, "password alone is not enough")
check(login(username="tester", password="pw", code="000000") == 401, "wrong code rejected")
good = code()
check(login(username="tester", password="pw", code=good) == 200, "password + current code signs in")
check(login(username="tester", password="pw", code=good) == 401, "the same code cannot be used twice")
sys.exit(1 if fails else 0)
PY
kill -TERM $MPID; wait $MPID 2>/dev/null; MPID=""

echo "== worker recycling hands terminals over"
printf 'user = tester\npassword = pw\ndir = %s/state7\n' "$S" > "$S/r.conf"
"$HERE/../cannoli" -h 127.0.0.1 -p $((P+6)) -w 2 --loop-workers --max-requests 15 -l "$HERE/terminale.so:static=$HERE/static;config=$S/r.conf" > "$S/server.log" 2>&1 &
MPID=$!
for _ in $(seq 1 60); do curl -s -o /dev/null "http://127.0.0.1:$((P+6))/" && break; sleep 0.1; done
python3 - "$HERE/t/client.py" "http://127.0.0.1:$((P+6))/" <<'PY' || FAILS=$((FAILS+1))
import sys
src = open(sys.argv[1]).read().split('print("pages and login")')[0]
sys.argv = ["client", sys.argv[2], "tester", "pw"]
exec(src)
r, _ = call("POST", "/login", {"username": "tester", "password": "pw"})
cookie = r.getheader("Set-Cookie").split(";")[0]
r, body = call("POST", "/api/sessions", {"cols": 80, "rows": 24}, cookie=cookie)
sid = json.loads(body)["id"]
ws = WS("/ws/" + sid, cookie); ws.send(b"R80 24"); ws.send(b"Iexport MARK=still-here\r"); ws.drain()
for _ in range(60): call("GET", "/", cookie=cookie)        # push both workers past max_requests
code = None
ws.s.settimeout(12)
try:
    while True:
        ws._need(2)
        op, n = ws.buf[0] & 15, ws.buf[1] & 127
        ws._need(2 + n)
        if op == 8: code = struct.unpack("!H", ws.buf[2:4])[0]; break
        ws.buf = ws.buf[2 + n:] if n < 126 else b""
except Exception as e:
    pass
check(code == 1012, "draining worker closes the terminal with 1012 (got %s)" % code)
time.sleep(0.5)
ws = WS("/ws/" + sid, cookie)
ws.send(b"Iecho $MARK\r")
check(ws.status == 101 and b"still-here\r\n" in ws.read_until(b"still-here\r\n"), "reconnect lands on a fresh worker; the session carried on")
call("POST", "/api/sessions/" + sid + "/kill", cookie=cookie)
sys.exit(1 if fails else 0)
PY
grep -q "respawning" "$S/server.log" && echo "  PASS: workers were recycled" || { echo "  FAIL: no worker was recycled"; FAILS=$((FAILS+1)); }
kill -TERM $MPID; wait $MPID 2>/dev/null; MPID=""

echo "== refuses to start without a login"
OUT=$("$HERE/../cannoli" -h 127.0.0.1 -p $((P+4)) -w 1 -l "$HERE/terminale.so:static=$HERE/static;dir=$S/state5" 2>&1 & sleep 1.5; kill $! 2>/dev/null)
echo "$OUT" | grep -q "refusing to start without" && echo "  PASS: no credentials, module not loaded" || { echo "  FAIL: $OUT" | head -3; FAILS=$((FAILS+1)); }
[ $FAILS -eq 0 ] && echo "All Terminale tests passed!" || { echo "$FAILS failing group(s)"; exit 1; }
