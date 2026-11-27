# KaitoKit 効率化の調査と提案

## 1. 方針と互換性条件

CPU、open、entry 読み出し、展開、並列復号、関連アプリの利用方法を調査した。第 1〜7 節は初回調査で、公開 API / SPI の戻り値、形式、エラー順を維持する改善を提案した。第 8 節以降に実装と検証結果を記す。

優先するのは、ベンチマーク用の特別な実装ではなく、現在の production source のまま適用できる内部改善である。新しい外部 dependency、C / Rust への全面的な置換、ABI 変更、OS の最低要件変更は提案しない。

## 2. 計測環境と方法

- Apple M4 Max、128 GiB、arm64、macOS 27.3、Swift 6.4.2
- production source を release build し、公開 `ArchiveReader` / `EntryStream` を使う外部 harness を `/tmp` に作成
- 中央値。値はこの環境・入力に対するもので、全機種への一律の倍率ではない
- 実 decode には、同じ 32 MiB（33,554,432 byte）の deterministic payload を ZIP / 7z / XZ / Zstd / Brotli / gzip / bzip2 / RAR にした一式を使用
- 参照には 7-Zip 26.06、bsdtar、RAR を使用。KaitoKit と参照ツールの処理系・設定・I/O が完全に同じではないため、差はおおまかな調査目標とする

## 3. 優先度の高い改善

### E-01: CFB の entry ごとの `ISO8601DateFormatter` 生成をやめる

優先度: **最高（小さな変更で大きな効果）**

`Sources/KaitoKit/Formats/CFB/CFBReader.swift:139` は、作成日時がある storage ごとに `ISO8601DateFormatter()` を生成している。

作成日時の有無だけを変えた、同じ 5,000 entry の Compound File で計測した。

| 入力 | open 中央値 |
|---|---:|
| created = 0（formatter を使わない） | 約 3.0 ms |
| created ≠ 0（5,000 回生成） | 約 490 ms |

さらに、同じ日付を 5,000 回変換するだけの比較では、entry ごとの生成が約 479.8 ms、1 個の formatter の共有が約 4.2 ms だった。open 全体でも、この処理が支配的である。

提案:

- `CFBReader.init` 内に optional の formatter を一つだけ持ち、最初の created 値で初期化して使い回す。reader の操作を直列化する契約なので、共有 cache やグローバル lock は不要である。
- `formatSpecific["created"]` の文字列、created = 0 の扱い、無効な FILETIME の扱いは変えない。
- created / modified / CLSID を含む fixture で公開値を凍結し、5000 件の open を回帰計測に加える。

### E-02: WIM の SHA-1 文字列生成を Foundation format から直接 hex へ変える

優先度: **高**

`Sources/KaitoKit/Formats/WIM/WIMReader.swift:248,271` は、20 byte の hash を `String(format: "%02x", $0)` で 20 回変換して join している。

本文 hash を持つ 5,000 file の stored WIM では、open が約 **64.6 ms** だった。同じ処理を 30 archive 相当で測った分離 benchmark では、現在の Foundation 経路が **1,867.2 ms**、直接 hex の `unsafeUninitializedCapacity` 経路が **5.7 ms** だった。現在の open 時間の大半がこの文字列生成と一致する。

提案:

- 内部の hex helper に置き換え、小文字 40 桁と byte 順を現行どおりにする。
- `ZipCentralDirectoryParser` にも同様の最適化があるため、専用 helper を新たな公開 API にせず、内部で共有する。
- 既存の `formatSpecific["sha1"]` golden と、ADS・hard link・複数 image の値を比較する。
- 同じ `String(format:)` パターンは CFB の CLSID、cpio、StuffIt、LHA にもあるが、まずは実測の大きい WIM と CFB に限定する。全形式一律の書き換えはしない。

### E-03: 展開時の親 directory open を reader / root ごとに再利用する

優先度: **高（多 entry の展開）**

`Extractor` は entry ごとに `ExtractionDirectoryAccess.openRoot` と、親への全成分の open を行う。通常 file は一時 inode を作って検証後に公開する設計を維持したまま、root から同じ親を何度も開いている。

100 directory、各 50 file、合計 5,000 個の空 file を持つ tar の展開は、中央値で **1,139.0 ms** だった。

KaitoFinder の `ExtractionDestination.parentDescriptor` は、同期 worker ごとに直近の親 descriptor を保持している（`../KaitoFinder/KaitoFinder/Extraction/ExtractionDestination.swift:87-93`）。安全性を下げずに同じ考え方を利用できる。

提案:

