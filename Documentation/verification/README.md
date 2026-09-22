# 検証記録

設計書（[`../design.md`](../design.md)）の各追補が主張する数値の裏付けとなる、実行コマンドと
その出力をそのまま残した記録。ファイル名は `YYYY-MM-DD-<主題>.md` で、日付順に並ぶ。

本文中の絶対パスは `<repo>` / `<corpus>` / `<home>` / `<tmp>` に置換してある。コーパスや大きな実書庫は
リポジトリに含めないため、記録の再現には同じ書庫を用意する必要がある。

| 記録 | 日付 | 主題 | 対応するコミット |
| --- | --- | --- | --- |
| [2026-09-22-release-review-0.9.0.md](2026-09-22-release-review-0.9.0.md) | 2026-09-22 | 0.9.0 リリースレビュー R1〜R11、HFS+ / RPM の上限、tar・属性・file list の回帰テスト、文書整合 | v0.9.0 |
| [2026-09-22-sevenzip-deflate64.md](2026-09-22-sevenzip-deflate64.md) | 2026-09-22 | 7z Deflate64 coder 040109 の追加、7zz fixture、32 KiB を超える距離、上限・破損の検証 | v0.9.0 |
| [2026-09-22-small-method-gaps.md](2026-09-22-small-method-gaps.md) | 2026-09-22 | WIM XPRESS 4〜64 KiB chunk、XZ RISC-V のエラー分類、旧 GNU sparse tar の展開 | v0.9.0 |
| [2026-09-22-rpm-stripped-payload.md](2026-09-22-rpm-stripped-payload.md) | 2026-09-22 | RPM stripped cpio `07070X`、header file list、hard link / ghost / SHA-256、rpmbuild 6.1.0 の v4 / v6 照合 | v0.9.0 |
| [2026-09-22-hfsplus-decmpfs.md](2026-09-22-hfsplus-decmpfs.md) | 2026-09-22 | HFS+ decmpfs の属性・実サイズ・chunk 復号、新旧 fixture と単体検証、7-Zip の 5 type 展開照合、Apple 実物の type 4 / 8 照合 | v0.9.0 |
| [2026-09-22-release-review-0.8.1.md](2026-09-22-release-review-0.8.1.md) | 2026-09-22 | 0.8.0 レビュー R1〜R14 の再現・修正・回帰テスト（parser crash、AppleDouble、UDIF、sparse、Shrink、巻数・件数上限） | v0.8.1 |
| [2026-09-22-dmg.md](2026-09-22-dmg.md) | 2026-09-22 | Apple Disk Image（UDIF）と HFS+ の読み取り追加、hdiutil fixture の mount / 7-Zip 照合、extents overflow と hard link の確認 | v0.8.0 |
| [2026-09-21-arj.md](2026-09-21-arj.md) | 2026-09-21 | ARJ の読み取り追加、method 1〜3 = lh6 の黒箱確定（実物 11 書庫）、自作 writer / encoder fixture の 3 reader 照合 | v0.8.0 |
| [2026-09-21-chm.md](2026-09-21-chm.md) | 2026-09-21 | CHM（ITSF）の読み取り追加、LZX の reset interval / block の黒箱確定、自作 writer fixture の 7-Zip 照合、実物 2 本の一致 | v0.8.0 |
| [2026-09-21-cfb.md](2026-09-21-cfb.md) | 2026-09-21 | Compound File（MS-CFB）の読み取り追加、自作 writer fixture の 7-Zip 照合、MSI 名の制約 | v0.8.0 |
| [2026-09-21-bincue.md](2026-09-21-bincue.md) | 2026-09-21 | BIN/CUE 生 sector image（2352 / 2448 / 2336）の ISO / UDF 読み取り、`.cue` の解決、自作 wrapper fixture | v0.8.0 |
| [2026-09-21-zip-legacy.md](2026-09-21-zip-legacy.md) | 2026-09-21 | ZIP Shrink / Reduce / Implode の追加、部分クリア規約の黒箱確定、自作 encoder fixture の unzip / 7-Zip / deark 照合 | v0.8.0 |
| [2026-09-21-macwrappers.md](2026-09-21-macwrappers.md) | 2026-09-21 | MacBinary / AppleSingle / BinHex 単体（StuffIt でない payload）の公開、unar 照合 | v0.8.0 |
| [2026-09-21-wim.md](2026-09-21-wim.md) | 2026-09-21 | WIM の読み取り追加、LZX の WIM 変種の黒箱確定、XPRESS decoder、自作 encoder fixture の 7-Zip 照合 | v0.8.0 |
| [2026-09-21-appledouble.md](2026-09-21-appledouble.md) | 2026-09-21 | ZIP / tar の AppleDouble sidecar 方針（merge / hide / expose）、ditto・bsdtar fixture | v0.8.0 |
| [2026-09-21-udf.md](2026-09-21-udf.md) | 2026-09-21 | UDF 1.02〜2.60 の読み取り追加、hdiutil / newfs_udf fixture、macOS UDF driver 照合、sparable / VAT の合成検証 | v0.8.0 |
| [2026-09-20-stuffit-split.md](2026-09-20-stuffit-split.md) | 2026-09-20 | classic StuffIt 分割セットの連結、fork 復元、unar 照合 | v0.8.0 |
| [2026-09-20-tar-sparse.md](2026-09-20-tar-sparse.md) | 2026-09-20 | tar GNU sparse 0.0 / 0.1 / 1.0 の展開、bsdtar 照合 | v0.8.0 |
| [2026-09-20-pbzx.md](2026-09-20-pbzx.md) | 2026-09-20 | pbzx の黒箱計測と読み取り、圧縮 cpio の連鎖、PE 内 CAB | v0.8.0 |
| [2026-09-20-iso-zisofs.md](2026-09-20-iso-zisofs.md) | 2026-09-20 | ISO zisofs の展開、xorriso fixture、長さ 0 extent の LBA、libarchive writer の不具合 | v0.8.0 |
| [2026-09-20-rar5-file-copy.md](2026-09-20-rar5-file-copy.md) | 2026-09-20 | RAR5 file copy 参照の本文公開、solid / AES、上限の加算 | v0.8.0 |
| [2026-09-20-brotli.md](2026-09-20-brotli.md) | 2026-09-20 | brotli の追加、WBITS / large window の検査、試し復号による検出、Apple Compression の出力引き出し | v0.8.0 |
| [2026-09-20-lzip.md](2026-09-20-lzip.md) | 2026-09-20 | lzip の追加、member 索引、XZ Utils 照合、`.tlz` の判別 | v0.8.0 |
| [2026-09-20-sevenzip-zstd.md](2026-09-20-sevenzip-zstd.md) | 2026-09-20 | 7z Zstandard coder 04F71101 の追加、libarchive fixture、properties と上限 | v0.8.0 |
| [2026-09-20-sevenzip-bcj-large-payload.md](2026-09-20-sevenzip-bcj-large-payload.md) | 2026-09-20 | 7z x86 BCJ / ARM64 filter の符号境界の折り返し修正、7zz オラクル掃引 | v0.8.0 |
| [2026-09-20-format-candidates.md](2026-09-20-format-candidates.md) | 2026-09-20 | 追加できる形式の候補調査（出自・オラクル・再利用・工数）、7z BCJ/ARM64 filter の 1 MiB 超バグの再現、文書の陳腐化の修正 | v0.8.0 |
| [2026-09-19-release-review.md](2026-09-19-release-review.md) | 2026-09-19 | 圧縮tar再利用・中断・空き容量、tar先読み、7z KDF・solid、最大上限 | 未コミット |
| [2026-09-18-lz4-legacy.md](2026-09-18-lz4-legacy.md) | 2026-09-18 | LZ4 legacy・8 MiB境界・混在連結・CLI差分・上限 | 未コミット |
| [2026-09-18-lz4-frame.md](2026-09-18-lz4-frame.md) | 2026-09-18 | LZ4 frame・XXH32・圧縮tar・連結・skippable・上限 | 未コミット |
| [2026-09-18-sevenzip-swap.md](2026-09-18-sevenzip-swap.md) | 2026-09-18 | 7z Swap2/Swap4・solid・AES・分割・プレビューと編集 | 未コミット |
| [2026-09-18-zip-methods.md](2026-09-18-zip-methods.md) | 2026-09-18 | ZIP 20/95・暗号化・分割・編集・読み取り量の回帰 | 未コミット |
| [2026-09-17-release-hardening.md](2026-09-17-release-hardening.md) | 2026-09-17 | 圧縮tar別名、空LHA、XZの辞書上限、全件とsanitizer | 未コミット |
| [2026-09-08-performance-rar-lha.md](2026-09-08-performance-rar-lha.md) | 2026-09-08 | RAR29 と LHA の高速化（CRC16 の slice-by-eight 化、重複一致の周期コピー、静的 Huffman の一次 lookup） | `7a1d210` |
| [2026-09-08-performance-stability.md](2026-09-08-performance-stability.md) | 2026-09-08 | PPMd の毎シンボル検査除去と安定性の再確認 | `7a1d210` |
| [2026-09-08-review-fixes-verification.md](2026-09-08-review-fixes-verification.md) | 2026-09-08 | 敵対レビュー指摘（展開先を脱出する symbolic link を含む）の修正検証 | `7a1d210` |
| [2026-09-08-performance-rar5-ppmd.md](2026-09-08-performance-rar5-ppmd.md) | 2026-09-08 | RAR5 の周期コピーと 10bit Huffman lookup、PPMd の固定確率表 | `a70bd9d` |
| [2026-09-09-xadmaster-feature-gap.md](2026-09-09-xadmaster-feature-gap.md) | 2026-09-09 | XADMaster との機能差分の black-box 調査(86 書庫 + 破損 27 書庫) | `4f6c138` |
| [2026-09-09-sevenzip-singlefile-gaps.md](2026-09-09-sevenzip-singlefile-gaps.md) | 2026-09-09 | 7z coder 連鎖・LZMA_Alone・`.tar.Z` の実装と検証 | `fc8146e` |
| [2026-09-09-branch-filter-derivation.md](2026-09-09-branch-filter-derivation.md) | 2026-09-09 | SPARC / IA-64 branch filter の black-box 導出とオラクル固定ベクタ | `b18f11b` |
| [2026-09-09-iso9660.md](2026-09-09-iso9660.md) | 2026-09-09 | ISO 9660 reader(ECMA-119 / Joliet / Rock Ridge)の実装と XADMaster 比較 | `a1a2753` |
| [2026-09-09-ar.md](2026-09-09-ar.md) | 2026-09-09 | ar reader(BSD `#1/` / SysV `//` / symbol table / thin)の実装と XADMaster 比較 | `4466c30` |
| [2026-09-09-cpio-binary-recovery.md](2026-09-09-cpio-binary-recovery.md) | 2026-09-09 | 切り詰めた binary cpio の救済対応 | `94bc3f5` |
| [2026-09-09-cpio.md](2026-09-09-cpio.md) | 2026-09-09 | cpio reader(bin / odc / newc / crc / hpbin / hpodc)の実装と XADMaster 比較 | `94bc3f5` |
| [2026-09-09-xar.md](2026-09-09-xar.md) | 2026-09-09 | xar reader(TOC XML / zlib・bzip2・lzma・xz heap / flat package)の実装と XADMaster 比較 | `deed11d` |
| [2026-09-09-rpm.md](2026-09-09-rpm.md) | 2026-09-09 | RPM reader(lead / header / cpio payload / blob fallback)の実装と XADMaster 比較 | `975cde6` |
| [2026-09-09-cab.md](2026-09-09-cab.md) | 2026-09-09 | CAB reader(CFHEADER / CFFOLDER / CFFILE / CFDATA、MSZIP の folder 内辞書引き継ぎ)の実装と XADMaster 比較 | `efb978b` |
| [2026-09-09-format-gap-queue.md](2026-09-09-format-gap-queue.md) | 2026-09-09 | XADMaster が対応し KaitoKit が未対応の形式の洗い出しと実装キュー | `0b38a37` |
| [2026-09-09-recovery-mode.md](2026-09-09-recovery-mode.md) | 2026-09-09 | 破損書庫の救済モードの実測(XADMaster 比較・健全書庫と暗号化書庫の不変性・tar 検出の修正)、追補で RAR5 の切り詰め救済 | `4969b34` / `7aba9ae` / `5e83353` / `c00dd09` |
| [2026-09-09-new-format-performance.md](2026-09-09-new-format-performance.md) | 2026-09-09 | 新規 6 形式(ISO / cpio / ar / xar / RPM / CAB)の安全性と展開性能。CAB の 1 ブロック破損による folder 全滅の修正と二乗性の解消(211 倍)、xar の日時解析(3.55 倍)、ISO の名前検査(1.20 倍) | `dc87edc` |

これらは 2026-09-08 に `Documentation/` 直下から本ディレクトリへ移した。記録本文に埋め込まれた
`git status` などの出力には移動前のパスが残っているが、当時の実行結果として意図的に手を入れて
いない。旧名との対応は次のとおり。

| 旧名 | 現在 |
| --- | --- |
| `performance-rar-lha-2026-09-08.md` | `verification/2026-09-08-performance-rar-lha.md` |
| `performance-stability-2026-09-08.md` | `verification/2026-09-08-performance-stability.md` |
| `batch12-review-verification-2026-09-08.md` | `verification/2026-09-08-review-fixes-verification.md` |
| `performance-rar5-ppmd-2026-09-08.md` | `verification/2026-09-08-performance-rar5-ppmd.md` |
