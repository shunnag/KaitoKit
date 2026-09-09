# XADMaster との機能差分の black-box 調査 — 2026-09-09

XADMaster に対して KaitoKit に足りていないものを測る。**XADMaster の source は
参照していない。** 比較は design.md §10 のとおり展開オラクル(実行ファイルの入出力)
だけで行った。同 session の provenance incident と是正は §10 に開示してある。

## 方法

- KaitoKit 側: `kaito detect` / `kaito list` / `kaito sha`(release build)。
- XADMaster 側: `Scripts/bench/xadsha`(`XADArchive` の public API だけを使う既存の
  オラクル)と、同じ API で「開けたか・形式名・件数」だけを返す `xadprobe`。
- 正解: 全書庫に同じ 5 ファイル(`a.txt` 9200B / `b.bin` 60000B / `c.rnd` 40000B /
  `sub/nested.md` 900B / `sub/日本語ファイル.txt` 1700B)を入れ、原本の SHA-256 と
  照合する。どちらが正しいかを両者の一致だけで判断しない。
- 書庫: 生成器のある形式を総当たりで 86 個(第 1 ラウンド 66、第 2 ラウンド 20)。
  `7zz` 25.x / `zip` / `rar` 6.24 / LHa for UNIX / `tar` / `xz` 5.8.3 / `gzip` /
  `bzip2` / `compress` / `zstd` / `lz4` / `brotli` / `cpio` / `ar` / `xar` / `hdiutil`。

## 結果 1: KaitoKit が失敗し XADMaster が正しく展開できるもの(実差分)

| 書庫 | XADMaster | KaitoKit | issue |
|---|---|---|---|
| `-m0=BCJ2 -m1=LZMA2 -m2=LZMA -m3=LZMA` の 7z | 正解 | `7z LZMA after a streaming coder` | cooViewer-6moc |
| ISO 9660 (`hdiutil makehybrid -iso -joliet`) | `ISO 9660` 6 件 | `tar` と誤判定して **0 件で成功** | cooViewer-ogfp |
| 先頭 1 KiB が 0 のファイル全般 | 開けない | `tar` と誤判定して **0 件で成功** | cooViewer-k8v4 |
| `7zz -m0=SPARC -m1=LZMA2` | 正解 | `Unsupported archive method: 7z SPARC filter` | cooViewer-k1jf |
| `7zz -m0=IA64 -m1=LZMA2` | 正解 | `Unsupported archive method: 7z IA64 filter` | cooViewer-k1jf |
| `7zz -tzip -mm=PPMd` | 正解 | `Unsupported archive method: 98` | cooViewer-th30 |
| `xz --format=lzma`(LZMA_Alone) | `LZMA_Alone` | `Unsupported archive format` | cooViewer-fvo8 |
| `7zz -v40k`(`.7z.001`) | 正解 | `7z next header extends past end of file` | cooViewer-1h3p |
| `cpio -H newc` / `-H odc` | `Cpio` | `Unsupported archive format` | cooViewer-7wbx |
| `ar rc` | `Ar` | `Unsupported archive format` | cooViewer-7wbx |
| `xar -cf` | `XAR` | `Unsupported archive format` | cooViewer-7wbx |
| `xz --riscv --lzma2` | 正解 | `Malformed archive: invalid XZ stream` | cooViewer-zu1v |
| RAR5 の前に実行ファイルを連結した SFX | `RAR 5` 6 件 | `Unsupported archive method: RAR5 SFX archive` | cooViewer-yd18 |

`.Z` で圧縮した tar だけ KaitoKit が中の tar を展開しない(`.gz`/`.bz2`/`.xz` は
7 件に展開する)。XADMaster も 1 件のままなので XADMaster との差ではないが、
KaitoKit 内部の非一貫として cooViewer-ocsk に分けた。

## 結果 2: KaitoKit のほうが正しい / 強いもの