- `ArchiveReader` が管理する展開 root ごとに、直近の親だけを保持する小さな cache を内部に置く。reader / stream を並列に使わない契約を変えず、worker 間では共有しない。
- root を切り替えたら `extractionRootKey` と hard-link provenance と同時に破棄する。reader の deinit では descriptor を必ず閉じる。
- 親を開く際の一時的な owner mode 復元、final directory metadata、symlink 拒否、file-as-parent、エラー順を変えない。
- cache のヒット率と open 回数も計測し、現行値との交互比較で採用を決める。現時点の 1,139.0 ms は現行実装の値であり、改善後の保証値ではない。

### E-04: PPMd は `decodeSymbol2` とモデル更新だけを対象にする

優先度: **中（大きいが、作業範囲を絞る）**

同じ 32 MiB の 7z PPMd payload で、KaitoKit は約 **2.79 s**、7-Zip は約 **2.32 s** で、この入力では約 20% の差だった。一方で、既存の他の純 Swift codec は参照を上回るものが多く、PPMd だけを特別扱いして調べるのが適切である。

`sample` による release process の内訳:

- `decodeSymbol2` を中心とする記号選択: **約 54%**
- `updateModel` / `appendState` / suballocator: **約 27%**

対象箇所:

- `Sources/KaitoKit/Codecs/PPMd/VariantH/PPMd7Model.swift:398-470`: 全 state の unmasked scan と、選択時の二度目の走査
- 同 `:1322-1375`: 初回 state 追加と state 拡大
- 同 `PPMd7Suballocator.swift:104-135`: free-list と frontier の処理

提案:

1. `decodeSymbol2` の unmasked index と frequency を一度の走査で集め、threshold 後の選択を byte load なしで行う。最大 256 件の bounded storage を使い、heap への一時配列は避ける。
2. `appendState` の初回・拡大パスで、context / state block の検査を一箇所にまとめ、完了後の state 書き込みを局所化する。
3. suballocator では、既に検証した class / unit の範囲をそのまま使い、`swift_beginAccess` と境界検査を繰り返さない。
4. 現在の checked span と、allocator が動かない期間の pointer 利用は維持する。安全性を落とした unchecked な全面置換や C 化は行わない。
5. 実装候補ごとに、SHA-256、返却済み prefix、error の種類と順序を凍結した baseline と照合し、PPMd の実コーパスと ASan で差分を確認する。

### E-05: bzip2 の並列数は飽和点まで絞り、過剰な worker を増やさない

優先度: **中（planning の改善）**

同じ 32 MiB の bzip2 payload での結果:

| decodeThreads | 中央値 |
|---:|---:|
| 1 | 約 418 ms |
| 2 | 約 319 ms |
| 4 | 約 288 ms |
| 8 | 約 295 ms |
| 16 | 約 294 ms |

並列化は有効だが、この入力では 4 前後で飽和している。7-Zip の約 260 ms との差は約 11% で、大規模な書き換えよりも、scan / scheduling / 小 job の調整が適切である。

提案:

- block 数・block サイズ・保留出力を見て、予想される並列利益が scheduling cost を上回る場合だけ worker を増やす。
- process 全体の `LeafDecodePool` は維持し、各 reader が大量の先行 job を作って他の reader を遅らせないようにする。
- 「全環境で 4 に固定」はしない。他の CPU、他の block 構成、実 tar staging でも交互測定する。

## 4. 現状を大きく変えなくてよい部分

同じ 32 MiB の payload では、参照実装を上回る、または近い結果が多かった。これらを一律に最適化対象へしない。

| 形式 | KaitoKit | 参照 | 評価 |
|---|---:|---:|---|
| ZIP Deflate | 約 3.3 ms | 7zz 約 22.0 ms | 現行経路を維持 |
| 7z LZMA2 | 約 21.2 ms | 7zz 約 29.6 ms | 現行経路を維持 |
| XZ | 約 22.3 ms | 7zz 約 32.0 ms | 現行経路を維持 |
| RAR5 | 約 11.5 ms | rar 約 25.2 ms | 現行経路を維持 |
| 7z Zstandard | 約 6.1 ms | bsdtar 約 16.4 ms | 現行経路を維持 |
| Brotli | 約 19.0 ms | — | 現時点では優先度を下げる |

7-Zip の zstd-in-7z は、この環境の 7zz では decode できないため、参照には bsdtar を使った。Brotli は参考値の比較対象を確定しなかったため、現行値だけを記す。

また、bzip2 の `decodeThreads = 4` と `16` の差は小さく、無条件に並列数を上げる変更は効かない。公開 option の意味を変えず、planner だけを改善すべきである。

## 5. 関連プロジェクトへの提案

### KaitoFinder

- `ExtractionDestination` の親 descriptor cache は有効なので、KaitoKit 側の cache と設計をそろえると、二重の open を双方で減らせる。
- `ReaderOptions` で無制限にしている出力上限は、性能と可用性の両面で、hardware / destination に応じた有限値にする。大きい入力を無制限に読めることより、途中までの大量の不要な decode / write を止める方が待ち時間を減らせる。
- 並列 worker 数は、hardware の論理 CPU 数だけでなく、出力先の I/O、実 block 数、メモリ予算にも合わせる。

