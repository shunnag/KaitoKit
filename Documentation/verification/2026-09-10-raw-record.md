# ZIP entry の生レコード範囲の検証（2026-09-10）

## 1. 変更範囲と公開 API

開始点は `main` / `db2c5d0`（0.3.0、変更なし）。GyoshukuKit の `design.md` §7 に従い、
既存 entry を再圧縮せず移動するための取得 API だけを追加した。バージョンは従来の
CHANGELOG 節の規約に従い、先頭に 0.4.0 を追加した。依存、Swift 6 language mode、
macOS 26.0 の deployment target は変更していない。

```swift
public struct RawEntryRecord: Sendable {
    public let recordRange: Range<UInt64>
    public let payloadRange: Range<UInt64>
    public let formatSpecific: [String: String]
}

// ArchiveReader の追加メソッド
public func rawRecord(of entry: ArchiveEntry) throws -> RawEntryRecord?
```

`recordRange` は local header・名前・extra・payload・必要な data descriptor の全体。
`payloadRange` は保存済み圧縮 payload のみ。どちらも source の先頭からの絶対 offset で、
SFX prefix がある場合もその分を含む。暗号化 ZIP の payload は暗号ヘッダ、salt、password
verifier、認証コードなどの保存済み envelope を含み、復号後の byte の範囲ではない。

ZIP の `formatSpecific` は既存の `ArchiveEntry.formatSpecific` を保持し、以下を加える。

| キー | 値 |
| --- | --- |
| `crc32` | CD に保存された CRC。`0x` + 8 桁の小文字 16 進数。AE-2 では `0x00000000` |
| `headerMethod` | ヘッダに保存された方式番号の 10 進数。AES は `99`。既存の `method` は実際の圧縮方式 |
| `hasDataDescriptor` | `"true"` / `"false"` |
| `isZIP64` | entry の local または central に ZIP64 extra があれば `"true"`、なければ `"false"` |

既存の `flags` は `0x` + 4 桁の 16 進数、`encryption` は `none` / `ZipCrypto` /
`AES-128` / `AES-192` / `AES-256`。暗号化でも password provider を呼ばない。
entry の所属確認は通常の `read` と同じ `ArchiveReader.validate` を通る。

> **Scope and API**
>
> Starting from clean `main` at `db2c5d0` (0.3.0), this adds only the raw-record accessor and its
> Sendable result, following GyoshukuKit design §7. Version 0.4.0 is recorded at the top of
> CHANGELOG; dependencies, Swift 6 mode and the macOS 26 deployment target are unchanged.
> The signatures above are the complete public addition. Both ranges use absolute source offsets,
> including any SFX prefix. The record includes the local header, name, extra fields, stored payload
> and required descriptor. An encrypted payload range includes its stored encryption envelope.
> Metadata retains the existing entry fields, including encryption and hexadecimal flags, and adds
> stored CRC, header method, descriptor presence and entry ZIP64 status. Booleans are lowercase
> strings. AES keeps the actual compression method in `method` and reports `99` in `headerMethod`.
> No password is requested; entry identity uses the same validation as normal reads.

## 2. 対応形式と範囲の検証

| 対象 | 戻り値・理由 |
| --- | --- |
| ZIP / ZIP64、SFX prefix 付き ZIP | 完全な entry は検証した範囲を返す。descriptor の署名有無と幅を解析する |
| ZipCrypto / WinZip AES ZIP | 保存された暗号 byte は移動できるため範囲を返し、暗号情報を付ける |
| `isIncomplete` entry | 形式によらず `nil`。復旧時の未検証 extent を公開しない |
| 7z（solid / non-solid） | `nil`。solid folder の byte は entry ごとに独立していない。non-solid の生レコード対応も未実装 |
| RAR4 / RAR5 | `nil`。生レコード移動の対応を追加していない |
| tar / LHA | 今回は `nil`。形式ごとの完全なレコード移動の検証は追加していない |
| ar / cpio / ISO / CAB / RPM / xar / gzip / bzip2 / xz / LZMA / compress | `nil`。ZIP 以外の実装は内部 `FormatReader` の既定値を使う |

descriptor の解釈は [PKWARE APPNOTE 6.3.10](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT)
§4.3.9 / §4.5.3 を参照した。entry の ZIP64 extra の存在でサイズ欄の幅を選ぶ。
書庫全体の ZIP64 EOCD や version needed だけを根拠にしない。署名なしは 12 / 20 byte、
署名ありは 16 / 24 byte、bit 3 がなければ追加は 0 byte。CRC 自体が `0x08074b50` でも、
CRC と両サイズの全体を照合して署名と区別する。解釈が複数一致する場合は拒否する。

