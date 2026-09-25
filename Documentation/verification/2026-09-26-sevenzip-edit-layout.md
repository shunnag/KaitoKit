# P5-K / S23: 7z edit layout and decrypted packed stream (2026-09-26)

Worktree: `/Users/nagash/Github/KaitoKit-p4k`, starting HEAD
`d171f272686a6c5c87feeb86051fa84f2a3abb97`. No commit was made. The canonical
KaitoKit checkout, GyoshukuKit and KaitoFinder were not changed.

All functions named in P5-K SCOPE were found before implementation. New API is
limited to the `SevenZipEditLayout` SPI declarations in P5 §0.2. ReaderOptions'
public initializer and existing public declarations are unchanged.

## Frozen inputs and K0

The 33 archives and both expected JSON files were copied unchanged from
`SP/p5/fixtures` to `Tests/Fixtures/sevenzip-edit`. `README.md`, `NOTICE-lines.txt`
and the original `SHA256SUMS` were also copied unchanged from `SP/p5`; the NOTICE
lines were appended to `Tests/Fixtures/NOTICE`. A Python SHA-256 comparison against
the original manifest verified all 37 imported payload/documentation files. The
manifest itself was copied byte-for-byte; its original paths still refer to the
Step 0 directory, including tools and logs that are not imported here.

K0 ran while `git diff -- Sources` was empty, against the starting HEAD. Its one
test passed before the first Sources edit. `public-values.json` captures all
public entry fields, every formatSpecific key, full stream SHA-256 and length,
and typed errors from URL opens. It covers 34 password runs across 33 archives
(`mix.7z` with both `secret` and `secret2`). The 32-byte empty archive remains an
open error. The frozen golden is 417,189 bytes, SHA-256:

```text
3fa61155d95ba4f6c9c081c82d4c0d22d9705809a6c61cd025226dd0f51e59f3
```

The companion `.sha256` file is checked by the test. Golden generation refuses
to overwrite an existing file. Initial evidence is in `.build/p5k-k0.log` and
`.build/p5k/k0-freeze.json`; later tests compare both option settings to the same
frozen bytes.

## Implementation and coverage

Recording reuses the existing parse. Raw times are captured before Date
conversion; coder flags distinguish explicit arity and absent versus empty
properties. The internal state retains raw file values and encoded-header
streams. Main folders are converted to SPI values only when requested. Reopen
shares that state without retaining a source in the snapshot or adding reads.

The AES SPI shares the existing decoder helper, key cache, cycle ceiling and
PackInfo verifier. It synchronizes the reader password without invoking the
provider. The result stops at the AES output size and has no output CRC or
further decompression; a wrong password is deliberately not authenticated.

The new tests cover:

- All 33 structural goldens (32 successful opens and the frozen negative open),
  every successful reopen, physical-to-signature offset conversion, coder
  graph, pack SHA-256/CRC, substreams, file raw fields and property order.
- SFX base 4096, packPos 16, libarchive version 0.3/property order, both supported
  empty headers, AES-only headers, anti and streamed zero-size files.
- First unrepresented reason; external_names reports `additionalStreams` because
  that section precedes external FilesInfo. Parser tests also exercise both
  FilesInfo and UnpackInfo `externalData` flags and their unchanged errors.
- Option off, non-7z, split `.7z.001`, and direct ConcatenatedByteSource exclusion;
  identical open byte counts and no snapshot/reopen reads.
- Synthetic explicit 1-in/1-out coders, present empty properties, partial pack
  digests, zero-substream folders, and a multi-folder/multi-pack encoded header.
- Matching failures with recording off/on for malformed and truncated headers.
- All 17 main AES folders in expected-decrypted.json, with recording off/on
  (34 checks), varied read boundaries, zero-padding removal, current password,
  wrong-password bytes, required-password/provider behavior, index errors,
  non-AES and indirect-AES rejection, cycle ceiling, PackInfo digest/cache, and
  shared key derivation across header, packed and ordinary entry reads.
- SPI import without `@testable`, plus a separate external package that checks
  allowed SPI access and rejects the same use without the SPI import.

## Commands and results

Swift: Apple Swift 6.4 (`swiftlang-6.4.0.34.1`, arm64 macOS 27.2), Swift 6 language
mode. The initial literal K0 `swift test --filter SevenZipPublicValueGoldenTests`
(with `KAITOKIT_WRITE_7Z_PUBLIC_GOLDEN=1`) failed during manifest compilation:
the outer sandbox denied the default `~/.cache/clang/ModuleCache`. Subsequent
commands used writable caches and disabled SwiftPM's nested sandbox only; the
outer workspace restrictions remained in effect.

The following abbreviations reproduce the actual command arguments:

