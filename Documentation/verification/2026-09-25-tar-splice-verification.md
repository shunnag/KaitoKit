# S14 / P3-K stage B: verified compressed tar splices

Run dates: 2026-09-25–26 (JST). macOS 27.2 (26B5091g), Apple Swift 6.4, arm64.

Base: `feature/2026-09-24-review`, `73c1b9f` (committed stage A and compressed golden).
Scope: K5 and AC13–17. Only KaitoKit is edited; no commit, tag or release is created.
Paths below use `<repo>`, `<tmp>` and `<corpus>`. The frozen stage A golden inputs, compressed
expected values, read-amount tests and descriptor tests are unchanged.

## Implementation and acceptance coverage

`ArchiveReader.openSplicedCompressedTar(output:sourceURL:base:splice:options:)` returns a
`sending ArchiveReader`. All new public declarations belong to `TarEditLayout`; the public
ReaderOptions initializer is unchanged. `CompressedTarSplice.Segment` uses `reused(output:base:)`
and `encoded(output:)`. There is no `makeReader` or `baseChanged` API.

The verifier checks consumed-byte CRCs against the retained snapshot without reading the base
archive or consulting its current identity. gzip additionally verifies the image CRC algebra,
32 KiB dictionary, raw block boundaries, trailer CRC and modulo-32-bit ISIZE. The image self-check
validates every mapped interval in one pass, including interior points in a wholly reused span.
A final reused gzip segment must include the base's DEFLATE final block. XZ validates the
complete envelope and Index CRC, checks reused block sizes, and uses the existing Apple decoder
for encoded blocks. XZ flags must match the base only when a reused segment exists. Bzip2
encoded segments use the existing serial concatenated-stream decoder.

The normal detector, compressed-tar hint, SingleFileReader envelope metadata checks, TarReader,
AppleDoubleReader and fresh aggregate output budget are shared with full open. The result always
has a snapshot, even with recording off. Output identity changes fail verification.

All encoded bytes share one staging. Image fragments retain flat leaves, with full Data allocations
counted once against the memory budget. More than 1,024 fragments or eight leaves triggers one
sequential compaction; a lower memory limit also compacts an oversized retained Data leaf.

- AC13: append, middle/large deletion, both header-length rename cases, prefix insertion, whole
  encoding, adjacent reused bzip2/XZ deletion, three chained generations, both staging thresholds,
  and the three frozen EOF-straddle archives. Entries, encoding, format, contents, layout/header
  groups and maps including compressed CRCs are compared with full open.
- AC14: malformed segment coverage/boundaries, gzip dictionary/trailer/stored-block failures,
  XZ flags/Index/CRC failures, missing streams/blocks, corrupted base maps, same-inode base rewrite
  with restored mtime, output identity change, wrong hint, recovery and limits. Failure/cancellation
  paths check descriptor cleanup. No base archive reads are asserted. Empty streams, repeated gzip
  points, a missing gzip final block with a valid tar prefix and recomputed trailer, outer metadata
  limits and concurrent splices have additional regressions.
- AC14b: 7,000 fixed-seed mutations, 200 for each of 35 edit/chain/EOF outputs. Flip, overwrite,
  truncate, boundary offsets ±1/±512 and segment-kind changes test that K5 is never looser than
  full open; accepted outputs also compare all public values and maps.
- AC15: separate low fragment/leaf limits force compaction; retained Data budgets are checked,
  including a new limit below the base's original threshold.
- AC16: the prototype manifest reader compares all 63 first-generation and 12 chained outputs,
  including each entry's SHA-256. Its timings are five-sample medians with load 1/5/15 before and
  after each item. The optional large probe generates each codec's GK framing incrementally for
  a 4 GiB + 1 MiB tar image, appends at EOF, and compares maps, ISIZE and streamed contents.
  Its comparison needs two decoded images concurrently and skips below 12 GiB of temporary space.
- AC17: CHANGELOG, README and design §11 describe the contract, retained leaves, CRC collision
  limitation, metadata/identity limits, inherited global PAX state and SPI compatibility policy.

## Reproduction

The orchestrator's named manifest-generation helper was absent. The checked-in replacement
[make-tar-splice-manifest.py](../../Scripts/fixtures/make-tar-splice-manifest.py) reads the existing
prototype `results.jsonl`, `map/*.chunks.json`, output bytes and `p3lib.py` helpers. It reconstructs
the `chain.py` s1/s2 rules, asserts copied byte ranges, and does not regenerate or modify the corpus.

