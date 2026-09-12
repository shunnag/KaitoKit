# StuffIt X slice 3 検証記録（2026-09-13、bd cooViewer-gu28.3）

**依頼仕様の Cyanide 是正を適用し、perf 5 本の Cyanide 88 fork を復元、stream 終端の CRC が一致した。**
支給 SHA-256 がある Cyanide 70 fork はすべて一致した。残る 18 fork は展開後の SHA が未収録のため、
CRC 一致と SHA 一致を区別する。Brimstone catalog による通常 open/list の未対応は slice 4 の範囲として維持する。

## 入力と遵守

- 作業は指定 worktree の編集のみ。git checkout / restore / stash / reset / commit / push は実行していない。
- `inbox/stuffit/SHA256SUMS` に対して、Ch.03、Ch.07、Ch.37、Ch.11、stuffitx-vectors.json、archive-verification.json の 6 入力を照合し、すべて一致した。
- 実装入力は指定されたレポートの範囲と JSON、CC0/perf 書庫、支給オラクル、既存 KaitoKit のみ。
  レポート内のリンク先や他の章は開いていない。Web・外部 StuffIt 実装ソースの閲覧・検索は行っていない。
- DeflateDecompressor と既存 Huffman helper は呼んでいない。canonical 表構築を含めて Ch.07 §5 + Ch.37 から独立に実装した。
- ByteSource、CRC32、slice 2 の StuffItRC4、EncodingDetector、EntryStream を共有した。
  SevenZipFolderCoordinator の decoder 保持・前方読み捨て・後方再起動・世代番号・終端照合の形に合わせた。

## 実装

- `Formats/StuffItX/StuffItXBitReader.swift`: LSB packed field、64 bit P2、packed BE octet、整列、実消費位置を保持する入力 buffer。
- `StuffItXElementParser.swift`: 順序・重複を残す algorithm records、key 4 の追加値、Root/version、Clue、End、未知 type の二列 framing。
  `StuffItXFramedInput` は範囲索引だけを保持し、圧縮データを全体コピーしない。
- `StuffItXCatalog.swift`: key 1〜12、packed 日時/POSIX/Finder/link、key 10 の count 後整列、独立 comment record。
- `StuffItXReader.swift`: 全要素の索引後に親 ID・共有 slot・fork を解決。UTF-8 候補と EncodingPolicy、data/resource entry、solidGroup、圧縮サイズ按分、最後の空 object。
  kind 3 は非公開 metadata とし、auxiliary-only stream の長さは Data attr 5 で決め、対応 codec なら全体を検証する。
- `StuffItXStreamCoordinator.swift`: decoder 継続、前方読み捨て、後方再起動、CRC-32/MD5。
  CRC は最初の checksum block の BE32。MD5 は checksum frame を連結した 16 バイト。
  catalog は解析前、通常 data は stream 全体の終端で検証する。途中の fork だけでは stream 全体の checksum は未確定。
- `Codecs/StuffItX/`: 共通 range decoder、Darkhorse、Cyanide、Deflate、Blend、RC4-stored、dispatch。
  range state と Darkhorse tree は固定長ポインタ。Cyanide の N×6 は辞書予算で制限。
  Deflate は 10〜25、6 bit の distance 個数、50 distance symbols、実履歴・window 上限・完全終端を検査する。
- ArchiveFormat / FormatDetector / ArchiveReader / CLI / Compat を接続。
  既存 wrapper の出口判定を `StuffIt!` に広げた。`StuffIt?` は unsupportedFormat。
  CLI は fork と solid group を表示し、sha の entry 失敗を stderr に分離する。

## 容器の対応範囲と Cyanide の是正

### Brimstone catalog

CC0 48 本のうち Root recovery の 10 本を除く 38 本と、perf 5 本のすべてが、
Catalog 要素に algorithm `(1,0)` を持つ。これは未圧縮ではなく Brimstone。
Windows 2009 の DES password 標本は catalog 自体に暗号も持つ。

具体例 `testfile.stuffit7_dlx.mac9.sitx`:

```text
Catalog element offset = 38
attributes = {1:1, 5:472}
algorithms = [(1,0)]
compressed payload = offset 46, length 213
```

従って key 10 を解釈する前に compression 0 が必要になる。comment 版の追加 catalog も 0。
指定どおり 0 を未対応にすると open/list は unsupportedMethod になる。
支給 JSON の名前や fork 期待値を runtime に埋め込んだり、偽の名前で成功扱いにしたりはしていない。

### Cyanide tail-model byte の是正

同 Mac 標本の stream 9 の先頭は次の通り。

```text
payload offset = 373
16 77 00 00 00 dc 00 00 00 d7 ff ...
opaque=16, marker=77, N=220, primary=215, n=255
```

初回は依頼仕様の「n≤253、254/255 は malformed」に従って拒否したが、依頼側から同条件を訂正する指示を受けた。
是正後は n=0〜255 をすべて受理する。群分割は Ch.07 のままで、n=255 の群は
`2,4,8,16,32,64,129`、n=254 では最後の群が 128 となる。
M1FFN の list は 256 entry のまま。実際に復号した `rank = 2^h + l + 1` が 256 以上のときだけ
`malformed("StuffIt X Cyanide rank")` とする。byte への切り詰めも alphabet の拡張も行わない。
本体の変更は n の拒否を取り除く一箇所で、既存の群分割と rank 検査は変更していない。

是正前の拒否 172 fork（CC0 84 + perf 88）は全て復元・stream CRC 検証を通った。
SMSSender の stream 105 は先頭 block が n=248、後続に n=254/255 を含むため、先頭だけでなく終端まで再検証した。

## テストと fixture

CC0 fixture 10 本を既存慣行の `.b64` で固定した。元ファイルの最大サイズは 12,208 バイト。
`slice3-manifest.json` に名前・サイズ・SHA-256、`slice3-verified-forks.json` に支給 5 書庫の fork/stream 期待値を保持する。
recovery は小さい BinHex transport を収録し、unwrap 後 263,691 バイトであることと区別する。

`slice3-vectors.json` の routing 101〜105 の 10 vector を XCTest に固定した。
Darkhorse の外側 window 20 と Deflate の外側 window 15 はハーネス入力へ補う。

| vector | 結果 |
| --- | --- |
| Darkhorse 3 本 | 全出力一致 |
| Cyanide 2 本 | 全出力一致 |
| Deflate 3 本 | 全出力一致 |
| RC4-stored 1 本 | 全出力一致 |
| Blend 1 本 | submethod 0 の 3 + 1 の 15 + 2 の 13 = 31 バイト一致。次の submethod 3 で unsupportedMethod |

chunk 1/7/4096、および一バイト単位の frame・短い ByteSource read で状態継続を検証した。
P2 の公開表 11 例と最大幅、順序付き重複 algorithm、EOF、二列 framing、catalog typed fields、
comment/CRC/MD5、共有 slot、逆順アクセス、世代番号、空 entry、auxiliary 長、未対応 payload の
entry 単位失敗、辞書・metadata・総量上限も人工書庫で検証した。

是正の回帰テストは、全 256 通りの n を持つ一文字 stream、n=254/255 の rank 255 の受理、
n=254 の rank 256 と n=255 の rank 256/257 の指定エラーによる拒否を固定した。
境界標本は Ch.07 の初期等頻度区間の中点から独立に作成した。N×6 の辞書上限検査も維持する。
CC0 固定 fixture では、Mac 7 の通常版と comment 版の Cyanide 各 5 stream、および Windows の
auxiliary 1 stream、合計 11 stream の SHA-256 が支給 JSON と一致した。

## 実行コマンドと環境

通常の `swift build` はユーザーキャッシュへの書き込み制限で失敗した。
`~/.cache/clang/ModuleCache` に対する Operation not permitted とユーザーキャッシュ無効化の警告が出た。
Release の標準設定も dSYM 生成で Operation not permitted になった。
以後、作業ツリー内の cache と Release のデバッグ情報なし設定を使用した。ソースを変えて回避してはいない。

```sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang"
swift build --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
swift test --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
swift build -c release --product kaito -debug-info-format none --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
STUFFITX_CORPUS="$PWD/inbox/stuffit-corpus" STUFFITX_VERIFY_STREAMS=1 STUFFITX_LARGE_WINDOWS=1 swift test -c release -debug-info-format none --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox --filter StuffItX
```

是正後の全体 XCTest は KaitoKit 982 tests（40 skip）+ Compat 23 tests、合計 **1005 tests、失敗 0**。
追加の 2 skip は外部 corpus と 32 MiB 距離検証を通常実行では明示起動にしているため。
残り 38 skip は既存テスト。設定後のコンパイラ警告は 0。
外部 `zip` が非対応 bzip2 を診断する行は既存テストの環境診断で、コンパイラ警告・テスト失敗ではない。

Release の追加検証結果は後掲の最終実行欄に記す。

## compare.py と指定 CLI

```sh
python3 inbox/stuffit-corpus/compare.py .build/out/Products/Release/kaito --only sitx
```

```text
match: 0
name_diff: 0
no_oracle: 0
kaito_error: 48
mismatch: 0
```

exit 0 は compare.py が mismatch のみを失敗条件にしているため。48 本は open error であり、成功した比較はない。
archive の主分類は未対応 method 22、暗号 16、recovery 10。
実際に open を停止させた最初の理由は catalog compression 0 が 37、catalog encryption 2 が 1、Root recovery が 10。
圧縮 0 を catalog まで含めて除外すれば対象集合は空になるため、mismatch 0 を acceptance 達成とは扱わない。

次の指定コマンドはすべて exit 1、同じ診断を返した。

```sh
.build/out/Products/Release/kaito list inbox/stuffit-corpus/cc0/testfile.stuffit7_dlx.mac9.sitx
.build/out/Products/Release/kaito sha inbox/stuffit-corpus/cc0/testfile.stuffit7_dlx.mac9.comment.sitx
.build/out/Products/Release/kaito list inbox/stuffit-corpus/perf/SMSSenderPro3osx.sitx
```

```text
error: Unsupported archive method: StuffIt X compression 0
```

## catalog を介さない実データ層の検証

`StuffItXCorpusTests.testExternalInventory` は明示された corpus を既存 wrapper で剥がし、
要素と fork の索引を作り、各 stream を coordinator で直接読む。通常 ArchiveReader の成功とは区別する。
Root recovery を含む 10 本は索引の時点で未対応。
出力は `.build/slice3-inventory.json`。予期しない error は XCTest の失敗にする。

CC0 の索引可能な 38 本、257 fork 参照の内訳:

| 分類 | 件数 |
| --- | ---: |
| 復元・stream CRC 一致、支給 JSON の (size, SHA-256) 集合と一致 | 88（data 54、resource 32、非公開 auxiliary 2） |
| Brimstone 0 未対応 | 64 |
| Iron 6 未対応 | 6 |
| JPEG 7 未対応 | 2 |
| 暗号未対応 | 97 |

Windows 2009/2010 の backcompat text は 12 bytes、SHA-256
`b2f51cd17b3cbe77f091f887d91110164a2cb5a5a9ebe828c44d655c83dca8eb`。
2009/2010 default の auxiliary は 661 bytes、CRC32 `2ee09fcc`、SHA-256
`02fedbd0a0a7379500fe15bd70a95aea90f79537e0dfe4031ce4e25ffbc8e4d0`。
支給 archive-verification の stream 期待値と一致する。Mac の Cyanide fork も是正後は一致した。
名前と catalog record の対応は、このデータ層の照合には含めない。

## perf 5 本

全 5 本で catalog は compression 0。下表の結果は通常 open を迂回したデータ層だけの結果。
compression 列の括弧は Data stream の本数。fork 数は kind 0/1 の参照数で、空 object を含めない。

