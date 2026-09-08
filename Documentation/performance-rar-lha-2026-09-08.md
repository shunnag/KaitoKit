# RAR29 / LHA performance verification — 2026-09-08

All measurements below were run in `<repo>` using the supplied
archive corpus and the XADMaster executable as a black box. No third-party
decoder implementation sources were consulted. No commits were created.

## Final extraction medians

The before column is the unmodified repository's Swift 6.3.3 release build
measured in this session. Each pair runs `xadbench extract <archive> 3` followed
by `kaito bench <archive> 3`. XADMaster values are medians of its JSON `rep_ms`.
Compilation, tests, and oracle runs did not overlap these benchmarks.

| Archive | Before KaitoKit ms | Final KaitoKit ms | Paired XADMaster ms | K / X | Change |
|---|---:|---:|---:|---:|---:|
| book-rar4.cbr | 29.445 | 30.211* | 34.75* | 0.87 | +2.6% |
| book-tiff-rar4.cbr | 987.587 | 386.113 | 317.41 | 1.22 | -60.9% |
| book-lh5.lzh | 5987.840 | 2105.210 | 2716.64 | 0.77 | -64.8% |
| book-lh6.lzh | 5986.622 | 2131.214 | 2759.29 | 0.77 | -64.4% |
| book-lh7.lzh | 6007.697 | 2166.296 | 2795.21 | 0.78 | -63.9% |
| book-tiff-lh5.lzh | 2564.970 | 382.778 | 883.01 | 0.43 | -85.1% |
| book-tiff-lh6.lzh | 2505.287 | 347.405 | 856.36 | 0.41 | -86.1% |
| book-tiff-lh7.lzh | 2500.154 | 339.283 | 843.58 | 0.40 | -86.4% |
| book-rar5.cbr | 29.308 | 29.298 | 34.47 | 0.85 | -0.0% |
| book-tiff-rar5.cbr | 527.727 | 523.726 | 314.12 | 1.67 | -0.8% |
| book-tiff.7z | 526.687 | 522.100 | 422.49 | 1.24 | -0.9% |
| book-deflate.cbz | 686.924 | 681.372 | 660.43 | 1.03 | -0.8% |

