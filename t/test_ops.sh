#!/bin/bash
# Operations features: health check, Prometheus metrics, per-client
# connection and rate limits, SIGHUP configuration + certificate reload,
# TLS settings (chain, min version, ALPN) and systemd notifications.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${BIN:-$ROOT/cannoli}"
for tool in curl python3 openssl nc; do command -v $tool >/dev/null || { echo "SKIP: $tool not installed"; exit 0; }; done
P1=$(( 20000 + RANDOM % 20000 )); P2=$((P1 + 1))
S="$(mktemp -d)"; MPID=""; NPID=""
cleanup() { [ -n "$MPID" ] && kill -9 "$MPID" 2>/dev/null; [ -n "$NPID" ] && kill "$NPID" 2>/dev/null; rm -rf "$S"; }
trap cleanup EXIT
trap "" PIPE
cd "$S"
FAILS=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAILS=$((FAILS+1)); }

# CA -> intermediate -> leaf, so serving the full chain can be checked
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 2 -subj /CN=TestRoot >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout int.key -out int.csr -subj /CN=TestIntermediate >/dev/null 2>&1
printf 'basicConstraints=critical,CA:true\nkeyUsage=critical,keyCertSign\n' > int.ext
openssl x509 -req -in int.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out int.pem -days 2 -extfile int.ext >/dev/null 2>&1
mkleaf() {
  openssl req -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr -subj "/CN=$1" >/dev/null 2>&1
  printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\n' > leaf.ext
  openssl x509 -req -in leaf.csr -CA int.pem -CAkey int.key -CAcreateserial -out leaf.pem -days 2 -extfile leaf.ext >/dev/null 2>&1
  cat leaf.pem int.pem > fullchain.pem
}
mkleaf leaf-one

# systemd notification socket stand-in
python3 - "$S/notify.sock" > notify.log <<'PY' &
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM); s.bind(sys.argv[1])
while True:
    d = s.recv(4096).decode(); print(d.replace("\n", " | "), flush=True)
PY
NPID=$!
sleep 0.3

write_conf() {
cat > ops.conf <<EOF
[server]
host = 127.0.0.1
port = $P1
workers = 2
health_path = /healthz
max_connections_per_ip = 1
rate_limit = $1
rate_limit_window = 2
[admin]
enabled = 1
[headers]
X-Gen = $2
[ssl]
enabled = 1
port = $P2
cert = $S/fullchain.pem
key = $S/leaf.key
min_version = 1.3
EOF
}
write_conf 5 one
NOTIFY_SOCKET="$S/notify.sock" "$BIN" --config ops.conf --demo -w 3 > server.log 2>&1 &
MPID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null http://127.0.0.1:$P1/healthz && break; sleep 0.1; done

echo "health + systemd"
H=$(curl -s http://127.0.0.1:$P1/healthz)
echo "$H" | grep -q '"status":"ok","workers":3' && pass "health: $H" || fail "health: $H"
grep -q "READY=1 | MAINPID=$MPID" notify.log && pass "READY=1 with MAINPID" || fail "notify: $(cat notify.log)"

echo "rate limit (5 per 2s)"
sleep 2
CODES=$(for i in 1 2 3 4 5 6 7; do curl -s -o /dev/null -w "%{http_code} " http://127.0.0.1:$P1/hello; done)
echo "$CODES" | grep -q "^200 200 200 200 200 429 429" && pass "$CODES" || fail "codes: $CODES"
C=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:$P1/healthz)
[ "$C" = 200 ] && pass "health exempt from rate limit" || fail "health -> $C"

echo "connection limit (1 per address)"
sleep 2.1
( exec 3<>/dev/tcp/127.0.0.1/$P1; sleep 3 ) &
HOLD=$!
sleep 0.3
R=$(printf 'GET /hello HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n' | timeout 3 nc 127.0.0.1 $P1 | head -1 | tr -d '\r')
[ "$R" = "HTTP/1.1 429 Too Many Requests" ] && pass "second connection refused" || fail "second connection -> $R"
kill $HOLD 2>/dev/null; wait $HOLD 2>/dev/null
sleep 2.1

echo "metrics"
M=$(curl -s http://127.0.0.1:$P1/__admin/metrics)
echo "$M" | grep -q '^cannoli_requests_total{code="2xx"} [1-9]' && pass "request counters" || fail "metrics: $(echo "$M" | head -5)"
echo "$M" | grep -q 'cannoli_rejected_total{reason="rate_limit"} [1-9]' && echo "$M" | grep -q 'cannoli_rejected_total{reason="connection_limit"} [1-9]' && pass "rejection counters" || fail "rejections: $(echo "$M" | grep rejected)"
echo "$M" | grep -q 'cannoli_request_duration_seconds_bucket{le="+Inf"}' && pass "latency histogram" || fail "histogram missing"

echo "TLS settings"
OUT=$(echo | openssl s_client -connect 127.0.0.1:$P2 -CAfile ca.pem -alpn h2,http/1.1 -servername localhost 2>/dev/null)
echo "$OUT" | grep -q "Verify return code: 0 (ok)" && pass "full chain served (verifies against the root)" || fail "chain: $(echo "$OUT" | grep -i verify)"
echo "$OUT" | grep -q "ALPN protocol: http/1.1" && pass "ALPN http/1.1" || fail "ALPN: $(echo "$OUT" | grep -i alpn)"
OUT12=$(echo | openssl s_client -connect 127.0.0.1:$P2 -tls1_2 2>&1)
echo "$OUT12" | grep -q "Cipher is (NONE)" && pass "TLS 1.2 refused (min_version 1.3)" || fail "TLS 1.2 accepted with min_version 1.3"

echo "SIGHUP reload"
mkleaf leaf-two
write_conf 100 two
kill -HUP $MPID; sleep 2.5
G=$(curl -s -D - -o /dev/null http://127.0.0.1:$P1/hello | tr -d '\r' | grep '^X-Gen:')
[ "$G" = "X-Gen: two" ] && pass "config change applied" || fail "after reload: '$G'"
CN=$(echo | openssl s_client -connect 127.0.0.1:$P2 -servername localhost 2>/dev/null | openssl x509 -noout -subject 2>/dev/null)
echo "$CN" | grep -q "leaf-two" && pass "renewed certificate served" || fail "certificate after reload: $CN"
grep -q "RELOADING=1" notify.log && pass "RELOADING/READY notified" || fail "no RELOADING"
H=$(curl -s http://127.0.0.1:$P1/healthz)
echo "$H" | grep -q '"workers":3' && pass "-w 3 from the command line kept across reload" || fail "workers after reload: $H"
echo "port = notanumber" >> ops.conf
kill -HUP $MPID; sleep 1.5
grep -q "invalid configuration, keeping the running one" server.log && pass "invalid config rejected" || fail "invalid config not reported"
C=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:$P1/hello)
[ "$C" = 200 ] && pass "still serving after rejected reload" || fail "after bad reload -> $C"

kill -TERM $MPID; for _ in $(seq 1 100); do kill -0 $MPID 2>/dev/null || break; sleep 0.05; done
kill -0 $MPID 2>/dev/null && fail "master did not exit" || MPID=""
grep -q "STOPPING=1" notify.log && pass "STOPPING=1" || fail "no STOPPING"
[ $FAILS -eq 0 ] && echo "All operations tests passed!" || { echo "$FAILS failure(s)"; exit 1; }
