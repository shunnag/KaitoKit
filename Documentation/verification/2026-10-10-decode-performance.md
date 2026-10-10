# 2026-10-10 decode 性能の検証記録（KaitoKit 0.13.0）

`perf/kk-integrate` の `7307881` を、`a489c76` に `sha --sink` の CLI patch だけを適用した base と比較した。
復号並列数の自動化、decoder・暗号・ハッシュの hot loop、entry 初期化、UDIF の先読み、展開 I/O の変更を含む。
前回の [xz / bzip2 の並列復号記録](2026-09-29-parallel-decoders.md) に続く計測。

## 環境と方法

| 項目 | 条件 |
|---|---|
| 機械 | MacBook、Apple M4 Max |
| CPU | 16 cores（12P + 4E） |
| メモリ | 128 GiB |
| OS | macOS 27.2 |
| toolchain | Xcode 27.0 |
| build | base / branch とも release |
| revision | base = a489c76 + sha --sink のみ、branch = 7307881 |

- harness は `Tests/Measurement/decode-ab/`。`make-corpus.sh` の固定 seed・UTC mtime の入力
  （text / random 各 256 MiB、小ファイル 50,000 件）を使い、追加形式を含めて計56書庫。
- 追加書庫は 7zz の Deflate64 ZIP、PPMd の 7z / ZIP、`hdiutil create -fs HFS+` で作った
  UDZO / ULFO / UDBZ / ULMO の DMG、8 frame を連結した zstd、`lzip -b` の2 member。
  同じ書庫と manifest を両 binary に使う。書庫自体は repository に含めない。
- identity gate は通常の `kaito sha` の stdout と終了コードを照合する。全56書庫で一致し、
  `list` / `sha --sink` の全672 sample が終了0。worker 数で展開 byte 列は変わらない。
- 3 round を base→branch / branch→base / base→branch と交互に実行し、各側の best-of-3 を採用する。
  round の前に書庫全体を読んで warm にし、各 sample は別 process。既定の自動並列数を使う。
  この機械の branch の自動要求は16、base の XZ / bzip2 の worker 上限は8。
- wall は Python の `perf_counter` の経過時間。起動・metadata 解析・stdout の整形・CRC 検証を含み、
  stdout は `/dev/null` へ送る。`sha --sink` は SHA-256 の計算を省いて全 entry を読み切る。
  `list` は open を測り、圧縮 tar では staging の復号全体も含む。
- peak RSS は `/usr/bin/time -l` の `max_rss`（bytes）。wall は10 ms 単位の `time -l` real を使わない。
  絶対値は機械・入力・実行条件に依存する。

集計元は `.build/release-data/ab-final-summary.txt`（wall）、`ab-final-rss.txt`（max_rss）、
`noise-summary.txt`（base 対 base）。[生データ](2026-10-10-decode-performance.jsonl) は
`ab-final.jsonl` の config 内の binary / manifest の絶対パス3箇所だけを相対表記にしたコピー。
`base/` は base worktree、`branch/` は保存済み branch CLI、`corpus/` は計測 corpus を表す。
revision・binary / manifest の digest・機械情報・gate・sample は保持した。

```sh
python3 Tests/Measurement/decode-ab/ab.py \
  --summary Documentation/verification/2026-10-10-decode-performance.jsonl
python3 Tests/Measurement/decode-ab/ab.py \
  --summary Documentation/verification/2026-10-10-decode-performance.jsonl --metric max_rss
```

### base 対 base の揺らぎ

0.1 s 超の61行中59行は best 比が ±2% 以内。`noise-summary.txt` の例外は以下の2行。
±2% は大半の行の目安であり、全行に共通の上限ではない。短い操作では起動時間の揺らぎも大きい。

| 書庫 | 操作 | base best（s） | 同一 base best（s） | 比 |
|---|---|---:|---:|---:|
| small-rar5.rar | sha --sink | 1.9338 | 2.1155 | 1.0940 |
| small.tar.bz2 | list | 0.4773 | 0.4669 | 0.9783 |

## sha --sink の wall time

base best が 0.05 s を超える全52書庫。比は branch / base（小さいほど短い）。
値と比は wall summary の4桁表示をそのまま使い、丸めた秒数から比を計算し直していない。

