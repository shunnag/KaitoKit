# 2026-11-03 全形式の decode 性能・安定性検証

`1afc1c6b8d770e77d8c14a54bda6ac40c191ea1b`（0.20.0）を baseline に、対応形式の復号を
再計測し、独立 block の並列化と CPU のボトルネックを個別に最適化した記録。製品への採用対象は
RAR15、LZ4、Deflate64、CAB LZX。出力・部分出力・エラーの意味を変えることなく速度を改善する。
ここに書く「A/B」は **candidate / baseline**、競合比は **candidate / 参照実装** で、小さいほど速い。
「全形式で最速」「全形式で競合に勝った」という意味ではない。

## 環境と測定方法

- M4 Max（16 core、128 GiB）と Mac mini M4（10 core、16 GiB）、macOS 27.2、Xcode 27.2 の release。
- Mac mini には `100.67.198.94` で接続し、`.local` 登録済みの ssh host key と一致することを確認した。
  既存 checkout ではなく一時領域へ source を送って検証した。
- 主 corpus は 71 書庫・約 6.5 GB（text / random 各 256 MiB、小ファイル 50,000 件）。
  manifest SHA-256 は `96427e30e45a907e13772296aac461ac09861f952cb179a847caaa055190fe1f`。
  追加 codec corpus は 12 書庫で、manifest SHA-256 は
  `76cac57a82f0fcc379a8c7be2d541ce723f9179e8f8fa6a0652fdf31819197c6`。
- M4 Max baseline `<tmp>/kaito-ppmd-state-base` の SHA-256 は
  `a5bb34a6843d478736b0b7662683811f7af19af20b84d93bfcec9087b89c8f1f`。
  mini baseline の SHA-256 は `590b9dac13758711f3c958f547f17f32bfdc1a6f459570f89178032b0a40c857`。
- `Tests/Measurement/decode-ab/compete.py` で、別 process・書庫 warm・base / candidate 交互順の
  5〜15 round を測定した。short job や小さな差は A/A の幅と両機の再現を採用条件にした。
  `sha --sink` は、実際の entry を読みつつ SHA-256 の計算だけを省く。起動・open・CRC 検証は計測に含む。
- `verify-corpus.py` は元入力との entry 名・サイズ・SHA-256 を照合し、`Outcomes.swift` は
  public API の部分出力・エラーを比較する。original は threads auto / 1 / 3 / 16 と buffer
  1 / 4,099 / 65,536、mutations は auto + 4,099 を使う。

## 採用した変更と結果

### RAR15: 状態バッファの固定確保

`SolidState` の `chSet*`、`nToPl*`、window と `corrHuff` を固定長の unsafe buffer にし、
deinit で解放する。Array の CoW と排他検査を hot loop から外したが、RAR4 共通 decoder、
RAR29 decoder、PPMd range decoder、標準 filter、solid/filter 実行部は変更していない。

| A/B（小さいほど速い） | M4 Max single | M4 Max auto | mini single | mini auto |
|---|---:|---:|---:|---:|
| 実 RAR15 書庫 | 0.7778 | 0.8372 | 0.7340 | 0.7286 |

RAR15 / RAR13 の 31 tests（9 skipped）と実書庫 17 entry を確認。original / mutation の
出力・エラーはすべて一致した。

### LZ4: 独立 block の並列復号

単一の modern independent frame のみ、全 block の文法と実出力長を先に検証して並列復号する。
展開後サイズが記録されていない一般的な frame も、全量上限の内側では対象にする。dependent、legacy、
連結 frame、単一 block、 trailing data、予算超過、解析できない入力は従来の直列 decoder に戻す。
圧縮サイズは `min(256 MiB, parallelDecodeMemory / 2)` 以下に限り、入力を block ごとに保持して
後続 I/O race を避ける。

- サイズ発見のための復号は行わず、完全な token walk だけを行う。短い match が密な block でも
  検証済みのサイズで Apple Compression を呼び、同じ token walk を繰り返さない。
