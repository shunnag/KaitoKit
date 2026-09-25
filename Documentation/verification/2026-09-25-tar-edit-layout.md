# S12 / P3-K stage A: tar edit layout

Base: `feature/2026-09-24-review`, `24311ac` (P1-K + P1b SPI).
Scope: Step 0 and K1–K4. K5 and the splice/4 GiB probes belong to stage B.
Only KaitoKit is edited; no commit, tag or release is created. GyoshukuKit checks use a committed export,
not its concurrently edited working tree. Paths below use `<repo>`, `<tmp>` and `<corpus>`.

The supplied fourteen files (eleven archives plus README, expected maps and macOS version) were all
readable and copied byte-for-byte. Sources were unchanged when the golden was generated.
The 109-input corpus contains eight existing, eleven supplied and ninety synthetic archives.
All 2,868 opening/option combinations compare the same expected values with recording off and on.
An independent export of `24311ac`, with the no-op option helper, regenerated identical JSON (`cmp`).
The [original test/support/input/map/value SHA-256 ledger](2026-09-25-tar-edit-layout-frozen-sha256.json)
recorded 128 files unchanged at completion of stage A. It remains a historical Step-0 record;
correction 1 below changes storage and loading while retaining all decoded input and expected-value bytes.

## Step 0 and stage gates

| Check | Executed | Skipped | Failures | Seconds |
| --- | ---: | ---: | ---: | ---: |
| Baseline KaitoKitTests | 1,458 | 47 | 0 | — |
| Baseline KaitoKitCompatTests | 34 | 0 | 0 | — |
| Baseline full package | 1,492 | 47 | 0 | 474.734 |
| K1 broad tar gate | 116 | 0 | 0 | 76.484 |
| K2 broad tar gate | 122 | 0 | 0 | 85.954 |
| K3 broad tar gate | 126 | 0 | 0 | 82.838 |
| K4 broad tar gate | 131 | 0 | 0 | 88.811 |
| Final KaitoKitTests | 1,480 | 47 | 0 | — |
| Final KaitoKitCompatTests | 34 | 0 | 0 | — |
| Final full package | 1,514 | 47 | 0 | 561.924 |

Each gate included local-time golden, differential fuzz and the existing tar, single-file, compressed
cpio, AppleDouble, XZ resource-limit and reopen tests. A separate UTC golden passed after each stage:
50.041 / 45.042 / 42.758 / 43.880 seconds. The unchanged read-amount and descriptor assertions are in
`SingleFileArchiveReaderIntegrationTests`, `ReopenSharingTests` and the existing tar integration tests.

The eight fuzz seeds (three synthesized GK streams and five frozen third-party streams) each receive
300 deterministic flip / overwrite / truncate / insert mutations; bzip2 also receives false candidate
insertion. K1–K4 completed 2,400 mutations with zero differences in 8.484 / 21.416 / 20.338 / 25.688 s.
K2 adds direct recorded/unrecorded gzip output/error-prefix comparisons and independent chunk decoding.
K4 compares the new bzip2 staging with an explicitly serial reference, including open errors and all contents.
AC9's prose says six third-party outputs; the supplied fixture set and the spec's generation commands
enumerate five. All five supplied third-party outputs are covered, giving eight seeds and 2,400 mutations.

## Commands and environment

Logs and temporary exports/builds are under `<tmp>/kaitokit-s12`.
The initial literal `swift test` failed before building: the default Clang module cache is outside the
writable sandbox. Subsequent SwiftPM commands use this wrapper; debug optimization is unchanged:

```sh
#!/bin/zsh
exec env CLANG_MODULE_CACHE_PATH=<tmp>/kaitokit-s12/module-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=<tmp>/kaitokit-s12/module-cache \
  swift "$1" --disable-sandbox --cache-path <tmp>/kaitokit-s12/cache \
  --config-path <tmp>/kaitokit-s12/config --security-path <tmp>/kaitokit-s12/security \
  --build-system native --jobs 4 "${@:2}"
```