| 書庫 | base best（s） | branch best（s） | 比（B/A） |
|---|---:|---:|---:|
| mixed-UDBZ.dmg | 5.4497 | 1.5647 | 0.2871 |
| mixed-ULFO.dmg | 0.1559 | 0.0398 | 0.2554 |
| mixed-ULMO.dmg | 0.1004 | 0.0443 | 0.4413 |
| random-aes.7z | 0.3110 | 0.0933 | 0.2999 |
| random-nonsolid.7z | 0.0562 | 0.0575 | 1.0222 |
| random-rar5-blake2.rar | 0.7975 | 0.5960 | 0.7474 |
| random-solid.7z | 0.0565 | 0.0568 | 1.0049 |
| random.multi.tar.xz | 0.0869 | 0.0918 | 1.0565 |
| random.single.tar.xz | 0.2650 | 0.2659 | 1.0033 |
| random.tar.bz2 | 1.3860 | 0.9117 | 0.6578 |
| random.tar.gz | 0.0803 | 0.0819 | 1.0210 |
| random.tar.lz | 5.2415 | 5.2358 | 0.9989 |
| random.tar.lz4 | 0.1416 | 0.0999 | 0.7056 |
| random.tar.zst | 0.0983 | 0.0988 | 1.0051 |
| small-aes.7z | 0.6266 | 0.5992 | 0.9563 |
| small-deflate64.zip | 3.7690 | 2.4416 | 0.6478 |
| small-ditto.zip | 0.3773 | 0.3146 | 0.8337 |
| small-nonsolid.7z | 1.9775 | 1.6726 | 0.8458 |
| small-rar5-blake2.rar | 2.8264 | 1.4041 | 0.4968 |
| small-rar5.rar | 2.1729 | 0.9455 | 0.4351 |
| small-solid.7z | 0.5790 | 0.5813 | 1.0039 |
| small-zip6.zip | 0.3607 | 0.3008 | 0.8339 |
| small.multi.tar.xz | 0.3427 | 0.2933 | 0.8558 |
| small.single.tar.xz | 0.7778 | 0.7835 | 1.0073 |
| small.tar.bz2 | 0.5132 | 0.4326 | 0.8430 |
| small.tar.gz | 0.2685 | 0.2692 | 1.0028 |
| small.tar.lz | 0.6392 | 0.6419 | 1.0043 |
| small.tar.lz4 | 0.5894 | 0.2919 | 0.4953 |
| small.tar.zst | 0.3212 | 0.3072 | 0.9566 |
| text-aes.7z | 1.0051 | 0.9347 | 0.9300 |
| text-deflate64.zip | 3.6460 | 1.1202 | 0.3073 |
| text-ditto.zip | 0.1098 | 0.1097 | 0.9994 |
| text-nonsolid.7z | 0.9152 | 0.9177 | 1.0028 |
| text-ppmd.7z | 5.6753 | 3.7113 | 0.6539 |
| text-ppmd.zip | 5.7060 | 4.3089 | 0.7552 |
| text-rar5-blake2.rar | 1.4574 | 1.2346 | 0.8471 |
| text-rar5.rar | 0.6804 | 0.6636 | 0.9754 |
| text-solid.7z | 0.9195 | 0.9250 | 1.0060 |
| text-zip6.zip | 0.1102 | 0.1108 | 1.0053 |
| text.8frame.zst | 0.2166 | 0.0484 | 0.2236 |
| text.mm.lz | 0.8355 | 0.6969 | 0.8342 |
| text.multi.tar.xz | 0.2261 | 0.1702 | 0.7529 |
| text.single.tar.xz | 1.1243 | 1.1254 | 1.0010 |
| text.tar.bz2 | 0.6400 | 0.4994 | 0.7803 |
| text.tar.gz | 0.1615 | 0.1626 | 1.0072 |
| text.tar.lz | 0.8795 | 0.8817 | 1.0025 |
| text.tar.lz4 | 0.7785 | 0.2122 | 0.2725 |
| text.tar.zst | 0.2655 | 0.2354 | 0.8865 |
| text.txt.bz2 | 3.1779 | 0.3586 | 0.1128 |
| text.txt.gz | 0.1199 | 0.1197 | 0.9986 |
| text.txt.xz | 1.2974 | 0.1325 | 0.1021 |
| text.txt.zst | 0.2168 | 0.1876 | 0.8650 |

## list（open）の wall time

base best が 0.05 s を超え、best 比の差が2%を超える13行を掲載する。
圧縮 tar の staging が主な対象。`random.tar.zst` は0.1 s 未満で、
`small-aes.7z` の median 比は0.9983。これらの小さな増加は確定した性能後退として扱わない。

