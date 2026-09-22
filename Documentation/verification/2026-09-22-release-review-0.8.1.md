# KaitoKit 0.8.1 リリースレビュー検証 — 2026-09-22

基点は `release/0.8.1` の `fc36308`（v0.8.0）。開始時は clean working tree。R1〜R14 の回帰テストを実装変更前に追加して個別実行し、以下の失敗を採取した。コンパイル時のテスト API の誤記は修正してから実行しており、コンパイル失敗を回帰の再現には数えていない。subagent は使用していない。commit / push は行っていない。

既存 fixture をメモリ上で変更するか、テスト内で bytes を構成した。`Tests/Fixtures/` と `SHA256SUMS` は変更していない。`inbox/` は参照・変更していない。各節のパスはリポジトリ相対。ログ全文は実行環境の `/tmp/kaito-081-red-R<n>.log` に置き、以下に実際の失敗文を保存する（重複する assertion とプロセス実行パスは省略）。

## 実行環境とコマンド

Apple Silicon、Apple Swift 6.4（swiftlang-6.4.0.34.1）、macOS target `arm64-apple-macosx27.2.0`。7zz / xz / brotli は `/opt/homebrew/bin/` にある。通常の `swift build` は sandbox によるホーム配下の module cache への書き込み拒否で失敗した。

```text
error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: /Users/nagash/.cache/clang/ModuleCache: Operation not permitted
error: unable to load standard library for target 'arm64-apple-macosx14.0'
```

以後は以下を使用した。build 成果物と cache は `.build` 配下で、別の scratch path は使っていない。ユーザー cache の configuration / security warning は残るが、build / test は実行できた。

```sh
cd /Users/nagash/Github/KaitoKit
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
  swift build --disable-sandbox --cache-path .build/swiftpm-cache
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
  swift test --disable-sandbox --cache-path .build/swiftpm-cache

# 各節の「追加テスト名」を引数にして個別再現する。
run_test() {
  CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
    swift test --disable-sandbox --cache-path .build/swiftpm-cache --filter "$1"
}
```

初回の R1 で test target を build した後、ソースが同一の R2〜R14 は `--skip-build --filter '<クラス>.testR<n>[A-Z]'` で個別実行した。R6 は core の hardlink read が空である既存契約に合わせた後に再実行した。R9 は原文の末尾反転が既存検査で拒否されたため、同じ終端未検証の問題を余剰出力で切り分けて再実行した。どちらも実装修正前のログを以下に記録している。

## R1. ARJ の短い基本 header

再現手順: 9 byte `60 ea 01 00 00 8d ef 02 d2` を `Data` として組み立て、`FormatDetector.detect` と `ArchiveReader.open` が `unsupportedFormat` を返すことを要求する。CRC は正しいが基本 header は 1 byte しかない。

追加テスト名: `ARJReaderTests.testR1ShortCRCValidMainHeaderDoesNotCrash`（`run_test ARJReaderTests.testR1ShortCRCValidMainHeaderDoesNotCrash`）。

修正前の失敗文:

```text
Swift/ContiguousArrayBuffer.swift:695: Fatal error: Index out of range
exited with unexpected signal code 5
```

修正ファイル: `Sources/KaitoKit/Formats/ARJ/ARJReader.swift:131`。

修正内容: `findMainHeader` で file type の byte を読む前に基本 header 長が 7 以上であることを要求する。短い候補は検出対象から外し、既存の `unsupportedFormat` にする。

## R2. CFB root mini-stream のサイズ overflow

再現手順: 既存 `cfb/v4.cfb.gz.b64` をメモリで復元し、root directory entry の 64 bit サイズだけを `UInt64.max` に変える。既定の `maxEntrySize` では `limitExceeded`、上限を `UInt64.max` にしても実 chain が不足して `malformed` になることを要求する。

追加テスト名: `CFBReaderTests.testR2RootMiniStreamSizeOverflowIsRejected`（`run_test CFBReaderTests.testR2RootMiniStreamSizeOverflowIsRejected`）。

修正前の失敗文:

```text
exited with unexpected signal code 5
```

修正ファイル: `Sources/KaitoKit/Formats/CFB/CFBReader.swift:198`。

修正内容: root サイズにも `Checked.size(..., limit: maxEntrySize)` を適用する。正のサイズの sector 切り上げを `(size - 1) / sectorSize + 1` とし、上限を外した設定でも加算 overflow しない。修正前のプロセスは最初の open で停止するため、同じテスト後半の上限無効時の検査には到達しない。

