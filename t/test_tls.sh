#!/bin/bash
# {classic, loop workers} x {HTTP, HTTPS}: GET, POST body, keep-alive, error
# paths, and a silent TLS client that must not pin a worker. Skipped when
# openssl or the Strada SSL library is unavailable.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for tool in curl python3 bc nc; do command -v $tool >/dev/null || { echo "SKIP: $tool not installed"; exit 0; }; done
BIN="${BIN:-$ROOT/cannoli}"
SSL_LIB="${STRADA_SSL_LIB:-/usr/local/lib/strada/lib/ssl/libstrada_ssl.so}"
if ! command -v openssl >/dev/null || [ ! -f "$SSL_LIB" ]; then echo "SKIP: openssl or $SSL_LIB not available"; exit 0; fi
P1=$(( 20000 + RANDOM % 20000 )); P2=$((P1 + 1))
S="$(mktemp -d)"
MPID=""
cleanup() { [ -n "$MPID" ] && kill -9 "$MPID" 2>/dev/null; rm -rf "$S"; }
trap cleanup EXIT
cd $S
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 2 -subj /CN=localhost >/dev/null 2>&1
FAILS=0
trap "" PIPE
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAILS=$((FAILS+1)); }

for MODE in classic loop; do
  LOOP=0; [ $MODE = loop ] && LOOP=1
  cat > tls.conf <<EOF
[server]
host = 127.0.0.1
port = $P1
workers = 1
loop_workers = $LOOP
header_timeout = 2
timeout = 2
[ssl]
enabled = 1
port = $P2
cert = $S/cert.pem
key = $S/key.pem
EOF
  $BIN --config tls.conf --demo > tls_$MODE.log 2>&1 &
  MPID=$!
  for _ in $(seq 1 50); do curl -sk -o /dev/null https://127.0.0.1:$P2/hello && break; sleep 0.1; done
  for SCHEME in http https; do
    P=$P1; [ $SCHEME = https ] && P=$P2
    U=$SCHEME://127.0.0.1:$P
    echo "[$MODE $SCHEME]"
    R=$(curl -sk $U/hello); [ "$R" = "Hello, World!" ] && pass GET || fail "GET -> $R"
    R=$(head -c 200000 /dev/zero | tr '\0' b | curl -sk -X POST --data-binary @- $U/submit)
    echo "$R" | grep -q '"body_length":"200000"' && pass "POST 200KB" || fail "POST -> $R"
    N=$(curl -sk -v $U/hello $U/json $U/hello 2>&1 | grep -c "Re-using existing connection\|Reusing existing")
    [ "$N" -ge 2 ] && pass "keep-alive reuse ($N)" || fail "keep-alive reuse count $N"
    C=$(curl -sk -o /dev/null -w "%{http_code}" -H "Content-Length: 99999999999" -X POST $U/submit)
    [ "$C" = 413 ] && pass "413 error path" || fail "413 -> $C"
    C=$(curl -sk -o /dev/null -w "%{http_code}" $U/nope)
    [ "$C" = 404 ] && pass "404" || fail "404 -> $C"
  done
  echo "[$MODE] silent TLS client cannot pin the worker"
  ( exec 3<>/dev/tcp/127.0.0.1/$P2; sleep 6 ) &
  SP=$!
  sleep 0.3
  T0=$(date +%s.%N); C=$(curl -sk -m 10 -o /dev/null -w "%{http_code}" https://127.0.0.1:$P2/hello); T1=$(date +%s.%N)
  W=$(echo "$T1 - $T0" | bc)
  [ "$C" = 200 ] && (( $(echo "$W < 3.5" | bc) )) && pass "served after ${W}s" || fail "code=$C after ${W}s"
  kill $SP 2>/dev/null
  kill -TERM $MPID; for _ in $(seq 1 100); do kill -0 $MPID 2>/dev/null || break; sleep 0.05; done
  kill -0 $MPID 2>/dev/null && { fail "master did not exit within 5s of SIGTERM"; kill -9 $MPID; }
  MPID=""
done
[ "$FAILS" -eq 0 ] && echo "All TLS integration tests passed!" || { echo "$FAILS failure(s)"; exit 1; }
