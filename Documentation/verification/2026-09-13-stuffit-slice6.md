# StuffIt slice 6 検証（2026-09-13、bd `cooViewer-gu28.6`）

暗号層と SFX 走査を実装し、全 1,034 tests（40 skip、失敗 0）、build / test / release の
警告 0 を確認した。追加照合では `.exe` 21 本すべてと暗号化 `.sitx` 15 本が完全一致。
残る Windows 2009 DES は JPEG 一つだけ未対応で、暗号層・catalog・他の出力は検証できた。
**受理基準 2 の「16 本が compare.py で完全一致」は未達**。以下に未対応 JPEG と
支給オラクルの比較範囲の差を記録する。

対象は `feat/stuffit` の指定 worktree。編集のみ行い、git checkout / restore / stash / reset /
commit / push は実行していない。Web、外部実装ソース、vendor binary、資料のリンク先は参照していない。
開始時・完了時の HEAD は `c9c6f8877ce6773fed251d0895e94b467a4c4c1a`。
検証環境は Apple Swift 6.4（swiftlang-6.4.0.34.1）、arm64、macOS 27.0（26A428）。

## 実装と受理範囲

- `MD5Transform.swift`: RFC 1321 の圧縮関数を自前で実装した。通常の MD5 finalization は持たない。
- `StuffItXCrypto.swift`: Ch.13 の byte count・staging buffer・chaining words を維持する snapshot、
  `StuffIt || BE16(offset) || round source` の 256 round、`V = D(K,2)` を実装した。
  snapshot の一時 length word は buffer に吸収せず count にも加算しない。
- key 4 は既存の順序付き record を使い、合計長で一度派生、記録順に鍵を分割、逆順に層を剥がす。
  外側の verifier は一つだけ。各層の IV / salt はその層の入力の先頭から読む。
  verifier と全 IV / salt の長さ不足は `truncated`、verifier 不一致は `wrongPassword`。
- AES / Blowfish / DES は `CCCrypt` の ECB・padding なしによる一 block の**暗号化**を使う。
  CFB は `C XOR E_K(F)` と暗号文 feedback を自前で組み、末尾の部分 block を切り捨てない。
  RC4 は既存 `StuffItRC4` に `K || salt` を渡し、最初の keystream byte から使用する。
- 復号は framed 入力の直後、decompression の前。各層は固定 16 KiB の入力 buffer と
  CFB の feedback / keystream 各一 block または RC4 順列を保持し、書庫全体を materialize しない。
  coordinator は派生鍵を保持し、後方 seek では再派生しない。
  password 変更判定も UTF-8 bytes で行い、Swift String の正準等価比較による誤った鍵再利用を防ぐ。
- password bytes は UTF-8。正規化・NUL 終端処理・鍵長での切り詰めはしない。
  根拠は Ch.13 が記載する Ch.14 の Mac SDK 境界の結論と利用者の指定であり、Ch.14 自体は開いていない。
  実 writer の歴史的 GUI 全般の文字変換を保証するものではない。
- データ暗号化は password なしで列挙し `isEncrypted = true`。stream 取得時に `passwordRequired`。
  暗号化 catalog は open 時に password を要求し、未設定なら PasswordProvider を呼ぶ。
  解決した password は ArchiveReader と reopen に引き継ぐ。
  暗号化 kind-3 補助 stream は列挙を妨げず、所有 entry 取得時に実長全体と checksum を検証する。
- MZ `.exe` は候補起点を位置順に走査し、classic は最初の entry header CRC、StuffIt 5 は
  archive header CRC、StuffIt X は Root の packed header を検証する。不正な候補は飛ばし、
  最初の有効候補へ RebasedByteSource で起点を移す。stub を実行する処理はない。

| profile | 受理範囲・理由 |
|---|---|
| 派生長・層の合計鍵長 | 1〜65,536 bytes。snapshot offset の BE16 を維持し、加算・確保を制限する |
| AES | 16 / 24 / 32 bytes。通常の AES 鍵長 |
| Blowfish | 5〜56 bytes。Ch.13 ordinary profile |
| DES | 8 bytes。parity bit を書き換えず派生鍵を使う |
| RC4 | 1〜1,024 bytes。実例 64 bytes を含み、宣言長で増える派生作業と salt の資源量を制限する。KSA 入力はその 2 倍 |
| SFX 起点 | `maximumSFXScanSize` 既定・上限 1 MiB、境界を含む。0 は無効。header 検証は起点より先を読める |