```sh
python3 Scripts/fixtures/make-tar-splice-manifest.py <corpus>/p3val > <tmp>/splice-manifest.json
KAITOKIT_TAR_SPLICE_PROBE=<tmp>/splice-manifest.json swift test -c release -Xswiftc -enable-testing --filter TarEditScaleProbeTests
KAITOKIT_TAR_SPLICE_PROBE_LARGE=1 swift test -c release -Xswiftc -enable-testing --filter TarEditScaleProbeTests
# Final rerun uses both opt-ins in one invocation:
KAITOKIT_TAR_SPLICE_PROBE=<tmp>/splice-manifest.json KAITOKIT_TAR_SPLICE_PROBE_LARGE=1 swift test -c release -Xswiftc -enable-testing --filter TarEditScaleProbeTests
```

This sandbox uses the stage A SwiftPM wrapper below for each build/test command. It preserves
debug optimization and routes caches to writable temporary storage:

```sh
env CLANG_MODULE_CACHE_PATH=<tmp>/module-cache SWIFTPM_MODULECACHE_OVERRIDE=<tmp>/module-cache \
  swift <build-or-test> --disable-sandbox --cache-path <tmp>/cache --config-path <tmp>/config \
  --security-path <tmp>/security --build-system native --jobs 4 <remaining-arguments>
```

## Executed results

The following commands use the wrapper above. All functional checks below completed successfully; the quiet-machine timing gate remains unqualified as described below.

| Command/check | Result |
| --- | --- |
| `swift build` | Passed: 10.60 s initially, then 0.25 s, 0.23 s and final incremental build 2.78 s |
| `swift test` with the focused filter below | Two 13-test runs before the final-block regression: 23.576 s and 25.136 s, 0 failures; each ran 7,000 mutations, 857 accepted and compared |
| `swift test` | Final run: 1,530 tests, 49 skipped, 0 failures; 573.538 s (47 existing opt-in skips plus two scale probes) |
| Local-time golden within full suite | 109 inputs, 2,868 combinations, recording off/on; 40.413 s |
| Stage A differential fuzz within full suite | 2,400 mutations; 25.122 s, plus recorded gzip comparison (0.039 s) |
| K5 differential fuzz within full suite | 7,000 mutations, 857 accepted and compared; 23.189 s |
| `swift build -c release` | Passed, 62.06 s initially and 59.13 s finally (production build without testability flags) |
| Prototype release probe | Final run: 75/75 output comparisons; five samples per operation, 881.251 s, no skips |
| Separate UTC golden (`swift test --skip-build --filter TarPublicValueGoldenTests`) | 109 inputs, 2,868 combinations, off/on; 42.901 s, no failures |
| Large release probe | Final run: all three codecs passed at 4 GiB + 1 MiB; 186.717 s, no skips |
| AddressSanitizer | Final run: 20 tests, 0 failures/findings; 87.544 s; includes all 9,400 tar mutations |
| ThreadSanitizer | Final run: 20 tests, 0 failures/findings; 14.563 s; includes concurrent splices and shared snapshots |
| arm64 framework build | Passed; final implementation build 59.36 s, library evolution enabled |
| Public interface scan | All ten forbidden SPI identifiers absent from four interfaces |
| External consumer, `swift build -c release` | Passed, 73.23 s; final-code diagnostic builds 57.12 s and 1.75 s also passed; runtime printed `TarEditLayout SPI 1 9` |
| External consumer without SPI import | Expected failure: `cannot find 'CompressedTarSplice' in scope` |

```sh
swift build
swift build -c release
swift test --filter CompressedTarSpliceTests
swift test --filter 'CompressedTarSpliceTests|TarSpliceDifferentialFuzzTests'
swift test --filter 'CompressedTarSpliceTests|TarSpliceSPIImportTests|TarSpliceDifferentialFuzzTests'
swift test
TZ=UTC swift test --skip-build --filter TarPublicValueGoldenTests
swift test --sanitize=address --scratch-path <tmp>/asan --filter 'TarEditDifferentialFuzzTests|ParallelBzip2DecompressorTests|CompressedTarSpliceTests|TarSpliceDifferentialFuzzTests'
swift test --sanitize=thread --scratch-path <tmp>/tsan --filter 'ParallelBzip2DecompressorTests|TarEditingSnapshotTests|CompressedTarSpliceTests'
# Before fixing the final-block guard (expected regression failure):
swift test --sanitize=thread --scratch-path <tmp>/tsan --filter CompressedTarSpliceTests.testReusedGzipMustContainFinalBlock
# In the external consumer package:
swift build -c release
# Positive consumer execution: TarEditLayout SPI 1 9
# Rebuild with a non-SPI source referencing CompressedTarSplice: expected compile failure.
KAITOKIT_ARCHS=arm64 bash <tmp>/build-framework.sh
```