`--disable-sandbox` is SwiftPM's nested sandbox option; the outer workspace sandbox stays in effect.
The native backend emits its existing deprecation warning. K2's initial compile attempts found that
the SDK imports zlib's CRC-combine length as `Int`; the internal call was corrected before the K2 gate.
The first input-generation build encountered a test closure being edited during compilation; the final
input and value generation ran successfully before any Source edits. No frozen expectations were changed.

```sh
swift test
git diff --quiet -- Sources
KAITOKIT_WRITE_TAR_GOLDEN_INPUTS=1 swift test --filter TarPublicValueGoldenTests
TZ=UTC KAITOKIT_WRITE_TAR_GOLDEN=1 swift test --filter TarPublicValueGoldenTests
TZ=UTC swift test --filter TarPublicValueGoldenTests
swift test --filter 'TarPublicValueGoldenTests|TarEditDifferentialFuzzTests'
# After each K1–K4:
swift build
swift test --filter 'TarPublicValueGoldenTests|GyoshukuFixtureMapTests|ThirdPartyFixtureMapTests|TarLayoutTests|TarEditLayoutSPIImportTests|CompressedTarChunkMapTests|TarEditingSnapshotTests|ParallelBzip2DecompressorTests|TarEditDifferentialFuzzTests|ReopenSharingTests|CompressedTarAliasTests|CompressedCpioAliasTests|SingleFileArchiveReaderIntegrationTests|SingleFileFormatTests|TarIntegrationTests|TarHardeningTests|TarSparseTests|XZResourceLimitTests|AppleDoubleSidecarTests'
TZ=UTC swift test --filter TarPublicValueGoldenTests
```

## Final validation

Swift 6.4, macOS 27.2 (26B5091g), arm64; deployment target macOS 26.0.
The final full suite adds 22 tests to the baseline, with the same 47 skips and zero failures.
Its golden covered all 2,868 combinations with recording off and on; its 2,400-mutation fuzz took
27.098 seconds with zero differences. Existing tests, including read-amount and descriptor assertions,
were not edited. `git diff --check` passed.

| Check | Result |
| --- | --- |
| `swift build`, after K1 / K2 / K3 / K4 | Passed; 5.43 / 0.27 / 4.69 / 2.90 s |
| Final `swift build`, including the CLI environment-variable lookup | Passed; 1.26 s |
| TSan: parallel bzip2 and snapshot tests | 8 tests, zero failures/reports; 1.194 s |
| ASan: differential fuzz and parallel bzip2 | 7 tests, zero failures/reports; 32.924 s; fuzz 32.265 s |
| Release package build | Passed; 61.94 s; final CLI incremental rebuild 2.49 s |
| arm64 framework build | Passed; 62.51 s, with the cache/output adaptation below |
| Public framework `.swiftinterface` scan | None of the ten prohibited SPI names appeared |
| Release consumer, separate `public import` and SPI `internal import` files | Passed |
| Same SPI access through an ordinary import | Failed as expected: SPI protection diagnostics |
| Independent baseline golden regeneration | Byte-identical JSON (`cmp`); all 128 frozen file hashes unchanged |
| Unchanged GyoshukuKit, committed export `e907e1daea09bb20ca8096b72a74e4b6edf70fbe` | 322 tests, 2 skips, zero failures; 517.143 s |

The literal framework command also encountered the unwritable default module cache. A temporary copy
of the unchanged build script redirected its framework and scratch output under `<tmp>/kaitokit-s12`,
used the same cache paths as the wrapper, and added `--disable-sandbox --build-system native --jobs 2
-debug-info-format none`. This still built and assembled the arm64 framework with library evolution;
the repository script was not edited. Release CLI builds also used `-debug-info-format none`.
The external consumer's first harness attempt made a function public while its parameter came from
an internal import; correcting that harness function to internal passed. Its ordinary-import rejection
was then checked separately.