### GyoshukuKit

- SPI（`ZipRawLayout`、`SevenZipEditLayout`、`TarEditLayout`、`LHARawLayout`）を変えず、KaitoKit 側の内部改善をそのまま利用できる。
- updater が `.max` にしている出力上限を host から渡せるようにすると、編集時の不要な全量 decode / copy を早期に止められる。
- 圧縮 tar / 7z / LHA の raw layout を変えないため、E-01〜E-03 は既存の writer と互換のまま適用できる。

## 6. 実施順と受け入れ条件

1. **CFB / WIM**: 小さな変更で、公開値を変えずに open を大幅に短縮できる。
2. **展開の parent cache**: 全 hardening、symlink pivot、hard link、resource fork、restrictive umask、失敗時の cleanup とエラー順を維持する。
3. **PPMd**: 凍結した baseline との出力・prefix・error 一致を必須とし、2 か所だけを最適化する。
4. **bzip2 planner**: 多機種・多 block 構成の結果を見て、飽和点を調整する。

全項目で、次を受け入れ条件とする。

- `swift test`（KaitoKit / Compat / public value golden / SPI import）が成功
- 変更前後の entry・digest・error・返却済み prefix が一致
- ASan / UBSan の圧縮 payload 変異で crash・hang・診断がない
- framework / dynamic product の build と、GyoshukuKit の SPI 利用が壊れていない
- 同一 release 条件での交互計測を行い、今回の入力だけを理由に他形式・他機種の性能を後退させない

## 7. 今回の検証で得られた追加の根拠

- 26 種の圧縮 seed・500 packed-payload 変異、および全形式 53 seed・5,000 変異で、crash / hang / sanitizer finding は 0。
- 全 test は KaitoKitTests 2,102 tests、63 skipped、0 failures、Compat は 34 tests、0 failures。StuffIt X JPEG は 18 tests、1 skipped、0 failures、実コーパス 292 件一致。
- CFB / WIM / cpio / 多数展開の測定は、最適化候補を含まない現行 production source と公開 API で実施した。
- PPMd の `sample` は、ライブラリの推測ではなく、実際の `ArchiveReader.read` からの call graph を示している。

したがって、効率化は「安全を犠牲にした全面改修」ではなく、**実測で支配的な少数の経路を、既存の安全性と接続性を保ったまま局所改善する**方針が最も効果的である。

## 8. 初回レビューでの実装と測定

- CFB は作成日時があるentryの間だけ `ISO8601DateFormatter` を一つ再利用する。created / modified / CLSID の既存の公開値は変更していない。
- WIM はSHA-1を小文字40桁の直接hexへ変換する。stored / ADS / 複数image / 圧縮resourceの既存の値とdigestを維持する。
- 展開ではreaderごとにroot直下の親directoryを一つだけ再利用する。rootと親のdevice / inode / generation、種別、modeを照合し、symlink pivotやroot差替え時は従来のopenへ戻す。5,000個の空fileでは再確認の中央値が928.3 msから870.7 msだった。
- PPMdの候補領域方式と詰めた候補列は、mask修正後の出力一致を確認したが、それぞれ約3,111 ms / 3,799 msとなり、元の約2,832 msより遅かったため採用しなかった。bzip2のzero初期化回避も、paired測定で有意差がなかったため採用しなかった。試験的な差分は残していない。
- GyoshukuKitの `prefersSpeed` のZstandardは、同じ書庫のbyte列を保ったまま、単一実行の約37 msから8 threadsの約13 msへ並列化できた。新しいGPU / NPU実装は追加していない。
- [Mac構成別の性能方針](hardware-performance.md) に、M1・M4・M5・M6・Intelと将来の多level構成に対する計画を記録する。

## 9. 最終候補の採否

PPMd `decodeSymbol2` の直接選択loopは、7回交互の従来binaryとの比較で、中央値が2,814.29 msから2,813.20 msだった。約0.04%の差にとどまり、実装上の利点を確認できなかったため採用しなかった。mask済み候補を保持する方式、候補を詰める方式、直接loopのいずれも最終diffには残していない。

GyoshukuKitの祖先directory反復をbyte単位へ変える候補は、全試験名で従来と同じprefixを確認し、10,000候補のoracleも成功した。しかし同じ `testWriterAgreesWithRealWriterForTenThousandCandidates` を保存した旧・新test bundleで実行すると、旧版が5.389秒、変更版が6.621秒と約23%悪化したため採用しなかった。旧版の全testが長いことと、この変更の速度は別の問題であり、他のtest時間を改善の根拠にしていない。