- block buffer の所有権を `Data` へ移し、worker から consumer への余分なコピーを除く。
- 出力は元の block 境界で返す。content checksum は全出力を返した後の read で検査し、
  部分出力・失敗時 buffer・エラー順を直列と一致させる。

| 自動並列 | M4 Max A/B | mini A/B | M4 Max / lz4 | mini / lz4 |
|---|---:|---:|---:|---:|
| `text.tar.lz4` | 0.8686 | 0.7664 | 1.3444 | 1.4810 |
| `small.tar.lz4` | 0.9400 | 0.8979 | 1.3501 | 1.3390 |

single thread は M4 Max で 0.9989 / 0.9943、mini で 0.9979 / 0.9988（text / small）。
A/A の幅を超える回帰はなかった。競合との差は残るが、当初の約 1.9 倍から縮めた。
M4 Max の max RSS は直列の text 83.84 / small 124.47 MiB から、並列の text 247.20 /
small 227.45 MiB に増える。4 workers では約 48 MiB、8 workers では約 32 MiB を削減できたが、
text の中央値がそれぞれ約 1.8% / 2.4% 悪化したため、速度目的では worker cap を採用しなかった。
保持量は従来の `parallelDecodeMemory` で制限できる。

### Deflate64: bit 状態と Huffman 表

`readBits`、match copy、長さ・距離計算を inline 化した。`bitAlignment` は毎回更新せず、
byte 列から補った `availableBits` の下位 3 bit から必要時に求める。Huffman entry は
符号・bit 数・lookup 数を 4 byte に詰め、表の cache 量を減らした。以前不一致になった
caller output 直接 history は使っていない。

| 1 thread | M4 Max A/B | mini A/B | M4 Max / 7zz | mini / 7zz |
|---|---:|---:|---:|---:|
| `text-deflate64.7z` | 0.9295 | 0.9202 | 1.7112 | 1.7121 |
| `text-deflate64.zip` | 0.9334 | 0.9234 | 1.7055 | 1.7036 |

固定 table の追加効果は 7z で約 1.2%、ZIP では中立〜小幅改善として両機で確認した。

### CAB LZX: 固定 Huffman 高速表と block 参照

`LZXHuffmanTable` を class にし、1024 件の fast lookup を固定 buffer に保持する。prefix は
10 bit にマスクされるため、全 lookup は確保範囲内。init 失敗時と deinit の解放を両方保ち、
16 bit の canonical fallback は従来どおり。さらに optional の main / length table を token ごとではなく
block ごとに解く。table 差し替え位置、match / raw block / E8 / frame 境界は変更しない。

| product.cab（106 files） | A/B | block 参照の追加効果 | candidate / 7zz |
|---|---:|---:|---:|
| M4 Max（最終結合版） | 0.4535 | 約 0.89（負荷変動あり） | 2.3253 |
| mini | 0.4386 | 0.8817 | 2.4993 |

約 5.2 倍だった差を約 2.3〜2.5 倍まで縮めた。WIM LZX でも退行はなかった。

## 出力・破損入力・sanitizer

- 主 71 + 追加 12 書庫の全 83 書庫について、元入力との entry 名・サイズ・SHA-256 が一致した。
- 818 個の checked-in fixture について、baseline と結合版の終了コード・全 entry 出力・stderr が
  すべて一致した（`<tmp>/kaito-all-fixture-sweep.jsonl`、SHA-256
  `758fa8887d92816232763235cdfe4a558c7c1ad0f18cedd9f2027861f4187da7`）。
- LZ4 は 93 の小型 original / mutation と 57 の大型 mutation が完全一致。両機で 79 関連 tests＋
  Compat 1 test を通過し、ASan/UBSan の 240 mutants は crash / hang / finding 0。
- Deflate64 は 21 tests（任意の性能測定 1 skip）と 38 mutation outcomes が完全一致。
- CAB LZX は 31 tests（外部 corpus 1 skip）と 19 mutation outcomes が完全一致。実 product.cab の
  106 files は cabextract の展開結果とも一致した。
