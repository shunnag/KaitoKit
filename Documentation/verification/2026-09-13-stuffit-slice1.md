# StuffIt slice 1 検証記録（2026-09-13、bd `cooViewer-gu28.1`）

## 対象と入力

`feat/stuffit` worktree に classic / StuffIt 5、MacBinary / AppleSingle / BinHex 4、
method 0 / 1 / 2 / 3 / 13 / 15 を実装した。暗号・method 5/6/8/14・StuffIt X・
実行ファイル stub の探索は後続 slice。AppleDouble は data fork を別ファイルに持つため非対応。
LHA の `MacBinaryDataForkDecompressor.swift` は変更していない。

実装入力は `inbox/stuffit/` の次の 11 ファイルだけで、すべて同梱 `SHA256SUMS` と一致した。
既存 KaitoKit の契約・CRC・byte source・EncodingPolicy はそのまま利用した。
Web、および XADMaster / The Unarchiver / stuffit-go / libxad / macutils その他の StuffIt
実装ソースは開かず、検索・参照していない。コーパスはデータとして読み、実行していない。

| 入力 | 使用箇所 |
|---|---|
| `report/00-conventions.md` | byte order、CRC、epoch、根拠区分 |
| `report/01-classic-stuffit.md` | 署名、22/112 byte header、directory stack、fork 配置 |
| `report/02-stuffit5.md` | banner、archive/primary CRC、可変 header、親参照、ignored marker。RC4 節は読んだが未実装 |
| `report/04-classic-codecs.md` | 共通 bit/history と method 0/1/2/3/13/15 の節だけ |
| `report/06-wrappers-and-segments.md` | MacBinary / BinHex / AppleSingle・Double、resource map。MKey / SitC は解釈せず書庫の resource を保持 |
| `report/11-verification-and-limits.md` | 有限な検証と未確定事項の限界 |
| `report/tables/method13.json` | 固定表 1〜5、meta code |
| `report/tables/arsenic-randomization.json` | 256 個の間隔定数 |
| `research/core-vectors.json` | 対象 method の独立作成 vector |
| `research/archive-verification.json` | 平文・対応 method の fork SHA-256 |
| `research/THIRD_PARTY_DATA.md` | 形式定数の転記元の記録 |

## 実装と厳格性

- wrapper は一段だけ。MacBinary / AppleSingle の data fork は `RebasedByteSource` と
  `BoundedByteSource` の組合せで区間を限定する。書庫自身の resource fork も source として保持する。
  BinHex は全体を連続 RLE90 状態で復号し、3 CRC を照合、復号サイズに `maxInMemorySize` を適用する。
- classic entry CRC と StuffIt 5 archive/primary CRC を照合する。stored fork の宣言範囲、
  directory marker の矛盾・空 stack・未閉鎖、SIT5 の comment 長・親の存在・子数を検証する。
  ignored marker は 48 byte 消費し、entry 数を減らさない。
- data / resource を独立 entry とし、resource は `名前/..namedfork/rsrc`。
  rawName、1904 年起点の更新時刻、container・type・creator・Finder flags・fork を公開する。
- method 0 の長さ不一致は malformed。RLE90 の count 1、LZW の不正 code、Huffman の不正木、
  method 13 の範囲外長さ・alphabet を跨ぐ run を拒否する。必要な出力に足りない入力は truncated。
  容器の final length を得た後に codec 終端記号が残ることは許容するが、出力 token の途中で
  宣言長を超える場合は malformed とする。全圧縮入力の終端構文を検証したとは主張しない。
- Arsenic は 26 bit 初期 code、除算を先に行う range 更新、model ごとの更新と rescale、
  run の overflow、MTF、move-before-emit BWT、238 起点の randomization、最終 RLE と CRC32 を検証する。
  外側の CRC16 は method 15 のみ省略する。レポートの実際の wire header は独立した N を持たず、
  capacity と primary index を持つため、実 rank 数 N を capacity 以下に抑え、primary < N を検証する。
- hot loop の辞書・木・model・MTF・BWT は固定ポインタ領域。BWT は capacity byte の列と
  実 N 個の UInt32 置換表を保持し、宣言 capacity × 5 + 固定領域を dictionary 上限で検査する。
  出力 fork 全体の中間配列は持たず、`Decompressor.read(into:)` の宛先へ逐次書く。
