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

## LZ4 並列計画の早期終了（0.22.1）

`cooViewer-3g4e` の指摘を確認した。0.22.0 の `SizeWork.run` は失敗した lane も含め全 block を処理し、結果の確認も全 lane の完了後だった。match 直後に終わる不正 block では、token walk の拒否後に Swift decoder が実際に復号して error を診断するため、先頭の失敗とは無関係な後続 block にも大きな費用が生じる。

最終版は失敗を `Synchronization.Atomic<Bool>` で全 lane に共有し、block ごとに呼出側の `UnsafeCurrentTask.isCancelled` も確認する。既に実行中の block は完了するが、未開始の block は飛ばす。結果欄が未確定なら強制アンラップせず、従来どおり直列 decoder へ戻す。計画の失敗を `try?` で直列へ戻す契約は変えず、部分出力・失敗時 buffer・error 順を直列 decoder に委ねる。GCD worker だけの `Task.checkCancellation()` に依存せず、呼出側の task を捕捉して確認する。

新しい 2 tests は、2 lane の最初の block を test hook で同期させる。先頭が不正な frame と検証中に取消す frame のどちらも、開始 index は `[0, 2]` だけで `[1, 3]` を検証しないことを確認する。停止処理を外した反証では両方とも `[0, 1, 2, 3]` になり、意図どおり失敗した。既存の serial / parallel outcome、全 buffer 境界、legacy・差分試験も成功した。

さらに 4 MiB を出力する match の直後に終わる block を 256 個持つ independent frame（4,213,003 bytes、block maximum 4 MiB）を `sha --sink --threads auto` に与えた。M4 Max の `time -p` の user CPU は 0.22.0 が 0.10 秒、最終版が 0.01 秒で、どちらも `LZ4 block has no final literal sequence` と同じ error だった。wall time は 0.01 秒刻みの表示なので、ここから倍率は主張しない。

入力の上限に近い最悪ケースも測った。1 block 16,452 bytes で同じ形の block を 15,800 個持つ independent frame（260,004,811 bytes）を、Mac mini で `sha --sink --threads auto` に与え、5 回交互に起動した。real / user は 0.22.0 が約 1.1 / 9.1 秒、最終版が 0.06 / 0.01 秒（初回のみ real 0.34 秒）で、どちらも同じ error。

完了通知より先に停止を公開するよう直した最終版と直す前の版で、新しい 2 tests を 30 個の CPU 負荷の下で各 150 回実行し、どちらも全回成功した。直す前の競合は実行では再現せず、コードの順序から確認した。

### 正常系の性能

64 MiB の Swift source corpus（SHA-256 `0ea82c38fc3cfba471d2f2441306d278efbafc4fc422c8b195d40e1da2d519ab`）を `accel-lab lz4-make-frame` で independent frame にし、`lz4 -t` で検証した。`sha --sink --threads auto`、12 回交互起動（各 6 回）の中央値。0.22.0 (`aac75e8`) と最終版の別々の release binary を使い、性能測定と全 test は同時に実行していない。

| machine | block | 0.22.0 | 最終版 |
|---|---:|---:|---:|
| M4 Max | 4 KiB | 0.045681563 s | 0.045225958 s |
| M4 Max | 16 KiB | 0.020966042 s | 0.021000812 s |
| M4 Max | 64 KiB | 0.015597438 s | 0.015594105 s |
| Mac mini M4 | 4 KiB | 0.046548480 s | 0.047043084 s |
| Mac mini M4 | 16 KiB | 0.023735250 s | 0.023593958 s |
| Mac mini M4 | 64 KiB | 0.019524854 s | 0.019097812 s |

最初の `NSLock` 版は M4 Max の 4 KiB block で約 9% 遅く、採用しなかった。atomic に変えた最終版は、4 KiB の差が M4 Max で約 −1.0%、mini で約 +1.1%、16・64 KiB でも測定のばらつきを超える一貫した後退はなかった。

### sanitizer

- 標準 `swift test --sanitize address --filter 'LZ4FrameTests|LZ4DifferentialTests'`：25 tests、0 failures、sanitizer finding なし。
- 14 の実際の production source file と一時 probe を直接 build する TSan：失敗・取消しの両ケースを通過し、race 報告なし。同じ probe を ASan / UBSan でも通過した。
- 全 target の `swift test --sanitize=thread` は、テスト実行前に既存の PPMd source で Swift compiler が `Invalid bitcast` / `Broken module found` となり、実行できなかった。これは LZ4 の test failure ではない。`-Xswiftc -sanitize=address,undefined` は SwiftPM XCTest helper の ASan late-load で停止するため、標準 `--sanitize address` と直接 probe の結果を区別して記録する。

## 0.22.1 の全テスト

最終 production source を持つ `/tmp/kaitokit-lz4-plan-cancellation-candidate` で、Mac mini の全 test を実行した。外部 tool を必須にし、timezone を Asia/Tokyo にした `swift test -j 4` の結果は **2,102 tests、68 skipped、0 failures**（1,453.271 秒）、Compat は **34 tests、0 failures**。文書・導入例の 15 tests、新規 2 tests の 25 回連続実行も成功した。`Scripts/build-framework.sh` では arm64 / x86_64 の universal framework を生成できた。

上記の修正を入れた最終版でも、Mac mini の `swift test -j 4` は **2,102 tests、68 skipped、0 failures**（1,408.351 秒）、Compat は **34 tests、0 failures** だった。
