# 多言語ファイル名エンコーディング判定の変更前測定

bd `cooViewer-6lrc.1`、Task A 訂正版。取得日・測定日: 2026-09-14。

基準は main / HEAD `854af2b16aef9e2098083652296fa985d13701f1` の現行検出器。
`EncodingDetector.swift` の SHA-256 は `6a2e069e99ce62c4d39c37131571661b505d588ef1664a1f4792b534771097af` で不変。
既存テストの期待値も変更していない。CLDR 表は判定器には接続せず、測定用 CLI は既存の判定・名前解決経路を使う。

all の単名完全一致率は **kaito(ja) 18.49%、kaito(none) 18.56%、kaito(zh) 18.56%、udet 45.67%**。
eval は **kaito(ja) 18.77%、kaito(none) 18.87%、kaito(zh) 18.87%、udet 45.97%**。
次の判定器実装 task では以下の all / eval と同じ入力を使って変更前後を比較する。

## 入力と再現方法

入力は支給された `inbox/cldr/`、18言語の `inbox/name-corpus/raw/`、`inbox/bench/udet`。
外部通信と UniversalDetector / XADMaster / The Unarchiver の実装ソース参照は行っていない。

CLDR の main / auxiliary は大小文字を含む scalar 集合を昇順の閉区間 `[lo, hi, ...]` に圧縮した。
19言語の展開結果は旧表と完全一致し、ko main は `[0xAC00, 0xD7A3]` の1範囲。
`LanguageExemplars.contains(_:language:kind:)` は区間を二分探索し、未知の言語は false を返す。
生成ファイルは **214,673 → 160,303 bytes**（54,370 bytes、25.33% 減）。
[NOTICE](../../NOTICE) はバイト不変（SHA-256 `190581b989dbc2447a50ec33e040dbfa05631edb1cca329a1b3b2594bc3b8f0c`）。

seed の既定は `20260914`。記事名を strip / NFC に揃えて対象文字種で選び、重複除去・ソートする。
元記事名を残して30%の装飾版と、各言語200件の短名候補を追加する。ISO-2022-JP は7 bitで全件が ASCII 除外になるため候補から削除した。
ベトナム語の CP1258 で表現不能な前合成文字は、NFD から形状記号（U+0302 / U+0306 / U+031B）だけを基底と NFC 再合成し、
声調（U+0300 / U+0301 / U+0303 / U+0309 / U+0323）を結合文字のまま直後に置く。変換後の scalar 列を正解 text とする。
例: ế → U+00EA U+0301、ệ → U+00EA U+0323、ờ → U+01A1 U+0300。すでに CP1258 で表現できる文字は保持する。

巻数の装飾は ja / zh-* のみ `第NN巻`。vi は `Tập NN`、th は `เล่ม NN`、uk / ru は `Том NN`、
el は `Τόμος NN`、fr は `Tome NN`、de は `Band NN`、その他は `Vol.NN` を使う。

`--split all|tune|eval`（既定 all）は `SHA-256(NFC(strip(元記事名))).digest()[0] < 179` を tune、それ以外を eval とする。
装飾版・短名は元記事の split を継承し、装飾に含める別の記事名も同じ split から選ぶ。短名の出典が複数ならソート順で最初の元記事を選ぶ。
名前生成と書庫生成の乱数を分離し、all の生成後に split で選択する。tune と eval は行IDが重ならず、その和集合は all の全行とバイト一致した。
同じ短い文字列が別の元記事から現れる可能性があるため、文字列や bytes の完全な非重複を保証する分割ではない。
200短名は分割前の各言語の件数であり、各 split の件数と全 split の統計は schema_version 2 の summary.json に残す。

表現不能、全 ASCII bytes、厳密 UTF-8 bytes は除外する。Big5-HKSCS は CP950 で表現できない名前に限定。
書庫は同じ言語・encoding の重複しない bytes を k = 1 / 2 / 3 / 5 / 10 / 30 / 100 件選び、組合せごとに最大100 group。
各組合せの20%に ASCII 名を1〜3件追加する。k は追加前の非 ASCII 名数。書庫間では同じ名前を再利用する。

## 指標

主指標は復号結果と正解 text の **Unicode scalar 列の完全一致**。正準等価でも scalar が異なれば不一致。
単名は名前単位、書庫は ASCII 名を含む全構成員が一致した group 単位で採点する。書庫で復号できない名前は既存の単名解決へ戻す。

