# ZIP PPMd var.I 復号ループの最適化（2026-09-12、cooViewer-2weq）

## 結果

展開時間は交互 7 巡の B/A 比の中央値で **36.6% 短縮**した。
各巡の `extract-median-ms` の中央値は **411.308 → 260.990 ms**、約 9.16 → 14.44 MB/s。
提供された A/A ノイズ床（±1.7%）を明確に超え、全巡で改善した。

| 検証 | 最終結果 |
| --- | --- |
| 変更前 release build | exit 0、30.31 秒、警告 0 |
| `swift build` | exit 0、4.37 秒、警告 0 |
| 変更後 release build | exit 0、32.05 秒、警告 0 |
| `swift test` の KaitoKitTests | 903 tests、38 skip、失敗 0、267.946 秒 |
| 同 KaitoKitCompatTests | 23 tests、失敗 0、0.695 秒 |
| 全体 | **926 tests、38 skip、失敗 0、コンパイラ警告 0** |
| 既存 ZipPPMdTests | 16 tests、skip 0、失敗 0、22.371 秒 |
| 追加 PPMdVarIMemoryTests | 4 tests、skip 0、失敗 0、0.017 秒 |
| SHA 全行 cmp | 9 書庫・12 entry・21 行一致、stderr / 終了値も一致 |
| 改変入力 A/B | 648 件、受理 93・拒否 555、出力・エラーの差分 0 |
| ASan | 657 件、クラッシュ・タイムアウト・所見 0 |
| `git diff --check` | exit 0 |

追加した 4 tests は、非整列を含む 6 バイト state の終端、全 256 通りの state 数での
領域上限と unit 整列、解放後の検査と decode の拒否、72 回の model 生成・破棄と
不正パラメータの例外を確認する。既存の復元方式・破損入力・64 書庫の writer matrix も通った。
skip は既存の 38 件で、追加テストの skip はない。
Info-ZIP の `zip error: Not supported (Compression method bzip2 not enabled)` は
既存 bzip2 テストの skip 理由であり、テスト失敗ではない。

## 対象と出自

`perf/ppmd-vari-hot-loop` の変更前 `d944efde06c26fd0bcaa770f5bef16ec17e8e445` を基準とする。
指定 worktree の外には書き込まず、生成物・バイナリ・ログは `.build/ppmd-vari-perf/` に置いた。
参照した PPMd 原典は提供済み `inbox/ppmdi1/Model.cpp` と
`inbox/ppmdi1/APPNOTE-5.10-method98.txt` のみ。第三者の実装ソースは開いていない。
既存テストが呼ぶ 7zz は黒箱の writer / oracle としてだけ使用した。
`PPMd7*`、`RARPPMdRangeDecoder`、var.I range decoder、公開 API、ビルド設定は変更していない。
禁止された git 操作および課題管理の更新は実行していない。

## 実装

| 領域 | 所有と初期化 |
| --- | --- |
| `charMask` | 256 × UInt8。model の init で確保・初期化し、再開と escape 世代の巻戻りは `update(repeating: 0, count: 256)` |
| `binSumm` | 25 × 64 × UInt16。init で一度確保し、既存のループで値を初期化 |
| `see` | 24 × 32 × SEE。同じ要素に対して `mean()` / `update()` / `sum` の更新を行う |
| `unmasked` | 256 × Offset。init で一度確保し、今回の探索で書いた要素だけを読む |
| `pending` 2 箇所 | `withUnsafeTemporaryAllocation(of: Offset.self, capacity: 16)` の呼出しごとの局所領域 |

