# LZMA / LZMA2 bit tree 先読みの検証(2026-09-12)

対象: `perf/lzma-bit-tree-preload`、bd `cooViewer-r897`。
基準 A は `origin/main` = `8a2efbeff4c6b9070848ced589ec72b89f9476d1`。

採用形は、設計パネルの提案パッチ(通常木・逆順木・plain literal 木で子の確率を先読みし、
`decodeBit(probability:store:)` と pointer wrapper を分ける)**そのまま**である。
`literal 木の手展開`は採用しない。`@_transparent` も付けない。

**結果: book-solid.7z −14.3%、book-tiff.7z −10.7%、両書庫の total digest は基準と一致、
`swift test` 失敗 0。** tiff の 10% 以上短縮と solid 非悪化の両条件を満たす。

## 4 変種の A/B(この記録の主要な証拠)

最初の実装は「literal 木を深さ 8 に手展開する」逸脱を含んでおり、book-solid.7z が
+31%(`@inline(__always)` のみ)、`@_transparent` を足しても +18% 退行した。
逸脱の根拠は、設計検討の「literal 木を loop に戻すと solid が +40% 遅くなる」という
先行主張だった。その主張と実測が正面から食い違ったため、**同一コミットから 4 つの
binary を作って直接比較した**。

| 変種 | 内容 |
|---|---|
| BASE | `origin/main` |
| HU | 提案パッチ + literal 木の手展開 + `@_transparent` |
| LOOP | 提案パッチ(literal は loop)+ `@_transparent` |
| LOOPQ | 提案パッチそのまま(`@_transparent` なし)= **採用形** |

4 binary の SHA-256 はすべて異なる。

| 変種 | SHA-256 |
|---|---|
| BASE | `de5e41d7814b977d7a48c232f56fdd3acd35369b662032bbaa03347bd633dcee` |
| HU | `fe2d17dfb499584e6baaafa22401f62d514c4c5c8da8f60655547c7509c2f876` |
| LOOP | `c7594d3d3a2344d0e17ab8dfb530838323c5d1e05daae2ae283daa4a79805648` |
| LOOPQ | `8542fb2f8099ea63becc1b3668689d1e214592bbb5728db2ae2ae6568391167e` |

4 変種とも両書庫の total digest は一致した(book-solid.7z 200 entry
`5ffea8f37ce097435251c538c33adc6e275e394df46f28f026dcda90f30d0044`、
book-tiff.7z 100 entry
`896dc342532bb7b7b19f7d9864e87cd56ce22d57bc2704f7f3618cb72449aa72`)。
展開 byte 数も全実行で solid 403,014,550 / tiff 384,498,400 で一致。
したがって 4 変種は復号結果として等価であり、差は codegen だけである。

各組み合わせを交互 5 巡(各巡 3 回展開の中央値)で測定した。
「各巡 B/A の中央値」を判定に用いる。

### book-solid.7z

| B の変種 | A median ms | B median ms | 各巡 B/A の中央値 | 範囲 | 時間の変化 |
|---|---:|---:|---:|---|---:|
| HU | 9523.731 | 11203.725 | **1.1791** | 1.1734〜1.1925 | +17.9% |
| LOOP | 9707.165 | 8399.130 | **0.8637** | 0.8459〜0.8817 | −13.6% |
| LOOPQ（採用） | 9822.633 | 8474.812 | **0.8573** | 0.8542〜0.8803 | −14.3% |
| A/A | 9400.837 | 9397.586 | 0.9982 | 0.9708〜1.0029 | — |

### book-tiff.7z

| B の変種 | A median ms | B median ms | 各巡 B/A の中央値 | 範囲 | 時間の変化 |
|---|---:|---:|---:|---|---:|
| HU | 518.866 | 462.381 | 0.8943 | 0.8874〜0.9025 | −10.6% |
| LOOP | 515.094 | 462.225 | 0.8965 | 0.8952〜0.9015 | −10.4% |
| LOOPQ（採用） | 522.022 | 467.380 | **0.8931** | 0.8814〜0.8994 | −10.7% |
| A/A | 513.057 | 512.998 | 0.9999 | 0.9977〜1.0116 | — |

