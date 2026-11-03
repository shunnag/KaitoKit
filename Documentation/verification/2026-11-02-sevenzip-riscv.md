# 7z RISC-V filter (method 0x0B) の導出と検証 — 2026-11-02

## 範囲と資料

7z の RISC-V branch filter を `BCJFilterDecompressor` に追加した。XZ の同 ID filter は別課題
（`cooViewer-zu1v`）であり、今回は変更していない。

実装入力は RISC-V の公開命令形式、既存の `Decompressor` 契約、7-Zip 26.05 (`7zz`) の
black-box 入出力だけである。第三者の decoder source や実装解説は参照していない。
2026-09-18 に検索結果へ実装断片が表示された incident は `Documentation/design.md` §10 に
残してあり、今回の規則は実行ファイルへの probe から独立に再導出した。

filter 出力は `-m1=Copy -mhc=off` で署名 32 byte 直後から読める。

```
7zz a -t7z -m0=RISCV -m1=Copy -mhc=off probe.7z probe.bin
7zz x -so probe.7z > restored.bin
```

変換済みでない任意の packed byte に対する復号も、同じ形の小さな 7z の packed stream だけを
差し替えて観測した。この probe は CRC が元入力のものなので警告を伴うが、変換規則の観測にだけ
使い、採用した fixture はすべて通常の `7zz x` の CRC 検証を通した。

## 復号規則

以下の演算は 32 bit の wrapping arithmetic。`pc = startOffset + i`、`LE` / `BE` はそれぞれ
little / big endian の 32 bit 読み取りを表す。`i + 8 <= size` の間だけ処理し、最後の 7 byte
以内は変換せず返す。入力・出力の byte 数は同じである。

### JAL

opcode `0x6F` で `rd` が 1 / 5 の語だけを変換する。他の `rd` は変換しない。

```
target = ((first & 0xFF000000) >> 23)
       | ((first & 0x00FF0000) >> 7)
       | ((first & 0x0000F000) << 5)
immediate = (target - pc) & 0x1FFFFF
```

`immediate` を公開命令形式どおり `imm[20] / imm[10:1] / imm[11] / imm[19:12]` に
配置し、元の `rd` と opcode を保つ。処理後は 4 byte 進む。

### AUIPC と後続命令

opcode `0x17` では次の語も読む。変換後の対は `rd = 2` で識別する。

`rd = 2` の場合、`low = first >> 12`、`originalRD = (low >> 15) & 31` とする。
`originalRD != 0, 2` かつ `(low & 3) == 3` なら、

```
target = BE(second) - pc
upper = (target + ((target & 0x800) != 0 ? 0x1000 : 0)) & 0xFFFFF000
first = upper | (originalRD << 7) | 0x17
second = ((target & 0xFFF) << 20) | low
```

として 8 byte 進む。`0x1000` の加算は、負の 12 bit 即値による借りを元の AUIPC 上位へ戻す。
条件を満たさない `rd = 0 / 2` は 4 byte 進む。

`rd != 0, 2` で、後続語の `rs1 == rd` かつ `(second & 3) == 3` のときは、

```
target = (first & 0xFFFFF000) | (second >> 20)
first = ((second & 0xFFFFF) << 12) | 0x117
second = target
```

として 8 byte 進む。この復号経路は PC を加えず、即値を連結する。対にならない場合は
6 byte 進む。それ以外の語は 2 byte 進むため、32 bit 語の中間にある JAL 風の byte 列を
一律に命令とみなすことはない。

### 縮小命令

`low2 != 3` の 16 bit 命令そのものを変換する経路はない。全 16 bit パターンのうち
`low2 != 3` の 49,152 個を 6 byte の未変換領域を挟んで 7zz に入力し、全 halfword が
無変換であることを確認した。縮小命令は 2 byte 整列と走査位置にだけ影響する。

## 独立モデルとの全 byte 比較

上記を Swift とは別の Python モデルに実装し、packed stream を差し替えた 7zz 復号と比較した。
乱数 seed は 20261102。不一致を規則へ反映するたびに全ケースを再実行し、最終モデルは次の
全ケースで一致した。

| 入力 | byte 数 | 7zz と一致 |
| --- | ---: | --- |
| 敵対的乱数 | 262,144 | 全 byte |
| JAL を含む 8,192 record | 131,072 | 全 byte |
| AUIPC 対を含む 8,192 record | 131,072 | 全 byte |
| 変換済み marker 形を含む 8,192 record | 131,072 | 全 byte |
| 混合 8,192 record | 131,072 | 全 byte |
| AUIPC の出力が JAL 形になる入力 | 16 | 全 byte |
| 長さ 1〜64 の末尾境界 | 各長 | 全 byte |

モデルだけでなく、7zz が通常の writer として生成した filter 出力をモデルが原本へ戻すことも
確認した。

## 固定ベクタ

16 byte ごとに JAL、AUIPC 対、marker、縮小命令前置、非対象レジスタ、対にならない AUIPC、
乱数を配した 256 record（4,096 byte、seed 20261102）を使用する。先頭は縮小命令なので、
先頭 2 byte を除いた入力と `startOffset = 2` でも同じ oracle を検証できる。
plain / filtered で 818 byte が異なる。

| fixture | SHA-256 |
| --- | --- |
| `riscv-vector-plain.bin.b64` | `cc8015e25a080a7080f0161c34d1f0267a82c0653834ca7bae73cc2b73becf38` |
| `riscv-vector-filtered.bin.b64` | `061cf92e119d3ab29bea43c38d6c42fef62e7c94ec6f10f058df5153323e52d7` |

`SevenZipFilterTests` は入力 / 出力 chunk をそれぞれ 1, 3, 4, 16, 17, 4,096 byte に変えた
36 組、非ゼロ開始位置、末尾の不完全な 2 byte 単位、奇数 start offset の拒否を検査する。
小さな JAL / AUIPC 固定ベクタと、既存の `branch-riscv.7z`（LZMA2、8,192 byte）も展開する。

## 最終検証

- `swift test -j 4 --filter SevenZipFilterTests`: 19 tests、0 failures。
- CLI の `kaito sha` で Copy / LZMA2、4,096 / 262,144 / 1,048,576 byte の 6 書庫を展開し、
  全て原本のサイズ・SHA-256 と一致した。7zz の展開も原本と全 byte 一致した。1 MiB 書庫は
  filter の 256 KiB 内部入力境界をまたぐ。
- `swift test -j 4`: KaitoKit 2,051 tests / 53 skipped / 0 failures、KaitoKitCompat 34 / 0。
  初回は実行ツールの 15 分上限で途中中断されたため、時間制限なしで全件を再実行して完了した。
- CI は [KaitoKit PR #82](https://github.com/shunnag/KaitoKit/pull/82) の checks で確認する。
