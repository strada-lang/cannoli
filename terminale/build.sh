#!/bin/bash
# Build terminale.so and the precompressed static files.
#   ./build.sh            optimized build
#   ./build.sh --fast     quick unoptimized build
set -e
cd "$(dirname "$0")"
STRADA="${STRADA:-strada}"
FLAGS=""
[ "$1" = "--fast" ] && FLAGS="-O0 --no-lto"
command -v "$STRADA" >/dev/null || { echo "build.sh: '$STRADA' not found (install Strada or set STRADA=)"; exit 1; }
echo "Building terminale.so..."
"$STRADA" $FLAGS --shared terminale.strada -o terminale.so -l util -l crypt -l crypto
for f in static/xterm.js static/addon-webgl.js static/addon-fit.js static/addon-web-links.js static/xterm.css static/app.js static/app.css static/themes.js static/addon-search.js; do
    gzip -9 -k -f "$f"
done
echo "Built $(pwd)/terminale.so"