The framework used the same temporary adaptation as stage A: unchanged assembly logic with
writable cache/framework/scratch paths, `--disable-sandbox --build-system native --jobs 2
-debug-info-format none`. The repository's build script was not edited. The ordinary consumer uses
`public import KaitoKit` in one file and `@_spi(TarEditLayout) internal import KaitoKit` in another.
Its negative file uses `internal import KaitoKit` without the SPI annotation.

The final combined Release probe build took 153.43 s; both tests passed without skips in
1,067.968 s. Earlier separate probe runs passed 75 outputs in 917.012 s and the three large cases
in 193.134 s; the other opt-in test was skipped in each separate invocation. The TSVs below
contain the final rerun. The first framework build passed in 72.64 s; the final implementation
build is listed above.
Two earlier full suites passed 1,529 tests with 49 expected skips in 593.771 s and 584.585 s.
Earlier development runs also executed the seven-test splice suite (1.755 s) and the nine-test
splice/fuzz selection (24.763 s), both without failures. Initial test compilation exposed missing
`try`, integer-type and non-Sendable Task-result issues; those attempts did not run tests.
The first prototype Release build was restarted because a test file changed during compilation.
The first negative consumer build additionally diagnosed an ambiguous import access level;
the explicit non-SPI `internal import` rerun failed solely on the intended unavailable type.
The first ASan/TSan runs passed 19 tests in 82.144/13.291 s. After the per-interval gzip
self-check, they passed 19 tests in 85.761/14.248 s. The final runs in the table add the
missing-final-block regression.
The missing-final-block regression first failed as intended before its fix (one selected test).
That failing XCTest run under TSan also reported a DebugSymbolsDT/Spotlight symbolizer thread leak
and exited with signal 6; the final 20-test TSan rerun passed without warnings or findings.
The native SwiftPM backend emitted its existing deprecation warning. No sibling suites were run
in S14, and neither sibling working tree was edited.

The compressed golden directory remains 358,194 bytes; no input or expected-value bytes changed.
`git diff --check` passed. The existing read-amount, descriptor and reopen test files are unchanged.

## Prototype timings and qualification

[Complete TSV](2026-09-25-tar-splice-probe.tsv): all 675 metric values for 75 outputs from the final
implementation. One metric line interrupted by XCTest summary output was rejoined without changing
its value. Each time is the median of five Release opens. Load averages were sampled before
and after each item; one-minute load ranged from 2.035 to 6.143. These are diagnostic measurements,
not a quiet-machine acceptance claim. The thresholds remain 0.60 / 0.25 / 0.35 for tgz / tbz / txz.
The measured mixed tbz `delete-huge` ratio is 0.432 (348.170 / 805.209 ms), above its 0.25
threshold. Its one-minute load was 3.390 before and 4.072 after; quiet remeasurement remains required.

Additional `uptime` snapshots were 4.56 / 5.58 / 6.13 at 00:34 JST (Release build underway),
and 5.16 / 4.01 / 4.39 at 00:55 JST (after the probes and ordinary production rebuild).
The per-item load 1/5/15 samples in the TSV are the loads associated with the actual measurements.

A temporary external SPI consumer isolated the mixed bzip2 `delete-huge` costs after the probes.
It opened the same base/output and manifest, timed 30 K5 opens, then timed five plain-tar opens
of the returned composite image and five serial decodes of just the encoded segment. The latter
uses the normal `.bz2` reader and streams into a 1 MiB buffer. There is one encoded segment:
4,470,322 compressed bytes, producing 6,064,032 bytes. The final diagnostic medians were:

| Diagnostic operation | Median ms |
| --- | ---: |
| K5, 30 opens | 336.980 |
| Plain-tar open of the composite image, five opens | 190.364 |
| Isolated serial encoded-stream decode, five decodes | 143.828 |

Final diagnostic load 1/5/15: 2.888 / 3.377 / 4.021. These are independent measurements, not
instrumented phases to add exactly. They suggest the required tar parsing and serial decoding
account for most of this case's cost. No threshold, verification check or prescribed decoder was
changed. The earlier diagnostic measured K5 337.393 ms and isolated decode 145.555 ms at
load 2.676 / 3.430 / 4.098.

A five-second, one-millisecond-interval stack sample was attempted on that consumer after the
base snapshot was ready. `sample` exited 255: it could not examine the process and suggested
sudo. This sandbox does not allow escalation, so no stack sample is available. The shell also
reported that its automatic background `nice(5)` adjustment was denied; the consumer completed
successfully. The diagnostic consumer and logs remain in the temporary run directory.

```sh
# In the temporary external SPI consumer package; the ordinary API/SPI check also executes:
swift build -c release
KAITOKIT_PROFILE_MANIFEST=<tmp>/splice-manifest.json KAITOKIT_PROFILE_READY=<tmp>/profile-ready <tmp>/spi-consumer/.build/release/Consumer
# In the first diagnostic invocation the consumer ran in the background; after its ready marker:
sample <consumer-pid> 5 1 -file <tmp>/bzip2-delete-huge.sample.txt
# The second invocation adds isolated composite-tar parsing, and runs without the sampler:
swift build -c release
KAITOKIT_PROFILE_MANIFEST=<tmp>/splice-manifest.json <tmp>/spi-consumer/.build/release/Consumer
```

