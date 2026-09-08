# CRC-16/ARC verification

Run from the KaitoKit repository root. The benchmark compiles the actual CRC16
source with the same driver for both versions. Keep a copy of the old source and
release CLI **before editing** (or obtain CRC16.swift from the intended baseline
commit with `git show`). No third-party CRC code is needed.

```sh
W="$PWD/.build/crc16-work"
mkdir -p "$W/cache" "$W/tmp"
export CLANG_MODULE_CACHE_PATH="$W/cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$W/cache"
export TMPDIR="$W/tmp"
export DEVELOPER_DIR=/Applications/Xcode.app

# Baseline for this change; source is KaitoKit's own code.
git show 66bc07a:Sources/KaitoKit/Core/CRC16.swift > "$W/CRC16-before.swift"
swiftc -O -module-cache-path "$W/cache" \
  "$W/CRC16-before.swift" Tests/Benchmarks/CRC16Bench.swift -o "$W/micro-before"
swiftc -O -I Sources/CBzip2 -module-cache-path "$W/cache" \
  Sources/KaitoKit/Core/CRC16.swift Tests/Benchmarks/CRC16Bench.swift -o "$W/micro-after"

# Stop concurrent builds/tests before measuring. Seven samples per invocation;
# take the median of each process, then the median of three alternating pairs.
for i in 1 2 3; do
  "$W/micro-before" 16 32 48 63 64 65 80 96 112 127 128 256 4096 65536 1048576 16777216
  "$W/micro-after" 16 32 48 63 64 65 80 96 112 127 128 256 4096 65536 1048576 16777216
done

# Real bytes, input loading/copying outside the measured interval.
# S must be the authorized corpus scratchpad supplied with the task.
for i in 1 2 3; do
  "$W/micro-before" --file "$S/bench3/lhastore/store.lzh" 16777216
  "$W/micro-after" --file "$S/bench3/lhastore/store.lzh" 16777216
done
```

The timed loop makes cumulative CRC updates and emits both the warmup CRC and the
CRC of all measured repetitions. Verify that both versions report identical CRCs.
Each sample processes about 256 MiB, capped at one million calls for short inputs,
and runs at least eight iterations. GB/s uses decimal bytes; KiB/MiB lengths use
powers of two. The input is deterministic pseudorandom data unless `--file` is set.

The task's end-to-end and corpus commands are wrapped without changing their
`bench ARCHIVE 3` / `sha ARCHIVE` semantics. `bench` alternates three pairs and
retains all stdout/stderr. `sha` compares the spec's top-level files; **also run
`sha-lha`**, because the LHA corpus contains subdirectories. Nonzero exit values
are retained and compared, rather than counted as successful extraction.

```sh
swift build --disable-sandbox -c release --product kaito
K="$(swift build --disable-sandbox -c release --show-bin-path)/kaito"
python3 Tests/Benchmarks/CRC16Compare.py bench "$W/kaito-before" "$K" "$S"
python3 Tests/Benchmarks/CRC16Compare.py bench "$S/bin/kaito-r3" "$K" "$S"
python3 Tests/Benchmarks/CRC16Compare.py sha "$S/bin/kaito-r3" "$K" "$S"
python3 Tests/Benchmarks/CRC16Compare.py sha-lha "$S/bin/kaito-r3" "$K" "$S"

python3 Tests/Benchmarks/CRC16Constants.py
swift test --disable-sandbox
DEVELOPER_DIR=/Applications/Xcode-beta.app swift test --disable-sandbox \
  --scratch-path .build/crc16-swift64
DEVELOPER_DIR=/Applications/Xcode-beta.app swift build --disable-sandbox \
  --scratch-path .build/crc16-x86 --arch x86_64 --product kaito
```

`CRC16FoldingTests` compares the unchanged slice-by-eight fallback with folding
for every length 0...4096 and for 64 KiB, 1 MiB and 16 MiB, including different
seeds, one-byte/prime/boundary partitions and guard pages. Existing CRC tests add
an independent bit-serial reference. The internal folding flag never overrides
CPU feature detection. On a machine without the instructions, tests still
exercise the software fallback safely.

For x86_64 execution on Apple Silicon, SwiftPM's arm64 discovery helper may refuse
the x86-only test bundle. Build with `swift test --arch x86_64`, then execute that
bundle directly using Rosetta's x86_64 XCTest runner:

```sh
swift test --disable-sandbox --scratch-path .build/crc16-test-x86 \
  --arch x86_64 --filter CRC16
arch -x86_64 /Applications/Xcode.app/Contents/Developer/usr/bin/xctest \
  -XCTest CRC16FoldingTests,CRC16Tests \
  .build/crc16-test-x86/x86_64-apple-macosx/debug/KaitoKitPackageTests.xctest
```

The imported C helper requires **C sanitizer flags in addition to Swift flags**.
`CRC16Fuzz.sh` adds `-Xcc -fsanitize=address,undefined` to build calls made by the
existing fuzz scripts, preserving their 300-mutant / 8-second configuration.
Its wrapper, cache and temporary files stay under `.build/`. The standalone C
check also tests each 16-byte block length from 64...4096 at all 64 alignments,
with exact allocation endpoints and random seeds, on both instruction sets.

```sh
bash Tests/Benchmarks/CRC16Fuzz.sh "$S"/fuzz-seeds/*/*
clang -O1 -g -fsanitize=address,undefined \
  Tests/Benchmarks/CRC16FoldingSanitizer.c -o "$W/c-sanitizer"
"$W/c-sanitizer"
clang -arch x86_64 -O1 -g -fsanitize=address,undefined \
  Tests/Benchmarks/CRC16FoldingSanitizer.c -o "$W/c-sanitizer-x86"
"$W/c-sanitizer-x86"
git diff --check
```

The 2026-09-09 results, mathematical derivation, references and limitations are in
[Documentation/design.md](../../Documentation/design.md). Full measured samples,
comparison rows and build/test logs from that run are in `.build/crc16-work/`.
