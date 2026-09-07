#!/usr/bin/env bash
# Generate compact real-tool seeds whose packed data reaches each decoder family.
set -euo pipefail

if (($# != 1)); then
    echo "usage: $0 <output-directory>" >&2
    exit 2
fi

OUTPUT_DIR="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

SEVEN_ZIP_BIN="${KAITOKIT_7ZZ_BIN:-${KAITO_7ZZ:-}}"
if [[ -z "$SEVEN_ZIP_BIN" ]]; then
    SEVEN_ZIP_BIN="$(command -v 7zz || true)"
fi
if [[ -z "$SEVEN_ZIP_BIN" || ! -x "$SEVEN_ZIP_BIN" ]]; then
    echo "error: set KAITOKIT_7ZZ_BIN or put 7zz on PATH" >&2
    exit 2
fi

RAR5_LZ_SEED="${KAITOKIT_RAR5_LZ_SEED:-}"
RAR_BIN="${KAITOKIT_RAR_EXECUTABLE:-${KAITOKIT_RAR_BIN:-}}"
if [[ -z "$RAR5_LZ_SEED" && -z "$RAR_BIN" ]]; then
    RAR_BIN="$(command -v rar || true)"
fi
if [[ -z "$RAR5_LZ_SEED" && ( -z "$RAR_BIN" || ! -x "$RAR_BIN" ) ]]; then
    echo "error: set KAITOKIT_RAR_EXECUTABLE, put rar on PATH, or set KAITOKIT_RAR5_LZ_SEED" >&2
    exit 2
fi

# Direct seed overrides accept either an archive or a whitespace-wrapped .b64
# fixture. Repository fixtures keep the default run independent of corpus paths.
RAR4_LZ_SEED="${KAITOKIT_RAR4_LZ_SEED:-$ROOT_DIR/Tests/Fixtures/rar4/solid_lz_rar300.rar.b64}"
RAR4_PPMD_SEED="${KAITOKIT_RAR4_PPMD_SEED:-$ROOT_DIR/Tests/Fixtures/rar4/ppmd_lorem_rar300.rar.b64}"
LHA_LH4_SEED="${KAITOKIT_LHA_LH4_SEED:-$ROOT_DIR/Tests/Fixtures/lha/lh4-small.lzh.b64}"
LHA_LH6_SEED="${KAITOKIT_LHA_LH6_SEED:-$ROOT_DIR/Tests/Fixtures/lha/lh6-small.lzh.b64}"
LHA_LH7_SEED="${KAITOKIT_LHA_LH7_SEED:-$ROOT_DIR/Tests/Fixtures/lha/lh7-small.lzh.b64}"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kaito-fuzz-seeds.XXXXXX")"
cleanup_work_dir() {
    rm -rf "$WORK_DIR"
}
trap cleanup_work_dir EXIT

install_seed() {
    local source_path="$1"
    local destination_path="$2"
    if [[ ! -f "$source_path" ]]; then
        echo "error: compressed seed not found: $source_path" >&2
        exit 2
    fi
    if [[ "$source_path" == *.b64 ]]; then
        python3 - "$source_path" "$destination_path" <<'PY'
import base64
from pathlib import Path
import sys

source, destination = map(Path, sys.argv[1:])
encoded = b"".join(source.read_bytes().split())
destination.write_bytes(base64.b64decode(encoded, validate=True))
PY
    else
        cp "$source_path" "$destination_path"
    fi
}

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

install_seed "$RAR4_LZ_SEED" "$OUTPUT_DIR/rar4-lz.rar"
install_seed "$RAR4_PPMD_SEED" "$OUTPUT_DIR/rar4-ppmd.rar"

if [[ -n "$RAR5_LZ_SEED" ]]; then
    install_seed "$RAR5_LZ_SEED" "$OUTPUT_DIR/rar5-lz.rar"
else
    "$RAR_BIN" a -cfg- -idq -m5 -ep -y \
        "$WORK_DIR/rar5-lz.rar" "$WORK_DIR/payload.bin"
    install_seed "$WORK_DIR/rar5-lz.rar" "$OUTPUT_DIR/rar5-lz.rar"
fi

install_seed "$LHA_LH4_SEED" "$OUTPUT_DIR/lha-lh4.lzh"
install_seed "$LHA_LH6_SEED" "$OUTPUT_DIR/lha-lh6.lzh"
install_seed "$LHA_LH7_SEED" "$OUTPUT_DIR/lha-lh7.lzh"

python3 - "$SCRIPT_DIR/mutate.py" \
    "$OUTPUT_DIR/rar4-lz.rar" \
    "$OUTPUT_DIR/rar4-ppmd.rar" \
    "$OUTPUT_DIR/rar5-lz.rar" \
    "$OUTPUT_DIR/lha-lh4.lzh" \
    "$OUTPUT_DIR/lha-lh6.lzh" \
    "$OUTPUT_DIR/lha-lh7.lzh" <<'PY'
import importlib.util
from pathlib import Path
import sys

module_path = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("kaito_mutate", module_path)
if spec is None or spec.loader is None:
    raise SystemExit(f"cannot load payload locator: {module_path}")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

for seed_text in sys.argv[2:]:
    seed = Path(seed_text)
    if not module.compressed_payload_ranges(seed.read_bytes()):
        raise SystemExit(f"generated seed has no recognized packed range: {seed}")
PY

echo "generated compressed seeds in $OUTPUT_DIR"
echo "use --password KaitoFuzz so encrypted seeds reach their packed data"
