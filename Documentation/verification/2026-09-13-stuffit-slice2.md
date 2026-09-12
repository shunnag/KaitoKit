# StuffIt slice 2 検証記録（2026-09-13、bd `cooViewer-gu28.2`）

## 対象と入力

`feat/stuffit` の slice 1 に method 5（LZAH）、6（固定 Huffman + PackBits）、8（MW）、
14（installer）、StuffIt 5 の RC4、classic の改変 DES / feedback、書庫コメントを追加した。
作業は指定 worktree 内の編集だけで、checkout / restore / stash / reset / commit / push は行っていない。
Web、XADMaster / The Unarchiver / stuffit-go / libxad / macutils その他の StuffIt・DES・RC4
実装ソースは開かず、検索もしていない。既存 slice 1 と KaitoKit の契約に合わせた。

実装入力は下記の指定 9 ファイル。すべて `inbox/stuffit/SHA256SUMS` と一致した。
`research/THIRD_PARTY_DATA.md` の数値表の出自も確認した。コーパスと支給オラクルは
`inbox/stuffit-corpus/` のみを用い、他の展開実装は起動していない。

| 入力 | 使用部分 |
|---|---|
| `report/04-classic-codecs.md` | method 5 / 8 / 14 |
| `report/12-classic-method6.md` | method 6 の全体 |
| `report/02-stuffit5.md` | Password verification and RC4 |
| `report/05-classic-encryption.md` | 改変順列、password、MKey、fork 鍵、feedback |
| `report/06-wrappers-and-segments.md` | Finding MKey and SitC |
| `report/tables/classic-key-substitution.json` | 8 × 64 語の形式定数 |
| `research/core-vectors.json` | 独立作成の 6 vector |
| `research/core-verification.json` | 実 fixture の鍵 4 ケース、人工鍵 10 ケース |
| `research/archive-verification.json` | method 6 の 3 fork、暗号化 StuffIt 5 の 9 fork |

置換表の 512 語は JSON の行・添字順と完全一致する。出自・原ファイルの著作権表示と
LGPL 2.1 以降の記載は `Documentation/design.md` §10 に追記した。独立作成した表とは主張しない。

## 実装と判断

- LZAH は指定の 4,096 byte seed、627 slot、bit 1 = 左、等重みを越えない交換、
  leaf 順を保つ ceil(f/2) と再構築を使う。33,024 byte の rescale vector を含む 3 本が
  1 / 7 / 4096 byte の読み出し幅で一致する。
- MW は以前の参照と現在の参照の展開を連結する pair 辞書で、容量は 16,385、
  展開 stack は 16,384、幅は最大 15。定義の上限・参照の降順・出力境界を検証する。
  reset / end は byte alignment を挟まない。期待出力に届く前の end は truncated。
- installer は block ごとに木を更新し、256 KiB のゼロ履歴は fork 全体で保持する。
  tree-length の入れ子上限は 16 段。長さ記述で表現できる最大 38 bit まで共通 prefix tree
  の挿入を拡張した。通常の canonical builder の 32 bit 制限は維持した。
  同長コードは指定の不安定 partition を再現し、`3,2,0,1` と meta-tree vector が一致する。
  各木の末尾と次 block の前に整列する。N を越える match / fork を越える block は malformed。
  Ch.04 に従い、容器の期待出力に達した後の未使用 block は読まない。
- method 6 の翻訳表は fork 開始時に一度ゼロ初期化し、正 block は先頭 n 個だけを書き換える。
  負 block を挟んだ部分表の継承、非単調 code 長の 115〜119 / 254〜256 周辺、PackBits の
  block 内 operand 境界を検証する。符号付き長さは Int64 に拡張して絶対値を求め、Int32.min
  でも trap しない。宣言 I より早い stop / 入力終端は失敗とする。末尾の no-op は許容する。
  期待 fork 長以降の未使用 stored block は Ch.12 に従って消費しない。
- 復号は fork ごとの bounded ByteSource から逐次行う。RC4 は 256 byte の固定順列、
  classic は 8 byte の feedback 状態を保持する。ByteSource の任意位置契約を保つため、
  巻戻し時は初期状態から再生する。cursor と順列へのアクセスは Mutex 内に限定した。
