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

## 性能の残差

2026-09-08 の三系統ベンチ(`inbox/bench-2026-09-08/benchmark-report.md` §9.3)で、
KaitoKit がフォーク XADMaster に負けているのは LZMA/LZMA2 だけである。

| 書庫 | フォーク ms | KaitoKit ms | K/F |
|---|---:|---:|---:|
| `book-solid.7z`(LZMA2 solid) | 6,660.1 | 9,314.7 | 1.40 |
| `book-tiff.7z`(LZMA2) | 396.5 | 497.3 | 1.25 |
| `book-tiff-rar4.cbr` | 313.9 | 379.0 | 1.21 |

RAR4 は本 session の provenance 制約(§10 の 2026-09-09 開示)で対象外。
LZMA/LZMA2 を cooViewer-9tlo として追う。