- 未対応 method と暗号は列挙後の stream 取得時に `unsupportedMethod`。
  暗号非対応の段階で password provider が呼ばれて `passwordRequired` に変わらないようにした。

## 観測に基づく判断・仕様文との相違

1. **vector の実数は 11 本。** 指示中の「10 本」に対し、指定された method の vector は
   RLE90/LZW/Huffman 各 1、method 13 が 6、Arsenic が 2。すべて hex のまま固定した。
2. **Huffman の leaf は byte 種類数より多い。** `v1.5-lzw-comment.sit` の SimpleText resource は
   513 node・257 leaf・256 種類・深さ 11。node 511 / leaf 256 ではこの正常標本を拒否するため、
   明示 stack、深さ ≤256・node ≤1023 とした。257 leaf の合成テストも追加した。
3. **BinHex の最終ゼロ埋め。** CC0 の 44 `.hqx` を説明された 6-bit/RLE 規則で観測すると、
   fork CRC の後は、余分なし 29、本体外 `00` が 7、`0000` が 8。CRC は宣言区間だけで一致する。
   最大 2 byte のゼロ埋めを許容し、非ゼロ・それ以上は拒否する。該当 `.hqx` を fixture に含めた。
4. **オラクルは data fork だけ。** 支給 `.sha` は resource-only の Test Image / SimpleText /
   NCSA Mosaic を空 data として出力する。従って `kaito sha` の StuffIt 既定動作は data fork の
   検証・表示とし、resource-only は空 data の行を表示する。`sha --forks` は reader が公開する
   全 fork を検証・表示する。reader の公開 entry は仕様どおりであり、省略しない。
   また `compare.py` は非ゼロ終了でも先に stdout のサイズを整数化するため、StuffIt の失敗詳細は
   stderr に限定した。支給スクリプトは一切変更せず実行した。
5. **`v1-huffman.sit` の壊れた resource CRC。** SimpleText resource は出力 58,768 byte、
   格納 CRC `4579` に対して実 CRC `d303`、SHA-256
   `f6019cd27eb7c7c25dc4d030186d09cbfdc984a36888f57d86f450c909d0656d`。
   指定散文からの独立した Python 木走査でも一致した。別標本 `v1.5-lzw-comment.sit` と
   `v1-nocompression.sit` は CRC `4579`、SHA-256
   `e723b7dba9c45f352e366898dc3b9d377f6b7531a7a365c6e51b40368af79ced`。
   オラクルは空 data だけで resource を検査していない。既定 `sha` は完全一致するが、
   `reader.read(resource)` / `sha --forks` は正しく checksumMismatch を返す。この失敗を隠さない。
6. **fixture の選択。** 指定 6 writer を含めたが、7 win の `.sea` はコーパスに存在しない。
   `.exe` を代用したり、未提供の書庫を合成して vendor fixture と扱うことはしない。
   `.sea` wrapper は多くが 40 KB を超えるため、wrapper 3 種の組は `.sit` に置き、
   classic `.sea.bin` を別に含めた。26 本・base64 最大 38,043 byte、合計 135,447 byte。
7. **暗号化 fixture の期待値。** classic パスワード標本のオラクルは data をサイズ 0 として返す。
   列挙する名前・サイズは対応する平文標本のオラクルと report の resource 値に固定し、復号は検査しない。
8. **archive-verification の対象。** 全 13 書庫のうち、今回の平文かつ対応 method は 6 書庫・41 fork。
   `v1-fhf-faster.sit` は classic だが method 6 のため slice 2、パスワード付きも slice 2、SITX は slice 3。
   それらの出力 SHA が検証済みだとは主張しない。

## コーパス比較

実行した支給コマンド:

```sh
python3 inbox/stuffit-corpus/compare.py .build/out/Products/Release/kaito
```

```text
match: 110
name_diff: 0
no_oracle: 0
kaito_error: 106
mismatch: 0
```

216 本すべてを実行し、終了コード 0。match のうち 81 本は wrapper。
エラー分類は重複を避けて `.sitx` → `.exe` → password の順で数えた。