- password の文字コードは **UTF-8 bytes**。MacRoman への変換はしない。classic の bit 7
  クリアと password block 数、StuffIt 5 の first5(MD5) の段階的切り詰めは指定どおり。
  暗号化 flag は復号成功後も維持し、展開後の従来の CRC を検証する（method 15 は内部 CRC）。
- resource map は count と reference offset の両方で宣言された type-list offset を使う。
  28 以外の offset も受理し、MKey / SitC は type と ID 0 で選ぶ。範囲外・重複・MKey の長さを
  検証する。コメントは MacRoman として `archiveComment` と最初の entry の
  `formatSpecific["comment"]` に公開する。StuffIt 5 optional header のコメントを優先する。
- 必須 MKey / archive hash の欠落は password provider を呼ぶ前に unsupportedMethod とする。
  それ以外の暗号化 fork は passwordRequired / wrongPassword を区別する。
  この接続に必要なため、指定変更一覧に加えて `Reader/ArchiveReader.swift` の slice 1 用の
  password 処理スキップも置き換えた。共通 bit reader の byte alignment も追加した。

### 指定資料と実コーパスの差

1. **classic の 8 byte password。** Ch.05 の規則で `password` を 2 block 派生すると
   A=`eb53a5151ff258ce`。CC0 の `testfile.stuffit45_dlx.mac9.password.sit.bin` の
   MKey=`e3fe9f12776699c9` に対する V は `10f77836b4c1d1da`、検証暗号の末尾は
   `ce0cb724` で不一致だった。1 block 派生では A=`49f4e7aadf3ee397`、
   V=`955a10958aac6c80`、検証暗号=`34a6f8e98aac6c80` となり検証が成立した。
   この観測に限り、**指定の派生を優先し、それが失敗した長さ 8 にだけ 1 block 候補を試す**。
   候補も必ず MKey で検証する。CC0 の wrapper 6 本の全 fork が平文 counterpart と一致した。
   core-verification の 4 + 10 ケースは指定の派生のままで一致する。
   これは全暗号化 CC0 一致のために追加した、明示的な互換性拡張である。
2. **classic padding のヘッダ位置。** 許可された入力章に byte offset の明記がないため、
   既存 112 byte header の未使用領域と実コーパスを確認し、104 を resource、105 を data とした。
   例えば Test Text は resource=3 / data=5、testfile.PICT は resource=7 / data=3。
   trailer の除外・padding の除去後に全 fork の SHA / CRC が一致した。
3. **StuffIt 7 の空 fork の鍵。** mac9 password 書庫の最初の Test Image は data の
   U=C=0 でも kd=5 を持つ。非空 encrypted fork の鍵 5 byte は必須のまま、空 fork は
   0 / 5 byte の両方を受理し、filename や payload の座標には実際の鍵長を反映する。
4. **go の受け入れ条件の制約。** 支給 `oracle/go/v1-fhf-faster.sit.sha` は空出力だけで、
   method 6 の正常展開の期待値ではない。この標本は Ch.12 / archive-verification の
   3 fork の SHA と CRC で検証した。`v1-lzm-newde-password123.sit` もオラクルは空出力で、
   実際の fork method byte は `18 / 18 / 13`（hex）、追加 flag 0x10 を持ち、本文を暗号文と判断した。
   Ch.05 の 0x80 暗号と同じと仮定して codec に渡さず、暗号化として列挙する。
   MKey がなければ指定の resource fork 欠落エラー、MKey があっても未記述の 0x10 は
   unsupportedMethod とする。この標本も素の `.sit` で resource fork がない。
   **「des 標本以外の 16 本の展開結果が oracle/go と一致」は、支給入力のままでは成立しない。**
   空出力を成功扱いにして合わせることはしていない。
5. **go wrapper のオラクル階層。** `SITv1-2.sit` と `doom-i-101.hqx` の oracle/go は
   内側の書庫自体を 1 member として返している。wrapper の data 長と SHA がその値に一致し、
   内側は KaitoKit で全 fork の CRC を検証する。展開後の行との直接比較とは分けて記録する。

## 検証コマンド

slice 1 と同じ制限付き環境の設定を使用した。製品設定は変更せず、cache と一時ファイルは
worktree 内に置いた。既存テストの `/tmp` / `/private/tmp` の表記差を避けるため、TMPDIR
には worktree の `/tmp` 表記を使う。SwiftPM の入れ子 sandbox を無効化し、dSYM を省略する。

```sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/stuffit-check/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/stuffit-check/module-cache"
export TMPDIR="${PWD#/private}/.build/stuffit-slice2/tmp"
swift_options=(--disable-sandbox --cache-path .build/stuffit-check/cache
  --config-path .build/stuffit-check/config --security-path .build/stuffit-check/security
  -debug-info-format none)
swift build "${swift_options[@]}"
swift test "${swift_options[@]}"
swift build -c release --product kaito "${swift_options[@]}"
python3 inbox/stuffit-corpus/compare.py .build/out/Products/Release/kaito
.build/out/Products/Release/kaito sha inbox/stuffit-corpus/go/v1-fhf-faster.sit --forks
.build/out/Products/Release/kaito sha inbox/stuffit-corpus/go/v1-lzm-des-password123.sit -p password123
.build/out/Products/Release/kaito sha inbox/stuffit-corpus/cc0/testfile.stuffit45_dlx.mac9.password.sit.bin -p password
.build/out/Products/Release/kaito sha inbox/stuffit-corpus/cc0/testfile.stuffit7_dlx.mac9.password.sit -p password
```

最終集計・コマンド出力・変更ファイルは後段に記す。

## 最終コーパス集計

`compare.py` は exit 0。支給オラクルに対する data fork の集計は次のとおり。

```text
match: 145
name_diff: 0
no_oracle: 0
kaito_error: 71
mismatch: 0
```

71 件の内訳は `.sitx` 48、`.exe` 21、resource fork のない classic 暗号化 2 件。
`.sitx` / `.exe` は wrapper 版も各形式に含めて数える。全 CC0 を `sha --forks -p password`
でも実行し、成功 145 / 失敗 71、成功分の member 出力は合計 1,324 行だった。

| 暗号化書庫の系統 | 復号成功 | 必須 resource fork なし | 備考 |
|---|---:|---:|---|
| classic 4.5 mac9 | 6 | 2 | `.sit` / `.sea` の AS・bin・hqx は全 fork 成功、素の 2 本は不能 |
| StuffIt 6.5.1 mac9（SIT5） | 8 | 0 | `.sit` / `.sea` と各 wrapper |
| StuffIt 6.5.1 macx1（SIT5） | 8 | 0 | `.sit` / `.sea` と各 wrapper |
| StuffIt 7 Windows（SIT5） | 1 | 0 | `.sit` |
| StuffIt 7 mac9（SIT5） | 4 | 0 | `.sit` と各 wrapper |
| StuffIt 7 macx1（SIT5） | 8 | 0 | `.sit` / `.sea` と各 wrapper |
| 合計 | 35 | 2 | 復号成功分の全 fork は各平文 counterpart と一致、差分 0 |

resource fork 不足で失敗する CC0 は以下の 2 本。

- `testfile.stuffit45_dlx.mac9.password.sit`
- `testfile.stuffit45_dlx.mac9.password.sea`

どちらも `unsupportedMethod("StuffIt encryption without archive resource fork")` で、
`passwordRequired` や誤った空出力の成功にはしない。

### go 標本の集計

17 本中、復号不能の素の暗号化 2 本を除く 15 本を検証した。

| 照合先・結果 | 本数 | 標本 |
|---|---:|---|
| oracle/go の展開 data と一致 | 12 | 下記の直接一致群 |
| oracle/go の wrapper data と一致 | 2 | `SITv1-2.sit`、`doom-i-101.hqx`。内側の全 fork の CRC も成功 |
| archive-verification と一致 | 1 | `v1-fhf-faster.sit`。oracle/go は空出力 |
| resource fork 不足で unsupportedMethod | 2 | `v1-lzm-des-password123.sit`、`v1-lzm-newde-password123.sit` |

直接一致群は、`SITv1-13.sit`、`v1-huffman-optimal.sit`、`v1-huffman.sit`、
`v1-lzw+h-better.sit`、`v1-lzw+huffman.sit`、`v1-lzw-fast.sit`、`v1-lzw.sit`、
`v1-nocompression.sit`、`v1-optimal-with-comment.sit`、`v1.5-lzw-comment.sit`、
`v5-comment.sit`、`v5-selfextractor.sea`。