「時間の変化」は各巡 B/A の中央値から求めた値であり、median 同士の比とは小数第 1 位で
ずれることがある(例: LOOPQ solid は median 比 0.8628、各巡 B/A 中央値 0.8573)。

### book-solid.7z の各巡

| 巡 | HU A | HU B | HU B/A | LOOP A | LOOP B | LOOP B/A | LOOPQ A | LOOPQ B | LOOPQ B/A | A/A A | A/A B | A/A B/A |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 9207.871 | 10980.490 | 1.1925 | 9646.740 | 8342.777 | 0.8648 | 9822.633 | 8390.094 | 0.8542 | 9906.777 | 9617.339 | 0.9708 |
| 2 | 9393.879 | 11073.193 | 1.1788 | 9593.013 | 8285.038 | 0.8637 | 9698.468 | 8314.717 | 0.8573 | 9507.223 | 9397.586 | 0.9885 |
| 3 | 9548.009 | 11203.725 | 1.1734 | 9751.090 | 8399.130 | 0.8614 | 9662.464 | 8505.456 | 0.8803 | 9400.837 | 9384.348 | 0.9982 |
| 4 | 9523.731 | 11248.064 | 1.1811 | 9707.165 | 8558.957 | 0.8817 | 9935.905 | 8527.639 | 0.8583 | 9360.988 | 9388.506 | 1.0029 |
| 5 | 9561.922 | 11274.737 | 1.1791 | 10003.523 | 8462.274 | 0.8459 | 9899.053 | 8474.812 | 0.8561 | 9396.231 | 9400.762 | 1.0005 |

### book-tiff.7z の各巡

| 巡 | HU A | HU B | HU B/A | LOOP A | LOOP B | LOOP B/A | LOOPQ A | LOOPQ B | LOOPQ B/A | A/A A | A/A B | A/A B/A |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 509.102 | 459.454 | 0.9025 | 517.063 | 466.142 | 0.9015 | 517.894 | 464.434 | 0.8968 | 533.804 | 532.656 | 0.9978 |
| 2 | 514.023 | 459.667 | 0.8943 | 514.350 | 461.093 | 0.8965 | 528.678 | 467.380 | 0.8841 | 513.057 | 512.998 | 0.9999 |
| 3 | 518.914 | 464.994 | 0.8961 | 515.094 | 461.115 | 0.8952 | 521.405 | 468.969 | 0.8994 | 512.193 | 518.151 | 1.0116 |
| 4 | 518.866 | 463.704 | 0.8937 | 516.913 | 463.251 | 0.8962 | 531.239 | 468.216 | 0.8814 | 513.495 | 512.308 | 0.9977 |
| 5 | 521.075 | 462.381 | 0.8874 | 513.710 | 462.225 | 0.8998 | 522.022 | 466.235 | 0.8931 | 511.212 | 512.548 | 1.0026 |

A/A ノイズ床(solid 0.9708〜1.0029、tiff 0.9977〜1.0116)より、
HU の solid 退行も LOOP / LOOPQ の改善もはるかに大きい。
LOOPQ は両書庫で 3 変種中の最良であり、これを採用した。

## 覆った先行主張

設計検討の「literal 木の手展開を loop に戻すと book-solid が +40% 遅くなる」は
**否定された**。実際には loop 形(LOOPQ)が solid の最速形であり、
手展開こそが +17.9% の退行源だった。
この主張を根拠に実装へ手展開の逸脱を指示したのは誤りである。

同じ先行検討にある次の 2 件は今回再測していない。確定した根拠としては扱わない。

| 先行主張 | 状態 |
|---|---|
| bit 復号本体の手書き branchless 化は +5.4〜6.3% | 未再測 |
| `normalize()` の branchless 化は tiff +7%、solid +55% | 未再測 |
| literal 木の loop 化は solid +40% | **実測で否定(loop が最速)** |

入力分解(tiff は match symbol 約 97%、solid は literal 約 99%)は変わらず、
match 側 tree が tiff を、literal tree が solid を支配する。
片方だけを直すともう片方はノイズに埋もれるため、3 種すべての tree に先読みを入れている。

