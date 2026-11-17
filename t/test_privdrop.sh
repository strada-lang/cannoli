#!/bin/bash
# Privilege drop (server.user / server.group). Needs root: run with
#   sudo t/test_privdrop.sh
# Skipped otherwise (it cannot be faked in an unprivileged user namespace).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${BIN:-$ROOT/cannoli}"
[ "$(id -u)" = 0 ] || { echo "SKIP: not running as root (sudo $0)"; exit 0; }
USER_NAME="${CANNOLI_TEST_USER:-nobody}"
id "$USER_NAME" >/dev/null 2>&1 || { echo "SKIP: no user $USER_NAME"; exit 0; }
PORT=$(( 20000 + RANDOM % 20000 ))
S="$(mktemp -d)"; chmod 755 "$S"; MPID=""
cleanup() { [ -n "$MPID" ] && kill -9 "$MPID" 2>/dev/null; rm -rf "$S"; }
trap cleanup EXIT
FAILS=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAILS=$((FAILS+1)); }
UID_EXP=$(id -u "$USER_NAME"); GID_EXP=$(id -g "$USER_NAME")
cat > "$S/p.conf" <<CONF
[server]
host = 127.0.0.1
port = $PORT
workers = 2
user = $USER_NAME
pid_file = $S/cannoli.pid
[log]
error_file = $S/error.log
access_file = $S/access.log
CONF
"$BIN" --config "$S/p.conf" --demo > "$S/server.log" 2>&1 &
MPID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null http://127.0.0.1:$PORT/hello && break; sleep 0.1; done
for P in $MPID $(pgrep -P $MPID); do
  U=$(awk '/^Uid:/{print $2, $3, $4, $5}' /proc/$P/status); G=$(awk '/^Gid:/{print $2, $3, $4, $5}' /proc/$P/status)
  SUP=$(awk '/^Groups:/{$1=""; print}' /proc/$P/status | xargs)
  [ "$U" = "$UID_EXP $UID_EXP $UID_EXP $UID_EXP" ] && [ "$G" = "$GID_EXP $GID_EXP $GID_EXP $GID_EXP" ] \
    && pass "pid $P runs as $USER_NAME (uid/gid all ${UID_EXP}/${GID_EXP})" || fail "pid $P uid [$U] gid [$G]"
  echo " $SUP " | grep -qE " 0 " && fail "pid $P still has root's supplementary group 0: [$SUP]" || pass "pid $P supplementary groups: [$SUP]"
done
curl -s -o /dev/null http://127.0.0.1:$PORT/hello
sleep 0.3
[ -s "$S/access.log" ] && pass "access log still writable after the drop" || fail "access log empty"
[ "$(stat -c %U "$S/access.log")" = "$USER_NAME" ] && pass "log files handed to $USER_NAME" || fail "log owner $(stat -c %U "$S/access.log")"
kill -TERM $MPID; wait $MPID 2>/dev/null; MPID=""
[ $FAILS -eq 0 ] && echo "All privilege-drop tests passed!" || { echo "$FAILS failure(s)"; exit 1; }