```sh
swift test
swift test --scratch-path <tmp>/kaitokit-s12/tsan --sanitize=thread \
  --filter 'ParallelBzip2DecompressorTests|TarEditingSnapshotTests'
swift test --scratch-path <tmp>/kaitokit-s12/asan --sanitize=address \
  --filter 'TarEditDifferentialFuzzTests|ParallelBzip2DecompressorTests'
swift build -c release -debug-info-format none --scratch-path <tmp>/kaitokit-s12/release
KAITOKIT_ARCHS=arm64 <tmp>/kaitokit-s12/build-framework.sh
swift build -c release --package-path <tmp>/kaitokit-s12/spi-consumer
swift test --package-path <tmp>/kaitokit-s12/siblings/GyoshukuKit
```

The only added cancellation check is in the parallel bzip2 wait loop. Existing cancellation checks
were not moved. No K5 implementation or splice/4 GiB scale probe ran in stage A.

## Stage-A acceptance

| AC | Evidence / status |
| --- | --- |
| 1, full package | Passed: 1,492 → 1,514 tests, 47 skips unchanged, zero failures |
| 2, public values | Passed: frozen baseline, both options, local time and UTC after every stage; independent baseline JSON identical |
| 3, GK framing | Passed: six real GK fixtures, including all three EOF-straddle files, byte-identical on the recorded OS |
| 4, tar layout | Passed: independent walk, member/global coverage, extension groups, sparse/hardlink boundaries, reasons and trailing zero checks |
| 5, SPI import | Passed: no-`@testable` tests, custom identity provider, external release consumer and negative ordinary-import compile |
| 6, compressed maps | Passed: frozen prototype maps, digest checks, independently decoded intervals, third-party checks, limits and gzip equivalence |
| 7, snapshot | Passed: source/image/reopen sharing, identity changes, split/cpio exclusions, concurrent reads and TSan |
| 8, parallel bzip2 | Passed: 1/2/8 workers, errors/fake boundaries, serial fallback, memory counters, cancellation/deinit and TSan |
| 9, differential fuzz | Passed: 2,400 fixed mutations, explicit serial bzip2 reference, under 120 s, ASan clean |
| 10, build/interfaces | Passed with the documented sandbox cache adaptations |
| 11, unchanged GK | Passed: 322 tests, 2 skips, zero failures in an isolated committed export using the adjacent KaitoKit export |
| 12, measurements | Not qualified: load >4; all 42 observations and the RSS substitution are recorded below |

## Stage-A Release probes

All 42 `kaito bench <archive> 5` commands exited successfully. The baseline binary was built from
an isolated `git archive 24311ac` export; the candidate was built from the stage-A Sources with the same
Release flags. The twelve `text` / `small` / `mixed` archives came from `<corpus>/p3val/arc`; the two
500,000-entry archives came from `<corpus>/tarproto/img`. `KAITOKIT_BENCH_TAR_EDIT_LAYOUT` was `0`
for baseline/off and `1` for on. Each command ran sequentially after the full test suites finished.

**AC12 is not qualified.** Observed one-minute loads were 5.74–13.38, above the required <4.
The table reports observations, not a performance acceptance pass. The complete
[TSV with before/after 1/5/15-minute load and `uptime`](2026-09-25-tar-edit-layout-probes.tsv)
also includes extraction medians, timestamps and exit codes. Thresholds have not been relaxed.

