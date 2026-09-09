# 7z branch filter (SPARC / IA-64 / RISC-V) の black-box 導出 — 2026-09-09

design.md §10 の許可資料(LZMA SDK の `Methods.txt` / `7zFormat.txt` /
`lzma-specification.txt`)は filter の **ID と container** は定めるが、
**変換そのもの**を定義していない。そこで変換規則を実行ファイルだけを使って
導出した。禁止対象 source は開いていない。

## オラクルの作り方

7-Zip は `-m1=Copy` を指定すると filter の出力を無圧縮のまま packed stream に
書く。`-mhc=off` でヘッダも平文にすると、packed data は署名 32 byte 直後から
始まる。したがって

```
7zz a -t7z -mhc=off -m0=<FILTER> -m1=Copy out.7z probe.bin
dd if=out.7z bs=1 skip=32 count=<size>   # = filter(probe.bin)
```

で任意の入力に対する **filter の encode 出力**が直接読める。これは実行ファイルの
入出力だけを使う black-box 観測で、§10 の「ブラックボックスの展開オラクル」に当たる。

## SPARC

上位 2 bit が `01` の語(SPARC CALL)だけが変換される。`00` / `10` / `11` の語は
そのまま(24 語の網羅 probe で確認)。

適用条件と変換は次のとおりで、6 回 × 8,192 byte の敵対的乱数ベクタで
オラクルと完全一致した(不一致 0)。

```
4 byte 境界ごと、big endian。
適用条件: (b0 == 0x40 && (b1 & 0xC0) == 0) || (b0 == 0x7F && (b1 & 0xC0) == 0xC0)
encode:   src  = word << 2
          dest = src + offset          (decode は - offset)
          dest >>= 2
          word = (0x40000000 - (dest & 0x400000)) | 0x40000000 | (dest & 0x3FFFFF)
```

`offset` は書庫内の byte 位置。`0x40000000 - (dest & 0x400000)` の項が
22 bit 変位の符号拡張を再構成する。

## IA-64

16 byte の bundle 単位。下位 5 bit の template が、どの slot が分岐命令かを決める。
template 0〜31 を総当たりした結果、変換される slot は次のとおり。

| template | 変換される slot | mask |
|---|---|---:|
| 0x10, 0x11 | 2 | 4 |
| 0x12, 0x13 | 1, 2 | 6 |
| 0x16, 0x17 | 0, 1, 2 | 7 |
| 0x18, 0x19 | 2 | 4 |
| 0x1C, 0x1D | 2 | 4 |
| その他 | なし | 0 |

slot は bundle の bit 5 から 41 bit ずつ。opcode を bit 37〜40 で総当たりすると
**5 だけ**が変換される。さらに bit 9 / 10 / 11 のいずれかが 1 だと変換されない
(1 bit ずつの感度 probe で確認)。

```
inst = (bundle >> (5 + 41*slot)) & (2^41 - 1)
適用条件: ((inst >> 37) & 0xF) == 5 && ((inst >> 9) & 0x7) == 0
encode:   src  = ((inst >> 13) & 0xFFFFF) | (((inst >> 36) & 1) << 20)
          src <<= 4
          dest = src + offset          (decode は - offset)
          dest >>= 4
          inst &= ~(0x8FFFFF << 13)
          inst |= (dest & 0xFFFFF) << 13
          inst |= ((dest >> 20) & 1) << 36
```

`offset` は bundle 先頭の byte 位置。6 回 × 8,192 byte の敵対的 bundle ベクタで
オラクルと完全一致した(不一致 0)。

## RISC-V(実装しない)

opcode を 0x00〜0x7F まで総当たりすると、単独語で変換されるのは `0x6F`(JAL)
だけである。ただし観測された変換は immediate への加算ではなく語全体の再配置
(`0x123450ef` → `0x6f2d20ef`)で、さらに AUIPC (`0x17`) と後続命令の**対**を
まとめる経路がある。単語 probe では対の経路に到達できず、導出には別種の
実験計画が要る。

一方 XADMaster も RISC-V filter 付き 7z を **全 entry 0 バイト**で返すため
(2026-09-09-xadmaster-feature-gap.md 結果 2)、これは XADMaster との差ではない。
費用に見合わないため実装せず、`7z method 0x0B` として明示的に失敗させる現状を保つ。

## 固定ベクタ

導出の裏づけとして、オラクル出力そのものを固定テストに入れる。

| ファイル | 中身 | SHA-256 |
|---|---|---|
| `Tests/Fixtures/sevenzip/sparc-vector-plain.bin.b64` | 4,096 byte の probe | `42355772e089ee253ca6b361993156c6fd50dd9dea78110d7f387e8c4b1ac6d1` |
| `Tests/Fixtures/sevenzip/sparc-vector-filtered.bin.b64` | 7zz の SPARC filter 出力 | `678c8ff2903b5b39ac5e4cb34a426cae7a2bc6e131617a162302a93a464b5488` |
| `Tests/Fixtures/sevenzip/ia64-vector-plain.bin.b64` | 4,096 byte の probe | `ed1eb85d618010a3cec4e1cbc429e3de3671a387f1d1ce2bb2e1c19a42a88f40` |
| `Tests/Fixtures/sevenzip/ia64-vector-filtered.bin.b64` | 7zz の IA-64 filter 出力 | `a91802db740401e17d61f724c4bb403a82bf68a303af96ad591662e5782b7c30` |

decode 方向の実装は、filtered を入力として plain を再現できなければならない。
