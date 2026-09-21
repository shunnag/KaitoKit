# ZIP の Shrink / Reduce / Implode（2026-09-21）

環境: macOS 27.2 / Apple Silicon / Info-ZIP UnZip 6.00（Apple 版、`/usr/bin/unzip`）/ 7-Zip 26.03 `7zz` /
deark 1.7.3（Homebrew、いずれも黒箱 reader）。

## 実装と範囲

- `ZipReader.makeDecompressor` の method 1（Shrink）、2〜5（Reduce factor 1〜4）、6（Implode）を
  `Sources/KaitoKit/Codecs/ZipLegacy/ZipLegacyDecompressors.swift` に接続した。method 名は `shrink` /
  `reduce1`〜`reduce4` / `implode`。従来は `unsupportedMethod("1")` などで拒んでいた。
- 3 つの stream には終端記号が無い。中央 directory の宣言サイズまで出力して止め、`EntryStream` の CRC-32 と
  宣言長の照合で検証する。宣言サイズが無い entry（復旧時）は `malformed`。
- Shrink: 9〜13 bit の動的 LZW。`256,1` で code 幅を 1 増やし、`256,2` で葉（他 code の prefix になっていない
  code）をすべて解放して最下位から再利用する。表が満杯のときは登録を省く。
- Reduce: S(255) から S(0) の順に 6 bit の個数 N と N 個の 8 bit を読む follower set、B(N) = N−1 を表す最小 bit 数、
  DLE（144）の状態機械（`DLE 0` = literal 144、`DLE V [C] D` = 長さ L(V)+3（L が最大なら +C）、距離
  (V >> (8−factor))·256 + D + 1 の copy）。窓 4 KiB。出力の先頭より前を指す copy は 0 を返す。
- Implode: flag bit 1 = 8 KiB 窓（距離下位 7 bit）/ 4 KiB 窓（6 bit）、bit 2 = literal 木あり（最短 match 3）/
  なし（2、literal は 8 bit）。木は §5.3.7 の「(個数−1)<<4 | (長さ−1)」の byte 列から §5.3.8 の手順で code を作り、
  16 bit を反転して LSB 先頭で照合する。長さ symbol 63 の後は 8 bit の追加長。
- 上限: `maxEntrySize` は ZIP 全体の既存検査（中央 directory の宣言サイズ）で掛かる。3 decoder の状態は
  Shrink 8192 entry の表、Reduce 4 KiB 窓、Implode 8 KiB 窓で固定。
- CLI の `list` / `sha`、Compat の method 名は既存の経路のまま。fuzz seed（`Scripts/fuzz/make-compressed-seeds.sh`）に
  shrink / reduce4 / implode の fixture を加え、`mutate.py` の packed-range locator が method 1〜6 を含むようにした。

## 出自

PKWARE APPNOTE.TXT 6.3.10 §5.1〜5.3（`inbox/zip-legacy/APPNOTE.TXT`、SHA-256
`0b993022a7d320a0bf704e6980bea36fafd17a6066ab994db0a0c16278a50cd6`）の散文だけを実装入力にした。
Info-ZIP / 7-Zip / deark / PKZIP の実装 source は開いていない。APPNOTE が書いていない点は次のとおり黒箱で確定した。

| 点 | 確定した内容 | 方法 |
| --- | --- | --- |
| bit 順 | byte 内 LSB 先頭（Deflate と同じ） | 自作 encoder の出力を unzip / 7zz / deark が受理 |
| 終端 | 記号無し。宣言サイズで止める | 同上（末尾の余り bit は無視される） |
| Shrink の部分クリアと直前 code | 直前に出した code も葉なら解放し、次の code で「直前 + 先頭 byte」を最下位の解放 code に登録する（prefix は解放済み code を指す） | encoder 3 案（A: この規約、A2: 直前 code を保護、B: クリア直後は登録しない）の stream を 3 reader に渡し、A だけ 3 者とも CRC 一致、A2 / B は 3 者とも拒否（`experiments/clear_experiment.py`、70 KB、3 回のクリア） |
| Reduce の follower set の並び | S(255) から順、個数 6 bit、値 8 bit、index は B(N) bit | deark が受理 |
| Reduce の B(1) | 要素 1 個の set の index は 0 bit ではなく 1 bit（B(N) = max(1, N−1 の bit 数)） | APPNOTE の「N−1 を表す最小 bit 数」は 0 とも 1 とも読める。size 1 / 2 の set を含む stream を 0 bit / 1 bit の両方で作り、deark は 1 bit の方だけを受理（size 1 の使用 206 回、size 2 の使用 435 回）。最初の自作 encoder は size ≤ 2 の set を作らないことでこの点を避けていたので、fixture を size 1 / 2 を含むものに作り直した（reduce1〜4.zip に size 1 の set が各 4〜249 個） |
| Reduce の copy | deark は距離より長い copy（自己参照）を拒み、距離 256 未満の 3 byte copy は V=0 が literal DLE と衝突して符号化できない | deark の拒否で判明。fixture の encoder はこれらを避ける |
| Implode の木 | §5.3.8 の code を 16 bit 反転して LSB 先頭で読む | unzip / 7zz / deark が受理 |

