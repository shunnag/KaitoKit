# P4-K LHA raw layout verification — 2026-09-26

Worktree: `~/Github/KaitoKit-p4k`, branch `feature/2026-09-26-p4k`,
base `d35f2da23ba2c213453aa36353eda7a0184b7fc1`. No commit was made. The canonical
KaitoKit checkout, GyoshukuKit and KaitoFinder were not edited.

Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), target `arm64-apple-macosx27.2.0`.
All named P4-K parser/reader functions were present before editing.

## Results

| Check | Result |
| --- | --- |
| `swift build` | Passed, 13.88 s, no compiler warnings |
| Focused `swift test` | 112 tests: 91 passed, 21 skipped, 0 failures; 3.105 s |
| Full `swift test`, KaitoKitTests | 1,510 tests: 1,457 passed, 53 skipped, 0 failures; 567.897 s |
| Full `swift test`, KaitoKitCompatTests | 34 passed, 0 skipped, 0 failures; 2.008 s |
| Full total | **1,544 tests: 1,491 passed, 53 skipped, 0 failures** |
| New LHA tests | 11 layout + 2 golden + 1 SPI import tests, all passed in both runs |
| External SPI compiler probes | SPI import exit 0; ordinary import exit 1 as expected |
| Frozen import identity | 63/63 files byte-identical |
| API/unsafe-concurrency audit and whitespace check | Passed |

The two trailing Swift Testing runners each discovered zero tests. All 1,544
tests counted above are XCTest cases; summary lines were not double-counted.
Both test commands exited 0. No failed build or test invocation occurred.

`KAITOKIT_LHA_CORPUS` was unset. The full suite's 53 skips break down as follows;
the focused run's 21 skips are exactly the LHA row:

| Area | Skips | Reasons |
| --- | ---: | --- |
| LHA | 21 | 17 require `KAITOKIT_LHA_CORPUS`; 1 requires `KAITOKIT_BOOK_LHA`; 1 optional raw `.lzh` corpus is absent; 1 LHX/LHArk corpus and 1 PMarc 2 corpus are absent |
| RAR4 | 11 | 5 require `KAITOKIT_RAR4_CORPUS`; 2 oracle archives, 1 differential corpus, 1 malformed corpus, 1 solid PPMd fixture and 1 additional-fixture corpus are absent |
| ar | 1 | `KAITOKIT_AR_ORACLE` unset |
| CAB | 1 | `KAITOKIT_CAB_CORPUS` unset |
| cpio | 3 | 2 require `KAITOKIT_CPIO_ORACLE`; 1 requires `KAITOKIT_CPIO_DETECTION_BASELINE` |
| StuffIt / StuffIt X | 11 | 3 external oracle inputs, 2 external corpora, and one each of the external go sample, historical archive, external JPEG corpus, hostile JPEG corpus, 32 MiB distance probe and release performance probe require explicit configuration |
| Tar scale probes | 2 | `KAITOKIT_TAR_SPLICE_PROBE` / `KAITOKIT_TAR_SPLICE_PROBE_LARGE` unset |
| ZIP scale probes | 2 | `KAITOKIT_ZIP_SCALE_PROBE` unset |
| ZIP bzip2 oracle | 1 | Installed Info-ZIP lacks bzip2 support |

Existing ZIP/tar golden tests ran in the full suite with `UTC=false`; their
UTC-only date comparisons were not run separately. The new LHA golden tests
compared every field, including dates, with `TZ=Asia/Tokyo` in both runs.

## Implementation and fixture checks

- The four SPI types and `ArchiveReader.lhaRawLayout()` match P4 §0.2.
  Public record arrays are shared; only unpublished records need a position map.
  Header offsets are derived from the preceding member. OS IDs use the existing
  record's padding; the test enforces the specified maximum 16-byte stride growth
  from the previous 48-byte record.
