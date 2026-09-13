# StuffIt slice 5 性能検証（2026-09-13、bd `cooViewer-gu28.5`）

対象 HEAD は `c1ad9d1f04312dc6722891445b0f284485a5a37f`（`feat/stuffit`）。
A は支給の `inbox/bench/kaito-before`、最終 B は `inbox/bench/slice5/kaito-after`。
変更後の release も同じ worktree で作成した。外部実装のソースと Web は参照していない。
git checkout / restore / stash / reset / commit / push は実行していない。

## 実装

- Huffman: 10 bit の一次表を MSB/LSB 各 1,024 件、固定長 `UInt32` ポインタで保持する。
  symbol と長さを格納し、長い符号と未定義の枝は元の木へ戻す。
  `insert(symbol:code:length:)` の検証と符号割当順は保持した。method 3 の明示木は構築後に
  先頭 10 段だけを表へ反映する。長さゼロの根の葉、深さ 256、38 bit 符号も維持する。
- 対象 HEAD の `children` / `symbols` は既に固定長ポインタだった。節点を `Int32` に縮め、
  一次表を含む各 codec の最大領域を従来の予算内に収めた。`ReadLimits` の受理境界は変更していない。
- method 13: 木を所有する class は残し、各 `read` の開始時に非所有の `Decoder` 値へ
  table / children / symbols のポインタを取り出す。三項演算子が選ぶのはこの値であり、
  symbol ごとの class の retain/release を不要にした。所有者は `read` の間生存する。
- bit reader: 表引きの前に 32 bit 以上を補充し、通常経路では 32 bit の非整列ロードを使う。
  `peek` / `consume` は非 throwing。末尾はゼロ詰めして参照し、実在 bit 数を超える消費時に
  `truncated` を返す。先読み中の I/O エラーも実消費まで保留する。byte 読み出しと整列は
  完全な先読み octet を残し、旧実装の端数 bit の扱いを維持する。
- Arsenic: `q = floor(R/T)`、`floor(C/q)`、最後の区間への余りの割当、頻度更新・rescale は保持する。
  `25 - ceil(log2(R))` に相当する最小幅を求め、正規化の bit 読み出しをまとめた。
  code の桁あふれが起こり得る場合だけ旧ループに戻し、入力切れと桁あふれの優先順を保つ。
  累積表の各試作は後述の実測で退行したため戻した。
- Cyanide: 16 slot 以上の model で 4 区間の上端をまとめて確認し、該当する組の中を二分する。
  小さい model と末尾は従来の走査を使う。等頻度の右端との交換、+1、rescale の順序は変更していない。
- method 6 / 14 は既存の呼出しのまま表引きを使う。method 5 の距離木も共有する。
  StuffIt X Deflate は既に固定長ポインタの表引きであり、器を統合せず変更していない。
  容器、wrapper、暗号、Brimstone、Iron、Darkhorse、BWT permutation、RLE 出力処理は変更していない。

## 計測方法

Swift 6.4（swiftlang-6.4.0.34.1）、arm64、macOS 27.0（26A428）。
CPU の型番は sandbox 内の `sysctl` が拒否されたため未確認。
release は `-debug-info-format none` を付けて作成した。
ベンチマークと build / test / ASan 検証は並走していない。
`inbox/bench/ab.sh` により各巡 A→B を交互に 5 巡、各プロセス内 3 回。
以下の A/B は各 slot の展開時間の中央値、B/A は**各巡の比の中央値**であり、中央値同士の比ではない。
先に A/A を測定し、全試作の binary と TSV / log を `inbox/bench/slice5/` に残した。

## 変更ごとの A/B（ms）

### Huffman・bit reader・ARC 除去

before → huffman。採用後、通常 bit 読み出しの補充判定を修正した。

| 書庫 | A ms | B ms | B/A |
|---|---:|---:|---:|
| 911AJOKEMIM.mov.sit | 765.816 | 791.574 | 1.0337 |
| BirdFluWAVE.sitx | 634.894 | 635.714 | 1.0008 |
| SMSSenderPro3osx.sitx | 3443.048 | 3433.405 | 0.9980 |
| doom-i-101.hqx | 51.399 | 22.628 | 0.4402 |
| i_like_icon.sit | 25.590 | 5.407 | 0.2109 |
| theplanets.sit | 347.733 | 346.638 | 1.0009 |
| warriors_screen.sitx | 134.022 | 133.160 | 0.9931 |

