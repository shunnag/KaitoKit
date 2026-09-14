# タイ語の頻出比率規則の修正（bd cooViewer-fl6u）

2026-09-14。基点は `49932d4` / `fix/thai-frequency-rule`、Task B 訂正6。調整は tune のみで行い、選択した定義を固定した後に eval を受け入れ測定した。eval は Task B ですでに観測された集合であり、未観測 holdout ではない。checkout / commit / push は行っていない。

**受け入れ結果: 未達。** tune の比率規則の発火率は7.04%→0.31%になったが、eval の th 単名は77.70%（目標78.05%）、zh-cn(none、非ASCII≥4)は90.85%（目標92.06%）。性能も22秒以下を満たさなかった。対象テストはすべて成功し、全言語の書庫k≥10は訂正6から完全に不変。下記の選択案を残すが、受け入れ済みの修正とは扱わない。evalを見た再選択・再調整はしていない。

## 変更した定義

比率規則専用の頻出集合を、既存の10字 `านรกเอยมลว` に `สทดคง` を加えた15字へ広げた。文字得点の `frequent["th"]` は変更していない。候補表、他言語、prior、API、稀記号・タイ数字・正書法の規則も変更していない。

- run: タイ字母・結合記号の連続区間。数字、句読点、他スクリプトで切る。
- 最小 run: 8 Unicode scalar。
- 分母 L: run 内の Unicode 一般カテゴリ L* の数。結合記号は分母・頻出数の双方に含めない。
- 頻出数 C: 上記15字に含まれる字母の数。
- 減点: `max(0, 0.35 × L − C) × −1.5`。文字平均では割らない。
- 採点上限256 scalar、短周期反復を空白へ置換する既存処理を維持する。
- 15字の不変 Bool 表を一度だけ作り、採点時には既存どおり表引きする。

依頼文の「前置母音を除く現行定義」と実装には差があった。基点の `if p.letter` は前置母音 U+0E40–U+0E44（カテゴリ Lo）も分母に含め、`เ` は旧頻出集合にも含む。本変更はその実装をそのまま維持する。前置母音を除外する変更を同時には入れていない。

