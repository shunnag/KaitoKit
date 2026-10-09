# 2026-09-29 圧縮 tar の staging の並列復号（xz block 並列、bzip2 block 単位）の検証記録（KaitoKit）

2026-10-10 P1 / D1 で単独 `.xz` / `.bz2` stream にも適用し、固定 8 worker / 512 MiB 上限を
CPU 構成・電力方針・物理メモリからの自動値と process 共通 leaf pool に置き換えた。
以下の計測と「残る手」は 2026-09-29 時点の記録。現在の設定は [組み込み](../embedding.md#組み込みの注意) を参照。

KaitoAccelLab（GPU / NPU の検証、https://github.com/shunnag/KaitoAccelLab）が「CPU 側に残る伸びしろ」として挙げた項目を本流で検証し実現した記録。
方針は Fable advisor と相談して決め、実装は Codex（worktree ごとに独立 thread）、計測・審査・文書は orchestrator。

## 対象と結果

| 項目 | 結果 | PR |
|---|---|---|
| xz の block 並列復号（`ParallelXZDecompressor`） | 実施。tar.xz staging が 11 block で 5 倍、GyoshukuKit の 18 block で 6.7 倍。出力と地図は直列と同一 | #41 |
| 単一 stream bzip2 の block 単位並列（`Bzip2BlockScanner`） | 実施。bsdtar の tar.bz2 staging が 5.5〜6 倍。出力と地図は直列と同一 | #42 |
| libcompression / zlib の呼び出し粒度 | 据え置き。全 streaming codec は既に 256 KiB 単位で、前提が誤りだった。残る小さな読みは `XZResourceValidator` の 1 KiB `ByteReader`（79 MB の xz の走査で 1.3 ms、復号 2.1 s の 0.06%）、`LZ4FrameInput` の 4 byte 読み、UDIF / pbzx / decmpfs / MSZIP の chunk ごとの decoder 初期化で、いずれも 1% 未満 | なし |

## 計測（M4 Max 12P+4E、macOS 27.2、release `kaito`、5 round の中央値、base と branch を交互に実行）

corpus: KaitoAccelLab と同じ text256 / random256 / small（5 万 file）/ headers。`list` は書庫を開く時間（tar.* では staging = 展開全体を含む）、`sha` は全 entry の SHA-256。

noise floor（main 対 main）: 20 書庫 × 2 操作 = 40 行で 0.964〜1.022。

### xz（feat/parallel-xz、base = main bf33753）

| 書庫 | block | list base → branch（比） | sha base → branch（比） |
|---|---|---|---|
| text.tar.xz（xz -6 -T0） | 11 | 2018 → 409 ms（0.20） | 2121 → 510 ms（0.24） |
| text-gk.tar.xz（GyoshukuKit） | 18 | 1922 → 289 ms（0.15） | 2041 → 389 ms（0.19） |
| small-gk.tar.xz（GyoshukuKit） | 41 | 1327 → 399 ms（0.30） | 2254 → 1338 ms（0.59） |
| random.tar.xz（xz -6 -T0） | 11 | 237 → 73 ms（0.31） | 333 → 170 ms（0.51） |
| text9.tar.xz（xz -9 -T0、192 MiB block） | 2 | 1.00（直列に落ちる） | 1.00 |
| text1.tar.xz（xz -T1） | 1 | 0.99（直列に落ちる） | 1.00 |
| 他 15 書庫 | | 0.98〜1.01 | 0.98〜1.02 |

参考: `xz -d -T16` は text.tar.xz を 0.23 s、`-T1` で 1.89 s。`kaito sha` は tar の解析・temp file への staging・SHA-256 を含む。
peak RSS（`/usr/bin/time -l`、`kaito sha`）: text.tar.xz 82 → 351 MiB（W = 8、job = 24 MiB 出力 + 7.5 MiB 圧縮、予備 2 job、設計上限 512 MiB）、text9.tar.xz 142 → 142 MiB（直列）。

### bzip2（feat/parallel-bzip2-blocks、base = main bf33753）

| 書庫 | list base → branch（比） | sha base → branch（比） |
|---|---|---|
| text.tar.bz2（bsdtar、単一 stream、900k block × 約 300） | 5840 → 958 ms（0.16） | 5809 → 1055 ms（0.18） |
| 他 20 書庫 | 0.99〜1.03 | 0.99〜1.01 |

参考: `bzip2 -d` は 5.58 s（直列）。peak RSS: 90 → 312 MiB（W = 8、run ≤ 9 block、走査の窓 4 × 8 MiB + 1 MiB）。

## 検証

- 出力の同一性: release CLI の `kaito sha` を main と branch で比較（xz: 6 書庫、bzip2: 1 書庫）。すべて同一。
- テスト: Codex sandbox で全 suite（xz: 1,591 tests、bzip2: 1,582 tests、0 failures）。新規テストは直列との差分比較（生成 fixture と `xz -T0 --block-size`、GyoshukuKit の header だけの block を持つ fixture、連結 stream、単一 block、予算で W < 2 / W = 2、切断、check 欄の改変、bit 位置の偽 magic、地図の同一性）、worker 数と保持量の上限、入力の読み回数、deinit / 取消しの 2 s 以内の放棄。
- ThreadSanitizer: 下記。
- 直列 `XZDecompressor` / `Bzip2Decompressor` と公開 API は不変。GyoshukuKit / KaitoFinder は変更なし。
- GyoshukuKit（隣の KaitoKit を path 依存で解決）の全 suite を取り込み後の main に対して実行: 589 tests（19 skipped）、0 failures。tar の区切りの地図を使う圧縮 tar の編集経路が新しい復号器で通る。

ThreadSanitizer（`swift test --sanitize=thread`）: ParallelXZ の 14 tests、ParallelBzip2 の 10 tests とも 0 failures、TSan の警告なし。

### 両方を取り込んだ main（1b7b34a）対 取り込み前（bf33753）

| 書庫 | list（比） | sha（比） |
|---|---|---|
| text.tar.xz | 1960 → 406 ms（0.21） | 2052 → 505 ms（0.25） |
| text-gk.tar.xz | 1905 → 287 ms（0.15） | 2009 → 385 ms（0.19） |
| small-gk.tar.xz | 1348 → 396 ms（0.29） | 2253 → 1324 ms（0.59） |
| random.tar.xz | 238 → 74 ms（0.31） | 334 → 171 ms（0.51） |
| text.tar.bz2 | 5534 → 949 ms（0.17） | 5642 → 1041 ms（0.18） |
| text1.tar.xz / text9.tar.xz（直列に落ちる） | 0.99 / 1.00 | 1.00 / 1.00 |
| 他 14 書庫（zip / 7z / rar / lzh / gz / zst / br） | 0.91〜1.03 | 0.98〜1.01 |

0.91 は headers.zip の list（14.0 → 12.7 ms）、1.03 は text.7z の list（4.2 → 4.3 ms）で、いずれも十数 ms 以下の操作の noise。

main での全 suite: 1,562 tests（54 skipped）、0 failures。

## 判断の記録

- xz は走査ではなく検証済みの block 表から仕事を作るので、bzip2 の「偽の境界からの復帰」は持たない（advisor の指摘）。
- job は連続 block の run（出力 ≤ 16 MiB）にまとめる。GyoshukuKit が大きな member の前に置く 512 byte の header だけの block を単独の job にしないため。
- 合成 stream では元の Index の CRC32 が検査されないので、最後の job が確かめる（Codex の指摘）。
- bzip2 の復帰は stream の byte 境界の始点から直列で読み直し、既出の prefix を捨てる（libbz2 は bit 位置から再開できない）。手作業で block を bit 単位で切り出し `BZh9` + block + EOS + block CRC に組み直したものを `bzip2 -d` が受け付けることを、実装の前に text.tar.bz2 で確かめた。
- 途中で GPU が 4 KiB block の LZ4 で CPU を上回ったように見えた計測（KaitoAccelLab）は、CPU 側の lock 付き動的分割の崩れだった。同じ罠を避けるため、ここでは常に main と branch を交互に走らせ、noise floor を先に取った。

## 残る手

- 単独の `.xz` / `.bz2` の entry stream、pbzx、UDIF の xz chunk、ZIP method 95、xar は直列のまま（有界の先読みで同じ decoder を使えるが、この round では staging に限った）。
- worker 数の上限 8 は bzip2 の設計を踏襲した。12P core の機械では 12 まで上げる余地がある（保持量の上限と一緒に決める）。
- KaitoKit の release tag と KaitoFinder の依存更新は利用者の判断。
