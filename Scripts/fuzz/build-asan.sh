#!/usr/bin/env bash
# AddressSanitizer/UndefinedBehaviorSanitizer 付き成果物を通常ビルドと分離して作る。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build-asan"

exec swift build \
    --package-path "$ROOT_DIR" \
    --scratch-path "$BUILD_DIR" \
    --disable-sandbox \
    -c debug \
    -Xswiftc -sanitize=address,undefined
