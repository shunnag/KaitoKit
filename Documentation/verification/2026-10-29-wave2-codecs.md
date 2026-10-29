# Deflate64 and independent LZ4 decode performance (2026-10-29)

Scope: `cooViewer-y9eq.10` and `cooViewer-y9eq.16`, starting at
`7b1e5837718f6e4f11a36cd427a857c6851b8814` on `perf/wave2-ke1`.
The work is confined to this worktree. No `bd`, git mutation, or CHANGELOG edit was used.

## Provenance

KaitoKit is clean-room. This work used KaitoKit's own source, fixtures, and
2026-10-10/10-11 verification records; the existing RFC 1951 / PKWARE APPNOTE
Deflate64 and public LZ4 block/frame format contracts; and Apple's installed
`compression.h` documentation for `compression_decode_buffer` and
`compression_decode_scratch_buffer_size`. `7zz` and `lz4` were used solely as
black-box executables on project-owned bytes. No unrar, 7-Zip/p7zip, XADMaster,
The Unarchiver, libarchive, zlib inflate, LZ4 reference, libdeflate, or other
implementation source was opened or used.

## Changes by file

- `Sources/KaitoKit/Codecs/Deflate64Decompressor.swift`: fixed Huffman tables are
  immutable, thread-safe static values; input storage is uninitialized and sized
  to at most the compressed range / 256 KiB; the 64 KiB ring is uninitialized.
  A local value holds input cursor, 64-bit reservoir, output/history accounting,
  and pending match state throughout each read. Stored bytes copy in bulk after
  draining prefetched reservoir bytes. Literal output uses a precomputed budget;
  matches use the existing `copyLZMatchThroughWindow`. Header parsing, incomplete
  Huffman trees, speculative-refill policy, final padding/trailing-byte checks,
  and error ordering are retained.
- `Sources/KaitoKit/Codecs/LZ4/LZ4AppleBlockDecoder.swift`: an independent-block
  adapter owns reusable scratch, probes the first 32 match sequences, validates
  the complete token grammar of retained candidates without copying output, then calls `COMPRESSION_LZ4_RAW` with validated output size + 1 bytes.
  A zero result or decoded-size disagreement falls back to Swift. An output over
  the block maximum produces the existing `limitExceeded` error class.
- `Sources/KaitoKit/Codecs/LZ4/LZ4FrameDecompressor.swift`: checked independent
  modern blocks select the adapter. Dependent blocks, legacy frames, and modern
  frames with neither checksum retain the original Swift call. Stored
  blocks and checksum/content-size processing retain their original order.
- `Tests/KaitoKitTests/Support/Deflate64HEADDecoder.swift`: frozen starting-HEAD
  decoder and private Huffman implementation, renamed as test-only types. This
  is distinct from the existing older `Deflate64ReferenceDecoder`.
- `Tests/KaitoKitTests/Codecs/Deflate64DifferentialTests.swift`: compares both
  frozen HEAD and the earlier tree oracle with the optimized decoder. Adds
  deterministic random stored/fixed streams and arbitrary bytes, crossing input
  sizes 1 / 7 / 4096 / 65537 / 262144 and output sizes 1 / 7 / 4096 / 65537 /
  262144 / 300000. Existing fixtures, maximum match/distance, dynamic secondary
  tables, bit flips, truncations, extra trailing bytes, and size mismatches remain.
  Outcomes include exact errors, returned bytes/count, finished state, and the
  complete caller buffer on a throwing read.
- `Tests/KaitoKitTests/Support/LZ4HEADFrameDecompressor.swift`: frozen starting-HEAD
  frame parser always calling the unchanged Swift block decoder.
- `Tests/KaitoKitTests/Codecs/LZ4DifferentialTests.swift`: all existing LZ4 fixtures;
  the full routing truth table; 18 randomized CLI-generated frames covering
  independent block/content/both checksums, no checksums, dependent blocks, and
  legacy; 1728 mutations/truncations; 8192 arbitrary token-walk comparisons;
  malformed end conditions with recomputed block checksums; limits and empty
  output fallback. Exact errors and output at failure match the Swift oracle.
- `Tests/Measurement/wave2-codecs/measure.py`: repeatable corpus generation, SHA
  identity gates, and alternating release `kaito bench` runs. No external source.
