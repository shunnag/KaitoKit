# KDF 予算と verifier の修正（2026-10-26）

## 環境・範囲

- 作業場所: 専用 worktree（`<repo>`）。基点は依頼指定の 143003a / v0.16.0。
- Apple M4 Max、16 cores（12 performance / 4 efficiency）、128 GB。
- 実測: macOS 27.2（26B118）、Xcode 27.1（27A9275）、Apple Swift 6.4、arm64。
  依頼の macOS 26 / Swift 6 と異なるので、依頼文の秒数は転記せず今回の実測を残す。
- 第三者のアーカイブ実装ソースは参照していない。入力は依頼文、現行の自作実装・テスト、
  `design.md` §10。依頼にある監査報告本体はこの worktree に存在しなかった。
- git は報告にも変更確認にも使わず、編集前のファイル SHA-256 と編集後を比較した。
  main repository は開かず、commit / push / branch 作成・インストールは行っていない。

通常の SwiftPM は既定 module cache への書込みで失敗し、Xcode build system は dSYM 作成で
`Operation not permitted` になった。以下の環境変数と `--disable-sandbox --build-system native` を
全検証で使う。製品設定は変更していない。

```sh
export CLANG_MODULE_CACHE_PATH=/tmp/kdf-clang-cache
export SWIFTPM_MODULECACHE_OVERRIDE=/tmp/kdf-swift-cache
swift build --disable-sandbox --build-system native -c release --product kaito
cp .build/arm64-apple-macosx/release/kaito .build/kdf-verification/kaito-before
```

修正前 binary は製品ソース編集前に作った。作業ログ・binary・計測用高 cycles 書庫は
`.build/kdf-verification/` と `/tmp/kdf-*.log` に保存し、fixture の通常テストには含めない。

## S1 / C3 — 7z entry KDF

### 再現

`Tests/Fixtures/sevenzip-kdf/generate.py` は自作 header / SHA-256 KDF と OpenSSL の
AES-256-CBC primitive だけを使う。通常 fixture は cyclesPower 8、password `anypw`、
平文 `Kaito KDF test!\n`、CRC 付き。計測用 `--opaque` は KDF を生成時に回さず、
零の暗号文と CRC なしの folder を置く。計測では出力内容の正しさを主張しない。

```sh
python3 Tests/Fixtures/sevenzip-kdf/generate.py --output .build/kdf-verification/crafted1.7z --folders 1 --power 24 --opaque
python3 Tests/Fixtures/sevenzip-kdf/generate.py --output .build/kdf-verification/crafted4.7z --folders 4 --power 24 --opaque
python3 Tests/Fixtures/sevenzip-kdf/generate.py --output .build/kdf-verification/crafted33.7z --folders 33 --power 24 --opaque
/usr/bin/time -p .build/kdf-verification/kaito-before sha .build/kdf-verification/crafted1.7z -p anypw --sink
/usr/bin/time -p .build/kdf-verification/kaito-before sha .build/kdf-verification/crafted4.7z -p anypw --sink
/usr/bin/time -p .build/kdf-verification/kaito-before sha .build/kdf-verification/crafted33.7z -p anypw --sink
```

### 原因

entry の factory と decrypted packed stream SPI が無課金の closure を渡していた。
鍵 cache の salt 重複排除は folder ごとに異なる salt で回避でき、辞書にも保持上限がなかった。

### 修正

追加 API `ReadLimits.maxSevenZipEntryKDFWork` の最終既定値は **67,108,864 = `4 * (1 << 24)`**
SHA-256 rounds。7-Zip の固定値 cyclesPower 19 なら128種の salt 分、最大 cyclesPower 24 なら4回分。
最大コスト一回は今回の release 実測で user **0.42秒**、四回は約1.7秒であり、既存 header 予算と
同じ約2秒の目安へ揃えた。通常の writer は一つの salt を書庫内で共有し、多数 folder でも一度の導出で済む。header の既存予算とは独立し、cache は共有する。
reader が持つ `KDFWorkBudget` を factory / coordinator / SPI に渡し、cache miss の直前に課金する。
cache hit と direct key は無料。超過は `limitExceeded("7z entry KDF work")`。
鍵 cache は64件の FIFO、退去後の再導出は再課金する。password 変更・失敗で予算を戻さない。

### 回帰テスト

`SevenZipEntryKDFTests` は33個の distinct salt / 2個の shared salt の checked-in fixture を使う。
既定予算の境界は既消費分だけを internal hook で課金し、最後の4回を実際の cyclesPower 8 で導出する。
既定値を超える最後の miss が導出前に拒まれることを既存の `didDeriveKey` で数える。
明示上限の32→33回への引上げ、正しい平文、一覧の無課金、繰返し cache hit、SPI、password 変更、
FIFO の退去と direct key を検証する。sleep と高 cycles fixture は通常 suite に入れない。
既存 encrypted-7z fixture は変更していない。

## S2 / C4 — StuffIt X KDF

### 再現