- 最終結合版の全 suite は mini で **2,096 tests / 64 skipped / 0 failures**、Compat 34 tests、
  Asia/Tokyo の LHA golden 2 tests に成功した（1,418.462 秒）。
- x86_64 向け build に成功し、Rosetta 上の x86_64 binary と arm64 binary で、CAB LZX・LZ4・
  Deflate64・RAR15 の代表書庫の全 entry 出力が一致した。
- 最終 KaitoKit と GyoshukuKit・現在の KaitoFinder を組み合わせた統合 suite も、mini で
  **1,800 tests / 35 skipped / 0 failures** に成功した（1,445.997 秒）。
- Deflate64 / RAR15 / CAB / LZ4 の 11 seed から選んだ最終 240 mutants は、ASan/UBSan で
  crash 0 / hang 0 / sanitizer finding 0。最初の timeout 8 秒を超えた CAB 変異も全て有限時間で
  終了し、最も遅いものは約 141 秒だった。全 240 件を timeout 180 秒で再集計した。

## 他形式の実物比較と適用範囲

CAB・CHM・ARJ・WIM・DMG・CFB・ISO・UDF・MSI の 47 書庫を追加で調べた。7zz も KaitoKit も
受理した 36 書庫を `compete.py` で比較した。小さな fixture には process 起動の影響が大きいため、
その比率だけで最適化を採用せず、106 file の product.cab を別途長時間測定した。

- 7zz が受理しない 8 UDF と `hfs-decmpfs.dmg` は、この比較の対象外。UDF の全般的な速度を
  示すものではない。
- `apfs-zlib.dmg` と `hfs-adc.dmg` は KaitoKit が既存の制約でエラーになるため、速度比較の対象外。
- CAB Quantum は現状 `unsupportedMethod("cab Quantum")`。今回の LZX 最適化で対応方式を増やした
  わけではない。
- CHM、WIM、DMG、CFB、ARJ についても checked-in fixture の挙動は網羅したが、大きな実書庫が
  無いものの絶対的な性能順位はここでは主張しない。

## 却下した候補

- PPMd mask 集計と `decodeSymbol1` の 4 state 展開: color / text が悪化。
- RAR5 bit reservoir: single は小幅改善だが mini automatic が約 2.2% 悪化し、既定経路で一貫しない。
- Deflate64 direct caller history: solid fixture の offset 323332 と ZIP checksum で不一致。
- PPMd の bit-parallel 記号検索・context 検証再利用: いずれも差が約 1% 未満で採用せず。
- LZMA match group の inline 化: small solid / text LZMA が約 1% 悪化。
- CAB match の共通周期コピー: 短い match の setup が増え、product.cab が約 5% 悪化。

## KaitoAccelLab の再評価と残る制限

KaitoAccelLab の資料と実装を確認した。LZ4 GPU 復号は CPU 16 lane の 0.15〜0.6 倍、
GPU 1 thread は CPU 1 core の約 1/350、NPU の GRU + range coder は 0.24〜0.65 MB/s。
GPU CRC、MTLIO、神経 codec の新規展開はせず、CPU 並列と OS の codec を採用した。
xz / bzip2 の block 並列は本流に存在するため重複実装しない。Compression.framework には zstd API がなく、
libarchive は公開 header がないため今回の製品変更には使わない。

PPMd color はまだ参照実装の約 1.65〜1.81 倍、Deflate64 は約 1.70 倍、LZ4 は約 1.34〜1.48 倍、
CAB LZX は約 2.33〜2.50 倍の時間が残っている。今回の変更でこれらを完全には解消していない。
第三者 decoder の source や逆アセンブルは使わず、KaitoKit 自身のコード・公開形式ノート・
KaitoAccelLab・black-box writer / reader だけを使った。

再現用の主要な生データは `<tmp>/kaito-final-*.jsonl`、`<tmp>/kaito-cab-*.jsonl`、
`<tmp>/kaito-other-format-competitor.jsonl` に保存した。大きな corpus と binary は repository に含めない。
