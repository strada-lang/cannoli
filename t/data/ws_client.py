import socket, ssl, sys, os, base64, time, struct
port, tls, wait = int(sys.argv[1]), sys.argv[2] == "1", float(sys.argv[3])
def frame(op, payload, masked=True):
    mask = os.urandom(4)
    h = bytes([0x80 | op, (0x80 if masked else 0) | len(payload)])
    return h + (mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)) if masked else payload)
def conn():
    s = socket.create_connection(("127.0.0.1", port))
    if tls:
        ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
        s = ctx.wrap_socket(s)
    s.settimeout(20)
    return s
def upgrade(s, extra=b""):
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall(("GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % key).encode() + extra)
    hdr = b""
    while b"\r\n\r\n" not in hdr:
        hdr += s.recv(1)
    rest = hdr.split(b"\r\n\r\n", 1)[1]
    return hdr.startswith(b"HTTP/1.1 101"), rest
def read_frame(s, buf=b""):
    while len(buf) < 2: buf += s.recv(4096)
    n = buf[1] & 127
    while len(buf) < 2 + n: buf += s.recv(4096)
    return buf[0] & 15, buf[2:2+n]
out = []
s = conn(); ok, rest = upgrade(s, frame(1, b"early"))       # frame pipelined with the upgrade
op, p = read_frame(s, rest); out.append(ok and p == b"echo:early")
time.sleep(wait)                                            # idle longer than the SSL 5s wait limit
s.sendall(frame(1, b"after-idle")); op, p = read_frame(s); out.append(p == b"echo:after-idle")
s.sendall(frame(8, struct.pack("!H", 1000))); op, p = read_frame(s); out.append(op == 8)   # close handshake
s2 = conn(); ok, rest = upgrade(s2); s2.sendall(frame(1, b"x", masked=False))
op, p = read_frame(s2, rest); out.append(op == 8 and struct.unpack("!H", p[:2])[0] == 1002)  # unmasked -> 1002
print(" ".join("ok" if x else "FAIL" for x in out))