- `Tests/Measurement/wave2-codecs/LZ4Probe.swift`: standalone release block probe
  comparing Swift, validation, Apple alone, and the complete adapter on legacy
  corpus bytes. This probe can call the adapter directly; production legacy
  framing always selects Swift.
- `Documentation/verification/2026-10-29-wave2-codecs.jsonl`: corpus and binary
  digests, every generator/benchmark command and result, identity-output digests,
  and final summary numbers. This Markdown file records the source changes,
  command outcomes, bound arguments, and interpretation.
- `Documentation/design.md`: records this bounded hot-path exception and adapter
  provenance; this record holds the bound arguments and verification results.

## Bound and behavior arguments

1. **Deflate64 input.** `0 <= inputOffset <= inputCount <= inputCapacity <= 256 KiB`.
   Refill exposes only the remaining validated compressed range. Only a validated
   source-returned prefix becomes readable. The reservoir refills through 56 bits,
   hence has at most 64 bits; required-bit reads are at most 32, Huffman codes at
   most 15. Speculation consumes only already fetched bytes, preserving malformed
   versus truncation/source-error priority. Stored headers align the reservoir;
   buffered bytes are copied only after its complete bytes have been consumed.
2. **Deflate64 literals.** At read entry, `totalOutput <= expectedSize` (if known).
   `literalLimit = min(outputCapacity, expectedSize - initialTotal, UInt64.max - initialTotal)`.
   Each literal requires `outputOffset < literalLimit`. Since outputOffset counts
   all bytes in the call, both the caller write and `totalOutput + 1` are proven
   in bounds. Stored-copy count is additionally bounded by storedRemaining and
   initialized input bytes. An exhausted budget still consumes the next token
   or stored byte before reporting the same error as HEAD. Token-free end markers
   still validate normally when the expected size has been reached.
3. **Deflate64 history/matches.** Ring indexes are masked to 0...65535. A decoded
   distance is checked against `min(totalOutput, 65536)` before use, so no virgin
   ring byte can be read. Literal writes and stored/match copies initialize every
   newly available history byte. Match copy counts fit the caller and expected
   budget; checked total addition occurs before any copy. The shared primitive
   stages at most one history period, doubles disjoint output spans for overlap,
   and mirrors at most one full ring turn. The maximum 65538-byte match uses a
   second invocation for its final two bytes, including distance 65536. Local
   state is committed with `defer` even on throws. Allocations occur after all
   throwing initialization range checks.
4. **Deflate64 tables and arithmetic.** The canonical constructor validates counts,
   prefix collisions, and symbols; every root slot and every full secondary suffix
   range exists. Masked lookup indexes therefore stay inside the borrowed table.
   Length symbols reach the helper only in 257...285: bases + extra bits yield
   3...65538. All validated distance symbols 0...31 yield 1...65536. These sums
   fit Int without per-token Checked conversions.
5. **LZ4 grammar.** Checksums cannot establish structural validity: an attacker can
   recompute one, and content checksums are verified after block output delivery.
   Every Apple-decoded block therefore gets a complete acceptance walk. Cursor
   increments stay in the encoded range. Each length extension and output addition
   is checked against remaining output before arithmetic. Distances are positive
   and at most prior output (independent history is empty). A final literal-only
   sequence is required; after any match it has >= 5 literals and the final match
   starts >= 12 output bytes before the end. Any failed acceptance check restarts
   the original Swift decoder, which supplies the exact error and check priority.
   That preserves `truncated`, `malformed`, and `limitExceeded` ordering even for
   recomputed checksums. Block checksum verification still precedes the walk.
   At the 32nd match, a prefix producing < 2048 bytes also falls back to Swift:
   this is only a performance selection, never permission to bypass validation.
   Sequence count is bounded by encoded bytes; no counter can approach Int.max.