`Tests/Fixtures/stuffitx-kdf/generate.py` は既存の `StuffItXContainerTests.Writer` と同じ
p2 / element / frames を使う自作 generator。空 catalog に RC4 1,024-byte record を並べる。
65,536-byte 宣言の書庫は **192 bytes**（依頼の225 bytesとは別の自作入力）。
暗号文がなくても password を渡すと verifier 読取り前に導出する。終了時の `truncated` は
仕事を支払った後の検査であり、軽い拒否ではない。

```sh
python3 Tests/Fixtures/stuffitx-kdf/generate.py --length 16384 --output .build/kdf-verification/crafted16384.sitx
python3 Tests/Fixtures/stuffitx-kdf/generate.py --length 32768 --output .build/kdf-verification/crafted32768.sitx
python3 Tests/Fixtures/stuffitx-kdf/generate.py --output .build/kdf-verification/crafted65536.sitx
/usr/bin/time -p .build/kdf-verification/kaito-before list .build/kdf-verification/crafted16384.sitx -p x
/usr/bin/time -p .build/kdf-verification/kaito-before list .build/kdf-verification/crafted32768.sitx -p x
/usr/bin/time -p .build/kdf-verification/kaito-before list .build/kdf-verification/crafted65536.sitx -p x
```

### 原因

256 round の各16-byte出力が前 round の全出力を再投入する。丸めた鍵長 R に対し入力は
約 `16 * R²` byte。1,024-byte RC4 record を64個並べると、受理範囲内の65,536 byteに達する。
catalog と各 entry の coordinator は別々の crypto を作り、reader 単位の累積予算も取消し検査もなかった。

### 修正

追加 API `ReadLimits.maxStuffItXKDFWork` の最終既定値は **4,194,304 = `1 << 22`** MD5 圧縮回数。
鍵と verifier の導出をまとめて先払いし、catalog / entry / 補助 stream で reader の同じ予算を使う。
実際の鍵素材は1 KiB未満（RC4 実例64、AES最大32、Blowfish最大56、DES 8 byte）。
16-byte鍵なら4,104 entry 分、32-byte鍵なら2,734 entry 分を reader 内で許す（8-byte password）。
約4 KiBの単独導出が約1.7秒の目安となり、8 KiB以上や65,536-byte宣言の約10.7億回を拒む。
padding・verifier も含む現行計算を維持した結果、password `x` での正確な境界は4,032 byte。
4,096 byteの仕事量は4,309,566回なので、指定の `1 << 22` では受理されない。
例えば8-byte password / 16-byte鍵は1,022回、128-byte鍵は8,688回。
受理範囲 `1...65_536` / RC4 `<= 1_024` は変えず、超過は
`limitExceeded("StuffIt X KDF work")`。各 round 先頭に `Task.checkCancellation()` を置く。

仕事量は実際の continuing MD5 の padding と一時 length block も数える。
入力長 P、丸め出力長 R、m = R / 16 の一導出は
`floor((P + 17) / 64) + 1 + (m - 1) * (floor((P + 9) / 64) + 2)
+ 255 * m * (floor((R + 9) / 64) + 2)` 回。
これを password→鍵と鍵→2-byte verifier について合算する。password `x` / 65,536-byte鍵では
**1,071,646,206回**。鍵導出だけの再投入量は **68,460,482,560 bytes**（約68.5 GB）、
192-byte書庫の約3.57億倍。これは計算値であり、CPU命令数の測定値ではない。

### 回帰テスト

`StuffItXKDFWorkTests` は既存 Swift test writer を再利用し、192-byte fixture と byte 単位で照合する。
最大鍵長は catalog open と entry read の双方で導出前に拒否する。password なしの catalog は
`passwordRequired`、entry は一覧だけなら導出しない。128-byte の実導出と caller 上限引上げ、
二つの encrypted stream の通算、catalog→entry の通算、cache 再読、password 変更、取消しを検査する。
計算した圧縮回数は continuing MD5 の実際の byteCount と snapshot から独立に数えた値と照合する。
既存の全 cipher・暗号化 fixture のテストも実行する。最大鍵長のエラーは時間ではなく error で判定する。

## S3 / C6 — StuffIt 5 verifier

### 再現

編集前 SHA-256 と一致する `StuffItCrypto.swift` を一行の差分から復元し、`first5` / `sit5Key` を
切り出した小さな Swift harness を `swiftc -O -module-cache-path /tmp/kdf-swift-cache` で実行した。
修正後は同じ harness に現行 `ConstantTime.swift` を加えて実行し、`cmp` で stdout の一致を確認した。

```sh
swiftc -O -module-cache-path /tmp/kdf-swift-cache .build/kdf-verification/verifier-before.swift -o .build/kdf-verification/verifier-before
swiftc -O -module-cache-path /tmp/kdf-swift-cache .build/kdf-verification/verifier-after.swift -o .build/kdf-verification/verifier-after
.build/kdf-verification/verifier-before
.build/kdf-verification/verifier-after
cmp /tmp/kdf-before-verifier.log /tmp/kdf-after-verifier.log
```

### 原因

秘密の5-byte verifier だけが `Array ==` に残り、不一致位置に依存する早期終了を許していた。
実用的な攻撃や時間差の大きさは測定・主張しない。

### 修正