`validateEntryRanges` に descriptor を含む経路を追加し、既存の local header 順序、
offset 加算、重複 header と payload の重なり検出を共用する。前方の全 entry も順に
調べるので、CD の順序や API の呼出順が違っても、前の descriptor との重なりを見逃さない。
descriptor を読む上限は source 長、CD 開始、次の local header の最小値。
追加の byte 読取は一件あたり最大 24 byte で、payload の走査・復号・展開は行わない。

通常の payload 範囲検証と raw 検証は進捗を別に保持する。従来の一覧・open・read が
descriptor を検証しない挙動を維持し、raw API だけが descriptor の不一致や
local / central の bit 3 不一致を拒否する。AE-2 も optional な検証用 CRC ではなく、
CD の保存値 0 を descriptor と照合する。

> **Supported formats and validation**
>
> Complete ZIP entries, including ZIP64, SFX and supported encryption, return validated ranges.
> Incomplete entries and every non-ZIP format return nil. Solid 7z data is shared across entries;
> non-solid 7z, RAR, tar, LHA and other formats have no raw-record implementation in this change.
> Per APPNOTE §4.3.9 and §4.5.3, entry ZIP64 extras determine descriptor width, independently of
> archive-wide ZIP64 end records or extraction version. The optional signature and all descriptor
> fields are checked, including when the CRC itself equals the signature. Ambiguous matches fail.
> The existing range-validation loop checks earlier local records as well as the requested entry,
> bounds descriptor reads before the next record, central directory and source end, and reads at
> most 24 additional bytes per entry. Separate progress caches preserve normal open/read behavior.
> Only the new accessor rejects bad descriptors or disagreement between local and central bit 3.
> AE-2 descriptors are compared against the stored central CRC of zero.

## 3. 新規 XCTest

`RawEntryRecordTests` の 20 件。主な ZIP 入力は既存の `HandZipEntry` と
`RawRecordArchiveBuilder` で byte 表から構成した。7z は Copy coder 一つの folder に
二つの substream を置き、RAR は既存の `RAR5TestSupport` を使う。第三者実装の source は
参照していない。実機の `ditto` と Info-ZIP は外部 fixture 作成・照合のみに使う。

| テスト名 | 確認内容 |
| --- | --- |
| `testRawZIPRecordsRoundTripAfterReorderingAndDeletion` | stored、deflate、4 descriptor 形態、空 directory の 6 件を別ファイルへ逆順コピー。3 件への削除も実行し、CD を新 offset で再構築。全 record byte・展開 byte の一致と `unzip -t` 成功 |
| `testZIP32DescriptorsWithAndWithoutSignature` | 12 / 16 byte の正確な終端、lazy / eager、公開 metadata |
| `testZIP64DescriptorsUseEightByteSizesForSmallEntries` | 20 / 24 byte の終端。local / central 両方、local のみ、central のみの ZIP64 extra |
| `testZIP64ExtraWithZeroLocalSizesStillUsesWideDescriptor` | local の 32-bit size 欄が 0 でも ZIP64 extra から幅を判定 |
| `testSFXOffsetsAreAbsoluteAndZIP64EndDoesNotWidenZIP32Descriptor` | 1,024 byte の SFX prefix、ZIP32 / ZIP64 EOCD、version needed 4.5 の ZIP32 descriptor |
| `testDescriptorCRCEqualToSignatureIsNotMistakenForSignature` | 実 CRC が署名値になる payload で、署名有無 × ZIP32/64 の 4 ケース |
| `testMalformedDescriptorThrowsWithoutChangingReadBehavior` | CRC、両サイズ、ZIP64 上位 32 bit の改変を拒否。通常読取を前後で確認し、検証済みキャッシュがあっても raw を拒否 |
| `testTruncatedDescriptorsCannotConsumeCentralDirectoryBytes` | 全 4 形態を descriptor 内の各 byte で切り詰め、CD の byte を descriptor として使わない |
| `testDescriptorCannotOverlapAnotherEntryInEitherRequestOrder` | 次 entry の offset が descriptor 内を指す場合、両呼出順で拒否 |
| `testRawRangesReusePayloadMetadataAndAliasValidation` | payload の重なり、local metadata の過大長、local header の別名参照を既存検証で拒否 |
| `testDescriptorFlagDisagreementOnlyRejectsRawRecord` | local / central の bit 3 の不一致は raw のみ拒否 |
| `testDittoDataDescriptorsRoundTrip` | 実機 `ditto -c -k --norsrc --noextattr` の 2 descriptor を含む record を逆順に移動し、KaitoKit と `unzip -t` で往復確認 |
| `testEncryptedZipCryptoRecordMovesWithoutRequestingPassword` | Info-ZIP の暗号化 record を移動。password provider を呼ばず、移動後は KaitoKit と `unzip -P … -t` で検証 |
| `testEncryptedAE2RecordPreservesEnvelopeAndZeroStoredCRC` | AE-2 の envelope 全体・保存 CRC 0・method 99 を保持し、KaitoKit で移動後の認証と内容を確認。descriptor の非 0 CRC を拒否 |
| `testIncompleteRecoveryEntryReturnsNil` | 実際に payload を切り詰めて recovery で開いた entry が nil |
| `testSolidSevenZipEntryReturnsNil` | 同じ solidGroup の 2 entry が nil、既存の読取は成功 |
| `testRAREntryReturnsNil` | クリーンルーム RAR5 entry が nil、読取は成功 |
| `testTarLHAAndOtherUnimplementedFormatsReturnNil` | tar / LHA / ar が nil、読取は成功 |
| `testRawRecordValidatesEntryIdentity` | 別の entry の値と範囲外 index を notFound で拒否 |
| `testRawRecordSupportsShortByteSourceReads` | 1 回 3 byte しか返さない source でも ZIP64 descriptor を正しく読む |

