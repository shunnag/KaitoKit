# RAR5 block 並列復号 / RAR5 block-parallel decoding

## 日本語

### 実装

`RAR5Decoder` は、圧縮入力が 64 KiB 以上、解決済みの thread 数が 2 以上で、
並列のメモリ予算に空きがあるときだけ block 並列の経路を使う。
block header の checksum・size・table flag・last flag を先に調べ、
最大 2 MiB の圧縮入力を一つの batch にする。各 block は独立した表を持つ必要がある。

`LeafDecodePool` の葉と consumer が、それぞれ専用の Huffman 表で符号を読み、
literal run と 8 byte の match / repeat token にする。距離の履歴・直前の長さは
token に解決せず、consumer が窓へ直列に適用するときに更新する。
表の解析は既存の関数を共有する。consumer も従来どおり block に入る時点で
表を読み直すので、後続の solid member に渡す表と検査の順序を保てる。

batch 内の全 worker が終わってから token を使う。consumer は未開始の葉を自分で
実行でき、worker は他の葉を待たない。呼び出しが戻る前に全葉を回収するので、
読み出しの放棄で入力 pointer を参照する background job は残らない。
member の先行復号 worker では block 並列を有効にしない。
reader の `resolvedDecodeThreads` を渡し、既存の自動 thread / 電力方針をそのまま使う。

追加の領域は、既存の入力（再利用時は保持 capacity）と窓を `parallelDecodeMemory` から差し引いた残り、
または 32 MiB の小さい方で制限する。worker ごとの小辞書と表の領域を先に数え、
token は block ごとに最大 4 MiB、圧縮 size の 16 倍（下限 64 KiB）まで確保する。
literal run をまとめてコピーし、match は従来の検査と窓コピーを使う。
1 thread と小さな member は並列のメモリ予算も解決しない。

次の場合は、その block の先頭から member の残りを従来の loop で処理する。

- 表を継承する block、filter を含む block、token で表現できない距離。
- 壊れた表・符号、token 領域の不足、並列のメモリ予算の不足。
- 2 block をまとめられない場合、2 MiB を超える圧縮 block。

filter record の token 化と表を継承する block の grouping は今回見送った。
filter の状態は元の実装だけが扱う。先読みで見つけた誤りは公開せず、
従来の loop が同じ入力位置で error と部分出力を決める。
LZ の意味的な検査は token の適用時に行い、失敗した read が書いた buffer も照合した。

変更ファイル:

- `Sources/KaitoKit/Codecs/RAR/RAR5Decoder.swift`: batch・token・直列適用・表 parser の共有。
- `Sources/KaitoKit/Formats/RAR/RAR5Reader.swift`: 解決済み thread 数の受け渡し。
- `Tests/KaitoKitTests/RAR/RAR5DecoderTests.swift`: 4 件の同値性・予算・reader 検査。
- `CHANGELOG.md`: Unreleased の変更項目。
- この検証記録。

### 計測

Apple M4 Max（12 performance + 4 efficiency core、128 GB）、release、warm cache。
`kaito sha <archive> --sink --threads 1|auto` を毎回別 process で起動し、
warm-up 1 回の後の 5 回の最短 wall time。変更前と変更後は同じ compiler / flags。最終の全 test が終わってから、各回の A/B の順を交互にして計測した。
discovery の元の書庫は見つからなかったため、次の再生成 corpus を使った。

- 72 枚の JPEG、合計 47,348,396 byte（45.15 MiB）。768 × 1024 の決定的な
  RGB noise を ImageIO の JPEG quality 0.65 で保存し、RAR 7.23 の
  `-ma5 -m3 -s` で圧縮。書庫は 47,253,863 byte。
- 128 MiB の単一 text。既存の KaitoKit 計測 corpus の 16 MiB text を 8 回連結し、
  `-ma5 -m3` で圧縮。書庫は 18,930,016 byte。

| corpus | before, 1 thread | after, 1 thread | before, auto | after, auto | auto speedup |
|---|---:|---:|---:|---:|---:|
| solid JPEG | 233.23 ms | 233.28 ms (+0.02%) | 232.88 ms | 58.12 ms | 4.01× |
| single text | 184.84 ms | 184.92 ms (+0.04%) | 183.86 ms | 93.76 ms | 1.96× |

最初の計測でも auto は JPEG 62.11 ms、text 96.43 ms で、改善は noise より十分大きい。
`getrusage(RUSAGE_CHILDREN)` を測定ごとに独立した Python process から読み取った
peak RSS は、JPEG が before / after-1 / after-auto = 46.41 / 46.34 / 55.00 MiB、
text が 61.92 / 61.89 / 76.38 MiB。

書庫 SHA-256:

- JPEG: `e7fb2e3ad9800e04a52fb828931c7b999fbb1587787a11b92e4d70f4ffb3d9d7`
- text: `69a0f3b8ee33d0360372f0ac3056c8893fd6c45bfc114893bab19782ce5f599d`
- 連結前の 16 MiB text: `35b6b85eff0d016c2119281779b8fc0a0b19b464c48e91e213271b01ebfd8e55`

### 検証

- Swift 6 strict concurrency の release build が成功。
- 全 test は 2,042 件、skip 58、失敗 0（直列実行、1,331 秒）。
  保持 capacity の最終修正後も `--parallel --num-workers 2` で全 2,042 件を再実行し、終了 status 0、失敗 0。
  RAR test は 327 件、skip 11、失敗 0。
