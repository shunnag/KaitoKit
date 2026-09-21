# 7z x86 BCJ / ARM64 filter の符号境界の折り返し修正（2026-09-20）

環境: macOS 27.2 / Apple Silicon / 7-Zip 26.03。実装入力は KaitoKit 自身のコードと、
7zz の `-m1=Copy -mhc=off` 出力（packed stream = filter の encode 出力。
[2026-09-09 の導出記録](2026-09-09-branch-filter-derivation.md) と同じ黒箱手法）だけで、
7-Zip / LZMA SDK / xz などの filter 実装ソースは開いていない。

## 再現

[候補調査](2026-09-20-format-candidates.md) の副産物として見つかったもの。2 MiB の乱数 payload を
x86 BCJ または ARM64 filter 付きで 7zz が書いた書庫を KaitoKit が `Checksum mismatch` にする。
`-m1=Copy` でも失敗するので LZMA2 ではなく filter の問題で、入力 chunk を 256 KiB / 64 KiB に
変えても不一致の位置と件数が同じ（x86: 8 byte、ARM64: 2 byte）だったので chunk 境界でもない。

## 原因（packed stream と原本の差分から）

- **x86**: offset 453,175 の `E8` 候補。原本の変位 0x00FE37FB に `ip + 5` を足すと 2^24 をまたぎ、
  7zz は `E8 37 22 05 FF`（0xFF052237）を書く。復号は `0xFF052237 - 0x6EA3C = 0xFEFE37FB` で止まって
  いたが、変位は 25 bit の符号付き値として保存されているので、bit 24 の符号で上位 byte を
  0x00 / 0xFF に正規化しないと元の 0x00FE37FB に戻らない。小さな fixture で通っていたのは、
  ip が小さいと加算が 2^24 をまたがないため。
- **ARM64**: offset 849,124 の ADRP。原本の page delta 0x1FF91 に `pc >> 12`（0xCF）を足すと 0x20060
  になり、7zz はこれを 18 bit の符号付き値として bit 17 を immhi の上位 3 bit へ符号拡張した
  0x90F00313 を書く。復号は `0x1E0060 - 0xCF = 0x1DFF91` をそのまま書き戻していたので、
  同じ 18 bit の折り返しと符号拡張が要る。

両方とも「変換対象の候補が現れ、かつ ip / pc との加減算が符号境界をまたぐ」場合だけ壊れるので、
乱数 payload では 1 MiB 前後から確率的に発生する（seeded payload では 1,048,576 byte でも失敗した）。

この折り返し規則は仕様書から読んだものではなく、上の 2 組の実測ペアから推定し、下記の
16 / 20 / 40 / 520 MiB の掃引と E8 高密度 payload で確認したものである。

## 修正

`Sources/KaitoKit/Codecs/Filters/BCJFilterDecompressor.swift`:

- `decodeX86`: 減算後の `destination` を `normalizeX86Displacement`（bit 24 が 1 なら上位 byte 0xFF、
  0 なら 0x00）に通してから書き戻す。lookback の内側 loop は変更しない。loop が見る `signByte` は
  shift 8 / 16 / 24 に対応する bit 0〜23 の範囲だけで上位 byte を参照しないため、正規化前の値でよい。
- `decodeARM64`: `decoded = (encoded - (pc >> 12)) & 0x3FFFF` とし、bit 17 が立っていれば
  `0x1C0000` を OR して 21 bit へ符号拡張してから immlo / immhi に分解する。
  ±2^17 pages の範囲 guard は変更しない。

## テスト

`Tests/KaitoKitTests/SevenZipBranchLargePayloadTests.swift`（6 件）:

- 固定ベクタ 4 件: 上記 2 箇所の実測値（`startOffset` 453,175 / 849,124）、16 MiB + 4 KiB の
  ゼロ埋め payload の offset 0x0100_0800 に置いた `E8 00 00 00 00` が `E8 05 08 00 FF` になる
  ip > 2^24 の実測値、および offset 0x00FF_FFF8 に置いた `E8 E8 00 00 12 00 00 00`（先頭の E8 は
  sign byte でない 0x12 のため変換されず previousMask を立て、offset 1 の E8 が mask の立った状態で
  2^24 をまたいで変換される）が `E8 E8 FE FF 11 FF 00 00` になる実測値。入力 chunk 1〜31 で照合。
- 7zz オラクル掃引: xorshift64* の seeded payload を 8 KiB / 256 KiB + 4 / 1 MiB / 1 MiB + 64 KiB /
  2 MiB / 4 MiB で作り、`-m0=BCJ|ARM64 -m1=Copy -mhc=off` の packed stream を `BCJFilterDecompressor`
  で復号して全 byte 比較。7zz が無ければ skip（`KAITO_REQUIRE_7ZZ=1` で必須）。
- `-m1=LZMA2` の 1 MiB + 64 KiB 書庫を `ArchiveReader` 経由で読み SHA-256 を照合。

修正前のコードでは固定ベクタ 3 件（453,175 / 0x0100_0800 / 849,124）と掃引・LZMA2 の計 5 件が失敗する（固定ベクタは全 chunk で不一致、掃引は BCJ 1 MiB が
byte 974,804 から、ARM64 1 MiB が byte 538,778 から不一致）。修正後は 6 件とも通過、既存の
`SevenZipFilterTests` 16 件も通過。

## 手動の掃引（release CLI、`kaito sha` と原本の SHA-256）

| payload | BCJ | ARM64 | ARM | ARMT | PPC | SPARC | IA64 |
|---|---|---|---|---|---|---|---|
| 2 MiB（再現書庫、LZMA2 と Copy） | 一致 | 一致 | — | — | — | — | — |
| 16 MiB / 20 MiB / 40 MiB（乱数、Copy） | 一致 | 一致 | 一致 | 一致 | 一致 | 一致 | 一致 |
| 520 MiB（乱数、Copy。ARM64 の `pc >> 12` が 2^17 を超える） | 一致 | 一致 | — | — | — | — | — |
| 20 MiB（E8 30% / E9 10% / 00 20% / FF 20% / 乱数 20% の高密度 payload、Copy。lookback の入れ子を多数含む） | 一致 | — | — | — | — | — | — |

```
$ for a in bcj arm64 bcj-copy arm64-copy plain; do .build/release/kaito sha .build/repro-bcj/$a.7z | head -1 | cut -f2,3; done
2097152	4c2c75eb71ba6bb4c4822897df667cd7369b246f7187c6150963e9eec6f9cb32
2097152	4c2c75eb71ba6bb4c4822897df667cd7369b246f7187c6150963e9eec6f9cb32
2097152	4c2c75eb71ba6bb4c4822897df667cd7369b246f7187c6150963e9eec6f9cb32
2097152	4c2c75eb71ba6bb4c4822897df667cd7369b246f7187c6150963e9eec6f9cb32
2097152	4c2c75eb71ba6bb4c4822897df667cd7369b246f7187c6150963e9eec6f9cb32
```

## 残る制約

- x86 の `ip` が 2^32 を超える書庫（4 GiB 超の folder）は手元で検証していない。演算は 32 bit の
  wrap なので規則は同じだが、実測はしていない。
- BCJ2 は別の decoder（`BCJ2Decompressor`）で、本件の影響を受けない（2 MiB で一致）。
