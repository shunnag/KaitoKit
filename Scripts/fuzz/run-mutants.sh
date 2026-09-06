#!/usr/bin/env bash
# 全ミュータントを制限時間付きで実行し、クラッシュと sanitizer 診断を集計する。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
COUNT=200
TIMEOUT_SECONDS=5

usage() {
    echo "usage: $0 [--count N] [--timeout SECONDS] <seed-or-directory> [...]" >&2
}

while (($# > 0)); do
    case "$1" in
        --count)
            (($# >= 2)) || { usage; exit 2; }
            COUNT="$2"
            shift 2
            ;;
        --timeout)
            (($# >= 2)) || { usage; exit 2; }
            TIMEOUT_SECONDS="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*)
            usage
            exit 2
            ;;
        *)
            break
            ;;
    esac
done

if (($# == 0)) || ! [[ "$COUNT" =~ ^[1-9][0-9]*$ ]] || \
        ! [[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*([.][0-9]+)?$ ]]; then
    usage
    exit 2
fi

declare -a SEEDS=()
for candidate in "$@"; do
    if [[ -d "$candidate" ]]; then
        while IFS= read -r -d '' path; do
            SEEDS+=("$path")
        done < <(find "$candidate" -type f -print0 | sort -z)
    elif [[ -f "$candidate" ]]; then
        SEEDS+=("$candidate")
    else
        echo "error: seed not found: $candidate" >&2
        exit 2
    fi
done

if ((${#SEEDS[@]} == 0)); then
    echo "error: no seed archives found" >&2
    exit 2
fi

BUILD_DIR="$ROOT_DIR/.build-asan"
"$SCRIPT_DIR/build-asan.sh"
BIN_DIR="$(swift build --package-path "$ROOT_DIR" --scratch-path "$BUILD_DIR" \
    --disable-sandbox -c debug --show-bin-path)"
Kaito_BIN="$BIN_DIR/kaito"
if [[ ! -x "$Kaito_BIN" ]]; then
    echo "error: ASan kaito binary not found: $Kaito_BIN" >&2
    exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kaito-mutants.XXXXXX")"
KAITO_KEEP_WORK_DIR=0
cleanup_work_dir() {
    if [[ "$KAITO_KEEP_WORK_DIR" == 1 ]]; then
        echo "failure artifacts preserved: $WORK_DIR" >&2
    else
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup_work_dir EXIT
MUTANT_DIR="$WORK_DIR/inputs"
LOG_DIR="$WORK_DIR/logs"
mkdir -p "$LOG_DIR"
python3 "$SCRIPT_DIR/mutate.py" --count "$COUNT" -o "$MUTANT_DIR" "${SEEDS[@]}"

crashes=0
hangs=0
sanitizer_findings=0
tested=0
while IFS= read -r -d '' mutant; do
    tested=$((tested + 1))
    log="$LOG_DIR/$(basename "$mutant").log"
    set +e
    python3 - "$Kaito_BIN" "$mutant" "$TIMEOUT_SECONDS" "$log" <<'PY'
import subprocess
import sys

binary, mutant, timeout_text, log = sys.argv[1:]
try:
    completed = subprocess.run(
        [binary, "sha", mutant],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=float(timeout_text),
        check=False,
    )
except subprocess.TimeoutExpired as error:
    output = error.output or b""
    with open(log, "wb") as handle:
        handle.write(output)
    raise SystemExit(124)

output = completed.stdout
with open(log, "wb") as handle:
    handle.write(output)

diagnostics = (
    b"AddressSanitizer",
    b"UndefinedBehaviorSanitizer",
    b"runtime error:",
    b"Sanitizer:DEADLYSIGNAL",
)
if any(marker in output for marker in diagnostics):
    raise SystemExit(126)
if completed.returncode < 0 or completed.returncode >= 128:
    raise SystemExit(125)
# 破損として正常に拒否した非 0 終了は finding に数えない。
raise SystemExit(0)
PY
    status=$?
    set -e

    case "$status" in
        0)
            ;;
        124)
            hangs=$((hangs + 1))
            echo "hang: $mutant (see $log)" >&2
            ;;
        126)
            sanitizer_findings=$((sanitizer_findings + 1))
            echo "sanitizer: $mutant (see $log)" >&2
            ;;
        *)
            crashes=$((crashes + 1))
            echo "crash: $mutant (see $log)" >&2
            ;;
    esac
done < <(find "$MUTANT_DIR" -type f -print0 | sort -z)

echo "mutants: $tested, crashes: $crashes, hangs: $hangs, sanitizer findings: $sanitizer_findings"
if ((crashes != 0 || hangs != 0 || sanitizer_findings != 0)); then
    KAITO_KEEP_WORK_DIR=1
    exit 1
fi