## R3. CFB sibling tree の無制限再帰

再現手順: テスト内で 4,000 個の空 stream が左 sibling だけで連なる CFB を合成する。既定の metadata / entry 上限内で open し、`f4000` から `f1` までの一覧順・内容を確認する。低い件数上限の拒否と、最深部から entry 1 に戻る循環の拒否も確認する。

追加テスト名: `CFBReaderTests.testR3DeepSiblingTreeDoesNotUseTheCallStack`（`run_test CFBReaderTests.testR3DeepSiblingTreeDoesNotUseTheCallStack`）。

修正前の失敗文:

```text
exited with unexpected signal code 11
```

修正ファイル: `Sources/KaitoKit/Formats/CFB/CFBReader.swift:225`。

修正内容: 再帰関数を明示的な traversal stack に置き換える。左、自分、storage の子、右という既存順序と visited による循環検査を維持し、path depth と entry count の既存上限も残す。

## R4. CHM section ID の Int 変換

再現手順: 既存 `chm/uncompressed.chm.gz.b64` の最初の PMGL record を、空の `/x`、section `0x8000000000000000`（10 byte ENCINT）に変える。directory の解析結果も確認してから public open の `malformed` を要求する。

追加テスト名: `CHMReaderTests.testR4SectionIDBeyondIntIsRejected`（`run_test CHMReaderTests.testR4SectionIDBeyondIntIsRejected`）。

修正前の失敗文:

```text
Swift/arm64e-apple-macos.swiftinterface:13900: Fatal error: Not enough bits to represent the passed value
exited with unexpected signal code 5
```

修正ファイル: `Sources/KaitoKit/Formats/CHM/CHMReader.swift:276`。

修正内容: 公開 entry の生成前に `entry.section <= UInt64(Int.max)` を確認する。空 entry にも適用し、`solidGroup` などの `Int` 初期化が trap しないようにする。

## R5. UDIF sector-byte 乗算の overflow

再現手順: XML plist、1 個の raw chunk の mish、512 byte の koly trailer をテスト内で合成する。chunk と trailer の sector 数をともに `2^55` にする。open が `malformed("unsigned integer multiplication overflow")` を返すことを要求する。

追加テスト名: `DMGReaderTests.testR5SectorByteOverflowIsRejected`（`run_test DMGReaderTests.testR5SectorByteOverflowIsRejected`）。

修正前の失敗文:

```text
exited with unexpected signal code 5
```

修正ファイル: `Sources/KaitoKit/Formats/DMG/UDIFImage.swift:99`。

修正内容: disk 長の `Checked.mul(trailer.sectorCount, 512)` を chunk 解析より先に行う。後続の chunk 範囲検査と合わせ、各 chunk の sector-to-byte 変換も表現可能な disk 内に収まる。

## R6. AppleDouble の index 変更と tar hard link

再現手順: metadata だけの `._foo`、通常 file `foo`、`foo` を指す `link`、`link` を指す `chained` を手組み tar に入れる。`.merge` / `.hide`、resource fork 有無の組合せで最終 index・reopen・hard link 展開を確認する。

追加テスト名: `AppleDoubleSidecarTests.testR6HardLinkIndicesFollowSidecarRemovalAndForkInsertion`（`run_test AppleDoubleSidecarTests.testR6HardLinkIndicesFollowSidecarRemovalAndForkInsertion`）。

修正前の失敗文:

```text
XCTAssertEqual failed: ("Optional("1")") is not equal to ("Optional("0")")
XCTAssertEqual failed: ("Optional("2")") is not equal to ("Optional("1")")
failed: caught error: "Malformed archive: hard-link target is not a distinct archive member"
```

修正ファイル: `Sources/KaitoKit/Formats/Wrappers/AppleDoubleReader.swift:158`。

修正内容: sidecar の除去と fork 挿入を含む最終 index の写像を作り、`hardLinkTargetIndex` も変換する。除去された参照先に古い index を残さない。tar hardlink 自身の `ArchiveReader.read` は従来どおり空であり、本文の取得は展開側・Compat が参照を辿る。この既存契約は変更せず、回帰テストでは公開 index と実際の展開結果を検査する。

## R7. 読めない AppleDouble 候補の露出維持