*JPEG RAR4 initially measured 31.266 ms in the final full sweep (+6.2% versus
this session's baseline, below the supplied original 33 ms). Three additional
alternating pairs measured 29.242, 31.077, and 30.211 ms; the starred entries use
the median of those three medians. Their paired XADMaster medians were 34.75,
34.64, and 34.85 ms. The raw initial result and all rechecks are retained below.

RAR29 TIFF meets both the 480 ms limit and the 1.5x paired ratio. JPEG lh5 and
TIFF lh7 meet the 3600 / 1200 ms limits, and all six LHA archives meet the 1.3x
ratio. RAR5, 7z, and deflate are regression checks; their decoders were unchanged.

## Per-step measurements and implementation

| Root cause / archive | Before step ms | After step ms | Technique |
|---|---:|---:|---|
| CRC16 / book-lh5.lzh | 5987.840 | 3745.171 | Slice-by-eight reflected ARC, once-built table borrowed through a raw pointer |
| CRC16 / book-tiff-lh7.lzh | 2500.154 | 414.813 | Same CRC16 change |
| RAR29 / book-tiff-rar4.cbr | 987.587 | 379.146 | Period staging/doubling, distance-one memset, wrapped copies, local window/history/emitted state, raw slot constants, 64-bit peek, 10-bit primary table |
| LHA static Huffman / book-lh5.lzh | 3745.171 | 2093.729 | 11-bit primary lookup and loop-local 64-bit reservoir |
| LHA static Huffman / book-tiff-lh7.lzh | 414.813 | 342.422 | Same static Huffman change |

The RAR copy/state change first measured 551.502 ms. Subsequent retained changes
measured 515.386 ms (64-bit peek), 510.360 ms (remaining local state), 490.676 ms
(raw slot constants), and 474.799 ms (remaining-bit check before addition).
LHA was then optimized. The first full sweep still gave a RAR paired ratio of
1.53x despite meeting the absolute 480 ms limit, so a 4 KiB, 10-bit primary table
was added ahead of the existing 128 KiB, 15-bit fallback. That measured 379.146 ms
against 316.99 ms (1.20x), after which optimization stopped.

Two RAR experiments were reverted: immediate match emission (527.127 ms) and
constant-sized short staging copies in the shared LHA primitive (512.455 ms).
`LHABoundedWindow.swift` therefore has no production change; RAR reuses its
existing bounded copy algorithm, with a RAR-only byte loop for chunks <= 8 bytes.

The logical bit bounds remain separate from the eight-byte physical sentinels.
All word loads fit inside the allocated input. Invalid Huffman metadata is rejected
before publishing tables; slot/distance/output bounds are checked before raw
accesses. RAR checks its sticky overrun flag every symbol iteration, including
symbol 258's no-output path. Window/history/emitted state is committed on return
or error, including PPMd/filter paths. The general `MSBFirstBitReader` and other
LHA methods are unchanged apart from benefiting from CRC16.

Added tests cover CRC-16/ARC's `123456789 -> 0xBB3D`, deterministic random buffers
at 16 alignments and lengths 0...80 plus larger boundaries through 8192 bytes,
incremental split updates against the old bit-serial reference, every position
and distance in a 32-byte ring, short caller chunks, RAR primary/fallback codes,
and LHA 1...16-bit codes across bulk refills and truncated sentinel lookahead.

## Verification commands and sandbox adjustments

The initial requested release build could not write the default module cache:

```text
<unknown>:0: error: error opening '<clang module cache>/Swift-1IEYM950OGIQC.swiftmodule' for output: <clang module cache>: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macosx14.0'
```

Builds/tests succeeded using repository-local caches and SwiftPM's
`--disable-sandbox` option (the outer filesystem sandbox remained active):

```sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/perf-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/perf-cache"
DEVELOPER_DIR=/Applications/Xcode.app swift build --disable-sandbox -c release --product kaito
DEVELOPER_DIR=/Applications/Xcode.app swift test --disable-sandbox
swift test --disable-sandbox
Scripts/fuzz/build-asan.sh
Scripts/fuzz/run-mutants.sh --count 300 --timeout 8 "$S"/fuzz-seeds/rar/*.rar "$S"/fuzz-seeds/lha/*
git diff --check
git status --porcelain
```

Tests and fuzzing also set `TMPDIR="$PWD/.build/performance/tmp/"` to keep their
scratch work in the repository. SwiftPM emitted a nonfatal readonly manifest-cache
warning; it did not prevent compilation or tests. The toolchains reported Apple
Swift 6.3.3 and Apple Swift 6.4. The release executable used for benchmarks and
SHA checks was `.build/release/kaito`, built with Swift 6.3.3.

The XADMaster harness, supplied corpus/oracles, and Downloads `st1200-pts.rar`
were accessible. The requested command reading
`<external LZH fixture>` was intentionally not run
because the task prohibited touching that repository. Instead, the supplied
`$S/fuzz-seeds/lha/book.lzh` was compared against `$S/oracle/book.lzh.tsv`.
SHA TSV output was written inside `.build/performance/`, using the supplied
`compare-sha.py` with the same oracle files. Process sampling was unavailable:
`sample` reported that it could not examine the process. Inspection of KaitoKit's
own generated assembly was used to identify remaining array-subscript calls.

### Actual build/test/fuzz output

`rar-primary-build`

```text
Building for production...
[0/3] Write sources
[1/3] Write swift-version--58304C5D6DBC2206.txt
[3/4] Compiling KaitoKit Bzip2Decompressor.swift
[4/6] Compiling kaito main.swift
[4/6] Write Objects.LinkFileList
[5/6] Linking kaito
Build of product 'kaito' complete! (28.81s)
```

`swift-6.3.3-tests`

```text
Test Suite 'KaitoKitPackageTests.xctest' passed at 2026-09-08 05:33:32.104.
	 Executed 582 tests, with 33 tests skipped and 0 failures (0 unexpected) in 124.451 (124.490) seconds
Test Suite 'All tests' passed at 2026-09-08 05:33:32.104.
	 Executed 582 tests, with 33 tests skipped and 0 failures (0 unexpected) in 124.451 (124.491) seconds
◇ Test run started.
↳ Testing Library Version: 1902
↳ Target Platform: arm64e-apple-macos14.0
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
```

`swift-6.4-tests`

```text
Test Suite 'All tests' passed at 2026-09-08 05:35:50.188.
	 Executed 568 tests, with 33 tests skipped and 0 failures (0 unexpected) in 124.806 (124.843) seconds
Test Suite 'All tests' passed at 2026-09-08 05:35:50.973.
	 Executed 14 tests, with 0 failures (0 unexpected) in 0.668 (0.671) seconds
◇ Test run started.
↳ Testing Library Version: 2078
↳ Target Platform: arm64e-apple-macos14.0
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
◇ Test run started.
↳ Testing Library Version: 2078
↳ Target Platform: arm64e-apple-macos14.0
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
```

`swift-6.4-release-build`

```text
[66 / 77] KaitoKit
[73 / 78] kaito-product
[75 / 79] kaito-product
[77 / 79] kaito-product
error: Operation not permitted
error: GenerateDSYMFile <repo>/.build/performance/release64/out/Products/Release/kaito.dSYM <repo>/.build/performance/release64/out/Products/Release/kaito failed with a nonzero exit code. Command line:     cd <repo>
    /Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/dsymutil <repo>/.build/performance/release64/out/Products/Release/kaito -o <repo>/.build/performance/release64/out/Products/Release/kaito.dSYM
error: Build failed
```

`swift-6.4-release-native-build`

```text
[0/5] Write sources
[2/5] Write swift-version-39B54973F684ADAB.txt
[4/6] Compiling KaitoKit Bzip2Decompressor.swift
[5/7] Compiling kaito main.swift
[5/7] Write Objects.LinkFileList
[6/7] Linking kaito
Build of product 'kaito' complete! (20.82s)
warning: '--build-system native' has been deprecated and will be removed in a future release; please report an issue at https://github.com/swiftlang/swift-package-manager/issues if you are unable to adopt the default build system.
```

`asan-build`

```text
[20 / 32] KaitoKit
[27 / 39] KaitoKit
[31 / 43] kaito-product
[35 / 45] KaitoKit
[38 / 45] KaitoKit
[44 / 46] kaito-product
[46 / 46] KaitoKitDynamic-product
Build complete! (2.14秒)
```

`mutants`

```text
warning: 'kaitokit': failed storing manifest for 'kaitokit' in cache: attempt to write a readonly database
Building for debugging...
Build complete! (0.22秒)
warning: <swiftpm state>/configuration is not accessible or not writable, disabling user-level cache features.
warning: <swiftpm state>/security is not accessible or not writable, disabling user-level cache features.
warning: <swiftpm cache> is not accessible or not writable, disabling user-level cache features.
generated 300 mutants from 16 seed(s)
mutants: 300, crashes: 0, hangs: 0, sanitizer findings: 0
```

Swift 6.3.3 executed 582 tests (33 skipped, zero failures); Swift 6.4
executed 568 KaitoKit tests plus 14 compat tests (33 skipped, zero failures).
Both full test commands exited 0. The 300-mutant command exited 0 with zero
crashes, hangs, or sanitizer findings.

The additional Swift 6.4 release build using its default `swiftbuild` engine
failed only at dSYM generation with `Operation not permitted`. The same
Swift 6.4 compiler built release successfully with the native build system:

```sh
swift build --disable-sandbox --build-system native \
  --scratch-path .build/performance/release64-native -c release --product kaito
```

The three changed decoder acceptance archives were also SHA-checked using that
Swift 6.4 release executable; all returned `RESULT: OK`. This extra check did
not replace the full Swift 6.3.3 release oracle sweep.

### Actual Swift 6.4 release oracle output

```text
book-tiff-rar4.cbr
expected 100 entries, actual 100 entries
missing in actual: 0
extra in actual: 0
digest/size mismatches: 0
total digest: match (896dc342532bb7b7b19f7d9864e87cd56ce22d57bc2704f7f3618cb72449aa72 vs 896dc342532bb7b7b19f7d9864e87cd56ce22d57bc2704f7f3618cb72449aa72)
RESULT: OK

book-lh5.lzh
expected 200 entries, actual 200 entries
missing in actual: 0
extra in actual: 0
digest/size mismatches: 0
total digest: match (5ffea8f37ce097435251c538c33adc6e275e394df46f28f026dcda90f30d0044 vs 5ffea8f37ce097435251c538c33adc6e275e394df46f28f026dcda90f30d0044)
RESULT: OK

book-tiff-lh7.lzh
expected 100 entries, actual 100 entries
missing in actual: 0
extra in actual: 0
digest/size mismatches: 0
total digest: match (896dc342532bb7b7b19f7d9864e87cd56ce22d57bc2704f7f3618cb72449aa72 vs 896dc342532bb7b7b19f7d9864e87cd56ce22d57bc2704f7f3618cb72449aa72)
RESULT: OK


```

### Actual oracle output

```text
<corpus>/bench-work/corpus/archives/book-rar4.cbr:
expected 200 entries, actual 200 entries
missing in actual: 0
extra in actual: 0
digest/size mismatches: 0
total digest: match (5ffea8f37ce097435251c538c33adc6e275e394df46f28f026dcda90f30d0044 vs 5ffea8f37ce097435251c538c33adc6e275e394df46f28f026dcda90f30d0044)
RESULT: OK

<corpus>/bench-work/corpus/archives/book-tiff-rar4.cbr:
expected 100 entries, actual 100 entries
missing in actual: 0
extra in actual: 0
digest/size mismatches: 0
total digest: match (896dc342532bb7b7b19f7d9864e87cd56ce22d57bc2704f7f3618cb72449aa72 vs 896dc342532bb7b7b19f7d9864e87cd56ce22d57bc2704f7f3618cb72449aa72)
RESULT: OK

<corpus>/bench-work/corpus/archives/book-lh5.lzh:
expected 200 entries, actual 200 entries
missing in actual: 0
extra in actual: 0
digest/size mismatches: 0
total digest: match (5ffea8f37ce097435251c538c33adc6e275e394df46f28f026dcda90f30d0044 vs 5ffea8f37ce097435251c538c33adc6e275e394df46f28f026dcda90f30d0044)
RESULT: OK

<corpus>/bench-work/corpus/archives/book-lh6.lzh:
expected 200 entries, actual 200 entries
missing in actual: 0
extra in actual: 0
digest/size mismatches: 0
total digest: match (5ffea8f37ce097435251c538c33adc6e275e394df46f28f026dcda90f30d0044 vs 5ffea8f37ce097435251c538c33adc6e275e394df46f28f026dcda90f30d0044)
RESULT: OK

<corpus>/bench-work/corpus/archives/book-lh7.lzh:
expected 200 entries, actual 200 entries
missing in actual: 0
extra in actual: 0
digest/size mismatches: 0
total digest: match (5ffea8f37ce097435251c538c33adc6e275e394df46f28f026dcda90f30d0044 vs 5ffea8f37ce097435251c538c33adc6e275e394df46f28f026dcda90f30d0044)
RESULT: OK

<corpus>/bench-work/corpus/archives/book-tiff-lh5.lzh:
expected 100 entries, actual 100 entries
missing in actual: 0
extra in actual: 0
digest/size mismatches: 0
total digest: match (896dc342532bb7b7b19f7d9864e87cd56ce22d57bc2704f7f3618cb72449aa72 vs 896dc342532bb7b7b19f7d9864e87cd56ce22d57bc2704f7f3618cb72449aa72)
RESULT: OK

<corpus>/bench-work/corpus/archives/book-tiff-lh6.lzh:
expected 100 entries, actual 100 entries
missing in actual: 0
extra in actual: 0
digest/size mismatches: 0
total digest: match (896dc342532bb7b7b19f7d9864e87cd56ce22d57bc2704f7f3618cb72449aa72 vs 896dc342532bb7b7b19f7d9864e87cd56ce22d57bc2704f7f3618cb72449aa72)
RESULT: OK

<corpus>/bench-work/corpus/archives/book-tiff-lh7.lzh:
expected 100 entries, actual 100 entries
missing in actual: 0
extra in actual: 0
digest/size mismatches: 0
total digest: match (896dc342532bb7b7b19f7d9864e87cd56ce22d57bc2704f7f3618cb72449aa72 vs 896dc342532bb7b7b19f7d9864e87cd56ce22d57bc2704f7f3618cb72449aa72)
RESULT: OK

<corpus>/bench-work/corpus/archives/book-rar5.cbr:
expected 200 entries, actual 200 entries
missing in actual: 0
extra in actual: 0
digest/size mismatches: 0
total digest: match (5ffea8f37ce097435251c538c33adc6e275e394df46f28f026dcda90f30d0044 vs 5ffea8f37ce097435251c538c33adc6e275e394df46f28f026dcda90f30d0044)
RESULT: OK

<corpus>/bench-work/corpus/archives/book-tiff-rar5.cbr:
expected 100 entries, actual 100 entries
missing in actual: 0
extra in actual: 0
digest/size mismatches: 0
total digest: match (896dc342532bb7b7b19f7d9864e87cd56ce22d57bc2704f7f3618cb72449aa72 vs 896dc342532bb7b7b19f7d9864e87cd56ce22d57bc2704f7f3618cb72449aa72)
RESULT: OK

<corpus>/bench-work/corpus/archives/book-tiff.7z:
expected 100 entries, actual 100 entries
missing in actual: 0
extra in actual: 0
digest/size mismatches: 0
total digest: match (896dc342532bb7b7b19f7d9864e87cd56ce22d57bc2704f7f3618cb72449aa72 vs 896dc342532bb7b7b19f7d9864e87cd56ce22d57bc2704f7f3618cb72449aa72)
RESULT: OK

<corpus>/bench-work/corpus/archives/sjis2000.zip:
expected 2000 entries, actual 2000 entries
missing in actual: 0
extra in actual: 0
digest/size mismatches: 0
total digest: match (9f422e3330804be8ffb8eeff25d9dc554eb24ac0f8ec04adec4aa52df9fde126 vs 9f422e3330804be8ffb8eeff25d9dc554eb24ac0f8ec04adec4aa52df9fde126)
RESULT: OK

<external RAR4 archive>:
expected 20 entries, actual 20 entries
missing in actual: 0
extra in actual: 0
digest/size mismatches: 0
total digest: match (44cc72cc4a9b5a03afa47cfb6cd59b154b3c673a7da1b3015ca487130862e68b vs 44cc72cc4a9b5a03afa47cfb6cd59b154b3c673a7da1b3015ca487130862e68b)
RESULT: OK

<corpus>/fuzz-seeds/lha/book.lzh:
expected 4 entries, actual 4 entries
missing in actual: 0
extra in actual: 0
digest/size mismatches: 0
total digest: match (53bbe8926086ebd7d4e65b9c90dc9c367385ee0808a23bae3972cbfe5e3ce97c vs 53bbe8926086ebd7d4e65b9c90dc9c367385ee0808a23bae3972cbfe5e3ce97c)
RESULT: OK


```

### Actual benchmark output: baseline

```text
book-tiff-rar4.cbr XADMaster: {"mode":"extract","archive":"book-tiff-rar4.cbr","entries":100,"bytes":1153495200,"diskread":0,"pageins":2,"rep_ms":[435.08,318.52,320.04],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"} [exit 0]
book-tiff-rar4.cbr KaitoKit: extract-median-ms	987.587 [exit 0]
book-lh5.lzh XADMaster: {"mode":"extract","archive":"book-lh5.lzh","entries":200,"bytes":1209043650,"diskread":0,"pageins":2,"rep_ms":[2831.59,2717.88,2711.90],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"} [exit 0]
book-lh5.lzh KaitoKit: extract-median-ms	5987.840 [exit 0]
book-lh6.lzh XADMaster: {"mode":"extract","archive":"book-lh6.lzh","entries":200,"bytes":1209043650,"diskread":0,"pageins":2,"rep_ms":[4489.43,4467.80,4465.29],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"} [exit 0]
book-lh6.lzh KaitoKit: extract-median-ms	5986.622 [exit 0]
book-lh7.lzh XADMaster: {"mode":"extract","archive":"book-lh7.lzh","entries":200,"bytes":1209043650,"diskread":0,"pageins":2,"rep_ms":[2910.75,2797.66,2786.52],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"} [exit 0]
book-lh7.lzh KaitoKit: extract-median-ms	6007.697 [exit 0]
book-tiff-lh5.lzh XADMaster: {"mode":"extract","archive":"book-tiff-lh5.lzh","entries":100,"bytes":1153495200,"diskread":0,"pageins":2,"rep_ms":[1000.94,879.44,881.49],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"} [exit 0]
book-tiff-lh5.lzh KaitoKit: extract-median-ms	2564.970 [exit 0]
book-tiff-lh6.lzh XADMaster: {"mode":"extract","archive":"book-tiff-lh6.lzh","entries":100,"bytes":1153495200,"diskread":0,"pageins":2,"rep_ms":[967.26,859.55,858.42],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"} [exit 0]
book-tiff-lh6.lzh KaitoKit: extract-median-ms	2505.287 [exit 0]
book-tiff-lh7.lzh XADMaster: {"mode":"extract","archive":"book-tiff-lh7.lzh","entries":100,"bytes":1153495200,"diskread":0,"pageins":2,"rep_ms":[970.74,842.43,861.27],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"} [exit 0]
book-tiff-lh7.lzh KaitoKit: extract-median-ms	2500.154 [exit 0]
book-rar4.cbr XADMaster: {"mode":"extract","archive":"book-rar4.cbr","entries":200,"bytes":1209043650,"diskread":0,"pageins":2,"rep_ms":[155.02,34.94,34.58],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"} [exit 0]
book-rar4.cbr KaitoKit: extract-median-ms	29.445 [exit 0]
book-rar5.cbr XADMaster: {"mode":"extract","archive":"book-rar5.cbr","entries":200,"bytes":1209043650,"diskread":403046400,"pageins":2,"rep_ms":[165.73,34.58,34.70],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"} [exit 0]
book-rar5.cbr KaitoKit: extract-median-ms	29.308 [exit 0]
book-tiff-rar5.cbr XADMaster: {"mode":"extract","archive":"book-tiff-rar5.cbr","entries":100,"bytes":1153495200,"diskread":17145856,"pageins":2,"rep_ms":[429.72,315.73,317.00],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"} [exit 0]
book-tiff-rar5.cbr KaitoKit: extract-median-ms	527.727 [exit 0]
book-tiff.7z XADMaster: {"mode":"extract","archive":"book-tiff.7z","entries":100,"bytes":1153495200,"diskread":15482880,"pageins":2,"rep_ms":[527.51,409.30,411.56],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"} [exit 0]
book-tiff.7z KaitoKit: extract-median-ms	526.687 [exit 0]
book-deflate.cbz XADMaster: {"mode":"extract","archive":"book-deflate.cbz","entries":200,"bytes":1209043650,"diskread":402317312,"pageins":1,"rep_ms":[793.70,663.51,677.98],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"} [exit 0]
book-deflate.cbz KaitoKit: extract-median-ms	686.924 [exit 0]
```

### Actual benchmark output: crc

```text
book-lh5.lzh XADMaster: {"mode":"extract","archive":"book-lh5.lzh","entries":200,"bytes":1209043650,"diskread":0,"pageins":2,"rep_ms":[2811.44,2703.50,2698.50],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"} [exit 0]
book-lh5.lzh KaitoKit: extract-median-ms	3745.171 [exit 0]
book-tiff-lh7.lzh XADMaster: {"mode":"extract","archive":"book-tiff-lh7.lzh","entries":100,"bytes":1153495200,"diskread":0,"pageins":2,"rep_ms":[978.88,860.44,851.83],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"} [exit 0]
book-tiff-lh7.lzh KaitoKit: extract-median-ms	414.813 [exit 0]
```

### Actual benchmark output: rar

```text
book-tiff-rar4.cbr XADMaster: {"mode":"extract","archive":"book-tiff-rar4.cbr","entries":100,"bytes":1153495200,"diskread":0,"pageins":2,"rep_ms":[431.95,318.89,319.89],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"} [exit 0]
book-tiff-rar4.cbr KaitoKit: extract-median-ms	551.502 [exit 0]
book-rar4.cbr XADMaster: {"mode":"extract","archive":"book-rar4.cbr","entries":200,"bytes":1209043650,"diskread":0,"pageins":2,"rep_ms":[156.68,35.18,35.04],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"} [exit 0]
book-rar4.cbr KaitoKit: extract-median-ms	29.577 [exit 0]
```

### Actual benchmark output: rar-peek

```text
book-tiff-rar4.cbr XADMaster: {"mode":"extract","archive":"book-tiff-rar4.cbr","entries":100,"bytes":1153495200,"diskread":0,"pageins":2,"rep_ms":[428.16,313.61,313.86],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"} [exit 0]
book-tiff-rar4.cbr KaitoKit: extract-median-ms	515.386 [exit 0]
```

### Actual benchmark output: rar-local

```text
book-tiff-rar4.cbr XADMaster: {"mode":"extract","archive":"book-tiff-rar4.cbr","entries":100,"bytes":1153495200,"diskread":0,"pageins":2,"rep_ms":[426.11,314.43,313.93],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"} [exit 0]
book-tiff-rar4.cbr KaitoKit: extract-median-ms	510.360 [exit 0]
```

### Actual benchmark output: rar-slots

```text
book-tiff-rar4.cbr XADMaster: {"mode":"extract","archive":"book-tiff-rar4.cbr","entries":100,"bytes":1153495200,"diskread":0,"pageins":2,"rep_ms":[428.13,312.01,313.28],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"} [exit 0]
book-tiff-rar4.cbr KaitoKit: extract-median-ms	490.676 [exit 0]
book-rar4.cbr XADMaster: {"mode":"extract","archive":"book-rar4.cbr","entries":200,"bytes":1209043650,"diskread":0,"pageins":2,"rep_ms":[156.23,34.73,34.61],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"} [exit 0]
book-rar4.cbr KaitoKit: extract-median-ms	29.227 [exit 0]
```

### Actual benchmark output: rar-bounds

```text
book-tiff-rar4.cbr XADMaster: {"mode":"extract","archive":"book-tiff-rar4.cbr","entries":100,"bytes":1153495200,"diskread":0,"pageins":2,"rep_ms":[426.24,309.51,307.86],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"} [exit 0]
book-tiff-rar4.cbr KaitoKit: extract-median-ms	474.799 [exit 0]
```

### Actual benchmark output: lha

```text
book-lh5.lzh XADMaster: {"mode":"extract","archive":"book-lh5.lzh","entries":200,"bytes":1209043650,"diskread":0,"pageins":2,"rep_ms":[2805.39,2689.60,2694.78],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"} [exit 0]
book-lh5.lzh KaitoKit: extract-median-ms	2093.729 [exit 0]
book-tiff-lh7.lzh XADMaster: {"mode":"extract","archive":"book-tiff-lh7.lzh","entries":100,"bytes":1153495200,"diskread":0,"pageins":2,"rep_ms":[958.90,844.92,845.17],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"} [exit 0]
book-tiff-lh7.lzh KaitoKit: extract-median-ms	342.422 [exit 0]
```

### Actual benchmark output: rar-primary

```text
book-tiff-rar4.cbr XADMaster: {"mode":"extract","archive":"book-tiff-rar4.cbr","entries":100,"bytes":1153495200,"diskread":0,"pageins":2,"rep_ms":[428.64,313.83,316.99],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"} [exit 0]
book-tiff-rar4.cbr KaitoKit: extract-median-ms	379.146 [exit 0]
```

### Actual benchmark output: final-accepted

```text
book-tiff-rar4.cbr XADMaster: {"mode":"extract","archive":"book-tiff-rar4.cbr","entries":100,"bytes":1153495200,"diskread":0,"pageins":2,"rep_ms":[426.82,316.89,317.41],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"} [exit 0]
book-tiff-rar4.cbr KaitoKit: extract-median-ms	386.113 [exit 0]
book-lh5.lzh XADMaster: {"mode":"extract","archive":"book-lh5.lzh","entries":200,"bytes":1209043650,"diskread":0,"pageins":2,"rep_ms":[2837.73,2714.90,2716.64],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"} [exit 0]
book-lh5.lzh KaitoKit: extract-median-ms	2105.210 [exit 0]
book-lh6.lzh XADMaster: {"mode":"extract","archive":"book-lh6.lzh","entries":200,"bytes":1209043650,"diskread":0,"pageins":2,"rep_ms":[2876.29,2759.29,2756.89],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"} [exit 0]
book-lh6.lzh KaitoKit: extract-median-ms	2131.214 [exit 0]
book-lh7.lzh XADMaster: {"mode":"extract","archive":"book-lh7.lzh","entries":200,"bytes":1209043650,"diskread":0,"pageins":2,"rep_ms":[2911.59,2795.21,2778.42],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"} [exit 0]
book-lh7.lzh KaitoKit: extract-median-ms	2166.296 [exit 0]
book-tiff-lh5.lzh XADMaster: {"mode":"extract","archive":"book-tiff-lh5.lzh","entries":100,"bytes":1153495200,"diskread":0,"pageins":2,"rep_ms":[996.99,882.75,883.01],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"} [exit 0]
book-tiff-lh5.lzh KaitoKit: extract-median-ms	382.778 [exit 0]
book-tiff-lh6.lzh XADMaster: {"mode":"extract","archive":"book-tiff-lh6.lzh","entries":100,"bytes":1153495200,"diskread":0,"pageins":2,"rep_ms":[975.02,856.36,854.34],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"} [exit 0]
book-tiff-lh6.lzh KaitoKit: extract-median-ms	347.405 [exit 0]
book-tiff-lh7.lzh XADMaster: {"mode":"extract","archive":"book-tiff-lh7.lzh","entries":100,"bytes":1153495200,"diskread":0,"pageins":2,"rep_ms":[958.95,841.78,843.58],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"} [exit 0]
book-tiff-lh7.lzh KaitoKit: extract-median-ms	339.283 [exit 0]
book-rar4.cbr XADMaster: {"mode":"extract","archive":"book-rar4.cbr","entries":200,"bytes":1209043650,"diskread":0,"pageins":2,"rep_ms":[156.40,35.15,35.49],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"} [exit 0]
book-rar4.cbr KaitoKit: extract-median-ms	31.266 [exit 0]
book-rar5.cbr XADMaster: {"mode":"extract","archive":"book-rar5.cbr","entries":200,"bytes":1209043650,"diskread":0,"pageins":2,"rep_ms":[156.65,34.47,34.38],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"} [exit 0]
book-rar5.cbr KaitoKit: extract-median-ms	29.298 [exit 0]
book-tiff-rar5.cbr XADMaster: {"mode":"extract","archive":"book-tiff-rar5.cbr","entries":100,"bytes":1153495200,"diskread":0,"pageins":2,"rep_ms":[427.08,313.70,314.12],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"} [exit 0]
book-tiff-rar5.cbr KaitoKit: extract-median-ms	523.726 [exit 0]
book-tiff.7z XADMaster: {"mode":"extract","archive":"book-tiff.7z","entries":100,"bytes":1153495200,"diskread":0,"pageins":2,"rep_ms":[527.24,422.49,407.81],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"} [exit 0]
book-tiff.7z KaitoKit: extract-median-ms	522.100 [exit 0]
book-deflate.cbz XADMaster: {"mode":"extract","archive":"book-deflate.cbz","entries":200,"bytes":1209043650,"diskread":0,"pageins":1,"rep_ms":[777.58,657.69,660.43],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"} [exit 0]
book-deflate.cbz KaitoKit: extract-median-ms	681.372 [exit 0]
```

### Actual benchmark output: rar4-regression-recheck

```text
book-rar4.cbr XADMaster: {"mode":"extract","archive":"book-rar4.cbr","entries":200,"bytes":1209043650,"diskread":0,"pageins":2,"rep_ms":[157.03,34.75,34.67],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"} [exit 0]
book-rar4.cbr KaitoKit: extract-median-ms	29.242 [exit 0]
book-rar4.cbr XADMaster: {"mode":"extract","archive":"book-rar4.cbr","entries":200,"bytes":1209043650,"diskread":0,"pageins":2,"rep_ms":[155.95,34.64,34.44],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"} [exit 0]
book-rar4.cbr KaitoKit: extract-median-ms	31.077 [exit 0]
book-rar4.cbr XADMaster: {"mode":"extract","archive":"book-rar4.cbr","entries":200,"bytes":1209043650,"diskread":0,"pageins":2,"rep_ms":[157.10,34.55,34.85],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"} [exit 0]
book-rar4.cbr KaitoKit: extract-median-ms	30.211 [exit 0]
```

## Files changed

- `Sources/KaitoKit/Core/CRC16.swift`
- `Sources/KaitoKit/Codecs/RAR/RAR29Decoder.swift`
- `Sources/KaitoKit/Codecs/LHA/LZSStaticHuffmanDecoder.swift`
- `Tests/KaitoKitTests/CRC16Tests.swift`
- `Tests/KaitoKitTests/LHABoundedWindowTests.swift`
- `Tests/KaitoKitTests/RAR4ReaderTests.swift`
- `Tests/KaitoKitTests/LZSStaticHuffmanDecoderTests.swift`
- `Documentation/design.md`
- `Documentation/performance-rar-lha-2026-09-08.md`
- `CHANGELOG.md`

Build logs, benchmark wrappers, and SHA TSVs are retained under the ignored
`.build/performance/` directory. All source/document changes remain uncommitted.

## Final working tree

`git diff --check` exited 0 and produced no output.

`git diff --stat` (tracked files):

```text
 CHANGELOG.md                                       |   3 +
 Documentation/design.md                            |  13 +-
 .../Codecs/LHA/LZSStaticHuffmanDecoder.swift       | 106 +++-----
 Sources/KaitoKit/Codecs/RAR/RAR29Decoder.swift     | 293 ++++++++++++---------
 Sources/KaitoKit/Core/CRC16.swift                  |  45 +++-
 .../LZSStaticHuffmanDecoderTests.swift             |  28 ++
 Tests/KaitoKitTests/RAR4ReaderTests.swift          |  53 ++++
 7 files changed, 352 insertions(+), 189 deletions(-)
```

`git status --porcelain`:

```text
 M CHANGELOG.md
 M Documentation/design.md
 M Sources/KaitoKit/Codecs/LHA/LZSStaticHuffmanDecoder.swift
 M Sources/KaitoKit/Codecs/RAR/RAR29Decoder.swift
 M Sources/KaitoKit/Core/CRC16.swift
 M Tests/KaitoKitTests/LZSStaticHuffmanDecoderTests.swift
 M Tests/KaitoKitTests/RAR4ReaderTests.swift
?? Documentation/performance-rar-lha-2026-09-08.md
?? Tests/KaitoKitTests/CRC16Tests.swift
?? Tests/KaitoKitTests/LHABoundedWindowTests.swift
```