| Archive | Baseline open ms | Off ms | On ms | Off/base | On/base | Observed 1-minute load |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| text.tgz | 381.716 | 385.895 | 431.707 | 1.0109 | 1.1310 | 12.23–13.38 |
| text.tbz | 6058.528 | 844.841 | 860.854 | 0.1394 | 0.1421 | 9.07–12.23 |
| text.txz | 2044.987 | 2034.509 | 2027.623 | 0.9949 | 0.9915 | 6.68–9.36 |
| text.tar | 0.132 | 0.130 | 0.136 | 0.9848 | 1.0303 | 6.68–6.68 |
| small.tgz | 388.423 | 388.871 | 391.730 | 1.0012 | 1.0085 | 6.30–6.68 |
| small.tbz | 2941.132 | 608.792 | 615.606 | 0.2070 | 0.2093 | 6.30–6.62 |
| small.txz | 1204.714 | 1213.725 | 1220.970 | 1.0075 | 1.0135 | 5.80–6.41 |
| small.tar | 177.067 | 176.767 | 174.210 | 0.9983 | 0.9839 | 6.02–6.02 |
| mixed.tgz | 782.758 | 923.689 | 850.823 | 1.1800 | 1.0870 | 6.02–7.93 |
| mixed.tbz | 10505.424 | 1624.245 | 1553.930 | 0.1546 | 0.1479 | 7.93–8.71 |
| mixed.txz | 3406.758 | 3368.926 | 3401.501 | 0.9889 | 0.9985 | 6.56–8.06 |
| mixed.tar | 196.359 | 191.164 | 195.913 | 0.9735 | 0.9977 | 6.35–6.56 |
| k500.tar | 1810.708 | 1804.345 | 1818.985 | 0.9965 | 1.0046 | 5.76–6.35 |
| k500.tgz | 1939.164 | 1917.763 | 1923.194 | 0.9890 | 0.9918 | 5.74–5.86 |

The observed values exceeding the numeric thresholds are mixed gzip off (1.1800 > 1.02),
mixed gzip on (1.0870 > 1.08), text gzip on (1.1310 > 1.13), and text tar on
(1.0303 > 1.03, from medians rounded to 0.001 ms). All bzip2 observations are below their
0.40 / 0.60 ratios. These comparisons need a quiet-host rerun before AC12 can pass.

For the RSS command, `/usr/bin/time -l kaito list k500.tar` completed the child command but failed
to print resource statistics: `time: sysctl kern.clockrate: Operation not permitted`.
The same two `kaito list` commands were then run directly with stdout discarded; `os.wait4`
collected each child’s Darwin `ru_maxrss`, avoiding the blocked clock-rate query. Both children exited 0.
The [RSS record](2026-09-25-tar-edit-layout-rss.json) includes both failed `time -l` reports and the
fallback measurements. This is a documented measurement substitution, not a successful literal `time -l` run.

| Mode | Maximum RSS bytes | MiB | `uptime` before → after (1/5/15 min) |
| --- | ---: | ---: | --- |
| base | 479,854,592 | 457.625 | 5.43 / 7.28 / 8.25 → 5.40 / 7.24 / 8.23 |
| on | 494,944,256 | 472.016 | 5.40 / 7.24 / 8.23 → 5.40 / 7.24 / 8.23 |

The observed RSS increase is 15,089,664 bytes (14.391 MiB), below +24 MB.
The host load condition still prevents qualifying AC12. No K5 timing or splice/4 GiB probe was run.

```sh
# Repeat for text/small/mixed × tgz/tbz/txz/tar, plus k500.tar and k500.tgz:
KAITOKIT_BENCH_TAR_EDIT_LAYOUT=0 <baseline>/kaito bench <archive> 5
KAITOKIT_BENCH_TAR_EDIT_LAYOUT=0 <candidate>/kaito bench <archive> 5
KAITOKIT_BENCH_TAR_EDIT_LAYOUT=1 <candidate>/kaito bench <archive> 5
KAITOKIT_BENCH_TAR_EDIT_LAYOUT=0 /usr/bin/time -l <baseline>/kaito list <corpus>/tarproto/img/k500.tar
KAITOKIT_BENCH_TAR_EDIT_LAYOUT=1 /usr/bin/time -l <candidate>/kaito list <corpus>/tarproto/img/k500.tar
# RSS fallback: posix_spawn the same list commands, redirect stdout, then os.wait4(pid, 0).
```

## S12 correction 1: compact golden storage

Only the golden storage/loader and its documentation changed. Production Sources, existing tests,
the framing encoder, `TarGoldenInputSupport`, supplied fixtures, AC12 thresholds and the timing
records above are unchanged. The orchestrator will repeat AC12 on a quiet machine; no performance
probe was rerun for this correction.

The 109 logical inputs (8 existing, 11 supplied, 90 synthetic), 2,868 combinations, both recording
states, four option modes, all opening methods, reopen assertions and UTC dates remain covered.
The original `modes`, `methods`, `publicRows`, read/stream outcomes, `summary` and off/on comparison
loop are byte-identical. All 109 manifest SHA-256 values are unchanged, and the 107 remaining stored
inputs are byte-identical.