再現手順: method 7 の通常 ZIP entry `._ordinary` または `__MACOSX/._ordinary` と、読める stored entry を合成する。対応する `ordinary` の有無、`.merge` / `.hide` / `.expose` の全組合せで一覧と他 member の読み取りを確認する。候補自体の read は引き続き `unsupportedMethod` になる。

追加テスト名: `AppleDoubleSidecarTests.testR7UnreadableSidecarCandidatesRemainVisible`（`run_test AppleDoubleSidecarTests.testR7UnreadableSidecarCandidatesRemainVisible`）。

修正前の失敗文:

```text
failed: caught error: "Unsupported archive method: 7"
```

修正ファイル: `Sources/KaitoKit/Formats/Wrappers/AppleDoubleReader.swift:112`。

修正内容: sidecar の stream 作成・prefix read・header 解析を probe として扱い、未対応形式 / method、破損、切断、checksum、password エラーでは候補を残す。`limitExceeded` と I/O、および `CancellationError` 等のその他のエラーは伝播させる。

## R8. AppleDouble resource fork 完了時の CRC

再現手順: 1,000 byte の AppleDouble stored member を作り、offset 38 に 4 byte の resource fork `RSRC` を入れる。fork 内の byte 38 または末尾 byte 999 を反転し、ZIP CRC は元のままにする。`.expose` の全体 read と `.merge` の fork read、1 byte ずつ読む最後の read、エラー後の再読が checksumMismatch になることを要求する。

追加テスト名: `AppleDoubleSidecarTests.testR8ResourceForkCompletionChecksTheWholeSidecarCRC`（`run_test AppleDoubleSidecarTests.testR8ResourceForkCompletionChecksTheWholeSidecarCRC`）。

修正前の失敗文:

```text
XCTAssertThrowsError failed: did not throw an error
```

修正ファイル: `Sources/KaitoKit/Formats/Wrappers/AppleDoubleReader.swift:256`。

修正内容: `SliceDecompressor.isFinished` を残り fork 長だけで決めず、元の stream を固定 64 KiB buffer で読み切ったあとに確定する。外側 `EntryStream` の既存 completion 検査から呼ぶため、fork の最後の byte を利用側へ返す前に sidecar 全体の CRC と終端を検証する。

## R9. UDIF 圧縮 chunk の終端と余剰出力

再現手順: 既存 `dmg/hfs-lzma.dmg.gz.b64` の 1 MiB XZ chunk を使用する。Index CRC の反転が単体 stream / disk read ともに拒否されることを確認した上で、有効な XZ はそのまま、blkx の chunk sector 数だけを 1 sector 減らして plist をメモリで再構成する。先頭 1 byte の disk read でも chunk 全体の展開を検証し、二度とも余剰出力を拒否することを要求する。

追加テスト名: `DMGReaderTests.testR9CompressedChunkMustReachValidatedEnd`（`run_test DMGReaderTests.testR9CompressedChunkMustReachValidatedEnd`）。

修正前の失敗文:

```text
XCTAssertThrowsError failed: did not throw an error
```

修正ファイル: `Sources/KaitoKit/Formats/DMG/UDIFImage.swift:278`。

修正内容: `drain` は期待長を満たした後も未完了 decoder から追加 read し、余剰出力なら `malformed`、0 byte でも未完了なら `truncated` とする。cache への追加は検証成功後だけ。原文の「XZ の末尾 1 byte 反転」は修正前から `XZResourceValidator` の footer 検査で拒否された。Index CRC 反転もこの環境の decoder では拒否されたため、それらを修正前失敗とは数えていない。実際に失敗したのは宣言長を短くした上記ケースで、共通原因である宣言長到達時の未完了 stream の受理を修正した。

## R10. native 署名と BinHex probe の優先順位

再現手順: 既存 `cfb/v3.cfb.gz.b64` の 4,096 byte stored stream の先頭（file 先頭から 64 KiB 内）を `(This file must be converted with BinHex 4.0)` に置き換える。detect が CFB、open の entry 一覧が元と同じで、stream から説明文を読み取れることを要求する。

追加テスト名: `CFBReaderTests.testR10NativeCFBSignatureWinsOverPayloadBinHexText`（`run_test CFBReaderTests.testR10NativeCFBSignatureWinsOverPayloadBinHexText`）。

修正前の失敗文:

```text
XCTAssertEqual failed: threw error "Malformed archive: BinHex alphabet"
failed: caught error: "Malformed archive: BinHex alphabet"
```

修正ファイル: `Sources/KaitoKit/Formats/FormatDetector.swift:205`。