最初に `--decode <truth_iana>` で CF の厳密復号を照合する。FAIL / MISMATCH は codec-mismatch として全4方式の共通分母から除外。
書庫は該当 bytes を一つでも含む group 全体を除外する。同一 bytes の複数正解表記に不一致行があれば同じ扱いとする。

kaito は `--language ja` / `--no-language` / `--language zh` の3通り。`--from-windows` は指定しない。
udet は名前ごと、書庫は空行区切りで累積し、返却 MIME に対応する Python codec で厳密復号する。
Shift_JIS→CP932、EUC-KR→CP949、GB2312→GB18030、Big5→CP950、TIS-620→CP874 等の対応を使い、`(nil)` は windows-1252 とする。

encoding 名の一致率は別名を揃えた副次指標。混同対は codec-mismatch を除いた分母内で、正しい検出も含めた検出名上位3件を示す。
kaito の IANA 名と udet の MIME 表記はそのまま集計し、同数なら名前順。encoding 名が異なっても正しく復号できる場合がある。
`--baseline <report.json>` は言語別の今回 − 基準の差を percentage points で出す。基準にない policy や分母0は —。入力ハッシュが異なる場合はその旨も表示する。

詳細な言語×encoding、非 ASCII scalar 数（1 / 2–3 / 4–7 / 8+）、言語×encoding×k、混同対、名前単位正解率、fallback 数は
`.build/name-corpus/`（all）と `.build/name-corpus-eval/` の report.md / report.json に保存。標準出力・標準エラーは各 runs/ に残す。
実コーパスと生成集計表は git 管理外。実書庫や独立した無作為サンプルにおける利用者体験を直接表す測定ではない。

## コーパスの規模

| split | 対象記事名 | 装飾候補 | 短名候補 | 符号化後の行数 | 書庫 | ASCII 混在書庫 | 構成員 / うち ASCII |
|---|---:|---:|---:|---:|---:|---:|---:|
| all | 18049 | 5415 | 3600 | 58348 | 34300 | 6860 | 753570 / 13670 |
| eval | 5438 | 1624 | 1154 | 17771 | 34300 | 6860 | 753641 / 13741 |

| 言語 | raw 行数 | all 対象記事名 | eval 対象記事名 | all 名前行数 | eval 名前行数 |
|---|---:|---:|---:|---:|---:|
| ja | 2499 | 2376 | 736 | 6553 | 2010 |
| zh-cn | 2481 | 2427 | 752 | 3345 | 1041 |
| zh-tw | 2481 | 2403 | 714 | 2344 | 703 |
| ko | 536 | 420 | 118 | 736 | 211 |
| vi | 2500 | 562 | 167 | 805 | 232 |
| th | 682 | 581 | 172 | 940 | 287 |
| uk | 868 | 598 | 174 | 4211 | 1242 |
| ru | 817 | 627 | 194 | 4907 | 1500 |
| es | 2499 | 689 | 216 | 4003 | 1254 |
| pt | 2499 | 720 | 209 | 4233 | 1232 |
| fr | 2498 | 682 | 204 | 3918 | 1110 |
| de | 2500 | 472 | 137 | 2881 | 927 |
| it | 2500 | 267 | 95 | 1686 | 674 |
| pl | 2500 | 899 | 269 | 3787 | 1184 |
| cs | 2500 | 1423 | 404 | 5940 | 1732 |
| hu | 2500 | 1384 | 402 | 5731 | 1692 |
| el | 738 | 581 | 195 | 954 | 328 |
| tr | 2500 | 938 | 280 | 1374 | 412 |

ベトナム語は all で **230 → 805行**。変換後の text を使った行は578件、eval は232行（変換171件）。
ISO-2022-JP の到達不能な0行カテゴリを削除し、言語別の巻数表記によって日本語の巻数語による除外を避けた。
入力の規模・表記・分割・派生名の乱数系列が変わっているため、旧Task Aとの率の差は検出器の改善を示さない。

## codec-mismatch

| split | 単名の行数 | MISMATCH | FAIL | 共通分母 | 書庫除外 group | 書庫の共通分母 |
|---|---:|---:|---:|---:|---:|---:|
| all | 58348 | 49 | 14 | 58285 | 427 | 33873 |
| eval | 17771 | 29 | 4 | 17738 | 591 | 33709 |

