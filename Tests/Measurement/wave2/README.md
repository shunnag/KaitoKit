# Wave 2 integrity hot loops

Scope: cooViewer-y9eq.21 (BLAKE2sp), cooViewer-y9eq.22 (CRC64), and the
ZipCrypto CRC survey item. Baseline: KaitoKit `7b1e583`; measured on arm64,
Apple Swift 6.4 (`swiftlang-6.4.0.34.1`, clang `2100.3.34.1`).

## Implementation and files

- `Sources/KaitoKit/Core/Blake2.swift`: eight `SIMD8<UInt32>` chaining words;
  lane i is leaf i. Full 512-byte stripes compress all eight leaves together.
  The RFC sigma schedule is unrolled into vector additions, XORs and rotations.
  Fewer than two stripes remain buffered so a leaf's final block is never
  compressed without its final flag. Scalar BLAKE2s handles the last one or two
  blocks per leaf and the root, and remains available to standalone callers.
  Updates accept arbitrary lengths, unaligned buffers and empty inputs; copies
  retain independent value semantics, and finalize remains repeatable.
- `Sources/CBzip2/CRC64Folding.h`: header-only PMULL folding, reusing the
  alias-safe 16-byte load/vector primitives from KaitoKit's `CRC16Folding.h`.
  Four independent 128-bit accumulators fold 64 bytes at a time. The last
  representative is reduced with the existing slice-by-eight tables.
  `target("aes")` is local to the helper, with cached Apple FEAT_PMULL detection
  before dispatch. Only complete 16-byte blocks are read; Swift handles tails.
- `Sources/KaitoKit/Core/CRC64.swift`: preserves the original slice-by-eight
  loop for small inputs and unsupported CPUs, with an internal seed/dispatch
  entry point for comparisons. Initial/final complements are unchanged.
- `Sources/CBzip2/ZipCryptoCRC.h` and
  `Sources/KaitoKit/Formats/Zip/ZipCrypto.swift`: one guarded call per buffer
  enters a `target("crc")` loop using two Arm `__crc32b` operations per decoded
  byte. Key state returns to Swift after each call. Password initialization
  and the portable decrypt path retain the existing IEEE CRC32 table.
  `hw.optional.armv8_crc32` is queried once. x86 SSE4.2 CRC32 uses CRC32C,
  so the x86 path intentionally uses the existing table.
- `Sources/CBzip2/shim.h`: includes the two headers in the existing module.
  No package target, module map, or link setting was added.
- `Tests/KaitoKitTests/Core/Wave2IntegrityTests.swift`: six regression tests.
- `Tests/KaitoKitTests/Support/ScalarBlake2sp.swift`: test-only snapshot of the
  old scalar BLAKE2s/BLAKE2sp implementation, retaining its provenance header.
- `Tests/Measurement/wave2/HotLoopBench.swift`, `run.py`, `compare.py`,
  `CRC64Constants.py`, `HelperSanitizer.c`, and this `README.md`: release
  harness, independent constant derivation, sanitizer harness and report.

## CI and portability

`.github/workflows/ci.yml:199` builds universal debug tests with
`--arch arm64 --arch x86_64`. The runtime matrix at lines 402–406 includes
`macos-26` and two `macos-26-intel` shards. Ubuntu jobs handle CI tooling;
Swift package builds and runtime tests use macOS. The new C helpers compile
Arm intrinsics only under `__aarch64__`. On x86_64 and other architectures,
their feature checks return false and Swift uses the existing tables.
A complete x86_64 package build and the new tests under Rosetta verify this
path locally; physical Intel hardware was not benchmarked.

## Coverage

- Existing RFC 7693 BLAKE2s vectors, BLAKE2sp known answers and RAR5 archives.
  New comparisons cover every length 0–1100, chunk sizes 1–130, all two-way
  splits through 1100 around stripe boundaries, deterministic random inputs
  through 4 MiB, unaligned starts, empty updates, repeated finalize and copies.
- CRC-64/XZ `123456789` = `995DC9BBDF1939FA`; lengths 0–300 at every starting
  offset 0–63 with three seeds; chunk sizes 1–130; random inputs through
  16 MiB plus a byte; boundary partitions and the incremental value API.
  Comparisons force the original Swift slice-by-eight path as the reference.
- CRC64 and BLAKE2sp buffers adjacent to inaccessible guard pages exercise
  both starts and tails without readable padding.
- ZipCrypto round trips use an independent bit-step encryption oracle,
  empty/Unicode/all-byte passwords, and whole-buffer and split decryption
  with both hardware and forced table dispatch. Existing archive tests remain.