全 fork 読みでは `v1-huffman.sit` の resource が既知の `checksumMismatch` になる。
格納 CRC `4579` と実出力 CRC `d303` の差は slice 1 と同じで、data の照合は成功する。
`v1-fhf-faster.sit` の正しい 3 fork は、CRC `73f9` / `7cee` / `4579` と
以下の SHA-256 がすべて一致する。resource fork を持たない go 暗号化 2 本は、
password の値によらず鍵の取得前に失敗する。指定コマンドでは `password123` を与えて確認した。

## 指定 CLI の出力

最終 release の SHA-256 は `67db3f0f2ce8d09ef90e519e8b0320e5a2f90701d95f4791eab516cb20bab939`。

`kaito sha .../go/v1-fhf-faster.sit --forks`:

```text
0	2336	828a2d431f43b6d0d01ea3307972a75e24a8e27683a505c69d6c9448b6b384e7	About System 7.5/..namedfork/rsrc
1	19696	d78c0b5547fc230e734ce2fc05ae7fada9f075e601a819a9d4d0f2b33b883bef	About System 7.5
2	58768	e723b7dba9c45f352e366898dc3b9d377f6b7531a7a365c6e51b40368af79ced	SimpleText/..namedfork/rsrc
total	3	f9f340907df73b63de9dfc820013ba38794e6f27690f2a35b473a7d854e771e3	

exit: 0
```

`kaito sha .../go/v1-lzm-des-password123.sit -p password123`:

```text
0	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	SimpleText
partial	1	cd372fb85148700fa88095e3492d3f9f5beb43e555e5ff26d95f5a6adc36f8e6	
error: failed entry 1 (About System 7.5): Unsupported archive method: StuffIt encryption without archive resource fork
error: 1 archive entries failed
exit: 1
```

`kaito sha .../cc0/testfile.stuffit45_dlx.mac9.password.sit.bin -p password` と
`kaito sha .../cc0/testfile.stuffit7_dlx.mac9.password.sit -p password` は、
両方とも exit 0 で次の同一出力になった。

```text
0	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	Test Image
1	11	9734aef6d3788ba985e78f7b3785dc4817e770be92a4e5e57e64a92cc9c2fc25	Test Text
2	220	e514232511df1a4f4221a75c27523518c3c62a2fe6470fa56e430364428eecd1	testfile.jpg
3	2694	318d71cd4d027c6bec6917af3ddc3b7df0ec8b07031045a9cdd9052b94c7782e	testfile.PICT
4	87	fdda20984cc1591419ec4583e24e72e4dba39d0b96608253f853a2dfb238ad1a	testfile.png
5	12	b645efee0ed710034959eae942277a750d08687c30bcf0e9ec6ea7641527462f	testfile.txt
total	6	873d01475ab1f240d4fe5700b5f24d5bc3ab1469d2ab8c981bd75e6c3e7defaf	

exit: 0
```

追加の `kaito sha .../cc0/testfile.stuffit651_dlx.mac9.password.sit -p password --forks`
は、archive-verification.json の 9 fork の SHA と一致した。

```text
0	9134	4b8175653903645616d9e07627957ae0dba4c7ac3b3e9aa6afc8e07144dcfbb0	Test Image/..namedfork/rsrc
1	332	5f0c7e77ac2430be40532730665ea27f0cf1088ac049e0c06851d62085b87315	Test Text/..namedfork/rsrc
2	11	9734aef6d3788ba985e78f7b3785dc4817e770be92a4e5e57e64a92cc9c2fc25	Test Text
3	220	e514232511df1a4f4221a75c27523518c3c62a2fe6470fa56e430364428eecd1	testfile.jpg
4	44549	011604ad448ef4451081d04bd395c2a974cab637877fb64b45e62ebe39bc452e	testfile.PICT/..namedfork/rsrc
5	2694	318d71cd4d027c6bec6917af3ddc3b7df0ec8b07031045a9cdd9052b94c7782e	testfile.PICT
6	87	fdda20984cc1591419ec4583e24e72e4dba39d0b96608253f853a2dfb238ad1a	testfile.png
7	332	f788dcd5313a531a27fc62a9b4c951a6653ef11b49f2262ee0796f72c5564b0a	testfile.txt/..namedfork/rsrc
8	12	b645efee0ed710034959eae942277a750d08687c30bcf0e9ec6ea7641527462f	testfile.txt
total	9	f50992ced64b04eb872ef9adf1f80fed80f0632c0c8c887dba27ed3e404d1c19	

exit: 0
```