6. **LZ4 buffers.** Frame descriptors bound modern maxima to 64 KiB...4 MiB;
   legacy uses 8 MiB and stays on Swift. The walk proves
   `expected <= maximumSize <= min(blockMaximum, remainingEntryLimit)` before
   allocation. The adapter reserves and passes **expected + 1** to Apple, rather
   than the frame maximum. This sum fits Int because expected is at most 4 MiB.
   The existing buffer adds 32 bytes of slack and retains capacity across blocks;
   growth follows validated output requests, not a frame's advertised maximum.
   A fresh buffer for a 5-byte output therefore needs only 38 bytes, even with a
   4 MiB frame maximum or a 5-byte entry limit. The extra byte is never published:
   an Apple return above expected reaches the cap and fails `count == expected`,
   falling back to Swift for the original behavior and error priority. Zero and
   all other size disagreements likewise fall back. Input, output, and scratch
   are disjoint. Empty encoded blocks fall back before any base-address unwrap;
   valid empty output re-decodes in Swift on Apple's ambiguous zero. Scratch is
   allocated once per adapter and reused serially; ineligible streams never
   construct the lazy adapter.

## Verification and commands

All paths below are relative to the workspace root. Logs and temporary files stay
under `.build/wave2/`; TMPDIR was set there for tests and final builds. Swift 6.4,
arm64 macOS 27.2, on the local M4 Max host. Hardware-detail sysctl was denied by the
sandbox; no escalation was requested. Existing `XZSyntheticStream.swift` unused
Foundation-import and SwiftPM native-build deprecation warnings are unrelated.

The final build/test commands use this common environment and argument prefix:

```sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/wave2/module-cache"
export TMPDIR="$PWD/.build/wave2/tmp"
SPM=(--disable-sandbox --build-system native
     --cache-path .build/wave2/cache --config-path .build/wave2/config
     --security-path .build/wave2/security)
swift build "${SPM[@]}"
swift test "${SPM[@]}" --filter 'Deflate64|LZ4'
swift test "${SPM[@]}"
swift test "${SPM[@]}" --scratch-path .build/wave2/asan --sanitize address --filter 'Deflate64|LZ4'
swift build "${SPM[@]}" -c release --product kaito
```

| Command | Result |
|---|---|
| `pwd`; read-only `git status --short`, `git rev-parse HEAD`, `git show HEAD:<codec>`; `rg`, `sed`, `cat` of project records/source | Correct root and clean starting worktree; starting HEAD above; no git write commands |
| `which lz4`; `which 7zz`; `lz4 --help`; `swift --version`; `uname -a` | `/opt/homebrew/bin/lz4` v1.10.0; `/opt/homebrew/bin/7zz`; Swift 6.4; arm64 macOS 27.2 |
| `swift build -c release --product kaito` with stdout to the then-missing `.build` directory | Shell redirection failed before build; created local artifact directory |
| `swift build --disable-sandbox -c release --product kaito` with local Clang cache | Compiler/linker succeeded, final dsymutil step failed `Operation not permitted`; executable used only for smoke, replaced for final A/B |
| First native baseline build | Failed because production source changed during compilation; replaced with isolated immutable HEAD source snapshot |
| `swift build SPM` | Passed, 10.01 s |
| `swift test SPM --filter 'Deflate64\|LZ4'` | Passed, 47 tests, 1 skipped, 0 failures; 36.611 s test time |
| `xcrun xctest -XCTest KaitoKitTests.Deflate64DecompressorTests .build/arm64-apple-macosx/debug/KaitoKitPackageTests.xctest` | Passed, 8 tests, 0 failures |
| `swift build SPM -c release --product kaito` | Passed, 67.18 s |
| `swift test SPM --scratch-path .build/wave2/asan --sanitize address --filter 'Deflate64\|LZ4'` | Initial adapter passed in 77.935 s; final density selection passed in 78.131 s; final density-boundary tests passed in 77.922 s. Each run: 47 tests, 1 skipped, 0 failures, no ASan report |
| Native HEAD release build with `--package-path .build/wave2/baseline-package --scratch-path .build/wave2/baseline-build` and absolute SPM cache/config/security paths | Passed, 67.37 s |
| `swift test SPM` (initial adapter, before density selection) | Passed, 1951 tests, 55 skipped, 0 failures; 1255.420 s |
| `swift build SPM` (final adapter) | Passed, 3.60 s |
| `swift test SPM --filter 'Deflate64\|LZ4'` (final adapter / density cases) | Passed, 47 tests, 1 skipped, 0 failures; 36.225 s |
| `swift test SPM --scratch-path .build/wave2/release-tests -c release` (final adapter) | Passed, 1951 tests, 55 skipped, 0 failures; 277.493 s test time, 211.62 s build time |
| Redundant second full debug run | Superseded by the final full release run; stopped through the execution session's Ctrl-C control (exit 130). Direct process signaling was sandbox-denied; session control succeeded |
| Native debug build used to observe the redundant run's SwiftPM lock | Passed after session interruption; no source changes |
| `python3 Tests/Measurement/wave2-codecs/measure.py generate` | Passed; all 9 archives generated. The script logs every black-box command and return code |
| `swift build SPM --scratch-path .build/wave2/candidate-build -c release --product kaito` | Passed, 67.86 s; final production CLI copied to `.build/wave2/kaito-after` |
| `python3 Tests/Measurement/wave2-codecs/measure.py measure` | Passed; all 9 SHA identity gates matched, all 54 bench commands exited 0 |
| Text tar noise recheck: 7 rotated rounds, `kaito-before bench <text.tar.lz4> 5` twice and `kaito-after bench <text.tar.lz4> 5` once per round | Passed, 21 commands exited 0; A/A and A/B results below |
| Local summary script over primary and noise JSONL | Passed; 105 durable records include commands, results, digests, summaries |
| `GIT_OPTIONAL_LOCKS=0 git diff --check` | Passed, no whitespace errors |
| Whitespace/newline scan of all changed and untracked files; JSONL validation | Passed, 12 files; 105 valid records, 102 successful recorded commands, 9 matching SHA gates; CHANGELOG absent from changes |
| `swiftc -O -parse-as-library <KaitoKit LZ4 sources> Tests/Measurement/wave2-codecs/LZ4Probe.swift -o .build/wave2/lz4-probe` | Initial default module-cache write denied; passed with `-module-cache-path .build/wave2/module-cache` |
| `lz4-probe <text/image-legacy.lz4>` | All modes produced identical counts; detailed observations below |
| `xcrun xctest -XCTest KaitoKitTests.NameSafetyRegressionTests <debug test bundle>` | Passed, 10 tests, 0 failures |
| `ps -o pid,etime,pcpu,comm -ax`; `sample <swift-test PID> 1 -file .build/wave2/full-process.sample`; hardware-detail `sysctl` | Sandbox denied process/hardware inspection; no escalation |
| ASan rebuild after adding the density-boundary regression cases | Initial test-only `[Any]` inference error; fixed by declaring the sequence `[UInt8]`, then reran all selected tests |
| Frozen-HEAD copy comparison against transformed `git show HEAD:<Deflate64 source>` | Exact match after type/access renaming |

