# 2026-10-11 decode 性能の検証記録（KaitoKit 0.14.0）

`perf/kk014-integrate` の `db78268` を 0.13.0（`d9eaada`）と比較した。7z LZMA2 の reset 単位の並列復号、
LZMA core、非 solid 7z と RAR5 の先行復号、RAR5 の復号 loop、`.xz` の自前 LZMA2 復号、zstd の sequence 復号と
XXH64 の変更を含む。前回の [0.13.0 の記録](2026-10-10-decode-performance.md) と同じ harness・corpus を使う。

## 環境と方法

| 項目 | 条件 |
|---|---|
| 機械 | MacBook、Apple M4 Max |
| CPU | 16 cores（12P + 4E） |
| メモリ | 128 GiB |
| OS | macOS 27.2 |
| toolchain | Xcode 27.0 |
| build | base / branch とも release |
| revision | base = d9eaada（0.13.0）、branch = db78268 |

- harness は `Tests/Measurement/decode-ab/`。前回と同じ固定 seed の corpus（text / random 各 256 MiB、
  小ファイル 50,000 件）と追加形式の計56書庫。書庫自体は repository に含めない。
- 3 round を交互順に実行し、各側の best-of-3 を採用する。既定の自動並列数、各 sample は別 process。
- [生データ](2026-10-11-decode-performance.jsonl) は binary / manifest の絶対パス3箇所だけを相対表記にした。
  `base/`・`branch/` は保存した CLI、`corpus/` は計測 corpus を表す。

```sh
python3 Tests/Measurement/decode-ab/ab.py \
  --summary Documentation/verification/2026-10-11-decode-performance.jsonl
python3 Tests/Measurement/decode-ab/ab.py \
  --summary Documentation/verification/2026-10-11-decode-performance.jsonl --metric max_rss
```

## 同一性と壊れた入力の検証

- `kaito sha` の stdout と終了コードを、全56書庫（AES の7z は password 付き）× 既定 / `--threads 1` /
  `--threads 3` / `--threads 16` の224通りで base と照合し、すべて一致した。
- 壊れた 7z / RAR5 / XZ の331書庫（切り詰め・bit 反転・zero 埋め、自作と review で作ったもの）を、公開 API で
  threads 自動 / 1 / 3 × 読み取り buffer 1 / 4,099 / 65,536 byte で読み、entry ごとの返却 byte 数・
  返却 byte の SHA-256・エラーを照合した。2,979通りすべて一致。
- zstd は単一 frame の変異5,039個（切り詰め・bit 反転）× buffer 1 / 127 / 4,099 / 65,537 byte と、
  約3 MB の text を level 3 / 19 / `--long=24` で圧縮した frame の変異603個 × 3 buffer で照合し、すべて一致。
- LZMA core と zstd の変更は、AddressSanitizer 下の差分 fuzz（LZMA 約149万行、0 DIFF・0 report）と
  静的な境界の追跡で review した。zstd の review で見つかった、長さの検査前に範囲外の pointer を作る計算は
  `db78268` で整数の和にした。

### 意図した挙動の変更

- LZMA2 の `0x01` chunk の後に property のない LZMA chunk（`0x80`〜`0xBF`）が続く stream は、
  LZMA SDK / liblzma / 7-Zip と同じく壊れた stream として拒否する。0.13.0 は復号を続けていた。
- RAR5・非 solid 7z・`.xz` で entry stream を開くタスクを取り消すと `CancellationError` が返る場合がある。

### base 対 base の揺らぎ

0.1 s 超の66行中58行は best 比が ±2% 以内。外れた8行は bzip2 / 多 block xz / gz で、±5.6% 以内。

## sha --sink の wall time

base best が 0.05 s を超える49書庫。比は branch / base（小さいほど短い）。