CommonCrypto の実測では Blowfish の最小鍵長定数は 8 で、5 / 6 / 7 は `kCCKeySizeError (-4310)`。
そのため 5〜7 bytes は鍵を 2 回並べ、巡回する鍵展開への入力の周期を同一にした。
KDF・verifier・鍵スライスは元の宣言長のまま。5 / 6 / 7 / 56 の人工 CFB 書庫も検証した。
これは実 corpus の Blowfish-16 とは区別する。

SFX の File URL は自動走査し、Data / 任意 ByteSource は既存 RAR / 7z と同じ
`scanForSFXInData: true` を要求する。`.sea` の先頭署名判定は変更していない。
`.exe` が持たないのは**書庫 wrapper 自体の resource fork**であり、内側 entry の resource fork は扱う。
classic の暗号化 fork は MKey を持つ書庫 resource fork がないため既存の `unsupportedMethod` を保つ。

Root 暗号、JPEG compression 7、複数 digest scope、反復 compression / preprocessing は本 slice の範囲外。
verifier は 16 bit の password 検査であり、成功時も展開・実長・最終 checksum の検証を続ける。

## 入力の照合

4 ファイルとも `inbox/stuffit/SHA256SUMS` と一致した。

| 入力 | SHA-256 |
|---|---|
| `report/13-stuffitx-encryption.md` | `0763a1eb0031d755d27a51ba4a601876448fbd630eef274d4da01b3ecec0935e` |
| `report/03-stuffitx-container.md` | `c529f36039d7769ec6abae079f0314088418357ffe58c05515c55fe8d743ff53` |
| `report/02-stuffit5.md`（Windows self-extracting wrapper 節） | `a2590b95afb86534b038829cd7f33efc2b97fccb6bdb057e4a38371b19a701e4` |
| `rfc1321.txt` | `284a79d148400d9cd2a423211d1103b5cef0fb9256a4cbe6d7ebe5197c3149dd` |

## テスト

追加 XCTest は 14 件。K/V 表（8 / 16 / 32 / 64）、4 snapshot と count、MD5 padding 境界、
AES 完全例（45 → 27 → Cyanide 12 bytes、CRC `6ec18ffe`）、全 cipher・鍵長境界・層順、
framing の一 byte 分割、40,003 bytes の streaming、部分 block、任意位置読み、空平文、
truncated、passwordRequired / wrongPassword、catalog provider / reopen、UTF-8 / NUL / 正準等価文字列、
鍵の同一性を確認する後方 seek、SFX の複数候補・境界・classic 暗号を検証する。

外部 corpus 用 XCTest は `STUFFIT_SLICE6_CORPUS` を指定した場合だけ実行する。
素の暗号化 `.sitx` 10 本に含まれる 40 暗号要素について、38 data stream は最終 CRC が一致。
Windows 2009 DES の catalog は Brimstone（compression 0）で、復号した圧縮入力 73 bytes は
同じ writer の `win.backcompat.sitx` の catalog と一致する。
DES 暗号の内側に compression 5 を持つ data stream も最終 CRC を検証する。
JPEG の復号した圧縮入力 168 bytes は `testfile.stuffit_deluxe_2009.win.sitx` の同要素と一致する。

## コーパス照合の方法と受理基準との差

支給 `compare.py` とオラクルは変更していない。
そのままの集計と、追加 `Tests/Fixtures/stuffit/verify_slice6_corpus.py` の集計を分けて記録する。

支給スクリプトには次の相違があるため、「password 付き 16 本が compare.py で完全一致」は達成できない。

- Mac 7 の素の `.sitx` には選択されるオラクルがなく、wrapper 6 本の期待値は
  **平文の圧縮書庫自体**の単一 SHA。展開後の fork 群と比較するため mismatch になる。
- Windows password 版は成功時に JPEG を含む 3 data fork を出すが、スクリプトが優先する
  通常版 `.sitx` のオラクルには JPEG がなく 2 fork しかない。成功した 7 本が mismatch になる。