共通の確認では record 先頭の `PK\x03\x04`、次の local record / CD と一致する終端、
source 内の包含、繰り返し取得を assert する。deflate の `payloadRange` は単独の decoder に
渡し、`read(entry)` の内容と照合する。descriptor のない entry の範囲も往復テストに含む。
再構築では local byte をコピーするだけで、再圧縮はしていない。CD 順と local 順を変え、
CD の最後から raw API を呼ぶ経路も通す。

> **New XCTest coverage**
>
> The table lists all 20 tests by exact name. Clean-room builders provide ZIP, solid 7z and RAR
> inputs; system ditto and Info-ZIP generate additional black-box fixtures. Tests cover all five
> descriptor lengths, ZIP64 extras in either header, SFX absolute offsets, signature-valued CRC,
> corrupt and truncated fields, neighboring-record overlaps, local aliases, cached validation,
> encryption without a password request, nil fallback formats, recovery, identity and short reads.
> The main round trip copies all six raw records in reverse order into a new file, then repeats
> with only three retained records, rebuilding central offsets. KaitoKit verifies identical entry
> contents and record bytes, and unzip -t verifies each new archive. Ditto gets its own real
> two-descriptor round trip. ZipCrypto is checked with both KaitoKit and unzip; AE-2 is checked with
> KaitoKit including authentication. Common checks verify record signatures, exact boundaries,
> containment, repeated calls and independent decompression of each deflate payload range.

## 4. 実行環境とコマンド

Apple Silicon arm64、macOS 27.0（26A428）、Apple Swift 6.4
（swiftlang-6.4.0.34.1、clang-2100.3.34.1）。

指定された以下のコマンドを実行し、両方とも終了値 1。ホーム配下の module cache への
書込み制限により、manifest コンパイルの段階で停止した。pipefail で終了値を確認した。

```sh
set -o pipefail
swift build 2>&1 | tee /tmp/kaitokit-raw-record-build-requested.log | tail -20
swift test 2>&1 | tee /tmp/kaitokit-raw-record-test-requested.log | tail -40
```

共通のエラー抜粋／Shared error excerpt:

```text
<unknown>:0: error: error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: /Users/nagash/.cache/clang/ModuleCache: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macosx14.0'
```

前回の検証記録と同じく、一時キャッシュを指定して SwiftPM 自身の sandbox を無効化した。
実行環境の filesystem 制限は維持している。

```sh
set -o pipefail
CLANG_MODULE_CACHE_PATH=/tmp/kaitokit-module-cache swift build --disable-sandbox 2>&1 \
  | tee /tmp/kaitokit-raw-record-build-adjusted.log | tail -20
CLANG_MODULE_CACHE_PATH=/tmp/kaitokit-module-cache swift test --disable-sandbox --filter RawEntryRecordTests 2>&1 \
  | tee /tmp/kaitokit-raw-record-tests-focused.log | tail -70
CLANG_MODULE_CACHE_PATH=/tmp/kaitokit-module-cache swift test --disable-sandbox 2>&1 \
  | tee /tmp/kaitokit-raw-record-test-adjusted.log | tail -40
git diff --check
```