| kaito_error の内訳 | 件数 | 挙動 |
|---|---:|---|
| `.sitx`（wrapper を含む） | 48 | unsupportedFormat |
| `.exe` | 21 | unsupportedFormat |
| その他のパスワード付き | 37 | unsupportedMethod("StuffIt encryption") |
| 想定外 | 0 | — |

支給 `compare.py` 自体はエラー詳細を 40 本までしか表示しないため、同スクリプトを無改変で
実行した名前空間の report 全体も収集した。対応する CC0 110 書庫をさらに `sha --forks` で読み、
全 1,014 行（directory の空行を含む）が成功。非空 fork は、対応する oracle の data SHA と
`archive-verification.json` の resource SHA に一致した。receipt entry の data は各 oracle を用いた。

指定 go 9 標本の `sha` は index・size・SHA・name・total の全行が `oracle/go/` と一致した。
`--forks` も 8 本は成功し、残る `v1-huffman.sit` は上記の resource CRC 不一致を報告した。

```text
go required: 9 exact matches
CC0 all forks: 110 archives, 1014 rows
```

`SITv1-2.sit` は指定 9 本の外であり、外側が MacBinary。
オラクルは wrapper 自身の data (`fixer.sit`) を提示するが、今回の reader は内側の書庫を公開する。
method 5/6/8 を含む他の go 標本、暗号化標本も指定どおり未対応。go の書庫実体は fixture に含めない。

## ビルド・テスト・環境

SwiftPM の既定 cache は許可された書込み範囲外だったため、初回の素の `swift build` は
cache 警告 3 件と manifest の module-cache 書込みエラーで停止した。以降は cache / config /
security / module-cache / TMPDIR を worktree 内に指定し、SwiftPM の入れ子 sandbox を無効化した。
既存テストの `/tmp` と `/private/tmp` の URL 表記差を避け、TMPDIR は同じ worktree の `/tmp` 表記。
release の dSYM 生成に依存しないよう `-debug-info-format none` を使用した。製品設定は変更しない。

```sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/stuffit-check/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/stuffit-check/module-cache"
export TMPDIR="${PWD#/private}/.build/stuffit-check/tmp"
swift_options=(--disable-sandbox --cache-path .build/stuffit-check/cache
  --config-path .build/stuffit-check/config --security-path .build/stuffit-check/security
  -debug-info-format none)
swift build "${swift_options[@]}"
swift test "${swift_options[@]}"
swift build -c release --product kaito "${swift_options[@]}"
```

最終集計は以下に記す。

| コマンド | 最終結果 |
|---|---|
| `swift build`（上記環境引数） | exit 0、`Build complete! (1.51秒)`、警告 0 |
| `swift test`（上記環境引数） | exit 0、計 956 tests、38 skip、失敗 0、警告 0 |
| `swift build -c release --product kaito`（上記環境引数） | exit 0、`Build complete! (30.95秒)`、警告 0 |
| `compare.py`（最終 release） | exit 0、match 110 / name_diff 0 / no_oracle 0 / kaito_error 106 / mismatch 0 |
| ASan の test bundle を直接実行 | exit 0、30 tests、失敗 0、所見 0 |
| `git diff --check` | exit 0、出力なし |

全テストの出力:

```text
Executed 933 tests, with 38 tests skipped and 0 failures (0 unexpected) in 286.504 (286.570) seconds
Executed 23 tests, with 0 failures (0 unexpected) in 0.783 (0.785) seconds
```

933 件が KaitoKitTests、23 件が KaitoKitCompatTests。38 skip は既存の外部ツール・標本条件。
StuffIt の 30 tests は、この worktree ではすべて実行されている。

最終 release `kaito` の SHA-256 は
`8f88233f5b5ea71b8b05342cb4590a6e6adb71b15612a8a623b16b6a45197afd`。

指定 CLI コマンドも最終 release で実行した（ともに exit 0）:

```sh
.build/out/Products/Release/kaito list inbox/stuffit-corpus/cc0/testfile.stuffit651_dlx.mac9.sit
.build/out/Products/Release/kaito sha inbox/stuffit-corpus/go/SITv1-13.sit
```

