# codec の性能・安定性検証（2026-11-05）

基点は KaitoKit 0.21.0。公開 API、対応形式、build 要件は変えず、復号の CPU 経路だけを対象にした。GPU / NPU の研究実装と全候補の生の計測は [KaitoAccelLab](https://github.com/shunnag/KaitoAccelLab) の `Documentation/speed-report.md` §8〜10 と `Results/` に保存する。本番の Package には Metal / Core ML を追加しない。

## 測定方法

M4 Max と Mac mini M4、macOS 27.2、Xcode 27.2 / Swift 6.4.2。release binary を使い、固定入力を変更前後で交互に測定した。性能測定と全テストを同じ Mac で同時には実行していない。数値は中央値で、全入力への一律の倍率ではない。

再現には `KaitoAccelLab/Scripts/benchmark_kaito_inprocess.py`、`benchmark_lz4_cli.py`、`make_larc_corpus.py`、`make_ppmd_corpus.py` を使う。LArc は独自 encoder で生成した実 `-lzs-` / `-lz5-` 書庫を使う。lha-unix の `-o1` / `-o2` は header level であり、`-lh1-` の生成物を LArc 測定から除外した。

## 採用した改善

### 独立 modern LZ4 frame

block の文法と展開後サイズを検証したうえで Apple decoder を使い、最大 `workers` lane でサイズを求める。小 block は出力 256 KiB を目標に一つの job にまとめる。dependent・legacy・連結 frame・単一 block・解析できない入力は従来の直列経路を使う。job 内で失敗した場合は block ごとに再実行し、部分出力・失敗時 buffer・checksum の error 順を直列経路と照合した。

`sha --sink --threads auto`、64 MiB の Swift source corpus、各 block size の結果:

| machine | block | 0.21.0 | 最終 |
|---|---:|---:|---:|
| Mac mini | 4 KiB | 0.111276 s | 0.043320 s |
| Mac mini | 16 KiB | 0.056996 s | 0.022517 s |
| Mac mini | 64 KiB | 0.043240 s | 0.017926 s |
| M4 Max | 4 KiB | 0.105119 s | 0.046040 s |
| M4 Max | 16 KiB | 0.049523 s | 0.022293 s |
| M4 Max | 64 KiB | 0.037343 s | 0.016607 s |

M4 Max の 256 MiB でも 2.55〜2.83 倍。乱数・ゼロ列・外部 `lz4`・両 checksum・256 MiB の出力一致、後続 block の文法・復号失敗、200 変異の ASan / UBSan を確認した。

### LArc、PPMd、CAB LZX

`sha --sink --threads 1` または実 entry 読み出しの測定:

| 対象 | Mac mini 変更前 → 最終 | M4 Max 変更前 → 最終 |
|---|---:|---:|
| LArc text-lzs | 23.3630 → 18.3435 ms | 24.6050 → 18.8675 ms |
| LArc color-lzs | 165.1490 → 90.3975 ms | 167.8565 → 90.4005 ms |
| LArc color-lz5 | 85.0075 → 78.6620 ms | 87.2795 → 80.8800 ms |
| PPMd H text.7z | 184.931 → 170.333 ms | 185.504 → 170.098 ms |
| PPMd I text.zip | 232.875 → 195.796 ms | 235.889 → 199.152 ms |
| CAB LZX product.cab | 30.762 → 28.757 ms | 30.642 → 28.673 ms |

LZS は専用 bit cursor、lz5 は inline emit だけを採用した。共通 emit / beginMatch の inline は入力によって後退したため採らない。LZS は 10,000 token、辞書 wrap、距離 1 / 2,048、buffer 1 / 7 / 4,096 / 65,536、prefix と切断を検査した。

PPMd H / I は、検証済みの context / state を allocator が動かない範囲で再利用する。suffix・successor・拡大後の state 配列と range coder の検査は残す。凍結した旧実装との差分、38 生成書庫、公開 API harness の 496 結果で、SHA-256・返却済み prefix・error が一致した。ASan 40 tests（1 skip）も成功した。

LZX の高速表は 12 bit とし、実 product.cab の 106 file が cabextract と一致した。17 tests（1 skip）と ASan を確認した。

### RAR15 / RAR20 / RAR3 filter

| 対象 | Mac mini 変更前 → 最終 | M4 Max 変更前 → 最終 |
|---|---:|---:|
| RAR15 文書 | 6.0515 → 4.7730 ms | 5.7425 → 4.8740 ms |
| RAR15 音声 | 1.0155 → 0.7305 ms | 0.9390 → 0.7470 ms |
| RAR20 biglz | 2.8005 → 1.6495 ms | 3.0260 → 1.7160 ms |
| RAR20 audio | 0.5775 → 0.5400 ms | 0.6135 → 0.5690 ms |

RAR15 は consume-only bit 更新と `decodeNum` / `addBits` の inline を使う。RAR20 は 10 bit・1,024 entry の short-code 表を追加し、長い符号は canonical loop に残す。公開 API の 264 結果で出力・prefix・error が一致し、両機の ASan も成功した。

RAR3 filter の global data は、長さの検査後に一括で consume する。global-data が多い特殊な stream では M4 Max の 1,000 展開が 24.070 → 18.620 ms。長さ 0・1・17・128・上限 0x1FC0、切断、16 bit payload-length を検査し、両機の 8 tests と ASan が成功した。

## 全テスト

最終 production source を完全な tracked source に重ねた `/tmp/kaito-larc-verified-mini-20261105` で、Mac mini の `swift test -j 4` を実行した。

- KaitoKit: **2,100 tests、68 skipped、0 failures**（1,404.471 秒）
- KaitoKitCompat: **34 tests、0 failures**
- 最終 LArc 関連 8 tests、両機の ASan、LZ4・PPMd・RAR・LZX の個別試験も成功

生の全出力は KaitoAccelLab の次の log に保存する。

- `Results/kaito-larc-final-full-mini-20261105.txt`
- `Results/kaito-larc-final-asan-mini-20261105.txt`
- `Results/kaito-codec-final-full-mini-20261104.txt`
- `Results/lz4-kaito-parallel-scan-source256-20261104.txt`

初回の一時 copy に文書と fixture がなかった失敗 log は `kaito-larc-incomplete-tree-full-mini-20261105.txt` に残し、完全な source tree の最終結果と区別する。