- `CRC64Constants.py` derives inverse powers directly from the polynomial,
  verifies them by independent polynomial division, and checks all 128 basis
  vectors for each of the 128-bit and 512-bit folds (256 identities total).
- `HelperSanitizer.c` checks 4,097 lengths, varying alignment and random raw
  seeds against bit-step oracles, allocating no readable bytes past the input.
  Arm runs exercise both accelerated helpers; x86 runs verify disabled guards.

## Release benchmark method

`HotLoopBench.swift` is compiled with `swiftc -O` against the actual before or
final Swift sources. `run.py` copies only `ZipCryptoKeys` verbatim out of
`ZipCrypto.swift`; stubs satisfy unrelated header-validation dependencies,
which are outside the timed path. No production algorithm is replaced.
Each case processes a deterministic 16,777,216-byte random buffer eight times
(128 MiB), discards one warm-up sample, and takes the median of seven samples.
Input generation and compilation are outside timing. Digests/CRCs and cipher
results are printed to prevent dead-code elimination. Final timing repeats
alternate before/after binaries; see the results below.

Reproduction (all git operations here are read-only):

```sh
mkdir -p /tmp/kaito-wave2-before /tmp/kaito-wave2-after
for path in Sources/KaitoKit/Core/Blake2.swift Sources/KaitoKit/Core/CRC64.swift Sources/KaitoKit/Formats/Zip/ZipCrypto.swift; do
  GIT_OPTIONAL_LOCKS=0 git show "7b1e583:$path" > "/tmp/kaito-wave2-before/${path##*/}"
  cp "$path" /tmp/kaito-wave2-after/
done
python3 Tests/Measurement/wave2/run.py /tmp/kaito-wave2-before /tmp/kaito-wave2-bench-before
python3 Tests/Measurement/wave2/run.py /tmp/kaito-wave2-after /tmp/kaito-wave2-bench-after
```

## Provenance

This work uses only KaitoKit's own code, RFC 7693, the BLAKE2sp tree and stripe
specification in the BLAKE2 paper, CRC polynomial definitions, generic GF(2)
carry-less-multiply folding, and Arm instruction semantics. The CRC64 constants
were derived independently, following KaitoKit's existing `CRC16Folding.h`
pattern and provenance notes. I did not open XADMaster, unrar, 7-Zip,
xz/liblzma, or zlib sources. No `bd` command was run; `CHANGELOG.md` was not
edited, and no git operation wrote repository metadata.

## Commands and actual results

Commands ran from `/Users/nagash/Github/KaitoKit-wt-ka1`. SwiftPM commands use
`CLANG_MODULE_CACHE_PATH=/tmp/kaito-wave2-module-cache` and `--disable-sandbox`.
The user cache is read-only; SwiftPM reports disabled cache/manifest-cache
warnings but uses writable build/module caches. Raw logs are under
`/tmp/kaito-wave2-*.log`.

