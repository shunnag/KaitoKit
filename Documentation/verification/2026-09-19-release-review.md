# KaitoKit release review verification — 2026-09-19

Base: clean working tree at `26b84ca`. Changes are uncommitted. Neither `../GyoshukuKit` nor `../KaitoFinder` was modified. No subagents were used.

Tests were written before each implementation change. New API/test seams were added without enforcement so missing behavior could be observed as runtime assertions. K7 is the explicit exception: its regression passed immediately, and inspection found no overflow requiring a fix. Compilation/setup errors were corrected before collecting the red results below; they are not presented as failing assertions.

All paths below are relative to this repository. Complete local command logs are under `/private/tmp/kaitokit-release-review-logs/`; the observed assertion text is preserved here so the record does not depend on those temporary logs.

## K1. Share compressed-tar staging on reopen

Reopening reran detection and decompression on the original compressed source: 440 bytes were read, a second reopen reached 880 bytes, and the spilled case gained one descriptor. The reader now retains the immutable staged source and constructs a fresh TarReader over it. Successive reopens retain the same source; published format, entries, member contents, and the URL hint are preserved after unlink. The original public open(source:options:) overload is preserved; an additive open(source:sourceURL:options:) overload supplies the URL hint needed by the counting-source tests. The hint plumbing was present in the red run, but staging reuse was not.

Files changed:

- `Sources/KaitoKit/Reader/ArchiveReader.swift`
- `Tests/KaitoKitTests/SingleFileArchiveReaderIntegrationTests.swift`
- `Tests/KaitoKitTests/Support/CountingByteSource.swift`

Tests added:

- `SingleFileArchiveReaderIntegrationTests.testCompressedTarReopenReusesStagedMemoryWithoutReadingCompressedSource`
- `SingleFileArchiveReaderIntegrationTests.testCompressedTarReopenReusesSpilledDescriptorWithoutReadingCompressedSource`

Exact failing assertion text observed before the fix (repeated identical assertions omitted):

```text
XCTAssertEqual failed: ("440") is not equal to ("0") - reopen must reuse the staged tar source
XCTAssertEqual failed: ("17") is not equal to ("16") - reopen must not create another staging descriptor
XCTAssertEqual failed: ("880") is not equal to ("0") - successive reopens must keep sharing staged bytes
```

## K2. Cancel compressed-tar staging

An already-cancelled detached task successfully staged a gzip-compressed tar containing a 4 MiB body with a zero memory threshold. Task.checkCancellation() now runs at the top of every materialization iteration, before reading the next chunk.

Files changed:

- `Sources/KaitoKit/Reader/SingleFileMaterializer.swift`
- `Tests/KaitoKitTests/SingleFileArchiveReaderIntegrationTests.swift`

Tests added:

- `SingleFileArchiveReaderIntegrationTests.testCancelledCompressedTarStagingStopsBeforeSpilling`

Exact failing assertion text observed before the fix (repeated identical assertions omitted):

```text
XCTAssertTrue failed - compressed-tar staging must propagate CancellationError
```

## K3. Reserve temporary-volume free space

Both initial spill and continued writing ignored available space. ReadLimits.stagingFreeSpaceReserve defaults to 1 GiB, independently of maxEntrySize. A statvfs query uses f_bavail * f_frsize before spill and before the next write after each 256 MiB. An in-memory prefix is split at the same check boundaries when it spills. Low space throws limitExceeded("staging free space"); the existing defer closes the unlinked descriptor. A task-local Sendable query hook isolates deterministic tests from concurrent readers. The field and hook existed for the red runs, but enforcement did not. Tests cover reserve minus one, the accepted boundary and ample capacity, no query for memory-only staging, and failure/descriptor cleanup after 256 MiB.

Files changed:

- `Sources/KaitoKit/Core/ReadLimits.swift`
- `Sources/KaitoKit/Reader/SingleFileMaterializer.swift`
- `Tests/KaitoKitTests/SingleFileArchiveReaderIntegrationTests.swift`

Tests added:

- `SingleFileArchiveReaderIntegrationTests.testStagingFreeSpaceReserveRejectsSpillWithoutLeakingDescriptor`
- `SingleFileArchiveReaderIntegrationTests.testStagingFreeSpaceReserveAllowsSpillAtReserve`
- `SingleFileArchiveReaderIntegrationTests.testStagingFreeSpaceReserveDoesNotQueryForMemory`
- `SingleFileArchiveReaderIntegrationTests.testStagingFreeSpaceReserveRechecksAfter256MiBAndClosesFailedSpill`

Exact failing assertion text observed before the fix (repeated identical assertions omitted):

```text
XCTAssertEqual failed: ("0") is not equal to ("1") - small spills need one free-space check
XCTAssertThrowsError failed: did not throw an error
XCTAssertEqual failed: ("0") is not equal to ("1") - spilling must query available temporary space
XCTAssertEqual failed: ("0") is not equal to ("2") - staging must recheck space after 256 MiB
```

## K4. Bound tar header read-ahead

Listing 64 members of 1 MiB each read 16,779,264 bytes with the default cursor. Headers now use a 4 KiB ByteReader; PAX and GNU L/K payloads use readByteRange directly. No per-byte work was added to body listing. The new test requires less than 512 KiB read during open, then verifies the final member contents. The existing integration and hardening suites cover extension metadata, sparse rejection, hard links, and recovery.

Files changed:

- `Sources/KaitoKit/Formats/Tar/TarReader.swift`
- `Tests/KaitoKitTests/TarHardeningTests.swift`
- `Tests/KaitoKitTests/Support/CountingByteSource.swift`

Tests added:

- `TarHardeningTests.testListingLargeMembersReadsOnlySmallHeaderWindows`

Exact failing assertion text observed before the fix (repeated identical assertions omitted):

```text
XCTAssertLessThan failed: ("16779264") is not less than ("524288") - tar listing must not prefetch large member bodies
```

## K5. Budget open-time 7z AES derivations

Six AES folders with distinct 16-byte salts and cycle power 8 performed six derivations despite a four-derivation test budget. ReadLimits.maxSevenZipHeaderKDFWork defaults to 4 * (1 << 24) SHA-256 rounds. One inout budget spans encoded-header and parsed-header decoding, including additional streams and password-provider retries. The nonescaping charge callback reaches the actual key-cache miss immediately before derive(); a rejected miss performs no derivation. Main entry streams remain lazy and use the unbudgeted entry path. Cache hits and direct-key mode consume no rounds. A task-local derivation observer counted actual calls in red and green runs. The field and observer existed for the red run, without enforcement. Further tests cover a shared encoded-header/additional-stream budget and default encrypted-fixture extraction.

Files changed:

- `Sources/KaitoKit/Core/ReadLimits.swift`
- `Sources/KaitoKit/Formats/SevenZip/SevenZipAES.swift`
- `Sources/KaitoKit/Formats/SevenZip/SevenZipReader.swift`
- `Sources/KaitoKit/Formats/SevenZip/SevenZipFolderPipeline.swift`
- `Tests/KaitoKitTests/SevenZipHardeningTests.swift`
- `Tests/KaitoKitTests/SevenZipIntegrationTests.swift`

Tests added:

- `SevenZipHardeningTests.testHeaderKDFWorkStopsBeforeFifthDistinctDerivation`
- `SevenZipHardeningTests.testHeaderKDFWorkAllowsSufficientBudget`
- `SevenZipHardeningTests.testHeaderKDFWorkChargesCacheMissesOnly`
- `SevenZipHardeningTests.testHeaderKDFWorkDoesNotChargeDirectKeys`
- `SevenZipHardeningTests.testHeaderKDFWorkDoesNotLimitRepeatedEntryStreams`
- `SevenZipHardeningTests.testHeaderKDFWorkIsSharedByEncodedHeaderAndAdditionalStreams`
- `SevenZipIntegrationTests.testHeaderKDFDefaultBudgetOpensAndExtractsEncryptedFixture`

Exact failing assertion text observed before the fix (repeated identical assertions omitted):

```text
XCTAssertThrowsError failed: did not throw an error
XCTAssertEqual failed: ("6") is not equal to ("4") - header KDF budget must stop before the fifth derivation
```

## K6. Drop failed 7z solid decoder state

A clean-room two-substream solid LZMA2 folder omits every kCRC digest. Its packed stream contains 16 valid bytes, an invalid control, and a valid continuation. Entry A failed, but the original coordinator kept its partially advanced decoder and entry B returned bytes without an error. The accessor also showed retained state after discard failed. Decoder failures now clear the retained decoder in read, discard, restart, backward-restart, and completion paths; the next request restarts from the factory and encounters the corruption again. Completion cleanup also covers the wrong-size guard. The internal reader accessor was added before the red run; no failure cleanup was present yet.

Files changed:

- `Sources/KaitoKit/Formats/SevenZip/SevenZipFolderPipeline.swift`
- `Sources/KaitoKit/Formats/SevenZip/SevenZipReader.swift`
- `Tests/KaitoKitTests/SevenZipHardeningTests.swift`

Tests added:

- `SevenZipHardeningTests.testSolidDecoderErrorDropsStateAndRejectsForwardEntryWithoutCRCs`
- `SevenZipHardeningTests.testSolidDiscardErrorDropsDecoderState`

Exact failing assertion text observed before the fix (repeated identical assertions omitted):

```text
XCTAssertFalse failed - failed solid decoder must be released
XCTAssertThrowsError failed: did not throw an error - forward entry must not reuse a failed solid decoder
XCTAssertFalse failed - failed solid discard must release its decoder
```

## K7. Verify UInt64.max size limits

The test opens one known-length and one unknown-length stored RAR5 member with maxEntrySize and maxTotalUncompressedSize both at UInt64.max. It reads the unknown member twice from offset zero, reads the known member, and interleaves partial and complete replays. Unknown sizes invoke both ArchiveOutputBudget.availableAdditionalSize and recordUnknownEntry. The test passed on its first run; no production arithmetic change was justified. There is no failing assertion to report for K7, and none was fabricated. Audit: total never exceeds limit; each previouslyRecorded size is included in total, so replayAllowance <= total and replayAllowance + (limit - total) <= limit, even at .max. recordUnknownEntry bounds additional before adding it. EntryStream bounds requested output by entrySizeLimit - bytesProduced; verifyUnknownLengthAtLimit probes one byte without computing limit + 1.

Files changed:

- `Tests/KaitoKitTests/ReaderAggregateLimitTests.swift`

Tests added:

- `ReaderAggregateLimitTests.testMaximumSizeLimitsAllowKnownUnknownAndReplayedEntries`

Baseline result: `Executed 1 test, with 0 failures (0 unexpected)`. No failing assertion was observed; production arithmetic was unchanged.

## K8. Update release documentation and verification record

The documentation tests first reported missing LZ4/LZMA aliases in both introductions, missing new limits in both integration-note languages, and the absent changelog link and record. Unreleased now has one Japanese bullet for each K1–K7, with reasons and the record link. README documents the defaults and scopes of both safety bounds, staged-source sharing, and cancellation. The verification index links this record.

Files changed:

- `CHANGELOG.md`
- `README.md`
- `Documentation/verification/README.md`
- `Documentation/verification/2026-09-19-release-review.md`
- `Tests/KaitoKitTests/ReleaseReviewDocumentationTests.swift`

Tests added:

- `ReleaseReviewDocumentationTests.testReadmeIntroductionsAndIntegrationNotesDocumentFormatsAndSafetyLimits`
- `ReleaseReviewDocumentationTests.testReleaseReviewRecordExistsAndIsLinkedFromChangelog`

Exact failing assertion text observed before the fix (repeated identical assertions omitted):

```text
XCTAssertTrue failed - Japanese introduction must list LZ4
XCTAssertTrue failed - Japanese introduction must list LZMA
XCTAssertTrue failed - Japanese introduction must list .lzma
XCTAssertTrue failed - Japanese introduction must list .tlz
XCTAssertTrue failed - English introduction must list LZ4
XCTAssertTrue failed - English introduction must list LZMA
XCTAssertTrue failed - English introduction must list .lzma
XCTAssertTrue failed - English introduction must list .tlz
XCTAssertTrue failed - Japanese integration notes must document stagingFreeSpaceReserve
XCTAssertTrue failed - Japanese integration notes must document maxSevenZipHeaderKDFWork
XCTAssertTrue failed - English integration notes must document stagingFreeSpaceReserve
XCTAssertTrue failed - English integration notes must document maxSevenZipHeaderKDFWork
XCTAssertTrue failed - changelog must link the release-review verification record
XCTAssertTrue failed - release-review verification record must exist
```

## RAR4 accepted limitation

RAR4 `-hp` / RAR3 header encryption has no cumulative header-KDF work budget. Each encrypted header block carries its own salt, so a legitimate large `-hp` archive performs one derivation per header. Applying the small cumulative 7z/RAR5-style bound would reject such archives. This remains an accepted limitation; no RAR4 code or behavior was changed.

## Verification commands and counts

Swift 6.4, Swift 6 language mode, arm64 macOS. The first literal `swift test` invocation could not compile the manifest because the outer sandbox disallowed `/Users/nagash/.cache/clang/ModuleCache`. Verification therefore uses writable caches and disables only SwiftPM's nested sandbox; the outer workspace restrictions remain in effect. No approval or permission changes were made.

Common flags on every successful build/test command:

```sh
export CLANG_MODULE_CACHE_PATH=/private/tmp/kaitokit-release-review-logs/clang-cache
export SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/kaitokit-release-review-logs/swift-cache
# Passed after `swift build` or `swift test`:
--disable-sandbox \
  --cache-path /private/tmp/kaitokit-release-review-logs/pm-cache \
  --config-path /private/tmp/kaitokit-release-review-logs/pm-config \
  --security-path /private/tmp/kaitokit-release-review-logs/pm-security
```

Focused runs (counts are test executions, including intentional red runs; repeated XCTest suite summaries are not counted again):

| Item | Baseline/red | Focused green | Log stems |
| --- | --- | --- | --- |
| K1 | 2 tests, 5 assertions failed | 2 passed | `K1-red`, `K1-green` |
| K2 | 1 test, 1 assertion failed | 1 passed | `K2-red`, `K2-green` |
| K3 | 3 tests, 3 assertions failed; cadence: 1 test, 2 assertions failed | 4 passed, then 1 passed with an ample-capacity case | `K3-red`, `K3-cadence-red`, `K3-green`, `K3-ample-green` |
| K4 | 1 test, 1 assertion failed | 44 passed (all TarIntegrationTests and TarHardeningTests) | `K4-red`, `K4-green` |
| K5 | 6 tests, 2 assertions failed | 6 passed, then 7 passed with the cross-stage test | `K5-red`, `K5-green`, `K5-green-extended` |
| K6 | 2 tests, 3 assertions failed | 3 passed, including existing completion/restart test | `K6-red`, `K6-green` |
| K7 | 1 passed immediately | Included again in final aggregate-limit suite | `K7-baseline` |
| K8 | 2 tests, 14 assertions failed | 2 passed | `K8-red`, `K8-green` |

Required final commands, using the common cache flags above:

```sh
swift build
swift build -c release
swift test --filter 'SingleFileArchiveReaderIntegrationTests|CompressedTarAliasTests|LZ4FrameTests|TarIntegrationTests|TarHardeningTests|SevenZipHardeningTests|SevenZip|ReaderAggregateLimitTests|ZipHardeningTests'
swift test --filter ReleaseReviewDocumentationTests
git diff --check
```

- Debug build: passed, no compiler warnings (`build-debug.log`).
- Required targeted filter: **220 tests passed**, zero failures and zero skips: 219 KaitoKit tests plus 1 compatibility test (`targeted-final.log`).
- Documentation filter: **2 tests passed**, zero failures (`K8-green.log`).
- Ample-capacity addition to K3's accepted-boundary test: **1 test passed** (`K3-ample-green.log`); production code was unchanged after the targeted suite.
- **20 new test methods; 309 total test executions** across all recorded runs, including intentional red tests and repetitions. Of these, 297 passed and 12 were intentionally failing pre-fix test executions (31 assertion failures). Build/setup failures executed no tests and are excluded.
- Release build: the ordinary scratch directory reached compilation/linking without warnings, but `GenerateDSYMFile` for `libKaitoKitDynamic.dylib.dSYM` failed with `error: Operation not permitted` (`build-release.log`). A fresh scratch-directory retry failed at the same step (`build-release-fresh.log`). The optimized release build **passed with zero warnings** after disabling debug-symbol generation (`build-release-no-debug-info.log`, 46.77 seconds):

  ```sh
  swift build -c release -debug-info-format none \
    --scratch-path /private/tmp/kaitokit-release-review-logs/release-build
  ```

  The common cache flags above were also applied. Ordinary dSYM generation remains unverified because the environment denies that operation.
- `git diff --check`: passed. No commit was created.
- The full suite is reserved for the orchestrator as requested.

## Verification scope and remaining limits

- K7 had no failing baseline; the test and arithmetic audit are the verification result.
- Standard release dSYM generation could not finish (`Operation not permitted`); debug and optimized release without debug symbols built without warnings.
- Free-space tests inject deterministic capacities and check descriptor cleanup. They do not deliberately exhaust the host volume; periodic checks are a reserve check, not an atomic disk-space reservation against other processes.
- No full-suite, sanitizer, Intel, or cold/network-volume benchmark was run in this task. K4 measures ByteSource bytes read deterministically.
- Full-suite results may be appended below by the orchestrator.

## Follow-up scope — K10–K13

This follow-up preserves the existing uncommitted K1–K8 work at HEAD `26b84ca`. The user reported that the full suite had passed before this follow-up; the approximate “1,2xx” count is not presented as a newly measured result. No commit was created, and neither sibling repository was modified. All four items have an observed failing test before their fixes. Follow-up logs are in `/private/tmp/kaitokit-k10-k13-logs/`. The runtime assertion text below is copied from those logs; repeated identical assertions are omitted. One K11 test compilation error was corrected before collecting its red run and executed no tests.

## K10. Bound StuffIt SFX candidate validation work

The reduced hostile MZ fixture repeats invalid StuffIt 5 candidates every 100 bytes over a 16 KiB scan window. Each candidate advertises an 8 KiB header; the metadata limit is 32 KiB. Before the fix, open read 1,442,784 bytes and eventually reported unsupported format. The regression requires the specific `limitExceeded("StuffIt SFX scan")` error and fewer than 128 KiB read, using bytes rather than elapsed time.

Candidate validation now shares one `ReadLimits.maxMetadataSize` byte budget (16 MiB by default) across classic, StuffIt 5 and StuffIt X candidates, including cursor read-ahead. The initial signature window remains separately bounded by `maximumSFXScanSize` (at most 1 MiB, plus 100 look-ahead bytes). Exhaustion escapes the candidate-skip catch. StuffIt 5 headers no larger than 64 KiB are CRC-checked during scanning. Larger structurally plausible headers are selected after their fixed 100-byte header and metadata limit checks; StuffIt5Parser then checks the complete header CRC once, before publishing entries. A bad large header therefore fails in the parser instead of restarting the candidate search.

A second fixture uses a valid 131,174-byte header with a long comment and auxiliary field. It demonstrates bounded scan reads, successful listing and exact extraction, and full-parser rejection when the final header byte is corrupted. Existing classic / StuffIt 5 / StuffIt X MZ cases still pass.

Files changed:

- `Sources/KaitoKit/Formats/StuffIt/StuffItSFX.swift`
- `Tests/KaitoKitTests/StuffItSFXTests.swift`

Tests added:

- `StuffItSFXTests.testStuffIt5SFXCandidateValidationHasACumulativeByteBudget`
- `StuffItSFXTests.testLargeStuffIt5SFXHeaderIsValidatedOnceByParser`

Exact failing assertion text observed before the fix:

