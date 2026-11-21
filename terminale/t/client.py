#!/usr/bin/env python3
"""End-to-end test client for Terminale: client.py BASE_URL USER PASSWORD"""
import base64, http.client, json, os, socket, ssl, struct, sys, time, urllib.parse

base, user, password = sys.argv[1], sys.argv[2], sys.argv[3]
u = urllib.parse.urlparse(base)
tls = u.scheme == "https"
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
prefix = u.path.rstrip("/")
fails = 0
def check(ok, name):
    global fails
    print(("  PASS: " if ok else "  FAIL: ") + name)
    if not ok: fails += 1

def call(method, path, body=None, cookie=None, headers=None):
    c = http.client.HTTPSConnection(u.hostname, u.port, context=ctx) if tls else http.client.HTTPConnection(u.hostname, u.port)
    h = dict(headers or {})
    if cookie: h["Cookie"] = cookie
    data = None
    if body is not None:
        data = urllib.parse.urlencode(body)
        h["Content-Type"] = "application/x-www-form-urlencoded"
    c.request(method, prefix + path, data, h)
    r = c.getresponse()
    out = r.read()
    c.close()
    return r, out

class WS:
    def __init__(self, path, cookie, origin=None):
        s = socket.create_connection((u.hostname, u.port))
        if tls: s = ctx.wrap_socket(s)
        s.settimeout(10)
        key = base64.b64encode(os.urandom(16)).decode()
        req = "GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n" % (prefix + path, u.hostname, u.port, key)
        if cookie: req += "Cookie: %s\r\n" % cookie
        if origin: req += "Origin: %s\r\n" % origin
        s.sendall((req + "\r\n").encode())
        self.s, self.buf = s, b""
        head = b""
        while b"\r\n\r\n" not in head:
            d = s.recv(1)
            if not d: break
            head += d
        self.status = int(head.split(b" ")[1]) if head else 0
    def send(self, payload):
        mask = os.urandom(4)
        n = len(payload)
        h = bytes([0x82]) + (bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack("!H", n) if n < 65536 else bytes([0x80 | 127]) + struct.pack("!Q", n))
        self.s.sendall(h + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))
    def _need(self, n):
        while len(self.buf) < n:
            d = self.s.recv(65536)
            if not d: raise EOFError
            self.buf += d
    def recv(self):
        while True:
            self._need(2)
            op, n = self.buf[0] & 15, self.buf[1] & 127
            off = 2
            if n == 126: self._need(4); n = struct.unpack("!H", self.buf[2:4])[0]; off = 4
            elif n == 127: self._need(10); n = struct.unpack("!Q", self.buf[2:10])[0]; off = 10
            self._need(off + n)
            p = self.buf[off:off + n]; self.buf = self.buf[off + n:]
            if op == 9: continue
            if op == 8: raise EOFError
            return p
    def read_until(self, needle, timeout=8):
        out, end = b"", time.time() + timeout
        while needle not in out and time.time() < end:
            try: m = self.recv()
            except (EOFError, socket.timeout): break
            if m[:1] == b"O": out += m[1:]
            elif m[:1] == b"X": out += b"<EXIT>"; break
        return out
    def expect(self, kind, timeout=5):
        """next message of type `kind` (a byte string like b"Z"), or None"""
        end = time.time() + timeout
        self.s.settimeout(timeout)
        while time.time() < end:
            try: m = self.recv()
            except (EOFError, socket.timeout, TimeoutError): return None
            if m[:1] == kind: return m[1:]
        return None
    def drain(self, quiet=0.6):
        """everything until the stream has been quiet for a moment"""
        out = b""
        self.s.settimeout(quiet)
        while True:
            try: m = self.recv()
            except (EOFError, socket.timeout, TimeoutError): break
            if m[:1] == b"O": out += m[1:]
        self.s.settimeout(10)
        return out
    def close(self):
        try: self.s.close()
        except Exception: pass