The baseline package copies KaitoKit's own Sources and Package.swift and restores
both changed original codec files with read-only `git show HEAD:<path>`. Its Tests
link points into the same workspace, but tests are not built for this CLI product.
No checkout, index update, commit, worktree creation, or other git mutation is used.

## Backend selection measurement

The probe initially ran from `.build/wave2/LZ4Probe.swift` and was then promoted
to the tracked measurement directory. It builds without importing an external
implementation:

```sh
swiftc -module-cache-path .build/wave2/module-cache -O -parse-as-library \
  Sources/KaitoKit/Core/KaitoError.swift \
  Sources/KaitoKit/Codecs/LZ4/LZ4BlockDecoder.swift \
  Sources/KaitoKit/Codecs/LZ4/LZ4AppleBlockDecoder.swift \
  Tests/Measurement/wave2-codecs/LZ4Probe.swift -o .build/wave2/lz4-probe
.build/wave2/lz4-probe .build/wave2/corpus/text-legacy.lz4
.build/wave2/lz4-probe .build/wave2/corpus/image-legacy.lz4
```

A release (`swiftc -O`) block probe decoded each legacy corpus 20 times with the
unchanged Swift decoder, token walk alone, Apple alone, and walk + Apple. All
modes counted the same 1,342,177,280 text / 671,088,640 image-like bytes. Before
adaptive selection, text took 0.622 / 0.399 / 0.347 / 0.740 s respectively; the
walk erased Apple's gain. Image-like blocks took 0.125 / 0.033 / 0.065 / 0.097 s.
A pointer-only acceptance walk alone did not materially change that result.
The final 32-sequence probe returned dense text to Swift (0.629 s versus Swift's
0.629 s for 20 passes) and kept image-like blocks accelerated (0.094 versus
0.128 s). These block-probe numbers omit framing/checksums and are selection
evidence, not the final end-to-end A/B. Legacy frames retain Swift throughout;
that avoids the measured text regression and any new per-legacy-block allocation.