```text
XCTAssertLessThan failed: ("131504") is not less than ("65536") - SFX scanning must defer large StuffIt 5 header CRCs to the parser
XCTAssertEqual failed: ("Optional(Unsupported archive format)") is not equal to ("Optional(Malformed archive: StuffIt 5 archive header CRC)")
XCTAssertEqual failed: ("Optional(Unsupported archive format)") is not equal to ("Optional(Read limit exceeded: StuffIt SFX scan)")
XCTAssertLessThan failed: ("1442784") is not less than ("131072") - StuffIt SFX candidate validation must have a cumulative byte budget
```

Focused counts: **2 red tests, 4 failed assertions; 5 green SFX tests, 0 failures** (`K10-red.log`, `K10-green.log`). The enormous 160 GB baseline workload was intentionally replaced by the smaller deterministic fixture. The limit bounds reads/CRC work, not wall-clock latency of an arbitrary ByteSource.

## K11. Verify StuffIt X auxiliary-only streams lazily

Auxiliary-only stream declarations are now checked against `maxEntrySize`, including encrypted streams. Their complete declared lengths still count against the aggregate uncompressed limit. All kind-3 owner associations are indexed before entry publication, independently of stream order. The owner stream is returned only after the auxiliary has been decoded through its real end and its integrity checks have succeeded. Successful verification uses `verifiedAuxiliaries`; reopening, password changes and changed read limits retain the existing cache-reset behavior. Failed verification is not cached. Encryption flags still depend on actual encrypted streams, so plain auxiliary owners remain unencrypted.

The hostile regression declares a 1 GiB Darkhorse auxiliary with a one-byte body containing the dictionary exponent but no range-code prefix. This deliberately produces a quick baseline failure, instead of expanding a gigabyte. Open must list its owner with less than 1 MiB read; requesting the owner's stream then reads the auxiliary and reports truncation before exposing the ordinary payload. Additional tests cover plain/encrypted declared-size boundaries, repeat/reopen verification counts, and repeated CRC failures before an ordinary owner stream is returned. The existing auxiliary-prefix test was updated to expect checksum failure on owner access rather than open.

Unsupported auxiliary codecs now fail on owner access through the same lazy path as encrypted auxiliaries; they are no longer eagerly attempted and silently noted in entry metadata.

Files changed:

- `Sources/KaitoKit/Formats/StuffItX/StuffItXReader.swift`
- `Tests/KaitoKitTests/StuffItXReaderTests.swift`

Tests added:

- `StuffItXReaderTests.testLargeDarkhorseAuxiliaryIsNotDecodedUntilOwnerRead`
- `StuffItXReaderTests.testAuxiliaryDeclaredLengthIsCheckedAgainstEntryLimit`
- `StuffItXReaderTests.testAuxiliaryVerificationIsCachedPerReader`
- `StuffItXReaderTests.testCorruptAuxiliaryFailsBeforeOwnerStreamIsReturned`

Test updated before the fix:

- `StuffItXReaderTests.testAuxiliaryUsesDeclaredStreamLengthAndIsNotPublished`

Exact failing assertion text observed before the fix:

```text
XCTAssertThrowsError failed: did not throw an error - declared auxiliary length must respect maxEntrySize
XCTAssertNoThrow failed: threw error "Checksum mismatch for entry -1"
XCTAssertGreaterThan failed: ("0") is not greater than ("0") - the first owner read must verify its auxiliary
XCTAssertGreaterThan failed: ("0") is not greater than ("0") - reopen must have an independent verification cache
XCTAssertNoThrow failed: threw error "Checksum mismatch for entry -1" - auxiliary integrity errors must be deferred until owner access
XCTAssertNoThrow failed: threw error "The archive is truncated" - listing must not decode an auxiliary-only Darkhorse stream
```

Focused counts: **5 red tests, 7 failed assertions; 24 green-run tests, 1 skipped, 0 failures** (`K11-red.log`, `K11-green.log`). The green filter covers StuffItXReaderTests, StuffItXCryptoTests and StuffItXFixtureTests, including resource forks, comments, ten historical containers and existing auxiliary SHA checks. The opt-in external crypto test is the skipped test. External JPEG and SMSSender oracle results are recorded below. Verification at owner access can still perform work up to the configured limits; this change specifically removes that decoding from open.

## K12. Recognize the .taz compressed-tar alias

`.taz` is now recognized alongside `.tar.Z` and `.tz`, using the existing case-insensitive filename matching and compress/tar staging path. The new fixture is a hand-built tar compressed by `/usr/bin/compress`, renamed to `.taz` and `.TAZ`. Both aliases list `folder/payload.txt`, extract the exact payload and reopen after unlink, with both an all-memory threshold and an immediate-spill threshold. README's Japanese table and English alias list include `.taz`.

Files changed:

- `Sources/KaitoKit/Reader/ArchiveReader.swift`
- `Tests/KaitoKitTests/CompressedTarAliasTests.swift`
- `README.md`

Tests added:

- `CompressedTarAliasTests.testTAZAliasListsTarMembersAndReopensAfterUnlink`

Exact failing assertion text observed before the fix:

```text
XCTAssertEqual failed: ("compress") is not equal to ("tar") - taz must be a compressed-tar alias
XCTAssertEqual failed: ("["archive.taz"]") is not equal to ("["folder/payload.txt"]") - taz must list tar members
XCTAssertEqual failed: ("compress") is not equal to ("tar") - TAZ must be a compressed-tar alias
XCTAssertEqual failed: ("["archive.TAZ"]") is not equal to ("["folder/payload.txt"]") - TAZ must list tar members
```

Focused counts: **1 red test, 8 failed assertions; 4 green compressed-tar alias tests, 0 failures** (`K12-red.log`, `K12-green.log`). The fixture generator was available; this test did not skip.

## K13. Document the follow-up fixes and verification

Unreleased has separate K10, K11 and K12 bullets covering the scan budget, lazy auxiliary verification and `.taz`. The compressed-tar alias lists were updated with K12, and this record extends the previous K1–K8 evidence without replacing it. The new documentation regression checks all three Unreleased items, the four follow-up sections, and the enumerated README aliases.

Files changed:

- `CHANGELOG.md`
- `Documentation/verification/2026-09-19-release-review.md`
- `Tests/KaitoKitTests/ReleaseReviewDocumentationTests.swift`

Tests added:

- `ReleaseReviewDocumentationTests.testFollowupReviewDocumentsSFXAuxiliaryAndTAZChanges`

Exact failing assertion text observed before the fix:

```text
XCTAssertTrue failed - Unreleased must document K10
XCTAssertTrue failed - Unreleased must document K11
XCTAssertTrue failed - Unreleased must document K12
XCTAssertTrue failed - verification record must cover K10
XCTAssertTrue failed - verification record must cover K11
XCTAssertTrue failed - verification record must cover K12
XCTAssertTrue failed - verification record must cover K13
```

Red count: **1 test, 7 failed assertions** (`K13-red.log`). Final documentation test counts are recorded below.