Foundation LZFSE compresses the exact frozen JSON; the test uses Foundation to decompress it and
asserts its committed SHA-256 before JSON parsing. No expectation was regenerated from the changed
parser. The original JSON, the new readable dump and the independently regenerated `24311ac` JSON
are byte-identical (`cmp`). The baseline export's 203 Source files also match the commit byte-for-byte.

The two largest deterministic inputs now use versioned manifest recipes. `many-entries` uses seed 0
and the existing tar builder; `gzip-rich-header` uses seed 65 for its 270,000-byte comment. The latter's
270-byte deflate/trailer tail remains frozen inside the recipe, avoiding zlib-version differences in
re-encoding. Every decoded or generated input goes through the same original SHA-256 assertion.

| Stored content | Before bytes | After bytes |
| --- | ---: | ---: |
| Public-value JSON / LZFSE | 24,492,114 | 103,945 |
| many-entries.tar.b64 | 98,215 | 0 (generated from recipe) |
| gzip-rich-header.tar.gz.b64 | 365,142 | 0 (generated from recipe) |
| Entire tar-golden directory, including README, manifest and hash | 25,205,686 | 358,194 |

The directory shrank from 112 to 111 files, 24.038 to 0.342 MiB: **98.58% smaller**.
Sizes sum the regular files intended for Git, rather than filesystem allocation or Git pack size.

Hashes for the compact representation:

- Decompressed JSON (unchanged): `9ea2ba84246f423558a82207b23052d94db06ac03a61b14ef6f926c1c339f796`
- `public-values.json.lzfse`: `37a2b46d3d8d9877c684e83c431d775e4feeeeb8345af4ea6c4a3e5859663517`
- `manifest.json`: `b32537ced23f32ae728ced5f96f998842a45a9f00561c846b8f71cbc6f6c1652`
- Golden test/loader: `1bbdf3ed3190e6e886656808d7f7a32b3e3066eff3c8476d4f2311c9e8fdf6d9`

Correction validation uses the same SwiftPM cache/native-backend wrapper described above. Logs are
under `<tmp>/kaitokit-s12/correction1`. The [golden README](../../Tests/Fixtures/tar-golden/README.md)
documents baseline-only regeneration, readable dumps and failure diagnostics. A value mismatch still
dumps every full row and now also writes directly comparable `expected.json` / `actual.json` files.

| Run | Result |
| --- | --- |
| `TZ=UTC KAITOKIT_DUMP_TAR_GOLDEN=<dump> swift test --filter TarPublicValueGoldenTests` | 1 test, zero failures, 43.478 s; dumped JSON identical to original |
| On `24311ac`: `TZ=UTC KAITOKIT_WRITE_TAR_GOLDEN=1 KAITOKIT_DUMP_TAR_GOLDEN=<dump> swift test --filter TarPublicValueGoldenTests` | 1 test, zero failures, 43.918 s; regenerated JSON identical to original |
| On `24311ac`: `TZ=UTC KAITOKIT_WRITE_TAR_GOLDEN_INPUTS=1 swift test --filter TarPublicValueGoldenTests` | 1 test, zero failures, 43.777 s; manifest identical, all 109 original hashes and 107 stored inputs preserved |
| Full `swift test` | 1,514 tests, 47 skips, zero failures, 548.188 s; KaitoKitTests 1,480 / Compat 34 |
| Local-time golden within the full run | 109 inputs, 2,868 combinations, both options, zero failures, 42.385 s |
| Tar differential fuzz within the full run | 2,400 mutations, zero differences, 26.060 s |

Release/framework, sanitizers, sibling suites and performance probes were not rerun for this
storage-only correction. Their stage-A results above remain the original measurements.
`git diff --check` passed. The final hash audit of 413 production/test/supplied-fixture files found
only the intended golden test/loader change; the original test support and read-amount/descriptor
tests are unchanged. No commit, tag or release was created.