| Command | Actual result |
| --- | --- |
| `swift --version`; `uname -m`; `xcrun swift --version`; `type -a swift` | Swift 6.4, arm64; `/usr/bin/swift`. |
| `git rev-parse --short HEAD` (optional locks disabled) | `7b1e583`. |
| `swift build --disable-sandbox` before edits | Exit 0, 11.42 s. |
| `python3 Tests/Measurement/wave2/run.py /tmp/kaito-wave2-before /tmp/kaito-wave2-bench-before` | Exit 0. Initial medians: BLAKE2sp 0.459966 GB/s, CRC64 2.337582 GB/s, ZipCrypto 0.144537 GB/s. |
| `python3 Tests/Measurement/wave2/CRC64Constants.py` | Exit 0; both inverse-power pairs and all 256 identities verified. |
| First post-edit `swift build --disable-sandbox` | Exit 1: implicit CBzip2 import conflicted with existing private imports. Both new imports were changed to `private import CBzip2`. |
| First `swift test --disable-sandbox --filter Wave2IntegrityTests` | Exit 1: a mechanical snapshot rename produced `ScalarScalarBlake2sp`; corrected to `ScalarBlake2sp`. |
| Retried `swift test --disable-sandbox --filter Wave2IntegrityTests` | Exit 0, build 9.68 s; no selected-test summary was emitted, so the tests were also run directly below. |
| `xcrun xctest -XCTest Wave2IntegrityTests .build/debug/KaitoKitTests.xctest` | Exit 0: 6 tests, 0 failures, 20.032 s; PMULL=true, CRC32=true. |
| `python3 Tests/Measurement/wave2/run.py /tmp/kaito-wave2-after /tmp/kaito-wave2-bench-after` | Exit 0. Initial medians: BLAKE2sp 1.553092 GB/s, CRC64 30.899636 GB/s, ZipCrypto 0.196323 GB/s; all observable outputs matched baseline. These initial runs overlapped builds; final isolated repeats are reported separately. |
| `swift build --disable-sandbox --arch x86_64 --scratch-path /tmp/kaito-wave2-x86` | Exit 0, 10.83 s; toolchain warns x86_64 is deprecated for its macOS 27 SDK deployment setting. |
| `swift build --disable-sandbox --build-tests --arch x86_64 --scratch-path /tmp/kaito-wave2-x86` | Exit 0; both test bundles compiled. Existing SevenZipFolderPrefetchTests unnecessary-await warning. |
| `/usr/bin/arch -x86_64 /Applications/Xcode.app/Contents/Developer/usr/bin/xctest -XCTest Wave2IntegrityTests /tmp/kaito-wave2-x86/debug/KaitoKitTests.xctest` | Exit 0: 6 tests, 0 failures, 35.662 s; PMULL=false, CRC32=false. |
| `xcrun clang -O2 -g -fsanitize=address,undefined -fno-omit-frame-pointer -I Sources/CBzip2 Tests/Measurement/wave2/HelperSanitizer.c -o /tmp/kaito-wave2-helper-sanitizer` | Exit 0. |
| `/tmp/kaito-wave2-helper-sanitizer` | Exit 0: 4,097 cases, PMULL=1, CRC32=1, no mismatches or sanitizer findings. |
| `xcrun clang -arch x86_64 -O2 -g -fsanitize=address,undefined -fno-omit-frame-pointer -I Sources/CBzip2 Tests/Measurement/wave2/HelperSanitizer.c -o /tmp/kaito-wave2-helper-sanitizer-x86` | Exit 0. |
| `/usr/bin/arch -x86_64 /tmp/kaito-wave2-helper-sanitizer-x86` | Exit 0: 4,097 cases, PMULL=0, CRC32=0, no mismatches or sanitizer findings. |
| `xcrun clang -O2 -march=armv8-a+nocrypto+nocrc -I Sources/CBzip2 Tests/Measurement/wave2/HelperSanitizer.c -o /tmp/kaito-wave2-helper-baseline-arm` | Exit 0: compiles without global crypto/CRC features. |
| `/tmp/kaito-wave2-helper-baseline-arm` | Exit 0: 4,097 cases, PMULL=1, CRC32=1, no mismatches; per-function attributes enable the helpers. |
| `xcrun xctest -XCTest NameSafetyRegressionTests .build/debug/KaitoKitTests.xctest` | Exit 0: 10 tests, 0 failures, 0.875 s; diagnostic check while full-run output was buffered. |
| `git diff --check` | Exit 0 at implementation review; final check also recorded below. |

Read-only inspection used `pwd`, `rg --files`, `rg -n`, `cat`, `sed`, `ls`,
`head`, `tail`, `wc`, `git status --short`, `git diff --stat`, `git diff --numstat`
and scoped `git diff`, plus `xcrun --find clang` / `xcrun --find xctest`.
These located the three implementations, the existing bridge, package, tests,
provenance notes and CI matrix. No applicable AGENTS.md was found. The first
inventory's nonexistent top-level `Core`/`Formats` paths made that `rg` exit 2;
the paths were corrected to `Sources/KaitoKit`. An optional `rg` of an absent
`~/.agents/AGENTS.md` also returned 2. Searches with no matches returned 1.
`sysctl -n machdep.cpu.brand_string` and a diagnostic `ps -axo pid,etime,%cpu,comm`
were denied by the environment; no escalation was attempted. File creation,
source snapshots and edits used `mkdir`, `cp` and Python/heredocs and succeeded.
Process polls used `write_stdin`; no process was terminated.

### Full suite

`CLANG_MODULE_CACHE_PATH=/tmp/kaito-wave2-module-cache swift test --disable-sandbox`
exited **0**. KaitoKit: **1,918 tests, 55 skipped, 0 failures**, 1,273.336 s;
KaitoKitCompat: **34 tests, 0 failures**, 2.126 s. Combined: **1,952 tests,
55 skipped, 0 failures**. The six new tests all ran and passed in the full run
(20.119 s). Log: `/tmp/kaito-wave2-full-test.log`.

The skips are existing opt-in scale/performance cases, absent external corpora
or fixtures, and one Info-ZIP bzip2 fixture unsupported by the installed zip
binary. No new test was skipped. Relevant existing suites include:

