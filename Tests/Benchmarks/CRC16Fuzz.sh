#!/usr/bin/env bash
# Reuse the repository's fuzz commands, instrumenting imported C as well as Swift.
# Usage: DEVELOPER_DIR=/Applications/Xcode.app bash Tests/Benchmarks/CRC16Fuzz.sh SEED...
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CRC16_WORK="$ROOT_DIR/.build/crc16-fuzz"
export CRC16_REAL_SWIFT="$(xcrun --find swift)"
mkdir -p "$CRC16_WORK/toolchain" "$CRC16_WORK/cache" "$CRC16_WORK/tmp"
cat > "$CRC16_WORK/toolchain/swift" <<'WRAPPER'
#!/bin/sh
if [ "$1" = build ]; then
    shift
    exec "$CRC16_REAL_SWIFT" build -Xcc -fsanitize=address,undefined "$@"
fi
exec "$CRC16_REAL_SWIFT" "$@"
WRAPPER
chmod +x "$CRC16_WORK/toolchain/swift"
export PATH="$CRC16_WORK/toolchain:$PATH"
export CLANG_MODULE_CACHE_PATH="$CRC16_WORK/cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CRC16_WORK/cache"
export TMPDIR="$CRC16_WORK/tmp"
"$ROOT_DIR/Scripts/fuzz/build-asan.sh"
exec "$ROOT_DIR/Scripts/fuzz/run-mutants.sh" --count 300 --timeout 8 "$@"
