#!/bin/bash
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/cannoli"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== Cannoli Configuration CLI Tests ==="

"$BIN" -t > "$TMP/default.out"
grep -Eq "configuration is valid" "$TMP/default.out"

cat > "$TMP/good.conf" <<CONF
[server]
host = 127.0.0.1
port = 18080
workers = 2
CONF
"$BIN" -t -c "$TMP/good.conf" > "$TMP/good.out"
grep -Eq "configuration is valid" "$TMP/good.out"

cat > "$TMP/bad.conf" <<CONF
[server]
port = nope
workers = 0
CONF
if "$BIN" -t -c "$TMP/bad.conf" > "$TMP/bad.out" 2>&1; then
    echo "FAIL: invalid configuration was accepted"
    exit 1
fi
grep -Eq "server.port must be an integer" "$TMP/bad.out"
grep -Eq "server.workers" "$TMP/bad.out"

if "$BIN" -t -c "$TMP/missing.conf" > "$TMP/missing.out" 2>&1; then
    echo "FAIL: missing configuration file was accepted"
    exit 1
fi
grep -Eq "configuration file does not exist" "$TMP/missing.out"

if "$BIN" --unknown-flag > "$TMP/unknown.out" 2>&1; then
    echo "FAIL: unknown CLI option was accepted"
    exit 1
fi
grep -Eq "unknown option" "$TMP/unknown.out"

if "$BIN" -p > "$TMP/missing_arg.out" 2>&1; then
    echo "FAIL: option missing value was accepted"
    exit 1
fi
grep -Eq "requires an argument" "$TMP/missing_arg.out"

echo "All configuration CLI tests passed!"