- Coverage includes all header levels, anonymous members at the first/middle/last
  positions and in consecutive runs, both EOF acceptance forms, empty archives,
  empty-directory terminators, SFX, OS-9's two-byte header undercount, LHArk,
  64-bit packed size, headers larger than 4 KiB, invalid positions, short/failed
  tail reads, the 65,536-byte boundary, cancellation, detached Sendable values,
  recovery, numbered volumes, direct concatenated sources and reopen without reads.
- All 63 frozen files (31 base64 files, 31 goldens and the manifest) were compared
  byte-for-byte to `scratchpad/p4/fixtures` after import: 63/63 identical.
  Each decoded fixture is also checked against its manifest size and SHA-256.
- The golden tests compare the exact Step 0 JSON format under `TZ=Asia/Tokyo`:
  31 fixtures, 74 entries, 72 content hashes, two expected content errors and one
  expected open error. All three existing `Tests/Fixtures/lha` archives are also
  compared to their frozen goldens. There is no golden regeneration path.
- The 4 GiB packed-size fixture is materialized by extending its 62-byte header
  file sparsely to 4,294,967,359 bytes. Its contents are not buffered in memory.
- The tl-S11 four-entry view and LHA `rawRecord(of:) == nil` remain unchanged.

## Commands actually run

Commands ran from the worktree above. Cache paths stay inside the worktree;
`--disable-sandbox` disables SwiftPM's nested sandbox. Swift 6 strict concurrency
is enabled by the existing package configuration. Build and test logs are in
`.build/p4k/`.

```sh
mkdir -p .build/p4k/cache .build/p4k/configuration .build/p4k/security .build/p4k/module-cache
CLANG_MODULE_CACHE_PATH="$PWD/.build/p4k/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/p4k/module-cache" swift build --disable-sandbox --cache-path "$PWD/.build/p4k/cache" --config-path "$PWD/.build/p4k/configuration" --security-path "$PWD/.build/p4k/security" -j 4 > .build/p4k/build.log 2>&1
TZ=Asia/Tokyo CLANG_MODULE_CACHE_PATH="$PWD/.build/p4k/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/p4k/module-cache" swift test --disable-sandbox --cache-path "$PWD/.build/p4k/cache" --config-path "$PWD/.build/p4k/configuration" --security-path "$PWD/.build/p4k/security" -j 4 --filter 'LHARawLayout|LHAPublicValueGolden|LHA|EmptyLHA|ZipRawLayoutSPIImport' > .build/p4k/focused.log 2>&1
TZ=Asia/Tokyo CLANG_MODULE_CACHE_PATH="$PWD/.build/p4k/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/p4k/module-cache" swift test --disable-sandbox --cache-path "$PWD/.build/p4k/cache" --config-path "$PWD/.build/p4k/configuration" --security-path "$PWD/.build/p4k/security" -j 4 > .build/p4k/full.log 2>&1
```

`LHARawLayoutSPIImportTests` uses `@_spi(LHARawLayout) internal import KaitoKit`
without `@testable`. A separate compiler probe exercises all four SPI types,
their cases/properties and `lhaRawLayout()`/`member(at:)`. Its only import is
`@_spi(LHARawLayout) internal import KaitoKit`. An otherwise identical file with
plain `import KaitoKit` is the negative probe:

```sh
sed 's/@_spi(LHARawLayout) internal import/import/' .build/p4k/spi-allowed.swift > .build/p4k/spi-denied.swift
xcrun swiftc -typecheck -swift-version 6 -target arm64-apple-macos26.0 -I .build/out/Products/Debug -I Sources/CBzip2 -module-cache-path .build/p4k/module-cache .build/p4k/spi-allowed.swift > .build/p4k/spi-allowed.log 2>&1
xcrun swiftc -typecheck -swift-version 6 -target arm64-apple-macos26.0 -I .build/out/Products/Debug -I Sources/CBzip2 -module-cache-path .build/p4k/module-cache .build/p4k/spi-denied.swift > .build/p4k/spi-denied.log 2>&1
```

The positive probe exited 0. The negative probe exited 1: the types cannot be
found and `lhaRawLayout` is inaccessible due to `@_spi` protection.

## API and worktree audit