Preliminary `kaito bench` smokes (before final selection, while tests were active)
likewise showed text legacy 35.911 -> 43.989 ms and modern 41.884 -> 49.668 ms;
image legacy 9.067 -> 7.582 ms and modern 11.605 -> 10.255 ms. These are explicitly
superseded by the final alternating measurements below. Deflate64 smoke medians
were text 237.393 -> 183.088 ms and small files 221.568 -> 115.674 ms.

## Release measurements

Both binaries use the same Swift 6.4 native release product build. No build or
other test was active during these measurements. The baseline restores starting
HEAD's codecs; the candidate contains the final changes. Text is 64 MiB; synthetic
RGB/image-like data is 32 MiB; small-file ZIP contains 5000 files / 11,645,829
uncompressed bytes. Payload generation uses a fixed seed; archive metadata is
captured by the manifest/digests. These inputs differ from the older 256 MiB corpus.

For each archive the harness first compares exact `kaito sha` stdout and success
status, then runs before→after / after→before / before→after. Each CLI invocation
uses `bench <archive> 3`. Table values are the median of the three process medians
(9 repetitions per side). Total B/A uses median(open + extract); paired B/A is
the median of the three within-round ratios. Open/extract columns are separate
marginal medians, so their sum need not equal the median total. LZ4-compressed tar
staging/decode is charged to **open**, and member reads to extract.

| Archive | Open ms, before → after | Extract ms, before → after | Total B/A | Paired B/A |
|---|---:|---:|---:|---:|
| image-legacy.lz4 | 0.167 → 0.170 | 9.018 → 8.995 | 0.9968 | 0.9968 |
| image.lz4 | 0.170 → 0.166 | 11.592 → 10.389 | 0.8922 | 0.8954 |
| image.tar.lz4 | 12.082 → 10.670 | 0.477 → 0.480 | 0.8878 | 0.8878 |
| small-deflate64.zip | 3.873 → 3.930 | 221.640 → 114.629 | 0.5256 | 0.5235 |
| text-deflate64.zip | 0.308 → 0.297 | 240.802 → 184.970 | 0.7684 | 0.7638 |
| text-legacy.lz4 | 0.208 → 0.191 | 37.612 → 36.410 | 0.9679 | 0.9675 |
| text-zip6.zip | 0.306 → 0.317 | 23.886 → 23.783 | 0.9950 | 0.9948 |
| text.lz4 | 0.208 → 0.221 | 42.202 → 41.740 | 0.9890 | 0.9877 |
| text.tar.lz4 | 65.952 → 52.119 | 3.429 → 3.422 | 0.7999 | 0.9285 |

Deflate64 extraction improved **23.2%** on text and **48.3%** on small files. The
small-file extraction average is 44.33 → 22.93 microseconds per entry (includes
decode and reader work, not an isolated initialization cost). Image-like modern
LZ4 improved about **11%** end to end. Dense text's bounded probe keeps the Swift
path; modern text LZ4 and the unchanged ZIP deflate control show no material gain.
Legacy remains on Swift; its small timing changes are not attributed to Apple.

The primary text tar sample was noisy (candidate open medians 78.312 / 51.267 /
52.119 ms), so its apparent 20% median-total gain is **not** treated as a codec
speedup. A seven-round follow-up rotated baseline A / baseline B / candidate,
with 5 repetitions each. Median totals were **55.298 / 55.879 / 54.619 ms**;
paired A/A = 1.0125 and A/B = 0.9904. The candidate difference is
near the baseline noise floor. All follow-up commands and individual values are
also in the [raw record](2026-10-29-wave2-codecs.jsonl).

The orchestrator performs the final A/B on its separate machine. These local
numbers establish measured behavior on the stated corpus, not a cross-machine
or all-input speed guarantee.


## Independent-review follow-up: validated output allocation (2026-10-29)

The review's tiny-block allocation defect was reproduced before fixing it. A valid
compressed block expanding to five bytes, inside an independent block-checksummed
frame advertising a 4 MiB maximum, retained **4,194,337 bytes** of logical buffer
capacity. This happened with maxEntrySize = 5, 64, and 4 MiB, both after reading
the payload and after EOF. The regression test failed all six capacity assertions
against the intended <= 64-byte bound.