internal `ConstantTime.equals([UInt8], [UInt8])` を追加し、この比較だけを置き換えた。
全 byte の XOR / OR を畳み、長さ不一致は false。公開値の比較と `verified` は変えていない。

### 回帰テスト

`StuffItSlice2CryptoTests.testStuffIt5VerifierAcceptRejectAndLengthSemantics` は正常値、各5位置の
不一致、0 / 4 / 6-byte長、空配列比較を検証する。archive hash の長さ不一致は従来どおり
`malformed`、同長の誤値は `wrongPassword`。

## 実測出力・検証結果（初回修正の記録）

以下は初回の旧既定値（7z `32 * (1 << 24)` / StuffIt X `1 << 26`）による履歴。
最終既定値の境界再計測と再検証は後述する。

1 / 4 folder は提示された24.44 / 103.27秒を再現せず、今回の user CPU は0.48 / 2.13秒だった。
33 folder では24.94秒。当時の既定予算は33個目の導出前に止めるため、初回修正後も32回分の仕事は許していた。
一覧は修正後も導出せず完了した。秒数は `/usr/bin/time -p` の丸め値。

### S1 修正前・1 folder

```text
0	16	f000
total	1	16	
real 0.75
user 0.48
sys 0.00
```

### S1 修正前・4 folder

```text
0	16	f000
1	16	f001
2	16	f002
3	16	f003
total	4	64	
real 2.14
user 2.13
sys 0.00
```

### S1 修正前・33 folder

```text
0	16	f000
1	16	f001
2	16	f002
3	16	f003
4	16	f004
5	16	f005
6	16	f006
7	16	f007
8	16	f008
9	16	f009
10	16	f010
11	16	f011
12	16	f012
13	16	f013
14	16	f014
15	16	f015
16	16	f016
17	16	f017
18	16	f018
19	16	f019
20	16	f020
21	16	f021
22	16	f022
23	16	f023
24	16	f024
25	16	f025
26	16	f026
27	16	f027
28	16	f028
29	16	f029
30	16	f030
31	16	f031
32	16	f032
total	33	528	
real 25.11
user 24.94
sys 0.08
```

### S1 修正後・33 folder（初回の旧既定予算）

```text
error: failed entry 32 (f032): Read limit exceeded: 7z entry KDF work
error: 1 archive entries failed
0	16	f000
1	16	f001
2	16	f002
3	16	f003
4	16	f004
5	16	f005
6	16	f006
7	16	f007
8	16	f008
9	16	f009
10	16	f010
11	16	f011
12	16	f012
13	16	f013
14	16	f014
15	16	f015
16	16	f016
17	16	f017
18	16	f018
19	16	f019
20	16	f020
21	16	f021
22	16	f022
23	16	f023
24	16	f024
25	16	f025
26	16	f026
27	16	f027
28	16	f028
29	16	f029
30	16	f030
31	16	f031
32	ERROR	failed entry 32: Read limit exceeded: 7z entry KDF work	f032
partial	32	512	
real 22.68
user 22.23
sys 0.07
```

### S2 修正前・16,384 bytes

```text
error: The archive is truncated
real 38.41
user 34.62
sys 0.14
```

### S2 修正前・32,768 bytes

```text
error: The archive is truncated
real 162.83
user 147.50
sys 1.00
```

### S2 修正前・65,536 bytes

192-byte書庫は修正前に完走まで user 706.16秒 / wall 763.96秒を消費した。
提示の120秒での打切り計測より長く実行し、今回の値をそのまま残す。

```text
error: The archive is truncated
real 763.96
user 706.16
sys 4.88
```

### S2 修正後・65,536 bytes（初回の旧既定予算）

```text
error: Read limit exceeded: StuffIt X KDF work
real 0.01
user 0.00
sys 0.00
```

### S3 修正前

```text
accepted: true
mismatch[0]: wrongPassword
mismatch[1]: wrongPassword
mismatch[2]: wrongPassword
mismatch[3]: wrongPassword
mismatch[4]: wrongPassword
length[0]: malformed("StuffIt 5 archive hash")
length[4]: malformed("StuffIt 5 archive hash")
length[6]: malformed("StuffIt 5 archive hash")
```

### S3 修正後

```text
accepted: true
mismatch[0]: wrongPassword
mismatch[1]: wrongPassword
mismatch[2]: wrongPassword
mismatch[3]: wrongPassword
mismatch[4]: wrongPassword
length[0]: malformed("StuffIt 5 archive hash")
length[4]: malformed("StuffIt 5 archive hash")
length[6]: malformed("StuffIt 5 archive hash")
```

### 初回の修正後 CLI コマンド

```sh
swift build --disable-sandbox --build-system native -c release --product kaito
cp .build/arm64-apple-macosx/release/kaito .build/kdf-verification/kaito-after
/usr/bin/time -p .build/kdf-verification/kaito-after sha .build/kdf-verification/crafted33.7z -p anypw --sink
/usr/bin/time -p .build/kdf-verification/kaito-after list .build/kdf-verification/crafted65536.sitx -p x
/usr/bin/time -p .build/kdf-verification/kaito-after list .build/kdf-verification/crafted33.7z -p anypw
```