集合は依頼で指定されたリストの先頭15字。追加5字も含め、[2013年のタイ語記事本文を独立集計した公開頻度表](https://linguistics.stackexchange.com/questions/4317/looking-for-thai-letter-frequency-resource)で頻出する文字である。今回の tune/eval から字母ランキングや名前辞書を作っていない。結合記号を含む順位と字母のみの順位は異なるため、「全scalarで厳密に上位15個」という意味ではない。

## tune の比較

10字 / 15字 / 指定20字（`นรากเอยมลวสทดคงหตปัี`）× 最小8 / 12 scalar × 35 / 30 / 25% の18通り、および比率規則撤去を比較した。20字集合の `ัี` は結合記号なので、現行の分母定義では頻出数にも加わらない。撤去試行は閾値0にして比率の減点だけを無効化し、稀記号・タイ数字の処理は維持した。

表の単名正解は CF の厳密復号と正解文字列が一致する行だけを分母にする。th は外国語を含め653行すべてを分母にした。比較用に付加した指定CJK例2件はコーパスの分母に含めない。全候補で「学校法人大手前学園」EUC-JP / ja は正解だった。

| 集合 | 最小scalar | 閾値 | th発火 / 653 | th正解 ja / none (653) | ja正解 ja / none (4530) | zh-cn非ASCII≥4 正解 ja / none (1631) | 同 CP874誤判定 none | 指定GB18030例 none |
|---|---|---|---|---|---|---|---|---|
| 10 | 8 | 35% | 46 (7.04%) | 539 / 559 | 4526 / 4371 | 847 / 1475 | 32 | gb18030 |
| 10 | 8 | 30% | 28 (4.29%) | 542 / 562 | 4526 / 4358 | 847 / 1475 | 32 | gb18030 |
| 10 | 8 | 25% | 7 (1.07%) | 543 / 563 | 4526 / 4345 | 845 / 1462 | 47 | cp874 |
| 10 | 12 | 35% | 23 (3.52%) | 542 / 562 | 4526 / 4348 | 844 / 1445 | 70 | cp874 |
| 10 | 12 | 30% | 10 (1.53%) | 542 / 562 | 4526 / 4343 | 844 / 1445 | 70 | cp874 |
| 10 | 12 | 25% | 2 (0.31%) | 543 / 563 | 4526 / 4339 | 844 / 1442 | 73 | cp874 |
| 15 | 8 | 35% | 2 (0.31%) | 543 / 563 | 4526 / 4351 | 845 / 1465 | 44 | gb18030 |
| 15 | 8 | 30% | 2 (0.31%) | 543 / 563 | 4526 / 4346 | 845 / 1464 | 48 | gb18030 |
| 15 | 8 | 25% | 0 (0.00%) | 543 / 563 | 4526 / 4342 | 844 / 1451 | 63 | cp874 |
| 15 | 12 | 35% | 0 (0.00%) | 543 / 563 | 4526 / 4340 | 844 / 1442 | 73 | cp874 |
| 15 | 12 | 30% | 0 (0.00%) | 543 / 563 | 4526 / 4338 | 844 / 1441 | 75 | cp874 |
| 15 | 12 | 25% | 0 (0.00%) | 543 / 563 | 4526 / 4338 | 843 / 1437 | 79 | cp874 |
| 20 | 8 | 35% | 0 (0.00%) | 543 / 563 | 4526 / 4345 | 844 / 1455 | 55 | gb18030 |
| 20 | 8 | 30% | 0 (0.00%) | 543 / 563 | 4526 / 4343 | 844 / 1452 | 60 | gb18030 |
| 20 | 8 | 25% | 0 (0.00%) | 543 / 563 | 4526 / 4340 | 843 / 1445 | 69 | cp874 |
| 20 | 12 | 35% | 0 (0.00%) | 543 / 563 | 4526 / 4339 | 844 / 1440 | 75 | cp874 |
| 20 | 12 | 30% | 0 (0.00%) | 543 / 563 | 4526 / 4337 | 844 / 1438 | 78 | cp874 |
| 20 | 12 | 25% | 0 (0.00%) | 543 / 563 | 4526 / 4336 | 843 / 1435 | 81 | cp874 |
| 撤去 | 8 | 0% | 0 (0.00%) | 543 / 563 | 4526 / 4335 | 843 / 1434 | 82 | cp874 |

**選択: 15字 / 8 scalar / 35%。** 発火率は2/653 = 0.3063%で1%以下。条件を満たす候補中で CJK→CP874 の誤判定が最も少なく、指定 GB18030 / none 例と既存の規則境界テストをともに維持する。10字の25%だけでは7/653 = 1.072%で未達。最小12 scalarへの変更は8 scalarの交差復号を対象外にする。20字化やさらなる閾値低下は、thの判定を追加改善せずCJKの抑止を弱めた。

比率規則撤去と比べ、選択後は tune の zh-cn(none、非ASCII≥4)の CP874 誤判定を82→44行、正解を1434→1465行へ改善する。一方、訂正6の32行 / 1475正解からは後退する。抑止は残るが、訂正6と全件同じ抑止力を保ったという意味ではない。日本語単名は ja で4526/4530のまま、noneでは4371→4351。th単名は ja 539→543、none 559→563である。

## 採用規則の全発火行

採点範囲256 scalarと全文の診断は、th全653行で同じ発火規則・位置になった。以下の2行が比率規則の全発火行で、どちらも同じ固有名を含む。別々のコーパス行として数え、分母から除外しない。

| id | 正解名 | 発火run / scalar位置（0始まり） | 字母 C/L | 減点 | 分類 | 最終 ja / none |
|---|---|---|---|---|---|---|
| n0013939 | ซุปเปอร์แบงค์ ม.รัตนบัณฑิต | รัตนบัณฑิต / 16 (U+0E23) | 2/7 | −0.675 | 通常のタイ字母・声調を含む固有名中の分布の外れ値。正書法違反ではなく、残る誤発火 | cp874 / cp874（正解） |
| n0014420 | ซุปเปอร์แบงค์ ม.รัตนบัณฑิต.zip | รัตนบัณฑิต / 16 (U+0E23) | 2/7 | −0.675 | 上記名前の拡張子付き派生行。同じ分布の誤発火 | cp874 / cp874（正解） |

訂正6の46行の一覧・分類は[前回記録の「新規則の発火率」](2026-09-14-name-encoding-multilingual.md#新規則の発火率tuneのth全653行)を参照。今回の比率規則の発火行はその部分集合であり、新たな発火はない。稀記号の9行は別規則で、今回の変更対象ではない。

## 単体テストとビルド

`testThaiCommonRatioPreservesOrdinaryNames` に7例を追加した: `กรมสรรพากร`、`สำนักงานคณะกรรมการ`、`กระทรวงศึกษาธิการ`、`มหาวิทยาลัยเชียงใหม่`、`คณะสัตวแพทยศาสตร์`、`ฟุตบอลหญิงชิงแชมป์คอนคาแคฟ`、`จังหวัดพัทลุง`。すべて分布の減点0・違反イベントなし。後半3例は旧比率規則の誤発火も検出する。

既存の「学校法人大手前学園」EUC-JP / ja、「警察广场1号」GB18030 / none、「กรมสรรพากร」CP874 / ja の期待値と、run境界・減点値・稀記号・数字のテストは変更していない。

`swift build` debug/releaseは警告0。指定filterは KaitoKit の5対象クラス60件と、名前がfilterに一致するCompatの1件を実行し、計61件成功した。全体テストは依頼どおり orchestrator の担当であり、この作業では実行していない。

## eval の受け入れ値と差分

既存の測定器を無変更で実行した。割合の比較はTask Bと同じ小数点以下2桁表示。以下の「ja」「none」は判定器のlikelyLanguageであり、入力の言語ではない。

| 指標 | 訂正6 ja | 選択後 ja | 訂正6 none | 選択後 none |
|---|---|---|---|---|
| th 単名 | 222/287 (77.35%) | 223/287 (77.70%) | 231/287 (80.49%) | 232/287 (80.84%) |
| th 書庫 全k | 667/700 (95.29%) | 668/700 (95.43%) | 671/700 (95.86%) | 672/700 (96.00%) |
| th 書庫 k≥10 | 300/300 (100.00%) | 300/300 (100.00%) | 300/300 (100.00%) | 300/300 (100.00%) |
| ja 単名 | 1988/1998 (99.50%) | 1988/1998 (99.50%) | 1914/1998 (95.80%) | 1911/1998 (95.65%) |
| ja 書庫 全k | 1243/1245 (99.84%) | 1243/1245 (99.84%) | 1224/1245 (98.31%) | 1224/1245 (98.31%) |
| ja 書庫 k≥10 | 455/455 (100.00%) | 455/455 (100.00%) | 455/455 (100.00%) | 455/455 (100.00%) |
| zh-cn 単名 | 452/1041 (43.42%) | 448/1041 (43.04%) | 859/1041 (82.52%) | 850/1041 (81.65%) |
| zh-cn 書庫 全k | 600/700 (85.71%) | 600/700 (85.71%) | 683/700 (97.57%) | 683/700 (97.57%) |
| zh-cn 書庫 k≥10 | 300/300 (100.00%) | 300/300 (100.00%) | 300/300 (100.00%) | 300/300 (100.00%) |
| ko 単名 | 108/211 (51.18%) | 108/211 (51.18%) | 163/211 (77.25%) | 163/211 (77.25%) |
| ko 書庫 全k | 640/700 (91.43%) | 640/700 (91.43%) | 675/700 (96.43%) | 675/700 (96.43%) |
| ko 書庫 k≥10 | 300/300 (100.00%) | 300/300 (100.00%) | 300/300 (100.00%) | 300/300 (100.00%) |
| zh-cn 単名 非ASCII≥4 | 390/743 (52.49%) | 386/743 (51.95%) | 684/743 (92.06%) | 675/743 (90.85%) |

受け入れ条件ごとの判定:

| 条件 | 結果 |
|---|---|
| tune th 比率規則発火≤1% | 合格: 2/653 = 0.31%、全行を前掲 |
| eval th単名≥78.05% | **未達**: 223/287 = 77.70%。目標224正解に1行不足 |
| eval th / ko書庫k≥10 100% | 合格: 両policyとも各300/300 |
| eval ja単名≥99.50% / 書庫≥99.84% | 合格: ja policyで1988/1998 / 1243/1245、訂正6から不変 |
| eval zh-cn(none、非ASCII≥4)≥92.06% | **未達**: 675/743 = 90.85%、訂正6から9行 / 1.21pt低下 |
| 他言語の書庫k≥10 | 合格: 18言語・全符号化・k=10/30/100・全4detectorのreport行が前後で完全一致 |
| build / 対象test / 既存期待値 / diff | 合格: 警告0、61件成功、既存期待値不変、`git diff --check`成功 |
| 性能≤22秒 | **未達**: eval測定24.394秒、直接再測定22.269秒（旧版22.348秒） |

全言語の正解数の増減（割合ではなく行数）:

| lang | 単名 Δ ja / none | 書庫 全k Δ ja / none | 書庫 k≥10 Δ ja / none |
|---|---|---|---|
| cs | +0 / +0 | +0 / +0 | +0 / +0 |
| de | +0 / +0 | +0 / +0 | +0 / +0 |
| el | +0 / +0 | +0 / +0 | +0 / +0 |
| es | +0 / +0 | +0 / +0 | +0 / +0 |
| fr | +0 / +0 | +0 / +0 | +0 / +0 |
| hu | +0 / +0 | +0 / +0 | +0 / +0 |
| it | +0 / +0 | +0 / +0 | +0 / +0 |
| ja | +0 / -3 | +0 / +0 | +0 / +0 |
| ko | +0 / +0 | +0 / +0 | +0 / +0 |
| pl | +0 / +0 | +0 / +0 | +0 / +0 |
| pt | +0 / +0 | +0 / +0 | +0 / +0 |
| ru | +0 / +0 | +0 / +0 | +0 / +0 |
| th | +1 / +1 | +1 / +1 | +0 / +0 |
| tr | +0 / +0 | +0 / +0 | +0 / +0 |
| uk | -1 / -1 | +0 / +0 | +0 / +0 |
| vi | +0 / +0 | +0 / +0 | +0 / +0 |
| zh-cn | -4 / -9 | +0 / +0 | +0 / +0 |
| zh-tw | +0 / +0 | +0 / +0 | +0 / +0 |

単名の判定または復号文字列が変わった全行（ja / none）を以下に示す。除外対象のCF不一致行は正解率・この表に含めない。CJKおよびウクライナ語の正→誤は、集合拡張によってCP874の分布減点が弱まった実回帰である。誤→誤も区別して残した。thは通常の名前への過剰減点が弱まって1行回復した。

| policy | id | lang | 正解名 | 変更 | 正誤 |
|---|---|---|---|---|---|
| ja | n0006747 | zh-cn | 丹尼斯·米娜 | euc-jp→cp874 | 誤→誤 |
| ja | n0007207 | zh-cn | 多米尼克·科爾 | gb18030→cp874 | 正→誤 |
| ja | n0007683 | zh-cn | 斯帕陨石坑 | euc-jp→cp874 | 誤→誤 |
| ja | n0007708 | zh-cn | 新疆风毛菊 | euc-jp→cp874 | 誤→誤 |
| ja | n0007860 | zh-cn | 桑康·乍薩 | gb18030→cp874 | 正→誤 |
| ja | n0008244 | zh-cn | 立氏立克次體 | gb18030→cp874 | 正→誤 |
| ja | n0009476 | zh-cn | 立氏立克次體 - 118.jpg | gb18030→cp874 | 正→誤 |
| ja | n0013919 | th | จิโงกุ-โซชิ (พิพิธภัณฑสถานแห่งชาติโตเกียว) | cp949→cp874 | 誤→正 |
| ja | n0017199 | uk | VIRGINIA SLIMS OF HOUSTON 1988, ОДИНОЧНИЙ РОЗРЯД | iso-8859-5→cp874 | 正→誤 |
| none | n0004733 | ja | 大阪市立玉造幼稚園 | euc-jp→cp874 | 正→誤 |
| none | n0004960 | ja | 文化財返還問題 | euc-jp→cp874 | 正→誤 |
| none | n0005203 | ja | 浜松鉄道病院 | euc-jp→cp874 | 正→誤 |
| none | n0005428 | ja | 荒巻三之 | cp949→cp874 | 誤→誤 |
| none | n0006747 | zh-cn | 丹尼斯·米娜 | gb18030→cp874 | 正→誤 |
| none | n0006833 | zh-cn | 伯纳德·金 | gb18030→cp874 | 正→誤 |
| none | n0007044 | zh-cn | 卡蒙 (阿列日省) | gb18030→cp874 | 正→誤 |
| none | n0007207 | zh-cn | 多米尼克·科爾 | gb18030→cp874 | 正→誤 |
| none | n0007708 | zh-cn | 新疆风毛菊 | gb18030→cp874 | 正→誤 |
| none | n0007860 | zh-cn | 桑康·乍薩 | gb18030→cp874 | 正→誤 |
| none | n0008244 | zh-cn | 立氏立克次體 | gb18030→cp874 | 正→誤 |
| none | n0009125 | zh-cn | 卡蒙 (阿列日省) v14 | gb18030→cp874 | 正→誤 |
| none | n0009476 | zh-cn | 立氏立克次體 - 118.jpg | gb18030→cp874 | 正→誤 |
| none | n0013919 | th | จิโงกุ-โซชิ (พิพิธภัณฑสถานแห่งชาติโตเกียว) | cp949→cp874 | 誤→正 |
| none | n0017199 | uk | VIRGINIA SLIMS OF HOUSTON 1988, ОДИНОЧНИЙ РОЗРЯД | iso-8859-5→cp874 | 正→誤 |

書庫の変更はk=1だけ: `g0004994`（th、上記 `n0013919` と同名）が ja / none / zh で cp949→cp874（誤→正）。`g0000733`（ja、「荒巻三之」）はnoneでcp949→cp874（誤→誤）。ほかの書庫に判定の変更はない。k≥10は正解数だけでなく検出符号化の件数・fallback・構成員正解数も不変。udetも全測定値が不変だった。

## 性能

コード固定後の既存測定器による `archives-kaito_ja` はtune **22.774秒**、eval **24.394秒**。上限22秒を超えたため、同じevalの書庫入力で旧版→新版を直列に一度ずつ再測定した。

| 実行 | 秒 | ≤22秒 |
|---|---|---|
| 訂正6旧版・直接再測定 | 22.348 | 未達 |
| 選択後・直接再測定 | 22.269 | 未達 |

この再測定で新版が旧版より遅いという結果は出なかったが、絶対値の性能条件は合格にしない。Task B記録の21.452秒は別実行の値であり、今回の結果に置き換えない。追加の性能調整は行っていない。両再測定のstdoutは、それぞれの保存済みeval `archives-kaito_ja.stdout.tsv` とバイト一致した。

```python
import json, subprocess, time
from pathlib import Path
root = Path('.build/thai-rule')
results = []
for label, binary in [('before', root / 'kaito-before'),
                      ('after', Path('.build/thai-swift/release/kaito'))]:
    with (root / f'perf-{label}.stdout.tsv').open('w') as out, (root / f'perf-{label}.stderr.txt').open('w') as err:
        start = time.perf_counter()
        subprocess.run([str(binary), 'detect-encoding', '--archive', '--language', 'ja',
                        '.build/name-corpus-eval/archives.tsv'], stdout=out, stderr=err, check=True)
        results.append(dict(label=label, seconds=time.perf_counter() - start))
    (root / 'performance.json').write_text(json.dumps(results, indent=2))
```

## 入力と再現手順

作業開始時の `.build/` は空で、依頼文の配置済みコーパスは存在しなかった。tune は既存の `inbox/name-corpus/raw` から無変更の生成器で再生成した。eval は隣接作業の `../kk-encc/.build/task-b-eval` の TSV / summary と、`../scratchpad/enc/m-eval-b` の訂正6 report / runs を作業用ディレクトリへコピーした。eval のTSVのSHA-256はTask B記録と一致した。調整のためのeval再生成・行選別は行っていない。

| ファイル | SHA-256 |
|---|---|
| tune/names.tsv | `0f8e8d9387d11c6dc95c5f392480c7ffd80d0f80b0cbf2d6f5f0279a39fcde10` |
| tune/archives.tsv | `0c7647590a2a6abaed27314dad9726ef0ca08d7651204778ea9f6caf94c32fdf` |
| eval/names.tsv | `474cc4caf74072b728b81446fc3f447d47ef11fd9b85240fecb8c6fa67f90b6d` |
| eval/archives.tsv | `e9cff6e43c0dea13653c037ce1bccd834631b9d8481a05bdbfec8d4ae6b201e3` |
| eval/report.json（訂正6） | `835ae521144c136a135595241ec94ab5719deb82a94c758907529bc3eea4291f` |
| 変更前 NameEncodingScorer.swift | `5c89af869e2de824a17d850bee00b7d1e31bcf8fbf83d4793476236783d4a785` |
| 変更後 NameEncodingScorer.swift | `376a109e9623d6c429a1284ef82776702de341cc39c926cc7a80a0ecce85f119` |
| 検証した release/kaito | `d4c814c11f0013325e26d9ff290ac3c5e80563d0d3709f92ac0c61bae7d04072` |

最初のビルドはmanifest用clang module cacheがホームディレクトリへの書込を拒否されて失敗した。Task Bのsandbox引数に加えて `CLANG_MODULE_CACHE_PATH` を `.build/clang-cache` に設定して再実行し、成功した。製品ソースやPackage.swiftの変更は不要だった。

```sh
mkdir -p .build/thai-rule .build/clang-cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
python3 Tests/Tools/make-name-corpus.py --split tune --out-dir .build/name-corpus-tune

# 変更前に実施。ビルドした実行ファイルを .build/thai-rule/kaito-before に保存。
swift build -c release --product kaito -debug-info-format none --scratch-path .build/thai-swift --disable-sandbox --cache-path .build/swift-cache --config-path .build/swift-config --security-path .build/swift-security
cp .build/thai-swift/release/kaito .build/thai-rule/kaito-before
python3 Tests/Tools/measure-name-detection.py .build/thai-rule/kaito-before --udet inbox/bench/udet --corpus .build/name-corpus-tune --out-dir .build/name-corpus-tune

# 選択した規則の実装後。前後のreport/runsは別ディレクトリへ保存。
swift build --scratch-path .build/thai-swift --disable-sandbox --cache-path .build/swift-cache --config-path .build/swift-config --security-path .build/swift-security
swift test --scratch-path .build/thai-swift --disable-sandbox --cache-path .build/swift-cache --config-path .build/swift-config --security-path .build/swift-security --filter 'NameEncoding|EncodingDetectorCorpus|ArchiveNameEncoding'
swift build -c release --product kaito -debug-info-format none --scratch-path .build/thai-swift --disable-sandbox --cache-path .build/swift-cache --config-path .build/swift-config --security-path .build/swift-security
python3 Tests/Tools/measure-name-detection.py .build/thai-swift/release/kaito --udet inbox/bench/udet --corpus .build/name-corpus-tune --out-dir .build/name-corpus-tune-after --baseline .build/name-corpus-tune/report.json
python3 Tests/Tools/measure-name-detection.py .build/thai-swift/release/kaito --udet inbox/bench/udet --corpus .build/name-corpus-eval --out-dir .build/name-corpus-eval-after --baseline .build/name-corpus-eval/report.json
git diff --check
```

### `.build/` 内だけの比較・発火診断

`--check-orthography`、既存測定器・コーパス生成器は拡張していない。以下の診断mainは、実際の `traits` / `repeatedScalars` / `thaiDistribution` / `EncodingDetector.detect` を呼ぶ。`ratioPenalty` フィールドは稀記号等も含む分布規則の総減点であり、比率規則の発火率は `events` の `th-common-ratio` の有無で集計する。1行に複数イベントがあっても発火行数は1と数える。

比較では基点のscorerを `.build/thai-rule/NameEncodingScorer.swift` にコピーし、比率の3定数だけを環境変数から受け取る版を一度コンパイルした。CLI/API/候補の変更はない。変更前の製品CLIと診断の基点試行で、ja / zh-cn / th の両policyの単名正解数・分母が一致した。選択後は製品scorerそのものでもmainを再コンパイルし、診断の全行結果が選択試行と一致した。さらに既存測定器による選択後のtune全測定も同じ値だった。

`prepare-trials.py`（基点の製品ソースに対して実行する）:

```python
from pathlib import Path
import csv,json
root=Path('.build/thai-rule')
s=Path('Sources/KaitoKit/Text/NameEncodingScorer.swift').read_text()
s=s.replace('static let thaiFrequentFlags: [Bool] = (UInt32(0xE00)...0xE7F).map { frequent["th"]!.contains($0) }', '''static let trialThreshold = Double(ProcessInfo.processInfo.environment["THAI_THRESHOLD"] ?? "0.35")!
    static let trialMinimum = Int(ProcessInfo.processInfo.environment["THAI_MINIMUM"] ?? "8")!
    static let trialSet = Set((ProcessInfo.processInfo.environment["THAI_SET"] ?? "านรกเอยมลว").unicodeScalars.map(\\.value))
    static let thaiFrequentFlags: [Bool] = (UInt32(0xE00)...0xE7F).map { trialSet.contains($0) }''')
s=s.replace('let deficit = 0.35 * Double(length)', 'let deficit = trialThreshold * Double(length)').replace('if runScalars >= 8, deficit > 0 {','if runScalars >= trialMinimum, deficit > 0 {')
(root/'NameEncodingScorer.swift').write_text(s)
rows=[r for r in csv.DictReader(open('.build/name-corpus-tune/names.tsv'),delimiter='\t',quoting=csv.QUOTE_NONE) if r['lang'] in ['ja','zh-cn','th']]
rows += [dict(id='test-eucjp',lang='ja',truth_iana='euc-jp',hex='学校法人大手前学園'.encode('euc_jp').hex(),text='学校法人大手前学園'),dict(id='test-gb',lang='zh-cn',truth_iana='gb18030',hex='警察广场1号'.encode('gb18030').hex(),text='警察广场1号')]
(root/'tune-input.json').write_text(json.dumps(rows,ensure_ascii=False))
```

`main.swift`:

```swift
import Foundation
struct Input: Decodable { let id: String; let lang: String; let truth_iana: String; let hex: String; let text: String }
struct Event: Encodable { let rule: String; let offset: Int; let scalar: UInt32 }
struct Output: Encodable {
    let id: String; let lang: String; let eligible: Bool
    let ja: String; let jaCorrect: Bool; let none: String; let noneCorrect: Bool
    let ratioPenalty: Double; let events: [Event]; let fullEvents: [Event]; let crossPenalty: Double?
}
@main struct Inspect {
    static func evidence(_ text: String, limit: Int = 256) -> NameEncodingScorer.Orthography {
        let properties = text.unicodeScalars.prefix(limit).map { NameEncodingScorer.traits($0.value) }
        let repeated = NameEncodingScorer.repeatedScalars(properties)
        return NameEncodingScorer.thaiDistribution(properties.enumerated().map { repeated[$0.offset] ? NameEncodingScorer.traits(32) : $0.element })
    }
    static func encoding(_ value: String.Encoding) -> String { NameEncodingCandidates.all.first { $0.encoding == value }?.name ?? String(value.rawValue) }
    static func main() throws {
        let inputs = try JSONDecoder().decode([Input].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let cp874 = NameEncodingCandidates.all.first { $0.name == "cp874" }!
        for row in inputs {
            let chars = Array(row.hex)
            let bytes = stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...($0 + 1)]), radix: 16)! }
            let candidate = NameEncodingCandidates.all.first { $0.name == row.truth_iana }!
            let eligible = candidate.decode(bytes)?.unicodeScalars.elementsEqual(row.text.unicodeScalars) ?? false
            let ja = EncodingDetector.detect(bytes: bytes, policy: .automatic(likelyLanguage: "ja"))
            let none = EncodingDetector.detect(bytes: bytes, policy: .automatic(likelyLanguage: nil))
            let e = evidence(row.text)
            let full = evidence(row.text, limit: Int.max)
            let output = Output(id: row.id, lang: row.lang, eligible: eligible,
                ja: encoding(ja.encoding), jaCorrect: ja.string.unicodeScalars.elementsEqual(row.text.unicodeScalars),
                none: encoding(none.encoding), noneCorrect: none.string.unicodeScalars.elementsEqual(row.text.unicodeScalars),
                ratioPenalty: e.score, events: e.violations.map { Event(rule: $0.rule, offset: $0.offset, scalar: $0.scalar) },
                fullEvents: full.violations.map { Event(rule: $0.rule, offset: $0.offset, scalar: $0.scalar) },
                crossPenalty: cp874.decode(bytes).map { evidence($0).score })
            FileHandle.standardOutput.write(try JSONEncoder().encode(output)); FileHandle.standardOutput.write(Data([10]))
        }
    }
}
```

`run-trials.py`:

```python
from pathlib import Path
import json,os,subprocess,itertools,collections
root=Path('.build/thai-rule')
sets={10:'านรกเอยมลว',15:'นรากเอยมลวสทดคง',20:'นรากเอยมลวสทดคงหตปัี'}
variants=list(itertools.product(sets,[8,12],[.35,.3,.25]))+[(10,8,0)]
summary=[]
for size,minimum,threshold in variants:
 key=f'{size}-{minimum}-{threshold:.2f}'
 path=root/f'trial-{key}.jsonl'
 with path.open('w') as out:
  subprocess.run([str(root/'trial'),str(root/'tune-input.json')],stdout=out,check=True,env=dict(os.environ,THAI_SET=sets[size],THAI_MINIMUM=str(minimum),THAI_THRESHOLD=str(threshold)))
 rows=[json.loads(x) for x in path.read_text().splitlines()]
 th=[x for x in rows if x['lang']=='th']
 hits=[x['id'] for x in th if any(e['rule']=='th-common-ratio' for e in x['events'])]
 entry=dict(key=key,size=size,minimum=minimum,threshold=threshold,hits=hits,fullSame=all(x['events']==x['fullEvents'] for x in th))
 for lang in ['th','ja','zh-cn']:
  eligible=[r for r in rows if r['lang']==lang and r['eligible'] and not r['id'].startswith('test-')]
  entry[lang]=dict(eligible=len(eligible),**{p:dict(correct=sum(r[p+'Correct'] for r in eligible),cp874=sum(r[p]=='cp874' for r in eligible)) for p in ['ja','none']})
 entry['examples']=[{k:v for k,v in r.items() if k in ['id','ja','none','jaCorrect','noneCorrect']} for r in rows if r['id'].startswith('test-')]
 summary.append(entry)
 (root/'comparison.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2))
 print(key,'hits',len(hits),entry['th'],entry['ja'],entry['zh-cn'],entry['examples'],flush=True)
```

```sh
python3 .build/thai-rule/prepare-trials.py
xcrun swiftc -O -swift-version 6 -parse-as-library -package-name KaitoKit -module-cache-path .build/clang-cache Sources/KaitoKit/Text/{EncodingPolicy,EncodingDetector,NameEncodingCandidates,LanguageExemplars}.swift .build/thai-rule/{NameEncodingScorer,main}.swift -o .build/thai-rule/trial
python3 .build/thai-rule/run-trials.py > .build/thai-rule/trials.log

# 選択後: 製品scorerを直接呼ぶ診断。環境変数を読む試行用コピーを使わない。
xcrun swiftc -O -swift-version 6 -parse-as-library -package-name KaitoKit -module-cache-path .build/clang-cache Sources/KaitoKit/Text/{EncodingPolicy,EncodingDetector,NameEncodingCandidates,NameEncodingScorer,LanguageExemplars}.swift .build/thai-rule/main.swift -o .build/thai-rule/final-diagnostic
.build/thai-rule/final-diagnostic .build/thai-rule/tune-input.json > .build/thai-rule/final-tune.jsonl
```

正解率は復号文字列のscalar完全一致。zh-cn非ASCII≥4は `single_by_length` の `4–7` と `8+` を合算した。書庫k≥10は `archive_by_encoding_k` のk=10/30/100を合算し、言語ごとの全符号化を含めた。前後の全出力は `.build/name-corpus-{tune,eval}{,-after}/runs/`、比較の生結果は `.build/thai-rule/trial-*.jsonl` / `comparison.json`、evalの全policy・単名/書庫の変更行は `.build/thai-rule/eval-changes.json` に保存した。