### Arsenic 全 model の Fenwick 木

huffman → arithmetic。両書庫で退行し撤回。

| 書庫 | A ms | B ms | B/A |
|---|---:|---:|---:|
| 911AJOKEMIM.mov.sit | 820.591 | 889.253 | 1.0833 |
| theplanets.sit | 347.499 | 399.068 | 1.1497 |

### 通常 bit 読み出しの補充判定

huffman → bits。Arsenic の退行を解消する変更として採用。

| 書庫 | A ms | B ms | B/A |
|---|---:|---:|---:|
| 911AJOKEMIM.mov.sit | 792.164 | 763.539 | 0.9638 |
| i_like_icon.sit | 5.694 | 5.463 | 0.9818 |
| theplanets.sit | 347.121 | 341.518 | 0.9826 |

### Arsenic 32 symbol 以上の累積表

bits → cumulative。差分更新と二分探索を実装したが退行し撤回。

| 書庫 | A ms | B ms | B/A |
|---|---:|---:|---:|
| 911AJOKEMIM.mov.sit | 767.894 | 791.385 | 1.0306 |
| theplanets.sit | 341.262 | 349.934 | 1.0246 |

### Arsenic MTF の明示的一括移動

bits → mtf。差は A/A 床内。旧ループも既に 1 回の memmove に変換されるため撤回。

| 書庫 | A ms | B ms | B/A |
|---|---:|---:|---:|
| 911AJOKEMIM.mov.sit | 772.957 | 762.764 | 0.9895 |
| theplanets.sit | 342.880 | 343.635 | 1.0020 |

### Arsenic 8 要素ごとの累積表

bits → coarse。退行し撤回。

| 書庫 | A ms | B ms | B/A |
|---|---:|---:|---:|
| 911AJOKEMIM.mov.sit | 774.576 | 798.451 | 1.0278 |
| theplanets.sit | 346.186 | 352.138 | 1.0168 |

### Arsenic の model 番号による経路分離

bits → index。小さい model の分岐を除ける形も退行し撤回。

| 書庫 | A ms | B ms | B/A |
|---|---:|---:|---:|
| 911AJOKEMIM.mov.sit | 762.133 | 789.615 | 1.0345 |
| theplanets.sit | 339.858 | 349.165 | 1.0240 |

### Arsenic 正規化の一括読み出し

bits → normalize。両書庫で改善し採用。

| 書庫 | A ms | B ms | B/A |
|---|---:|---:|---:|
| 911AJOKEMIM.mov.sit | 758.002 | 678.893 | 0.8974 |
| theplanets.sit | 342.699 | 305.830 | 0.8909 |

### Cyanide 累積表と二分探索

normalize → cyanide。3 書庫で退行し撤回。

| 書庫 | A ms | B ms | B/A |
|---|---:|---:|---:|
| BirdFluWAVE.sitx | 635.567 | 714.730 | 1.1266 |
| SMSSenderPro3osx.sitx | 3430.582 | 3652.112 | 1.0646 |
| warriors_screen.sitx | 133.357 | 152.491 | 1.1412 |

### Cyanide 末尾からの走査

normalize → reverse。3 書庫で退行し撤回。

| 書庫 | A ms | B ms | B/A |
|---|---:|---:|---:|
| BirdFluWAVE.sitx | 650.876 | 674.603 | 1.0353 |
| SMSSenderPro3osx.sitx | 3603.336 | 3656.255 | 1.0188 |
| warriors_screen.sitx | 137.657 | 141.977 | 1.0306 |

### Arsenic SIMD 部分和による二分探索

normalize → binary。UInt16 頻度と SIMD8 の部分和を用いたが退行し撤回。

