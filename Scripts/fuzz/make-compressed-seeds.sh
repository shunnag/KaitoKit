#!/usr/bin/env bash
# Generate compact real-tool seeds whose packed data reaches each decoder family.
set -euo pipefail

if (($# != 1)); then
    echo "usage: $0 <output-directory>" >&2
    exit 2
fi

OUTPUT_DIR="$1"
SEVEN_ZIP_BIN="${KAITO_7ZZ:-}"
if [[ -z "$SEVEN_ZIP_BIN" ]]; then
    SEVEN_ZIP_BIN="$(command -v 7zz || true)"
fi
if [[ -z "$SEVEN_ZIP_BIN" ]]; then
    for candidate in /opt/homebrew/bin/7zz /usr/local/bin/7zz; do
        if [[ -x "$candidate" ]]; then
            SEVEN_ZIP_BIN="$candidate"
            break
        fi
    done
fi
if [[ -z "$SEVEN_ZIP_BIN" || ! -x "$SEVEN_ZIP_BIN" ]]; then
    echo "error: set KAITO_7ZZ, put 7zz on PATH, or install Homebrew sevenzip" >&2
    exit 2
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kaito-fuzz-seeds.XXXXXX")"
cleanup_work_dir() {
    rm -rf "$WORK_DIR"
}
trap cleanup_work_dir EXIT

python3 - "$WORK_DIR/payload.bin" <<'PY'
from pathlib import Path
import sys

block = bytes((index * 29 + index // 7) & 0xff for index in range(4096))
Path(sys.argv[1]).write_bytes(block * 4 + b"KaitoKit compressed payload seed\n" * 64)
PY

make_archive() {
    "$SEVEN_ZIP_BIN" a -bd -bb0 -y "$@" "$WORK_DIR/payload.bin" >/dev/null
}

make_archive -tzip -mm=Deflate "$OUTPUT_DIR/zip-deflate.zip"
make_archive -tzip -mm=Deflate64 "$OUTPUT_DIR/zip-deflate64.zip"
make_archive -tzip -mm=BZip2 "$OUTPUT_DIR/zip-bzip2.zip"
make_archive -tzip -mm=LZMA "$OUTPUT_DIR/zip-lzma.zip"
make_archive -tzip -mm=Deflate -mem=AES256 -pKaitoFuzz "$OUTPUT_DIR/zip-aes.zip"
make_archive -t7z -m0=LZMA2 "$OUTPUT_DIR/7z-lzma2.7z"
make_archive -t7z -m0=PPMd "$OUTPUT_DIR/7z-ppmd.7z"
make_archive -t7z -mf=BCJ2 "$OUTPUT_DIR/7z-bcj2.7z"
make_archive -t7z -m0=LZMA2 -pKaitoFuzz -mhe=on "$OUTPUT_DIR/7z-aes.7z"

echo "generated compressed seeds in $OUTPUT_DIR"
echo "use --password KaitoFuzz so encrypted seeds reach their packed data"
