# KaitoKit 0.9.0 リリースレビュー検証 — 2026-09-22

基点は `release/0.9.0` の `cd2e747`。開始時は clean working tree。敵対的 multi-agent pre-release review（6 観点、各指摘を 3 検証 lens、計 39 agents）で確認された R1〜R11 を扱う。この修正作業では subagent は使っていない。第三者の archive 実装 source は参照していない。install / branch 作成 / commit / push は行っていない。

実装・文書の変更前にテストを追加し、R1〜R3 と R4・R8〜R11 の文書検査の失敗を採取した。R4〜R7 の parser は基点から正しく拒否し、指摘はテスト不足なので、その runtime テストは基点でも成功する。ここを「修正前の実装不具合」とは数えず、既存ガードを一時的に外した mutation 検査で全ケースの失敗を採取し、直ちに元へ戻した。各節に実際の区別と出力を残す。コンパイル失敗を再現には数えていない。

fixture は既存 image をメモリ上で変更するか、テスト内で合成した。`Tests/Fixtures/` / `SHA256SUMS` / `inbox/` は変更・追加していない。以下のレビュー担当者の計測値は依頼文からの引用であり、この環境での再計測とは分けて示す。全文ログは実行環境の `<tmp>/kaito-090-*.log`。記録中のパスは `<repo>` / `<home>` / `<tmp>` へ正規化した。

## 実行環境とコマンド

Apple Silicon、macOS 27.2（26B5091g）、Apple Swift 6.4。package の Swift 6 / macOS 要件は変更していない。

```text
swift-driver version: 1.168.6 Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)
Target: arm64-apple-macosx27.2.0
```

通常の `swift build` は sandbox によりホームの module cache へ書けず、終了コード 1。

```text
<unknown>:0: error: error opening '<home>/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: <home>/.cache/clang/ModuleCache: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macosx14.0'
```

0.8.1 と同じく cache を `.build` 内へ置いた。以後の build / test は次の指定を共通に使用する。configuration / security / cache に関するホームへの警告は残るが、build / test は成功する。

```sh
cd <repo>
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
swift build --disable-sandbox --cache-path .build/swiftpm-cache
swift test --disable-sandbox --cache-path .build/swiftpm-cache --filter DMG
swift test --disable-sandbox --cache-path .build/swiftpm-cache --filter Rpm
swift test --disable-sandbox --cache-path .build/swiftpm-cache --filter Tar
swift test --disable-sandbox --cache-path .build/swiftpm-cache --filter ReleaseReviewDocumentationTests
swift test --disable-sandbox --cache-path .build/swiftpm-cache

run_test() {
  swift test --disable-sandbox --cache-path .build/swiftpm-cache --filter "$1"
}
```

最初の red 実行は次の filter を使用した。18 件、35 assertion failures、終了コード 1（既存文書テスト 4 件を含む）。ログは `<tmp>/kaito-090-red.log`。

```sh
run_test 'DMGDecmpfsTests.testR[12]Review|RpmReaderTests.testR3Review|TarSparseTests.testR[45]Review|DMGReaderTests.testDecmpfsAttributeErrorsAndHardLinkTarget|RpmReaderTests.testFileListCountsTypesDirectoryIndexesAndLongSizesAreValidated|ReleaseReviewDocumentationTests'
```

mutation は `<tmp>/kaito-090-mutations.py` から、対象ガードの文だけを一時削除して `run_test` 相当を実行した。各実行の `finally` で元の source を復元し、次のケースへ進めた。R4 / R5 は各 1 guard、R6 は属性件数 / 保持総量の 2 guards、R7 は hard link / symlink サイズの 2 guards。R1〜R3 の実装修正前に実施した。ログは `<tmp>/kaito-090-mutation-R<n>.log`。

## R1. HFS+ 属性走査の共有 metadata budget

再現: レビュー担当者は、4,500 file に各 3,400 byte の xattr を付けた 385,657 byte の UDZO DMG で、`kaito list` が `size 16781312 exceeds limit 16777216`、rc=1 を確認。xattr 無し 10,000 file の control は 10,002 entries を列挙できた。本作業では **volume header・catalog・attributes を持つ bare HFS+ 入力をテスト内で合成し、`ArchiveReader.open` から検査する方法**を採った。catalog は root と 1 file、attributes は 4,100 葉 × 4,096 byte = 16,793,600 byte、image 全体 16,809,984 byte。各葉に属性 1 件を置き、圧縮有りでは先頭を 17 byte の decmpfs、残りは 3,400 byte の別名属性にする。17 MB 程度で十分再現できるので、大きな fixture や数千 file の catalog は不要。