## 変更と不変条件

- `decodeBit(probability:store:)` に読み出し済みの確率を渡し、旧 signature は wrapper とした。
  `let bound` から `return bit` までの本体は変更していない。
- 通常木・逆順木・plain literal 木で子二つの確率を先読みし、復号 bit で選ぶ。
  最終段では先読みしない。逆順木の `bitCount == 0` は確率を load せず 0 を返す。
- 先読み段 k(0 起点)では `symbol < 2^(k+1) ≤ 2^(bitCount-1)`。
  よって `2s+1 ≤ 2^bitCount − 1` となり、従来の最終段の書込み範囲内に収まる。
  padding は追加していない。
- `normalize()`、`decodeDirectBits`、確率表のサイズと配置、matched literal の経路、
  literal-run の early exit、batch の呼出構造は変更していない。

実装の入力は設計パネルの提案パッチと既存 KaitoKit コードのみ。
XADMaster、7-Zip、xz、liblzma、その他 LZMA 実装の source は参照していない。

## 環境と再現手順

Apple M4 Max(16 cores: 12 performance / 4 efficiency、128 GB)、
macOS 27.0(26A428)、arm64、Apple Swift 6.4
(swiftlang-6.4.0.34.1、clang-2100.3.34.1)、SwiftPM release の `kaito`。

4 変種は同じ `origin/main` から作った source tree をそれぞれ release build したもので、
binary は本セッションの一時領域 `scratchpad/p2/lzma3/bin/kaito-{BASE,HU,LOOP,LOOPQ}` に置いた
(セッション終了で失われるため、各巡の全値は上表に転記してある)。
測定は build・test・digest 比較の完了後に、他の重い処理と並走させずに実行した。
各書庫を warm cache にしてから、各巡 A→B の順に別プロセスを交互に起動する。
`kaito bench ARCHIVE 3` が全 entry を 3 回展開し `extract-median-ms` を報告する。

```sh
B=<scratchpad>/lzma-bench
W=<scratchpad>/p2/lzma3
A="$B/work/corpus/archives"
for v in HU LOOP LOOPQ; do
  "$B/ab.sh" $W/bin/kaito-BASE $W/bin/kaito-$v "$A/book-solid.7z" 5 3 "$W/res/solid-$v.tsv"
  "$B/ab.sh" $W/bin/kaito-BASE $W/bin/kaito-$v "$A/book-tiff.7z"  5 3 "$W/res/tiff-$v.tsv"
done
"$B/ab.sh" $W/bin/kaito-BASE $W/bin/kaito-BASE "$A/book-solid.7z" 5 3 "$W/res/solid-AA.tsv"
"$B/ab.sh" $W/bin/kaito-BASE $W/bin/kaito-BASE "$A/book-tiff.7z"  5 3 "$W/res/tiff-AA.tsv"
python3 "$B/summarize.py" <tsv>
```

`ab.sh` は TSV に追記するため、再実行時は未使用のファイル名を指定する。
全 8 本の TSV は本セッションの一時領域 `scratchpad/p2/lzma3/res/` にある(揮発)。

## コーパスの同定

| 書庫 | SHA-256 |
|---|---|
| book-tiff.7z | `1441e766f3db1dbf9027101be955b96b61ef6fb88bbd242bff490b8ca54b9d38` |
| book-solid.7z | `031311639b7de30a8b09b1d1e5b74dfdac837b304a8423e7f5e20d0745e99e75` |

## ビルドとテスト

採用形(LOOPQ)の作業木で `swift build -c release --product kaito` と `swift test` を実行し、
いずれも終了 0、compiler warning / error は 0 だった。

| bundle | 件数 | skip | 失敗 |
|---|---:|---:|---:|
| KaitoKitTests.xctest | 882 | 38 | 0 |
| KaitoKitCompatTests.xctest | 22 | 0 | 0 |
| 合計 | **904** | 38 | **0** |

Swift Testing の別 runner は 0 tests で正常終了した。
テストログは本セッションの一時領域 `scratchpad/p2/lzma3/test-final.log`(揮発)。
`warning:` の出現は build・test とも 0 件であることを grep で確認した。