print("pages and login")
r, body = call("GET", "/")
check(r.status == 200 and b"Sign in" in body and b"xterm.js" not in body, "login page when signed out")
check("frame-ancestors 'none'" in (r.getheader("Content-Security-Policy") or ""), "CSP header")
r, _ = call("GET", "/api/sessions")
check(r.status == 401, "API needs a login (401)")
r, _ = call("GET", "/static/xterm.js")
check(r.status == 401, "terminal assets need a login")
check(WS("/ws/0123456789abcdef", None).status == 401, "WebSocket needs a login")
r, _ = call("POST", "/login", {"username": user, "password": "wrong"})
check(r.status == 401, "wrong password rejected")
r, _ = call("POST", "/login", {"username": user, "password": password}, headers={"Origin": "https://evil.example"})
check(r.status == 403, "cross-site login POST rejected")
r, _ = call("POST", "/login", {"username": user, "password": password})
sc = r.getheader("Set-Cookie") or ""
cookie = sc.split(";")[0]
check(r.status == 200 and "HttpOnly" in sc and "SameSite=Strict" in sc and len(cookie) > 70, "login sets an HttpOnly SameSite cookie")
check(("Secure" in sc) == tls, "Secure flag matches the scheme")
r, body = call("GET", "/", cookie=cookie)
check(r.status == 200 and b"static/xterm.js" in body, "app page when signed in")
r, body = call("GET", "/static/xterm.js", cookie=cookie, headers={"Accept-Encoding": "gzip"})
check(r.status == 200 and r.getheader("Content-Encoding") == "gzip" and len(body) < 200000, "xterm.js served gzipped (%d bytes)" % len(body))

print("sessions")
r, body = call("POST", "/api/sessions", {"cols": 100, "rows": 30}, cookie=cookie)
info = json.loads(body)
sid = info.get("id", "")
check(r.status == 200 and len(sid) == 16, "create session")
ws = WS("/ws/" + sid, cookie)
check(ws.status == 101, "WebSocket attach")
check(WS("/ws/" + sid, cookie, origin="https://evil.example").status == 403, "cross-site WebSocket refused")
ws.send(b"R100 30")
ws.send(b"Iecho mark-$((6*7))-$TERMINALE-$(id -un); stty size\r")
out = ws.read_until(b"30 100")
if b"mark-42-1-" not in out: print("    got:", out[-300:])
check(b"mark-42-1-" in out and b"30 100" in out, "shell runs with the window size set")
ws.send(b"Iexport KEEP=persisted-state\r")
ws.send(b"Tmy title")
ws.send(b"Iprintf 'caf\\xc3\\xa9 \\xe2\\x9c\\x93 done\\n'\r")
out = ws.read_until(b"done\r\n")
check("café ✓ done".encode() in out, "UTF-8 output intact")
ws.close()
time.sleep(0.4)
r, body = call("GET", "/api/sessions", cookie=cookie)
lst = json.loads(body)
mine = [s for s in lst["sessions"] if s["id"] == sid]
check(len(mine) == 1 and mine[0]["title"] == "my title" and mine[0]["cols"] == 100, "session survives the closed tab (title, size kept)")

ws = WS("/ws/" + sid, cookie)
first = ws.recv()
check(first[:1] == b"S" and first[1:] == b"100 30", "re-attach starts with the session size")
replay = ws.read_until(b"done\r\n", timeout=4)
check(b"mark-42" in replay, "scrollback replayed on re-attach")
ws.send(b"Iecho $KEEP\r")
check(b"persisted-state\r\n" in ws.read_until(b"persisted-state\r\n"), "shell state kept across re-attach")

print("throughput and flow")
ws.send(b"Ihead -c 20000000 /dev/zero | tr '\\0' x; echo; echo END-OF-$((1+1))FLOOD\r")
t0, total, tail = time.time(), 0, b""
while time.time() - t0 < 30:
    m = ws.recv()
    if m[:1] == b"O":
        total += len(m) - 1
        tail = (tail + m[1:])[-2048:]
        if b"END-OF-2FLOOD" in tail: break