| 書庫 | Data compression | fork 数 | Cyanide 復元・CRC 一致 | SHA 一致（Darkhorse を含む） | 展開後 SHA 未収録 | Brimstone + English 未対応 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| SMSSenderPro3osx.sitx | 0 (4), 1 (11), 2 (1) | 63（data 62/resource 1） | 53 | 53 | 1 | 9 |
| BirdFluWAVE.sitx | 1 (7) | 31（data 17/resource 14） | 31 | 17 | 14 | 0 |
| warriors_screen.sitx | 1 (2) | 2（data 1/resource 1） | 2 | 1 | 1 | 0 |
| theconceptosx.sitx | 1 (1) | 1 | 1 | 0 | 1 | 0 |
| Tickershock.sitx | 1 (1) | 1 | 1 | 0 | 1 | 0 |

後二者は既存 MacBinary wrapper で剥がした。SMSSender は 95 object を索引できる。
stream 106、owner 31、slot 0、2,239,186 bytes の Darkhorse 出力は CRC と SHA-256 が一致した。
オラクル上の該当名は `SMS Sender Pro/SMS Sender Help/SMS Sender Pro Manual.pdf`、SHA-256 は
`977458b201c9294a4aff4d7a0fb6f485eeb8332a532516333f62ad6c15ceabab`。
これは catalog からファイル名まで復元したとの主張ではない。
Cyanide は 22 stream / 88 fork、Darkhorse は 1 stream / 1 fork が成功し、23 stream 全ての CRC が一致した。
是正前の Cyanide 拒否 31 + 53 + 2 + 1 + 1 は 0 になった。SHA 一致は Cyanide 70 + Darkhorse 1 = 71、
対応するオラクルとの mismatch は 0。SMSSender の未対応 9 fork は同じ索引内で個別に失敗し、他の 54 fork は成功した。

支給 `oracle/perf/*.sha` の resource fork 16 件は未収録。また後二者の SHA は MacBinary の data fork、
すなわち圧縮された内側 `.sitx` の SHA であり、Cyanide の展開結果の SHA ではない。
照合スクリプトは包みから取り出した内側 bytes との一致を別途検査し、展開後の一致数には加えない。

| 包み | 支給 oracle の長さ | 実際の展開長 | 今回計算した展開後 SHA-256（支給期待値なし） |
| --- | ---: | ---: | --- |
| theconceptosx.sitx | 1,803,385 | 1,834,476 | `8aab8f7d62872ec85ed0e5f82fe3960e2a2791c5d315015c1d51f7a1811a2a7d` |
| Tickershock.sitx | 937,644 | 960,034 | `9e5c9bec7057ddc3c4bc6a7113af742316ecd1ade55946f9ac7113b86e5c63d6` |

従って 88 件すべてを「展開後の SHA オラクル一致」とは記録できない。未収録 18 件は復元・stream CRC 一致まで確認した。

## 残る範囲と判断

- compression 0/6/7、前処理、暗号、recovery、segment、Receipt、Root algorithms は未対応。
  type 11〜15 と未知 type は指定の二列 framing のみを読み飛ばし、segment 復元や index 身元検証とは扱わない。
- 順序付き algorithm list は全て保持するが、反復 compression・複数 digest scope は unsupportedMethod。
  本 slice で検証する checksum scope は単一の最終出力。Ch.14 は入力として許可されていない。
- 混在した通常/未知 kind の stream は entry 読み取り時に unsupportedMethod。
  auxiliary-only kind 3 の実長だけを採用し、未知 payload を通常 fork として公開しない。
- Darkhorse と Blend は指定出力長で停止する profile。range coder の物理終端を消費したとは主張しない。
  Cyanide の単独 stream は FF を、Deflate は最終 block と余剰完全 byte の不存在を検査する。
- key 10/comment catalog は人工の未圧縮 catalog で検証した。実 Mac catalog は Brimstone が必要なため未検証。
- acceptance 1（環境用 flags 付き build/test・警告 0）と 4（固定 vector）は達成。
  是正後は対応する実 Data の復元・CRC と、期待値のある SHA 照合も成功した。
  acceptance 2/3/5 の通常 open/list は Brimstone catalog が必要なため後続 slice で扱う。
  対応 catalog を持つ人工書庫の list/fork/solid と entry 単位失敗は検証した。
- Cyanide の仕様上の不整合は解消した。未収録の展開後 SHA 18 件は追加の独立期待値が必要。
  支給期待値の差し替え、fixture 依存の runtime shortcut、指定外資料の参照は行っていない。