4 個の所有バッファはすべて `private let UnsafeMutablePointer<T>` とし、
`deinit` で初期化済み要素を `deinitialize` してから `deallocate` する。
不正な引数と arena の確保失敗はバッファ確保より前に投げる。
確保後に投げうる `startModelRare()` は全プロパティと全要素の初期化後に呼ぶため、
Swift の初期化失敗時の `deinit` が同じ解放処理を行う。途中に投げるバッファ操作はない。
arena の早期解放と所有バッファの寿命を分け、model の破棄時に各バッファを一度だけ解放する。
同じ初期化順で例外を注入した最小の Swift 6 プログラムでも、catch より前に deinit が走り、
バッファを解放することを確認した（`throwing-init.swift` / `throwing-init.log`）。

SEE は値型だが、ポインタの添字の変更アクセサを通じた `see[i].mean()` と
`see[i].update()` はそのメモリ中の要素を変更する。コピーの一時値に更新を捨てる形にはしない。
定数表、頻度演算、復元方式、range coder の呼出し順は変えない。

`pending` は有効要素数を別の Int で管理し、追加時だけ要素を初期化する。
すべての return / throw で `defer` が有効要素を破棄し、局所領域を抜ける。
初期の 0 または 1 要素、追加直前の `< 16`、超過時の
`PPMd var.I: successor stack overflow` / `PPMd var.I: reduce-order stack overflow` を維持する。
走査は有効要素数 − 1 から 0 へ進み、旧 `reversed()` と同じ順序になる。
reduce-order から successor 生成を呼んでも、それぞれが別の局所領域を持つ。

## 束ねた検査が等価である理由

arena の `checkedInt(p, count: k)` は従来どおり、storage が nil ではなく、
`12 <= p <= end`、`0 <= k <= end - p` のときだけ成功する。
`requireUnit` はさらに `p >= unitsStart` と `(end - p) % 12 == 0` を要求する。
これらの述語、評価順、失敗時の `invalid PPMd var.I arena reference` は変更しない。
新しい internal `uncheckedGet8` / `uncheckedPut8` / `uncheckedGet32` / `uncheckedPut32` は
model の検証済みの頻出経路だけから呼び、既存の汎用 get / put / copy は検査を残す。
32 bit の load は従来と同じ unaligned little-endian、store は little-endian の memcpy である。

- `state(p)` は最初の `p >= unitsStart` と、その失敗時の
  `PPMd var.I: state outside unit area` を残す。続く `checkedInt(p, count: 6)` も残す。
  読む範囲は symbol の `[p,p+1)`、frequency の `[p+1,p+2)`、successor の `[p+2,p+6)`。
  すべて検証済みの `[p,p+6)` に含まれ、元の個別検査が追加で拒否できる offset はない。
- `writeState` も元から最初にあった 6 バイト検査だけで同じ三領域を覆う。
  元の実装と同じく、state に対する unit 整列条件は追加しない。
  frequency の `0...255` 検査とエラー文言を残し、symbol 書込み → frequency 検査 →
  frequency 書込み → successor 書込みの順も同じ。successor の値そのものへの検査は追加しない。
- `stats(c)` が最初に呼ぶ `numStats(c)` は 12 バイトの context 全体を `requireUnit` で検査する。
  その中の `[c+4,c+8)` の参照読取りには追加の検査が不要である。
  参照先に対する既存の `requireUnit(base, count: 6 * (n + 1))` はそのまま残す。
- `findState` の複数状態では、先頭で呼ぶ `stats` が既に全 `n+1` 状態を検査していた。
  従って、早い位置で symbol が見つかる場合も、末尾が不正な配列を新しく拒否することにはならない。
  単一状態では `oneState(c)` が 12 バイトの context を検査し、返す `base = c+2` の
  6 バイトすべてがその中に収まる。両方ともこの検査結果をループで再利用する。
  未発見時の `PPMd var.I: suffix symbol is missing` も変えない。
- `decodeSymbol1` / `decodeSymbol2` の配列走査も、冒頭の `stats` の検査結果を再利用する。
  `n` は UInt8 の読取りなので `0...255`、ループの `i` は `0...n`。
  `base + 6*i` からの 6 バイトは全体の範囲に収まり、旧 `at` の添字検査・advance と
  個別の state / symbol / frequency 検査が追加で失敗する場合はない。
  arena は最大 256 MiB + 12 バイトなので、この計算で Int / UInt32 の桁あふれも起きない。
  `unmasked` に保存する参照も同じ検証済み範囲の部分集合である。
