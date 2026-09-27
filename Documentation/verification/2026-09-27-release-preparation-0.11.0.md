# KaitoKit 0.11.0 release preparation — 2026-09-27

Prepared in `feature/2026-09-24-review` at `823ad46`, ten commits beyond
`v0.10.0`. No commit, push, tag or history rewrite was performed. GyoshukuKit and
KaitoFinder were not accessed or changed. The three replacement archives can be
copied into those repositories by the orchestrator.

## Project-owned 7z replacements

The originals were inspected with `/opt/homebrew/bin/7zz l -slt -t7z` and the
existing `expected-structures.json` before replacement. Each had one solid
folder and three ordinary files: `cat` (184,336 bytes, 0755), `ls` (252,512 bytes,
0755), and `t.txt` (50,000 bytes, 0644). There were no additional solid folders.

[`generate-filters.py`](../../Tests/Fixtures/sevenzip-edit/generate-filters.py)
now creates these names from seeded SHAKE-256 noise, synthetic x86 E8/E9 rel32
records and project-authored text. It preserves the original decoded sizes,
coder properties/binds/stream order, solid layout, entry names/kinds/permissions,
plain header and file property order. BCJ/BCJ2 retain creation/access/modification
times; PPMd retains modification times only. Present FILETIMEs are normalized to
2023-01-01 UTC after writing, with both header CRCs refreshed.

The writer is **7-Zip (z) 26.03 arm64, 2026-09-03**. Exact writer commands,
normalization and regeneration instructions are in the
[fixture README](../../Tests/Fixtures/sevenzip-edit/README.md).

| Archive | Bytes | SHA-256 |
|---|---:|---|
| `bcj.7z` | 39,836 | `00f22b8ab913ce939c590d15581569edaa9df91af63f2bd6d85e721f5f6391b1` |
| `bcj2.7z` | 38,532 | `316a1b3f0373cf7ae402fc3a05a8cf3727430db151a72382015353fed3e68133` |
| `ppmd.7z` | 80,554 | `d1888e17536f1887fb846f70c505f680b0b5b98446c8818e2d191a44ba29b73c` |

BCJ's decompressed LZMA2 stage differs from the original input, proving a real
filter transformation. BCJ2 retains four nonempty packed streams and two
nonempty branch streams (27,300 and 27,304 decoded bytes). The generator runs
`7zz t` and compares every `7zz x -so` output byte with its authored input.
`generate-filters.py --check` passed on a second independent generation.

Only these three records changed in `expected-structures.json` and
`public-values.json`. The AES arrays in `expected-decrypted.json` remain empty;
its provenance metadata records that check. `public-values.json.sha256`,
`NOTICE-lines.txt`, `Tests/Fixtures/NOTICE`, the README and `SHA256SUMS` were
updated. The manifest now checks all 40 local files instead of referring to
unavailable scratch scripts/logs. All 40 hashes match; the other 30 archives
remain byte-identical to HEAD. Archives plus the two structural/AES goldens now
occupy 2,039,509 bytes, within the original scratch-stage 2 MiB budget; no
archive exceeds the original 256 KiB individual budget.

The references in `SevenZipIntegrationTests`, `SplitVolumeTests` and
`CLISmokeTests` name the separate project-owned
`sevenzip/chain-lzma-lzma-lzma2-bcj2.7z.b64`, which is unchanged.
`SevenZipEditingSnapshotTests` consumes the refreshed structural golden and has
no old-payload constants to replace. No test proposition or assertion was
removed or weakened.

## NOTICE audit: other provenance items left unchanged

This is a review of the repository's recorded provenance, not a new license
determination or an audit of the external source repositories.

- **StuffIt X slice 4 English dictionary** (`Tests/Fixtures/NOTICE`, line 682):
  a redistributed word list expanded from XADMaster's
  `StuffItXEnglishDictionary.c`, embedded in `StuffItXEnglishDictionary.swift`.
  `Documentation/design.md` identifies Aladdin as the original asset source and
  describes it as an LGPL-derived expansion. The NOTICE records the user's
  incorporation decision, but does not supply a redistribution grant for that
  underlying word list; its referenced `research/THIRD_PARTY_DATA.md` is not in
  this checkout. This needs provenance/license follow-up before claiming all
  shipped content is project-authored or cleared for redistribution.
- **StuffIt X slice 7 JPEG tables** (`Tests/Fixtures/NOTICE`, line 749): numerical
  tables measured from vendor binaries, incorporated via the user's Python
  implementation. These are another non-project-origin data item; the record
  states they are measurements, not vendor code copies. The JPEG vector
  compressed prefixes are separately identified as coming from supplied CC0
  photographs. Nothing in this review establishes that the numerical tables
  are nonredistributable; their provenance remains a separate follow-up item.