| split | 言語 | truth_iana | 行数 | codec-mismatch |
|---|---|---|---:|---:|
| all | ja | cp932 | 3274 | 10 |
| all | ja | euc-jp | 3279 | 15 |
| all | zh-tw | big5-hkscs | 418 | 38 |
| eval | ja | cp932 | 1005 | 7 |
| eval | ja | euc-jp | 1005 | 5 |
| eval | zh-tw | big5-hkscs | 139 | 21 |

代表例（id / hex / text / decoded は各 report.json に記録）:

- CP932: `Echo〜優しい声〜` の `81 60` は CF で `～`（U+FF5E）になり、正解の `〜`（U+301C）と一致しない。
- EUC-JP: `Déjà vu (斉藤和義の曲)` は `8F` を含む列を CF で厳密復号できず FAIL。
- Big5-HKSCS: `丹尼尔·阿尔基布吉` の `A1 50` は CF で U+FF0E と U+F87E の列になり、正解の U+00B7 と一致しない。

## 単名の完全一致率

### all

| lang | 行数 | codec-mismatch | 分母 | kaito(ja) | kaito(none) | kaito(zh) | udet |
|---|---|---|---|---|---|---|---|
| ja | 6553 | 25 | 6528 | 99.79% | 99.80% | 99.80% | 65.99% |
| zh-cn | 3345 | 0 | 3345 | 0.00% | 0.00% | 0.00% | 14.92% |
| zh-tw | 2344 | 38 | 2306 | 0.00% | 0.00% | 0.00% | 11.01% |
| ko | 736 | 0 | 736 | 0.00% | 0.00% | 0.00% | 52.04% |
| vi | 805 | 0 | 805 | 8.82% | 8.82% | 8.82% | 24.35% |
| th | 940 | 0 | 940 | 0.00% | 0.00% | 0.00% | 0.00% |
| uk | 4211 | 0 | 4211 | 0.00% | 0.00% | 0.00% | 59.13% |
| ru | 4907 | 0 | 4907 | 0.00% | 0.00% | 0.00% | 75.61% |
| es | 4003 | 0 | 4003 | 8.47% | 8.52% | 8.52% | 49.74% |
| pt | 4233 | 0 | 4233 | 9.47% | 9.52% | 9.52% | 49.94% |
| fr | 3918 | 0 | 3918 | 12.38% | 12.58% | 12.58% | 49.97% |
| de | 2881 | 0 | 2881 | 18.60% | 18.85% | 18.85% | 47.52% |
| it | 1686 | 0 | 1686 | 21.06% | 21.06% | 21.06% | 49.53% |
| pl | 3787 | 0 | 3787 | 3.99% | 4.04% | 4.04% | 16.93% |
| cs | 5940 | 0 | 5940 | 17.14% | 17.44% | 17.44% | 31.92% |
| hu | 5731 | 0 | 5731 | 11.69% | 11.73% | 11.73% | 47.71% |
| el | 954 | 0 | 954 | 0.00% | 0.00% | 0.00% | 76.94% |
| tr | 1374 | 0 | 1374 | 17.32% | 17.32% | 17.32% | 36.83% |
| 全体 | 58348 | 63 | 58285 | 18.49% | 18.56% | 18.56% | 45.67% |

### eval