修正内容: wrapper probe を除外する先頭署名に lzip、pbzx、WIM、CFB、CHM、ARJ を追加する。今回の payload は原文の `truncated` ではなく `BinHex alphabet` で失敗したが、native 署名より本文の BinHex 説明文を優先する同じ退行を再現している。

## R11. GNU sparse 0.1 の実名

再現手順: PAX に `GNU.sparse.name=real.txt`、header に `GNUSparseFile.123/real.txt` を置く sparse 0.1 tar を合成する。bsdtar が `real.txt` へ同じ bytes を展開することを先に確認し、KaitoKit の name、pathComponents、展開先、reopen と本文を照合する。

追加テスト名: `TarSparseTests.testR11Pax01PreservesSparseNameForListingAndExtraction`（`run_test TarSparseTests.testR11Pax01PreservesSparseNameForListingAndExtraction`）。

修正前の失敗文:

```text
XCTAssertEqual failed: ("GNUSparseFile.123/real.txt") is not equal to ("real.txt")
XCTAssertEqual failed: ("["GNUSparseFile.123", "real.txt"]") is not equal to ("["real.txt"]")
XCTUnwrap failed: expected non-nil value of type "ArchiveEntry" - 0.1 name
```

修正ファイル: `Sources/KaitoKit/Formats/Tar/TarReader.swift:1223`。

修正内容: 0.0 / 0.1 分岐からも、与えられた `GNU.sparse.name` を返して既存の名前処理へ渡す。名前が無い既存 fixture の挙動は変わらない。

## R12. ZIP Shrink の連続部分クリア

再現手順: 9 bit LSB-first code `[65,66,67,256,2,256,2,68,257]` をテスト内で pack し、method 1 の ZIP を組み立てる。期待 bytes と CRC は `ABCDCD`。一括 read と 1 byte stream read の両方を確認する。

追加テスト名: `ZipLegacyMethodTests.testR12SuccessivePartialClearsRetainUnusedCodes`（`run_test ZipLegacyMethodTests.testR12SuccessivePartialClearsRetainUnusedCodes`）。

修正前の失敗文:

```text
XCTAssertEqual failed: threw error "Malformed archive: ZIP shrink undefined code 257"
failed: caught error: "Malformed archive: ZIP shrink undefined code 257"
```

修正ファイル: `Sources/KaitoKit/Codecs/ZipLegacy/ZipLegacyDecompressors.swift:132`。

修正内容: 今回の葉だけを free list にせず、既に払い出した範囲 `257..<nextCode` の未定義 code 全体を昇順で再構成する。前回解放後に未使用の code も残り、低い番号から再利用される。

## R13. StuffIt 分割の巻数上限ちょうど

再現手順: 既存 StuffIt MacBinary fixture の data / resource fork から、1 巻と 128 巻の `x.sit.N` を一時 directory に合成する。それぞれ上限を巻数に合わせ、先頭 / 最後の URL と reopen の digest を元書庫と照合する。その後 `x.sit.(N+1)` を追加し、上限超過の拒否も確認する。

追加テスト名: `StuffItSplitTests.testR13CompleteSetsAtTheVolumeLimitOpenButExtraPartsFail`（`run_test StuffItSplitTests.testR13CompleteSetsAtTheVolumeLimitOpenButExtraPartsFail`）。

修正前の失敗文:

```text
failed: caught error: "Read limit exceeded: StuffIt split part count"
```

修正ファイル: `Sources/KaitoKit/Formats/Wrappers/StuffItSplit.swift:166`。

修正内容: 次の兄弟 part を開けた後に `number <= maxVolumeCount` を調べる。完結セットの不存在の次巻では拒否せず、実在する超過 part は解析前に拒否する。

## R14. Mac wrapper の公開 entry 数上限

再現手順: 既存 `noresource.bin` を上限 0、`readme.txt.bin` / `readme.txt.as` / `readme.txt.hqx` を上限 1 で開き、`limitExceeded` を要求する。上限を実 entry 数の 1 / 2 にすると受理することも確認する。

追加テスト名: `MacWrapperTests.testR14PublishedForksRespectEntryCountLimit`（`run_test MacWrapperTests.testR14PublishedForksRespectEntryCountLimit`）。

修正前の失敗文:

```text
XCTAssertThrowsError failed: did not throw an error - noresource.bin
XCTAssertThrowsError failed: did not throw an error - readme.txt.bin
XCTAssertThrowsError failed: did not throw an error - readme.txt.as
XCTAssertThrowsError failed: did not throw an error - readme.txt.hqx
```