S1 一覧取得の末尾（全33 entry を表示、導出なし）:

```text
32	16	file	7zAES-256	7zAES-256	f032
real 0.00
user 0.00
sys 0.00
```

### build・対象テスト

```sh
swift build --disable-sandbox --build-system native
swift test --disable-sandbox --build-system native --filter SevenZip
swift test --disable-sandbox --build-system native --filter StuffIt
swift test --disable-sandbox --build-system native --filter ReadLimits
swift test --disable-sandbox --build-system native
```

上記の cache 環境変数を付けて実行。対象テストの最終集計:

```text
swift build
Build complete! (10.58s)
SevenZip
	 Executed 206 tests, with 1 test skipped and 0 failures (0 unexpected) in 131.340 (131.362) seconds
StuffIt
	 Executed 151 tests, with 7 tests skipped and 0 failures (0 unexpected) in 130.207 (130.239) seconds
ReadLimits
	 Executed 3 tests, with 0 failures (0 unexpected) in 0.093 (0.098) seconds
```

最大鍵長の catalog / entry 拒否テストは、それぞれ0.001秒で完了した（assert は error のみ）。

### 初回の全件テスト

SwiftPM の終了コードは 0。本体 `KaitoKitTests` は1,842件（依頼の1,828件＋追加14件）、
`KaitoKitCompatTests` は34件。全件の集計は1,876件、skip は依頼の基点と同じ51件。
開始行の module 名を集計して内訳も確認した。

```text
	 Executed 1876 tests, with 51 tests skipped and 0 failures (0 unexpected) in 1739.459 (1739.683) seconds
Test Suite 'All tests' passed at 2026-10-26 19:38:16.430.
	 Executed 1876 tests, with 51 tests skipped and 0 failures (0 unexpected) in 1739.459 (1739.687) seconds
```


## 既定値の再調整（release 境界再計測）

実装方式は維持し、既定値だけを下げた。7z の初回 `32 * (1 << 24)` は32 saltで約13.5秒、
StuffIt X の初回 `1 << 26` は8 KiBの宣言で約6.5秒を許していた。
既存 header 予算と同じ release の約2秒を目安に、7z は `4 * (1 << 24)`、StuffIt X は `1 << 22` とする。
7-Zip の固定値 cyclesPower 19 なら128 salt分であり、実際の writer は一つの salt を共有する。
4回の最大コスト導出と約4 KiBの StuffIt X 導出が境界で、必要な caller は上限を引き上げられる。

### 比較の等号と StuffIt X の正確な境界

`KDFWorkBudget.charge` の条件は `work <= remaining`。等しい場合は受理し、残りは0になる。
0の追加課金も受理し、それ以降の正の仕事量は `limitExceeded`。比較は今回変更していない。
7z の cyclesPower 24 ×4 saltは `4 * 2^24` と等しく、受理する。5 saltの5回目を拒否する。

StuffIt X は padding と verifier も含むため、厳密な4 KiBを受理するという見積りとは差がある。
password `x` での計算値は次のとおり。計算方式・受理する鍵長範囲を変更して辻褄を合わせず、指定の上限を維持した。

| 宣言した鍵素材 | MD5 圧縮回数 | `1 << 22` との比較 |
| --- | ---: | --- |
| 4,032 bytes | 4,177,977 | 受理 |
| 4,033 bytes | 4,194,554 | 超過（250回） |
| 4,096 bytes | 4,309,566 | 超過 |
| 8,192 bytes | 16,974,462 | 超過 |

この「受理」は導出を許す意味。自作 StuffIt X 計測書庫は暗号文を置かないため、導出後は
`truncated` になる。`limitExceeded` なら導出前に拒んでいる。
7z の `--opaque` も平文の正しさは主張せず、saltごとの導出仕事だけを検査する。

### 今回の変更範囲

`ReadLimits.swift` の既定値・doc comment、既定値を検査するテスト3ファイル、
README / embedding / design / CHANGELOG / 本記録の計9ファイル。
修正前 SHA-256 と照合し、課金、cache miss 判定、64鍵 FIFO、取消し、鍵長の受理範囲、
verifier の実装ファイルがすべて不変であることを確認した。fixture の generator / base64 / manifest も不変。
新たな第三者アーカイブ実装ソースの参照、インストール、commit / push / branch 作成は行っていない。

### 再計測手順

初回修正時の release binary を `.build/kdf-defaults/kaito-before`、最終既定値のものを
`.build/kdf-defaults/kaito-after` に保存した。以下は `<repo>` から実行する。
SwiftPM の cache 環境変数・native build system は先述と同じ。