| Suite | Actual result |
| --- | --- |
| RARCommonPrimitiveTests (RFC and BLAKE2sp known answers) | 14 tests, 0 failures |
| RAR5ReaderTests | 37 tests, 0 failures |
| ParallelXZDecompressorTests | 14 tests, 0 failures |
| XZNativeDecompressorTests | 11 tests, 0 failures |
| ZipEncryptionPrimitiveTests | 13 tests, 0 failures |
| ZipDifferentialTests | 9 tests, 1 skip, 0 failures; Info-ZIP ZipCrypto SHA256 comparison passed |
| ZipLegacyMethodTests | 6 tests, 0 failures; ZipCrypto-wrapped legacy archives passed |
| ZipModernMethodTests | 13 tests, 0 failures; encrypted XZ paths passed |

Additional read-only Python checks parsed the full-suite summaries and skip
reasons (exit 0), and verified the three benchmark source snapshots match the
final production files byte-for-byte (exit 0). A Python trailing-whitespace and
final-newline check also passed for every new file; the final pass includes the
benchmark comparison script and this completed report.

### Final build commands

| Command | Actual result |
| --- | --- |
| `CLANG_MODULE_CACHE_PATH=/tmp/kaito-wave2-module-cache swift build --disable-sandbox` | Exit 0, 3.30 s. Log: `/tmp/kaito-wave2-final-build.log`. |
| `CLANG_MODULE_CACHE_PATH=/tmp/kaito-wave2-module-cache swift build --disable-sandbox -c release` | Exit 1 after compilation/linking: `GenerateDSYMFile` / `dsymutil` returned `Operation not permitted`. Log: `/tmp/kaito-wave2-release-build.log`. No source change was needed. |
| `swift build --help` filtered for `debug-info-format` | Exit 0; this toolchain accepts the single-hyphen `-debug-info-format` option and value `none`. |

The release log also contains an existing unused-public-Foundation-import
warning in `XZSyntheticStream.swift`; that unrelated file was not changed.

`CLANG_MODULE_CACHE_PATH=/tmp/kaito-wave2-module-cache swift build --disable-sandbox -c release -debug-info-format none`
exited **0**, 66.10 s. This is the requested fallback for the denied dSYM step;
no instruction feature flags were enabled globally. Log:
`/tmp/kaito-wave2-release-no-debug.log`.

## Final throughput

Three isolated alternating before/after runs; each number is the median of
three process medians. Every process discards one warm-up and measures seven
samples of eight updates of a 16 MiB buffer. Units are decimal GB/s or MB/s.
No builds or tests ran concurrently with these final measurements.

| Item | Before | After | Gain |
| --- | ---: | ---: | ---: |
| BLAKE2sp | 0.460646 GB/s | 1.558178 GB/s | 3.3826x |
| CRC64 | 2.326594 GB/s | 31.303820 GB/s | 13.4548x |
| ZipCrypto | 144.814356 MB/s | 205.932478 MB/s | 1.4220x |

BLAKE2sp's measured gain is 3.38x here; the task's supplied probe reported
1.91 GB/s / 4.15x. The table reports this implementation's actual measurements.
All repeated observable outputs matched: BLAKE2sp digest
`Iwae31CS5g70JImP9wZ9VYoJmU+xT513TO7FpBib5lU=`, CRC64
`6003417886466083370`, and ZipCrypto accumulator `1788`. Full decrypted bytes
are checked separately by the independent round-trip and archive tests.

Final command (exit **0**):

```sh
python3 Tests/Measurement/wave2/compare.py /tmp/kaito-wave2-bench-before/bench /tmp/kaito-wave2-bench-after/bench /tmp/kaito-wave2-final-bench.json
```

Raw output: `/tmp/kaito-wave2-final-bench.log`; all cycle values:
`/tmp/kaito-wave2-final-bench.json`.

| Item | Before cycle medians (GB/s) | After cycle medians (GB/s) |
| --- | --- | --- |
| BLAKE2sp | 0.460646, 0.464149, 0.459836 | 1.562530, 1.558178, 1.556653 |
| CRC64 | 2.326594, 2.326080, 2.327494 | 31.728084, 31.303820, 30.818638 |
| ZipCrypto | 0.145298, 0.144814, 0.142738 | 0.205932, 0.206274, 0.205557 |

Final `GIT_OPTIONAL_LOCKS=0 git diff --check` and a whitespace/newline scan
of all ten new files both exited **0**. Final status contains only the four
modified production files and the ten new files listed above.