| 書庫 | base best（s） | branch best（s） | 比（B/A） |
|---|---:|---:|---:|
| mixed-UDBZ.dmg | 1.6123 | 1.5843 | 0.9826 |
| random-aes.7z | 0.0941 | 0.0824 | 0.8760 |
| random-nonsolid.7z | 0.0594 | 0.0520 | 0.8746 |
| random-rar5-blake2.rar | 0.5931 | 0.5859 | 0.9879 |
| random-solid.7z | 0.0596 | 0.0528 | 0.8860 |
| random.multi.tar.xz | 0.0958 | 0.0738 | 0.7697 |
| random.single.tar.xz | 0.2756 | 0.1976 | 0.7171 |
| random.tar.bz2 | 0.9419 | 0.9467 | 1.0051 |
| random.tar.gz | 0.0839 | 0.0715 | 0.8519 |
| random.tar.lz | 5.3468 | 5.3239 | 0.9957 |
| random.tar.lz4 | 0.1018 | 0.0892 | 0.8771 |
| random.tar.zst | 0.1020 | 0.0903 | 0.8861 |
| small-aes.7z | 0.6071 | 0.5325 | 0.8772 |
| small-deflate64.zip | 2.4687 | 2.4889 | 1.0082 |
| small-ditto.zip | 0.3182 | 0.3203 | 1.0064 |
| small-nonsolid.7z | 1.7007 | 0.2431 | 0.1429 |
| small-rar5-blake2.rar | 1.4117 | 0.3003 | 0.2127 |
| small-rar5.rar | 0.9537 | 0.2288 | 0.2400 |
| small-solid.7z | 0.5888 | 0.5154 | 0.8754 |
| small-zip6.zip | 0.3055 | 0.3065 | 1.0033 |
| small.multi.tar.xz | 0.2931 | 0.2709 | 0.9242 |
| small.single.tar.xz | 0.7967 | 0.6764 | 0.8489 |
| small.tar.bz2 | 0.4414 | 0.4398 | 0.9964 |
| small.tar.gz | 0.2700 | 0.2604 | 0.9642 |
| small.tar.lz | 0.6527 | 0.6116 | 0.9371 |
| small.tar.lz4 | 0.2937 | 0.2866 | 0.9756 |
| small.tar.zst | 0.3068 | 0.2881 | 0.9393 |
| text-aes.7z | 0.9759 | 0.8830 | 0.9048 |
| text-deflate64.zip | 1.1297 | 1.1299 | 1.0001 |
| text-ditto.zip | 0.1155 | 0.1150 | 0.9953 |
| text-nonsolid.7z | 0.9548 | 0.8675 | 0.9086 |
| text-ppmd.7z | 3.7322 | 3.7439 | 1.0031 |
| text-ppmd.zip | 4.3648 | 4.3720 | 1.0016 |
| text-rar5-blake2.rar | 1.2481 | 1.0296 | 0.8249 |
| text-rar5.rar | 0.6747 | 0.4669 | 0.6920 |
| text-solid.7z | 0.9616 | 0.8644 | 0.8989 |
| text-zip6.zip | 0.1141 | 0.1149 | 1.0072 |
| text.mm.lz | 0.7170 | 0.6465 | 0.9017 |
| text.multi.tar.xz | 0.1718 | 0.1401 | 0.8158 |
| text.single.tar.xz | 1.1838 | 0.9582 | 0.8095 |
| text.tar.bz2 | 0.5294 | 0.5062 | 0.9562 |
| text.tar.gz | 0.1685 | 0.1569 | 0.9310 |
| text.tar.lz | 0.9272 | 0.8234 | 0.8880 |
| text.tar.lz4 | 0.2171 | 0.2040 | 0.9393 |
| text.tar.zst | 0.2417 | 0.2050 | 0.8480 |
| text.txt.bz2 | 0.3534 | 0.3442 | 0.9741 |
| text.txt.gz | 0.1215 | 0.1148 | 0.9450 |
| text.txt.xz | 0.1330 | 0.1022 | 0.7689 |
| text.txt.zst | 0.1882 | 0.1555 | 0.8264 |

## list（open）の wall time

base best が 0.05 s を超え、best 比の差が2%を超える20行。`text.tar.bz2` の 1.0277 は
同じ書庫の base 対 base の揺らぎ（0.9520）の範囲内で、bzip2 は今回変更していない。

| 書庫 | base best（s） | branch best（s） | 比（B/A） |
|---|---:|---:|---:|
| random.multi.tar.xz | 0.0756 | 0.0629 | 0.8318 |
| random.single.tar.xz | 0.2551 | 0.1839 | 0.7208 |
| random.tar.gz | 0.0661 | 0.0589 | 0.8921 |
| random.tar.lz4 | 0.0848 | 0.0785 | 0.9259 |
| random.tar.zst | 0.0829 | 0.0765 | 0.9226 |
| small-aes.7z | 0.1497 | 0.1147 | 0.7661 |
| small-nonsolid.7z | 0.1579 | 0.1231 | 0.7799 |
| small-solid.7z | 0.1292 | 0.0959 | 0.7423 |
| small.multi.tar.xz | 0.2695 | 0.2471 | 0.9166 |
| small.single.tar.xz | 0.7723 | 0.6495 | 0.8410 |
| small.tar.gz | 0.2466 | 0.2404 | 0.9747 |
| small.tar.lz | 0.6290 | 0.5902 | 0.9382 |
| small.tar.zst | 0.2869 | 0.2661 | 0.9275 |
| text.multi.tar.xz | 0.1503 | 0.1318 | 0.8768 |
| text.single.tar.xz | 1.1736 | 0.9524 | 0.8115 |
| text.tar.bz2 | 0.4981 | 0.5119 | 1.0277 |
| text.tar.gz | 0.1524 | 0.1459 | 0.9572 |
| text.tar.lz | 0.9158 | 0.8209 | 0.8964 |
| text.tar.lz4 | 0.1981 | 0.1932 | 0.9756 |
| text.tar.zst | 0.2217 | 0.1909 | 0.8611 |

## peak RSS

best 比が 0.8〜1.2 の外にある行。単位は MB = 1,000,000 bytes。

| 書庫（sha --sink） | base peak RSS（MB） | branch peak RSS（MB） |
|---|---:|---:|
| small-rar5-blake2.rar | 168.6 | 239.9 |
| small-rar5.rar | 157.2 | 308.8 |

RAR5 の先行復号は、worker 数 × 最大約 1 MiB の batch 出力と packed 入力・再利用する作業領域を保持する。
保持量は `ReadLimits.parallelDecodeMemory`（既定は物理メモリの50%）に数える。

## 参照 CLI との比較（参考）

同じ MacBook で `7zz t` は small-nonsolid.7z 1.05 s、small-solid.7z 0.39 s、small.single.tar.xz 0.40 s。
`7zz` 26.04 はこの corpus の RAR5 member を展開できない（Unsupported Method）。`unrar t` は small-rar5.rar
1.38 s。`lzip -d` は random.tar.lz 15.1 s。