> **Environment and commands**
>
> Apple Silicon arm64, macOS 27.0 (26A428), Apple Swift 6.4 (swiftlang-6.4.0.34.1).
> Both original commands exited 1 during manifest compilation because the home module cache is
> not writable. Adjusted commands use the same temporary-cache and SwiftPM sandbox configuration
> as the previous verification record, retaining the execution environment's filesystem limits.
> Pipefail preserves actual status and tee retains full logs. The exact commands are shown above.

## 5. 結果

環境調整後の build、対象テスト、全 test はすべて終了値 0。新規 20 件は skip なし・失敗なし。
全体は KaitoKit 789 件（既存テスト側の 37 skip）と compat 22 件、合計 811 件で失敗 0。
通常の ZIP、復旧、暗号化、互換 API の既存テストも成功した。全体の XCTest 実行は約 161 秒。
`git diff --check` は終了値 0。

> **Results**
>
> Adjusted build, focused tests and the full suite all exited 0. All 20 new tests passed with no
> skips. KaitoKit ran 789 tests with 37 pre-existing fixture/environment skips; compat ran 22,
> totaling 811 tests and zero failures. Existing ZIP, recovery, encryption and compatibility
> tests passed. XCTest execution took approximately 161 seconds. Git diff --check exited 0.

外部 oracle と主な集計／External oracles and suite totals:

```text
raw record ditto: 2 descriptors, unzip -t: 0
raw record rebuild: 6 entries, unzip -t: 0
raw record rebuild: 3 entries, unzip -t: 0
Executed 20 tests, with 0 failures (0 unexpected) in 0.551 (0.554) seconds
Executed 789 tests, with 37 tests skipped and 0 failures (0 unexpected) in 159.826 (159.873) seconds
Executed 22 tests, with 0 failures (0 unexpected) in 0.773 (0.776) seconds
```

build 出力の末尾 20 行（環境調整版）／Final 20 lines of adjusted build output:

```text
Building for debugging...
[Planning deferred tasks]
[7 / 24] KaitoKit
[19 / 71]
[26 / 71]
[30 / 71]
[37 / 71]
[41 / 71]
[45 / 71]
[47 / 71]
[48 / 71]
[54 / 71] KaitoKit
[68 / 85] KaitoKit
[69 / 86] KaitoKit
[77 / 93] KaitoKit
[82 / 97] KaitoKit
[89 / 96] kaito-product
[93 / 96] KaitoKitCompat
[95 / 97] KaitoKitDynamic-product
Build complete! (3.42秒)
```

全 test 出力の末尾 40 行（環境調整版）／Final 40 lines of adjusted full-test output:

