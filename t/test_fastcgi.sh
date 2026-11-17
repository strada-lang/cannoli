#!/bin/bash
# FastCGI over TCP and a Unix socket: requests, FCGI_KEEP_CONN reuse, stale
# socket handling, socket mode, clean shutdown (socket file removed).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${BIN:-$ROOT/cannoli}"
command -v python3 >/dev/null || { echo "SKIP: python3 not installed"; exit 0; }
S="$(mktemp -d)"; MPID=""
cleanup() { [ -n "$MPID" ] && kill -9 "$MPID" 2>/dev/null; rm -rf "$S"; }
trap cleanup EXIT
FAILS=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAILS=$((FAILS+1)); }
C="$ROOT/t/data/fcgi_client.py"
wait_up() { for _ in $(seq 1 50); do python3 "$C" "$1" /hello >/dev/null 2>&1 && return 0; sleep 0.1; done; return 1; }

PORT=$(( 20000 + RANDOM % 20000 ))
"$BIN" --fastcgi --socket 127.0.0.1:$PORT --demo -w 2 > "$S/tcp.log" 2>&1 &
MPID=$!
wait_up 127.0.0.1:$PORT
R=$(python3 "$C" 127.0.0.1:$PORT /hello /json | tr '\n' '|')
echo "$R" | grep -q '^Hello, World!|{' && pass "TCP, two requests on one kept connection" || fail "TCP: $R"
kill -TERM $MPID; wait $MPID 2>/dev/null; MPID=""

SOCK="$S/c.sock"
python3 -c "import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])" "$SOCK"   # stale socket file
"$BIN" --fastcgi --socket "unix:$SOCK" --demo -w 2 > "$S/unix.log" 2>&1 &
MPID=$!
wait_up "$SOCK"
R=$(python3 "$C" "$SOCK" /hello)
[ "$R" = "Hello, World!" ] && pass "Unix socket (stale file replaced)" || fail "unix: $R"
[ "$(stat -c %a "$SOCK")" = 660 ] && pass "socket mode 0660" || fail "mode $(stat -c %a "$SOCK")"
"$BIN" --fastcgi --socket "$SOCK" --demo -w 1 > "$S/second.log" 2>&1
grep -q "already listening" "$S/second.log" && pass "second server refused" || fail "second server: $(tail -1 "$S/second.log")"
kill -TERM $MPID
for _ in $(seq 1 100); do kill -0 $MPID 2>/dev/null || break; sleep 0.05; done
kill -0 $MPID 2>/dev/null && fail "master did not exit" || { MPID=""; pass "clean shutdown"; }
[ ! -e "$SOCK" ] && pass "socket file removed" || fail "socket file left behind"
[ $FAILS -eq 0 ] && echo "All FastCGI tests passed!" || { echo "$FAILS failure(s)"; exit 1; }