- Windows 2009 DES だけは JPEG compression 7 を実際に使い、同 entry が `unsupportedMethod`。
  catalog・全暗号層は復号できるが、最終 JPEG 220 bytes の展開には次の slice が必要。
  利用者の JPEG 例外は `.exe` に限定されているため、これは受理基準 2 の未達として明記する。
- `.exe` 21 本には選択されるオラクルがなく、成功しても no_oracle になる。

追加照合は全 fork の `(size, sha256)` 多重集合を、Mac 7 password 版は同じ writer の平文 `.sitx`、
Mac / Windows 7 `.exe` は同じ名前の `.sit`、Windows 2009 / 2010 は同じ writer の
`.backcompat.sitx` と比較する。install `.exe` も同じ 3 ファイルを含むためこの完全な平文版を使う。
比較先の data fork は支給 `oracle/cc0` の平文 `.sit` / `.backcompat.sitx` の SHA にも照合する。
ディレクトリと空 fork は除外し、resource fork の非空 bytes は比較対象に含める。
raw stdout / stderr と全比較先は `.build/slice6/corpus.json` に保存する。

JPEG を欠く DES 版は成功行が期待値の部分集合であり、欠落が 220 bytes の JPEG 一つだけ、
stderr がその entry の compression 7 未対応であることを確認し、`partial_jpeg` と分類する。
完全一致の 15 本には加算しない。


## 実行コマンドと出力

