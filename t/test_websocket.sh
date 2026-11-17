#!/bin/bash
# WebSockets from a dynamic library ($c->ws_* methods): echo, a frame
# pipelined behind the upgrade, 7s idle (longer than the SSL library's 5s
# wait limit), close handshake, and 1002 for an unmasked client frame --
# over ws:// and wss://, in classic and loop workers.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${BIN:-$ROOT/cannoli}"
for tool in python3 openssl strada; do command -v $tool >/dev/null || { echo "SKIP: $tool not installed"; exit 0; }; done
P1=$(( 20000 + RANDOM % 20000 )); P2=$((P1 + 1))
S="$(mktemp -d)"; MPID=""
cleanup() { [ -n "$MPID" ] && kill -9 "$MPID" 2>/dev/null; rm -rf "$S"; }
trap cleanup EXIT
cd "$S"
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 2 -subj /CN=localhost >/dev/null 2>&1
cat > wsecho.strada <<'LIB'
func cannoli_dispatch(scalar $c) str {
    if ($c->path() ne "/ws") { return ""; }
    my scalar $ws = $c->ws_accept("", "*");
    if (!defined($ws)) { return "STATUS:403:no"; }
    while (1) {
        my scalar $m = $c->ws_recv();
        if (!defined($m)) { last; }
        $c->ws_send("echo:" . $m->{"data"});
    }
    return "x";
}
LIB
strada --shared wsecho.strada -o wsecho.so > build.log 2>&1 || { echo "FAIL: could not build test library"; cat build.log; exit 1; }
FAILS=0
for LOOP in 0 1; do
  printf '[server]\nhost = 127.0.0.1\nport = %s\nworkers = 1\nloop_workers = %s\n[ssl]\nenabled = 1\nport = %s\ncert = %s/cert.pem\nkey = %s/key.pem\n' $P1 $LOOP $P2 "$S" "$S" > ws.conf
  "$BIN" --config ws.conf -l "$S/wsecho.so" > server.log 2>&1 &
  MPID=$!
  for _ in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/$P1) 2>/dev/null && break; sleep 0.1; done
  for TLS in 0 1; do
    P=$P1; [ $TLS = 1 ] && P=$P2
    R=$(timeout 40 python3 "$ROOT/t/data/ws_client.py" $P $TLS 7 2>&1 | tail -1)
    echo "loop=$LOOP tls=$TLS: $R"
    [ "$R" = "ok ok ok ok" ] || FAILS=$((FAILS+1))
  done
  grep -q "respawning" server.log && { echo "FAIL: a worker died"; FAILS=$((FAILS+1)); }
  kill -TERM $MPID; wait $MPID 2>/dev/null; MPID=""
done
[ $FAILS -eq 0 ] && echo "All WebSocket tests passed!" || { echo "$FAILS failure(s)"; exit 1; }