原因: UF_COMPRESSED が無い volume でも属性木を読み、catalog / extents と共用した累計を単体 allocation の 16 MiB 上限で検査していた。

修正: `DMGReader.swift` で `items.contains { $0.ownerFlags & 0x20 != 0 }` のときだけ属性を読む。独立した `attributeBudget` を渡し、`HFSPlusVolume.swift` の属性走査だけ `maxTotalMetadataSize`（既定 256 MiB）を適用する。catalog / extents の既存制限、属性の `maxEntryCount`・単体 `maxMetadataSize`・`retainedSize` の総量検査は保持。

回帰テスト: `DMGDecmpfsTests.testR1ReviewSkipsUnneededLargeAttributeTree` と `testR1ReviewLargeDecmpfsTreeUsesItsOwnTotalBudget`。圧縮無しの正常木と壊れた属性 header が同じ一覧になること、圧縮有りは列挙して `[42]` を読めることを確認。小さい 4 葉の volume でも、単体上限 4,096 / 総量上限 16,384 で成功し、総量 16,383 で拒否する。17 byte の保持属性は単体上限 16 で引き続き拒否する。

修正前（2 テストとも同じ失敗）:

```text
failed: caught error: "Read limit exceeded: size 16781312 exceeds limit 16777216"
```

修正後:

```text
Test Case '-[KaitoKitTests.DMGDecmpfsTests testR1ReviewSkipsUnneededLargeAttributeTree]' passed (0.284 seconds).
Test Case '-[KaitoKitTests.DMGDecmpfsTests testR1ReviewLargeDecmpfsTreeUsesItsOwnTotalBudget]' passed (0.213 seconds).
```

## R2. inline decmpfs の過大な宣言サイズ

再現: レビュー担当者の 12,321 byte DMG は、27 byte の type 3 属性が 1 GiB を宣言し、`kaito sha` が RSS 1,088,208,896 byte / 0.97 秒で zlib length error。7-Zip 26.03 は RSS 5,619,712 byte / 0.00 秒、resource fork 版の KaitoKit は 14,516,224 byte。6 entries / 12,592 byte では zero-fill に 4.2 秒。同担当者の実 driver 計測は 65,535 / 65,536 byte が inline type 7、65,537 byte が resource type 8。本作業では init のみを呼び、1 GiB allocation を実際に起こす read は行っていない。

原因: inline の chunk 数は 1 なのに、decode 用 buffer は 64 KiB でなく宣言サイズで zero-fill していた。

修正: `DecmpfsDecompressor.init` の inline 分岐で `uncompressedSize <= 65_536` を要求する。超過は `malformed("hfs+ decmpfs inline declared size")`。type 1 の payload 長不一致の既存 `inline size` と区別する。これは decoder / stream 初期化時の拒否であり、DMG 一覧の作成自体を変えるものではない。

回帰テスト: `DMGDecmpfsTests.testR2ReviewInlineDeclaredSizeIsBoundedBeforeRead`。matching zlib payload の 65,536 byte は全 byte が一致。65,537 / 1 GiB は read せず init が指定の `malformed` を返す。type 1 の payload 長不一致は従来の別 message を維持。宣言値に比例する buffer は read 内なので、init での失敗により allocation 前の拒否を直接確認する。

修正前（2 宣言値で各 1 件）:

```text
XCTAssertThrowsError failed: did not throw an error
```

修正後:

```text
Test Case '-[KaitoKitTests.DMGDecmpfsTests testR2ReviewInlineDeclaredSizeIsBoundedBeforeRead]' passed (0.001 seconds).
```

修正後の CLI も補足計測した。`attributeVolume` と同じ bare volume の配置（20,480 byte、root + `declared.bin`、属性 1 葉）で、属性を `fpmc || LE32(3) || LE64(size) || zlib("abc")` の 27 byte とし、size だけを変えた。これはレビュー担当者の UDZO image とは別入力。`/usr/bin/time -l` は `sysctl kern.clockrate: Operation not permitted` で RSS を出せなかったため、Python の `os.wait4` が返す子プロセスの `ru_maxrss`（この macOS では byte）を使用した。

```sh
python3 <tmp>/kaito-090-inline-image.py
.build/debug/kaito sha <tmp>/kaito-090-inline-65537.img
.build/debug/kaito sha <tmp>/kaito-090-inline-1073741824.img
```