共有decode予算は、stored propertyを `ReadLimits` に追加する方式から、task-scopedな `ParallelDecodeMemoryBudget.$active` へ改めた。これにより既存structのlayout・initializer・Equatableを変えずに、taskと子taskのdecoderが予約を共有できる。scope外は従来のper-decoder動作である。

## 10. 最終版の実測と全検証

最終版をrelease buildし、外部harnessから公開APIを使って測定した。5,000 entryのCFBは、作成日時ありのopen中央値が **8.563 ms**、作成日時なしが **3.062 ms** だった。当初の作成日時あり約490 msに対して、formatter再利用が有効だった。5,000 fileのWIMは **4.279 ms** で、当初の約64.6 msから短縮した。

5,000個の空fileを持つ同じtarでは、展開の中央値が **864.846 ms** だった。変更前の再確認値928.291 msから約6.8%短い。全5回でfile数と内容を確認した。

最終検証は、KaitoKit 2,115 tests・63 skipped・0 failures、Compat 34 tests・0 failures、GyoshukuKit 951 tests・55 skipped・0 failures、universal framework生成、500件のASan / UBSan変異（crash / hang / finding 0）、DocumentationConsistency 11 tests、MigrationGuideSnippetCompile 4 testsが成功した。PPMd、bzip2、path処理の候補は、実測で効果がない、または後退したため全て差分を残さず撤回した。E-05 の bzip2 並列数は、この初期化コストの比較とは別の検討項目である。4 worker 付近での飽和は単一機種・単一入力での測定なので、多機種での測定までは固定の上限を設けない。


## 再レビューでの照合

M4 Max の release build で各 5,000 件の入力を 9 回ずつ開いたところ、中央値は作成日時付き CFB が 7.51 ms、WIM が 3.74 ms だった。ディレクトリ再利用は空ファイル 5,000 件を同じ順で展開し、旧版と現行版を 4 回ずつ交互に測定した。中央値は 943.8 ms と 937.9 ms で、各回の出力名・件数・サイズが一致した。この再測定ではテストも並行しており、ディレクトリ再利用の差は測定間のばらつきより小さい。

同じ 32 MiB の入力を 10 種の書庫・圧縮方式から復号し、いずれも release CLI の SHA-256 が元データと一致した。


## 残る候補の個別検証（2026-11-27）

PPMd Variant H の `appendState` では、モデル更新時に確保した状態領域とコンテキストを再検査してから、状態数・合計頻度・参照位置をまとめて書き込むようにした。Swift の release ビルドで実行順を入れ替え、各組の所要時間の差を比較した。32 MiB の入力は 12 組中 11 組で短縮し、短縮率の中央値は 1.93% だった。Swift ソースでは 0.86%（12 組）、PNG では 1.44%（6 組）だった。7z と RAR4 を含む 6 書庫で出力ハッシュの一致を確認した。採用候補単体の ASan 付き 11 試験では、生成した 38 書庫を含めて凍結したデコーダーと出力、エラーまでに返したバイト列、エラーが一致した。個別に試した suballocator の変更は各入力で 0.57〜0.88% の差だったため保留した。以前の `decodeSymbol2` 候補の採否は第 9 節に記録している。

M4 Max の release CLI で、bzip2 の入力と並列数を変えた。各行は、並列数の実行順を巡回した 5 回の中央値（ミリ秒）で、書庫を開いて全項目を復号する時間を含む。各並列数で SHA-256 を照合した。

| 入力 | 1 並列 | 2 並列 | 4 並列 | 8 並列 | 16 並列 |
|---|---:|---:|---:|---:|---:|
| 64 KiB、1 ブロック | 1.12 | 1.20 | 1.15 | 1.31 | 1.16 |
| 4 MiB、小ブロック（圧縮レベル 1） | 19.30 | 13.11 | 8.78 | 5.46 | 5.51 |
| 32 MiB、圧縮レベル 9 | 375.04 | 291.61 | 259.17 | 257.45 | 260.40 |
| 8 MiB のファイルを含む tar.bz2 | 33.86 | 33.74 | 33.87 | 33.53 | 34.09 |

小ブロックが多い入力では 4 から 8 並列でさらに短縮した。書庫全体に 4 並列の上限を設けるとこの入力で後退する。現行のスキャナは見つかったブロックだけを投入し、待機数と先読み出力を worker 数・メモリ予算に収める。今回の測定から新しい固定閾値は採用しなかった。

GyoshukuKit は編集時の読取上限、Zstandard の速度優先設定、電力方針・並列数ごとの出力一致、パス 1 万件を含む関連 18 テストが成功した。速度優先 Zstandard と祖先ディレクトリの反復方法の旧・新比較は、第 8・9 節の測定結果を参照。