dt = time.time() - t0
check(total >= 20000000, "20MB of output relayed in %.2fs (%.0f MB/s)" % (dt, total / dt / 1e6))
ws.send(b"I" + b"echo " + b"p" * 60000 + b" | wc -c | sed s/^/n=/\r")
check(b"n=60001" in ws.read_until(b"n=60001", timeout=10), "60KB paste delivered")

print("settings")
r, body = call("GET", "/api/settings", cookie=cookie)
check(r.status == 200 and body.strip() == b"{}", "no settings saved yet")
r, _ = call("POST", "/api/settings", {"settings": '{"theme":"nord","fontSize":15}'}, cookie=cookie)
r2, body = call("GET", "/api/settings", cookie=cookie)
check(r.status == 200 and json.loads(body) == {"theme": "nord", "fontSize": 15}, "settings saved to the server and read back")
r, _ = call("POST", "/api/settings", {"settings": '{"theme": oops'}, cookie=cookie)
r2, _ = call("POST", "/api/settings", {"settings": '{"x":"' + "y" * 20000 + '"}'}, cookie=cookie)
check(r.status == 400 and r2.status == 400, "malformed and oversized settings refused")
r, _ = call("POST", "/api/settings", {"settings": "{}"}, cookie=cookie, headers={"Origin": "https://evil.example"})
check(r.status == 403, "cross-site settings change refused")
r, _ = call("GET", "/api/settings")
check(r.status == 401, "settings need a login")

print("files")
ws.drain()
ws.send(b"Icd \"$(mktemp -d)\" && echo here=$PWD=$((1+1))\r")
out = ws.read_until(b"=2\r\n")
import re
m = re.search(rb"here=(/[^=\r\n]+)=2\r", out)
workdir = m.group(1).decode() if m else ""
r, body = call("GET", "/api/files?session=" + sid, cookie=cookie)
listing = json.loads(body)
check(r.status == 200 and workdir != "" and listing.get("path") == workdir and listing.get("entries") == [], "file browser opens the terminal's current directory")
blob = bytes(range(256)) * 400 + b"\r\n--not-a-boundary\r\n"
def upload(name, data, fields):
    bnd = "----tm" + os.urandom(8).hex()
    parts = b""
    for k, v in fields.items():
        parts += ("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n" % (bnd, k, v)).encode()
    parts += ("--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"%s\"\r\nContent-Type: application/octet-stream\r\n\r\n" % (bnd, name)).encode() + data + ("\r\n--%s--\r\n" % bnd).encode()
    c = http.client.HTTPSConnection(u.hostname, u.port, context=ctx) if tls else http.client.HTTPConnection(u.hostname, u.port)
    c.request("POST", prefix + "/api/upload", parts, {"Cookie": cookie, "Content-Type": "multipart/form-data; boundary=" + bnd})
    r = c.getresponse(); out = r.read(); c.close()
    return r, out
r, body = upload("../../evil name.bin", blob, {"session": sid})
saved = json.loads(body).get("path", "")
check(r.status == 200 and saved == workdir + "/evil name.bin", "upload lands in the terminal's directory (path stripped from the name)")
r, body = upload("evil name.bin", b"second", {"path": workdir})
check(json.loads(body).get("path") == workdir + "/evil name (1).bin", "an existing file is not overwritten")
r, body = call("GET", "/api/files?path=" + urllib.parse.quote(workdir), cookie=cookie)
names = {e["name"]: e["size"] for e in json.loads(body)["entries"]}
check(names == {"evil name.bin": len(blob), "evil name (1).bin": 6}, "listing shows both files with sizes")
r, body = call("GET", "/api/download?path=" + urllib.parse.quote(saved), cookie=cookie)
check(r.status == 200 and body == blob and "attachment" in (r.getheader("Content-Disposition") or ""), "binary file downloads byte-for-byte")
r, _ = call("GET", "/api/download?path=/nonexistent/x", cookie=cookie)
r2, _ = call("GET", "/api/files?session=" + sid)
check(r.status == 404 and r2.status == 401, "missing file is a 404; files need a login")
ws.send(b"Icd; rm -rf '" + workdir.encode() + b"'\r")

