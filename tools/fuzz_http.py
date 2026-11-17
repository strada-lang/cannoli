#!/usr/bin/env python3
"""Network fuzzer for a running Cannoli: sends mutated / malformed HTTP
requests over many concurrent connections for a while, then checks that the
server still answers a normal request.

usage: fuzz_http.py HOST PORT [SECONDS] [SEED] [CONNS]
Exit status 1 if the server stops answering.
"""
import random, socket, ssl, sys, threading, time

host, port = sys.argv[1], int(sys.argv[2])
seconds = float(sys.argv[3]) if len(sys.argv) > 3 else 20
seed = int(sys.argv[4]) if len(sys.argv) > 4 else 1
conns = int(sys.argv[5]) if len(sys.argv) > 5 else 16

SEEDS = [
    b"GET /hello HTTP/1.1\r\nHost: x\r\n\r\n",
    b"POST /submit HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\na=1&b",
    b"POST /submit HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5;e=1\r\npedia\r\n0\r\nT: 1\r\n\r\n",
    b"GET /echo?message=%41%zz&x=1 HTTP/1.1\r\nHost: x\r\nCookie: a=1; b\r\nRange: bytes=0-1,5-\r\n\r\n",
    b"POST /submit HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 3\r\n\r\nabc",
    b"GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n\x81\x85\x00\x00\x00\x00hello",
    b"GET http://x/json HTTP/1.0\r\n\r\n",
]
TOKENS = [b"\r\n", b"\n", b"\r", b":", b" ", b"\t", b";", b",", b"\x00", b"\xff", b"0", b"ffffffffffffffff",
          b"Content-Length: 99999999999\r\n", b"Transfer-Encoding: chunked\r\n", b"Host: y\r\n", b"%", b"..", b"/../",
          b"\r\n\r\n", b"Content-Length: -1\r\n", b"Expect: 100-continue\r\n", b"A" * 9000]

def mutate(rng, data):
    b = bytearray(data)
    for _ in range(rng.randint(1, 6)):
        op = rng.randrange(6)
        pos = rng.randrange(len(b) + 1) if b else 0
        if op == 0 and b:
            b[min(pos, len(b) - 1)] = rng.randrange(256)
        elif op == 1:
            b[pos:pos] = rng.choice(TOKENS)
        elif op == 2 and b:
            del b[pos:pos + rng.randint(1, 16)]
        elif op == 3:
            del b[pos:]
        elif op == 4:
            b[pos:pos] = bytes(rng.randrange(256) for _ in range(rng.randint(1, 32)))
        else:
            b += rng.choice(SEEDS)          # pipelined follow-up
    return bytes(b)

stats = {"sent": 0, "errors": 0}
lock = threading.Lock()
deadline = time.time() + seconds

def worker(n):
    rng = random.Random(seed * 1000 + n)
    while time.time() < deadline:
        try:
            s = socket.create_connection((host, port), timeout=3)
            s.settimeout(0.4)   # don't wait out the server's timeouts: more inputs per second
            payload = mutate(rng, rng.choice(SEEDS))
            # sometimes dribble it in pieces, sometimes stop half way
            if rng.random() < 0.3:
                for i in range(0, len(payload), 7):
                    s.sendall(payload[i:i + 7])
            else:
                s.sendall(payload)
            if rng.random() < 0.2:
                s.shutdown(socket.SHUT_WR)
            try:
                s.recv(65536)
            except Exception:
                pass
            s.close()
            with lock:
                stats["sent"] += 1
        except Exception:
            with lock:
                stats["errors"] += 1
            time.sleep(0.01)

threads = [threading.Thread(target=worker, args=(i,)) for i in range(conns)]
for t in threads: t.start()
for t in threads: t.join()

ok = False
for _ in range(20):
    try:
        s = socket.create_connection((host, port), timeout=5)
        s.sendall(b"GET /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        d = s.recv(100)
        ok = d.startswith(b"HTTP/1.1 200")
        s.close()
        if ok: break
    except Exception:
        pass
    time.sleep(0.25)
print("fuzz: %d requests, %d connection errors, server %s" % (stats["sent"], stats["errors"], "OK" if ok else "NOT RESPONDING"))
sys.exit(0 if ok else 1)