```sh
cp .build/kdf-verification/kaito-after .build/kdf-defaults/kaito-before
swift build --disable-sandbox --build-system native -c release --product kaito
cp .build/arm64-apple-macosx/release/kaito .build/kdf-defaults/kaito-after
python3 Tests/Fixtures/sevenzip-kdf/generate.py --output .build/kdf-defaults/salts4.7z --folders 4 --power 24 --opaque
python3 Tests/Fixtures/sevenzip-kdf/generate.py --output .build/kdf-defaults/salts5.7z --folders 5 --power 24 --opaque
python3 Tests/Fixtures/sevenzip-kdf/generate.py --output .build/kdf-defaults/salts32.7z --folders 32 --power 24 --opaque
python3 Tests/Fixtures/stuffitx-kdf/generate.py --length 4032 --output .build/kdf-defaults/t4032.sitx
python3 Tests/Fixtures/stuffitx-kdf/generate.py --length 4033 --output .build/kdf-defaults/t4033.sitx
python3 Tests/Fixtures/stuffitx-kdf/generate.py --length 4096 --output .build/kdf-defaults/t4096.sitx
python3 Tests/Fixtures/stuffitx-kdf/generate.py --length 8192 --output .build/kdf-defaults/t8192.sitx
```

今回の書庫は7z 4 / 5 / 32 saltが265 / 318 / 1,750 bytes、StuffIt X 4,096 / 8,192 byte宣言が
27 / 38 bytes。依頼の1,666 / 60 / 71 bytesとは別の自作入力で、同じ導出数・鍵長を検査する。

一部の初回測定がdebug buildと並行し、7z 4回のuser時間が2.73秒、StuffIt X 4,032 byteが3.52秒にぶれた。
そのログは `.build/kdf-defaults/loaded-kdf-defaults-after-*.log` に保持する。
最終比較は指定の全件テスト完了後に、最終ソースの release build が終わってから、ビルド・テストと並行させずに取り直した。

### 既定値変更後の対象テスト

```sh
swift build --disable-sandbox --build-system native
swift test --disable-sandbox --build-system native --filter SevenZip
swift test --disable-sandbox --build-system native --filter StuffIt
swift test --disable-sandbox --build-system native --filter ReadLimits
swift test --disable-sandbox --build-system native
```

build と対象テストの実出力（cache の環境変数は先述と同じ）:

```text
swift build
Build complete! (20.00s)
SevenZip
	 Executed 206 tests, with 1 test skipped and 0 failures (0 unexpected) in 146.810 (146.835) seconds
StuffIt
	 Executed 151 tests, with 7 tests skipped and 0 failures (0 unexpected) in 71.647 (71.662) seconds
ReadLimits
	 Executed 3 tests, with 0 failures (0 unexpected) in 0.051 (0.054) seconds
```

### 既定値変更後の全件テスト

終了コード0。本体1,842件＋互換層34件、計1,876件。skipは51件で変わらない。

```text
	 Executed 1876 tests, with 51 tests skipped and 0 failures (0 unexpected) in 1146.116 (1146.283) seconds
Test Suite 'All tests' passed at 2026-10-26 20:36:52.021.
	 Executed 1876 tests, with 51 tests skipped and 0 failures (0 unexpected) in 1146.116 (1146.285) seconds
```

### 最終 release の境界再計測

最終ソースからの build 実出力:

```text
Build of product 'kaito' complete! (87.50s)
```

全件テスト・release build の終了後、各コマンドを逐次一回ずつ実行した。
`before` は初回の旧既定値、`after` は今回の最終既定値。秒数は user CPU、0.00は表示桁の丸め値。

| 書庫 | before（秒） | after（秒） | after の結果 |
| --- | ---: | ---: | --- |
| 7z 1 salt | 0.42 | 0.42 | 受理、exit 0 |
| 7z 4 salt（予算と等しい） | 1.68 | 1.69 | 受理、exit 0 |
| 7z 5 salt | 2.11 | 1.68 | limitExceeded、exit 1 |
| 7z 32 salt | 13.52 | 1.69 | limitExceeded、exit 1 |
| StuffIt X 4,032 bytes | 1.60 | 1.59 | 導出後 truncated、exit 1 |
| StuffIt X 4,033 bytes | 1.63 | 0.00 | limitExceeded、exit 1 |
| StuffIt X 4,096 bytes | 1.63 | 0.00 | limitExceeded、exit 1 |
| StuffIt X 8,192 bytes | 6.54 | 0.00 | limitExceeded、exit 1 |

最大コスト `2^24` の一導出は前後とも user 0.42秒。4回なら約1.7秒となり、
新しい7z既定値で4回は受理、5回目以降は導出前に拒否された。
StuffIt X は約4 KiBに当たる4,032 byteの導出が user 1.59秒。
厳密な4,096 byteは計算上予算超過なので、上記のとおり最終既定値では導出前に拒否された。

#### 7z 1 salt / before

```sh
/usr/bin/time -p .build/kdf-defaults/kaito-before sha .build/kdf-verification/crafted1.7z -p anypw --sink
```

```text
0	16	f000
total	1	16	
real 0.44
user 0.42
sys 0.00
```

#### 7z 1 salt / after

```sh
/usr/bin/time -p .build/kdf-defaults/kaito-after sha .build/kdf-verification/crafted1.7z -p anypw --sink
```

```text
0	16	f000
total	1	16	
real 0.49
user 0.42
sys 0.00
```

#### 7z 4 salt（予算と等しい） / before

```sh
/usr/bin/time -p .build/kdf-defaults/kaito-before sha .build/kdf-defaults/salts4.7z -p anypw --sink
```