修正ファイル: `Sources/KaitoKit/Formats/Wrappers/MacWrapperReader.swift:73`。

修正内容: data fork と optional resource fork の最終公開数を `maxEntryCount` と比較してから `entries` に代入する。公開 API と ReaderOptions の既定値は変更しない。

## 文書の回帰検査

`ReleaseReviewDocumentationTests.testRelease081DocumentsAllFourteenReviewFixes` を追加した。0.8.1 節の R1〜R14、各検証見出し、README / CHANGELOG からのリンクを検査する。文書作成前の失敗は次のとおり。既存の 0.7.0 用テストは変更していない。

```text
XCTAssertEqual failed: ("1") is not equal to ("2") - 0.8.1 節が必要
```

## 最終検証

- 回帰テスト R1〜R14: 14 件実行、失敗 0、skip 0。
- 関連形式・既存検出テスト: KaitoKitTests 62 件と Compat 1 件、失敗 0、skip 0。
- `swift build`: 成功。上記の sandbox 対応コマンドを使用。
- 全件 `swift test`: 1,393 件（成功 1,348、失敗 0、skip 45）。追加した 14 件と文書テスト 1 件も全件実行内で成功。終了コード 0。

```text
Executed 1359 tests, with 45 tests skipped and 0 failures (0 unexpected) in 431.067 (431.164) seconds
Executed 34 tests, with 0 failures (0 unexpected) in 2.105 (2.109) seconds
```

skip はすべて HEAD に存在する既存テストで、新規 skip はない。外部コーパス・任意 oracle の環境変数未指定、明示実行する 32 MiB 距離検査など、既存の条件による。テストクラス別の内訳は次のとおり。

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

全件ログは `/tmp/kaito-081-full-tests.log`。`git diff --check` は成功し、`git status --short` の変更 24 ファイル（新規検証記録を含む）は Sources / Tests / CHANGELOG.md / README.md / Documentation/verification の範囲内。既存 fixture / SHA256SUMS への差分はなく、既存テストの削除・期待値変更もない。

CLI は次の実コマンドで確認した。

```sh
printf '\x60\xea\x01\x00\x00\x8d\xef\x02\xd2' > /tmp/kaito-crash.arj
.build/debug/kaito list /tmp/kaito-crash.arj
```

```text
error: Unsupported archive format
exit=1
```

異常終了や trap は発生しない。公開 API、ArchiveFormat の case、ReaderOptions の既定値は変更していない。未修正とした指摘はない。ただし R9 の原文どおりの footer 反転は修正前から拒否されるため、新規修正の根拠は上記の宣言長超過の再現であり、footer 検査自体は変更していない。既存テストの期待値や規約の変更もない。

## オーケストレータによる独立検証（2026-09-22 09:3x〜09:4x）

上記は Codex（sandbox 内、`--disable-sandbox` と `.build` 配下の cache を指定）の記録。オーケストレータは通常のシェルで同じ作業ツリーを検証した。

- `swift build`: 成功（103 秒）。
- `.build/debug/kaito list` に 9 byte の `.arj` を与えると `error: Unsupported archive format`、終了コード 1（修正前は同じ入力で `Fatal error: Index out of range` を確認済み）。
- `KAITO_REQUIRE_7ZZ=1 KAITO_REQUIRE_XZ=1 KAITO_REQUIRE_BROTLI=1 swift test`（CI と同じ oracle 必須指定）: XCTest 1,359 件（skip 45、失敗 0）+ Swift Testing 34 件（失敗 0）= 1,393 件、失敗 0。
- 修正前の失敗の再確認（`git show HEAD:` で `ZipLegacyDecompressors.swift` と `StuffItSplit.swift` だけを v0.8.0 の内容に戻し、`swift test --filter` で個別実行、その後 cp で修正版を復元）:
  - R12: `XCTAssertEqual failed: threw error "Malformed archive: ZIP shrink undefined code 257"`
  - R13: `failed: caught error: "Read limit exceeded: StuffIt split part count"`

この修正は Codex review（built-in reviewer、`v0.7.0` 基点）の 14 件の指摘に対するもの。最初の Codex 実行は内容フィルタで中断したため、同じ thread に「自リポジトリの parser の入力検証の強化」として言い直して再開した（CLAUDE.md の例外手順の 1 段目）。
