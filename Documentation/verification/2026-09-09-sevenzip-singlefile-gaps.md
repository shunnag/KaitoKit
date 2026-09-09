# 7z / single-file 互換性追補 (2026-09-09)

依頼項目 1・3・4 を実装した。項目 2 は許可資料に変換規則が無いため、
SPARC・IA-64・RISC-V のすべてを未実装のままとした。
第三者 archive decoder の実装 source は参照していない。
`Documentation/design.md` と指定された RAR 関連 source は変更していない。
commit / push は行っていない。

## 参照資料

| 項目 / format / filter | 今回参照した文書と用途 |
| --- | --- |
| 1: 7z coder chain | LZMA SDK [7zFormat.txt, 18.06](https://raw.githubusercontent.com/ip7z/7zip/main/DOC/7zFormat.txt)、Folder / Coders Info の binding と各出力の UnPackSize。以下の SDK 文書も method / LZMA の確認に参照。新しい codec grammar は実装していない |
| 1: テスト用 DEFLATE | [RFC 1951 (May 1996), §3.2.3–3.2.4](https://www.rfc-editor.org/rfc/rfc1951.html)、二重 stored block の BFINAL / LEN / NLEN |
| 2: SPARC | LZMA SDK [Methods.txt, 24.02 (2024-03-22)](https://raw.githubusercontent.com/ip7z/7zip/main/DOC/Methods.txt) の ID 09 / 03030805。同文書・7zFormat.txt・lzma-specification.txt に変換規則は無い。実装なし |
| 2: IA-64 | 同じ Methods.txt の ID 06 / 03030401。同じ 3 文書に変換規則は無い。実装なし |
| 2: RISC-V | 同じ Methods.txt の ID 0B。同じ 3 文書に変換規則は無い。実装なし |
| 3: LZMA_Alone | Igor Pavlov, LZMA SDK [lzma-specification.txt, DRAFT 2015-06-14](https://raw.githubusercontent.com/welovegit/LZMA-SDK/master/DOC/lzma-specification.txt)、lzma file format / Range Decoder。13-byte header、properties、辞書最小値、unknown-size sentinel、先頭 range byte |
| 4: compress / tar | 新規の外部仕様参照なし。依頼の suffix 要件と、既存 KaitoKit の `compressedTarFormat(for:)`、`SingleFileReader`、`LZWDecoder` の呼出し契約、`SingleFileMaterializer` / `TarReader` 接続を利用。LZW / tar の復号 grammar は変更していない |

7zFormat.txt は [LZMA-SDK mirror の同じ 18.06 文書](https://raw.githubusercontent.com/welovegit/LZMA-SDK/master/DOC/7zFormat.txt) も開いた。
公式 repository の lzma-specification.txt URL、7-zip.org 上の候補 URL、mirror の Methods.txt URL は取得できず、実装入力にしていない。
ISA 文書は参照していない。ISA encoding だけでは filter 作者が選んだ候補選択・即値変換・PC 補正規則を定義できないためである。
リポジトリ内では `Documentation/design.md` §10、依頼対象の既存コードと XCTest / fixture helper の規約を確認した。

## 変更点

1. `SevenZipFolderPipeline.swift` の `SevenZipPipelineValue.asBytes(expectedSize:limits:)`
   と factory 内の `byteInput(_:)`。bound output の宣言サイズで `Data` を事前確保し、
   短い出力と余分な出力を拒否する。確保前に `maxInMemorySize` と
   `maxTotalUncompressedSize` を検査する。既存 `.bytes` はそのまま返すため、
   packed input と AES が返す `SevenZipAESByteSource` に中間 buffer は追加されない。
   cycle / arity 検査は維持した。
2. 変更なし。既存の短い PPC / ARM / ARMT / ARM64 ID はすでに対応済み。
   不明な変換を推測して `.branch` に振り分けることはしていない。
3. `SingleFileReader.swift` の `LZMAAloneHeader`、reader 初期化と
   `makeDecompressor(format:source:limits:)`、`FormatDetector.detect`、
   `ArchiveFormat.lzma`、`ArchiveReader` dispatch、CLI `formatName`。
   辞書・宣言サイズを制限し、既存 `LZMADecoder` へ先頭 5 bytes を渡す。
   検出は最後に実行し、`.lzma` 拡張子、lc+lp <= 4 / pb <= 4、
   4 KiB 以上の 2^n または 3*2^n 辞書、上限内のサイズまたは unknown sentinel、
   先頭 range byte 0 を要求する。辞書形状の制限は検出時の保守的な方針であり、
   LZMA 仕様そのものの制約ではない。拡張子の無い URL / Data では自動検出しない。
4. `ArchiveReader.compressedTarFormat(for:)` に `.tar.Z` / `.tZ` を追加した。
   既存の memory / unlinked temporary-file staging をそのまま使用する。

## 回帰テストと source stash

追加 XCTest は次の 7 件。fixture は `TestZipSupport.checkedInFixture(_:)` で
既存の `Data(base64Encoded:options: .ignoreUnknownCharacters)` 規約に従って読む。

- `SevenZipIntegrationTests.testStreamingCoderChainCheckedInFixture`
- `SevenZipIntegrationTests.testStreamingCoderMaterializationLimitsAndDeclaredSizes`
- `SingleFileFormatTests.testLZMAAloneKnownAndUnknownSizes`
- `SingleFileFormatTests.testLZMAAloneLimitsMalformedHeadersAndTruncation`
- `SingleFileFormatTests.testCompressTarCheckedInFixtureMemoryAndFileStaging`
- `FormatDetectorM5Tests.testLZMAAloneDetectionRequiresHintAndRejectsNonArchives`
- `FormatDetectorM5Tests.testLZMAAloneDetectionChecksPropertiesLimitsAndRunsLast`

negative detection は OS の image writer が生成した完全な JPEG / PNG、UTF-8 text、
64 KiB の決定的な疑似乱数、64 KiB のゼロを、Data と `.lzma` URL の両方で検査した。
negative だけで常時拒否する検出器が通らないよう、同じ test に正例を含めた。

workspace の `.git` が read-only のため、次の temporary Git metadata を使って、
実際の workspace から **source 6 files だけ**を `git stash` した。test 4 files は保持した。

```sh
git clone --shared --no-checkout <repo> /tmp/kaito-gap-stash-repo
git --git-dir=/tmp/kaito-gap-stash-repo/.git --work-tree=<repo> read-tree HEAD
git --git-dir=/tmp/kaito-gap-stash-repo/.git --work-tree=<repo> stash push -m kaito-gap-source-regression-check -- Sources/KaitoKit/Formats/FormatDetector.swift Sources/KaitoKit/Formats/SevenZip/SevenZipFolderPipeline.swift Sources/KaitoKit/Formats/SingleFile/SingleFileReader.swift Sources/KaitoKit/Model/ArchiveFormat.swift Sources/KaitoKit/Reader/ArchiveReader.swift Sources/kaito/main.swift
```

同じ 7 tests を実行し、すべてがコンパイル後の test 実行で失敗することを確認した。
続けて同じ metadata に対する `git stash pop` で source を復元した。

```text
Saved working directory and index state On main: kaito-gap-source-regression-check
Unsupported archive method: 7z LZMA after a streaming coder
Unsupported archive method: 7z Deflate after a streaming coder
Unsupported archive format
XCTUnwrap failed: expected non-nil value of type "ArchiveFormat"
XCTAssertEqual failed: ("compress") is not equal to ("tar")
XCTAssertEqual failed: ("9728 bytes") is not equal to ("8192 bytes")
Executed 7 tests, with 32 failures (6 unexpected) in 0.188 (0.189) seconds
```

変更後の同じ focused test run:

```text
Executed 7 tests, with 0 failures (0 unexpected) in 0.545 (0.546) seconds
```

## 実行環境

既定の Xcode-beta / Swift 6.4 は user cache の書込みと dSYM 作成で sandbox 制限に当たった。
検証には installed Xcode の Swift 6.3.3 と writable な `/tmp` cache を使用した。
package / language mode の設定は変更していない。

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH=/tmp/kaito-gap-module-cache
swift build --disable-sandbox --cache-path /tmp/kaito-gap-cache --config-path /tmp/kaito-gap-config --security-path /tmp/kaito-gap-security -c release
swift test --disable-sandbox --cache-path /tmp/kaito-gap-cache --config-path /tmp/kaito-gap-config --security-path /tmp/kaito-gap-security
```

復元後の full suite は 2026-09-09 09:48:04 に完了した。warning は無い。
skip は既存の外部 corpus / tool 能力依存テストで、追加 7 tests はすべて実行・成功した。

```text
Test Suite 'All tests' passed at 2026-09-09 09:48:04.683.
Executed 653 tests, with 33 tests skipped and 0 failures (0 unexpected) in 158.648 (158.690) seconds
```

release build も warning 無し、exit status 0 で完了した:

```text
[8/10] Linking libKaitoKitDynamic.dylib
[9/10] Linking kaito
Build complete! (33.46s)
```

## CLI fixture 検証

```sh
base64 -d < Tests/Fixtures/sevenzip/chain-lzma-lzma-lzma2-bcj2.7z.b64 > /tmp/kaito-gap-chain.7z
.build/release/kaito sha /tmp/kaito-gap-chain.7z
base64 -d < Tests/Fixtures/singlefile/alone.lzma.b64 > /tmp/kaito-gap-alone.lzma
.build/release/kaito sha /tmp/kaito-gap-alone.lzma
base64 -d < Tests/Fixtures/singlefile/tar-compress.tar.Z.b64 > /tmp/kaito-gap.tar.Z
.build/release/kaito list /tmp/kaito-gap.tar.Z
```

LZMA_Alone は依頼の filename-hint 条件に従うので、extension の無い `/tmp/fx` では
`Unsupported archive format` となる。検証には `.lzma` extension を残した。
出力 entry 名は filename fallback によるもので、LZMA_Alone 内に元の名前は無い。

実際の出力 (順に chain / Alone / tar.Z):

```text
0	8192	50707e3abaa5a1b0676e0bd6b120133034ba7358c4584acc2b473207e015a2b8	code.bin
total	1	852ec24f56c14a5ce56e720007aecc24ff5cac5e523acf5dbcebecdf1ff2be35
0	8192	50707e3abaa5a1b0676e0bd6b120133034ba7358c4584acc2b473207e015a2b8	kaito-gap-alone
total	1	852ec24f56c14a5ce56e720007aecc24ff5cac5e523acf5dbcebecdf1ff2be35
0	8192	file	tar (stored)	plain	code.bin
```

未実装 filter の fixtures も実行し、対応済みとは扱っていないことを確認した:

```text
error: failed entry 0 (code.bin): Unsupported archive method: 7z SPARC filter
error: failed entry 0 (code.bin): Unsupported archive method: 7z IA64 filter
error: failed entry 0 (code.bin): Unsupported archive method: 7z method 0x0B
```

項目 2 の成功 digest / fail-without-fix 検査は未達であり、
`SevenZipFilterTests.swift` に対応を装う test は追加していない。