| lang | 行数 | codec-mismatch | 分母 | kaito(ja) | kaito(none) | kaito(zh) | udet |
|---|---|---|---|---|---|---|---|
| ja | 2010 | 12 | 1998 | 99.50% | 99.65% | 99.65% | 64.01% |
| zh-cn | 1041 | 0 | 1041 | 0.00% | 0.00% | 0.00% | 16.81% |
| zh-tw | 703 | 21 | 682 | 0.00% | 0.00% | 0.00% | 12.02% |
| ko | 211 | 0 | 211 | 0.00% | 0.00% | 0.00% | 54.98% |
| vi | 232 | 0 | 232 | 8.19% | 8.19% | 8.19% | 21.12% |
| th | 287 | 0 | 287 | 0.00% | 0.00% | 0.00% | 0.00% |
| uk | 1242 | 0 | 1242 | 0.00% | 0.00% | 0.00% | 60.31% |
| ru | 1500 | 0 | 1500 | 0.00% | 0.00% | 0.00% | 76.40% |
| es | 1254 | 0 | 1254 | 8.93% | 9.09% | 9.09% | 49.68% |
| pt | 1232 | 0 | 1232 | 9.66% | 9.82% | 9.82% | 49.84% |
| fr | 1110 | 0 | 1110 | 11.17% | 11.35% | 11.35% | 50.09% |
| de | 927 | 0 | 927 | 20.93% | 21.14% | 21.14% | 47.79% |
| it | 674 | 0 | 674 | 21.96% | 21.96% | 21.96% | 48.96% |
| pl | 1184 | 0 | 1184 | 5.24% | 5.24% | 5.24% | 16.98% |
| cs | 1732 | 0 | 1732 | 16.97% | 17.38% | 17.38% | 32.74% |
| hu | 1692 | 0 | 1692 | 11.94% | 12.00% | 12.00% | 47.93% |
| el | 328 | 0 | 328 | 0.00% | 0.00% | 0.00% | 77.44% |
| tr | 412 | 0 | 412 | 16.26% | 16.26% | 16.26% | 38.59% |
| 全体 | 17771 | 33 | 17738 | 18.77% | 18.87% | 18.87% | 45.97% |


## 書庫の完全一致率

### all

| lang | 行数 | codec-mismatch | 分母 | kaito(ja) | kaito(none) | kaito(zh) | udet |
|---|---|---|---|---|---|---|---|
| ja | 1400 | 91 | 1309 | 99.85% | 99.85% | 99.85% | 91.44% |
| zh-cn | 700 | 0 | 700 | 0.00% | 0.00% | 0.00% | 76.86% |
| zh-tw | 1400 | 336 | 1064 | 0.00% | 0.00% | 0.00% | 49.06% |
| ko | 700 | 0 | 700 | 0.00% | 0.00% | 0.00% | 92.57% |
| vi | 700 | 0 | 700 | 1.29% | 1.29% | 1.29% | 4.00% |
| th | 700 | 0 | 700 | 0.00% | 0.00% | 0.00% | 0.00% |
| uk | 3500 | 0 | 3500 | 0.00% | 0.00% | 0.00% | 67.37% |
| ru | 3500 | 0 | 3500 | 0.00% | 0.00% | 0.00% | 87.09% |
| es | 2800 | 0 | 2800 | 1.14% | 1.14% | 1.14% | 45.75% |
| pt | 2800 | 0 | 2800 | 1.11% | 1.11% | 1.11% | 45.11% |
| fr | 2800 | 0 | 2800 | 2.46% | 2.46% | 2.46% | 45.89% |
| de | 2800 | 0 | 2800 | 3.46% | 3.46% | 3.46% | 40.43% |
| it | 2800 | 0 | 2800 | 3.89% | 3.89% | 3.89% | 38.39% |
| pl | 2100 | 0 | 2100 | 0.43% | 0.43% | 0.43% | 3.00% |
| cs | 2100 | 0 | 2100 | 3.10% | 3.10% | 3.10% | 8.14% |
| hu | 2100 | 0 | 2100 | 2.14% | 2.14% | 2.14% | 19.19% |
| el | 700 | 0 | 700 | 0.00% | 0.00% | 0.00% | 57.43% |
| tr | 700 | 0 | 700 | 3.71% | 3.71% | 3.71% | 8.43% |
| 全体 | 34300 | 427 | 33873 | 5.31% | 5.31% | 5.31% | 45.68% |

### eval

