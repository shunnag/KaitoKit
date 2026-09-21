# ISO 9660 zisofs（Rock Ridge ZF）の展開追加（2026-09-20）

環境: macOS 27.2 / Apple Silicon / GNU xorriso 1.5.8.pl02 / libarchive 3.7.4（OS 同梱 bsdtar）と
3.8.9（Homebrew）/ 7-Zip 26.03。

## 実装と範囲

- Rock Ridge の ZF entry（length 16、version 1、algorithm `pz`、header size 4、log2 block 15〜17、
  展開後サイズ 7.3.3）を `ISOZisofsInfo` として読み、単一 extent の file だけに適用する。
  entry の `uncompressedSize` は展開後サイズ、`compressedSize` は extent 長、method は
  `zisofs (zlib)`、`formatSpecific["zisofsBlockSize"]` に block size。
- `ISOZisofsDecompressor` は file 本文の 16 byte header（magic `37 E4 53 96 C9 DB D6 07`、サイズ、
  header size、log2、予約 0）を ZF と照合し、`ceil(size / block) + 1` 個の 4 byte pointer を
  `maxMetadataSize` の範囲で一度読み、単調非減少・表の直後以降・extent 内を検証する。block は
  zlib（RFC 1950、`DeflateDecompressor(zlibWrapped:)`）で展開し、長さ 0 の pointer 区間は 0 埋め
  block として返す。各 block の出力長は block size（末尾は残り）に一致しなければ `malformed`、
  合計も宣言サイズに一致しなければ `malformed`。
- ZF の version が 1 でない、algorithm が `pz` でない、header size / log2 が範囲外、entry が短い、
  multi-extent の file に付いている: `formatSpecific["unsupported"] = "zisofs"`（multi-extent は
  `"zisofs multi-extent"`）のまま `stream` は `unsupportedMethod`。version ≠ 1 の SUSP entry は
  通常読み飛ばすが、ZF だけは圧縮本文をそのまま返さないために unsupported を立てる。
- 付随修正: 長さ 0 の extent は LBA を検証しない。libarchive の iso9660 writer は空 file と
  symlink の LBA に `0xFFFFFFF0` を書くため、bsdtar 製 ISO 全体が open 時に `truncated` に
  なっていた（zisofs 以前からの非互換）。長さのある extent の範囲外 LBA は従来どおり拒否する。

実装入力は "Description of the zisofs Format"（Thomas Schmitt、libburnia、"distribute freely"。
`inbox/zisofs/zisofs_format.txt`、SHA-256
`8038f426a084ad4a560240739b0d8c3b5d98751c28b26b7d88b1004e955790b9`）、RFC 1950、ECMA-119 /
SUSP / RRIP の既存実装である。zisofs-tools / libisofs / Linux kernel / libarchive の source は
開いていない。xorriso と libarchive は黒箱 writer / reader としてだけ実行した。

## 独立した検証データ

`Tests/Fixtures/iso/zisofs-32k.iso.gz.b64` と `zisofs-128k.iso.gz.b64`（`generate-zisofs.py`）:
project-owned の 6 file（84,000 byte の反復 text、70,000 byte の全 0、0 と 8,000 byte 乱数の混在、
4 byte、空、`deep ` × 3,000）を xorriso `-zisofs level=9:block_size=32k|128k -set_filter_r --zisofs`
で書いた 133,120 byte の image を gzip + base64 で保存。原本の SHA-256 は generator が出力し、
テストに固定した。

libarchive の `bsdtar --format iso9660 --options zisofs` も試したが、text.txt の block 3 と 6 を
libarchive 自身が復号できず（`zisofs decompression failed (-3)`、Python zlib も
`incomplete or truncated stream` / `invalid distance too far back`）、writer としても reader
オラクルとしても使わなかった。xorriso の image は bsdtar と 7zz（一覧）が読める。

## 通過した検証

- `ISOZisofsTests` 6 件、失敗 0: 2 画像の全 file（両 block size、chunk 1 / 4,099 / 65,536、
  `reopen()`）、合成 body（データ / 0 埋め / 末尾の端数 block、128 KiB 宣言の 1 byte、末尾 0 埋め）、
  header 5 種と pointer 3 種の破損、block の過長 / 過短、壊れた zlib、表より短い extent、
  ZF の version 2 / 他 algorithm / header size / log2 14・18 / 短い entry の `unsupported`、
  multi-extent、entry 上限（extent 長と展開後サイズの両方）、長さ 0 extent の範囲外 LBA。
- `ISOReaderTests` 29 件（既存の `unsupported = "zisofs"` 期待を含む）が通過。
- release CLI: xorriso image の全 entry の `kaito sha` が原本と一致。bsdtar 製の plain / zisofs
  image も open でき、libarchive 自身が復号できない text.txt だけ `truncated` になる。
  下の一覧は fixture ではなく、開発中に作った 200,000 / 120,000 byte 入力の scratch image。

```
$ kaito list xo.iso
0	0	file	ISO 9660 (stored)	plain	empty
1	120000	file	zisofs (zlib)	plain	mixed.bin
2	4	file	ISO 9660 (stored)	plain	small.txt
3	0	directory	ISO 9660 (stored)	plain	sub
4	15000	file	zisofs (zlib)	plain	sub/deep.txt
5	200000	file	zisofs (zlib)	plain	text.txt
6	70000	file	zisofs (zlib)	plain	zeros.bin
```

## 残る制約

- zisofs2（ZF version 2、64 bit サイズ、他 algorithm）は未対応。
- block の zlib stream が pointer 区間より早く終わった場合の末尾 byte は検査しない
  （`DeflateDecompressor` が消費長を公開しないため）。区間外への読み出しは pointer 検査で防ぐ。
- `Scripts/fuzz/mutate.py` に zisofs の payload locator は追加していない（ISO 全体の locator も無い）。