| 書庫 | XADMaster | KaitoKit |
|---|---|---|
| `7zz -m0=ARM64 -m1=LZMA2` | 全 entry を **0 バイト**で返す | 正解 |
| `xz --arm64 --lzma2` | **0 バイト** | 正解 |
| `7zz -m0=RISCV -m1=LZMA2` | **0 バイト** | 明示的に unsupported |
| `zip -mm=XZ`(method 95) | **0 バイト** | 明示的に unsupported |
| 7z ヘッダ暗号化 (`-mhe=on`) | 開けない | 正解 |
| RAR5 ヘッダ暗号化 (`-hp`) | 開けない | 正解 |
| ZIP WinZip AES-256 | 1 件で打ち切り | 6 件すべて正解 |
| `tar.gz` / `tar.bz2` / `tar.xz` | 内側の tar を 1 件として返す | 7 件に展開する |

XADMaster が未知の filter で例外を出さず **空データを返す**のは実害のある挙動で、
KaitoKit の「知らない method は明示的に失敗させる」方針のほうが安全である。

ISO 誤判定の原因は ISO 側ではなく tar 検出側にある。ISO 9660 の先頭 32 KiB は
system area で全 0 であり、tar の終端標識(0 の 512 byte block 2 個)と一致するため
「空の tar」と判定される。1 KiB の 0 だけのファイルでも `kaito detect` は `tar` を返す。
tar 検出に「checksum の通る非 0 ヘッダが 1 個以上ある」ことを要求すれば直る。
XADMaster は同じファイルを開かない。

lha-unix の `a1` / `a2` は header level の指定であって method ではないため、
`-lh1-` / `-lh2-` の実書庫は今回作れていない。両者の比較は未実施である。

## 結果 3: 両者とも未対応(XADMaster との差ではない)

`.zst` / `.tar.zst`、`.lz4` / `.tar.lz4`、`.br`、`.wim`、`.dmg`(UDZO / UDRO)、
uuencode。

## 結果 4: 差の無かった領域(回帰確認)

ZIP(stored / deflate / deflate64 / bzip2 / LZMA / ZipCrypto / data descriptor /
20000 件 / NTFS 時刻 / ディレクトリ無し)、7z(Copy / LZMA / LZMA2 / PPMd / BZip2 /
Deflate / Delta / BCJ / ARM / ARMT / PPC / 既定 BCJ2 / AES)、RAR4(通常 / solid /
暗号化)、RAR5(通常 / solid / 分割)、LHA(`-lh0-` / `-lh5-` / `-lh6-` / `-lh7-`)、tar(ustar / pax / gnutar / 長名 / 深い階層)、gzip(名前付き /
多メンバ)、bzip2(多ストリーム)、xz(多ブロック / 多ストリーム / x86 / delta /
sparc)、compress。以上 60 書庫で総合 SHA-256 が一致した。

## 結果 5: 破損・切り詰めからの救済(最大の差)

`zip-deflate.zip` / `rar5.rar` / `lha-lh5.lzh` / `tar-ustar.tar` / `7z-lzma2.7z` を
先頭 90% / 60% / 30% に切り詰めた 15 書庫。

| 書庫 | XADMaster | KaitoKit |
|---|---|---|
| ZIP 90/60/30% | いずれも 6 entry、切断前の内容は原本と一致 | `ZIP end-of-central-directory record ...` で open 失敗 |
| RAR5 90/60/30% | 5 entry、内容一致 | `The archive is truncated` |
| LHA 90/60/30% | 3 entry、内容一致 | `The archive is truncated` |
| tar 90/60/30% | 5 / 4 / 2 entry、切断された entry は読めた分だけ返す | `The archive is truncated` |
| 7z 90/60/30% | 開けない(ヘッダが末尾) | `7z next header extends past end of file` |

XADMaster は 15 件中 12 件で救済し、KaitoKit は 0 件である。cooViewer は KaitoKit が
失敗すると XADMaster へ自動 fallback するので実害は表に出ていないが、**単体の
ライブラリとしてはこれが最大の機能差**である。cooViewer-7q8s に分けた。既定の
厳格さは security 上の設計なので、opt-in の救済モードとして足すのが筋である。

## 結果 5-2: その他の破損パターン