- 検査から unchecked アクセスまでの間に `releaseArena`、外部入力の読取り、利用者への
  コールバックはない。間にある threshold / remove は range coder 内の演算だけである。
  頻度更新・rescale に入った分岐はそのまま return し、変更前の範囲を再利用しない。
  復元・割当てなど、別の範囲や寿命を扱う経路の個別検査は残す。

ポインタ化した表の添字も範囲内である。`charMask` の添字は UInt8 の symbol。
`binSumm` の row は既存の frequency 検査と定数表から非負になり、既存の row < 25 と
column の `0..<64` 検査を残す。`see` の row / column は既存の `0..<24` / `0..<32` 検査を残す。
`unmasked` への書込み前の count は処理済み状態数以下なので最大 255、読取りは書いた count 未満。
初期化ループの添字はそれぞれ固定の要素数内に限る。

従って、検査で拒否される offset と入力の受理・拒否は変わらない。
有限個の破損入力テストだけをこの等価性の証明とはせず、上記の範囲包含と寿命を根拠とする。

## 実行環境と再現方法

arm64 macOS 27.0（26A428）、Apple Swift 6.4
（swiftlang-6.4.0.34.1、clang-2100.3.34.1）を使用した。
通常の無指定 build はユーザーの Clang cache への書込み制限で失敗した。
cache / config / security / module cache を worktree 内へ移し、SwiftPM の入れ子 sandbox を無効化した。
さらに既定の swiftbuild の dSYM 生成が `Operation not permitted` で失敗するため、
新旧とも `-debug-info-format none` を使用した。最適化設定を片側だけ変えていない。
製品ソースや Package.swift に環境対策は追加していない。

一時ファイルも worktree 内に置く。既存の RAR URL 同値テストは `/private/tmp` と `/tmp` の
表記差を同一視しないため、最終テストの TMPDIR は同じ場所を指す `/tmp/...` 表記に揃える。
この調整前の全体実行では 3 テスト・7 アサーションがこの表記差で失敗した。
調整後に全体を再実行し、上表のとおり全件成功した。対象外ソースの修正やテスト除外はない。
追加テストの初回コンパイル時に配列リテラルの型推論エラーを修正し、最終 build には残っていない。

```sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ppmd-vari-perf/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ppmd-vari-perf/module-cache"
export TMPDIR="${PWD#/private}/.build/ppmd-vari-perf/tmp"

swift build --disable-sandbox --cache-path .build/ppmd-vari-perf/cache \
  --config-path .build/ppmd-vari-perf/config --security-path .build/ppmd-vari-perf/security \
  -debug-info-format none
swift test --disable-sandbox --cache-path .build/ppmd-vari-perf/cache \
  --config-path .build/ppmd-vari-perf/config --security-path .build/ppmd-vari-perf/security \
  -debug-info-format none
swift build -c release --product kaito --scratch-path .build/ppmd-vari-perf/release \
  --disable-sandbox --cache-path .build/ppmd-vari-perf/cache \
  --config-path .build/ppmd-vari-perf/config --security-path .build/ppmd-vari-perf/security \
  -debug-info-format none
```

変更前の build 完了時に `.build/out/Products/Release/kaito` を `kaito-before` として保存し、
同じ release 設定で別の scratch path に変更後を build し、`kaito-after` として保存する。
コマンドの共通部分は `.build/ppmd-vari-perf/swift-verify.sh` にも保持する。

## ASan による追加確認

```sh
zsh .build/ppmd-vari-perf/swift-verify.sh build -c release --product kaito \
  --scratch-path .build/ppmd-vari-perf/asan --sanitize address
python3 .build/ppmd-vari-perf/check-asan.py
```