## 最終実行

是正後の追加 Release 検証は **28 tests、skip 0、失敗 0、コンパイラ警告 0**。
Deflate の全 16 指数と、50 distance symbol の両端 100 token を実際に復元した。
32 MiB の履歴から 33,554,732 bytes を生成し、独立に用意した同長の期待値の SHA-256 と一致した。
外部 corpus の decoder 結果で、想定外の error はなかった。是正後の外部検査では Cyanide の malformed を
許容する特例も取り除き、全てテスト失敗にする。28 tests の実行時間は 3.100 秒。

通常 Reader と CLI の機能確認用に、外部テストが `.build/slice3-container.sitx` を生成する。
これは明示的に人工の未圧縮 catalog/data 書庫であり、実書庫の代替成功とは数えていない。

```sh
.build/out/Products/Release/kaito list .build/slice3-container.sitx
.build/out/Products/Release/kaito sha .build/slice3-container.sitx --forks
```

list（exit 0）:

```text
0  3  file       StuffIt X Stored  plain  folder/日本語                    fork=data      solid=10
1  3  file       StuffIt X Stored  plain  folder/alias                     fork=data      solid=10
2  2  file       StuffIt X Stored  plain  folder/日本語/..namedfork/rsrc   fork=resource  solid=10
3  0  directory  Directory         plain  folder                                          solid=-1
4  0  file       StuffIt X Stored  plain  empty                            fork=data      solid=-1
```

sha --forks（exit 0）は 5 行、total SHA-256
`8d5e82418c2b402147c8160dc92a8d5d6fe36be9a75444ac52eab9a06881bc08`。

初回の Debug build と Release kaito build は成功、警告 0。初回の差分確認も出力なし。
本是正では git 操作を行っていない。是正後のコマンドと結果は次節に記す。


今回の実行ログは `.build/slice3-all-tests.log`、`slice3-stream-test.log`、
`slice3-build.log`、`slice3-release.log`、`slice3-compare.log`、`slice3-*-list.log`、`slice3-*-sha.log` に保存した。

## Cyanide 是正後の再実行

Debug build と Release CLI build は exit 0、全体 XCTest は 1005 tests、40 skip、失敗 0。
コンパイラ警告は全実行で 0。

```sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang"
swift build --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
swift test --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
swift build -c release --product kaito -debug-info-format none --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
```

```text
Build complete! (1.35秒)
Executed 982 tests, with 40 tests skipped and 0 failures (0 unexpected) in 274.458 (274.515) seconds
Executed 23 tests, with 0 failures (0 unexpected) in 0.824 (0.826) seconds
Build complete! (33.60秒)
```

通常の対象テストは 28 tests、外部 corpus と 32 MiB 距離検証の 2 skip、失敗 0。
明示的に外部 corpus と距離検証を有効にした Release テストは 28 tests、skip 0、失敗 0。
Mac の固定 10 Cyanide stream の SHA 照合、全 n の受理と rank 境界も含む。

```sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang"
swift test --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox --filter StuffItX
STUFFITX_CORPUS="$PWD/inbox/stuffit-corpus" STUFFITX_VERIFY_STREAMS=1 STUFFITX_LARGE_WINDOWS=1 swift test -c release -debug-info-format none --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox --filter StuffItX
python3 Tests/Fixtures/stuffit/verify_slice3_inventory.py
```

外部検証と SHA 照合の出力（いずれも exit 0）:

```text
Executed 28 tests, with 0 failures (0 unexpected) in 3.100 (3.101) seconds
BirdFluWAVE.sitx: cyanide=31 decoded_crc=31 sha_match=17 sha_missing=14 unsupported=0
SMSSenderPro3osx.sitx: cyanide=53 decoded_crc=54 sha_match=53 sha_missing=1 unsupported=9
warriors_screen.sitx: cyanide=2 decoded_crc=2 sha_match=1 sha_missing=1 unsupported=0
theconceptosx.sitx: cyanide=1 decoded_crc=1 sha_match=0 sha_missing=1 unsupported=0
Tickershock.sitx: cyanide=1 decoded_crc=1 sha_match=0 sha_missing=1 unsupported=0
total: cyanide=88 decoded_crc=89 sha_match=71 sha_missing=18 unsupported=9 wrapper_sha_match=2 mismatch=0
CRC は直前に成功した外部 XCTest の stream 終端照合。SHA 不在 18 fork は SHA 一致に数えない。
```

