#!/bin/bash
# Build a Cannoli test file
# Usage: ./build_test.sh t/test_config.strada

set -e

CANNOLI_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -z "$1" ]; then
    echo "Usage: $0 <test.strada>"
    exit 1
fi

TEST_FILE="$1"
TEST_NAME=$(basename "$TEST_FILE" .strada)

# Concatenate all source files with the test
COMBINED="/tmp/${TEST_NAME}_combined.strada"

# Build combined file: source files + test + compress (must be last due to package declaration)
# cannoli_obj.strada must come before router.strada (router calls Cannoli::new)
cat "$CANNOLI_DIR/src/config.strada" \
    "$CANNOLI_DIR/src/mime.strada" \
    "$CANNOLI_DIR/src/session.strada" \
    "$CANNOLI_DIR/src/template.strada" \
    "$CANNOLI_DIR/src/validation.strada" \
    "$CANNOLI_DIR/src/request.strada" \
    "$CANNOLI_DIR/src/log.strada" \
    "$CANNOLI_DIR/src/response.strada" \
    "$CANNOLI_DIR/src/cannoli_obj.strada" \
    "$CANNOLI_DIR/src/router.strada" \
    "$CANNOLI_DIR/src/static.strada" \
    "$CANNOLI_DIR/src/server.strada" \
    "$CANNOLI_DIR/src/fastcgi.strada" \
    "$CANNOLI_DIR/src/app.strada" \
    "$TEST_FILE" \
    "$CANNOLI_DIR/lib/compress.strada" > "$COMBINED"

# Compile using installed strada
strada "$COMBINED" -o "/tmp/$TEST_NAME" -l z

echo "Built /tmp/$TEST_NAME"