## 変更ファイル

- `CHANGELOG.md`
- `Documentation/design.md`
- `Documentation/verification/2026-09-13-stuffit-slice2.md`
- `README.md`
- `Sources/KaitoKit/Codecs/StuffIt/StuffItCodec.swift`
- `Sources/KaitoKit/Codecs/StuffIt/StuffItHuffman.swift`
- `Sources/KaitoKit/Codecs/StuffIt/StuffItInstaller.swift`
- `Sources/KaitoKit/Codecs/StuffIt/StuffItLZAH.swift`
- `Sources/KaitoKit/Codecs/StuffIt/StuffItMW.swift`
- `Sources/KaitoKit/Codecs/StuffIt/StuffItMethod6.swift`
- `Sources/KaitoKit/Codecs/StuffIt/StuffItPackedInput.swift`
- `Sources/KaitoKit/Formats/StuffIt/StuffIt5Parser.swift`
- `Sources/KaitoKit/Formats/StuffIt/StuffItCrypto.swift`
- `Sources/KaitoKit/Formats/StuffIt/StuffItParser.swift`
- `Sources/KaitoKit/Formats/StuffIt/StuffItReader.swift`
- `Sources/KaitoKit/Formats/StuffIt/StuffItResourceMap.swift`
- `Sources/KaitoKit/Reader/ArchiveReader.swift`
- `Tests/Fixtures/NOTICE`
- `Tests/Fixtures/stuffit/manifest.json`
- `Tests/Fixtures/stuffit/slice2-key-vectors.json`
- `Tests/Fixtures/stuffit/slice2-vectors.json`
- `Tests/Fixtures/stuffit/testfile.stuffit45_dlx.mac9.comment.sit.bin.b64`
- `Tests/Fixtures/stuffit/testfile.stuffit45_dlx.mac9.password.sit.bin.b64`
- `Tests/Fixtures/stuffit/testfile.stuffit7_dlx.mac9.password.sit.b64`
- `Tests/Fixtures/stuffit/verified-forks.json`
- `Tests/KaitoKitTests/StuffItContainerTests.swift`
- `Tests/KaitoKitTests/StuffItCorpusTests.swift`
- `Tests/KaitoKitTests/StuffItHardeningTests.swift`
- `Tests/KaitoKitTests/StuffItSlice2CodecTests.swift`
- `Tests/KaitoKitTests/StuffItSlice2CryptoTests.swift`
- `Tests/KaitoKitTests/StuffItWrapperTests.swift`

## ログと検証範囲

ログは `.build/stuffit-slice2/` に保持する。`build-final.log`、`release-final.log`、
`test-stuffit-final.log`、`test-full-final.log`、`compare-final.log`、`corpus-report.json`、
`corpus-summary.log`、指定 CLI ごとの `method6.log` / `classic-bare.log` /
`classic-encrypted.log` / `sit7-encrypted.log` / `sit651-encrypted-forks.log` が最終出力。
`audit.py` は提供コーパスの全 fork 読みとオラクル照合、`verify-final.sh` は最終実行順序を保持する。
入力の SHA 一覧は `input-hashes.json`。これらは生成ログであり配布 fixture には含めない。

検証は有限の vector・構成例・コーパスに対するもの。今回の性能比較や ASan の追加実行は行っていない。
初回全テスト中の既存 `ZipHardeningTests.testZipCryptoRequiresPasswordRejectsWrongPasswordAndUsesProvider`
は、wrong-password の期待に対して checksumMismatch を返す失敗が一度あった。
外部 Info-ZIP で毎回生成する標本の一バイト検査値に依存するテストで、対象コードは変更していない。
最終全テストを別途再実行し、その結果を下表に記録する。

## 最終テスト結果