Shrink の規約 A は decoder 側では「直前 code が解放済みでも新 code の prefix として参照だけ残す」ことになる。
その entry は復元できない（prefix はやがて別の文字列に再割り当てされる）ので、整合した encoder はその entry を
出さない。最初の自作 encoder はこれを守っておらず、2 MB の単語列（クリア 149 回、解放済み prefix への登録 51 回）で
unzip / 7-Zip / deark / KaitoKit の 4 者がそろって失敗した（unzip と deark は同じ誤った出力、7-Zip は別の出力、
KaitoKit は `malformed`）。encoder を「その entry は木に残して code を占有させ prefix を次のクリアまで留めるが、
出力には使わない」に直すと 4 者の出力が原本と一致した。この一致は、再割り当てされた code が解放済み prefix への
参照で葉でなくなる（クリア時に 47 回発生）という decoder の表の扱いまで 3 reader と同じであることを示す。

## 独立した検証データ

`Tests/Fixtures/zip-legacy/`（`generate.py`、`manifest.json`）。payload は text.txt（31,680 byte、反復の多い行）、
dle.bin（DLE 0x90 の連続と全 byte 値）、runs.bin（1000 byte の同一 byte など長い run）、mixed.bin（20,000 byte の
半乱数）、empty.txt、one.txt の 6 file。

| fixture | method | 照合 reader |
| --- | --- | --- |
| shrink.zip | 1（code 幅 9→13、部分クリア無し） | unzip、7zz、deark |
| shrink-clear.zip | 1（words.txt 70,000 byte、部分クリア 3 回、解放 code の再利用） | unzip、7zz、deark |
| reduce1.zip〜reduce4.zip | 2〜5（factor 1〜4、長さ超過の C byte あり） | deark |
| reduce-empty-sets.zip | 2（follower set がすべて空） | deark |
| implode-4k-2trees.zip / 8k-3trees / 4k-3trees / 8k-2trees | 6（窓 × 木の 4 通り、追加長 8 bit あり） | unzip、7zz、deark |

Reduce は unzip（macOS 版は UNREDUCE 無し）と 7-Zip が読めないため deark のみ。生成時に各 reader が展開した
内容が原本と一致することを `generate.py` が確認し、manifest に SHA-256 と reader を記録する。

追加の掃引（fixture としては保存しない、`experiments/stress.py`）: 400 KB と 2 MB の単語列、64 KB の乱数
（Shrink は 13 bit でクリアを繰り返す）、154 KB の run 列を 5 方式（shrink、reduce1 / 4、implode 8k3 / 4k2）で
符号化し、3 reader（Reduce は deark）と `kaito extract` の全 20 組が原本と一致した。release build の `kaito sha` は
2 MB の Shrink を 0.08 s、Implode / Reduce を 0.02 s 台で読む。

## 通過した検証

- `ZipLegacyMethodTests` 5 件、失敗 0: 10 fixture × 6 entry の method 名・サイズ・SHA-256、61 byte buffer の
  streaming、1 byte ずつ返す source、`reopen()`、shrink-clear.zip、切り詰め（5 長さ）/ bit 反転（4 位置）/
  宣言サイズ ±1 が `malformed` / `truncated` / `checksumMismatch` になり次 member に漏れないこと、Shrink の
  未定義 escape（256,3）と symbol 数の合わない Implode 木が `malformed`、method 7 が `unsupportedMethod` のまま、
  ZipCrypto で包んだ Shrink / Implode（APPNOTE §6.1 の header を自作 cipher で作り、`unzip -P` が同じ内容を
  出すことを確認）が正しい password で読め、誤り / 未指定で `wrongPassword` / `passwordRequired`。
- `CLISmokeTests.testListLegacyZipMethods`: `list` の method 名と `sha` の一致。
- 既存 ZIP suite（ZipIntegration / ZipHardening / ZipModernMethod / ZipCodecAuditRegression、119 件）が通過。
  全 suite: 1320 件 / skip 45 / 失敗 0（KaitoKitTests）+ 29 件（Compat）。
- ASan mutant fuzz: 6 seed（shrink、shrink-clear、reduce1、reduce4、implode 8k3 / 4k2）から 600 mutant、
  crash 0 / hang 0 / sanitizer 0。CI と同じ `make-compressed-seeds.sh` → `run-mutants.sh --count 63` も
  18 seed（新規 3 を含む）で crash 0 / hang 0 / sanitizer 0。
- Compat の method 名は `methodDescription` をそのまま通す（Compat 側に method 名の switch は無い）。

bit 反転の検査で 1 点だけ元と同じ出力になる位置がある: 最後の copy の長さを伸ばすだけの反転は宣言サイズで
切られて元と一致し、CRC も通る。終端記号の無い形式の性質で、テストはその場合に出力が原本と一致することを確認する。

## 残る制約

- PKZIP 1.x 実物の書庫は手元に無い。3 つの独立 reader が同じ内容に展開する自作 stream での確認に留まる。
  特に Shrink の部分クリア規約は 3 reader の一致で確定したが、PKZIP が「直前 code が葉」の状況で別の
  振る舞いをする stream を作るなら解けない可能性がある（その stream は 3 reader も解けないはず）。
- method 7（Tokenize）、10（PKWARE DCL Implode）、18（IBM TERSE）、19（IBM z/Architecture LZ77）は従来どおり
  `unsupportedMethod`。
- Reduce の自己参照 copy（距離 < 長さ）は decoder としては窓から 1 byte ずつ写すので解けるが、deark が拒むため
  fixture では検証していない。Reduce 全体と B(1) = 1 bit の規約は独立 reader が deark 1 つしか無い上での確定。