`os.wait4` wrapper の実出力（`<tmp>/kaito-090-inline-rss.log`）:

```text
declared=65537 image=20480 attribute=27 exit=1 maxrss=12894208 bytes elapsed=0.020s
error: failed entry 0 (declared.bin): Malformed archive: hfs+ decmpfs inline declared size
declared=1073741824 image=20480 attribute=27 exit=1 maxrss=12926976 bytes elapsed=0.013s
error: failed entry 0 (declared.bin): Malformed archive: hfs+ decmpfs inline declared size
```

## R3. RPM stripped payload の 65,536 件上限

再現: レビュー担当者は rpm 6.1.0 の 70,071 file package で `17938176 > 16777216`、rc=1 を確認。`rpm2cpio | bsdtar -tf -` と `_rpmformat 4` の KaitoKit は全件列挙。本作業では 65,537 個の空 file と `07070X` record をメモリ上で構成し、既存 fixture の trailer を付けて `RpmStrippedPayload` の file-list / limits path を直接検査する。70k-file fixture は追加していない。

原因: file list 全体の概算保持量 `count * 256` を単体 allocation 上限でも検査していた。

修正: `RpmStrippedPayload.swift` の `maxMetadataSize` 検査だけを削除する。概算値・`maxTotalMetadataSize` 検査・`RpmReader` の aggregate 加算・header 配列 / payload の `maxEntryCount` 検査は維持。

回帰テスト: `RpmReaderTests.testR3ReviewStrippedFileListUsesAggregateMetadataLimit`。上限ちょうどの 65,537 records と末尾 index / 空本文を確認し、件数上限 65,536 と総量上限 16,777,471 はそれぞれ正しい `limitExceeded` になる。

修正前:

```text
failed: caught error: "Read limit exceeded: size 16777472 exceeds limit 16777216"
```

修正後:

```text
Test Case '-[KaitoKitTests.RpmReaderTests testR3ReviewStrippedFileListUsesAggregateMetadataLimit]' passed (0.284 seconds).
```

## R4. 非 GNU magic の S header の検査とエラー分類

再現: POSIX magic の helper で空の `S` member を作り、`malformed("invalid old GNU sparse header")` を要求する。レビューでこの assertion の削除と CHANGELOG の分類変更の欠落を確認。

原因: 旧 GNU sparse 対応の追加時に、以前の非対応ケースの assertion と `unsupportedMethod("GNU tar sparse entries")` からの変更説明が欠けた。

修正: `TarSparseTests` に POSIX magic 自体も照合するケースを復元し、CHANGELOG の既存 tar feature bullet に分類変更を追記。parser は変更しない。

回帰テスト: `TarSparseTests.testR4ReviewOldGNUTypeRequiresGNUMagic` と `ReleaseReviewDocumentationTests.testR4ReviewChangelogExplainsNonGNUMagicErrorClass`。文書の修正前失敗、および magic guard 一時削除時の失敗は次のとおり。runtime テストは基点でも成功した。

```text
XCTAssertTrue failed - tar の変更履歴に 非 GNU が必要
XCTAssertTrue failed - tar の変更履歴に unsupportedMethod("GNU tar sparse entries") が必要
XCTAssertTrue failed - tar の変更履歴に malformed が必要
XCTAssertThrowsError failed: did not throw an error
```

修正後:

```text
Test Case '-[KaitoKitTests.TarSparseTests testR4ReviewOldGNUTypeRequiresGNUMagic]' passed (0.000 seconds).
Test Case '-[KaitoKitTests.ReleaseReviewDocumentationTests testR4ReviewChangelogExplainsNonGNUMagicErrorClass]' passed (0.003 seconds).
```

## R5. pax と旧 GNU sparse map の競合

再現: `GNU.sparse.size=5` の pax header を旧 GNU `S` archive の前に付け、`malformed("conflicting GNU sparse maps")` を要求する。

原因: 既存の競合 guard に専用テストが無かった。

修正: `TarSparseTests` に合成ケースを追加。parser は変更しない。

回帰テスト: `TarSparseTests.testR5ReviewOldGNUAndPaxSparseMapsConflict`。基点は成功する。競合 guard の一時削除で、別の後続エラーになることまで区別して失敗した。

```text
XCTAssertEqual failed: ("Optional(Malformed archive: GNU sparse entry without a map)") is not equal to ("Optional(Malformed archive: conflicting GNU sparse maps)")
```

修正後（guard 復元）:

```text
Test Case '-[KaitoKitTests.TarSparseTests testR5ReviewOldGNUAndPaxSparseMapsConflict]' passed (0.000 seconds).
```

## R6. decmpfs 属性 parser の上限

再現: mount 検証済み `hfs-zlib.dmg` の disk bytes を変えずに `maxEntryCount: 0` と、保持属性 471 byte より 1 byte 小さい `maxTotalMetadataSize: 470` で open する。ともに `limitExceeded` を要求。属性名・payload は変更しない。

原因: 件数と保持属性の総量に専用 assertion が無かった。

修正: `DMGReaderTests.testDecmpfsAttributeErrorsAndHardLinkTarget` を拡張。volume の直接呼び出しでも `hfs+ decmpfs attribute count` を照合し、後続の公開 entry count に隠れないようにする。既存の属性エラー / hard link 検査は残す。

回帰テスト: 基点では成功。R1 変更前に属性件数と `retainedSize` の総量 guard を一時削除した結果は次のとおり（public open の保持総量と直接呼出しの属性件数が各 1 件失敗）。R1 適用後は同じ総量上限が属性 walk にも掛かるため、470 byte の場合は node budget が先に拒否する。保持属性の guard はそのまま残しており、最終構成で後段の guard 単独へ到達したとは主張しない。

```text
XCTAssertThrowsError failed: did not throw an error
XCTAssertThrowsError failed: did not throw an error
```

修正後:

```text
Test Case '-[KaitoKitTests.DMGReaderTests testDecmpfsAttributeErrorsAndHardLinkTarget]' passed (1.202 seconds).
```

## R7. RPM file list の link サイズ整合

再現: 既存 rpm fixture の tag 5008（LONGFILESIZES）で、hard link 群の最初の非 ghost member と symlink のサイズをそれぞれ 1 byte 増やす。payload は変更しない。

原因: hard link 群のサイズ一致と symlink の UTF-8 target 長検査に専用 assertion が無かった。

修正: `RpmReaderTests.testFileListCountsTypesDirectoryIndexesAndLongSizesAreValidated` に 2 mutation を追加し、いずれも `malformed("rpm file list")` を厳密に照合する。parser は変更しない。

回帰テスト: 基点では成功。2 サイズ guard を一時削除したときは各入力が open してしまい、次の失敗を得た。

```text
XCTAssertThrowsError failed: did not throw an error - /usr/share/kaito-rpm6/hard-a.txt
XCTAssertThrowsError failed: did not throw an error - /usr/share/kaito-rpm6/link.txt
```

修正後（guard 復元）:

```text
Test Case '-[KaitoKitTests.RpmReaderTests testFileListCountsTypesDirectoryIndexesAndLongSizesAreValidated]' passed (0.009 seconds).
```

## R8. v0.8.0 DMG 記録への decmpfs 追補

再現: `2026-09-22-dmg.md` は decmpfs の size 不明・本文非対応、Icon Composer の 48 圧縮 file が読めないという当時の記述のままで、後続記録への案内が無かった。

原因: 実装追加後も released record から現状へ辿れなかった。

修正: 本文を保存し、末尾に v0.8.0 時点の記録である旨と `2026-09-22-hfsplus-decmpfs.md` への 1 行の注記を追加。

回帰テスト: `ReleaseReviewDocumentationTests.testR8ReviewReleasedDMGRecordPointsToDecmpfsFollowup`。旧 method 名を残し、時点と追補リンクの両方が存在することを検査。

修正前:

```text
XCTAssertTrue failed - 旧記録から decmpfs 追補へリンクする
XCTAssertTrue failed - 旧記録の時点を明記する
```

修正後:

```text
Test Case '-[KaitoKitTests.ReleaseReviewDocumentationTests testR8ReviewReleasedDMGRecordPointsToDecmpfsFollowup]' passed (0.001 seconds).
```

## R9. 英語 README の tar 対応状況

再現: 英語 tar support row は pax 0.0 / 0.1 / 1.0 だけで、日本語 row と英語の既知の制限にある旧 GNU `S` が欠けていた。

原因: feature 追加時の言語間の更新漏れ。

修正: support row に `old GNU typeflag S` を追記。

回帰テスト: `ReleaseReviewDocumentationTests.testR9ReviewEnglishTarSupportIncludesOldGNU`。英語 tar support row の範囲に限定して検査する。

修正前:

```text
XCTAssertTrue failed - 英語の対応状況にも旧 GNU S 型が必要
```

修正後:

```text
Test Case '-[KaitoKitTests.ReleaseReviewDocumentationTests testR9ReviewEnglishTarSupportIncludesOldGNU]' passed (0.002 seconds).
```

## R10. decmpfs の公開 method 名・サイズの変更履歴

再現: 実装は `HFS+ decmpfs (…)` と対応 type の実サイズ / 格納長を返すが、CHANGELOG の feature bullet に従来値からの変更が無かった。

原因: 本文対応の説明だけで、一覧 API の利用者向けの変更点が抜けた。

修正: 既存 decmpfs feature bullet に `methodDescription` の `HFS+ compressed (decmpfs)` → `HFS+ decmpfs (…)` と、対応 type の `uncompressedSize` / `compressedSize` が `nil` でなくなることを追記。

回帰テスト: `ReleaseReviewDocumentationTests.testR10ReviewChangelogExplainsDecmpfsEntryMetadata`。feature bullet 自体から新旧名と両 property を検査する。

修正前（抜粋）:

```text
XCTAssertTrue failed - decmpfs の変更履歴に methodDescription が必要
XCTAssertTrue failed - decmpfs の変更履歴に uncompressedSize が必要
XCTAssertTrue failed - decmpfs の変更履歴に compressedSize が必要
```

修正後:

```text
Test Case '-[KaitoKitTests.ReleaseReviewDocumentationTests testR10ReviewChangelogExplainsDecmpfsEntryMetadata]' passed (0.003 seconds).
```

## R11. 検証記録の machine 固有パス・一時 worktree

再現: sevenzip-deflate64 / small-method-gaps にホームの絶対パス、前者の manifest command に machine 固有の一時 directory、後者の冒頭に残存しない作業 worktree が現在形で記載されていた。

原因: sandbox エラー出力と作業時の文脈を統合後もそのまま残した。

修正: repository / home / 一時 directory の prefix を `<repo>` / `<home>` / `<tmp>` に置換し、error message 本体と toolchain の固定パスは保持。index に `<tmp>` の規約を補足。small-method-gaps は一時 worktree で作業し `cd2e747` として `release/0.9.0` に統合済みと記載する。rpm-stripped-payload / hfsplus-decmpfs も検査したが該当 home path は無く、変更不要。released `2026-09-22-release-review-0.8.1.md` は変更していない。

回帰テスト: `ReleaseReviewDocumentationTests.testR11ReviewRecordsUsePortablePathsAndMergedWorktreeStatus`。対象 4 記録とこの記録について home / 一時 directory の machine 固有パスを拒み、worktree の過去形と統合先を要求する。

修正前（抜粋）:

```text
XCTAssertFalse failed - sevenzip-deflate64: home 絶対パスを置換する
XCTAssertFalse failed - small-method-gaps: home 絶対パスを置換する
XCTAssertFalse failed
XCTAssertTrue failed
```

修正後:

```text
Test Case '-[KaitoKitTests.ReleaseReviewDocumentationTests testR11ReviewRecordsUsePortablePathsAndMergedWorktreeStatus]' passed (0.002 seconds).
```

## 文書の回帰検査

`ReleaseReviewDocumentationTests.testRelease090DocumentsAllElevenReviewFixes` は `[Unreleased]` の R1〜R11、記録の各 `## R<n>.` と「再現 / 原因 / 修正 / 回帰テスト」、README / CHANGELOG のリンク、verification index の未リリース row を検査する。既存の 0.8.1 テストは変更していない。

作成前の実出力（抜粋）:

```text
XCTAssertTrue failed - 0.9.0 に R1 の説明が必要
XCTAssertTrue failed - 0.9.0 に R11 の説明が必要
XCTAssertTrue failed - README.md から検証記録へリンクする
XCTAssertTrue failed - CHANGELOG.md から検証記録へリンクする
XCTUnwrap failed: expected non-nil value of type "String"
```

## 最終検証

指定された各コマンドは冒頭の `.build` cache 指定で実行した。新しいテストは 12 件（DMG 3、RPM 1、tar 2、文書 6）、既存 2 件を拡張。既存 fixture、公開 API、ReaderOptions の既定値、MIT license は変更していない。

個別検証の実出力（各 target の最終行。重複する suite 集計は省略）:

```text
$ swift build
Build complete! (0.33秒)
$ swift test --filter DMG
Executed 21 tests, with 0 failures (0 unexpected) in 2.460 (2.462) seconds
Executed 1 test, with 0 failures (0 unexpected) in 0.010 (0.011) seconds
$ swift test --filter Rpm
Executed 19 tests, with 0 failures (0 unexpected) in 0.354 (0.356) seconds
Executed 2 tests, with 0 failures (0 unexpected) in 0.006 (0.007) seconds
$ swift test --filter Tar
Executed 101 tests, with 1 test skipped and 0 failures (0 unexpected) in 7.818 (7.827) seconds
Executed 1 test, with 0 failures (0 unexpected) in 0.086 (0.087) seconds
$ swift test --filter ReleaseReviewDocumentationTests
Executed 10 tests, with 0 failures (0 unexpected) in 0.040 (0.041) seconds
```

いずれも終了コード 0。tar filter の既存 skip 1 件は任意 corpus による。文書作成後の `testRelease090DocumentsAllElevenReviewFixes` も成功した。ログは `<tmp>/kaito-090-build.log`、`<tmp>/kaito-090-DMG.log`、`<tmp>/kaito-090-Rpm.log`、`<tmp>/kaito-090-Tar.log`、`<tmp>/kaito-090-docs.log`。

全件 `swift test` も終了コード 0。KaitoKitTests 1,403 件 + KaitoKitCompatTests 34 件 = **1,437 件、skip 45、失敗 0**（成功 1,392）。本体の基点 1,391 件から新規 12 件が増えた。ログは `<tmp>/kaito-090-full.log`。

```text
Executed 1403 tests, with 45 tests skipped and 0 failures (0 unexpected) in 422.478 (422.574) seconds
Executed 34 tests, with 0 failures (0 unexpected) in 2.120 (2.124) seconds
```

skip はすべて既存テスト。外部 corpus / 任意 oracle の条件、明示実行する大距離・性能・敵対入力の検証による。Info-ZIP の bzip2 非対応も従来の skip 条件であり、新規 skip は無い。実行ログの class 別内訳:

| 既存テストクラス | skip 数 |
| --- | ---: |
| `ArReaderTests` | 1 |
| `CabLZXTests` | 1 |
| `CpioReaderTests` | 3 |
| `LHACompatibilityCorpusTests` | 8 |
| `LHAIntegrationTests` | 2 |
| `LHAMacBinaryTests` | 4 |
| `LHAMethodCorpusTests` | 6 |
| `LHASFXTests` | 1 |
| `RAR4CorpusDifferentialTests` | 2 |
| `RAR4ReaderTests` | 5 |
| `RAR4SFXTests` | 1 |
| `RAR4VolumeTests` | 3 |
| `StuffItXCorpusTests` | 1 |
| `StuffItXCryptoTests` | 1 |
| `StuffItXDeflateTests` | 1 |
| `StuffItXJPEGTests` | 4 |
| `ZipDifferentialTests` | 1 |

`git diff --check` は成功。0.8.1 の検証記録は `git show HEAD:<path>` と byte 一致、fixture への差分は無い。CHANGELOG の既存 feature bullets は 6 件を保持し、R1〜R11 とこの記録へのリンクを追加した。

変更ファイルは次の 16 件（新規記録を含む）:

- `CHANGELOG.md`
- `Documentation/verification/2026-09-22-dmg.md`
- `Documentation/verification/2026-09-22-release-review-0.9.0.md`
- `Documentation/verification/2026-09-22-sevenzip-deflate64.md`
- `Documentation/verification/2026-09-22-small-method-gaps.md`
- `Documentation/verification/README.md`
- `README.md`
- `Sources/KaitoKit/Formats/DMG/DMGReader.swift`
- `Sources/KaitoKit/Formats/DMG/DecmpfsDecompressor.swift`
- `Sources/KaitoKit/Formats/DMG/HFSPlusVolume.swift`
- `Sources/KaitoKit/Formats/Rpm/RpmStrippedPayload.swift`
- `Tests/KaitoKitTests/DMGDecmpfsTests.swift`
- `Tests/KaitoKitTests/DMGReaderTests.swift`
- `Tests/KaitoKitTests/ReleaseReviewDocumentationTests.swift`
- `Tests/KaitoKitTests/RpmReaderTests.swift`
- `Tests/KaitoKitTests/TarSparseTests.swift`

未修正の指摘は無い。R4〜R7 は既存の正しい拒否にテストを補ったもので、修正前の runtime 不具合があったとはしていない。R2 の RSS 再計測は上記の自作 bare image に対するもの。レビュー担当者の UDZO / 70,071-file RPM 実物の再作成・mount / rpm rebuild は実施していない。