print("terminal state on re-attach, shared size")
ws.send(b"Iprintf '\\033[?1002h\\033[?1006h\\033[?25l'; sleep 1; printf '\\033[?1002l\\033[?1006l\\033[?25h'\r")
time.sleep(0.4)
ws2 = WS("/ws/" + sid, cookie)
replay = ws2.drain(0.4)
check(replay.endswith(b"\x1b[?25l\x1b[?1002h\x1b[?1006h\x1b[?2004h") or (b"\x1b[?1002h" in replay[-80:] and b"\x1b[?1006h" in replay[-80:] and b"\x1b[?25l" in replay[-80:]),
      "mouse mode and hidden cursor restored for a browser attaching later")
time.sleep(1.0)
ws.send(b"R91 27")
z = ws2.expect(b"Z", 4)
check(z == b"91 27", "another attached browser is told the new size")
ws2.close()
ws.send(b"R100 30")
ws.drain()

print("sign-ins")
r, body = call("GET", "/api/logins", cookie=cookie)
lg = json.loads(body)
check(r.status == 200 and len(lg["active"]) == 1 and lg["active"][0]["current"] and lg["active"][0]["address"] == "127.0.0.1", "this sign-in is listed")
check([x["result"] for x in lg["recent"]][:2] == ["ok", "failed"], "recent attempts are recorded")
r, _ = call("POST", "/login", {"username": user, "password": password})
cookie2 = (r.getheader("Set-Cookie") or "").split(";")[0]
r, body = call("GET", "/api/logins", cookie=cookie)
check(len(json.loads(body)["active"]) == 2, "second browser listed")
r, body = call("POST", "/api/logins/revoke", {"others": "1"}, cookie=cookie)
r2, _ = call("GET", "/api/sessions", cookie=cookie2)
r3, _ = call("GET", "/api/sessions", cookie=cookie)
check(json.loads(body).get("revoked") == 1 and r2.status == 401 and r3.status == 200, "sign out everywhere else")

print("second tab, kill, exit")
r, body = call("POST", "/api/sessions", {"cols": 80, "rows": 24}, cookie=cookie)
sid2 = json.loads(body)["id"]
r, body = call("GET", "/api/sessions", cookie=cookie)
check(len(json.loads(body)["sessions"]) >= 2, "two sessions listed")
r, _ = call("POST", "/api/sessions/" + sid2 + "/kill", cookie=cookie)
time.sleep(1.2)
r, body = call("GET", "/api/sessions", cookie=cookie)
check(sid2 not in [s["id"] for s in json.loads(body)["sessions"]], "killed session is gone")
ws.send(b"Iexit\r")
check(b"<EXIT>" in ws.read_until(b"<EXIT>", timeout=6), "exit ends the session (X frame)")
ws.close()
time.sleep(0.3)
r, body = call("GET", "/api/sessions", cookie=cookie)
check(sid not in [s["id"] for s in json.loads(body)["sessions"]], "exited session is gone")

print("logout and lockout")
r, _ = call("POST", "/logout", cookie=cookie)
r, _ = call("GET", "/api/sessions", cookie=cookie)
check(r.status == 401, "logout invalidates the token")
for _ in range(5): call("POST", "/login", {"username": user, "password": "nope"})
r, _ = call("POST", "/login", {"username": user, "password": password})
check(r.status == 429, "locked out after repeated failures (even with the right password)")
print("FAILS=%d" % fails)
sys.exit(1 if fails else 0)