`list` は 9 entry（resource 4 / data 5）を `fork=resource` / `fork=data` 付きで表示した。

```text
0	9134	file	StuffIt method 15 (Arsenic)	plain	Test Image/..namedfork/rsrc	fork=resource
1	332	file	StuffIt method 15 (Arsenic)	plain	Test Text/..namedfork/rsrc	fork=resource
2	11	file	StuffIt method 0 (Stored)	plain	Test Text	fork=data
3	220	file	StuffIt method 0 (Stored)	plain	testfile.jpg	fork=data
4	44549	file	StuffIt method 15 (Arsenic)	plain	testfile.PICT/..namedfork/rsrc	fork=resource
5	2694	file	StuffIt method 15 (Arsenic)	plain	testfile.PICT	fork=data
6	87	file	StuffIt method 0 (Stored)	plain	testfile.png	fork=data
7	332	file	StuffIt method 15 (Arsenic)	plain	testfile.txt/..namedfork/rsrc	fork=resource
8	12	file	StuffIt method 0 (Stored)	plain	testfile.txt	fork=data
```

`sha` の出力は次のとおりで、oracle/go/SITv1-13.sit.sha と完全一致する。

```text
0	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	NCSA Mosaic 1.0.2
total	1	cd372fb85148700fa88095e3492d3f9f5beb43e555e5ff26d95f5a6adc36f8e6
```

ログは `.build/stuffit-check/` の `build-final.log`、`test-full.log`、
`build-release-final.log`、`compare-final.log`、`list-final.log`、`sha-final.log`、
`test-asan-direct.log`。全コーパスのエラー内訳・full-fork 行数・go 比較は
`corpus-report.json` / `corpus-summary-final.log` に保存した。

局所検証は容器 → wrapper → 小 codec → method 13 → Arsenic → fixture → 境界条件の順で実行。
最終 StuffIt テストは 30 件。11 vector は 1 / 7 / 4096 byte の呼出し幅で一致する。
ヘッダ CRC・declared extent・directory 矛盾・未知の親・ignored marker・文字コード・各種上限・
password provider 抑制・Huffman 257 leaf・LZW 9〜14 bit と full dictionary / clear padding・
method 13 の不正 run・1 byte ずつしか返さない ByteSource を含む。

ASan の build は成功したが、`swift test` の列挙 helper は runtime の読み込み順で
`Interceptors are not working` と停止した。環境変数を SwiftPM に渡しても同じだったため、
同じ build 済み test bundle を、runtime を先読みする `xctest` で直接実行した。

```sh
swift test --scratch-path .build-asan --filter StuffIt -Xswiftc -sanitize=address "${swift_options[@]}"
DYLD_INSERT_LIBRARIES=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/21/lib/darwin/libclang_rt.asan_osx_dynamic.dylib \
/Applications/Xcode.app/Contents/Developer/usr/bin/xctest \
  -XCTest KaitoKitTests.StuffItCodecTests,KaitoKitTests.StuffItContainerTests,KaitoKitTests.StuffItCorpusTests,KaitoKitTests.StuffItHardeningTests,KaitoKitTests.StuffItWrapperTests \
  .build-asan/out/Products/Debug/KaitoKitTests.xctest
```

```text
Executed 30 tests, with 0 failures (0 unexpected)
```

直接実行の終了コード 0、ASan 所見 0。有限な fixture と構成テストであり、全 malformed 入力の
網羅や性能優位は主張しない。slice 1 では他実装との速度比較は実施していない。

## 変更ファイル


Sources/KaitoKit/Formats/StuffIt

- `StuffIt5Parser.swift`
- `StuffItParser.swift`
- `StuffItReader.swift`

Sources/KaitoKit/Formats/Wrappers

- `StuffItWrapper.swift`

Sources/KaitoKit/Codecs/StuffIt

- `StuffItArsenic.swift`
- `StuffItArsenicArithmetic.swift`
- `StuffItCodec.swift`
- `StuffItHuffman.swift`
- `StuffItLZW.swift`
- `StuffItMethod13.swift`
- `StuffItPackedInput.swift`
- `StuffItRLE90.swift`
- `StuffItTables.swift`