`cyanide` は今回是正した fork 数、`decoded_crc` と `sha_match` は既存 Darkhorse 1 fork を含む。
`wrapper_sha_match=2` は圧縮書庫自体と支給 SHA の照合であり、展開後の一致数には加えていない。
スクリプトは対象 5 書庫の件数、対応 stream の全長、未対応 9 fork の理由も検査する。

通常の CLI 比較も再実行した。catalog は対象外のままなので、初回と同じ集計である。

```sh
python3 inbox/stuffit-corpus/compare.py .build/out/Products/Release/kaito --only sitx
.build/out/Products/Release/kaito list inbox/stuffit-corpus/cc0/testfile.stuffit7_dlx.mac9.sitx
.build/out/Products/Release/kaito sha inbox/stuffit-corpus/cc0/testfile.stuffit7_dlx.mac9.comment.sitx
.build/out/Products/Release/kaito list inbox/stuffit-corpus/perf/SMSSenderPro3osx.sitx
```

compare.py は exit 0（成功した書庫比較は 0）:

```text
match: 0
name_diff: 0
no_oracle: 0
kaito_error: 48
mismatch: 0
```

残りの CLI 3 コマンドは各 exit 1:

```text
error: Unsupported archive method: StuffIt X compression 0
```

ログは `.build/slice3-cyanide-build.log`、`slice3-cyanide-all-tests.log`、`slice3-cyanide-release.log`、
`slice3-cyanide-tests.log`、`slice3-cyanide-stream-test.log`、`slice3-cyanide-oracle-check.log`、
`slice3-cyanide-compare.log`、`slice3-cyanide-mac-list.log`、`slice3-cyanide-mac-comment-sha.log`、
`slice3-cyanide-sms-list.log`。是正前の inventory は
`.build/slice3-inventory-before-cyanide-correction.json`、是正後は `.build/slice3-inventory.json`。

この是正で変更したファイルは `StuffItXCyanide.swift`、`StuffItXCodecTests.swift`、
`StuffItXFixtureTests.swift`、`StuffItXCorpusTests.swift`、本記録、design.md §11、README、CHANGELOG、
fixture NOTICE。外部 SHA 照合用に `Tests/Fixtures/stuffit/verify_slice3_inventory.py` を追加した。

## 変更ファイル

新規本体は `Sources/KaitoKit/Formats/StuffItX/` の BitReader / ElementParser（FramedInput を含む）/
Catalog / Reader / StreamCoordinator、および `Sources/KaitoKit/Codecs/StuffItX/` の Codec /
RangeDecoder / Darkhorse / Cyanide / Deflate / Blend / RC4Stored。

接続変更は `Model/ArchiveFormat.swift`、`Formats/FormatDetector.swift`、`Reader/ArchiveReader.swift`、
`Sources/kaito/main.swift`、`Sources/KaitoKitCompat/KaitoArchive.swift`。
wrapper 自体の byte 復元処理は流用し、内側形式の許可は FormatDetector 側で変更した。

テストは `StuffItXContainerTests.swift`、`StuffItXCodecTests.swift`、`StuffItXReaderTests.swift`、
`StuffItXDeflateTests.swift`、`StuffItXFixtureTests.swift`、`StuffItXCorpusTests.swift`。
追加 fixture 名は `Tests/Fixtures/stuffit/slice3-manifest.json`、研究 vector/期待値は
`slice3-vectors.json` と `slice3-verified-forks.json`。NOTICE も更新した。

文書変更は本記録、README、CHANGELOG、design.md §10/§11。
最終 status には `Documentation/stuffit-plan.md` の別差分も現れたが、本作業ではそのファイルを開いたり編集したりしていない。