```text
0	16	f000
1	16	f001
2	16	f002
3	16	f003
total	4	64	
real 1.70
user 1.68
sys 0.00
```

#### 7z 4 salt（予算と等しい） / after

```sh
/usr/bin/time -p .build/kdf-defaults/kaito-after sha .build/kdf-defaults/salts4.7z -p anypw --sink
```

```text
0	16	f000
1	16	f001
2	16	f002
3	16	f003
total	4	64	
real 1.71
user 1.69
sys 0.01
```

#### 7z 5 salt / before

```sh
/usr/bin/time -p .build/kdf-defaults/kaito-before sha .build/kdf-defaults/salts5.7z -p anypw --sink
```

```text
0	16	f000
1	16	f001
2	16	f002
3	16	f003
4	16	f004
total	5	80	
real 2.13
user 2.11
sys 0.01
```

#### 7z 5 salt / after

```sh
/usr/bin/time -p .build/kdf-defaults/kaito-after sha .build/kdf-defaults/salts5.7z -p anypw --sink
```

```text
error: failed entry 4 (f004): Read limit exceeded: 7z entry KDF work
error: 1 archive entries failed
0	16	f000
1	16	f001
2	16	f002
3	16	f003
4	ERROR	failed entry 4: Read limit exceeded: 7z entry KDF work	f004
partial	4	64	
real 1.70
user 1.68
sys 0.00
```

#### 7z 32 salt / before

```sh
/usr/bin/time -p .build/kdf-defaults/kaito-before sha .build/kdf-defaults/salts32.7z -p anypw --sink
```

```text
0	16	f000
1	16	f001
2	16	f002
3	16	f003
4	16	f004
5	16	f005
6	16	f006
7	16	f007
8	16	f008
9	16	f009
10	16	f010
11	16	f011
12	16	f012
13	16	f013
14	16	f014
15	16	f015
16	16	f016
17	16	f017
18	16	f018
19	16	f019
20	16	f020
21	16	f021
22	16	f022
23	16	f023
24	16	f024
25	16	f025
26	16	f026
27	16	f027
28	16	f028
29	16	f029
30	16	f030
31	16	f031
total	32	512	
real 13.61
user 13.52
sys 0.05
```

#### 7z 32 salt / after

```sh
/usr/bin/time -p .build/kdf-defaults/kaito-after sha .build/kdf-defaults/salts32.7z -p anypw --sink
```

```text
error: failed entry 4 (f004): Read limit exceeded: 7z entry KDF work
error: failed entry 5 (f005): Read limit exceeded: 7z entry KDF work
error: failed entry 6 (f006): Read limit exceeded: 7z entry KDF work
error: failed entry 7 (f007): Read limit exceeded: 7z entry KDF work
error: failed entry 8 (f008): Read limit exceeded: 7z entry KDF work
error: failed entry 9 (f009): Read limit exceeded: 7z entry KDF work
error: failed entry 10 (f010): Read limit exceeded: 7z entry KDF work
error: failed entry 11 (f011): Read limit exceeded: 7z entry KDF work
error: failed entry 12 (f012): Read limit exceeded: 7z entry KDF work
error: failed entry 13 (f013): Read limit exceeded: 7z entry KDF work
error: failed entry 14 (f014): Read limit exceeded: 7z entry KDF work
error: failed entry 15 (f015): Read limit exceeded: 7z entry KDF work
error: failed entry 16 (f016): Read limit exceeded: 7z entry KDF work
error: failed entry 17 (f017): Read limit exceeded: 7z entry KDF work
error: failed entry 18 (f018): Read limit exceeded: 7z entry KDF work
error: failed entry 19 (f019): Read limit exceeded: 7z entry KDF work
error: failed entry 20 (f020): Read limit exceeded: 7z entry KDF work
error: failed entry 21 (f021): Read limit exceeded: 7z entry KDF work
error: failed entry 22 (f022): Read limit exceeded: 7z entry KDF work
error: failed entry 23 (f023): Read limit exceeded: 7z entry KDF work
error: failed entry 24 (f024): Read limit exceeded: 7z entry KDF work
error: failed entry 25 (f025): Read limit exceeded: 7z entry KDF work
error: failed entry 26 (f026): Read limit exceeded: 7z entry KDF work
error: failed entry 27 (f027): Read limit exceeded: 7z entry KDF work
error: failed entry 28 (f028): Read limit exceeded: 7z entry KDF work
error: failed entry 29 (f029): Read limit exceeded: 7z entry KDF work
error: failed entry 30 (f030): Read limit exceeded: 7z entry KDF work
error: failed entry 31 (f031): Read limit exceeded: 7z entry KDF work
error: 28 archive entries failed
0	16	f000
1	16	f001
2	16	f002
3	16	f003
4	ERROR	failed entry 4: Read limit exceeded: 7z entry KDF work	f004
5	ERROR	failed entry 5: Read limit exceeded: 7z entry KDF work	f005
6	ERROR	failed entry 6: Read limit exceeded: 7z entry KDF work	f006
7	ERROR	failed entry 7: Read limit exceeded: 7z entry KDF work	f007
8	ERROR	failed entry 8: Read limit exceeded: 7z entry KDF work	f008
9	ERROR	failed entry 9: Read limit exceeded: 7z entry KDF work	f009
10	ERROR	failed entry 10: Read limit exceeded: 7z entry KDF work	f010
11	ERROR	failed entry 11: Read limit exceeded: 7z entry KDF work	f011
12	ERROR	failed entry 12: Read limit exceeded: 7z entry KDF work	f012
13	ERROR	failed entry 13: Read limit exceeded: 7z entry KDF work	f013
14	ERROR	failed entry 14: Read limit exceeded: 7z entry KDF work	f014
15	ERROR	failed entry 15: Read limit exceeded: 7z entry KDF work	f015
16	ERROR	failed entry 16: Read limit exceeded: 7z entry KDF work	f016
17	ERROR	failed entry 17: Read limit exceeded: 7z entry KDF work	f017
18	ERROR	failed entry 18: Read limit exceeded: 7z entry KDF work	f018
19	ERROR	failed entry 19: Read limit exceeded: 7z entry KDF work	f019
20	ERROR	failed entry 20: Read limit exceeded: 7z entry KDF work	f020
21	ERROR	failed entry 21: Read limit exceeded: 7z entry KDF work	f021
22	ERROR	failed entry 22: Read limit exceeded: 7z entry KDF work	f022
23	ERROR	failed entry 23: Read limit exceeded: 7z entry KDF work	f023
24	ERROR	failed entry 24: Read limit exceeded: 7z entry KDF work	f024
25	ERROR	failed entry 25: Read limit exceeded: 7z entry KDF work	f025
26	ERROR	failed entry 26: Read limit exceeded: 7z entry KDF work	f026
27	ERROR	failed entry 27: Read limit exceeded: 7z entry KDF work	f027
28	ERROR	failed entry 28: Read limit exceeded: 7z entry KDF work	f028
29	ERROR	failed entry 29: Read limit exceeded: 7z entry KDF work	f029
30	ERROR	failed entry 30: Read limit exceeded: 7z entry KDF work	f030
31	ERROR	failed entry 31: Read limit exceeded: 7z entry KDF work	f031
partial	4	64	
real 1.71
user 1.69
sys 0.01
```