| lang | 行数 | codec-mismatch | 分母 | kaito(ja) | kaito(none) | kaito(zh) | udet |
|---|---|---|---|---|---|---|---|
| ja | 1400 | 155 | 1245 | 99.84% | 99.92% | 99.92% | 90.28% |
| zh-cn | 700 | 0 | 700 | 0.00% | 0.00% | 0.00% | 78.14% |
| zh-tw | 1400 | 436 | 964 | 0.00% | 0.00% | 0.00% | 56.12% |
| ko | 700 | 0 | 700 | 0.00% | 0.00% | 0.00% | 90.86% |
| vi | 700 | 0 | 700 | 2.14% | 2.14% | 2.14% | 4.29% |
| th | 700 | 0 | 700 | 0.00% | 0.00% | 0.00% | 0.00% |
| uk | 3500 | 0 | 3500 | 0.00% | 0.00% | 0.00% | 67.00% |
| ru | 3500 | 0 | 3500 | 0.00% | 0.00% | 0.00% | 90.09% |
| es | 2800 | 0 | 2800 | 1.50% | 1.50% | 1.50% | 45.14% |
| pt | 2800 | 0 | 2800 | 1.68% | 1.68% | 1.68% | 44.89% |
| fr | 2800 | 0 | 2800 | 1.86% | 1.86% | 1.86% | 46.29% |
| de | 2800 | 0 | 2800 | 4.07% | 4.14% | 4.14% | 39.71% |
| it | 2800 | 0 | 2800 | 5.11% | 5.11% | 5.11% | 40.50% |
| pl | 2100 | 0 | 2100 | 0.76% | 0.76% | 0.76% | 3.43% |
| cs | 2100 | 0 | 2100 | 3.52% | 3.57% | 3.57% | 8.81% |
| hu | 2100 | 0 | 2100 | 2.29% | 2.29% | 2.29% | 18.38% |
| el | 700 | 0 | 700 | 0.00% | 0.00% | 0.00% | 57.71% |
| tr | 700 | 0 | 700 | 2.00% | 2.00% | 2.00% | 6.29% |
| 全体 | 34300 | 591 | 33709 | 5.36% | 5.38% | 5.38% | 46.07% |

全構成員一致なので、書庫内の名前を個別に数える率より厳しい。分母内の構成員について:

| split | 構成員 | kaito(ja) | kaito(none) | kaito(zh) | udet | kaito fallback (ja / none / zh) |
|---|---:|---:|---:|---:|---:|---:|
| all | 732965 | 13.11% | 13.19% | 13.19% | 57.22% | 284315 / 284329 / 284329 |
| eval | 728516 | 12.83% | 12.92% | 12.92% | 57.83% | 285018 / 285028 / 285028 |

## 混同対の要約

下表は report.json の検出名別件数から注目する対応を数えたもの。指定した検出名の件数 / 対象 truth の共通分母を示す。
この要約の別名比較は CODECS で揃える。詳細 report.md / report.json の上位3件には実際の返却名を残す。

| 検出器 | truth（言語） | 検出名 | all 件数 / 分母 | eval 件数 / 分母 |
|---|---|---|---:|---:|
| udet | CP874（th） | KOI8-R / IBM866 | 565 / 940 | 157 / 287 |
| udet | CP1258（vi） | windows-1252 | 294 / 805 | 75 / 232 |
| udet | KOI8-U（uk） | KOI8-R | 785 / 925 | 229 / 270 |
| udet | CP1251（uk / ru） | x-mac-cyrillic | 348 / 1982 | 88 / 591 |
| udet | MacCyrillic（uk / ru） | windows-1251 | 657 / 1990 | 184 / 592 |
| udet | CP1250 / ISO-8859-2（pl / cs / hu） | windows-1252 | 9829 / 10288 | 2931 / 3067 |
| kaito(ja) | CP949（ko） | euc-jp | 720 / 736 | 207 / 211 |
| kaito(ja) | GB18030（zh-cn） | euc-jp | 1718 / 3345 | 537 / 1041 |

上の件数は単名。書庫の言語×truth×k ごとの上位3件も各 report.md に保存した。
特に KOI8-U と KOI8-R のように共通の文字が多い組合せでは、encoding 名の混同と文字列不一致の件数は一致しない。

## 実行時間と検証

環境: macOS-27.0-arm64-arm-64bit-Mach-O、Apple Swift 6.4（swiftlang-6.4.0.34.1）、Python 3.14.7。
各本測定は1回、all と eval は順に実行。プロセス起動・入出力を含み、検出関数単体の速度ではない。

| 処理 | all 秒 | eval 秒 |
|---|---:|---:|
| CF 正解復号・23 encoding のプロセス合計 | 0.617 | 0.188 |
| names-kaito_ja | 1.526 | 0.487 |
| names-kaito_none | 1.463 | 0.448 |
| names-kaito_zh | 1.518 | 0.489 |
| names-udet | 0.301 | 0.096 |
| archives-kaito_ja | 5.601 | 5.566 |
| archives-kaito_none | 5.437 | 5.332 |
| archives-kaito_zh | 5.765 | 5.748 |
| archives-udet | 3.124 | 2.971 |
| total | 33.149 | 27.654 |