既存の変更:

- `Sources/KaitoKit/Model/ArchiveFormat.swift`
- `Sources/KaitoKit/Formats/FormatDetector.swift`
- `Sources/KaitoKit/Reader/ArchiveReader.swift`
- `Sources/kaito/main.swift`
- `Sources/KaitoKitCompat/KaitoArchive.swift`
- `Tests/Fixtures/NOTICE`
- `CHANGELOG.md`
- `README.md`
- `Documentation/design.md`

追加テスト:

- `Tests/KaitoKitTests/StuffItCodecTests.swift`
- `Tests/KaitoKitTests/StuffItContainerTests.swift`
- `Tests/KaitoKitTests/StuffItCorpusTests.swift`
- `Tests/KaitoKitTests/StuffItHardeningTests.swift`
- `Tests/KaitoKitTests/StuffItWrapperTests.swift`

本検証記録と `Tests/Fixtures/stuffit/{manifest.json,verified-forks.json}` も追加。
既存の未追跡 `Documentation/stuffit-plan.md` は変更していない。

## fixture 一覧

すべて `Tests/Fixtures/stuffit/<元ファイル名>.b64`。SHA と entry 期待値は manifest.json。

| 元ファイル名 | archive byte | base64 byte | 暗号 |
|---|---:|---:|---|
| `testfile.stuffit45_dlx.mac9.sit` | 2,804 | 3,790 | 平文 |
| `testfile.stuffit45_dlx.mac9.sea` | 2,804 | 3,790 | 平文 |
| `testfile.stuffit651_dlx.mac9.sit` | 2,776 | 3,753 | 平文 |
| `testfile.stuffit651_dlx.mac9.sea` | 2,776 | 3,753 | 平文 |
| `testfile.stuffit651_dlx.macx1.sit` | 2,776 | 3,753 | 平文 |
| `testfile.stuffit651_dlx.macx1.sea` | 2,776 | 3,753 | 平文 |
| `testfile.stuffit7_dlx.mac9.sit` | 2,514 | 3,397 | 平文 |
| `testfile.stuffit7_dlx.mac9.sea` | 2,514 | 3,397 | 平文 |
| `testfile.stuffit7_dlx.macx1.sit` | 2,514 | 3,397 | 平文 |
| `testfile.stuffit7_dlx.macx1.sea` | 2,514 | 3,397 | 平文 |
| `testfile.stuffit7.win.sit` | 795 | 1,074 | 平文 |
| `testfile.stuffit45_dlx.mac9.comment.sit` | 2,804 | 3,790 | 平文 |
| `testfile.stuffit651_dlx.mac9.comment.sit` | 2,814 | 3,802 | 平文 |
| `testfile.stuffit45_dlx.mac9.sit.bin` | 3,456 | 4,669 | 平文 |
| `testfile.stuffit45_dlx.mac9.sit.AS` | 3,437 | 4,645 | 平文 |
| `testfile.stuffit45_dlx.mac9.sit.hqx` | 3,766 | 5,091 | 平文 |
| `testfile.stuffit651_dlx.mac9.sit.bin` | 3,328 | 4,499 | 平文 |
| `testfile.stuffit651_dlx.mac9.sit.as` | 3,307 | 4,471 | 平文 |
| `testfile.stuffit651_dlx.mac9.sit.hqx` | 3,821 | 5,164 | 平文 |
| `testfile.stuffit7_dlx.macx1.comment.sit.bin` | 2,688 | 3,632 | 平文 |
| `testfile.stuffit7_dlx.macx1.comment.sit.as` | 2,655 | 3,587 | 平文 |
| `testfile.stuffit7_dlx.macx1.comment.sit.hqx` | 3,311 | 4,475 | 平文 |
| `testfile.stuffit45_dlx.mac9.password.sit` | 2,990 | 4,041 | 列挙のみ |
| `testfile.stuffit651_dlx.mac9.password.sit` | 2,827 | 3,822 | 列挙のみ |
| `testfile.stuffit7_dlx.mac9.sit.hqx` | 3,303 | 4,462 | 平文 |
| `testfile.stuffit45_dlx.mac9.sea.bin` | 28,160 | 38,043 | 平文 |

