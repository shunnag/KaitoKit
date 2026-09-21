# 7z Zstandard coder（04 F7 11 01）の読み取り追加（2026-09-20）

環境: macOS 27.2 / Apple Silicon / 7-Zip 26.03 / Homebrew libarchive 3.8.9（`bsdtar`）/ zstd 1.5.7。

## 実装と範囲

- `SevenZipMethod` に method ID `04 F7 11 01` を `.zstd` として登録し、folder の packed stream を
  既存の `ZstdDecompressor`（RFC 8878、連結 frame と skippable frame 対応）で復号する。
  一覧の method 名は `Zstandard`。
- coder の properties は 3 byte または 5 byte だけを受理し、それ以外は `malformed`。
  復号には使わない（writer の zstd version と level の記録）。
- frame header の window は従来どおり `ReadLimits.maxDictionarySize`、entry サイズは reader が
  open 時に `maxEntrySize` / `maxTotalUncompressedSize` で検査する。codec には folder の宣言サイズを
  `maxEntrySize` として渡し、solid folder が entry 上限より大きくても codec 側で拒否しない。
  宣言サイズと frame の内容が食い違えば `malformed`。
- **非対応のまま**: 7-Zip ZS の LZ4（04 F7 11 04）/ Brotli（04 F7 11 02）/ LZ5 / Lizard coder、
  zstd の外部辞書（Dictionary_ID 非零は従来どおり `unsupportedMethod`）。

実装入力は 7-Zip の公式 `DOC/Methods.txt`（24.02、SHA-256
`e7eacd2230f86de6348cb9f9ca077e5de27930475068fef1d52ba9480b8cf333`。`04 F7 11 xx` は
Tino Reichardt の external codec 予約領域、`01 = ZSTD`）、RFC 8878（既存 `inbox/zstd/rfc8878.txt`）、
既存 KaitoKit の 7z coder graph と `ZstdDecompressor`、および Homebrew libarchive 3.8.9 の出力の
黒箱観察（packed stream は署名 header 直後から RFC 8878 の frame 列そのもの、properties は
`01 05 <level> 00 00` の 5 byte。fixture では level byte が `01` と `13`）だけである。
properties 長を 3 / 5 byte に限る規則は Methods.txt に無く、この writer の観察と調査時の 7-Zip ZS
の記述（3 byte 形）に基づく黒箱の判断である。7-Zip ZS / NanaZip / p7zip / libarchive の source は
開いていない。

## 独立した検証データ

`Tests/Fixtures/sevenzip-zstd/`（`generate.py`、`manifest.json`、`README.md`）:
`sevenzip-swap` と同じ project-owned 入力（`first.bin` 262,403 byte、`second.bin` 1,027 byte、
`empty`）を `bsdtar --format 7zip --options 7zip:compression=zstd,7zip:compression-level=N`
（N = 1, 19）で 1 solid folder の 7z にした 2 書庫。7zz 26.03 は coder を一覧できるが復号できない
（`Method = 04F71101`、`Solid = +`）ので、生成器は (a) `7zz l -slt` の Packed Size で切り出した
packed stream を zstd CLI で復号して member の連結と比較し、(b) 各 entry を `bsdtar -xOf` で
展開して原本と比較した。archive と entry の SHA-256 は manifest に記録。

インライン vector: `printf 'kaito-' | zstd --no-check`、`printf 'zstd' | zstd`、
`zstd -19 --no-content-size --no-check`（window 8 MiB を宣言）、および RFC 8878 §3.1.2 の
skippable frame を手で組んだもの。

## 通過した検証

- `SevenZipZstdTests` 6 件、失敗 0: method 表と隣接 ID の未対応維持、properties 長（3 / 5 は受理、
  0 / 1 / 2 / 4 / 6 は `malformed`）、入力数、宣言サイズの過不足、skippable + 連結 frame の 1 stream
  復号、末尾 skippable、切り詰め、fixture 2 書庫の一覧・逆順 stream・`reopen()`、
  `maxEntrySize` / `maxTotalUncompressedSize`（open 時）、`maxDictionarySize`（header LZMA 1 MiB）、
  `maxInMemorySize`、codec 単位の window 上限（8 MiB 宣言 vs 4 KiB 上限）。
- release CLI: 2 fixture と 2 MiB 乱数の libarchive 書庫（`t7.7z`）の `kaito sha` が原本と一致。

```
$ .build/release/kaito list zstd-l19.7z
0	262403	file	Zstandard	plain	first.bin
1	1027	file	Zstandard	plain	second.bin
2	0	file	Copy	plain	empty
$ .build/release/kaito sha zstd-l19.7z | tail -1
total	3	90da5999dc95240fc6d75eae2fd6ce79ba218d1c5a11a8ec063eeb146c5de508
```

## 残る制約

- 7-Zip ZS の multithread writer が書く実書庫（skippable frame で区切った chunk 列）は手元に
  writer が無く、インライン vector で同じ構造を検証した。
- `Scripts/fuzz/mutate.py` の 7z locator は packed 領域を method に関わらず特定するので、
  新 fixture もそのまま seed にできる。