ASan 用 CLI の build は exit 0、警告 0。big.zip、既存の PPMd fixture 8 書庫、
下記の改変入力 648 件、計 **657 件**を各プロセス 10 秒上限で実行した。
正常終了 102、既存の型付きエラーによる拒否 555、クラッシュ 0、タイムアウト 0、
sanitizer の報告 0。正常な 9 書庫の SHA 出力も変更前バイナリと全行一致した。
全入力の終了値・stdout・stderr は `asan-results.jsonl`、集計は `asan-summary.json` に保持した。

## 正常書庫の SHA 比較

変更前後それぞれの release `kaito sha <archive>` を実行し、stdout の全行を `cmp` した。
さらに stderr と終了値も個別に `cmp` した。**9 書庫・12 entry・stdout 21 行が完全一致**、
全 27 回の cmp は exit 0。各 sha コマンドも exit 0、stderr は空だった。
base64 fixture は `.build/ppmd-vari-perf/fixtures/` に展開して比較した。

| 対象 | entry 数 | stdout 行数 | 結果 |
| --- | ---: | ---: | --- |
| 指定の `scratchpad/p2/ppmd-diff/perf/big.zip` | 1 | 2 | 一致 |
| `zip-ppmd/binary-o6-mem4m.zip.b64` | 1 | 2 | 一致 |
| `zip-ppmd/mixed.zip.b64` | 4 | 5 | 一致 |
| `zip-ppmd/random-o16-mem1m-cutoff.zip.b64` | 1 | 2 | 一致 |
| `zip-ppmd/random-o16-mem1m-restart.zip.b64` | 1 | 2 | 一致 |
| `zip-ppmd/text-o16-mem1m.zip.b64` | 1 | 2 | 一致 |
| `zip-ppmd/text-o2-mem1m.zip.b64` | 1 | 2 | 一致 |
| `zip-ppmd/text-o8-default.zip.b64` | 1 | 2 | 一致 |
| `rar4/ppmd_lorem_rar300.rar.b64` | 1 | 2 | 一致 |

big.zip の新旧共通出力は次のとおり。

```text
0	3768058	c08185117f4ff44d39340ddcac0b867e1a8caa01684b699dff1ca00b5e0e87f7	big.txt
total	1	edd24313853814cb663b541d0fc09ad8c5ae1e7b7c24c83cbde8838f039cf001
```

入力の絶対パス一覧は `archives.json`、各出力は `sha-{before,after}-{0...8}.{out,err,exit}`、
集計は `sha-summary.json` に保存した。比較コマンドの形は以下のとおり。

```sh
work="$PWD/.build/ppmd-vari-perf"
archive="$PWD/../scratchpad/p2/ppmd-diff/perf/big.zip"
"$work/kaito-before" sha "$archive" > "$work/before.out" 2> "$work/before.err"
"$work/kaito-after" sha "$archive" > "$work/after.out" 2> "$work/after.err"
cmp "$work/before.out" "$work/after.out"
cmp "$work/before.err" "$work/after.err"
```

## 改変入力の差分検証

単一 PPMd entry の固定 fixture 6 本それぞれから 108 ケース、計 **648 件**を作成した。
原本、32 等分位置 × 2 種類の byte 反転、7 段階の切断、全 16 order 値、全 4 restore 値、
予約上位 2 bit の全 4 値、辞書サイズ 6 値、宣言展開サイズ 6 値を含む。
切断後も ZIP envelope の圧縮サイズ・中央ディレクトリ位置を整合させ、decoder に入力を届ける。
展開サイズ 0 のケースでは CRC も 0 にして、空 entry を従来どおり受理することも確認する。

```sh
python3 .build/ppmd-vari-perf/compare-mutants.py
```