- **Imported prototype provenance is incomplete in NOTICE**: the unchanged
  `sevenzip-edit/g_*`, `z_default`, `z_plainhdr`, `z_nonsolid`, `z_aes`, `z_aesh`,
  `m`, `s200` (and `sfx` derived from `g_plain`), and the supplied `tar-edit`
  archives identify their writers/import paths without explicitly stating
  ownership of every payload byte. They are not identified as Apple payloads;
  this audit does not infer redistribution rights solely from the writer used.

The other explicit third-party fixture groups record redistribution provenance:
libarchive RAR fixtures under BSD-2-Clause, Lhasa fixtures under ISC, and the
StuffIt corpus under CC0 with a separate statement for self-extractor stubs.
The remaining named tool-generated groups describe project-owned inputs and
black-box writers. No other explicit bundled Apple executable payload was
identified in NOTICE. No entry above or its bytes was changed.

The old Apple-containing blobs still exist in local commit `ef06e22` and its
descendants. Replacing working-tree files does not remove those historical
objects. The orchestrator must account for that before the first public push;
history was left untouched under the no-commit instruction.

## Release documentation, path hygiene and CI

- An empty `Unreleased` section now precedes `0.11.0 - 2026-09-27`. The lead
  documents the four additive editing SPIs, their SemVer policy, unchanged
  public API/enums, and ZIP/zstd speed-ups.
- Added `d412a02`'s ZIP timestamp/Calendar improvement (500k open 1,142 → 463 ms),
  1,024-record cancellation checks and preservation through ZIP64/UDF retries;
  added `b518014`'s initial zstd improvement (1,449 → 513 ms).
- The already-cancelled Task behavior is documented under 変更 and on all three
  `KaitoArchive` failable initializers: `CancellationError` becomes `nil`.
- P11 now quotes the final host gate: text open 0.558 ≤ 0.70, small ZIP extract
  0.388 ≤ 0.55, headers ZIP extract 0.440 ≤ 0.65; RSS within before + 1 MiB.
  These are the recorded host measurements, not new measurements in this task.
- The tar K5 tbz large-delete ratio 0.432 versus target 0.25 is documented as
  a known limitation; no quiet remeasurement is claimed.
- All newly added verification Markdown records are indexed under v0.11.0.
  Seven machine-specific path occurrences in four changed verification files
  were redacted to `~` / `$SP`. The requested diff-since-v0.10.0 path scan is
  empty; no checked fixture exception was found or modified for redaction.
- CI now installs `zstd` alongside `sevenzip xz brotli`, including on Intel,
  and requires it with `KAITO_REQUIRE_ZSTD=1`. `ZstdTests` had hard-coded
  `/opt/homebrew/bin/zstd` and `/opt/homebrew/bin/7zz`; installation alone would
  still skip on Intel. It now uses the existing executable resolver (override,
  PATH, both Homebrew prefixes) and the required-oracle guard. Matrix, fixture
  and decoder assertions are unchanged.
- `Scripts/build-framework.sh` still has `CFBundleShortVersionString=0.1.0`
  and `CFBundleVersion=1`. No documented release procedure ties these constants
  to package release tags, so the script was left unchanged.

## Verification commands and results

Host: macOS 27.2 (26B5091g), arm64; Apple Swift 6.4
(`swiftlang-6.4.0.34.1`). Oracles: 7-Zip 26.03, XZ Utils 5.8.4, brotli 1.2.0,
zstd 1.5.7, all available under `/opt/homebrew/bin`.

The literal `swift build` initially failed because the outer workspace sandbox
denied the default module cache. Redirecting the caches then reached SwiftPM's
nested `sandbox-exec`, which was also denied. The documented workaround was
used for all successful Swift commands; it does not remove the outer sandbox:

```sh
export CLANG_MODULE_CACHE_PATH=/tmp/kaitokit-011-clang-cache
export SWIFTPM_MODULECACHE_OVERRIDE=/tmp/kaitokit-011-swift-cache
swift_flags=(--disable-sandbox --cache-path /tmp/kaitokit-011-spm-cache)

swift build "${swift_flags[@]}"
KAITO_REQUIRE_7ZZ=1 KAITO_REQUIRE_XZ=1 KAITO_REQUIRE_BROTLI=1 KAITO_REQUIRE_ZSTD=1 \
  swift test "${swift_flags[@]}"
TZ=UTC swift test "${swift_flags[@]}" \
  --filter 'ZipPublicValueGoldenTests|TarPublicValueGoldenTests|GyoshukuFixtureMapTests|SevenZip'
TZ=Asia/Tokyo swift test "${swift_flags[@]}" --filter LHAPublicValueGoldenTests
```