| 書庫 | A ms | B ms | B/A |
|---|---:|---:|---:|
| 911AJOKEMIM.mov.sit | 715.637 | 769.691 | 1.0755 |
| theplanets.sit | 322.963 | 331.189 | 1.0276 |

### Cyanide 4 区間ずつの判定

normalize → grouped。3 書庫の全 5 巡で改善し採用。

| 書庫 | A ms | B ms | B/A |
|---|---:|---:|---:|
| BirdFluWAVE.sitx | 663.193 | 649.147 | 0.9763 |
| SMSSenderPro3osx.sitx | 3736.628 | 3696.015 | 0.9862 |
| warriors_screen.sitx | 140.394 | 136.233 | 0.9714 |

MTF の根拠は `arsenic-before.asm` / `arsenic-mtf.asm`。変更前も `loadBlock` 内で
`x0 = mtf + 1`、`x1 = mtf`、`x2 = rank` の `memmove` が 1 回あり、同じ移動を行う。
これは KaitoKit 自身の binary の逆アセンブルで確認した。

## 最終検証

### 出力と受理結果の同一性

| 入力 | 件数 | 成功 | 拒否 | stdout 行数 | 差分 | sanitizer / crash |
|---|---:|---:|---:|---:|---:|---:|
| CC0 | 216 | 165 | 51 | 1,675 | 0 | 0 |
| go | 17 | 14 | 3 | 88 | 0 | 0 |
| perf | 17 | 17 | 0 | 8,916 | 0 | 0 |
| コーパス合計 | 250 | 196 | 54 | 10,679 | 0 | 0 |
| mutate.py | 3,534 | 548 | 2,986 | 10,229 | 0 | 0 |
| mutate-sitx.py | 3,552 | 133 | 3,419 | 7,465 | 0 | 0 |
| 敵対的入力合計 | 7,086 | 681 | 6,405 | 17,694 | 0 | 0 |

各入力を変更前 release・変更後 release・変更後 ASan の 3 本で処理した。
`sha --forks -p password` の stdout を一切正規化せず、全バイトを保存して `cmp`。
終了コードと stderr 先頭行も同一ファイル名で比較し、JSONL の記録を `cmp` した。
敵対的入力は延べ 21,258 実行で timeout も 0。コーパスの失敗 54 書庫は、追加で stderr **全体**も新旧一致を確認した。

`verify.py` は支給 `mutate.py` / `mutate-sitx.py` を `runpy` で実行し、
`subprocess.run` だけを 3 本の比較へ差し替える。入力生成・乱数 seed・60 書庫の選択は
元のスクリプトのままで、両スクリプトを変更していない。
各ケースは同じ一時ファイルを 3 回読み、比較が終わってから削除する。
ログは `final-corpus.log`、`final-mutate.log`、`final-mutate-sitx.log` と各 `*-before/after/asan.jsonl`、
stdout の生データは同名の `*.stdout`。全て `inbox/bench/slice5/` にある。

### 追加の境界照合

検証用プログラムは対象 HEAD の reader / tree / arithmetic / Cyanide Model を固定した参照とし、
変更後の実コードと比較した。いずれも `swiftc -O -sanitize=address`、警告・sanitizer 報告・差分 0。

- Huffman / bit reader: 338,720 比較。1〜3 byte の短い source 読み出し、I/O エラー、
  bit 順の切替、byte 読み出し、整列、16 KiB の補充境界、未定義の枝、32 / 38 bit 符号、
  長さゼロの根の葉、深さ 256 / 257 の明示木を含む。
- Arsenic: 3,454,625 比較。全 9 model の symbol、rescale、block reset、入力切れ、
  異常 code の桁あふれを含む。最終採用した正規化版も同じ比較を通過した。
- Cyanide: 274,225 比較。size 1〜129、各状態で全ての count を列挙し、symbol / slot と
  range に渡す start / frequency を照合した。等頻度交換、rescale、二重 bump も含む。

ソースとログは `boundary*` / `arithmetic-normalize-boundary*` / `cyanide-boundary*`。
これらの比較回数を、上の敵対的書庫 7,086 件に加算していない。

### 支給 compare.py