#### StuffIt X 4,032 bytes / before

```sh
/usr/bin/time -p .build/kdf-defaults/kaito-before list .build/kdf-defaults/t4032.sitx -p x
```

```text
error: The archive is truncated
real 1.62
user 1.60
sys 0.00
```

#### StuffIt X 4,032 bytes / after

```sh
/usr/bin/time -p .build/kdf-defaults/kaito-after list .build/kdf-defaults/t4032.sitx -p x
```

```text
error: The archive is truncated
real 1.60
user 1.59
sys 0.00
```

#### StuffIt X 4,033 bytes / before

```sh
/usr/bin/time -p .build/kdf-defaults/kaito-before list .build/kdf-defaults/t4033.sitx -p x
```

```text
error: The archive is truncated
real 1.64
user 1.63
sys 0.00
```

#### StuffIt X 4,033 bytes / after

```sh
/usr/bin/time -p .build/kdf-defaults/kaito-after list .build/kdf-defaults/t4033.sitx -p x
```

```text
error: Read limit exceeded: StuffIt X KDF work
real 0.00
user 0.00
sys 0.00
```

#### StuffIt X 4,096 bytes / before

```sh
/usr/bin/time -p .build/kdf-defaults/kaito-before list .build/kdf-defaults/t4096.sitx -p x
```

```text
error: The archive is truncated
real 1.65
user 1.63
sys 0.00
```

#### StuffIt X 4,096 bytes / after

```sh
/usr/bin/time -p .build/kdf-defaults/kaito-after list .build/kdf-defaults/t4096.sitx -p x
```

```text
error: Read limit exceeded: StuffIt X KDF work
real 0.00
user 0.00
sys 0.00
```

#### StuffIt X 8,192 bytes / before

```sh
/usr/bin/time -p .build/kdf-defaults/kaito-before list .build/kdf-defaults/t8192.sitx -p x
```

```text
error: The archive is truncated
real 6.58
user 6.54
sys 0.02
```

#### StuffIt X 8,192 bytes / after

```sh
/usr/bin/time -p .build/kdf-defaults/kaito-after list .build/kdf-defaults/t8192.sitx -p x
```

```text
error: Read limit exceeded: StuffIt X KDF work
real 0.00
user 0.00
sys 0.00
```

### 今回更新した9ファイル

- [CHANGELOG.md](../../CHANGELOG.md)
- [Documentation/design.md](../../Documentation/design.md)
- [Documentation/embedding.md](../../Documentation/embedding.md)
- [Documentation/verification/2026-10-26-audit-kdf-fixes.md](../../Documentation/verification/2026-10-26-audit-kdf-fixes.md)
- [README.md](../../README.md)
- [Sources/KaitoKit/Core/ReadLimits.swift](../../Sources/KaitoKit/Core/ReadLimits.swift)
- [Tests/KaitoKitTests/Core/ReaderOptionsTests.swift](../../Tests/KaitoKitTests/Core/ReaderOptionsTests.swift)
- [Tests/KaitoKitTests/SevenZip/SevenZipEntryKDFTests.swift](../../Tests/KaitoKitTests/SevenZip/SevenZipEntryKDFTests.swift)
- [Tests/KaitoKitTests/StuffIt/StuffItXKDFWorkTests.swift](../../Tests/KaitoKitTests/StuffIt/StuffItXKDFWorkTests.swift)

