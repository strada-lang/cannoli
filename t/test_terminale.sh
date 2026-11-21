#!/bin/bash
# The Terminale web terminal module (terminale/): builds terminale.so and
# runs its end-to-end suite (login, two-factor, sessions, re-attach, files,
# settings, worker recycling). Skipped without the tools it needs.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for tool in python3 openssl curl strada; do command -v $tool >/dev/null || { echo "SKIP: $tool not installed"; exit 0; }; done
[ -f /usr/include/pty.h ] && [ -f /usr/include/crypt.h ] || { echo "SKIP: libc development headers (pty.h, crypt.h) not installed"; exit 0; }
"$ROOT/terminale/build.sh" --fast > /tmp/cannoli_terminale_build.log 2>&1 || { echo "FAIL: terminale.so did not build"; tail -20 /tmp/cannoli_terminale_build.log; exit 1; }
exec bash "$ROOT/terminale/t/test.sh"