新旧で `kaito sha` の終了値・stdout・stderr が全件一致した。
**受理 93、拒否 555、差分 0、クラッシュ 0、10 秒上限のタイムアウト 0**。
受理には予約 bit や未使用末尾の変更などを含むため、改変入力をすべて拒否するとは仮定していない。
拒否時はエラー種別だけでなく理由の文字列も一致する。
再現スクリプトと入力は `compare-mutants.py` / `mutants/`、各結果と入力 SHA は `mutants.jsonl`、
集計は `mutants-summary.json` に保持した。

## 性能 A/B

全 build・test・SHA・改変入力・ASan の処理が終了してから実行した。
測定中にこれらの重い処理を並走させていない。
変更前を A、変更後を B とし、同じ `kaito bench <big.zip> 3` を A → B の順で交互に実行した。
最初の A / B 各 1 プロセスをウォームアップとして除外した後、7 巡、各バイナリ 21 回の展開を集計する。
各プロセス内の 3 回は CLI 既存実装どおりすべて中央値に使い、先頭 1 回を除く変更はしていない。

```sh
python3 .build/ppmd-vari-perf/bench.py
```

| 巡 | A extract-median-ms | B extract-median-ms | B/A |
| --- | ---: | ---: | ---: |
| 1 | 409.547 | 261.705 | 0.6390 |
| 2 | 410.286 | 264.102 | 0.6437 |
| 3 | 412.788 | 260.749 | 0.6317 |
| 4 | 413.472 | 257.486 | 0.6227 |
| 5 | 415.627 | 262.702 | 0.6321 |
| 6 | 410.352 | 260.087 | 0.6338 |
| 7 | 411.308 | 260.990 | 0.6345 |
| 中央値 | **411.308** | **260.990** | **0.6338** |

ウォームアップは A 411.382 ms / B 257.746 ms。
各巡 B/A の中央値は 0.633814、範囲 0.622741〜0.643702、時間短縮率は 36.6186%、約 1.578 倍速。
表の B/A 中央値は各巡の比の中央値であり、二つの ms 中央値の比とは区別する。
利用者提供の A/A は中央値 1.0016、範囲 0.9951〜1.0169。この約 ±1.7% の揺れに対し、
今回の最も改善が小さい巡でも 35.6% 短縮しており、有意な改善という受入条件を満たす。
依頼文の過去値 457.4 ms と直接比較せず、今回同じ設定で作った A を基準にした。

7 巡目のコマンド出力は以下のとおり。全巡とも reps は 3、bytes は 3,768,058、exit 0、stderr は空。

```text
A:
reps	3
open-median-ms	0.194
extract-median-ms	411.308
bytes	3768058

B:
reps	3
open-median-ms	0.183
extract-median-ms	260.990
bytes	3768058
```

保存した二つのバイナリの SHA-256 は異なる。

```text
edf0a744dcff5459fb77c66aa606168e3f5aef55f51cd6e58d0e3efbff37519f  kaito-before
986437da840f71b614fb8731dd835e5b6563297c58e71f0d650e24784e1df55d  kaito-after
```

全プロセスの出力・測定値は `bench.jsonl` / `bench.log`、集計は `bench-summary.json` に保存した。
新旧のソースと通常・ASan のバイナリ、各 build / test のログも同じ作業ディレクトリに保持した。
仕様上の動作・変更範囲の逸脱はない。コマンドの環境調整は上記の cache / sandbox / dSYM / TMPDIR のみ。

## orchestrator による独立検証

Codex の検証とは別に、orchestrator が同一 worktree から release / ASan の `kaito` を
組み直し、`main` (`d944efd`) の release binary を基準に実施した。

| binary | SHA-256(先頭 20 文字) |
|---|---|
| A: main `d944efd` | `c8e8680505a816e287e3` |
| B: 本変更 | `9b410e17d00207070a73` |