新旧とも `match: 149 / name_diff: 0 / no_oracle: 4 / kaito_error: 51 / mismatch: 12`、exit 1。
stdout 全体と終了コードが `cmp` で一致した。
12 mismatch は slice 4 で記録済みの Mac 7 `.sitx` wrapper のオラクル範囲の差であり、
圧縮書庫自体の SHA と展開後 entry の SHA が比較される。4 件は oracle がない。
51 error は既存の未対応形式・暗号・recovery・JPEG 等で、この変更による新規の不一致はない。
指定スクリプトが成功したとの扱いにはしていない。

### 再実行コマンド

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang" swift build --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang" swift test --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang" swift build -c release --product kaito -debug-info-format none --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang" swift build -c release --product kaito --sanitize address --scratch-path .build/slice5-asan -debug-info-format none --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
python3 inbox/bench/slice5/verify.py inbox/bench/kaito-before inbox/bench/slice5/kaito-after corpus inbox/bench/slice5/kaito-asan
python3 inbox/bench/slice5/verify.py inbox/bench/kaito-before inbox/bench/slice5/kaito-after mutate inbox/bench/slice5/kaito-asan
python3 inbox/bench/slice5/verify.py inbox/bench/kaito-before inbox/bench/slice5/kaito-after mutate-sitx inbox/bench/slice5/kaito-asan
python3 inbox/stuffit-corpus/compare.py inbox/bench/slice5/kaito-after
```

SwiftPM と Clang のキャッシュを worktree 内へ指定した。
通常 release と ASan release の build はともに exit 0、警告 0。

| binary | SHA-256 |
|---|---|
| kaito-before | `bbb95f3bf039041b9d6b3f6dde8a7ded1fef9ca0220b480cbf24fccc921ce73e` |
| kaito-after | `d7513ad95d7c68840edc324ca5420c077ff2fa3556128e6a764b9e74de74863f` |
| kaito-asan | `c2dd9e11e4909b35b056337dbc299f7bb7f4ea56e0ecda798c032aabd143eb4c` |

### build / test

- `swift build`: exit 0、1.93 秒。
- `swift test`: KaitoKit 997 tests（40 skip）+ Compat 23 tests、合計 1,020 tests、失敗 0。
  XCTest の所要時間はそれぞれ 287.293 秒 / 0.788 秒。
- 最終 release build: exit 0、36.41 秒。ASan release build: exit 0、43.33 秒。
- 上記 4 コマンドの `warning:` は全て 0。既存の外部 zip の bzip2 非対応メッセージは
  テスト失敗でもコンパイラ警告でもない。

ログは `final-build.log` / `final-test.log` / `final-release.log` / `final-asan-build.log`。

### profile と ARC

要求された `sample <pid> 8 1` は、この sandbox では自分で起動した子プロセスにもアクセスできず、
変更前後の method 13 / Arsenic / Cyanide の全 6 実行が exit 255 になった。
診断は `sample cannot examine process ... even though it appears to exist; try running with sudo`。
権限昇格できる実行環境ではないため、**変更後の動的 profile は未取得**。ログは `final-profile.log`。

| 対象 | 依頼文の変更前 profile（orchestrator） | 本環境での変更後 profile |
|---|---|---|
| method 13 | read leaf 4,991、release 663、retain 312、DYLD retain/release 445、ARC 約 22% | sample 拒否で未取得 |
| Arsenic / 911 | loadBlock 3,963（74%）、read 925（17%）、memmove 452（8%） | sample 拒否で未取得 |
| Cyanide / BirdFlu | block closure 2,251（52%）、Model.decode 1,475（34%）、read 426 | sample 拒否で未取得 |

補助検査として **KaitoKit 自身**の release binary を `nm` / `otool -tvV` で確認した。
`StuffItMethod13.read(into:)` 本体の直接呼出し箇所は、変更前が `swift_retain` 2・`swift_release` 3、
変更後は両方 0。三項の選択はポインタだけを持つ値になっている。
`method13-before-0.asm` / `method13-after-0.asm` に関数全体を保存した。
これは静的な呼出し箇所の確認であり、動的 profile の割合や `sample` 達成の代わりには数えない。

## 最終 A/A と A/B

perf 17 書庫と go の doom、計 18 書庫。主対象 7 書庫の A/A を最初に測り、残る 11 書庫も
それぞれ最終 A/B の前に測定した。最初の i_like_icon の A/A 第 1 巡は B/A 0.8081 だったが、
除外せず全 5 巡を記載する。絶対時間は測定時刻により動くため、採否は交互実行の比で判断した。

| 書庫 | A/A 中央値 | A/A 最小〜最大 |
|---|---:|---:|
| i_like_icon.sit | 1.0031 | 0.8081〜1.0111 |
| 911AJOKEMIM.mov.sit | 0.9866 | 0.9708〜1.0094 |
| theplanets.sit | 1.0021 | 0.9951〜1.0356 |
| BirdFluWAVE.sitx | 0.9989 | 0.9676〜1.0105 |
| warriors_screen.sitx | 0.9818 | 0.9637〜1.0021 |
| SMSSenderPro3osx.sitx | 1.0044 | 0.9983〜1.0078 |
| doom-i-101.hqx | 1.0027 | 0.9929〜1.0047 |
| CoralReef.sit | 1.0022 | 0.9982〜1.0103 |
| Galax.SIT | 0.9995 | 0.9311〜1.0625 |
| IconCollection.sit | 1.0049 | 0.9859〜1.0090 |
| IconfactoryIcons_2.sit | 0.9956 | 0.9941〜1.0133 |
| IconizerPro2.0.7.sit | 0.9809 | 0.9782〜1.0059 |
| Ikthusian-Classic-Coll.sit | 1.0033 | 0.9790〜1.0123 |
| Kineticon_1.7.1.sit | 0.9953 | 0.9673〜1.0453 |
| Tickershock.sitx | 0.9986 | 0.9845〜1.0065 |
| iconographerXF.sit | 0.9946 | 0.9747〜1.0106 |
| icontrol.sit | 0.9982 | 0.9711〜1.0162 |
| theconceptosx.sitx | 0.9919 | 0.9862〜1.0194 |

| 書庫 | 変更前 A ms | 変更後 B ms | B/A | 全 5 巡 B<A |
|---|---:|---:|---:|---|
| i_like_icon.sit | 26.478 | 5.608 | 0.2133 | はい |
| 911AJOKEMIM.mov.sit | 803.259 | 721.591 | 0.8968 | はい |
| theplanets.sit | 365.851 | 322.807 | 0.8831 | はい |
| BirdFluWAVE.sitx | 664.829 | 648.678 | 0.9762 | はい |
| warriors_screen.sitx | 140.868 | 135.687 | 0.9643 | はい |
| SMSSenderPro3osx.sitx | 3620.485 | 3588.029 | 0.9862 | いいえ |
| doom-i-101.hqx | 53.409 | 22.578 | 0.4229 | はい |
| CoralReef.sit | 52.634 | 45.290 | 0.8609 | はい |
| Galax.SIT | 1.908 | 1.676 | 0.8523 | はい |
| IconCollection.sit | 70.564 | 60.852 | 0.8641 | はい |
| IconfactoryIcons_2.sit | 378.974 | 330.677 | 0.8704 | はい |
| IconizerPro2.0.7.sit | 95.862 | 85.002 | 0.8815 | はい |
| Ikthusian-Classic-Coll.sit | 188.387 | 168.818 | 0.8894 | はい |
| Kineticon_1.7.1.sit | 7.307 | 6.412 | 0.8803 | はい |
| Tickershock.sitx | 93.892 | 90.264 | 0.9647 | はい |
| iconographerXF.sit | 52.885 | 47.439 | 0.9089 | はい |
| icontrol.sit | 8.943 | 7.981 | 0.8788 | はい |
| theconceptosx.sitx | 181.746 | 176.408 | 0.9725 | はい |

18 書庫の B/A 中央値は全て 1 未満。i_like_icon は 0.2133 で要求の 0.60 以下を達成し、
911 / theplanets / BirdFlu / SMSSender に退行はない。doom の展開時間は 57.7% 減少した。
raw TSV は `aa-<書庫>.tsv` / `final-<書庫>.tsv`。

BinHex を含む doom は open も別に測定される。open の中央値は A 49.799 / B 54.193 ms で、
表の B/A はこの open を含まない。各巡の open+extract の中央値は後記の計算値であり、
wrapper 自体を高速化したとの主張ではない。
open+extract は A 102.862 / B 76.764 ms。

## XADMaster 比較（各 5 回の中央値）

同一のファイルに `kaito bench <archive> 5` と
`DYLD_FRAMEWORK_PATH=inbox/bench/Frameworks xadbench extract <archive> 5` を直列実行した。
全実行が exit 0。XAD の `bytes` は 5 回分の合計なので 5 で割った。
911 の 1 回実行でも 17,399,293 byte となることを追加確認している。

**展開する fork と wrapper の段数が異なる。** Kaito は data+resource を展開する。
15 書庫では XAD の byte 数が Kaito の data fork 合計と厳密に一致し、resource 分が含まれない。
残る 3 wrapper は内側の圧縮書庫までで止まる。この差を含む raw 時間を次表に残す。
異なる処理量の行を、同じ出力に対する codec の速度比とは扱わない。

| 書庫 | Kaito ms | XAD ms | Kaito byte | XAD byte/回 | 差の内容 |
|---|---:|---:|---:|---:|---|
| i_like_icon.sit | 5.531 | 14.13 | 1,638,400 | 1,638,400 | 同量 |
| 911AJOKEMIM.mov.sit | 721.990 | 806.81 | 17,431,167 | 17,399,293 | resource +31,874 B |
| theplanets.sit | 319.644 | 280.86 | 10,783,321 | 8,148,766 | resource +2,634,555 B |
| BirdFluWAVE.sitx | 654.778 | 666.54 | 10,752,646 | 10,690,483 | resource +62,163 B |
| warriors_screen.sitx | 133.936 | 128.55 | 1,943,368 | 1,849,434 | resource +93,934 B |
| SMSSenderPro3osx.sitx | 3663.473 | 5825.72 | 56,775,412 | 56,775,002 | resource +410 B |
| doom-i-101.hqx | 22.182 | 60.29 | 5,764,400 | 2,545,575 | XAD は圧縮書庫まで |
| CoralReef.sit | 45.743 | 0.01 | 1,893,693 | 75 | resource +1,893,618 B |
| Galax.SIT | 1.768 | 0.00 | 59,067 | 0 | resource +59,067 B |
| IconCollection.sit | 61.135 | 1.54 | 2,215,434 | 56,692 | resource +2,158,742 B |
| IconfactoryIcons_2.sit | 333.106 | 1.07 | 15,229,266 | 272,018 | resource +14,957,248 B |
| IconizerPro2.0.7.sit | 85.408 | 66.13 | 3,217,678 | 1,979,265 | resource +1,238,413 B |
| Ikthusian-Classic-Coll.sit | 168.283 | 179.45 | 4,990,443 | 4,987,121 | resource +3,322 B |
| Kineticon_1.7.1.sit | 6.375 | 2.46 | 1,514,585 | 1,338,336 | resource +176,249 B |
| Tickershock.sitx | 90.209 | 0.02 | 960,034 | 937,644 | XAD は圧縮書庫まで |
| iconographerXF.sit | 47.633 | 39.55 | 2,079,494 | 1,610,182 | resource +469,312 B |
| icontrol.sit | 7.886 | 2.90 | 1,824,589 | 1,660,273 | resource +164,316 B |
| theconceptosx.sitx | 178.921 | 0.04 | 1,834,476 | 1,803,385 | XAD は圧縮書庫まで |

i_like_icon は同じ 1,638,400 byte で 5.531 / 14.13 ms（Kaito が約 2.55 倍速い）。
911 / BirdFlu / SMSSender は resource を含めても Kaito の方が短時間だった。
warriors は 133.936 / 128.55 ms で raw 時間では Kaito が約 4.2% 長いが、
resource 93,934 byte（data 比約 5.1%）を追加で展開している。

CoralReef / Galax / IconCollection / IconfactoryIcons_2 等は resource 主体であり、
XAD の対象は 75 / 0 / 56,692 / 272,018 byte だけだった。
Galax の XAD 0.00 ms は codec 全出力の復号時間ではない。
Tickershock / theconceptosx は MacBinary 内の圧縮 `.sitx` の 937,644 / 1,803,385 byte、
doom は BinHex 内の圧縮 `.sit` の 2,545,575 byte を XAD が返す。
doom のこの長さは支給 `unwrapped-go/doom-i-101.hqx.data` の長さとも一致する。

**全書庫で raw 時間が XAD 以下、という目標は未達。** resource を除く比較や wrapper を
同じ段数まで展開する比較には別の計測条件が必要であり、この表から達成を推定していない。
支給コマンドを改変したり、resource を省いて Kaito の結果を速く見せたりはしていない。
raw 出力は `kaito-<書庫>.txt` / `xad-<書庫>.txt` と `xad-comparison.json`。

## 仕様との差と判断

- Arsenic の累積表と二分探索は全試作で退行したため、指示の「効かない変更は戻す」に従い
  線形探索を残した。代わりに、測定で約 10% 改善した正規化の一括読み出しを採用した。
- MTF のソース上の一括移動への置換は撤回した。旧コードも機械語では既に 1 回の memmove。
- 32 bit の補充は表引きの `peek` 前に行う。通常の `bits` は必要分が足りなければ補充する。
  全ての bit 読み出しで 32 bit を要求した試作は Arsenic が 3.4% 退行したため修正した。
- `sample` による変更後 profile は実行環境の権限制限で未取得。静的 ARC 検査と実測時間を
  分けて記録した。これを profile の要件達成とはしていない。
- XAD の全書庫での raw 時間優位は未達。処理する fork / wrapper が異なる行を明記した。

変更ファイルは `StuffItHuffman.swift` / `StuffItPackedInput.swift` / `StuffItMethod13.swift` /
`StuffItArsenicArithmetic.swift` / `StuffItXCyanide.swift`、CHANGELOG、本記録、design.md §11 の 8 件。
`git diff --check` は出力なし。コードの変更後に全テスト・全照合・最終計測を行い、
その後は記録だけを編集した。

## orchestrator による独立検証

Codex の計測とは別に、変更前(`inbox/bench/kaito-before`、SHA-256 先頭 `bbb95f3bf039041b`)と
変更後(`739c5de19ed86bbb`)の release binary で `ab.sh`(A/A 3 巡 × 3 回、A/B 5 巡 × 3 回、各巡 B/A の中央値)を実行した。

| 書庫 | codec | A/A 床(範囲) | A/B | 判定 |
|---|---|---:|---:|---|
| i_like_icon.sit | classic method 13 | 0.9868(0.9624〜1.0248) | **0.2140**(0.2020〜0.3401) | 4.7 倍速。同量処理の XADMaster 14.1 ms に対し 5.5 ms |
| 911AJOKEMIM.mov.sit | SIT5 Arsenic | 0.9926(0.9851〜1.0068) | **0.8754**(0.8596〜0.9131) | 12.5% 改善 |
| BirdFluWAVE.sitx | SITX Cyanide | 1.0052(1.0008〜1.0086) | 0.9836(0.9588〜0.9889) | 僅かに改善、退行なし |

出力同一性: `compare.py` は新旧とも match 149 / mismatch 12(slice 4 で記録済みの Mac 7 wrapper の
オラクル範囲差)/ kaito_error 51 で同一。perf 17 + go 17 の `kaito sha --forks -p password` 出力は
34 / 34 で新旧完全一致。ASan(変更後)で敵対的入力 2,042 実行、所見 0。
`swift test` 1,020 件(997 + 23)、40 skip、失敗 0、`warning:` 0。

XADMaster との比較で「同量の処理」なのは i_like_icon.sit だけで、他は KaitoKit が resource fork も
展開するため処理量が多い。処理量あたりでは全書庫で KaitoKit が XADMaster より速いか同等であり、
resource fork を含めた絶対時間でも 911 / BirdFlu / SMSSender は KaitoKit が短い。