| コマンド | 結果 |
|---|---|
| `swift build`（上記環境引数） | exit 0、`Build complete! (0.24秒)`、警告 0 |
| `swift build -c release --product kaito`（同上） | exit 0、`Build complete! (32.08秒)`、警告 0 |
| `swift test --filter StuffIt`（同上） | exit 0、51 tests、skip 0、失敗 0、警告 0 |
| `swift test`（同上） | exit 0、954 + 23 = 977 tests、38 skip、失敗 0、警告 0 |
| `compare.py` | exit 0、match 145 / name_diff 0 / no_oracle 0 / kaito_error 71 / mismatch 0 |
| 指定 `sha` 4 コマンド | method 6 と暗号化 wrapper / SIT5 は exit 0、裸の classic DES は期待どおり exit 1 |
| `git diff --check` | exit 0、出力なし |

```text
Executed 51 tests, with 0 failures (0 unexpected) in 5.606 (5.609) seconds
Executed 954 tests, with 38 tests skipped and 0 failures (0 unexpected) in 289.326 (289.392) seconds
Executed 23 tests, with 0 failures (0 unexpected) in 0.783 (0.786) seconds
```

38 skip は既存の外部標本・ツール等の条件によるもので、StuffIt 51 tests はすべて実行した。
初回に揺れた既存 ZipCrypto テストも最終全テストでは成功した。
6 codec vector は元 JSON の入力・期待値と完全一致、method 6 と SIT5 暗号化の計 12 fork は
元 archive-verification.json と SHA が一致することを、XCTest と最終 CLI 出力の両方で確認した。

## orchestrator による独立検証

Codex の検証とは別に、orchestrator が release / ASan の `kaito` を組み直して実施した。

**コーパス。** `compare.py`(パスワード付きは平文版のオラクルを期待値に使う版)は
match 145 / mismatch 0 / kaito_error 71(`.sitx` 48、`.exe` 21、resource fork を持たない素の classic
暗号化書庫 2)。go 標本は method 5 / 8 / 13 / 2 / 3 / 0 の 12 本が data fork でオラクルと一致。
`v1-fhf-faster.sit`(method 6)は XADMaster が復号できないため oracle は空で、代わりに
`archive-verification.json` の 3 fork(resource 2,336 / data 19,696 / resource 58,768 バイト)の SHA-256
`828a2d43…` / `d78c0b55…` / `e723b7db…` と **完全一致**した。`SITv1-2.sit` は slice 1 と同じく内側の
オラクルと一致。`v1-lzm-des-password123.sit` / `v1-lzm-newde-password123.sit` は素の `.sit` で `MKey` が無く
復号不能(XADMaster も空 data)。

**8 バイト password の裏取り。** `testfile.stuffit45_dlx.mac9.password.sit.bin` の resource fork から
`MKey` = `e3fe9f12776699c9`、最初の暗号化 data fork(Test Text、C = 32)の trailer =
`f840fe78e1ca92d7d684e34e9565fa6d` を取り出し、研究ハーネスの native probe を通じて
**XADMaster 自身の `keyForPasswordData:entryKey:MKey:` を黒箱で呼んだところ、password `password`
(コーパス README が明記する正しいパスワード)は `password-rejected`** だった。KaitoKit は Ch.05 の
2 block 派生が失敗したときに限り 1 block 派生を試し、`MKey` 検証に通ったうえで CC0 の暗号化 classic
wrapper 6 本の全 fork が平文版と一致する。したがって Ch.05 の「長さ 8 は 2 block」は XADMaster の
実装挙動であって StuffIt 4.5 の writer と一致せず、**XADMaster はこの書庫を復号できない**。
KaitoKit の互換経路は実書庫で裏付けられた拡張として維持する(bd `cooViewer-gu28` に記録)。

**表の転記。** `StuffItCrypto.swift` の改変 DES 表 8 行 × 64 語が `classic-key-substitution.json` と
順序どおり完全一致することをスクリプトで照合した。

**敵対的入力(ASan)。** slice 1 のハーネスに `-p password` を加え、暗号化 wrapper(`.bin` / `.as` / `.hqx`)
と method 5 / 6 / 8 の go 標本を必ず含めた 70 書庫で、切り詰め・bit 反転・header field 総当り・
method nibble 総当り・payload 乱数化を流した。**4,171 実行で sanitizer 報告・crash・タイムアウトは 0。**

**テスト。** `swift test` 977 件(954 + 23)、38 skip、失敗 0、`warning:` 0。