| Mixed edit | tgz full / K5 ms (ratio) | tbz full / K5 ms (ratio) | txz full / K5 ms (ratio) |
| --- | ---: | ---: | ---: |
| append | 828.037 / 246.562 (0.298) | 1570.552 / 334.449 (0.213) | 3342.930 / 282.908 (0.085) |
| delete-mid | 831.113 / 248.055 (0.298) | 1555.441 / 279.926 (0.180) | 3288.873 / 337.181 (0.103) |
| delete-big | 823.445 / 245.446 (0.298) | 1461.916 / 223.095 (0.153) | 3259.869 / 318.646 (0.098) |
| delete-huge | 429.325 / 216.339 (0.504) | 805.209 / 348.170 (0.432) | 1343.594 / 272.582 (0.203) |
| rename-same | 827.725 / 245.210 (0.296) | 1545.615 / 278.715 (0.180) | 3266.243 / 334.945 (0.103) |
| rename-diff | 828.172 / 247.104 (0.298) | 1534.830 / 280.010 (0.182) | 3263.941 / 335.606 (0.103) |

## Large-image probe

The generated tar image is exactly 4,296,015,872 bytes; the append adds a 1,024-byte member group.
Generation uses the test encoder's GK framing and bounded chunks, without allocating a 4 GiB Data.
The large body is zero-filled, so these timings describe highly compressible data.
Full and K5 opens compared each entry's streamed SHA-256 and complete layout/maps. gzip ISIZE
is checked modulo 2^32. All three passed; no disk-space skip was needed.

[Large probe TSV](2026-09-25-tar-splice-large-probe.tsv), five-sample medians:

| Codec | Base ms | Full output ms | K5 ms | Load 1 |
| --- | ---: | ---: | ---: | ---: |
| tgz | 1355.806 | 1287.227 | 314.785 | 3.869 |
| tbz | 658.166 | 652.802 | 2.425 | 3.083 |
| txz | 6890.845 | 6819.600 | 297.211 | 2.505 |

## Orchestrator verification (2026-09-26 JST)

Isolated layout `$SCR/v3`: this working tree (rsync, no `.build` / `.git`) next to GyoshukuKit `efdb651` (P2-G, git archive).

| Run | Result |
|---|---|
| KaitoKit `swift test` (debug, all) | 1,496 XCTest + 34 swift-testing tests, 49 skipped, 0 failures (550.9 s) |
| GyoshukuKit `efdb651` `swift test` against this KaitoKit | 399 tests, 10 skipped (opt-in), 0 failures (459.3 s) |
| Release `TarEditScaleProbeTests` with the regenerated manifest (75 items) | all 75 splices accepted and equal to the full open; timings below |

Re-measurement of the acceptance rows (mixed corpus, K5 / full open of the same output, five-sample medians; one-minute load
2.2–4.2 while it ran, `mediaanalysisd` idle):

| Mixed edit | tgz ratio | tbz ratio | txz ratio |
| --- | ---: | ---: | ---: |
| append | 0.299 | 0.205 | 0.085 |
| delete-mid | 0.296 | 0.176 | 0.102 |
| delete-big | 0.294 | 0.153 | 0.097 |
| delete-huge | 0.499 | **0.432** (343.9 / 795.2 ms) | 0.203 |
| rename-same | 0.297 | 0.180 | 0.101 |
| rename-diff | 0.295 | 0.181 | 0.102 |

17 of 18 rows meet the limits (tgz 0.60, tbz 0.25, txz 0.35). tbz `delete-huge` reproduces at 0.432 and is **not met**; the
threshold is unchanged. The cause is structural rather than load: removing the 256 MiB member halves the output, so the
denominator (parallel bzip2 full open) drops to 795 ms, while K5 still has to parse the whole composite tar (≈190 ms measured by
Codex's isolated consumer, i.e. 0.24 of the full open by itself) and decode the one re-encoded 4.5 MB bzip2 segment serially
(≈144 ms). Parsing alone nearly reaches the limit, so no load level makes this row pass. The app-level acceptance for P3
(ORDER-P2-P3 §6.1: tar.bz2 `verification_open` ≤ 10 % of the serial-decoder B-P3 baseline) is measured separately in P3-A.
The other corpora (headers, small, single-stream third-party inputs) are not acceptance rows; their ratios are dominated by
parsing or by the whole-stream decode of converted single-stream inputs, as expected.