`cat /bin/ls <書庫>`(前置ゴミ)、`cat <書庫> /bin/ls`(後置ゴミ)、中央 1 byte の
bit 反転、RAR4 の分割。

| パターン | XADMaster | KaitoKit |
|---|---|---|
| 前置ゴミ ZIP / 7z / LHA | **開けない** | 6 件すべて正解(SFX 走査) |
| 前置ゴミ RAR5 | 6 件 | `RAR5 SFX archive` で失敗(cooViewer-yd18) |
| 後置ゴミ 4 形式 | 6 件 | 6 件 |
| bit 反転 4 形式 | 一覧は 6 件、壊れた entry は 0 バイトを返す | 一覧は 6 件、壊れた entry だけを checksum 不一致で失敗させる |
| RAR4 分割 | 6 件 | 6 件 |

bit 反転で XADMaster が黙って 0 バイトを返すのに対し、KaitoKit は
どの entry がどう壊れているかを返す。前置ゴミは RAR5 を除いて KaitoKit が強い。

## 結果 6: 名前の文字コード判定(差なし〜KaitoKit 優位)

CP932 名の LZH で XADMaster は `表計算①.txt` を percent escape に落とすが KaitoKit は
正しく復元する。CP932 名 2000 件の ZIP は両者とも正しい。4 件しか手がかりが無い
CP932 ZIP は両者とも判定に失敗するが、KaitoKit は byte を失わない。

## 結果 7: 第 3 ラウンド(2026-09-09 追加、fc8146e で再測)

`7zz` の timestamp / attribute 保存、空ファイル・空ディレクトリ・symlink、
RAR4 の旧形式分割(`.r00`)、RAR4 / RAR5 の recovery record、gzip の
FEXTRA+FNAME+FCOMMENT+FHCRC 全部入り、GNU sparse tar、`.lzma`、`.tar.lzma`、
LHA の空 member を含む 14 書庫。

`t.lzma` と `tar.tar.lzma` は fc8146e で XADMaster と一致するようになった
(それ以前は `Unsupported archive format`)。残り 11 書庫も総合 SHA-256 が一致。

唯一違うのは RAR5 の symlink で、XADMaster が 0 バイトを返すのに対し
KaitoKit は link target の 9 byte(`empty.txt`)を entry のデータとして返す。
これは `linkTargetStoredAsData` という意図した設計(design.md §11)であって
欠落ではない。

## 修正後の再測(2026-09-09)

第 1 ラウンドの 66 書庫を、7z coder 連鎖・LZMA_Alone・`.tar.Z`・SPARC / IA-64 filter を
入れたあとで測り直した結果。

| 分類 | 件数 | 内訳 |
|---|---:|---|
| 総合 SHA-256 が一致 | 40 | 修正前 34 から +6(7z BCJ2 連鎖・SPARC・IA-64・`.lzma`・`.tar.Z` ほか) |
| KaitoKit が正しく XADMaster が誤る | 3 | 7z ARM64 filter、7z / RAR5 の header 暗号化 |
| XADMaster が正しく KaitoKit が誤る | **7** | ISO 9660(tar 誤判定)、ZIP method 98、7z 分割、cpio × 2、ar、xar |
| 両者とも扱えない | 8 | `.zst` / `.lz4` / `.br` / `.wim` / `.dmg` / uuencode / zip method 95 / 7z RISC-V |
| 意味論の違い(欠落ではない) | 8 | 圧縮 tar の展開(KaitoKit は中の entry を返す)、RAR5 symlink、ZIP AES-256 の全件列挙 |

残る 7 件は cooViewer-ogfp / cooViewer-k8v4 / cooViewer-th30 / cooViewer-1h3p /
cooViewer-7wbx に分けてある。切り詰めからの救済(cooViewer-7q8s)は
この表とは別枠で、依然として最大の差である。

## cooViewer から見た優先度

cooViewer の `SupportedTypes.archiveExtensions` は
`zip / cbz / rar / cbr / lzh / lha / 7z / sit` と、3 桁の番号系列
(`r00`〜`r99`、`z01`〜`z99`、`000`〜`099`)である。したがって