**着手前の profile。** 変更前の release binary を `sample` で 10 秒採取した
8,037 サンプルの leaf 上位は、`decodeSymbol2` 871、`state` 755、`decodeByte` 682、
**`swift_beginAccess` 627**、`findState` 620、`decodeSymbol1` 601、`updateModel` 423、
`createSuccessors` 346、`decodeBinSymbol` 338、**`swift_endAccess` 247**、`stats` 183、
`setSuccessor` 178、`setFrequency` 169、`writeState` 137、`setSum` 135、
**`swift_isUniquelyReferenced_nonNull_native` 122**(ほかに各 DYLD-STUB)。
排他チェックが約 13%、CoW 一意性判定が約 2.6% を占めていた。
`createSuccessors` の call graph には `Array.reserveCapacity` →
`_ArrayBuffer._consumeAndCreateNew` → `swift_allocObject` → `malloc` が出ていた。
本変更はこの 3 点(class 内 Swift Array・escape ごとの 256 バイト再確保・
`pending` の heap 確保)だけを対象にしており、アルゴリズムは変えていない。

**是正後の profile。** 同じ手順で採取すると `swift_beginAccess` は 129 まで下がり、
CoW 一意性判定は上位から消えた。残る上位は `decodeSymbol2` 3,873、`findState` 882、
`createSuccessors` の closure 379 で、いずれも実処理である。
class の scalar プロパティ(`foundState` / `orderFall` / `runLength` 等)に残る
排他チェックは本変更の対象外で、別途 issue として扱う。

**性能 A/B。** `ab.sh` で交互 5 巡(各 3 回展開の中央値)。判定は各巡 B/A の中央値。

| 書庫 | 内容 | A median | B median | 各巡 B/A の中央値 | 範囲 | 時間の変化 |
|---|---|---:|---:|---:|---|---:|
| big.zip | Swift source 3,768,058 バイト、o=8 mem=64m | 442.707 ms | 284.905 ms | **0.6436** | 0.6241〜0.6759 | −35.6% |
| mixed.zip | PNG 連結 3,000,000 バイト、o=16 mem=256m | 5147.709 ms | 1283.218 ms | **0.2507** | 0.2339〜0.2573 | −74.9% |

A/A ノイズ床は big が各巡 B/A の中央値 1.0016(0.9951〜1.0169)、
mixed が 0.9980(0.9955〜1.0077)。改善はノイズ床の 20〜40 倍あり、両書庫とも全巡で改善した。
参考値として `7zz x -so` の実時間は big 0.14 秒、mixed 0.56 秒。
本変更で kaito の展開時間はそれぞれ 0.285 秒 / 1.28 秒になり、比は約 3.3 倍 / 約 9 倍から
約 2 倍 / 約 2.3 倍に縮んだ。

**受理・拒否集合の同一性。** 束ねた検査が入力の受理範囲を広げても狭めてもいないことを、
挙動の比較で確かめた。既存の敵対的入力ハーネス(切り詰め・bit 反転・parameter word 総当り・
宣言サイズ改変・payload 乱数化)を A と B の**両方**に流し、
`(終了コード, stdout 全体, stderr 先頭行)` を比較した。
**3,516 入力すべてで完全一致、相違 0。**

**ASan。** 同じ worktree から
`swift build --scratch-path .build-asan -Xswiftc -sanitize=address --product kaito` で組み、
同じ 3,516 入力を流した。**sanitizer 報告・crash・タイムアウトは 0。**
生ポインタ化した 4 バッファは malloc 由来なので、範囲外アクセスはこの経路で検出される。

**正常展開の一致。** big.zip、mixed.zip、`Tests/Fixtures/zip-ppmd/` の 7 書庫について
`kaito sha` の出力全体を A と B で比較し、全書庫で一致した。

**テスト。** worktree で `swift test` を実行し、**926 件(903 + 23)、38 skip、失敗 0、
`warning:` 0 件**。

ベンチ書庫・ハーネス・ログは本セッションの一時領域にあり、セッション終了で失われる。