```sh
cd /Users/nagash/Github/KaitoKit-p4k
SP=/private/tmp/claude-501/-Users-nagash-Github-KaitoFinder/3d80b8d3-15ce-4c2d-bf52-2944c9d6e58c/scratchpad
export CLANG_MODULE_CACHE_PATH="$PWD/.build/p5k/module-cache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/p5k/module-cache"
p5k_flags=(--disable-sandbox --cache-path "$PWD/.build/p5k/cache"
  --config-path "$PWD/.build/p5k/config" --security-path "$PWD/.build/p5k/security")

# Before changing Sources; 1 test passed.
KAITOKIT_WRITE_7Z_PUBLIC_GOLDEN=1 swift test "${p5k_flags[@]}" \
  --filter SevenZipPublicValueGoldenTests
# Implementation build passed.
swift build "${p5k_flags[@]}"
# First focused run: 12 tests passed, no skips/failures.
swift test "${p5k_flags[@]}" --filter \
  'SevenZipPublicValueGoldenTests|SevenZipEditingSnapshotTests|SevenZipDecryptedPackedStreamTests|SevenZipEditLayoutSPIImportTests'
# First release attempt failed at restricted dSYM generation.
KAITOKIT_7Z_SCALE_DIR="$SP/p45/scale" swift test "${p5k_flags[@]}" \
  -c release -Xswiftc -enable-testing --filter SevenZipEditLayoutScaleProbeTests
# Retry disables debug information; optimization and testability are unchanged.
KAITOKIT_7Z_SCALE_DIR="$SP/p45/scale" swift test "${p5k_flags[@]}" \
  -c release -debug-info-format none -Xswiftc -enable-testing \
  --filter SevenZipEditLayoutScaleProbeTests
```

Logs: `.build/p5k/build.log`, `targeted.log`, `scale-dsym-failed.log`, `scale.log`.

The release scale probe passed (1 test, 0 skips, 0 failures). Each archive/mode
used five fresh XCTest child processes, alternating which mode ran first. Timing
covers only URL `ArchiveReader.open`; RSS is the live reader's process resident
size before requesting a snapshot. The log also retains peak RSS and every
sample. No full suite or external build ran concurrently with these samples.

| Archive | Entries | Off median ms | On median ms | On/off | Off RSS B | On RSS B | Delta B | Delta B/entry |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| g_k100.7z | 100,101 | 236.659375 | 240.937583 | 1.018077 | 202,768,384 | 213,975,040 | 11,206,656 | 111.953487 |
| z_k100.7z | 100,101 | 204.646792 | 209.496000 | 1.023695 | 146,751,488 | 158,924,800 | 12,173,312 | 121.610294 |

Both meet the 1.10 time ratio and 128 B/entry bounds; both memory increments are
also below 12.8 MB.

External package checks completed:

```sh
swift build "${p5k_flags[@]}" --package-path "$PWD/.build/p5k/spi-client" \
  --scratch-path "$PWD/.build/p5k/spi-build" --target Allowed
swift build "${p5k_flags[@]}" --package-path "$PWD/.build/p5k/spi-client" \
  --scratch-path "$PWD/.build/p5k/spi-build" --target Denied
```

The Swift 6 package has two targets depending on the local KaitoKit product.
Each target contains `A.swift` with `public import KaitoKit`. Allowed's B.swift
uses `@_spi(SevenZipEditLayout) internal import KaitoKit`; Denied's C.swift uses
`internal import KaitoKit`. The remaining source is identical:

```swift
func inspect(_ reader: ArchiveReader) throws -> Int {
    var options = ReaderOptions()
    options.recordsSevenZipEditLayout = true
    let snapshot: SevenZipEditingSnapshot? = reader.sevenZipEditingSnapshot()
    let stream = try reader.sevenZipDecryptedPackedStream(folder: 0, packedInput: 0)
    return (snapshot?.folders.count ?? 0) + Int(stream.remaining)
}
```

Allowed exited 0 without `@testable`. Denied exited 1 as expected: the option
and both accessors were inaccessible due to SPI protection, and the snapshot
type was not in scope. The required public import produced only an unused-import
warning in Allowed. Logs: `.build/p5k/spi-allowed.log`, `spi-denied.log`.

The full test command completed with exit 0:

```sh
TZ=Asia/Tokyo swift test "${p5k_flags[@]}"
```

| Bundle | Reported tests | Passed | Skipped | Failures | Test seconds |
|---|---:|---:|---:|---:|---:|
| KaitoKitTests | 1,525 | 1,471 | 54 | 0 | 612.183 |
| KaitoKitCompatTests | 34 | 34 | 0 | 0 | 2.042 |
| Total | 1,559 | 1,505 | 54 | 0 | 614.225 |

The original ReopenSharingTests, descriptor/read-count checks, all 14 new
non-probe tests, and the remaining existing suites passed without modifying
existing test files. The new scale test is the only new skip in the default
full run; its separate release run passed above. The other 53 skips are existing
optional input/tool/probe conditions. Full log: `.build/p5k/full.log`; exact
skipped test names and reasons: `.build/p5k/full-summary.json`.