## 変更ファイル

編集前 SHA-256 との比較による一覧（31 files）。`.build` の計測物は含めない。

- [CHANGELOG.md](../../CHANGELOG.md)
- [Documentation/design.md](../../Documentation/design.md)
- [Documentation/embedding.md](../../Documentation/embedding.md)
- [Documentation/verification/2026-10-26-audit-kdf-fixes.md](../../Documentation/verification/2026-10-26-audit-kdf-fixes.md)
- [Documentation/verification/README.md](../../Documentation/verification/README.md)
- [README.md](../../README.md)
- [Sources/KaitoKit/Core/ConstantTime.swift](../../Sources/KaitoKit/Core/ConstantTime.swift)
- [Sources/KaitoKit/Core/KDFWorkBudget.swift](../../Sources/KaitoKit/Core/KDFWorkBudget.swift)
- [Sources/KaitoKit/Core/ReadLimits.swift](../../Sources/KaitoKit/Core/ReadLimits.swift)
- [Sources/KaitoKit/Formats/SevenZip/SevenZipAES.swift](../../Sources/KaitoKit/Formats/SevenZip/SevenZipAES.swift)
- [Sources/KaitoKit/Formats/SevenZip/SevenZipFolderPipeline.swift](../../Sources/KaitoKit/Formats/SevenZip/SevenZipFolderPipeline.swift)
- [Sources/KaitoKit/Formats/SevenZip/SevenZipHeaderDecoder.swift](../../Sources/KaitoKit/Formats/SevenZip/SevenZipHeaderDecoder.swift)
- [Sources/KaitoKit/Formats/SevenZip/SevenZipReader.swift](../../Sources/KaitoKit/Formats/SevenZip/SevenZipReader.swift)
- [Sources/KaitoKit/Formats/StuffIt/StuffItCrypto.swift](../../Sources/KaitoKit/Formats/StuffIt/StuffItCrypto.swift)
- [Sources/KaitoKit/Formats/StuffItX/StuffItXCrypto.swift](../../Sources/KaitoKit/Formats/StuffItX/StuffItXCrypto.swift)
- [Sources/KaitoKit/Formats/StuffItX/StuffItXReader.swift](../../Sources/KaitoKit/Formats/StuffItX/StuffItXReader.swift)
- [Sources/KaitoKit/Formats/StuffItX/StuffItXStreamCoordinator.swift](../../Sources/KaitoKit/Formats/StuffItX/StuffItXStreamCoordinator.swift)
- [Tests/Fixtures/NOTICE](../../Tests/Fixtures/NOTICE)
- [Tests/Fixtures/sevenzip-kdf/README.md](../../Tests/Fixtures/sevenzip-kdf/README.md)
- [Tests/Fixtures/sevenzip-kdf/distinct.7z.b64](../../Tests/Fixtures/sevenzip-kdf/distinct.7z.b64)
- [Tests/Fixtures/sevenzip-kdf/generate.py](../../Tests/Fixtures/sevenzip-kdf/generate.py)
- [Tests/Fixtures/sevenzip-kdf/manifest.json](../../Tests/Fixtures/sevenzip-kdf/manifest.json)
- [Tests/Fixtures/sevenzip-kdf/shared.7z.b64](../../Tests/Fixtures/sevenzip-kdf/shared.7z.b64)
- [Tests/Fixtures/stuffitx-kdf/README.md](../../Tests/Fixtures/stuffitx-kdf/README.md)
- [Tests/Fixtures/stuffitx-kdf/catalog65536.sitx.b64](../../Tests/Fixtures/stuffitx-kdf/catalog65536.sitx.b64)
- [Tests/Fixtures/stuffitx-kdf/generate.py](../../Tests/Fixtures/stuffitx-kdf/generate.py)
- [Tests/Fixtures/stuffitx-kdf/manifest.json](../../Tests/Fixtures/stuffitx-kdf/manifest.json)
- [Tests/KaitoKitTests/Core/ReaderOptionsTests.swift](../../Tests/KaitoKitTests/Core/ReaderOptionsTests.swift)
- [Tests/KaitoKitTests/SevenZip/SevenZipEntryKDFTests.swift](../../Tests/KaitoKitTests/SevenZip/SevenZipEntryKDFTests.swift)
- [Tests/KaitoKitTests/StuffIt/StuffItSlice2CryptoTests.swift](../../Tests/KaitoKitTests/StuffIt/StuffItSlice2CryptoTests.swift)
- [Tests/KaitoKitTests/StuffIt/StuffItXKDFWorkTests.swift](../../Tests/KaitoKitTests/StuffIt/StuffItXKDFWorkTests.swift)