All four required-oracle switches were set for the final full suite. The zstd
switch was added with the Intel path fix; matrix execution is checked in the
full-suite log.

The executable override was checked with `KAITO_ZSTD` pointing to a temporary
wrapper: `ZstdTests.testCLIGeneratedMatrix` passed all 80 cases and the wrapper
recorded 80 invocations. An intentionally nonexistent override with
`KAITO_REQUIRE_ZSTD=1` produced the required-oracle failure and no skip, as
expected. This is an arm64 host check of executable lookup and enforcement;
the Intel runner itself was not available locally.

`swift build` passed. The final full suite passed **1,570 XCTest tests**
(1,536 KaitoKit + 34 compatibility), **50 skips, 0 failures**. The two Swift
Testing runners discovered 0 additional tests. KaitoKit completed in 673.903 s,
compatibility in 2.136 s. The zstd CLI matrix executed all 80 cases successfully.

The 50 skips were:

| Group | Count | Reason |
|---|---:|---|
| ar | 1 | External oracle corpus not configured |
| CAB | 1 | External LZX corpus not configured |
| cpio | 3 | Two external oracle runs and a detection baseline not configured |
| LHA | 21 | Optional compatibility, book, MacBinary, method and SFX corpora absent/not configured |
| RAR4 | 11 | Optional differential, malformed, reader, SFX, solid PPMd and volume corpora absent/not configured |
| 7z | 1 | Frozen scale corpus not configured (Release probe) |
| StuffIt X | 7 | Optional external corpora, 32 MiB Deflate distance, JPEG adversarial/historical/performance runs |
| tar | 2 | Optional prototype manifest and 4 GiB + 1 MiB corpus |
| ZIP | 3 | Two scale probes not enabled; system Info-ZIP lacks bzip2 writing support |

None of the required 7zz / xz / brotli / zstd oracles was skipped.

| Requested timezone selection | Result |
|---|---|
| `TZ=UTC swift test --filter 'ZipPublicValueGoldenTests\|TarPublicValueGoldenTests\|GyoshukuFixtureMapTests\|SevenZip'` | Passed: 148 KaitoKit + 1 matching compatibility test = 149 tests; 1 skip, 0 failures; 130.671 s + 0.138 s |
| `TZ=Asia/Tokyo swift test --filter LHAPublicValueGoldenTests` | Passed: 2 tests, 0 skips, 0 failures; 1.045 s; 3 existing + 31 frozen Step 0 fixtures |

The UTC skip is `SevenZipEditLayoutScaleProbeTests.testOpenTimeAndResidentMemory`:
`KAITOKIT_7Z_SCALE_DIR` is not configured, and the probe is intended for Release.
The writable-cache flags shown above were used for both selections.

Final `git diff --check` passed. The requested path scan produced no matches,
and an additional scan including untracked new files also produced no matches.
HEAD remains `823ad46`, with no staged changes.

For each replacement, all three commands below returned 0; every `kaito sha`
entry digest/length matched the generator's input (nine entry comparisons):

```sh
/opt/homebrew/bin/7zz t -t7z Tests/Fixtures/sevenzip-edit/NAME.7z
/opt/homebrew/bin/7zz l -slt -t7z Tests/Fixtures/sevenzip-edit/NAME.7z
.build/out/Products/Debug/kaito sha Tests/Fixtures/sevenzip-edit/NAME.7z
```

| Entry | SHA-256 |
|---|---|
| `cat` | `8ff83208d438da0efc0267968f67c2308ef1f8cb72aac086cf1c70e4219659f9` |
| `ls` | `29da30e0a4d03a7e34d28912d7f39b99886e2b00d22a61dd697751ccc2b16248` |
| `t.txt` | `cd4b44213ea0e10fc4149b6b352a1dd9741921d6dd5913d0f9182f725243c72e` |

Raw local logs: `/tmp/kaitokit-011-build.log`,
`/tmp/kaitokit-011-golden.log`, `/tmp/kaitokit-011-full-test.log`,
`/tmp/kaitokit-011-utc-test.log`, `/tmp/kaitokit-011-lha-test.log`,
`/tmp/kaitokit-011-fixture-oracles.log`, `/tmp/kaitokit-011-zstd-path-test.log`,
`/tmp/kaitokit-011-zstd-required-test.log`. They are not checked in; this record
retains commands, results and portable paths.
