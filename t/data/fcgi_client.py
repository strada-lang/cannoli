#!/usr/bin/env python3
"""Minimal FastCGI client: fcgi_client.py ADDR URI [URI...]
ADDR is host:port or a Unix socket path. All URIs go over one connection
with FCGI_KEEP_CONN; prints the response body of each (one per line)."""
import socket, struct, sys
addr, uris = sys.argv[1], sys.argv[2:]
def rec(t, rid, c): return struct.pack("!BBHHBB", 1, t, rid, len(c), 0, 0) + c
def nv(k, v): k = k.encode(); v = v.encode(); return bytes([len(k), len(v)]) + k + v
if addr.startswith("/"):
    s = socket.socket(socket.AF_UNIX); s.connect(addr)
else:
    h, p = addr.rsplit(":", 1); s = socket.create_connection((h, int(p)))
s.settimeout(5)
buf = b""
def read_record():
    global buf
    while len(buf) < 8:
        d = s.recv(65536)
        if not d: raise EOFError
        buf += d
    _, t, _, clen, plen, _ = struct.unpack("!BBHHBB", buf[:8])
    while len(buf) < 8 + clen + plen:
        d = s.recv(65536)
        if not d: raise EOFError
        buf += d
    c = buf[8:8 + clen]; buf = buf[8 + clen + plen:]
    return t, c
for uri in uris:
    params = b"".join(nv(k, v) for k, v in [("REQUEST_METHOD", "GET"), ("REQUEST_URI", uri), ("DOCUMENT_URI", uri), ("SERVER_PROTOCOL", "HTTP/1.1")])
    s.sendall(rec(1, 1, struct.pack("!HB5x", 1, 1)) + rec(4, 1, params) + rec(4, 1, b"") + rec(5, 1, b""))
    out = b""
    while True:
        t, c = read_record()
        if t == 6: out += c
        if t == 3: break
    print(out.split(b"\r\n\r\n", 1)[-1].decode(errors="replace").strip())