## Follow-up verification commands and counts

Swift 6.4, Swift 6 language mode, arm64 macOS. The same writable-cache flags documented above were used via `/private/tmp/kaitokit-k10-k13-logs/swift-check`; SwiftPM's nested sandbox was disabled while the outer workspace restrictions remained in force. No approval or permission change was requested.

Required commands:

```sh
swift build
swift test --filter 'StuffIt|CompressedTarAliasTests|SFX'
git diff --check
```

Additional focused commands:

```sh
swift test --filter StuffItSFXTests
swift test --filter 'StuffItXReaderTests|StuffItXCryptoTests|StuffItXFixtureTests'
swift test --filter CompressedTarAliasTests
swift test --filter ReleaseReviewDocumentationTests
```

- Debug build: **passed, no warnings** (`build-debug.log`).
- Required filter, final run: **169 tests, 9 skipped, 0 failures** (`targeted-final.log`); 160 test cases passed. This includes the new documentation test because its name contains SFX. An earlier run began before the K13 documentation edits and repeated its seven expected missing-document assertions: **169 tests, 9 skipped, 1 failing test / 7 failed assertions** (`targeted-before-docs.log`). All other tests passed in that run. The final run was made after the documentation fix.
- K13 documentation filter: **3 tests passed, 0 failures** (`K13-green.log`), including both existing K8 tests and the new follow-up test.
- `git diff --check`: **passed**. Changes remain uncommitted.