- decoder の 21 test が成功。追加の 4 test は、literal・match・repeat・solid の引継ぎ、
  表の継承、filter、破損・切詰め、宣言 size、1 / 4,099 / 65,536 byte の読み出し、
  thread / memory 予算と再利用入力の保持 capacity、生成した solid / 大きな独立 member と reopen を検査する。
- raw stream の決定的な破損・切詰め 360 case で、直列 / 並列の返却 byte、error、
  失敗 read の buffer が一致。
- checked-in RAR fixture と password の 168 case で、変更前 / 変更後の 1 / auto の
  CLI stdout・stderr・終了 status が一致。
- 計測書庫は before-1 と after-1 / 3 / 16 / auto の entry SHA が一致。
  73 member の SHA は圧縮前の原本にも一致。
- `Scripts/fuzz/run-mutants.sh`: checked-in RAR seed 56 個から 200 mutant、
  block 並列を使う synthetic RAR5 seed から payload 変異を必須にした 300 mutant。
  ASan / UBSan で合計 500 件、crash 0、hang 0、sanitizer finding 0（timeout 15 秒）。

検証 command は `swift build -c release` / `swift test` に
`--disable-sandbox --build-system native --scratch-path <scratch>` を付けた。
release は両方に `-Xswiftc -gnone` を付けた。module cache と `TMPDIR` も scratch に向けた。
default の swiftbuild は sandbox 外への書込みと dSYM 生成で失敗したため、native を使用した。
fuzz script は scratch の `swift` wrapper で build system だけ native に指定した。
最初の全 test は `/private/tmp` と `/tmp` の URL 比較で失敗したため中断し、
同じ実体を指す `TMPDIR=/tmp/kk-rar5par` でやり直した。製品側の path 処理は変更していない。

第三者 decompressor の source は一切参照していない。RAR は fixture の生成にだけ使った。
scratch は `/private/tmp/kk-rar5par` 内、観測した空き容量は常に 25 GiB 以上。
scratch の観測最大は約 2.1 GiB。検証終了後に scratch を削除済み。
commit は作成しない。


### 最終 wall time の全 sample（ms）

| corpus | build | threads | samples |
|---|---|---|---|
| solid | before | 1 | 234.36, 233.23, 233.46, 233.48, 233.83 |
| solid | before | auto | 235.61, 233.59, 232.88, 233.10, 232.89 |
| solid | after | 1 | 233.80, 234.38, 233.34, 233.51, 233.28 |
| solid | after | auto | 58.92, 59.59, 58.12, 58.56, 58.70 |
| text | before | 1 | 185.41, 185.72, 184.84, 185.19, 185.38 |
| text | before | auto | 183.86, 185.59, 183.95, 184.71, 184.76 |
| text | after | 1 | 185.78, 185.05, 184.96, 184.92, 184.92 |
| text | after | auto | 94.68, 96.31, 93.76, 94.16, 94.69 |

## English

RAR5 now decodes self-contained Huffman blocks in bounded batches through
`LeafDecodePool`, then applies literal runs and match/repeat tokens serially.
The existing serial loop still owns filters and handles inherited tables,
unsupported token distances, malformed blocks, and budget exhaustion. Worker
errors remain speculative; the serial decoder determines the observable error
and partial output. Solid history and final Huffman tables retain their existing
ownership and validation order.

The reader passes its existing resolved thread count, including power policy.
Member-prefetch workers do not start nested block jobs. A batch contains at most
2 MiB of compressed input; worker storage and tokens fit the remaining
`parallelDecodeMemory`, capped at 32 MiB. Each block has at most 4 MiB of tokens.
All jobs finish before the synchronous call returns. Filter tokens and grouping
blocks that inherit tables were deferred; those members retain serial decoding
from the fallback block onward.

On an M4 Max, best of five separate warm-cache release processes, auto decoding
improved from 232.88 to 58.12 ms for 72 solid JPEG pages (4.01×), and from 183.86
to 93.76 ms for one 128 MiB text member (1.96×). Single-thread changes were
+0.02% and +0.04%. These are regenerated corpora; the original discovery archives
were unavailable. Peak RSS increased from 46.41 to 55.00 MiB for JPEG and from
61.92 to 76.38 MiB for text.

Validation includes byte/error/failing-buffer equivalence, solid continuation,
reader thread and memory limits, generated large-member/solid round trips,
360 raw mutation comparisons, 168 fixture/password CLI comparisons, source SHA
checks for all 73 benchmark members, and 500 ASan/UBSan mutants with zero crashes,
hangs, or sanitizer findings. The final RAR run passed 327 tests (11 skipped), with zero failures.
The full serial suite passed 2,042 tests (58 skipped), with zero failures.
The final capacity-accounting change also passed a complete 2,042-test rerun
with two test workers and exit status zero. Final A/B timing alternated run order
after test processes had stopped.
The same compiler flags were used for both benchmark builds. Native SwiftPM was
selected to keep build artifacts within the sandbox; test temporary paths use
the `/tmp` spelling of the required scratch directory. No third-party
decompressor source was consulted. Scratch was deleted after verification. No commit was created.