| Skips | Reported reason |
|---:|---|
| 1 | set KAITOKIT_AR_ORACLE to the supplied ar fixture directory |
| 1 | KAITOKIT_CAB_CORPUS is not configured |
| 2 | set KAITOKIT_CPIO_ORACLE to the supplied cpio fixture directory |
| 1 | set KAITOKIT_CPIO_DETECTION_BASELINE to the pre-change detection JSON |
| 17 | set KAITOKIT_LHA_CORPUS to run the LHA corpus tests |
| 1 | set KAITOKIT_BOOK_LHA to run the book fixture comparison |
| 1 | Tests/Fixtures/lha is empty |
| 1 | LHX/LHArk lhasa corpus is absent |
| 1 | lhasa PMarc 2 corpus is absent |
| 1 | RAR4 differential corpus is absent |
| 1 | RAR4 malformed-input corpus is absent |
| 1 | no additional RAR4 fixtures in Tests/Fixtures/rar4; differential skipped |
| 5 | KAITOKIT_RAR4_CORPUS is not configured |
| 1 | RAR3 solid PPMd fixture is absent |
| 2 | RAR4 oracle archive is absent |
| 1 | set KAITOKIT_7Z_SCALE_DIR to the frozen scale corpus; run in release |
| 3 | 外部オラクル入力は fixture に収録しない |
| 1 | 外部の go 標本は fixture に収録しない |
| 2 | 外部コーパス未指定 |
| 1 | 32 MiB 距離検証は明示実行 |
| 1 | 敵対的 JPEG 入力は明示実行 |
| 1 | 外部 JPEG コーパスは明示実行 |
| 1 | 性能測定は release で明示実行 |
| 1 | 外部歴史的書庫は明示実行 |
| 1 | set KAITOKIT_TAR_SPLICE_PROBE_LARGE=1 for the 4 GiB + 1 MiB corpus |
| 1 | set KAITOKIT_TAR_SPLICE_PROBE to the prototype segment manifest |
| 1 | Info-ZIP was built without bzip2 support; fixture skipped: |
| 2 | set KAITOKIT_ZIP_SCALE_PROBE to a 500k ZIP |

The required focused rerun completed with exit 0:

```sh
TZ=Asia/Tokyo swift test "${p5k_flags[@]}" \
  --filter 'SevenZip|ReopenSharingTests|SingleFileArchiveReaderIntegrationTests'
```

It reported 161 core tests (160 passed, 1 skipped, 0 failures; 81.161 seconds)
and 1 compatibility test (passed; 0.140 seconds): **162 reported, 161 passed,
1 skipped, 0 failures**. The sole skip was the opt-in scale probe, already passed
in release. Log: `.build/p5k/focused.log`; summary: `focused-summary.json`.

The final fixture audit again verified all 37 imported payload/documentation
hashes, confirmed the original SHA256SUMS with `cmp`, confirmed the appended
NOTICE text, and verified the K0 SHA-256 unchanged. `git diff --check` passed.
The final branch was `feature/2026-09-26-p4k` and HEAD remained
`d171f272686a6c5c87feeb86051fa84f2a3abb97`.

AC-K1–AC-K9 are satisfied by the build, full/focused runs, frozen public and
structural goldens, AES comparisons, external SPI compile checks, scale values,
and API/documentation audit above. No fixture was regenerated and no commit
was made.

## API audit

```sh
git diff -U0 -- Sources | rg -n '^\+.*\bpublic\b|@_spi'
git ls-files --others --exclude-standard Sources | xargs rg -n '\bpublic\b|@_spi'
git diff --check
git status --short
git rev-parse HEAD
```

The audit includes untracked source files. It finds only the option, the two
ArchiveReader accessors, nine SPI types and their specified members, plus the
CLI's SPI import. No public initializer, other public API, `@unchecked Sendable`
or `nonisolated(unsafe)` was added. Full declaration output is retained in
`.build/p5k/api-audit.log`.

## オーケストレータの検証（2026-09-26）

隔離した `$SCR/v3`（この worktree を rsync、隣に GyoshukuKit bfb2980 を `git archive`）。

| 実行 | 結果 |
|---|---|
| `TZ=Asia/Tokyo swift test`（全件） | XCTest 1,525 件、失敗 0、skip 54（任意実行の道具・corpus と scale probe） |
| GyoshukuKit bfb2980 の `swift test` をこの KaitoKit に対して | 439 件、失敗 0 |
| 公開の宣言 | 追加は `@_spi(SevenZipEditLayout)` の型・accessor・`ReaderOptions` の stored property だけ（`kaito` の main.swift は計測用に SPI を import する） |

Codex の release の scale probe（open の option の on / off 比 1.018〜1.024 倍、1 件あたりの記録 112.0〜121.6 B で上限 128 B 以内）は採り直していない。