```text
Test Suite 'KaitoArchiveRpmTests' started at 2026-09-10 10:16:27.895.
Test Case '-[KaitoKitCompatTests.KaitoArchiveRpmTests testStableFormatNameForEveryFixture]' started.
Test Case '-[KaitoKitCompatTests.KaitoArchiveRpmTests testStableFormatNameForEveryFixture]' passed (0.006 seconds).
Test Suite 'KaitoArchiveRpmTests' passed at 2026-09-10 10:16:27.901.
	 Executed 1 test, with 0 failures (0 unexpected) in 0.006 (0.006) seconds
Test Suite 'KaitoArchiveXarTests' started at 2026-09-10 10:16:27.901.
Test Case '-[KaitoKitCompatTests.KaitoArchiveXarTests testSingleEntryExtractionFollowsForwardReferencesAndChains]' started.
Test Case '-[KaitoKitCompatTests.KaitoArchiveXarTests testSingleEntryExtractionFollowsForwardReferencesAndChains]' passed (0.012 seconds).
Test Case '-[KaitoKitCompatTests.KaitoArchiveXarTests testStableFormatNameForEveryFixture]' started.
Test Case '-[KaitoKitCompatTests.KaitoArchiveXarTests testStableFormatNameForEveryFixture]' passed (0.018 seconds).
Test Suite 'KaitoArchiveXarTests' passed at 2026-09-10 10:16:27.931.
	 Executed 2 tests, with 0 failures (0 unexpected) in 0.030 (0.030) seconds
Test Suite 'KaitoArchiveZipConfigurationTests' started at 2026-09-10 10:16:27.931.
Test Case '-[KaitoKitCompatTests.KaitoArchiveZipConfigurationTests testLazyLocalHeaderDefaultIsThreadSafeAndUsedByBothInitializers]' started.
Test Case '-[KaitoKitCompatTests.KaitoArchiveZipConfigurationTests testLazyLocalHeaderDefaultIsThreadSafeAndUsedByBothInitializers]' passed (0.001 seconds).
Test Suite 'KaitoArchiveZipConfigurationTests' passed at 2026-09-10 10:16:27.932.
	 Executed 1 test, with 0 failures (0 unexpected) in 0.001 (0.001) seconds
Test Suite 'MigrationGuideSnippetCompileTests' started at 2026-09-10 10:16:27.932.
Test Case '-[KaitoKitCompatTests.MigrationGuideSnippetCompileTests testDocumentedCompatibilitySnippetsCompile]' started.
Test Case '-[KaitoKitCompatTests.MigrationGuideSnippetCompileTests testDocumentedCompatibilitySnippetsCompile]' passed (0.000 seconds).
Test Case '-[KaitoKitCompatTests.MigrationGuideSnippetCompileTests testDocumentedCooViewerArchiveSourceShapeCompiles]' started.
Test Case '-[KaitoKitCompatTests.MigrationGuideSnippetCompileTests testDocumentedCooViewerArchiveSourceShapeCompiles]' passed (0.000 seconds).
Test Case '-[KaitoKitCompatTests.MigrationGuideSnippetCompileTests testDocumentedDelegateSnippetCompiles]' started.
Test Case '-[KaitoKitCompatTests.MigrationGuideSnippetCompileTests testDocumentedDelegateSnippetCompiles]' passed (0.000 seconds).
Test Case '-[KaitoKitCompatTests.MigrationGuideSnippetCompileTests testDocumentedModernSnippetCompiles]' started.
Test Case '-[KaitoKitCompatTests.MigrationGuideSnippetCompileTests testDocumentedModernSnippetCompiles]' passed (0.000 seconds).
Test Suite 'MigrationGuideSnippetCompileTests' passed at 2026-09-10 10:16:27.933.
	 Executed 4 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
Test Suite 'KaitoKitCompatTests.xctest' passed at 2026-09-10 10:16:27.933.
	 Executed 22 tests, with 0 failures (0 unexpected) in 0.773 (0.776) seconds
Test Suite 'All tests' passed at 2026-09-10 10:16:27.933.
	 Executed 22 tests, with 0 failures (0 unexpected) in 0.773 (0.776) seconds
◇ Test run started.
↳ Testing Library Version: 2084
↳ Target Platform: arm64e-apple-macos14.0
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
◇ Test run started.
↳ Testing Library Version: 2084
↳ Target Platform: arm64e-apple-macos14.0
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
```

## 6. 検証の限界

4 GiB 超の実ファイルを今回新たに生成しての往復は行っていない。ZIP64 は小さい entry で
本物の 8-byte size 欄を作り、上位 32 bit の不一致も検査した。WinZip AES の外部 archiver
による往復検証は今回行っていない。payload の CRC / HMAC を実データに対して検証するのは
従来の read の役割であり、raw API は byte を復号・展開せず、構造と descriptor の整合を
検証する。source の byte は open からコピー完了まで不変である必要がある。

> **Verification limits**
>
> No new physical file larger than 4 GiB was generated for this change. Small ZIP64 entries contain
> actual eight-byte sizes, including tests that corrupt their high words. No external-archiver
> round trip was performed for WinZip AES. The raw API validates structure and descriptor agreement;
> actual payload CRC/HMAC verification remains part of normal reads. Source bytes must remain
> immutable from opening through completion of copying.

## 7. ローカルコミット

`main` 上で対象 9 ファイルを `git add` したが、sandbox の `.git` 書込み制限で
終了値 128 となった。その後、指定 trailer を含むメッセージで
`git commit -F build/commit-message.txt` を試み、ステージ済みの変更がないため終了値 1 となった。

```text
fatal: Unable to create '/Users/nagash/Github/KaitoKit/.git/index.lock': Operation not permitted
```

ステージ済みで残す指示についても、`git add` 自体が拒否されるため実行できなかった。
変更は作業ツリーに未ステージで残し、コミットメッセージは `build/commit-message.txt`
に保存した（`build/` は既存の ignore 対象）。HEAD は `db2c5d0` のまま。push は行っていない。

> **Local commit**
>
> Staging the nine changed files on main exited 128 because the sandbox denied creation of
> .git/index.lock. The subsequent git commit -F build/commit-message.txt exited 1 because there
> were no staged changes. Since git add itself is blocked, the requested staged fallback is
> unavailable too. All changes remain unstaged in the working tree, and the exact
> commit message, including both required trailers, is saved in build/commit-message.txt under
> the already ignored build directory. HEAD remains db2c5d0. Nothing was pushed.