Focused red/green totals (skipped tests are included in XCTest's executed count):

| Item | Red tests / failed assertions | Focused green tests | Log stems |
| --- | --- | --- | --- |
| K10 | 2 / 4 | 5 passed | `K10-red`, `K10-green` |
| K11 | 5 / 7 | 24 run: 23 passed, 1 skipped | `K11-red`, `K11-green` |
| K12 | 1 / 8 | 4 passed | `K12-red`, `K12-green` |
| K13 | 1 / 7 | 3 passed | `K13-red`, `K13-green` |

**8 new test methods**, plus the updated existing auxiliary-prefix test. Across every follow-up test run, including the intentional red runs, the early documentation failure, repeated suites and the external run below: **387 test executions = 358 passed + 19 skipped + 10 failing pre-fix executions (33 failed assertions)**. Compilation/setup failures executed no tests and are excluded. These totals do not include the earlier K1–K8 runs or the user's separately reported full suite.

## Follow-up external oracles

The existing external tests were run with the same optimized-build workaround recorded for K1–K8 (`-debug-info-format none`). The release build completed in 111.07 seconds without warnings; all **4 selected tests passed, 0 skipped, 0 failures**, in 34.72 seconds (`external-oracles.log`). This follow-up did not retry ordinary dSYM generation.

For the existing inventory test, a temporary corpus directory contained an empty `cc0` directory and a `perf/SMSSenderPro3osx.sitx` symlink to the supplied fixture in this repository. No fixture bytes or sibling repositories were modified. The exact environment and selected tests were:

```sh
STUFFITX_JPEG_CORPUS=1 \
STUFFITX_JPEG_REPORT=k11-followup \
STUFFITX_CORPUS=/private/tmp/kaitokit-k10-k13-logs/smssender-corpus \
STUFFITX_VERIFY_STREAMS=1 \
STUFFITX_INVENTORY=k11-smssender-inventory.json \
STUFFIT_SLICE6_CORPUS=/Users/nagash/Github/KaitoKit/inbox/stuffit-corpus \
swift test -c release -debug-info-format none \
  --scratch-path /private/tmp/kaitokit-release-review-logs/release-build \
  --filter 'StuffItXJPEGTests.testCorpus|StuffItXJPEGTests.testHistoricalArchives|StuffItXCorpusTests.testExternalInventory|StuffItXCryptoTests.testExternalEncryptedStreamsAndDESCompressedCounterparts'
```

The common writable-cache flags were also applied.

- `StuffItXJPEGTests.testCorpus`: **292 streams = 280 byte-for-byte matches + 12 expected unsupported sampling arrangements, 0 mismatches or other errors**. Verified the status counts in `.build/jpeg-k11-followup.json`, rather than counting printed lines alone.
- `StuffItXJPEGTests.testHistoricalArchives`: **7 historical archives**, including the 2009/2010 MZ installers and back-compatibility stubs, open and extract; every published non-directory entry was read. Their 220-byte JPEG matches SHA-256 `e514232511df1a4f4221a75c27523518c3c62a2fe6470fa56e430364428eecd1`. The eighth fixture still rejects the known unsupported Root recovery layer. Results are in `.build/jpeg-historical.json`.
- `StuffItXCryptoTests.testExternalEncryptedStreamsAndDESCompressedCounterparts`: **10 encrypted archives, 38 final-stream CRC matches, 1 catalog compressed-input match and 1 JPEG compressed-input match**, including the DES compressed counterpart.
- `StuffItXCorpusTests.testExternalInventory`: SMSSenderPro's **63 nonempty decoded forks** (62 data, 1 resource) completed without errors; all four English-preprocessed streams remain present. Fresh results are in `.build/k11-smssender-inventory.json`.

The freshly built CLI was then run through both SHA views:

```sh
/private/tmp/kaitokit-release-review-logs/release-build/out/Products/Release/kaito \
  sha inbox/stuffit-corpus/perf/SMSSenderPro3osx.sitx
/private/tmp/kaitokit-release-review-logs/release-build/out/Products/Release/kaito \
  sha inbox/stuffit-corpus/perf/SMSSenderPro3osx.sitx --forks
```

Both commands exited 0. Using the existing `Tests/Fixtures/stuffit/verify_slice4_corpus.py` row parser, the multiset of `(length, SHA-256, escaped name)` matched **all 95 supplied oracle rows**, including 62 nonempty data entries. The `--forks` view returned 96 rows; all 63 nonempty `(length, SHA-256)` pairs matched the fresh coordinator inventory. This reuses the existing oracle comparison rules; the old complete slice-4 script, which expects now-supported codecs to fail, was not run wholesale. The comparison script and results are retained locally as `verify-smssender.py`, `smssender-verification.log`, `smssender-sha.log`, `smssender-forks.log` and `smssender-summary.json` under the follow-up log directory. These CLI/oracle comparisons are additional checks, not additional XCTest methods.

## Follow-up verification limits

- All requested follow-up fixtures were available. The 292-stream corpus, historical SFX archives and SMSSenderPro checks were executed, not skipped.
- The required default filter reports 9 opt-in skips. Its inventory, crypto, JPEG-corpus and historical-JPEG tests were subsequently run explicitly above. LHA/RAR4 external SFX fixtures, the opt-in 32 MiB Deflate distance case, the JPEG mutation campaign and the full-size JPEG benchmark remain outside this follow-up's verification.
- The supplied SMSSenderPro data oracle has no independent resource-fork SHA. That fork passed its stored integrity check and the CLI/coordinator consistency comparison; independent resource-fork SHA equivalence cannot be claimed.
- The 12 unsupported JPEG sampling arrangements and the historical Root recovery layer remain accepted pre-existing limitations; their expected rejections passed.
- The reduced K10 hostile fixture avoids executing hundreds of gigabytes of redundant baseline work. The K11 tiny truncated Darkhorse fixture proves lazy decoding without intentionally expanding 1 GiB. Neither is a wall-clock benchmark.
- Ordinary release dSYM generation, the full suite after these follow-up edits, sanitizers and Intel execution were not run. The required debug build and optimized external tests passed on arm64. The prior user-reported full-suite result is not substituted for a new run.

## K9. Share parsed state on reopen

This follow-up preserves the existing K1–K8 and K10–K13 changes, stays at HEAD `26b84ca`, and makes no commit or changes to either sibling repository. All four format tests were written and failed before production changes. Logs are under `/private/tmp/kaitokit-k9-logs/`. A test API-label compilation error was corrected before collecting the runtime red result; compilation/setup failures executed no tests.

Each reader now provides `reopened(options:) -> sending Reader`. `ArchiveReader.reopen()` passes these fresh readers through the existing sharing initializer, retaining the parsed entry arrays and source handles. The parsed records are Sendable value types; arrays and dictionaries share immutable backing storage through Swift COW, without introducing shared decoder state or unchecked Sendable conformance. Published entries and name encoding are immutable lets.

| Format | Shared immutable state | Fresh state |
| --- | --- | --- |
| ZIP | ByteSource, central-directory offset, records, entries, encoding, local-header ordering and inverse positions; split-volume disk layout in the wrapper | Empty local-header cache, both local/raw validation positions, current password value, empty AES derived-key cache |
| tar | ByteSource, records, entries and encoding; compressed tar retains its existing staged source | Each requested EntryStream and wrapper budget/extraction provenance; TarReader has no retained decoder or cursor after parsing |
| 7z | Exact source (including SFX rebasing), parsed stream/folder/substream descriptions, packed ranges, records and entries | Empty solid-coordinator dictionary, empty packed-stream verification set, new AES key cache, current password value and per-reader limits |
| LHA | ByteSource, absolute member offsets/records, entries and encoding (including SFX/recovery results) | Each requested decompressor and wrapper budget/extraction provenance; no retained per-member decoder exists |

ZIP's local cache allocation is deferred until first use, retaining the existing indexed-array access pattern without allocating an entry-sized array on reopen. Eager local validation at initial open remains controlled by `lazyLocalHeaders` and recovery options. Reopened readers validate their own local records when first accessed. The wrapper's declared output total is validated at initial open and stored as an immutable scalar. Reopen creates a new ArchiveOutputBudget from that scalar, with fresh unknown-entry accounting and terminal-error state, so it neither repeats the entry sum nor copies runtime consumption. RAR's existing sharing paths also use this fresh budget snapshot; their format readers were not changed.

Split-volume ZIP **uses the sharing path**. Its immutable ZipDiskLayout is preserved by the sharing initializer so raw-record access remains available over the concatenated source. The existing split-volume tests cover raw records, boundaries, eager/lazy options, encrypted members and reopen after unlink. Ordinary byte-split sources, SFX-adjusted sources and compressed-tar staging retain their previous source ownership.

Passwords are copied from the public reader's current value, including changes made since open. Key material is freshly derived on entry access, independently in each clone. An already parsed encrypted 7z header is not decrypted again: resetting/changing the password on such a reader is checked when an encrypted entry is accessed, rather than by reparsing the header during reopen. Initial-open header password/provider validation remains unchanged. Tests cover correct/wrong/cleared/restored entry passwords and independence of older clones.

Files changed for K9:

- `Sources/KaitoKit/Reader/ArchiveReader.swift`
- `Sources/KaitoKit/Formats/Zip/ZipReader.swift`
- `Sources/KaitoKit/Formats/Tar/TarReader.swift`
- `Sources/KaitoKit/Formats/SevenZip/SevenZipReader.swift`
- `Sources/KaitoKit/Formats/LHA/LHAReader.swift`
- `Sources/KaitoKit/Formats/LHA/LHAHeaderParser.swift` (Sendable value-record conformance)
- `Tests/KaitoKitTests/ReopenSharingTests.swift`
- `CHANGELOG.md`
- `Documentation/verification/2026-09-19-release-review.md`

Tests added (all in ReopenSharingTests):

- `testZIPReopenShares10kParsedEntries`
- `testZIPReopenShares100kParsedEntries`
- `testZIPReopenHasFreshLocalCachesAndCarriesCurrentPassword`
- `testTarReopenSharesParsedEntries`
- `testLHAReopenSharesParsedEntries`
- `testSevenZipSolidReopenStartsIndependentCoordinator`
- `testSevenZipNonSolidReopenHasFreshPackVerification`
- `testSevenZipEncryptedReopenRetainsPasswordWithFreshKeys`
- `testDocumentationRecordsK9SharingAndTimings`

The 10k ZIP has seven-byte stored members. The existing 100k ZIP64 scale helper creates empty stored members. Both fixtures are built in memory, and ContinuousClock measures open and a single reopen, excluding fixture construction and member reads. The original first-member cache is warmed before reopen. CountingByteSource must report zero reads, entries/encoding must match, reads through both readers must be byte-exact, and another reopen must also read zero bytes. The CI assertion is the deliberately loose 50 ms absolute threshold; measured relative improvements are recorded below. The 100k fixture may skip if its construction exceeds 10 seconds in Debug; it did not skip in these measurements. These are local warm-process measurements, not cold-disk benchmarks.

Exact failing assertion text from the first Debug run (duplicates omitted):

```text
XCTAssertTrue failed - Unreleased must document K9 parsed-state sharing
XCTAssertTrue failed - verification record must cover K9 and reopen timings
XCTAssertEqual failed: ("1329267") is not equal to ("0") - lha reopen must share parsed state without source reads
XCTAssertLessThan failed: ("0.100161 seconds") is not less than ("0.05 seconds") - lha reopen must finish within 50 ms
XCTAssertEqual failed: ("1329267") is not equal to ("0") - lha successive reopen must not parse
XCTAssertEqual failed: ("428") is not equal to ("0") - encrypted 7z reopen must reuse its parsed header
XCTAssertEqual failed: ("608") is not equal to ("0") - encrypted 7z reopen must reuse its parsed header
XCTAssertEqual failed: ("2") is not equal to ("1") - 7z reopen must not derive header keys
XCTAssertEqual failed: ("345") is not equal to ("0") - 7z non-solid reopen must not parse
XCTAssertEqual failed: ("345") is not equal to ("0") - 7z successive reopen must not parse
XCTAssertEqual failed: ("350") is not equal to ("0") - 7z solid reopen must not parse
XCTAssertEqual failed: ("350") is not equal to ("0") - 7z successive reopen must not parse
XCTAssertEqual failed: ("10242048") is not equal to ("0") - tar reopen must share parsed state without source reads
XCTAssertLessThan failed: ("0.501831458 seconds") is not less than ("0.05 seconds") - tar reopen must finish within 50 ms
XCTAssertEqual failed: ("10242048") is not equal to ("0") - tar successive reopen must not parse
XCTAssertEqual failed: ("420") is not equal to ("0") - ZIP cached-reader reopen must not read headers
XCTAssertEqual failed: ("1266") is not equal to ("0") - encrypted ZIP reopen must not parse
XCTAssertEqual failed: ("1141") is not equal to ("0") - encrypted ZIP reopen must not parse
XCTAssertEqual failed: ("15566713") is not equal to ("0") - zip reopen must share parsed state without source reads
XCTAssertLessThan failed: ("0.888714584 seconds") is not less than ("0.05 seconds") - zip reopen must finish within 50 ms
XCTAssertEqual failed: ("15566713") is not equal to ("0") - zip successive reopen must not parse
XCTAssertEqual failed: ("625475") is not equal to ("0") - zip reopen must share parsed state without source reads
XCTAssertLessThan failed: ("0.089934666 seconds") is not less than ("0.05 seconds") - zip reopen must finish within 50 ms
XCTAssertEqual failed: ("625475") is not equal to ("0") - zip successive reopen must not parse
```

Initial Debug run: **9 tests failed, 24 assertion failures**. The optimized ZIP baseline ran **2 failing tests, 5 failed assertions**; the additional optimized timing failure was:

```text
XCTAssertLessThan failed: ("0.200430375 seconds") is not less than ("0.05 seconds") - zip reopen must finish within 50 ms
```

First post-fix behavior run: **8 tests passed, 0 failures**. Every zero-read assertion passed. The non-solid 7z test additionally observes 64 bytes for a 32-byte copied member: 32 for its fresh packed CRC verification and 32 for payload output. The solid test keeps an original stream partially read while a clone reads other members, then finishes the original stream exactly. The AES derivation observer shows zero new header derivations at reopen, a new entry derivation in the clone, and a still-warm original key cache. ZIP raw-record checks show a fresh clone cache and an unchanged original cache. Further password-reset cases and final suite counts are recorded below.

K9 Debug timings in milliseconds (single measured reopen):

| Format / entries | Before open | Before reopen | After open | After reopen | Reopen bytes before → after |
| --- | ---: | ---: | ---: | ---: | ---: |
| ZIP / 10,000 | 91.603458 | 89.934666 | 89.608625 | 0.001750 | 625,475 → 0 |
| ZIP64 / 100,000 | 883.925916 | 888.714584 | 889.587750 | 0.002667 | 15,566,713 → 0 |
| tar / 10,000 | 501.479750 | 501.831458 | 488.433042 | 0.001584 | 10,242,048 → 0 |
| LHA / 10,000 | 101.422792 | 100.161000 | 104.225500 | 0.002042 | 1,329,267 → 0 |

The optimized pre-fix measurements were ZIP 10k open **19.973084 ms**, reopen **20.188667 ms**, and ZIP64 100k open **208.136833 ms**, reopen **200.430375 ms**. Final optimized after measurements and verification counts follow.

### K9 optimized measurements

The optimized build uses `-c release -debug-info-format none` and the same scratch directory and cache flags as the earlier verification. The debug-symbol workaround is the previously recorded sandbox restriction, not a change to production optimization. All **9 new tests passed**, with no skips (`K9-release-green.log`).

| Stored ZIP fixture | Before open, ms | Before reopen, ms | After open, ms | After reopen, ms | Reopen bytes after |
| --- | ---: | ---: | ---: | ---: | ---: |
| 10,000 seven-byte members | 19.973084 | 20.188667 | 20.746667 | 0.000667 | 0 |
| 100,000 empty ZIP64 members | 208.136833 | 200.430375 | 207.942000 | 0.001625 | 0 |

The measured 100k reopen is well below 5 ms and below 5% of open. No per-entry work remains in this reopen path; the next member read still pays for its own local-header validation/cache allocation. Optimized tar 10k open/reopen measured **29.200541 / 0.000834 ms**, and LHA 10k **30.870458 / 0.001250 ms**, both with zero reopen reads. Their comparable before/after measurements are the Debug rows above; the optimized red run selected only the ZIP scale cases. Very small times are single ContinuousClock samples and should not be interpreted as stable microbenchmarks.

### K9 final verification

The final Debug regression filter selected all affected-format test classes and every test class in a file containing `reopen(...)` or a password-named test method, plus raw-record, aggregate-budget and documentation coverage. Its 64 classes include existing password/provider/header-encryption cases, parsed-name comparisons, active/backward solid reads, recovery, source lifetime after unlink, extraction provenance, ZIP split volumes and compatibility snippets.

**853 tests executed: 817 passed, 36 skipped, 0 failures** (`regression-final.log`). This is 847 KaitoKit tests and 6 compatibility tests. All 9 new methods passed here and in the optimized run. ZIP split-volume coverage was **28 passed**; no split-volume fallback was required. The original RAR unknown-size/reopen budget test passed after the wrapper budget change.

| Format | New Debug red tests / assertion failures | New tests in final run | Existing format classes in final run |
| --- | --- | --- | --- |
| ZIP | 3 / 9 | 3 passed | 166 run: 165 passed, 1 skipped, 0 failures (includes ZIP compatibility) |
| tar | 1 / 3 | 1 passed | 44 passed, 0 failures; compressed-tar/staging cases also ran in shared suites |
| 7z | 3 / 7 | 3 passed | 75 passed, 0 failures |
| LHA | 1 / 3 | 1 passed | 88 run: 67 passed, 21 optional-corpus skips, 0 failures |
| K9 documentation | 1 / 2 | 1 passed | 3 existing release-review documentation tests passed |

After the fix there is **no failing assertion text** for any format: each counting assertion observed **0 bytes** at reopen and successive reopen, with matching entries and exact payload reads. All new original-cache/key/coordinator independence assertions passed. The 10k and 100k fixtures did not skip. Across all K9 runs, including the pre-fix runs and repeated focused tests: **881 test executions = 834 passed + 36 skipped + 11 intentionally failing pre-fix executions (29 assertion failures)**. Compilation/setup failures are excluded. No result from the earlier K1–K8 / K10–K13 work is counted again.

Commands (the existing writable-cache flags documented above were applied by `swift-check`):

```sh
swift build
# Before production changes: 9 failing tests / 24 assertions.
swift test --filter ReopenSharingTests
# Optimized before: 2 failing ZIP scale tests / 5 assertions.
swift test -c release -debug-info-format none \
  --scratch-path /private/tmp/kaitokit-release-review-logs/release-build \
  --filter 'ReopenSharingTests.testZIPReopenShares'
# First after: 8 passing behavior tests, before the documentation update.
swift test --filter 'ReopenSharingTests.testZIP|ReopenSharingTests.testTar|ReopenSharingTests.testLHA|ReopenSharingTests.testSevenZip'
# Optimized final: 9 passed.
swift test -c release -debug-info-format none \
  --scratch-path /private/tmp/kaitokit-release-review-logs/release-build \
  --filter ReopenSharingTests
# Final regression: 853 executed, 36 skipped, 0 failures.
swift test --filter 'ArReaderTests|CLISmokeTests|CabLZXTests|CabReaderTests|CompressedTarAliasTests|CpioReaderTests|EmptyLHATests|EntryStreamUnknownSizeTests|FileByteSourcePermissionTests|ISOReaderTests|KaitoArchiveZipConfigurationTests|LHABoundedWindowTests|LHACompatibilityCorpusTests|LHAHardeningTests|LHAIntegrationTests|LHAMacBinaryTests|LHAMethodCorpusTests|LHASFXTests|LZ4FrameTests|LZ4LegacyTests|MigrationGuideSnippetCompileTests|RAR4HeaderEncryptionTests|RAR4ReaderTests|RAR4VolumeTests|RAR5CheckedInFixtureTests|RAR5HeaderEncryptionTests|RAR5PasswordCompatibilityTests|RAR5ReaderTests|RAR5RecoveryTests|RAR5SFXTests|RAR5VolumeTests|RARCommonPrimitiveTests|RARPasswordCompatibilityTests|RawEntryRecordTests|ReaderAggregateLimitTests|ReleaseReviewDocumentationTests|ReopenSharingTests|RpmReaderTests|SevenZipFilterTests|SevenZipHardeningTests|SevenZipIntegrationTests|SevenZipSFXIntegrationTests|SevenZipSwapTests|SingleFileArchiveReaderIntegrationTests|SingleFileFormatTests|SplitVolumeTests|StuffItSlice2CryptoTests|StuffItXCryptoTests|StuffItXReaderTests|SymbolicLinkExtractionTests|TarHardeningTests|TarIntegrationTests|XarReaderTests|ZipCodecAuditRegressionTests|ZipCodecByteSourceBoundaryTests|ZipCompatibilityRobustnessTests|ZipDifferentialTests|ZipEncryptionPrimitiveTests|ZipHardeningTests|ZipIntegrationTests|ZipModernMethodTests|ZipPPMdTests|ZipSplitVolumeTests|ZstdTests'
git diff --check
```

Debug build and optimized test build passed without compiler warnings. `git diff --check` passed, and the new test/record files were checked for trailing whitespace separately. The complete pre-K9 verification record and all prior diffs outside the K9 shared files were verified unchanged. No commit was created.

### K9 verification limits

- The 36 skipped regression tests were optional Ar/Cab/Cpio/LHA/RAR4/StuffIt X corpus or oracle checks, plus one Info-ZIP differential fixture because the installed Info-ZIP lacks bzip2 generation. The seven-zip-generated bzip2 and other ZIP differential checks passed. The 21 LHA skips are external-corpus checks, not the new LHA sharing test. Their identities/reasons are in `regression-final.log`.
- A fresh derived-key cache intentionally makes the clone pay its own first-entry KDF cost. Reusing a parsed encrypted 7z header changes the point at which a newly wrong/cleared password is rejected: entry access rejects it; reopen no longer re-decrypts that header. This behavior and correct-password carry-over are covered for both encrypted and unencrypted headers. Initial-open password/provider tests passed.
- The first ZIP local-header/raw-record access still allocates its own cache and validates the necessary preceding ranges. This work was not shifted into the reopen timing measurement.
- The 100k fixture contains empty stored members; 10k ZIP/tar/LHA fixtures contain seven-byte members. The timing table is a reproducible local warm-process sample, not a statistical performance guarantee or a cold/network-volume benchmark.
- The entire unfiltered suite, sanitizers, Intel execution and normal release dSYM generation were not run for K9. Debug and optimized arm64 builds, the 9-test optimized suite and the 853-test regression filter passed. The previously reported dSYM sandbox restriction remains in effect; optimized measurements used the existing no-debug-symbol workaround.

## オーケストレータによる全件検証（2026-09-19）

- K1–K8 適用後: `swift test` 1,215 件、45 skip、失敗 0（7m57s）+ Compat 24 件。
- K9–K13 適用後: `swift test` **1,232 件、45 skip、失敗 0**（7m38s）+ Compat 24 件、失敗 0。
- 修正前ベースライン: 1,195 件、45 skip、失敗 0。
- Release の bench harness（scratchpad の SwiftPM package、KaitoKit を path 依存）での実測:
  100,000 項目 stored ZIP は open 230〜242 ms、`reopen()` は K9 前 220 ms → K9 後 0.0 ms（3 回とも）。
  256 MiB（乱数）の tar.gz は open 54〜78 ms、`reopen()` は K1 後 0.0 ms。
- 受け入れたトレードオフ: StuffIt X の補助 stream は open ではなく所有 entry の読み出し時に検証する（K11）。
  RAR4 の `-hp` header ごとの KDF は形式上の制約として予算化しない（K5 の記録どおり）。
  `.max` の上限で開く利用側（KaitoFinder）では、圧縮 tar の一時展開は `stagingFreeSpaceReserve`（既定 1 GiB）だけが上限になる（K3）。

### ASan / UBSan 変異テスト（2026-09-19、オーケストレータ）

`Scripts/fuzz/run-mutants.sh`（`.build-asan`、`kaito sha`、timeout 8 s）で、今日の変更と `26b84ca` の追加を通る seed を使った。
- 平文 seed 26 本（`Tests/Fixtures/lz4-frame` の 16 本、`sevenzip-swap` の plain 2 本、`stuffit` の SFX/classic/sitx 6 本、
  `singlefile` の alone.lzma / tar.Z）: **400 変異、crash 0、hang 0、sanitizer 所見 0**。
- 暗号化 seed 2 本（`sevenzip-swap` の AES、`--password KaitoFixture`。K5 の KDF 予算と K6 の coordinator の解放を通る）:
  **120 変異、crash 0、hang 0、sanitizer 所見 0**。
2026-09-16 の 399 変異は今日の decoder（LZ4、Swap、XZ validator、ZIP 20/95）と K1–K13 の前のものなので、別に記録する。