## orchestrator による独立検証

Codex の検証とは別に、orchestrator が release / ASan の `kaito` を組み直して実施した。

**CC0 と go 標本。** `compare.py` は match 110 / mismatch 0 / kaito_error 106（`.sitx` 48、`.exe` 21、
パスワード付き 37。いずれも本 slice の範囲外）で Codex と同じ。go 標本は method 0/2/3/13 の 9 本が
オラクルと一致。`SITv1-2.sit`（MacBinary version I ヒューリスティックで包まれた classic）と
`doom-i-101.hqx`（3.4 MB の BinHex → classic、19 entry、`DOOM1.WAD` 4,196,020 バイト）は XADMaster が
内側へ降りないため wrapped のオラクルとは一致しないが、**内側の書庫を取り出して XADMaster に
渡した結果と (size, sha256) が全 entry で一致**した。

**実書庫（性能コーパス、`inbox/stuffit-corpus/perf/`、archive.org から取得）。** 12 本すべてで
data fork の (size, sha256) が XADMaster と一致した:

| 書庫 | 容器 / 主 method | 展開バイト | kaito sha 実時間 |
|---|---|---:|---:|
| 911AJOKEMIM.mov.sit | SIT5 / 15 | 17,431,167 | 0.83 秒 |
| theplanets.sit | SIT5 / 15 | 10,783,321 | 0.30 秒 |
| IconfactoryIcons_2.sit | SIT5 / 15 + 0 | 15,229,266 | 0.19 秒 |
| Ikthusian-Classic-Coll.sit | SIT5 / 15 + 0 | 4,990,443 | 0.21 秒 |
| i_like_icon.sit | classic / 13 | 1,638,400 | 0.04 秒 |
| ほか 7 本（CoralReef / IconCollection / IconizerPro / iconographerXF / icontrol / Kineticon / Galax） | SIT5 / 15 | — | ≤ 0.08 秒 |

**判断 5（`v1-huffman.sit` の resource CRC）の裏取り。** 当該 fork の格納バイト 55,416 を切り出し、
研究ハーネスの native probe（外部 XADMaster を link した黒箱）に method 3 で復号させたところ、
出力 58,768 バイトの SHA-256 は `f6019cd2…0656d`、CRC-16/ARC は `d303` で **KaitoKit と同一**。
格納 CRC `4579` は XADMaster の復号結果とも一致しない。復号は参照実装と同じであり、
厳格に `checksumMismatch` を返す方針を維持する。

**表の転記。** `StuffItTables.swift` の method 13 固定表（first / second / distance × 5、
MetaCodes / MetaCodeLengths）と Arsenic randomization 256 段が `method13.json` /
`arsenic-randomization.json` と完全一致することをスクリプトで照合した。

**敵対的入力（ASan）。** `swift build --scratch-path .build-asan -Xswiftc -sanitize=address` の
`kaito sha --forks` に、CC0 と go 標本から選んだ 60 書庫（classic / SIT5 / `.bin` / `.as` / `.hqx`）の
切り詰め 7 段・header bit 反転 16・全体 bit 反転 24・classic method nibble 総当り 32・
長さ field 16・SIT5 header field 総当り・payload 乱数化 3 を流した。
**3,520 実行で sanitizer 報告・crash・タイムアウトは 0。**

**テスト。** `swift test` 956 件（933 + 23）、38 skip、失敗 0、`warning:` 0。

**性能の早期シグナル（`kaito bench` vs `xadbench extract`、各 3 回の中央値）。**
911AJOKEMIM.mov.sit（Arsenic 17 MB）は kaito 814 ms / XADMaster 815 ms で同等。
i_like_icon.sit（classic method 13、1.6 MB）は kaito 27.2 ms / XADMaster 14.5 ms で約 1.9 倍遅く、
slice 5 の対象。`kaito bench` は resource fork も展開するため、resource fork の多い書庫では
XADMaster（data fork のみ）との単純比較はできない。

**検出器。** wrapper の内側が StuffIt でない場合は `unsupportedFormat` を投げる。MacBinary で包んだ
ZIP を作って main と比べたところ、main も同じく `unsupportedFormat` であり退行ではない。