| 書庫 | base best（s） | branch best（s） | 比（B/A） |
|---|---:|---:|---:|
| random.multi.tar.xz | 0.0695 | 0.0741 | 1.0672 |
| random.tar.bz2 | 1.3691 | 0.9106 | 0.6651 |
| random.tar.lz4 | 0.1253 | 0.0834 | 0.6655 |
| random.tar.zst | 0.0800 | 0.0819 | 1.0241 |
| small-aes.7z | 0.1446 | 0.1481 | 1.0243 |
| small.multi.tar.xz | 0.3178 | 0.2689 | 0.8462 |
| small.tar.bz2 | 0.4776 | 0.4035 | 0.8448 |
| small.tar.lz4 | 0.5694 | 0.2683 | 0.4712 |
| small.tar.zst | 0.2962 | 0.2849 | 0.9616 |
| text.multi.tar.xz | 0.2075 | 0.1522 | 0.7337 |
| text.tar.bz2 | 0.6268 | 0.4746 | 0.7572 |
| text.tar.lz4 | 0.7645 | 0.1955 | 0.2558 |
| text.tar.zst | 0.2513 | 0.2221 | 0.8836 |

## peak RSS

各 process の peak RSS の3回中の最小値（RSS summary の best）。単位は MB = 1,000,000 bytes。
wall の best を出した round と一致するとは限らない。

| 書庫（sha --sink） | base peak RSS（MB） | branch peak RSS（MB） |
|---|---:|---:|
| text.txt.xz | 13.5 | 304.1 |
| text.txt.bz2 | 14.7 | 422.8 |
| text.multi.tar.xz | 261.1 | 372.7 |
| text.tar.bz2 | 299.0 | 502.5 |
| text.8frame.zst | 20.5 | 346.1 |
| text.mm.lz | 20.6 | 298.2 |
| mixed-UDBZ.dmg | 26.2 | 121.9 |

単独 256 MiB の `text.txt.xz` は約14 MB → 約300 MB。3回の branch peak は304.1〜304.2 MB、
単独 bzip2 は422.8〜428.2 MB だった。並列数を増やすと入力・出力・辞書の保持量も増える。
`ReadLimits.parallelDecodeMemory` の既定は物理メモリの50%で、並列 job の保持量を予算内に収める。
RSS は process 全体の値であり、並列 job の予算とは測定範囲が異なる。

## 互換性と既知の性能後退

展開 byte 列・既存の error と ReadLimits を維持する。共通 leaf pool は active logical CPU 数を上限にし、
メモリ不足では並列数を減らすか直列へ戻す。今回の SHA 一致は全56書庫で確認した。

既知の小さな後退は、非圧縮性の `random.multi.tar.xz` の `sha --sink` が
0.0869 → 0.0918 s（1.0565、約5 ms 増加）。`list` も0.0695 → 0.0741 s。
8 → 16 worker ではメモリ帯域が律速になる入力で、並列数を増やしても短縮しない。
この corpus の計測を、全形式・全機械での性能保証にはしない。

## 最終 revision の scheduling 修正と再確認

GitHub Actions の 3 CPU runner で、12 reader の同時復号 test が 6 時間止まった。`sample` では
3本の cooperative thread がすべて結果待ちの `NSCondition` にあり、leaf を実行する thread は0本、
dispatch は `_pthread_workqueue_addthreads` で thread を要求したまま得られなかった。
M4 Max でも reader 数を active CPU 数の2倍（32）にすると同じく止まった。

修正後は、consumer がまず1 poll interval（50 ms、broadcast で早く戻る）待って Dispatch に実行機会を譲り、
結果がまだなく、待つ id の leaf が未開始なら（pool の待ち行列内でも Dispatch へ投入済みでも）
自分の thread で inline 実行する。後から始まった Dispatch の block は本体を省き、実行枠の計上だけを行う。
inline 実行は実行枠と peak に数えない。reader 数 `max(12, 2 × active CPU)` の XZ / bzip2 / zstd / UDIF の
同時読み取り test を追加し、CI の `build-and-test` に90分、`macos-26-runtime` に120分の timeout を付けた。

再確認は同じ MacBook で `7307881` と修正版を比較した。全56書庫の identity gate は一致、
3 round の `sha --sink` best 比は0.95〜1.05で、bzip2 系の5書庫を7 round で測り直した median 比は
0.98〜1.02。上の表の数値は `7307881` の計測のまま使う。