These searches include the untracked model file:

```sh
git diff -U0 -- Sources | rg -n '^\+.*\bpublic\b|^\+.*@_spi'
git ls-files --others --exclude-standard Sources | xargs rg -nH '\bpublic\b|@_spi'
git diff --check
git status --short
```

The first search reports only `@_spi(LHARawLayout)` and
`public func lhaRawLayout() throws -> LHAArchiveLayout?` in ArchiveReader.
The second reports only the following in `Model/LHARawLayout.swift`:

| SPI declaration | Members |
| --- | --- |
| `LHAMemberLayout: Sendable, Equatable` | `headerRange`, `dataRange`, `headerLevel`, `method`, `osID`, `crc16`, `entryIndex` |
| `LHAArchiveTerminator: Sendable, Equatable` | `zeroByte(offset:)`, `emptyNameDirectoryMember(_:)`, `endOfFile` |
| `LHATrailingBytes: Sendable, Equatable` | `none`, `zeros(count:)`, `nonZero(count:)`, `unchecked(count:)`, `notApplicable` |
| `LHAArchiveLayout: Sendable` | `archiveLength`, `firstHeaderOffset`, `endOfMembersOffset`, `terminator`, `trailingBytes`, `memberCount`, `unpublishedMemberCount`, `member(at:)` |

The complete search output is `.build/p4k/api-audit.log`. No new public
initializer, ReaderOptions field, ByteSource/FormatReader requirement,
`@unchecked Sendable` or `nonisolated(unsafe)` was added. Design and Unreleased
changelog documentation were updated.

## Performance scope

AC-K5 release benchmarks and RSS measurements were not run in this task. The
orchestrator owns the S14 comparison using `p4bench/archives/{k100,payload,headers}.lzh`
under the specified load condition. No performance acceptance claim is made here.
No sanitizer run or separate external corpus/oracle invocation was performed;
available existing oracle tests ran as part of the full and focused suites.

## オーケストレータの検証（2026-09-26）

隔離した `$SCR/v3`（この worktree を rsync、隣に GyoshukuKit d5c51b3 を `git archive`）。

| 実行 | 結果 |
|---|---|
| `TZ=Asia/Tokyo swift test`（全件） | XCTest 1,510 件 + swift-testing 34 件、失敗 0、skip 53（`KAITOKIT_LHA_CORPUS` などの任意実行） |
| GyoshukuKit d5c51b3 の `swift test` をこの KaitoKit に対して | 430 件、失敗 0 |

AC-K5（release の `kaito bench` の open と `kaito list` の常駐メモリを d35f2da と比べる）は、負荷の平均が 4 未満のときに採り、この節の後に追記する
（検証の時点では別の作業が機械を占有し、負荷の平均が 33 だった）。書庫は `SP/p4bench/archives/{k100,payload,headers}.lzh`（gyoshuku-bench で作成）。

### AC-K5 の計測（オーケストレータ、2026-09-26 08:13–08:14）

release の `kaito bench <archive> 5` の `open-median-ms` を、基準 d35f2da と P4-K d171f27 で交互に 2 回ずつ（`SP/p4bench/run_k5.sh`）。
負荷の平均（1 分）は 5.3〜7.2 で、条件の 4 未満は満たせなかった（機械を他の作業と共有）。交互の比で判定した。

| 書庫 | 基準 ms（2 回） | P4-K ms（2 回） | 比 | 条件 |
|---|---|---|---:|---|
| k100.lzh（1 byte × 100,000） | 430.1、424.9 | 427.5、428.0 | 1.00 | ≦ 1.02 |
| payload.lzh（256 MiB + 1,000 件） | 4.76、4.63 | 4.61、4.59 | 0.98 | ≦ 1.02 |
| headers.lzh | 59.0、56.8 | 57.5、55.6 | 0.97 | ≦ 1.02 |

`/usr/bin/time -l kaito list k100.lzh` の最大常駐メモリは両方とも 188,727,296 B（条件: 基準 + 2 MB 以下）。AC-K5 は合格。