- **`.7z.001` は cooViewer が開く**(`001` が分割書庫の先頭巻として通る)。
  KaitoKit が開けないので常に XADMaster へ fallback している。cooViewer-1h3p を
  P1 に上げた。
- **`.sit`(StuffIt)も開く宣言をしている**が、KaitoKit に reader が無い。
  書き手が手元に無いため今回の実測には含まれていないが、
  `Sources/KaitoKit/Formats` に StuffIt が存在しないことは確認した。cooViewer-gu28。
- cpio / ar / xar / ISO 9660 は cooViewer の対象拡張子ではないので、
  ライブラリ単体としての差分であり cooViewer への影響は無い。

切り詰めからの救済(cooViewer-7q8s)は拡張子に関係なく効くので、
cooViewer 利用者にとってはこれが最も影響の大きい差である。

## 性能の残差と、そこで否定した 5 つの仮説

2026-09-08 の三系統ベンチ(§9.3)で、KaitoKit がフォーク XADMaster に負けて
いるのは LZMA/LZMA2 だけである。

| 書庫 | フォーク ms | KaitoKit ms | K/F |
|---|---:|---:|---:|
| `book-solid.7z`(LZMA2 solid、1.2 GB) | 6,660.1 | 9,314.7 | 1.40 |
| `book-tiff.7z`(LZMA2、384 MB) | 396.5 | 497.3 | 1.25 |
| `book-tiff-rar4.cbr` | 313.9 | 379.0 | 1.21 |

RAR4 は本 session の provenance 制約(design.md §10 の 2026-09-09 開示)で対象外。

### 律速の特定

`sample` の top-of-stack は書庫によって全く違う。

- `book-tiff.7z`(TIFF、match が多い): `decodeLZMANewMatchBatch` 204 /
  `AccelerateCrypto_SHA256_compress` 71 / `_platform_memmove` 30 /
  `LZMADecoder.read` 25 / `decodeLZMARepeatedMatchSymbol` 15。
- `book-solid.7z`(JPEG、literal が支配的): `decodeLZMALiteralRun` **8,636** /
  `decodeLZMANewMatchBatch` 799 / `pread` 369 / `LZMADecoder.read` 146 /
  `_platform_memmove` 57 / zlib CRC32 **7**。

CRC32 の寄与は 7 sample しかないので、checksum を削る方向の改善は無い。
1.40 倍の書庫では時間の 87% が literal の 8 bit 木そのものである。

instrumented copy で呼び出し回数も採った(本体には入れていない)。

| 書庫 | matchBatch 呼出 | match/呼出 | literalRun 呼出 | literal/呼出 |
|---|---:|---:|---:|---:|
| `book-tiff.7z` | 1,334,916 | 4.13 | 99,000 | 1.70 |
| `book-solid.7z` | 16,228,748 | 1.06 | 16,082,783 | 19.09 |

### 試して否定した 5 案

いずれも `book-tiff.7z` / `book-solid.7z` で base と交互に回し、総合 SHA-256 の
一致を確認したうえでの中央値。採用閾値は 3%。

| 案 | 結果 |
|---|---|
| 3 つの hot 関数から `@inline(never)` を外す | 差 1% 未満、方向も一定しない |
| `decodeBit` を mask/select の branchless 形にする | **3.5% 悪化**(3 ラウンドとも同方向) |
| literal 木の子 (2s, 2s+1) を 32-bit で一度に読み、次段の load を重ねる | **47% 悪化** |
| range state を struct+`inout` から scalar local へ開く | **7% 悪化** |
| pread から `mappedIfSafe` へ | 僅かに悪化 |

`decodeLZMAPlainLiteral` は既に 8 段完全展開済みで、branchless 化も先読みも
手展開も逆効果だった。**既存の LZMA 復号器は Swift としては既に局所最適**で、
残る 1.25〜1.40 倍は微調整では埋まらない。次に試すなら literal の 8 bit 逐次
依存鎖そのものを短くする構造(range register の拡幅で normalize 頻度を下げる等)
だが、復号結果の bit 一致を壊す危険があるため独立した課題として扱う。
cooViewer-9tlo に測定値ごと記録した。