- debug / release build は警告0（2.07秒 / 40.42秒）。
- 全テストは KaitoKit 1,046件（既存の環境依存スキップ45件）と Compat 23件、合計1,069件、失敗0。
  追加は LanguageExemplarsTests の3件と、全23 encoding の IANA 往復を確認する CLI テスト1件。既存期待値は不変。
- 各言語の正例・負例、主/補助集合、未知の言語、全範囲の内外の境界、ko の1範囲を検証。展開した全19言語の集合は旧表と一致。
- `--self-check` は CODECS の全51キーをマップ先の codecs.lookup と照合。CF が実際に返した全23 IANA 名も CODECS に含まれた。
- ベトナム語の全声調の小文字・大文字で、変換後の CP1258 往復と NFC 等価を検証。言語別巻数表記と装飾相手の split も検証。
- all の3生成ファイルは再実行でバイト一致。tune / eval の行IDは非重複で、和集合は all の全行に一致。
- 小規模な通し測定と既知値で、混同対の除外・同数時の順序、--baseline の差の符号と pt 単位、基準にない policy を検証。
- all / eval の4方式の単名正解数を保存出力から別途再集計して一致。混同対の件数と各集計軸の総計も一致。
- `git diff --check` 成功。判定器と NOTICE の SHA-256 は訂正前後で一致。

udet (all): 未対応 MIME 0種類、(nil) は単名0件・書庫0件。
udet (eval): 未対応 MIME 0種類、(nil) は単名0件・書庫0件。

再測定用 SHA-256（各言語の raw 入力ハッシュは summary.json に保存）:

| 対象 | SHA-256 |
|---|---|
| all/names.tsv | `2fb290429ae3649ad87409caa4168322dafe432ada3e7cdb3201bd5d8fc26a48` |
| all/archives.tsv | `09851d6502189dbe6965b0e7222f21d02bc34d5eab49694b93179b9f063e0691` |
| all/summary.json | `ead1cc3614f290a1dfb08921b70e6e8e275fcf7d2682b396b0f8172abf8cd1dc` |
| eval/names.tsv | `474cc4caf74072b728b81446fc3f447d47ef11fd9b85240fecb8c6fa67f90b6d` |
| eval/archives.tsv | `e9cff6e43c0dea13653c037ce1bccd834631b9d8481a05bdbfec8d4ae6b201e3` |
| eval/summary.json | `90e34eecf642b45a2deea63e4fc5afec3dfbc7419691244fffc989c95985610c` |
| kaito release | `31054670173fb33cb99e33ae5f06f286714c75bfb174f07ad377ca70e188b573` |
| udet 黒箱 CLI | `26d1380e3d8790af34e92dd5744ca2d9eca788fc2f6c87e11d627060582d4c10` |

## 実行コマンド

通常環境での手順:

```sh
python3 Tests/Tools/make-exemplars.py
swift build && swift test
swift build -c release --product kaito
python3 Tests/Tools/make-name-corpus.py
python3 Tests/Tools/make-name-corpus.py --split eval --out-dir .build/name-corpus-eval
python3 Tests/Tools/measure-name-detection.py .build/release/kaito --udet inbox/bench/udet
python3 Tests/Tools/measure-name-detection.py .build/release/kaito --udet inbox/bench/udet --corpus .build/name-corpus-eval --out-dir .build/name-corpus-eval
python3 Tests/Tools/measure-name-detection.py --self-check
shasum -a 256 Sources/KaitoKit/Text/EncodingDetector.swift NOTICE
git diff --check
```

任意の保存済みレポートとの差は上の測定コマンドに `--baseline <report.json>` を追加する。
今回の sandbox では前回と同じキャッシュ書込み・dSYM 生成の制約があるため、製品設定を変えずに以下の SwiftPM 引数を使用した。
release の最適化レベルは維持し、外側の sandbox の権限変更は行っていない。

```sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/clang-cache"
swift build --disable-sandbox --cache-path .build/swift-cache --config-path .build/swift-config --security-path .build/swift-security
swift test --disable-sandbox --cache-path .build/swift-cache --config-path .build/swift-config --security-path .build/swift-security
swift build -c release --product kaito -debug-info-format none --disable-sandbox --cache-path .build/swift-cache --config-path .build/swift-config --security-path .build/swift-security
```