`LZ4AppleBlockDecoder.swift` now reserves and passes `expected + 1`, following the
walk's validated size. A fresh five-byte output requests 38 bytes including the
existing 32-byte slack, rather than pinning the frame maximum. The count-mismatch
fallback precedes the block-maximum guard, so a cap-sized Apple result always
re-decodes with Swift, including when expected equals blockMaximum. Section 6
above gives the updated bound argument. Scratch reuse, routing, and token
validation remain unchanged.

`LZ4BlockBuffer.capacity` has an internal read-only getter, and
`LZ4FrameDecompressor.decodedCapacity` forwards that diagnostic for tests. The new
`testTinyBlockInFourMiBFrameKeepsOutputCapacitySmall` uses an actual compressed
4 MiB-max frame, verifies all five bytes and EOF, and checks capacity <= 64 for
entry limits 5 / 64 / 4 MiB. Its frame helper now accepts a block descriptor with
the previous 64 KiB default preserved. These diagnostics do not add public API.
The other touched file is this verification record (summary, bound 6, follow-up).

Using the same CLANG_MODULE_CACHE_PATH, TMPDIR, and SPM arguments documented above:

| Command | Result |
|---|---|
| `swift test "${SPM[@]}" --filter LZ4DifferentialTests.testTinyBlockInFourMiBFrameKeepsOutputCapacitySmall` before the fix | Exit 1 as expected: 1 test, 6 capacity assertions failed at 4,194,337 bytes; payload/EOF checks passed |
| `swift test "${SPM[@]}" --filter 'Deflate64\|LZ4'` | Exit 0; 48 tests, 1 skipped, 0 failures; 36.435 s |
| `swift test "${SPM[@]}" --scratch-path .build/wave2/asan --sanitize address --filter 'Deflate64\|LZ4'` | Exit 0; 48 tests, 1 skipped, 0 failures; 78.670 s; no ASan report |
| `swift build "${SPM[@]}" --scratch-path .build/wave2/candidate-build -c release --product kaito` | Exit 0; 65.52 s |
| `cp .build/wave2/candidate-build/arm64-apple-macosx/release/kaito .build/wave2/kaito-capacity-fixed` | Exit 0; preserves both original comparison CLIs |
| `python3 .build/wave2/lz4-capacity-bench.py` | Exit 0; all 6 SHA commands and 18 bench commands succeeded; output identity matched across all three binaries for both archives |
| `GIT_OPTIONAL_LOCKS=0 git diff --check` | Exit 0; no whitespace errors |

The quick release recheck uses the existing 32 MiB image-like corpus and unchanged
archives. Binaries are `.build/wave2/kaito-before` (Swift HEAD baseline),
`.build/wave2/kaito-after` (pre-fix Apple), and `.build/wave2/kaito-capacity-fixed`.
For each of `image.lz4` and `image.tar.lz4`, the helper first compares all three
`sha` outputs, then executes `bench <archive> 5` in three alternating rounds:
Swift / pre-fix / fixed, fixed / pre-fix / Swift, Swift / pre-fix / fixed. No build
or test was active during timing. Results are medians of three process medians;
total is open + extract (tar staging/decode is charged to open), and paired ratios
are medians of the three within-round ratios. Exact commands, binary digests, and
all individual results are saved in `.build/wave2/lz4-capacity-bench.jsonl`.

| Archive | Swift baseline total ms | Pre-fix Apple total ms | Fixed Apple total ms | Paired fixed / Swift | Paired fixed / pre-fix |
|---|---:|---:|---:|---:|---:|
| image.lz4 | 11.758 | 10.398 | 10.518 | 0.8917 | 1.0115 |
| image.tar.lz4 | 12.436 | 11.012 | 11.027 | 0.8804 | 1.0014 |

The fixed adapter retains roughly **11–12%** of end-to-end gain against Swift on
both inputs. Its paired times are within 1.2% of the pre-fix adapter in this quick
check. The optional full suite was not repeated for this allocation-only fix.

Clean-room provenance was followed for the follow-up: only KaitoKit's own code,
records, existing project-owned fixtures, and the supplied review were used. No
prohibited implementation source was opened. No .git mutation, bd, or CHANGELOG
edit was performed.