通常の `swift build` はホーム側 cache への書込み制限で失敗したため、既存 slice と同じく
cache / config / security と Clang module cache を worktree 内へ指定した。
release の通常 dSYM 生成も `Operation not permitted` で失敗したため、
`-debug-info-format none` を付けた。コンパイラ最適化や実装の受理範囲は変えていない。
最終の build / test / release は次のコマンドで実行した。

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang" swift build --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
STUFFIT_SLICE6_CORPUS="$PWD/inbox/stuffit-corpus" CLANG_MODULE_CACHE_PATH="$PWD/.build/clang" swift test --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang" swift build -c release --product kaito -debug-info-format none --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
```

追加テスト単独は同じ `swift test` に `--filter 'StuffItXCryptoTests|StuffItSFXTests'` を指定した。
ログは `.build/slice6/build.log` / `test.log` / `release.log` / `focused.log` に保存した。

上記の build / test / release はすべて exit 0。debug build 1.36 秒、release build 36.29 秒。
`warning:` は build / test / release 各 0 件。
最終の全 XCTest は外部 corpus も有効にし、次の結果だった。

```text
KaitoKitTests:
Executed 1011 tests, with 40 tests skipped and 0 failures (0 unexpected) in 286.834 (286.902) seconds
KaitoKitCompatTests:
Executed 23 tests, with 0 failures (0 unexpected) in 0.791 (0.794) seconds
暗号実コーパス: 10 書庫、最終 CRC 一致 38、catalog 圧縮入力一致 1、JPEG 圧縮入力一致 1
```

| 受理基準 | 結果 |
|---|---|
| 1. build / test、warning 0 | 上記の環境用指定で達成 |
| 2. password 16 本の compare.py 完全一致 | 未達。DES の JPEG と支給オラクルの範囲差を下記に記録 |
| 3. `.exe` 21 本 | 全 157 非空 fork 一致。JPEG 例外なし |
| 4. K/V・snapshot・AES 完全例の固定 XCTest | 達成 |
| 5. passwordRequired / wrongPassword | 達成。catalog open、data stream、provider、password 変更も検証 |

```sh
python3 inbox/stuffit-corpus/compare.py .build/out/Products/Release/kaito
```

全 CC0 216 本に対する出力の集計（exit 1）:

```text
match: 149
name_diff: 0
no_oracle: 27
kaito_error: 15
mismatch: 25
```

15 error の内訳は classic の書庫 resource fork 不在 2、Root recovery 10、JPEG compression 7 が 3
（通常の Windows 2009 / 2010 各 1 と今回の DES 1）。
25 mismatch は Mac 7 wrapper の圧縮書庫 SHA を選ぶ 18 と、JPEG を欠くオラクルを選ぶ Windows 暗号版 7。
27 no_oracle は `.exe` 21 と Mac 7 の素の `.sitx` 6。
raw 出力は `.build/slice6/compare.log` に保存した。

対象だけの同じスクリプトも実行した。

```sh
python3 inbox/stuffit-corpus/compare.py .build/out/Products/Release/kaito --only 'password.*sitx'
python3 inbox/stuffit-corpus/compare.py .build/out/Products/Release/kaito --only '\.exe$'
```

| 対象 | match | name_diff | no_oracle | kaito_error | mismatch | exit |
|---|---:|---:|---:|---:|---:|---:|
| password 16 本 | 0 | 0 | 2 | 1 | 13 | 1 |
| `.exe` 21 本 | 0 | 0 | 21 | 0 | 0 | 0 |

```sh
python3 Tests/Fixtures/stuffit/verify_slice6_corpus.py .build/out/Products/Release/kaito
```

追加照合の出力（exit 0、復号できた全 252 非空 fork が一致）:

```text
{"exe": {"match": 21}, "password": {"match": 15, "partial_jpeg": 1}}
```

これは DES の JPEG 例外を明示した検証スクリプトの成功であり、受理基準 2 の完全達成ではない。
`.exe` は JPEG を含むものも全 entry を展開でき、許容されていた JPEG 例外は発生しなかった。

### password 付き `.sitx` 16 本

非空 fork は data / resource の両方を数える。全 95 fork 一致、欠落は DES の JPEG 一つ。

| ファイル | 結果 | 一致 fork |
|---|---|---:|
| `testfile.stuffit7_dlx.mac9.password.sitx` | 完全一致 | 9 |
| `testfile.stuffit7_dlx.mac9.password.sitx.as` | 完全一致 | 9 |
| `testfile.stuffit7_dlx.mac9.password.sitx.bin` | 完全一致 | 9 |
| `testfile.stuffit7_dlx.mac9.password.sitx.hqx` | 完全一致 | 9 |
| `testfile.stuffit7_dlx.macx1.password.sitx` | 完全一致 | 9 |
| `testfile.stuffit7_dlx.macx1.password.sitx.as` | 完全一致 | 9 |
| `testfile.stuffit7_dlx.macx1.password.sitx.bin` | 完全一致 | 9 |
| `testfile.stuffit7_dlx.macx1.password.sitx.hqx` | 完全一致 | 9 |
| `testfile.stuffit_deluxe_2009.win.password.aes.sitx` | 完全一致 | 3 |
| `testfile.stuffit_deluxe_2009.win.password.blowfish.sitx` | 完全一致 | 3 |
| `testfile.stuffit_deluxe_2009.win.password.des.sitx` | JPEG 1 entry 未対応、他は一致 | 2 |
| `testfile.stuffit_deluxe_2009.win.password.rc4.sitx` | 完全一致 | 3 |
| `testfile.stuffit_deluxe_2010.win.password.aes.sitx` | 完全一致 | 3 |
| `testfile.stuffit_deluxe_2010.win.password.blowfish.sitx` | 完全一致 | 3 |
| `testfile.stuffit_deluxe_2010.win.password.des.sitx` | 完全一致 | 3 |
| `testfile.stuffit_deluxe_2010.win.password.rc4.sitx` | 完全一致 | 3 |

### `.exe` 21 本

全 157 非空 fork 一致。対応する `.sit` も password 付きの場合は `password` で復号して比較した。

| ファイル | 結果 | 一致 fork |
|---|---|---:|
| `testfile.stuffit651_dlx.mac9.comment.exe` | 完全一致 | 9 |
| `testfile.stuffit651_dlx.mac9.exe` | 完全一致 | 9 |
| `testfile.stuffit651_dlx.mac9.password.exe` | 完全一致 | 9 |
| `testfile.stuffit651_dlx.mac9.rreceipt.exe` | 完全一致 | 10 |
| `testfile.stuffit651_dlx.macx1.comment.exe` | 完全一致 | 9 |
| `testfile.stuffit651_dlx.macx1.exe` | 完全一致 | 9 |
| `testfile.stuffit651_dlx.macx1.password.exe` | 完全一致 | 9 |
| `testfile.stuffit651_dlx.macx1.rreceipt.exe` | 完全一致 | 10 |
| `testfile.stuffit7.win.exe` | 完全一致 | 3 |
| `testfile.stuffit7.win.password.exe` | 完全一致 | 3 |
| `testfile.stuffit7_dlx.mac9.comment.exe` | 完全一致 | 9 |
| `testfile.stuffit7_dlx.mac9.exe` | 完全一致 | 9 |
| `testfile.stuffit7_dlx.mac9.rreceipt.exe` | 完全一致 | 10 |
| `testfile.stuffit7_dlx.macx1.comment.exe` | 完全一致 | 9 |
| `testfile.stuffit7_dlx.macx1.exe` | 完全一致 | 9 |
| `testfile.stuffit7_dlx.macx1.password.exe` | 完全一致 | 9 |
| `testfile.stuffit7_dlx.macx1.rreceipt.exe` | 完全一致 | 10 |
| `testfile.stuffit_deluxe_2009.win.backcompat.exe` | 完全一致 | 3 |
| `testfile.stuffit_deluxe_2009.win.install.exe` | 完全一致 | 3 |
| `testfile.stuffit_deluxe_2010.win.backcompat.exe` | 完全一致 | 3 |
| `testfile.stuffit_deluxe_2010.win.install.exe` | 完全一致 | 3 |

### 指定された 4 つの CLI コマンド

```sh
.build/out/Products/Release/kaito sha inbox/stuffit-corpus/cc0/testfile.stuffit_deluxe_2009.win.password.des.sitx -p password
```

exit 1。stdout と stderr:

```text
0	12	b2f51cd17b3cbe77f091f887d91110164a2cb5a5a9ebe828c44d655c83dca8eb	sources/testfile.txt
1	87	fdda20984cc1591419ec4583e24e72e4dba39d0b96608253f853a2dfb238ad1a	sources/testfile.png
2	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	sources
partial	3	2803eefb15a2fb42227482c5363bbf17698aaa664e0eb26243590b06d22db6c4	
error: failed entry 1 (sources/testfile.jpg): Unsupported archive method: StuffIt X compression 7
error: 1 archive entries failed
```

```sh
.build/out/Products/Release/kaito sha inbox/stuffit-corpus/cc0/testfile.stuffit7_dlx.mac9.password.sitx.hqx -p password
```

exit 0。stdout:

```text
0	12	b645efee0ed710034959eae942277a750d08687c30bcf0e9ec6ea7641527462f	testfile.txt
1	11	9734aef6d3788ba985e78f7b3785dc4817e770be92a4e5e57e64a92cc9c2fc25	Test Text
2	220	e514232511df1a4f4221a75c27523518c3c62a2fe6470fa56e430364428eecd1	testfile.jpg
3	2694	318d71cd4d027c6bec6917af3ddc3b7df0ec8b07031045a9cdd9052b94c7782e	testfile.PICT
4	87	fdda20984cc1591419ec4583e24e72e4dba39d0b96608253f853a2dfb238ad1a	testfile.png
5	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	Test Image
total	6	7d187cd6815deb5c70aae74b988e25eb5033ec10fc0547e6fff2995e413406be	
```

```sh
.build/out/Products/Release/kaito sha inbox/stuffit-corpus/cc0/testfile.stuffit651_dlx.mac9.exe
```

exit 0。stdout:

```text
0	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	Test Image
1	11	9734aef6d3788ba985e78f7b3785dc4817e770be92a4e5e57e64a92cc9c2fc25	Test Text
2	220	e514232511df1a4f4221a75c27523518c3c62a2fe6470fa56e430364428eecd1	testfile.jpg
3	2694	318d71cd4d027c6bec6917af3ddc3b7df0ec8b07031045a9cdd9052b94c7782e	testfile.PICT
4	87	fdda20984cc1591419ec4583e24e72e4dba39d0b96608253f853a2dfb238ad1a	testfile.png
5	12	b645efee0ed710034959eae942277a750d08687c30bcf0e9ec6ea7641527462f	testfile.txt
total	6	873d01475ab1f240d4fe5700b5f24d5bc3ab1469d2ab8c981bd75e6c3e7defaf	
```

```sh
.build/out/Products/Release/kaito sha inbox/stuffit-corpus/cc0/testfile.stuffit_deluxe_2010.win.install.exe
```

exit 0。stdout:

```text
0	12	b2f51cd17b3cbe77f091f887d91110164a2cb5a5a9ebe828c44d655c83dca8eb	sources/testfile.txt
1	87	fdda20984cc1591419ec4583e24e72e4dba39d0b96608253f853a2dfb238ad1a	sources/testfile.png
2	220	e514232511df1a4f4221a75c27523518c3c62a2fe6470fa56e430364428eecd1	sources/testfile.jpg
3	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	sources
total	4	8d4eddc0826a739747eab95bf737ea61ffd4272de2b18431c731e732169de568	
```

最終 release `kaito` の SHA-256: `8349b3a4e873402425aad44a88e6bd96dc403264a707754f83b5df17a4a99199`。

## 変更ファイル（15 ファイル）

| ファイル | 区分 | 内容 |
|---|---|---|
| `Sources/KaitoKit/Core/MD5Transform.swift` | 新規 | RFC 1321 の圧縮関数 |
| `Sources/KaitoKit/Formats/StuffItX/StuffItXCrypto.swift` | 新規 | continuing-MD5・verifier・暗号層 |
| `Sources/KaitoKit/Formats/StuffIt/StuffItSFX.swift` | 新規 | MZ 署名候補の走査と header 検証 |
| `Sources/KaitoKit/Formats/StuffItX/StuffItXStreamCoordinator.swift` | 変更 | 復号 pipeline・鍵の保持 |
| `Sources/KaitoKit/Formats/StuffItX/StuffItXReader.swift` | 変更 | password・catalog・暗号化補助 stream |
| `Sources/KaitoKit/Formats/FormatDetector.swift` | 変更 | StuffIt SFX の検出と rebase |
| `Sources/KaitoKit/Reader/ArchiveReader.swift` | 変更 | SFX options と解決済み password の接続 |
| `Sources/KaitoKit/Reader/PasswordProvider.swift` | 変更 | ReaderOptions の SFX 説明に StuffIt を追加 |
| `Tests/KaitoKitTests/StuffItXCryptoTests.swift` | 新規 | 固定値・暗号境界・実コーパス |
| `Tests/KaitoKitTests/StuffItSFXTests.swift` | 新規 | 候補検証・scan bound・password |
| `Tests/Fixtures/stuffit/verify_slice6_corpus.py` | 新規 | 同じ writer の全 fork と支給 data fork SHA の追加照合 |
| `Documentation/verification/2026-09-13-stuffit-slice6.md` | 新規 | 本記録 |
| `Documentation/design.md` | 変更 | §10 出自・§11 実装記録 |
| `CHANGELOG.md` | 変更 | slice 6 の変更点 |
| `README.md` | 変更 | 暗号・SFX・残る制約 |

## orchestrator による独立検証

Codex の検証とは別に、orchestrator が release / ASan の `kaito` を組み直して実施した。

- `compare.py`(平文版をオラクルにする版): kaito_error は resource fork 無しの classic 暗号化 2、
  recovery Root 10、JPEG(compression 7)3 のみ。`mismatch` / `no_oracle` に載る `.exe` 21 本と
  password 付き `.sitx` は、いずれも **KaitoKit の出力がオラクルより多い**ことによる(XADMaster は
  `.exe` を開けず、平文版の JPEG entry をサイズ 0 で出す。例: `2010.win.password.aes.sitx` は
  `testfile.jpg` が Cyanide 格納で、KaitoKit は 220 バイト・sha `e514…` で復号できる)。
- 誤 password → `The password is incorrect`(`wrongPassword`)、未指定 → `A password is required`
  (`passwordRequired`)を CLI で確認。
- `.exe`: `2010.win.install.exe` の 3 ファイルが `.sitx` 版と同じ sha256。
- ASan: password 付き `.sitx` と `.exe` 30 書庫に切り詰め・bit 反転・乱数化を流し **2,220 実行で所見 0**。
- `swift test` 1,034 件(1,011 + 23)、41 skip、失敗 0、`warning:` 0。
