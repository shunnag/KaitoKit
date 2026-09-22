# 変更履歴

すべての注目すべき変更をこのファイルに記録する。書式は
[Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に、
バージョニングは [Semantic Versioning](https://semver.org/lang/ja/) に従う。

## [Unreleased]

## [0.9.0] - 2026-09-22

対応済み形式の中で `unsupportedMethod` のまま残っていたメソッドを埋めた release。公開 enum `ArchiveFormat` の
case 追加は無く、利用側の網羅的 switch は変更不要。**既定の挙動が変わる点が 3 つ**ある: rpm 6 の package は
圧縮 payload 1 件ではなく中の file を列挙する、DMG / HFS+ の decmpfs file は `uncompressedSize` が実サイズになり
読み取りが成功する、typeflag `S` を含む tar は書庫全体が失敗せず開ける。各項目の出自は
[design.md §10](Documentation/design.md)、手順と実出力は
[Documentation/verification/](Documentation/verification/README.md) の 2026-09-22 の記録を参照。
リリース前レビューで確認した 11 件の修正は同節の後半にまとめた。

- 7-Zip `-m0=Deflate64` の 7z 書庫（method ID `04 01 09`）を既存の Deflate64 decoder で展開できるようにした。従来は `unsupportedMethod` で失敗していた。solid / non-solid、32 KiB を超える距離、上限と破損の検証は[検証記録](Documentation/verification/2026-09-22-sevenzip-deflate64.md)を参照。
- WIM の XPRESS chunk を 4〜64 KiB の 2 冪へ拡張した。LZX は 32 KiB のまま。辞書上限、chunk 表と圧縮入力長の上限、SHA-1 を検査する。[検証記録](Documentation/verification/2026-09-22-small-method-gaps.md)。
- XZ の非終端 RISC-V filter（ID `0x0B`）を native decoder の前に `unsupportedMethod("XZ RISC-V filter")` で拒否する。`.tar.xz` にも適用する。
- tar の旧 GNU sparse（`S` 型）の header 内 map と拡張 block 連鎖を展開する。穴を 0 で埋め、実サイズと格納長を公開する。非 GNU magic の `S` header は従来の `unsupportedMethod("GNU tar sparse entries")` から `malformed("invalid old GNU sparse header")` に変わる。star / Solaris は引き続き非対応。
- RPM の stripped cpio `07070X`（rpm ≥ 4.12 の大容量 file、rpm 6 の既定）を header tags から列挙・読取可能にした。hard link・ghost・SHA-256 終端検証、v4 / v6 の黒箱照合は[検証記録](Documentation/verification/2026-09-22-rpm-stripped-payload.md)を参照。
- HFS+ の decmpfs 圧縮 file（UF_COMPRESSED）の本文を読めるようにした。attributes B-tree の `com.apple.decmpfs` から実サイズと type を公開し、type 1 / 3 / 4 / 7 / 8 / 9 / 10 / 11 / 12（stored / zlib / LZVN / LZFSE、inline / resource fork）を chunk 単位で展開する。`methodDescription` は `HFS+ compressed (decmpfs)` から `HFS+ decmpfs (…)` に変わり、対応 type の `uncompressedSize` / `compressedSize` は `nil` でなく実サイズ / 格納長を返す。type 5 / 13 / 14 と未知の type は一覧のみ。fixture の読める 11 file と Apple の実物を原本の SHA-256 で照合し、type 3 / 4 / 7 / 8 / 9 は 7-Zip 26.03 の展開結果とも一致。[検証記録](Documentation/verification/2026-09-22-hfsplus-decmpfs.md)。

### 0.9.0 リリースレビューの修正

敵対的 multi-agent pre-release review（6 観点、各指摘を 3 検証 lens）で確認した R1〜R11。再現・修正前の失敗・回帰テストは[検証記録](Documentation/verification/2026-09-22-release-review-0.9.0.md)を参照。

- R1. UF_COMPRESSED が無い HFS+ volume の属性走査を省き、必要な走査には独立した `maxTotalMetadataSize` 上限を適用する。保持属性の件数・単体・総量上限は維持。
- R2. inline decmpfs の宣言サイズが 64 KiB を超えたら decoder 初期化時に `malformed` で拒否し、宣言値に比例する buffer 確保を防ぐ。
- R3. RPM stripped payload の全件分の保持量を単体 allocation 上限から外し、総量・件数上限で管理する。65,537 件の合成 file list で検証。
- R4. 非 GNU magic の tar `S` header を拒む回帰テストを復元し、エラー分類の変更を上記 feature bullet に追記。
- R5. pax `GNU.sparse.size` と旧 GNU `S` map の競合を拒む回帰テストを追加。
- R6. decmpfs 属性の件数 0 と保持サイズ未満の総量上限を、未変更 fixture で検査。
- R7. RPM tag 5008 の hard link member / symlink サイズ不整合を拒む回帰テストを追加。
- R8. v0.8.0 の DMG 検証記録に decmpfs 対応追補への注記を加え、当時の本文は保存。
- R9. README の英語 tar 対応状況に旧 GNU sparse（typeflag `S`）を追記。
- R10. decmpfs の method 名と公開サイズの変更を上記 feature bullet に明記。
- R11. 新規検証記録の machine 固有パスを置換し、一時 worktree の記述を release branch へ統合済みの状態に更新。

## [0.8.1] - 2026-09-22

0.8.0 のリリースレビューの修正。再現手順・修正前の失敗文・回帰テストは[検証記録](Documentation/verification/2026-09-22-release-review-0.8.1.md)を参照。

- R1. ARJ の短い基本 header で file type を範囲外参照する crash を、7 byte 以上の長さ検査で防いだ。`60 ea 01 00 00 8d ef 02 d2` の 9 byte を detect / open / CLI list に渡して再現。
- R2. CFB v4 の root mini-stream サイズを `maxEntrySize` で検査し、sector 数の切り上げを overflow しない式にした。root サイズを `UInt64.max` にした既存 fixture で再現。
- R3. CFB の sibling tree の再帰を明示的な stack に置き換え、4,000 entry の左鎖で起きる stack overflow を防いだ。テスト内の合成 CFB で一覧順・件数上限・循環拒否も検証。
- R4. CHM の section ID を `Int` へ変換する前に範囲検査し、不正値を `malformed` で拒否する。空の `/x` の section を `2^63` にして再現。
- R5. UDIF の sector 数から byte 数への検査付き乗算を chunk 解析前に移し、raw chunk の乗算 overflow を防いだ。trailer / chunk に `2^55` sector を宣言した小さな XML image で再現。
- R6. AppleDouble の除去・resource fork 挿入後の index へ tar hard link の参照先も写す。`._foo`、`foo`、hard link と連鎖 link を持つ合成 tar の `.merge` / `.hide` で再現。
- R7. AppleDouble 候補の probe が未対応 method や破損で失敗した場合は候補を通常 entry として残す。method 7 の `._ordinary` を持つ ZIP の既定 open で再現し、上限・I/O のエラー伝播は維持。
- R8. AppleDouble resource fork の最終 byte を返す前に元の sidecar stream を読み切り、CRC・終端を検証する。1,000 byte の stored sidecar の offset 38 に置いた 4 byte の fork と後続領域の反転で再現。
- R9. UDIF の圧縮 chunk を cache する前に decoder の終端を確定し、宣言長を超える出力を拒否する。既存 `hfs-lzma.dmg` の chunk 宣言を 1 sector 短くして再現（原文の footer 反転は既存検査で拒否済み）。
- R10. lzip / pbzx / WIM / CFB / CHM / ARJ の先頭署名を BinHex probe の除外に追加した。CFB の stored stream に BinHex 説明文を入れても native 形式で開けることを検証。
- R11. GNU sparse tar 0.1 の `GNU.sparse.name` を公開名・展開先へ引き継ぐ。header 名 `GNUSparseFile.123/real.txt`、sparse 名 `real.txt` の合成 tar を bsdtar と照合。
- R12. ZIP Shrink の連続した部分クリアでも、前回解放した未使用 code を低い番号順に再利用する。9 bit 列 `[65,66,67,256,2,256,2,68,257]` が `ABCDCD` に復元されることを検証。
- R13. StuffIt 分割の巻数上限検査を次の part の存在確認後へ移し、上限ちょうどの完結セットを受理する。1 巻 / 128 巻の URL open と、その次の part が実在する場合の拒否で再現。
- R14. MacBinary / AppleSingle / BinHex の公開 entry 数を resource fork 込みで `maxEntryCount` と照合する。`noresource.bin` の上限 0 と `readme.txt.bin` 等の上限 1 で再現。

## [0.8.0] - 2026-09-22

形式の追加を中心にした release。公開 enum `ArchiveFormat` に 12 の case（`.lzip` `.brotli` `.pbzx` `.udf` `.wim` `.macBinary`
`.appleSingle` `.binHex` `.compoundFile` `.chm` `.arj` `.dmg`）が増えたため、網羅的 switch を持つ利用側は case の追加が必要。
既存 case の範囲も広がった（ZIP の Shrink / Reduce / Implode、7z の Zstandard coder、RAR5 の file copy、ISO の zisofs と
BIN/CUE 生 sector image、tar の GNU sparse、圧縮 cpio、PE 内 CAB、classic StuffIt 分割セット、ZIP / tar の AppleDouble
sidecar の既定統合）。各項目の出自と検証は [design.md §10](Documentation/design.md) と
[Documentation/verification/](Documentation/verification/README.md) の 2026-09-20〜22 の記録を参照。

- Apple Disk Image（UDIF `.dmg` と生の HFS+ image）の読み取りを追加した。公開 enum `ArchiveFormat` に `.dmg`（compat の `formatName()` は `Apple Disk Image`）を追加（網羅的 switch を持つ利用側は case の追加が必要）。UDIF は末尾の koly と XML plist の blkx から chunk 表を組み、zero-fill / raw / zlib / bzip2 / lzfse / lzma（xz container）の chunk を展開した disk（直近 4 chunk を cache）として見せる。GPT / Apple Partition Map / bare volume から HFS Plus / HFSX を見つけ、catalog B-tree（file、directory、symlink、hard link は indirect node file の本文、resource fork は `name/..namedfork/rsrc`）、extents overflow B-tree、更新日時、permissions、type / creator を公開する。UDIF に包まれた ISO 9660 / UDF は既存 reader へ渡す。ADC（UDCO）chunk と APFS は名前付きの `unsupportedMethod`、decmpfs 圧縮 file（UF_COMPRESSED）は一覧のみ。実装入力は Apple TN1150、libmodi の GFDL 文書（koly / mish / blkx）、UEFI / Inside Macintosh の partition 表の位置。fixture は hdiutil / HFS+ driver / ditto が書いた image（zlib / bzip2 / lzfse / lzma / ADC / raw、ISO-in-UDIF、APFS）を mount と 7-Zip で照合した。[検証記録](Documentation/verification/2026-09-22-dmg.md)。
- ARJ の読み取りを追加した。公開 enum `ArchiveFormat` に `.arj`（compat の `formatName()` は `ARJ`）を追加（網羅的 switch を持つ利用側は case の追加が必要）。main / local file header（CRC 検証、extended header の読み飛ばし、end marker）、stored と method 1〜3（LHA lh6 と同じ bitstream。既存の static-Huffman decoder を lh6 の parameter で使う）、directory、DOS `\` 区切りと PATHSYM 名、書庫全体の名前 encoding 判定、comment、DOS 日時、method 8 / 9、DOS SFX（technote の header 探索）。method 4、garbled（暗号化）、multi-volume の続き file は一覧できるが `unsupportedMethod`。実装入力は ARJ 2.86 配布物の TECHNOTE.TXT（C 抜粋を切除）と CC0 の Archive Team wiki。利用者所有の実物 11 書庫 203 file（DOS SFX 5 本を含む）が 7-Zip と一致、うち 1 本は deark / unar とも一致。fixture は自作 writer + 自作 lh6 互換 encoder の出力を 7-Zip / deark / unar が同じ内容に展開することで検証した。[検証記録](Documentation/verification/2026-09-21-arj.md)。
- HTML Help（CHM / ITSF）の読み取りを追加した。公開 enum `ArchiveFormat` に `.chm`（compat の `formatName()` は `CHM`）を追加（網羅的 switch を持つ利用側は case の追加が必要）。ITSP directory の PMGL chunk 連鎖、section 0 の stored file、`MSCompressed` section の LZX（既存の [MS-PATCH] decoder を reset interval ごとに作り直し、reset table の 0x8000 byte block 単位で 16 bit 境界を取る。直近の reset interval を cache）、`/` 以下の利用者 file と `#`/`$` の format file を公開し `::DataSpace/…` は出さない。実装入力は Russotto の CHM format 文書と Wise / Wing の Unofficial CHM Specification（GPL 文書。利用者の裁定 2026-09-21）。fixture は自作 writer + 既存 CAB LZX encoder の出力を 7-Zip が同じ内容に展開することで検証し、利用者所有の実物 2 本（日本語 HTML Help）で 7-Zip と全 file 一致。[検証記録](Documentation/verification/2026-09-21-chm.md)。
- Microsoft Compound File（[MS-CFB]、OLE2 structured storage: `.msi` `.doc` `.xls` `.ppt` `.msg` `Thumbs.db`）の読み取りを追加した。公開 enum `ArchiveFormat` に `.compoundFile`（`"cfb"`、compat の `formatName()` は `Compound File`）を追加（網羅的 switch を持つ利用側は case の追加が必要）。version 3 / 4、header 外に続く DIFAT、mini FAT と mini stream、断片化した chain、storage を directory・stream を stored file として公開し、storage の CLSID と更新日時を `formatSpecific` / `modificationDate` に出す。制御文字で始まる名前は 7-Zip と同じ `[5]SummaryInformation` の綴り。Windows Installer が stream 名に使う詰め込み表記（U+3800〜U+4840）は公開仕様が無いため、利用者の裁定（2026-09-21）により 7-Zip の一覧を黒箱の基準にして写像を確定し、`!_Tables` / `setup.cab` などに戻す（元の名前は `formatSpecific["storedName"]`）。fixture は自作 writer の出力を 7-Zip が同じ内容に展開することで検証し、実物の `.msi`（version 4、90 MB）/ `.xls` / `.doc` で 7-Zip と名前・内容が一致した。[検証記録](Documentation/verification/2026-09-21-cfb.md)。
- BIN/CUE などの生 sector CD image（ECMA-130 の 2352 byte sector。Mode 1、Mode 2 の 8 byte sub-header あり / なし、96 byte の sub-channel 付き 2448 byte、sync / header を落とした 2336 byte）を、user data だけの 2048 byte block に写して ISO 9660 / UDF として開くようにした（新しい `ArchiveFormat` case は無く `.iso` / `.udf` のまま）。`.cue` を URL で開くと同じ directory の data track の image（`FILE` 行、最初の `MODE*` track）を開く。sector の並びは sync の有無と logical sector 16 の `CD001` / `BEA01` の位置で判定し、EDC / ECC は検証しない。[検証記録](Documentation/verification/2026-09-21-bincue.md)。
- ZIP の PKZIP 1.x 圧縮方式 Shrink（1）、Reduce（2〜5）、Implode（6）の読み取りを追加した（従来は `unsupportedMethod`）。method 名は `shrink` / `reduce1`〜`reduce4` / `implode`。stream に終端が無いので中央 directory の宣言サイズで止め、CRC-32 で検証する。APPNOTE が暗黙にしている bit 順（LSB 先頭）、Shrink の部分クリア（256,2）の規約、Reduce の follower set の読み方は、自作 encoder の出力を Info-ZIP unzip / 7-Zip / deark に展開させて確定した。method 7（Tokenize）は従来どおり非対応。[検証記録](Documentation/verification/2026-09-21-zip-legacy.md)。
- MacBinary / AppleSingle / BinHex 4 の wrapper を、payload が StuffIt でないときに 1 file の書庫として開くようにした（公開 enum `ArchiveFormat` に `.macBinary` / `.appleSingle` / `.binHex` を追加。従来は `unsupportedFormat`）。data fork が entry 0、resource fork が `name/..namedfork/rsrc`（`fork=resource`）。名前・type / creator・Finder flags・日時は header から。自作 fixture は The Unarchiver の `lsar` / `unar` が fork まで同じ内容に展開する。[検証記録](Documentation/verification/2026-09-21-macwrappers.md)。
- WIM（Windows Imaging）の読み取りを追加した。公開 enum `ArchiveFormat` に `.wim` を追加（網羅的 switch を持つ利用側は case の追加が必要）。stored / XPRESS / LZX の resource、複数 image（`1/` `2/` の前置）、alternate data stream、hard link 群、symbolic link / junction の reparse point、lookup table の SHA-1 による resource 検証に対応。LZX の WIM 変種（E8 header bit 無し、変換サイズ 12,000,000、block size flag、chunk 末尾の pad 無し）は Microsoft 製 boot.wim（29,335 entry）の全 resource が SHA-1 一致することで確定した。solid / ESD（LZMS）と分割 `.swm` の他 part は非対応。[検証記録](Documentation/verification/2026-09-21-wim.md)。
- ZIP / tar の AppleDouble sidecar（Finder / ditto の `__MACOSX/._name`、macOS tar の `._name`）を既定で畳むようにした（`ReaderOptions.appleDoublePolicy`、既定 `.merge`）。sidecar は一覧から消え、resource fork を持つものだけ `name/..namedfork/rsrc`（`fork=resource`）として data file の直後に並ぶ。`.hide` は fork も出さず、`.expose` で従来の一覧に戻る。**既定の変更**: Finder 製 ZIP の entry 数と index が変わる。compat の `entryIsResourceFork` は fork entry で `true` を返す。[検証記録](Documentation/verification/2026-09-21-appledouble.md)。
- UDF（ECMA-167 / OSTA UDF 1.02〜2.60）の読み取りを追加した。公開 enum `ArchiveFormat` に `.udf` を追加し（ISO 9660 構造を持たない UDF 専用 image。網羅的 switch を持つ利用側は case の追加が必要）、ISO 9660 との hybrid は `.iso` のまま UDF の木を Rock Ridge / Joliet / PVD より優先する（UDF 側が壊れていれば従来の木へ戻る）。block 512〜4096、type 1 / sparable / virtual（VAT）/ metadata partition、FE / EFE、inline data、複数 entry の ICB（strategy 4096 の indirect entry は未検証）、symlink、Macintosh resource fork の named stream に対応。writer は hdiutil / newfs_udf、真値は macOS の UDF driver（7-Zip は symlink を含む UDF を開けない）。[検証記録](Documentation/verification/2026-09-21-udf.md)。
- classic StuffIt の分割セット（署名 `B0 56` の 100 byte header を持つ part）を、URL open で同じ directory の兄弟 part を番号順に連結して開くようにした。resource fork も復元するので classic の暗号化書庫（MKey）も読める。Data からは単独 part が全体を覆う場合だけ開ける。合成 part は unar 1.10.8 でも同じ内容に展開されることを確認した。[検証記録](Documentation/verification/2026-09-20-stuffit-split.md)。
- pbzx（macOS `pkgbuild --compression latest` の Payload、OTA）の読み取りを追加した。chunk ごとの展開後サイズを検証し、展開結果が cpio ならその entry を直接列挙する。公開 enum `ArchiveFormat` に `.pbzx` を追加。layout は pkgbuild 出力の黒箱計測。[検証記録](Documentation/verification/2026-09-20-pbzx.md)。
- 圧縮 cpio（Archive Utility の `.cpgz`、`.cpio.gz|bz2|xz|zst|lz4|lzma|lz|br|Z`）を圧縮 tar と同じ staging で CpioReader に渡すようにした。`reopen()` は展開結果を再利用する。
- PE / Mach-O 実行形式の後ろに置かれた CAB（IExpress などの self-extractor）を、ZIP / RAR / 7z と同じ上限付き署名走査で開くようにした。
- tar の GNU sparse（pax 0.0 / 0.1 / 1.0）を展開するようにした。穴は 0 で埋め、実サイズを `uncompressedSize` に、格納長を `compressedSize` に公開する。旧 GNU `S` 型と star / Solaris の sparse は従来どおり `unsupportedMethod`。[検証記録](Documentation/verification/2026-09-20-tar-sparse.md)。
- ISO 9660 の zisofs（Rock Ridge ZF version 1 / `pz`）を展開するようにした。header と block pointer を ZF entry と照合し、32〜128 KiB の zlib block と 0 埋め block を順に返す。`uncompressedSize` は展開後サイズ、method は `zisofs (zlib)`。zisofs2（version 2）と multi-extent の zisofs は従来どおり `unsupportedMethod`。あわせて、長さ 0 の extent は LBA を検証しないようにした（libarchive の iso9660 writer は空 file と symlink に 0xFFFFFFF0 を書くため、bsdtar 製 ISO が `truncated` になっていた）。fixture は GNU xorriso で生成。[検証記録](Documentation/verification/2026-09-20-iso-zisofs.md)。
- RAR5 の file copy（redirection type 5、`rar -oi` の同一 file 参照）を、同一内容の先行 entry の本文を返す `.file` として公開するようにした。宣言サイズ・暗号化・solid group は参照先に従い、`formatSpecific["fileCopyTargetIndex"]` で参照先を示す。参照先が解決できない／サイズが合わない参照は従来どおり本文 0 の `.other`。合計展開上限には参照の出力も加算される。RAR 7.23 の plain / solid / AES 書庫を固定 fixture として追加。[検証記録](Documentation/verification/2026-09-20-rar5-file-copy.md)。
- brotli（`.br` / `.tar.br` / `.tbr`）の読み取りを追加した。復号は Apple Compression の `COMPRESSION_BROTLI`、header は RFC 7932 / RFC 9841（large window）の WBITS を解釈して `maxDictionarySize` と照合する。magic が無いため名前・header・先頭 64 KiB の試し復号で判定し、END 後の余分な byte は `malformed`。公開 enum `ArchiveFormat` に `.brotli` を追加したため、利用側の網羅的 switch には case の追加が必要。fixture は brotli CLI 1.2.0 で生成・照合した。[検証記録](Documentation/verification/2026-09-20-brotli.md)。
- lzip（`.lz` / `.tar.lz`）の読み取りを追加した。末尾の member size を辿る索引で multimember file の構造と展開後サイズを open 時に確定し、member ごとに CRC-32・data size・LZMA stream の消費長を検証する。`.tlz` は署名で LZMA_Alone と lzip を判別して tar 経路へ流す。公開 enum `ArchiveFormat` に `.lzip` を追加したため、利用側の網羅的 switch には case の追加が必要。fixture は自作 framing + Python raw LZMA1 と `bsdtar --lzip` で作り、すべて XZ Utils で照合した。[検証記録](Documentation/verification/2026-09-20-lzip.md)。
- 7z の Zstandard coder（method ID 04F71101。7-Zip ZS / NanaZip / libarchive 3.8 が書く）の読み取りを追加した。packed stream は RFC 8878 の frame 列で、既存の zstd decoder を使う。properties は 3 / 5 byte だけを受理し、solid folder の宣言サイズは entry 上限ではなく folder の宣言値で検査する。fixture は Homebrew libarchive の bsdtar で生成し、zstd CLI と bsdtar で独立に照合した。[検証記録](Documentation/verification/2026-09-20-sevenzip-zstd.md)。
- 7z の x86 BCJ / ARM64 filter で、変位が ip との加減算で符号境界をまたぐ場合に元の byte へ戻らず `Checksum mismatch` になる不具合を修正した。x86 は減算後の上位 byte を bit 24 の符号で 0x00 / 0xFF に正規化し、ARM64 は page delta を 18 bit の符号付き値として折り返す。乱数系の 1 MiB 前後以上の payload で確率的に発生していた。固定ベクタと 7zz オラクルの掃引テストを追加。[検証記録](Documentation/verification/2026-09-20-sevenzip-bcj-large-payload.md)。
- 追加できる形式の候補を出自・オラクル・既存コードの再利用・工数で整理した[候補調査](Documentation/verification/2026-09-20-format-candidates.md)を追加し、2026-09-09 の形式キューの状況列、DocC 概要の対応形式、移行ガイド §11 の未対応一覧を現行 main の対応状況に合わせて直した。調査で再現した 7z の x86 BCJ / ARM64 filter の不具合は上の項目で修正した。

## [0.7.0] - 2026-09-19

- ZIP・tar・7z・LHA の `reopen()` は解析済み entry と位置情報を共有する。ZIP の local header cache は初回利用時に確保し、展開予算の初期合計も再計算しない。reader ごとの検証・decoder・password・鍵 cache は独立させ、分割 ZIP の巻配置と圧縮 tar の staging も保持する（K9）。10k / 100k entry の前後測定と失敗文は [検証記録](Documentation/verification/2026-09-19-release-review.md#k9-share-parsed-state-on-reopen)を参照。

- StuffIt SFX の候補 header 検証を `maxMetadataSize` の累積読み取り予算で制限した。StuffIt 5 の scan 時の header 読み取りは 64 KiB までとし、大きい header の全 CRC は選択後の parser で一度だけ検証する（K10）。
- StuffIt X の auxiliary-only stream は宣言長を `maxEntrySize` と照合し、所有 entry の stream を返す前に遅延検証する。列挙時の過大な展開を防ぎ、検証成功は reader ごとに記憶する（K11）。
- `.taz` を大文字小文字を区別しない compressed-tar alias に追加した（K12）。再現時の失敗文・追加テスト・外部オラクルの結果は [release review 追補](Documentation/verification/2026-09-19-release-review.md#k10-bound-stuffit-sfx-candidate-validation-work)を参照。

- 圧縮 tar の `reopen()` は展開済み source を共有するようにした。preview ごとの再展開と一時 descriptor の増加を防ぎ、元ファイルの unlink 後も再利用できる（K1）。
- 圧縮 tar の staging で chunk ごとに task cancellation を確認し、巨大書庫の open を中断できるようにした（K2）。
- `ReadLimits.stagingFreeSpaceReserve`（既定 1 GiB）を追加。一時 volume の空き容量を spill 前と 256 MiB 書き込みごとに確認し、展開サイズ上限を解除した場合の volume 枯渇を抑える（K3）。
- tar の header cursor を 4 KiB に縮小し、PAX / GNU 拡張本文は直接範囲読み取りにした。大きい member の列挙で不要な本文を先読みしない（K4）。
- `ReadLimits.maxSevenZipHeaderKDFWork`（既定 `4 * (1 << 24)` SHA-256 rounds）を追加。7z の open 時の cache miss に累積上限を設け、異なる salt を並べた header の過大な KDF 処理を防ぐ（K5）。
- 7z solid decoder を read / discard / 完了確認などの失敗時に解放する。CRC のない後続 member が破損状態から読み出されることを防ぐ（K6）。
- サイズ上限を `.max` にした既知長・未知長 entry と再読み取りの回帰テストを追加。aggregate の残量・再生分の加算と entry の境界検査に overflow がないことを確認した（K7）。再現時の失敗文・追加テスト・RAR4 の受容する制約は[release review 検証記録](Documentation/verification/2026-09-19-release-review.md)を参照。

- LZ4 frameの読み取りを追加。単体・圧縮tar・連結・skippable・独立／連続block・各XXH32を検証し、分割・一時ディスク・展開上限に接続した。legacy frameも8 MiB block・連結・圧縮tarを読み取る。外部辞書は非対応。公開enum `ArchiveFormat` に `.lz4` を追加したため、利用側の網羅的switchにはcaseの追加が必要。[現行frame](Documentation/verification/2026-09-18-lz4-frame.md)・[legacy追補](Documentation/verification/2026-09-18-lz4-legacy.md)。
- 7z Swap2/Swap4 filterを追加。solidのmember境界・暗号化・分割を独立7zz fixtureで検証。[検証記録](Documentation/verification/2026-09-18-sevenzip-swap.md)。

- ZIP XZ（95）と旧Zstandard（20）の読み取りを追加。暗号化・分割・ZIP64・descriptor・辞書上限と接続した。AES XZの全block検査では認証済み圧縮入力を上限付きで一時保持し、暗号文の繰り返し読み取りを防ぐ。[検証記録](Documentation/verification/2026-09-18-zip-methods.md)。

- 圧縮 tar の `.tar.lzma` / `.tlz` / `.tbz` を既存 codec と TarReader に接続した。
- `.lha` / `.lzh` と正確な1 byte終端の組合せを空 LHA として受理し、全項目削除後の再編集を可能にした。名前のないデータは従来どおり曖昧な終端だけで識別しない。
- XZ の全block・連結streamの辞書を、Apple Compressionに渡す前に `ReadLimits.maxDictionarySize` と照合する。単体・圧縮tar/RPM・xarに適用。再現、境界テスト、全件・sanitizer結果は[横断検証](Documentation/verification/2026-09-17-release-hardening.md)を参照。

## [0.6.1] - 2026-09-17

- ZIP の EOCD 候補の再試行予算が正当な大規模書庫の初回解析まで拒否する不整合を修正した。件数に比例する中央ディレクトリを単一確保の `maxMetadataSize`（既定 16 MiB）で制限すると `maxEntryCount = 1,000,000` と両立しないため、既存の総 metadata 上限 `maxTotalMetadataSize`（既定 256 MiB）で制限し、メモリ上限は維持する。初回候補の通常解析だけを課金免除とし、上限／未対応エラー後の整合性検査と再試行には累積 work の上限を適用する。分割 ZIP の整合性検査も新しい総 metadata 上限に対応し、不正な末尾候補を除外できるようにした。試行回数の上限と兄弟巻探索の予算は変更しない。
- 完全な ZipCrypto entry で 1 byte のヘッダ検査を誤通過したパスワードによる CRC 不一致・decoder の破損／入力不足を `wrongPassword` に正規化した。7zAES と同様に、暗号化 stream 自体の破損も誤ったパスワードとして報告される場合がある。

## [0.6.0] - 2026-09-15

- ZIP 分割巻（Task Z1、bd `cooViewer-6lrc.2`）: `.z01`…`.zip` / `.zx01`…`.zipx` を最終巻・途中巻の URL から開けるようにした。ZIP64、100 巻以上、ヘッダ・データ・中央ディレクトリの境界越えに対応し、Compat と CLI の一覧・展開・SHA に接続した。宣言巻数の上限検査、欠番の巻名付きエラー、兄弟 symlink の拒否を追加し、`.001` バイト分割の優先順位を維持する。復旧方針・残る制約・検証結果は[検証記録](Documentation/verification/2026-09-15-zip-split-volumes.md)を参照。

- ファイル名判定（Task C Phase C-B）: CLDR の測定39言語を54 legacy候補へ接続し、Hebrew / Arabic / Persian、バルト・北欧・中東欧の候補と文字体系の規則、未定義 byte の事前除外を追加した。公開APIとreaderのCF復号は維持する。CP861はCF表の誤りにより対象外。PersianのCP1256では判定できてもک等8文字をCFで復号できず、既存fallbackの表記になることがある。VISCII / TCVN3と自前復号は含めない。eval の書庫（likelyLanguage ja）は 64.05% → 87.68%、日本語は単名 99.50% / 書庫 99.84% を維持、新 21 言語のうち 12 言語が書庫 k≥10 で 99% 以上。残差: トルコ語短名はアイスランド語との同一 bytes の交換で低下（CP1252 の集合から is を外せば戻る）、ギリシア語書庫の全大文字 Ά、ヘブライ語短名（udet 未満）、ru / uk 短名の MacCyrillic 大文字。1 書庫あたりの判定は最大 512 名 sample で約 36 ms。詳細は[検証記録](Documentation/verification/2026-09-14-name-encoding-languages.md)を参照。

- 多言語判定の測定基盤（Task C Phase C-A、bd `cooViewer-rbrj`）: 名前コーパス生成器と測定器を 39 言語・53 encoding に拡張し（新 21 言語、VISCII は RFC 1456 の表、fa / ro の互換写像）、CLDR の言語別文字集合を 41 言語に広げた。判定器の候補・採点・公開 API は変えていない。現行判定器のベースラインと CF の復号制約（CP861 表が CP775 と同一、CP1256 の 8 byte が復号不能）は[検証記録](Documentation/verification/2026-09-14-name-encoding-baseline-c.md)を参照。

- タイ語ファイル名判定（bd `cooViewer-fl6u`）: 分布規則専用の頻出集合を10字から15字へ広げ、tuneの実在名への発火率を7.04%から0.31%へ低減した。evalのth単名・zh-cn単名は受け入れ目標に未達で、差分と制約は[検証記録](Documentation/verification/2026-09-14-name-encoding-thai-rule.md)に記載。

- 多言語ファイル名判定（bd `cooViewer-6lrc.1`。西欧ラテンの書庫 k≥10 と zh-cn 単名に残差、記録参照）: 厳密復号できる 26 legacy 候補を CLDR・文字体系・正書法で採点し、非ASCII byte 数で減衰する言語事前確率を書庫全体で一度だけ適用する。文字一般カテゴリと位置、書庫全体で一つの言語を選ぶ整合、長語・タイ語の無母音・短周期反復を扱い、復号不能名も同じ byte 尺度で集計する。漢字の二重加点を撤去し、公知の頻出ハングル音節を使う。タイ語候補には字母の頻出率・稀記号・語中数字の証拠を加え、配置適合の加点を弱める。UTF-8 優先と日本語候補間の既存決定規則を保持し、正書法自己検査 CLI と自作の多言語 fixture を追加した。測定値・制約は[検証記録](Documentation/verification/2026-09-14-name-encoding-multilingual.md)を参照。

- StuffIt slice 8（2026-09-13、bd `cooViewer-gu28.8`）: resource fork を data ファイルの実 fork に展開し、CLI は data / hardlink の後に書き込む。resource-only は空の通常ファイルを作成し、非空 fork の上書き禁止と symlink 拒否を追加した。classic / SIT5 の `ArchiveEntry.name` を親フォルダ付きの完全な相対パスへ修正し、一覧・Compat・展開で同じ階層を保持する。Shift_JIS 名で CP932 decode に失敗した場合は MacJapanese を再試行する。[検証記録](Documentation/verification/2026-09-13-stuffit-slice8.md)。

- StuffIt slice 7（2026-09-13、bd `cooViewer-gu28.7`）: JPEG 再圧縮（compression 7、mode 0/1/2）のバイト完全復元を追加した。利用者の独立 Python 実装を関数単位で移植し、固定長モデルと行／scan 出力、`maxJPEGBlocks`（既定 2,097,152）、JPEG の key-6 CRC 範囲を接続した。入力不足・破損・未対応 profile を分類し、敵対的テストの seed／回数を環境変数で指定できるようにした。292 ストリームは 280 一致・参照と同じ 12 拒否・差分 0。詳細・歴史的 recovery 例の制約は [検証記録](Documentation/verification/2026-09-13-stuffit-slice7.md)。

- StuffIt slice 6（2026-09-13、bd `cooViewer-gu28.6`）: StuffIt X の continuing-MD5 派生、AES / Blowfish / DES の CFB、RC4、層状暗号、暗号化 catalog と PasswordProvider を追加した。MZ `.exe` 内の classic / StuffIt 5 / StuffIt X を header 検証付き署名走査で開く。[検証記録](Documentation/verification/2026-09-13-stuffit-slice6.md)。

- StuffIt slice 5（2026-09-13、bd `cooViewer-gu28.5`）: Huffman の 10 bit 表引きと method 13 の ARC 除去、Arsenic の正規化、Cyanide の slot 判定を高速化した。250 書庫の全 10,679 行と敵対的入力 7,086 件の新旧結果が一致。採用・撤回した変更の A/B と XADMaster 比較は [検証記録](Documentation/verification/2026-09-13-stuffit-slice5.md) に記載。

- StuffIt X slice 4（2026-09-13、bd `cooViewer-gu28.4`）: Brimstone（0、Blend 3）と意味論に従う 12 バイト arena、Iron（6、BWT/ST4・MTF/adaptive ranking）、English（組み込み辞書）・native x86 前処理を追加した。中間出力長を最終 fork 長から分離し、前処理後に checksum を検証する。CC0 対象 20 書庫と SMSSenderPro3osx.sitx 全 95 entry の支給 SHA が一致。native profile と旧 vector、比較スクリプトのオラクル範囲の差は [検証記録](Documentation/verification/2026-09-13-stuffit-slice4.md) に記載。

- StuffIt X slice 3 の容器、solid coordinator、未圧縮・Cyanide・Darkhorse・Deflate（window 10〜25）・Blend 0/1/2・RC4-stored、CRC-32/MD5、wrapper/CLI/Compat 接続を追加した（2026-09-13、bd `cooViewer-gu28.3`）。Cyanide は依頼仕様の是正に従い n=0〜255 を受理し、rank 256 以上だけを拒否する。実書庫の Brimstone catalog は後続 slice の範囲。詳細は [検証記録](Documentation/verification/2026-09-13-stuffit-slice3.md)。

- StuffIt の method 5/6/8/14、StuffIt 5 RC4・classic 改変 DES の復号、書庫コメントを追加した（2026-09-13、bd `cooViewer-gu28.2`）。
- StuffIt classic / StuffIt 5、MacBinary / AppleSingle / BinHex wrapper、method 0/1/2/3/13/15 と data/resource fork の読み取りを追加した（2026-09-13、bd `cooViewer-gu28.1`）。

- ZIP PPMd var.I の固定長バッファ化・局所スタック化・範囲検査の集約で、展開時間を 35.6%（Swift source 3.77 MB、order 8）／74.9%（PNG 3.00 MB、order 16）短縮した（2026-09-12、bd `cooViewer-2weq`）。
- LZMA / LZMA2 の bit tree で子の確率を先読みし、book-tiff.7z の展開を10.7%、book-solid.7z を14.3%短縮した（2026-09-12、bd cooViewer-r897）。
- zstd の宣言 window による即時確保 DoS を履歴の遅延確保で修正し、一覧取得の先読みを 64 KiB から 4 KiB に削減した。

### 追加（2026-09-12、Zstandard）

- RFC 8878 と xxHash 仕様に基づく純 Swift の Zstandard decoder を追加した（bd `cooViewer-c1vj.3`）。
  `.zst` / `.tar.zst` / `.tzst`、RPM の cpio payload、ZIP method 93 を展開する。
  FSE・Huffman、連結 frame・skippable frame、window 上限、XXH64 checksum を扱う。
- zstd CLI 生成の固定 fixture 46 件、80 通りの生成 matrix、7zz による第二オラクル、
  切断・反転・不正な entropy table と履歴参照の検証を追加した。
  辞書と 7z 内の zstd method は非対応。詳細は [検証記録](Documentation/verification/2026-09-12-zstd.md)。

> **Added (2026-09-12, Zstandard)**
>
> Added a pure Swift decoder derived from RFC 8878 and the xxHash specification (bd cooViewer-c1vj.3).
> Supports standalone/compressed tar streams, RPM cpio payloads and ZIP method 93, with FSE/Huffman,
> concatenated/skippable frames, bounded windows and XXH64 verification. Validation includes 46 fixed
> fixtures, 80 generated cases, a 7zz oracle and malformed inputs. Dictionaries and zstd in 7z remain unsupported.

### 追加（2026-09-12、CAB LZX）

- CAB の LZX（辞書 32 KiB〜2 MiB）を純 Swift で展開できるようにした（bd cooViewer-c1vj.5）。
  verbatim / aligned / uncompressed block、フレームを跨ぐ辞書と木、反復 offset、E8 変換に対応。
  後方ファイルの先読みと再オープン、消費した CFDATA だけの checksum 検証を維持する。
- Microsoft の仕様から Python 標準ライブラリだけで fixture encoder を作成。
  固定標本 14 件と実行時生成 20 書庫を cabextract の展開結果で検証する。
  Quantum と複数 cabinet にまたがるファイルは引き続き非対応。
  出自・破損入力・実 CAB との比較は [検証記録](Documentation/verification/2026-09-12-cab-lzx.md) を参照。

> **Added (2026-09-12, CAB LZX)**
>
> - Added a pure Swift CAB LZX decoder with 32 KiB–2 MiB dictionaries, all three block types,
>   persistent frame state, repeated offsets and E8 translation (bd cooViewer-c1vj.5).
>   Backward access, reopening and checksums limited to consumed CFDATA blocks retain their existing behavior.
> - Added a specification-derived Python fixture encoder, fourteen fixed fixtures and twenty generated
>   differential archives, all checked using cabextract as a black-box extraction oracle.
>   Quantum and files spanning cabinets remain unsupported.

### 追加（RAR5 SFX）

- RAR5 の上限付き SFX に対応した。SFX と multi-volume の組合せは引き続き非対応（bd cooViewer-yd18）。

> **Added (RAR5 SFX)**
>
> - Added bounded RAR5 SFX support. SFX combined with multi-volume remains unsupported (bd cooViewer-yd18).

### 追加（ZIP PPMd、cooViewer-th30）

- ZIP method 98 の PPMd var.I rev.1 decoder を追加した。公開ドメイン原典を、
  範囲検証付きの固定 arena・ストリーミング入力・既知サイズでの停止として移植した。
  order 2〜16、辞書 1〜256 MiB、restart / cut off / freeze を扱う。
- 7zz 生成 fixture と 64 通りの生成 matrix、復元カウンタ、切断・破損入力を検証した。
  freeze の正常な符号化書庫との一致は未検証。
  詳細は [検証記録](Documentation/verification/2026-09-11-zip-ppmd.md) を参照。

> **Added (ZIP PPMd, cooViewer-th30)**
>
> - Added a streaming ZIP method 98 decoder for PPMd var.I revision 1, ported from the public-domain
>   reference with a checked fixed arena and termination at the declared output size. It supports
>   orders 2–16, dictionaries of 1–256 MiB, and restart, cut off and freeze restoration.
> - Added 7zz fixtures, a 64-case generation matrix, restoration counters and malformed-input tests.
>   Valid freeze-encoded archives remain unverified; see the verification record.

## [0.5.0] - 2026-09-11

### 追加（バイト分割書庫）

- `.7z.001` / `.zip.001` 等の 7-Zip `-v` バイト分割を URL から開けるようにした。
  `ArchiveReader.open(url:)` と `FormatDetector.detect(url:)` が同じ連結処理を使い、
  署名や start header より短い先頭巻、不揃い巻、solid、暗号化にも対応する。
- 兄弟は保持した親 descriptor から regular file として開き、欠番で停止する。
  既定上限は 128 巻。`.002` 等から巻き戻さず、先頭 symlink は単独扱いにする。
  単巻 `.001` でも拡張子ヒントを保持し、`reopen()` は全巻削除後も同じ source を使う。
  分割セットの `rawRecord(of:)` は `nil`。ZIP の `.z01` spanned は引き続き非対応。
- RAR の連結 ByteSource と兄弟オープン・identity 検証を internal な共通部品へ移設した。
  合成 fixture と 7zz 生成書庫の検証は [検証記録](Documentation/verification/2026-09-11-split-volumes.md) を参照。

> **Added (byte-split archives)**
>
> - URL opens now support 7-Zip `-v` byte splits such as `.7z.001` and `.zip.001`. ArchiveReader and
>   FormatDetector share assembly, including short first volumes, unequal sizes, solid and encryption.
> - Siblings are regular files opened under a retained directory descriptor, stopping at the first gap
>   with a default limit of 128 volumes. Continuations do not rewind; symlink first volumes stay single.
>   Single `.001` files retain extension hints, and `reopen()` works after all paths are deleted.
>   Split sets return `nil` from `rawRecord(of:)`; ZIP `.z01` spanned archives remain unsupported.
> - RAR's concatenation and sibling/identity helpers are now shared internal primitives. See the linked
>   verification record for synthetic fixtures and archives generated by 7zz.

### 変更（7z 切断時のエラー）

- start header の CRC 検証後、next header がファイル終端を超える場合は `malformed` から
  `truncated` に変更した。単一ファイルの切断と分割セットの欠巻に同じ診断を返す。

> **Changed (7z truncation errors)**
>
> - After start-header CRC validation, a next header extending beyond EOF now throws `truncated`
>   instead of `malformed`, covering both truncated single files and missing split volumes.

## [0.4.0] - 2026-09-10

### 追加（2026-09-10、ZIP entry の生レコード範囲）

- `RawEntryRecord` と `ArchiveReader.rawRecord(of:)` を追加した。ZIP の local header から
  payload、bit 3 が立つ場合は data descriptor の末尾までを、SFX prefix を含む source の
  絶対範囲として返す。署名の有無と entry の ZIP64 extra に応じて descriptor を解析し、
  CRC・圧縮サイズ・展開サイズを中央ディレクトリと照合する。
- 既存の entry 範囲検証を共用し、source 外、中央ディレクトリとの重なり、前後の entry
  との重なりを拒否する。descriptor の検証は新 API だけで行い、通常の一覧・読取は変えない。
- 暗号化 ZIP もパスワードなしで範囲を取得でき、`formatSpecific` に暗号方式などを返す。
  `payloadRange` は暗号ヘッダ・salt・認証コードを含む保存済み payload の範囲となる。
  `isIncomplete` と ZIP 以外は `nil`。tar / LHA の対応は今回は追加しない。
- クリーンルーム ZIP の並べ替え・一部削除と、実機の `ditto` が生成した ZIP を、生レコード
  コピーと中央ディレクトリ再構築で往復検証する XCTest を追加した。KaitoKit と `unzip -t`
  の両方で確認する。詳細は [検証記録](Documentation/verification/2026-09-10-raw-record.md)。

> **Added (2026-09-10, raw ZIP entry record ranges)**
>
> - Added `RawEntryRecord` and `ArchiveReader.rawRecord(of:)`. ZIP ranges use absolute source
>   offsets, including SFX prefixes, and include the complete local record and any data descriptor.
>   Descriptor parsing uses the optional signature and the entry's ZIP64 extra fields, checking
>   CRC and both sizes against the central directory.
> - Reuses entry-range validation to reject out-of-source ranges and overlaps with the central
>   directory or other entries. Descriptor validation applies only to the new API; normal listing
>   and reading are unchanged.
> - Encrypted ZIP entries expose ranges without requesting a password and report encryption
>   metadata. Their payload range includes the stored encryption envelope. Incomplete entries
>   and all non-ZIP formats return `nil`; tar and LHA support is deferred.
> - Added XCTest round trips that reorder or delete entries in clean-room ZIPs and relocate
>   records generated by the system `ditto`, rebuilding the central directory and checking both
>   KaitoKit and `unzip -t`. See the linked verification record.

## [0.3.0] - 2026-09-10

### 追加・修正（2026-09-10、reader の送信と親ディレクトリの権限）

- `ArchiveReader.reopen()` の戻り値を `sending ArchiveReader` にし、Swift 6 の
  actor から別の isolation domain へ独立した reader を送信できるようにした。
  既存の呼び出しはソース互換で、実行時の処理は変えない。
- 親ディレクトリを開く際の `EPERM` / `EACCES` に限り、`FileByteSource` は葉の
  パスを直接開く。`ArchiveReader.open(url:)` と公開 initializer の両方に適用し、
  通常の `openat()` と directory anchor は維持する。fallback では anchor を持たず、
  RAR の後続巻探索は匿名 origin の既存の `unsupportedMethod` を返す。

> **Added and fixed (2026-09-10, reader transfer and parent-directory permissions)**
>
> - `ArchiveReader.reopen()` now returns `sending ArchiveReader`, allowing an independent reader
>   to cross from a Swift 6 actor into another isolation domain. Existing calls remain source
>   compatible, with no change to the runtime implementation.
> - Only `EPERM` or `EACCES` when opening the parent directory makes `FileByteSource` open the
>   leaf path directly. This applies to both `ArchiveReader.open(url:)` and the public initializer.
>   Normal `openat()` and directory anchoring are preserved. The fallback has no anchor, so RAR
>   continuation lookup returns the existing anonymous-origin `unsupportedMethod` error.

## [0.2.0] - 2026-09-09

### 修正（2026-09-09、CAB の救済性と展開性能）

- **1 ブロックの破損で folder 内の全ファイルが読めなくなる不具合を修正した。**
  entry の成否は、その entry が消費するブロックだけで決まるようになった。
  200 ファイルを 1 folder に持つ cab の最終ブロックを壊した場合、従来は 200 件すべてが
  失敗したが、199 件を正しく取り出し最後の 1 件だけが失敗する。これは cabextract
  （libmspack）および XADMaster の挙動と一致する（検証記録
  `2026-09-09-new-format-performance.md` §3.3）。
- 同じ原因で、1 folder に N entry があると展開が N × folderSize になっていた。
  folder 単位の前進復号器を `CabReader` が保持し（RAR5 の solid coordinator と同じ形。
  世代番号で古い stream を無効化し、folder を切り替えるときに直前の復号器を解放する）、
  順に読む限り folder を一度だけ復号する。200 ファイル 50 MiB の cab で
  MSZIP が 6,844 ms → 32 ms（211 倍）、stored が 1,358 ms → 8 ms（169 倍）。
  総量を固定したまま file 数を 10 → 200 に増やしても時間が変わらなくなった。
- MSZIP のブロックごとの `inflateInit2_` / `inflateEnd` を 1 つの `z_stream` の
  `inflateReset` にし、履歴の連結による二重確保と、ブロックごとのバッファ確保を外した。
  単一ファイルの cab でも 1.2 倍速い。
- 健全な書庫の出力は byte 単位で不変。

> **Fixed (2026-09-09, CAB recovery and extraction performance)**
>
> - **Fixed a defect where damage to one block made every file in the folder unreadable.**
>   An entry now succeeds or fails on the blocks it consumes and nothing else.
>   With the last block of a 200-file, single-folder cab damaged, all 200 entries used to fail;
>   now 199 are extracted correctly and only the last one fails. This matches the behavior of
>   cabextract (libmspack) and XADMaster (verification record
>   `2026-09-09-new-format-performance.md` §3.3).
> - The same cause made extraction cost N × folderSize for a folder holding N entries.
>   `CabReader` now retains a forward decoder per folder, shaped like the RAR5 solid coordinator:
>   a generation number invalidates older streams, and the previous decoder is released when the
>   folder changes. Read in order, a folder is decoded exactly once. For a 50 MiB cab of 200 files,
>   MSZIP went from 6,844 ms to 32 ms (211x) and stored from 1,358 ms to 8 ms (169x).
>   Time no longer grows as the file count rises from 10 to 200 at a fixed total size.
> - The per-block `inflateInit2_` and `inflateEnd` of MSZIP became one `z_stream` with
>   `inflateReset`, and the duplicate allocation from concatenating the history and the per-block
>   buffer allocations were removed. Even a single-file cab is 1.2x faster.
> - Output for undamaged archives is byte-for-byte unchanged.

### 修正（2026-09-09、xar と ISO 9660 の開封性能）

- xar の `mtime` 解析から `NSDateFormatter` を外した。5,110 項目の書庫では open の
  68% が ICU の日付シンボル再読み込みだった。`yyyy-MM-ddTHH:mm:ss`（+ 任意の `Z`）
  かつ年が 1583 以上の定型だけを算術で解き、それ以外は従来の formatter へ落とす
  二段構えなので、受理範囲も秒値も完全に同一。formatter は遅延生成で、通常の書庫では
  一つも作らない。23,724 通りの候補で従来経路との一致を固定する差分テストを追加した。
  open が xar-tree.xar（5,110 項目）で 299 ms → 84 ms（3.55 倍）、
  xar-many.xar で 12.2 ms → 3.4 ms。
- ISO 9660 の名前検査で、Foundation の `String.contains("/")`（Unicode 照合）を
  UTF-8 バイト走査にし、NUL 検査と 1 回の走査にまとめた。NFC 正規化は非 ASCII を
  含む名前だけに限った（全 ASCII では恒等変換）。open が 13.5 ms → 11.3 ms（1.20 倍）。
- 一覧・展開の出力は byte 単位で不変（更新日時を含む `list` の digest で確認）。

> **Fixed (2026-09-09, xar and ISO 9660 open performance)**
>
> - Removed `NSDateFormatter` from xar `mtime` parsing. For an archive of 5,110 items, 68% of the
>   open was ICU reloading its date symbols. Only the fixed shape `yyyy-MM-ddTHH:mm:ss` (with an
>   optional `Z`) and a year of 1583 or later is now solved arithmetically; everything else falls
>   back to the previous formatter, so the accepted range and the resulting seconds are identical.
>   The formatter is created lazily and a normal archive never builds one. A differential test
>   pins agreement with the previous path over 23,724 candidates.
>   Open went from 299 ms to 84 ms (3.55x) for xar-tree.xar (5,110 items), and from 12.2 ms to
>   3.4 ms for xar-many.xar.
> - In ISO 9660 name validation, Foundation's `String.contains("/")` (Unicode matching) became a
>   UTF-8 byte scan, merged into a single pass with the NUL check. NFC normalization is now applied
>   only to names containing non-ASCII bytes, since it is the identity for pure ASCII.
>   Open went from 13.5 ms to 11.3 ms (1.20x).
> - Listing and extraction output is byte-for-byte unchanged, confirmed by the digest of `list`,
>   which includes modification dates.

### 追加・修正（2026-09-09、CAB）

- 依存を追加せず純 Swift の Microsoft Cabinet reader を追加。None と MSZIP の
  圧縮、予約領域、多分割フラグ、UTF-8 ファイル名（attribs 0x80）に対応。
- MSZIP は CFDATA ブロックをまたいで LZ77 履歴を引き継ぐ。folder ごとに
  直前までの出力の末尾 32 KiB を辞書として渡す。履歴は folder 境界を越えない。
- CFDATA の checksum を展開完了時に検証する（0 は未計算として飛ばす）。
- Quantum と LZX は一覧のみ対応し、展開時に具体的なエラーを返す。
- ZIP の DOS 日時変換を `Core/DOSTimestamp.swift` へ移して共有した（ZIP の挙動は不変）。

> **Added and fixed (2026-09-09, CAB)**
>
> - Added a pure-Swift Microsoft Cabinet reader with no new dependencies. It supports None and
>   MSZIP compression, the reserved areas, the multi-cabinet flags, and UTF-8 filenames
>   (attribs 0x80).
> - MSZIP carries its LZ77 history across CFDATA blocks. Within each folder, the trailing 32 KiB of
>   the output so far is passed as the dictionary. The history never crosses a folder boundary.
> - CFDATA checksums are verified as extraction completes (a stored 0 means "not computed" and is
>   skipped).
> - Quantum and LZX can be listed, and return a specific error when read.
> - The ZIP DOS timestamp conversion moved to `Core/DOSTimestamp.swift` and is now shared
>   (ZIP behavior is unchanged).

### 追加・修正（2026-09-09、RPM）

- 依存を追加せず純 Swift の RPM reader を追加。lead / signature header / main header を
  解析し、payload の cpio entry を直接公開する（`.tar.gz` と同じ方針）。
  gzip / bzip2 / xz / lzma / 無圧縮 の payload に対応し、source package も読む。
- codec は宣言 tag ではなく payload 先頭の magic で決める。`RPMTAG_PAYLOADCOMPRESSOR`
  が無い古い package（既定は gzip）や、宣言と実体が食い違う package も読める。
- zstd payload・rpm 6 の簡略 cpio（`07070X`）・drpm・cpio でない payload は、
  圧縮済み payload を 1 entry として公開する。
- nindex / hsize / index entry の offset と count を確保前に検査し、
  巨大値は `limitExceeded` で即座に停止する。

> **Added and fixed (2026-09-09, RPM)**
>
> - Added a pure-Swift RPM reader with no new dependencies. It parses the lead, the signature
>   header and the main header, and exposes the cpio entries of the payload directly, the same
>   approach used for `.tar.gz`. It handles gzip, bzip2, xz, lzma and uncompressed payloads, and
>   reads source packages.
> - The codec is decided by the magic at the start of the payload rather than by the declared tag,
>   so old packages without `RPMTAG_PAYLOADCOMPRESSOR` (whose default is gzip), and packages whose
>   declaration disagrees with the payload, can still be read.
> - A zstd payload, the simplified rpm 6 cpio (`07070X`), drpm, and any payload that is not cpio
>   are exposed as a single entry holding the compressed payload.
> - nindex, hsize, and the offset and count of each index entry are checked before allocation, so
>   huge values stop immediately with `limitExceeded`.

### 追加・修正（2026-09-09、xar）

- 依存を追加せず純 Swift の xar reader を追加。TOC XML（自前の部分集合 pull parser）と
  zlib / bzip2 / lzma / xz / 無圧縮の heap、入れ子ディレクトリ、symlink、hard link、
  `<name enctype="base64">`、macOS の flat package（`.pkg`）に対応。
- `<subdoc>` の subtree は entry にしない。細工した subdoc に `<file>` を仕込むと
  heap の任意範囲を読む偽 member を注入できるため、丸ごと読み飛ばす。
- TOC checksum（圧縮後の TOC に対する sha1 / md5 / sha256 / sha512）を開封時に、
  `<extracted-checksum>` を展開完了時に検証する。style は大小文字を区別せず照合する。
- `application/x-lzma` と宣言されていても payload が xz magic なら xz として読み、
  `--rfc6713` の `application/zlib` も受理する。
- `DeflateDecompressor` に RFC 1950 の zlib mode を追加（既定の raw DEFLATE は不変）。
  一範囲だけを見せる `BoundedByteSource` を追加。
- hard link の実体が参照より後ろに置かれる書庫を展開できるようにした。`Extractor` と
  互換層の「target は自分より前の index」という前提を外し、安全性は `trustedTargets` に
  同じ root へ展開済みの inode があることで担保する。前方参照の遅延は展開ループ側の責務。
- DTD・未知の実体参照・入れ子 256 段超を拒否し、TOC サイズ・entry 数・サイズ・
  metadata・パス構成要素数に ReadLimits を適用する。

> **Added and fixed (2026-09-09, xar)**
>
> - Added a pure-Swift xar reader with no new dependencies. It supports the TOC XML (through an
>   in-house pull parser for a subset of XML), a zlib, bzip2, lzma, xz or uncompressed heap, nested
>   directories, symbolic links, hard links, `<name enctype="base64">`, and the macOS flat package
>   (`.pkg`).
> - The subtree of a `<subdoc>` never becomes an entry. A crafted subdoc containing a `<file>` could
>   otherwise inject a fake member that reads an arbitrary range of the heap, so it is skipped
>   wholesale.
> - The TOC checksum (sha1, md5, sha256 or sha512 over the compressed TOC) is verified at open, and
>   `<extracted-checksum>` as extraction completes. The style is matched case-insensitively.
> - A payload declared `application/x-lzma` is read as xz when it carries the xz magic, and the
>   `application/zlib` of `--rfc6713` is also accepted.
> - `DeflateDecompressor` gained an RFC 1950 zlib mode; the default raw DEFLATE is unchanged.
>   `BoundedByteSource`, which exposes exactly one range, was added.
> - Archives whose hard-link target is stored after the reference can now be extracted. The
>   assumption in `Extractor` and the compatibility layer that a target has a lower index was
>   removed; safety instead rests on `trustedTargets` holding an inode already extracted into the
>   same root. Deferring a forward reference is the responsibility of the extraction loop.
> - DTDs, unknown entity references and nesting beyond 256 levels are rejected, and ReadLimits is
>   applied to the TOC size, entry count, sizes, metadata and path component count.

### 追加・修正（2026-09-09、ar）

- 依存を追加せず純 Swift の ar reader を追加。BSD `#1/LEN`（NUL padding）、
  SysV/GNU `//` 長名表、16 byte 短名、混在形式、`.deb` の stored member に対応。
- symbol table を通常 entry として公開し、名前解決に使う string table `//` だけを除外。thin archive は検出後に具体的なエラーで拒否。
- header / サイズ / 長名参照 / ReadLimits の検査、末尾欠損の recovery、fixture と異常系テストを追加。

> **Added and fixed (2026-09-09, ar)**
>
> - Added a pure-Swift ar reader with no new dependencies. It supports BSD `#1/LEN` (with NUL
>   padding), the SysV/GNU `//` long-name table, 16-byte short names, mixed forms, and the stored
>   members of a `.deb`.
> - The symbol table is exposed as an ordinary entry; only the `//` string table used for name
>   resolution is hidden. A thin archive is detected and rejected with a specific error.
> - Added checks on the header, sizes, long-name references and ReadLimits, recovery from a missing
>   tail, and fixtures and malformed-input tests.

### 追加・修正（2026-09-09、cpio）

- 純 Swift の cpio reader を追加。bin（両 byte order / PDP-endian）、odc、newc、crc、
  hpbin / hpodc、連結書庫、symlink に対応し、hard link は宣言サイズを保持する。
- binary 検出を既存検出の後に置き、最大4レコードの連鎖を検証する。名前・サイズ・
  metadata・entry 数の上限と切り詰めを検査し、crc の単純加算不一致は malformed とする。

> **Added and fixed (2026-09-09, cpio)**
>
> - Added a pure-Swift cpio reader. It supports bin (both byte orders), odc, newc, crc, hpbin and
>   hpodc, concatenated archives and symbolic links, and preserves the declared size of a hard link.
> - Binary detection runs after the existing detections and validates a chain of up to four records.
>   Name, size, metadata and entry-count limits and truncation are checked, and a mismatch in the
>   simple additive crc is reported as malformed.

### 追加・修正（2026-09-09、ISO 9660）

- 依存を追加せず純 Swift の ISO 9660 reader を追加。PVD / Joliet / Rock Ridge、CE 継続、
  symlink、深い階層の relocation、multi-extent に対応。NM ありの Rock Ridge を Joliet より
  優先し、両方ある画像でも symlink を保持する。NM は既存の書庫全体の文字コード判定を使う。
- extent / sector 境界、metadata 予算、directory / CE 循環を検査する。UDF は対象外。
  CLI と互換層に統合し、小さい実 writer fixture と合成画像の境界・上限テストを追加。

> **Added and fixed (2026-09-09, ISO 9660)**
>
> - Added a pure-Swift ISO 9660 reader with no new dependencies. It supports PVD, Joliet and Rock
>   Ridge, CE continuation, symbolic links, relocation of deep hierarchies, and multi-extent files.
>   Rock Ridge with NM is preferred over Joliet, so symbolic links survive on an image that has
>   both. NM uses the existing archive-wide character encoding detection.
> - Extent and sector boundaries, the metadata budget, and directory and CE cycles are checked. UDF
>   is out of scope. The reader is integrated into the CLI and the compatibility layer, and small
>   fixtures from a real writer plus synthetic images exercise the boundary and limit tests.

### 追加・修正（2026-09-09、XADMaster との black-box 差分調査から）

- 7z の coder 連鎖に対応。byte を消費する coder（LZMA / LZMA2 / PPMd7 / Deflate /
  BZip2 / AES）の入力が他 coder の出力である folder を、宣言サイズちょうどで
  上限内に実体化してから復号する。`-m0=BCJ2 -m1=LZMA2 -m2=LZMA -m3=LZMA` が作る
  `LZMA -> LZMA -> LZMA2 -> BCJ2.main` の folder が展開できるようになった。
  入力がもともと byte 範囲の経路は割り当てなしのまま。

- LZMA_Alone（`.lzma`）を単一 entry 形式として追加。13 byte header を検証して
  既存の LZMA 復号器へ繋ぐ。magic を持たない形式なので判定は最後に行い、
  拡張子・properties・辞書サイズ・range coder 先頭 byte がすべて揃うことを要求する。
  互換層の `formatName()` は XADMaster と同じ `LZMA_Alone` を返す。

- `.tar.Z` / `.tZ` を `.tar.gz` / `.tar.bz2` / `.tar.xz` と同じ compressed-tar 経路に
  載せた。4 形式すべてが同じ entry 列と同じ内容を返す。

- 7z の SPARC / IA-64 branch filter に対応。変換規則は 7-Zip を
  `-m0=<FILTER> -m1=Copy -mhc=off` で filter 出力オラクルとして使い、
  実行ファイルの入出力だけから導出した（記録は
  `Documentation/verification/2026-09-09-branch-filter-derivation.md`）。
  6 回 × 8,192 byte の敵対的ベクタでオラクルと完全一致する。
  RISC-V filter は XADMaster も全 entry を空で返すため対象外とし、
  引き続き明示的に unsupported とする。

- 破損書庫の救済モード `ReaderOptions.recoverDamagedArchives`(既定 false)を追加。
  中央ディレクトリを失った ZIP は local file header を走査して救済し、tar と LHA は
  切断点まで entry を保持する。切れた entry は `ArchiveEntry.isIncomplete` で示し、
  読めた byte だけを返す(いずれも原本の正しい prefix であることを実測で確認)。
  EOCD を潰した ZIP は XADMaster と同じ総合 SHA-256 に到達し、ZIP と LHA の
  切れた entry では XADMaster が 0 byte を返すのに対し KaitoKit は救済できる。
  不完全な entry では CRC-32 / WinZip AES HMAC / MacBinary CRC-16 の検証を飛ばすため、
  救済した byte は認証されていない旨を公開 doc に明記した。password verifier は
  救済時も働き、誤ったパスワードは `wrongPassword` のままになる。
  健全な書庫 95 件と暗号化書庫 6 件は、この設定の有無で結果が完全に一致する。

- 救済モードを RAR5 にも広げた。切り詰められた RAR5 で切断点より前の entry を返し、
  切れた entry を `isIncomplete` として読めた byte だけ返す。末尾の end marker だけを
  失った書庫は無傷と同一の結果に到達し、stored entry では XADMaster(常に 0 byte)を
  上回って部分救済できる。solid は切れた member 以降を読ませないことで総合結果が
  XADMaster と一致する。多巻の欠落は次巻へまたがる entry を完全と偽らないため
  救済対象外とした。暗号化された不完全 entry は認証されない byte を返さず何も返さない。
  宣言 packed サイズはそのまま保持し `availablePackedSize` を別に持つため、
  `maxEntrySize` の資源上限は緩まない。

- 破損書庫の部分救済を大幅に高速化した。`RecoveryDecompressor` が 1 byte ずつ読むため
  `CopyDecompressor` の一括読み取り経路(1MB 閾値 / 4MB チャンク)が無効化され、
  stored entry の部分救済が byte ごとに `ByteSource` を叩いていた。救済時の packed
  サイズは実在 byte 数へ丸め済みで read 中に truncated を投げ得ないため、
  ZIP(method 0 かつ非暗号化)・LHA(`-lh0-`)・RAR5(method 0 かつ非暗号化)に
  限って wrapper を外した。ZIP 248ms→8.4ms(約 30 倍)、LHA 236ms→5.1ms(約 46 倍)、
  RAR5 295ms→15.3ms(約 19 倍)で、いずれも切断のない読み取りと同じ速度になった。
  出力は不変で、ZipCrypto / WinZip AES と LHA の MacBinary 経路は従来どおり。

- tar の形式判定が member header の数値フィールドまで解析していたため、size が壊れた
  tar が `malformed` ではなく「未対応形式」に化けていたのを修正。判定は 512 byte・
  非空のパス名・checksum 一致だけを見る。あわせて、先頭が 0 で埋まったファイルを
  「空の tar」として受理していた挙動を止めた(ISO 9660 が tar と誤判定され、
  0 件で成功していた直接の原因)。


- CRC-16/ARC を実行時判定付き PMULL / PCLMULQDQ folding で高速化。小入力・未対応 CPU は
  従来の slice-by-eight を維持し、公開 API・逐次更新・検証結果を変えずに LHA 展開時間を短縮。

- RAR5 の復号失敗を軽量な内部状態で保持し、ヘッダ走査では上限付き先読みバッファを
  再利用して展開・open を高速化。公開 API・エラー・展開内容は維持。

> **Added and fixed (2026-09-09, from the black-box comparison against XADMaster)**
>
> - Added support for 7z coder chains. A folder in which the input of a byte-consuming coder
>   (LZMA, LZMA2, PPMd7, Deflate, BZip2 or AES) is the output of another coder is now materialized
>   at exactly its declared size, within the limits, before decoding. The
>   `LZMA -> LZMA -> LZMA2 -> BCJ2.main` folder produced by
>   `-m0=BCJ2 -m1=LZMA2 -m2=LZMA -m3=LZMA` can now be extracted. Paths whose input was already a
>   byte range remain allocation-free.
> - Added LZMA_Alone (`.lzma`) as a single-entry format. Its 13-byte header is validated and handed
>   to the existing LZMA decoder. Because the format has no magic, detection runs last and requires
>   the extension, the properties, the dictionary size and the first byte of the range coder all to
>   agree. The compatibility layer's `formatName()` returns `LZMA_Alone`, as XADMaster does.
> - Put `.tar.Z` and `.tZ` on the same compressed-tar path as `.tar.gz`, `.tar.bz2` and `.tar.xz`.
>   All four forms return the same entry list and the same contents.
> - Added the 7z SPARC and IA-64 branch filters. The transformation rules were derived only from the
>   inputs and outputs of executables, using 7-Zip with `-m0=<FILTER> -m1=Copy -mhc=off` as a filter
>   output oracle (the record is
>   `Documentation/verification/2026-09-09-branch-filter-derivation.md`).
>   Six runs of 8,192-byte adversarial vectors match the oracle exactly.
>   The RISC-V filter is out of scope, because XADMaster also returns every entry empty for it, and
>   remains explicitly unsupported.
> - Added a recovery mode for damaged archives, `ReaderOptions.recoverDamagedArchives`, default
>   false. A ZIP that lost its central directory is recovered by scanning local file headers, and
>   tar and LHA keep the entries up to the point of truncation. A truncated entry is marked with
>   `ArchiveEntry.isIncomplete` and returns only the bytes that could be read; each was measured to
>   be a correct prefix of the original. A ZIP with a destroyed EOCD reaches the same overall
>   SHA-256 as XADMaster, and for truncated ZIP and LHA entries KaitoKit recovers data where
>   XADMaster returns 0 bytes. Incomplete entries skip CRC-32, the WinZip AES HMAC and the MacBinary
>   CRC-16 verification, so the public documentation states plainly that recovered bytes are
>   unauthenticated. The password verifier still runs during recovery, so a wrong password is still
>   `wrongPassword`. For 95 undamaged archives and 6 encrypted archives the results are identical
>   with and without the setting.
> - Extended the recovery mode to RAR5. A truncated RAR5 returns the entries before the cut, and a
>   truncated entry is marked `isIncomplete` and returns only the readable bytes. An archive that
>   lost only its trailing end marker reaches the same result as an intact one, and for stored
>   entries the partial recovery goes beyond XADMaster, which always returns 0 bytes. For solid
>   groups, refusing to read from the truncated member onward makes the overall result match
>   XADMaster. A multi-volume archive missing a later volume is excluded from recovery, so that an
>   entry continuing into the next volume is never presented as complete. An incomplete encrypted
>   entry returns nothing rather than unauthenticated bytes. The declared packed size is preserved
>   and `availablePackedSize` is held separately, so the `maxEntrySize` resource limit is not
>   loosened.
> - Made partial recovery of damaged archives much faster. Because `RecoveryDecompressor` read one
>   byte at a time, the bulk-read path of `CopyDecompressor` (a 1 MB threshold with 4 MB chunks) was
>   disabled, and partial recovery of a stored entry hit the `ByteSource` once per byte. During
>   recovery the packed size is already rounded down to the bytes that exist, so a read cannot throw
>   truncated; the wrapper was therefore removed for ZIP (method 0, unencrypted), LHA (`-lh0-`) and
>   RAR5 (method 0, unencrypted). ZIP went from 248 ms to 8.4 ms (about 30x), LHA from 236 ms to
>   5.1 ms (about 46x) and RAR5 from 295 ms to 15.3 ms (about 19x), all matching the speed of an
>   untruncated read. Output is unchanged, and the ZipCrypto, WinZip AES and LHA MacBinary paths
>   behave as before.
> - Fixed tar format detection, which parsed the numeric fields of a member header and so turned a
>   tar with a corrupt size into "unsupported format" instead of `malformed`. Detection now looks
>   only at the 512-byte record, a non-empty path name and a matching checksum. Accepting a file
>   that begins with zeros as an "empty tar" was also stopped; that was the direct cause of ISO 9660
>   being misdetected as tar and succeeding with zero entries.
> - Made CRC-16/ARC faster with PMULL and PCLMULQDQ folding selected at runtime. Small inputs and
>   CPUs without support keep the previous slice-by-eight, shortening LHA extraction without
>   changing the public API, incremental updates or verification results.
> - RAR5 decryption failures are now held in lightweight internal state, and header scanning reuses
>   a bounded read-ahead buffer, making extraction and open faster. The public API, the errors and
>   the extracted content are unchanged.

## [0.1.0] - 2026-09-08

### 修正・高速化（2026-09-08）

- RAR29 / LHA static Huffman の展開を高速化。CRC16 slice-by-eight、境界検証付きの
  重複 match コピー、生バッファの Huffman lookup / bit reservoir により性能目標を達成。

- RAR5 の長い password は実測済みの先頭 127 Unicode scalars を優先し、全 UTF-8 への
  fallback で既存 writer 互換を保持。symbolic-link target の末尾が NAME_MAX を超える場合も
  安全な dangling link として展開できるよう修正。

- RAR4 solid 群内の stored member を共有状態に影響させず読み取り、RAR5 symbolic link の
  read / stream が header target の UTF-8 bytes を返すよう修正。

- RAR5 の重複 match コピー・局所状態・Huffman lookup と PPMd の固定確率表 / mask を高速化し、
  TIFF RAR5 と solid PPMd の展開を XADMaster の 1.5 倍以内に改善。

- symlink target の最後の `..` まで既存の実 directory を要求し、後続 entry / 別 archive による
  未作成成分の symlink pivot を拒否。root 内の親相対 target と安全な前方参照は維持。
- EUC-JP 半角カナが主体の名前は既知語がなくても評価し、`ｶﾀｶﾅ半角.txt` の CP932 誤判定を修正。
- RAR4 非 BMP password の方式を archive 単位で記憶し、solid prefix の entry ごとの再展開を解消。
  header CRC の選択と KDF cache を再利用し、非最終候補では error 種別によらず次の候補を検証。
- CLI の失敗 entry と CRC 不一致の source member を stderr / ERROR TSV の両方で区別。
- RAR3 writer の 127 文字 cap を移行ガイドの password 項目へ統合。

- RAR3 Audio standard filter の fingerprint 長を実 program の 216 bytes に修正。
- RAR3 の長い password と BMP 外の Unicode password の互換性を修正。UTF-16 を優先し、
  CRC 検証で Unix scalar 表現へ fallback。候補の出力は検証前に呼出側へ公開しない。
- 結合文字の前後でも `/` を byte 境界で扱い、安全な名前の誤拒否と symlink 経由の展開先逸脱を修正。
- 展開 root 内に留まる親相対 symlink target を許容。途中の既存 symlink は追わない。
- LHA level 0〜3 の 0xFF / backslash separator、level-0 Unix metadata、CP932 の 0x8E lead byte
  と EUC-JP halfwidth kana の誤判定を修正。
- CLI `sha` / `extract` は失敗を entry ごとに報告して後続へ進み、部分成功では非ゼロ終了。
- PPMd の重複した state 全走査を廃し、検証済み arena span、range decoder の特殊化、
  状態検索と頻度集計の改善で RAR4 / 7z の展開を高速化。
- ZipCrypto のランダムな一バイト password hint に依存していたテストを最終 CRC 検証へ修正。

> **Fixed and made faster (2026-09-08)**
>
> - Made RAR29 and LHA static Huffman extraction faster. The performance targets were met through
>   CRC16 slice-by-eight, bounds-validated copying of overlapping matches, and Huffman lookup and a
>   bit reservoir over raw buffers.
> - Long RAR5 passwords now prefer the measured first 127 Unicode scalars, falling back to the UTF-8
>   of the whole input to stay compatible with existing writers. Fixed extraction so that a
>   symbolic-link target whose tail exceeds NAME_MAX is still extracted as a safe dangling link.
> - Stored members inside a RAR4 solid group are read without affecting the shared state, and
>   reading or streaming a RAR5 symbolic link now returns the UTF-8 bytes of the header target.
> - Made RAR5 overlapping-match copying, local state and Huffman lookup faster, along with the fixed
>   probability tables and masks of PPMd, bringing TIFF RAR5 and solid PPMd extraction within 1.5x
>   of XADMaster.
> - Symbolic-link targets now require an existing real directory for every component up to the last
>   `..`, rejecting a symlink pivot through components created by a later entry or a different
>   archive. Parent-relative targets that stay inside the root and safe forward references are kept.
> - Names consisting mainly of EUC-JP halfwidth katakana are now evaluated even without a known
>   word, fixing the CP932 misdetection of `ｶﾀｶﾅ半角.txt`.
> - The scheme for a non-BMP RAR4 password is remembered per archive, removing the per-entry
>   re-expansion of a solid prefix. The header CRC decision and the KDF cache are reused, and for a
>   non-final candidate the next one is tried regardless of the error kind.
> - The CLI distinguishes a failing entry from the source member of a CRC mismatch, both on stderr
>   and in the ERROR TSV.
> - The 127-character cap of the RAR3 writer was folded into the password section of the migration
>   guide.
> - Corrected the fingerprint length of the RAR3 Audio standard filter to the 216 bytes of the real
>   program.
> - Fixed compatibility for long RAR3 passwords and Unicode passwords outside the BMP. UTF-16 is
>   tried first, falling back to the Unix scalar representation on CRC verification. Output from a
>   candidate is never published to the caller before it is verified.
> - `/` is treated as a byte boundary even next to combining characters, fixing both the wrongful
>   rejection of safe names and an escape from the extraction destination through a symbolic link.
> - Parent-relative symbolic-link targets that stay inside the extraction root are allowed. Existing
>   symbolic links along the way are not followed.
> - Fixed the 0xFF and backslash separators of LHA levels 0 to 3, the level-0 Unix metadata, and the
>   misdetection of the CP932 0x8E lead byte and EUC-JP halfwidth kana.
> - The CLI `sha` and `extract` report failures per entry and continue, exiting non-zero on partial
>   success.
> - Removed the duplicated full scan of PPMd states and made RAR4 and 7z extraction faster through a
>   validated arena span, a specialized range decoder, and improved state lookup and frequency
>   accounting.
> - A test that depended on the random one-byte password hint of ZipCrypto was changed to verify the
>   final CRC.

### 追加

- Swift 6 strict-concurrency 対応の SwiftPM パッケージと、静的・動的ライブラリ製品。
- 境界検査付き `ByteSource` / `ByteReader` / `BitReader`、checked 算術、CRC32、読み取り上限。
- 生の名前を保持する文字コード判定と、書庫・エントリの公開モデル。
- copy、raw deflate、bzip2 のストリーミング復号基盤。
- ustar、pax (`x` / Solaris `X`)、GNU long name/link を扱う tar reader。
- M4 の LHA / LZH reader。header level 0 / 1 / 2 / 3、level 0 / 1 の byte sum、level 2 / 3 の
  optional 0x00 header CRC16、拡張 header 0x00 / 0x01 / 0x02 / 0x3f / 0x40〜0x42 / 0x46 /
  0x50〜0x54、32 / 64-bit size、DOS / Unix / Windows 日時、directory を扱う。認証済み
  member header を最大 1 MiB まで探す bounded SFX prefix にも対応する。
- LHA の `-lh0-` / `-lz4-` / `-pm0-` stored、`-lh1-` adaptive Huffman、
  `-lh4-`〜`-lh7-` static Huffman、1 MiB 辞書の `-lhx-`、OS marker 付き `-lh7-` の
  LHArk dialect、`-lz5-` / `-lzs-` LArc を実装し、member ごとの CRC16 を検証する。
  `-pm1-` / `-pm2-` / `-lh2-` / `-lh3-` は明示的に非対応。
- LHA legacy 名を書庫単位で判定し、0x46 codepage の 932 / 65001 / 936 は宣言済み
  encoding として扱う。末尾 separator の directory 判定、先頭 slash / drive prefix の相対化、
  filename field の NUL 終端、空名 member、OS/2 extended-attribute subdirectory を通常の
  安全な entry traversal と両立させる。各 member は独立しており `solidGroup == -1`。
- OS-9 LHA 2.01 が raw creator ID に 0x4B (既存 mapping では OS/68K marker) を記録し、2 bytes
  少なく宣言する level-2 header と、無効な DOS timestamp (`nil`) を、境界が一意に検証できる場合に
  受理する。zero terminator がなく、最終の境界検証済み payload の直後で exact EOF に達する archive は、
  最終 member が LArc の場合、または書庫内に構造検証済みの匿名通常 member を少なくとも 1 件含む場合だけ
  受理する。
- MacLHA の Macintosh OS marker を持つ member は、MacBinary / MacBinary II standard proposals に
  基づく有効な envelope の data fork だけを公開しながら、padding、resource fork、compatible trailing
  extension を含む全出力の LHA CRC16 を検証する。MacBinary ではない Macintosh member は変更せずに返す。
- hand-built level 0 / 1 / 2、codepage、metadata、static / legacy decoder vector、
  cooViewer `book.lzh` と lhasa の SHA-256 差分を追加。Swift 6.4 AddressSanitizer では
  parser / container 384 件と実 archive seed の method 320 件、計 704 deterministic mutant を実行し、
  test / sanitizer failure は 0 件だった。
- 供給された corpus directory の 227 archive は、当時の集計で 203 件が lhasa と byte-identical、8 件が
  Unix symlink semantics の差(後述のレビュー修正で `.symlink` として展開)、9 件が KaitoKit 側の想定内 failure (PM1 系 4 件: 非対応 3 / truncated 1、PM2 非対応
  3 件、4.5 GiB member に対する既定 4 GiB 上限 1 件、parent traversal 拒否 1 件)、7 件が
  lhasa / oracle 側の failure (LH2 / LH3 2、malformed PM2 1、truncated 1、unusual link / EA 3) だった。
- 中央ディレクトリ駆動、ZIP64、SFX prefix、遅延ローカルヘッダ検証に対応した ZIP reader。
- ZIP の stored、deflate、Deflate64、bzip2、raw LZMA1 圧縮方式と UNIX symlink。
- Traditional PKWARE (ZipCrypto) と WinZip AES-128/192/256 (AE-1/AE-2) の復号・認証。
- UTF-8 / Info-ZIP Unicode Path / 日本語文字コードの名前復元、ZIP timestamp、CRC32 検証。
- ZIP / tar の書庫単位文字コード判定と `ArchiveReader.nameEncoding`。
- 既知長の大きな stored entry を最終 `Data` へ直接読み込む高速経路。
- raw LZMA2 の chunk / reset state を逐次復号し、辞書サイズと chunk サイズを検証する
  `LZMA2Decoder`、および後方 seek 用の dictionary-reset index。
- plain / encoded header、UTF-16LE 名、日時・属性、empty / anti item、packed / folder /
  substream CRC を扱う 7z reader。
- 7z の Copy、LZMA1、LZMA2、PPMd7、Deflate、BZip2 と、Delta、x86 / ARM / ARMT /
  ARM64 / PPC BCJ、4-stream BCJ2 filter。PPMd7 は単一の上限付き arena と検証済み offset
  で context / suballocator を保持する。IA64 / SPARC filter は明示的に非対応。
- solid / block-split folder の継続読み取り、`solidGroup`、pure LZMA2 folder の
  dictionary reset からの後方再開。
- 7zAES の AES-256-CBC / SHA-256 KDF、header encryption、派生鍵 cache、KDF 計算量上限。
  独立した認証 tag がないため、最初の CRC 不一致または coder 構造不正を誤 password と判定。
- M3 の RAR4 reader。main / file / end header、header CRC、64-bit size、RAR Unicode / legacy 名、
  `EXT_TIME`、stored、unpack version 29 の LZ / PPMd-H と block transition、展開後 CRC32 を実装。
  RAR3 standard VM の E8 / E8E9 / Itanium / Delta / RGB / Audio は native 実装し、custom VM は
  明示的に拒否する。圧縮 version 15 / 20 / 26 を含む version 29 以外も明示的に非対応。
- RAR4 solid は window / Huffman / 距離 / filter program / PPMd model を entry 間で継続し、
  順方向 skip、後方再開、暗号化 solid を扱う。RAR3 per-file AES-128-CBC と `-hp` header
  encryption、old (`.rar` / `.r00`) / new (`.partN.rar`) multi-volume、上限付き SFX prefix、
  非最終 split part の packed CRC32 を実装。SFX prefix と multi-volume の組合せは明示的に非対応。
- M3 の RAR5 reader。CRC 付き main / file / service / encryption / end header、vint / extra record、
  サイズ不明 entry、stored と圧縮アルゴリズム version 0 の LZ (method 1〜5)、Delta / E8 /
  E8E9 / ARM filter を実装。solid は stored member の混在、member ごとの dictionary minimum
  変更、順方向 skip / 後方再開を扱う。
- RAR5 per-file AES-256-CBC と archive `-hp` header encryption、PBKDF2-HMAC-SHA256、password
  check、暗号化 CRC / BLAKE2sp HashMAC、暗号化 multi-volume を end-to-end 実装。非最終 part の
  packed CRC32 / BLAKE2sp、保持した directory descriptor からの sibling open、既定 128 volume
  上限、path を再解決しない `reopen()` を含む。archive-header KDF は個別の `count` を最大 24 に
  制限し、全 header-encrypted volume の異なる `(password, salt, count)` context を public API の
  `ReadLimits.maxRAR5HeaderKDFWork` へ HMAC-SHA256 iteration 単位で `2^count + 32` ずつ累積する。
  同一 context の key-cache hit は再加算せず、既定値は最大コストの `count = 24` context 4 件分
  (`4 * (2^24 + 32)`)。
- RAR5 の file-copy redirection の展開、RAR5 SFX、Data / 任意 `ByteSource` からの volume 継続、
  サイズ不明の暗号化 stored entry は明示的に非対応。圧縮アルゴリズム version 1 と version 2 以上、
  method 6 以上、file-encryption record version 1 以上、KDF count 上限超過は、対象 entry の
  stream 作成時に拒否し、他の entry の一覧・読み取りを妨げない。codec 辞書の既定上限は 1 GiB。
- RAR5 実書庫 5 本、431 file stream、915,433,332 bytes を RAR 7.23 と SHA-256 差分確認。
  RAR4 は `st1200-pts.rar` の 19/19 file と 241,647,978-byte PPMd↔LZ entry が一致した。
  追加 corpus 20 書庫では 47 regular file と 5 symlink target が一致し、既知 password で
  oracle を得られない暗号化 entry は 1 件、破損 `seek_data_cursor0` は双方が拒否した。
  RAR4 / RAR5 の unit-level deterministic mutant を合計 544 件実行。さらに 8 種の RAR seed から
  400 件を `Scripts/fuzz/run-mutants.sh` の ASan build で実行し、crash / hang / sanitizer finding は 0 件。
- test 時に 7zz で生成する各 7z method / AES / solid fixture、10 MiB streaming、cooViewer
  fixture の SHA-256 差分テスト (`/opt/homebrew/bin/7zz` がない環境では明示的に skip)。
- 検出、一覧、展開、SHA-256 差分 oracle、ベンチマークを提供する `kaito` CLI。
  `sha` は entry 全体の `Data` を保持せず、再利用する有界 buffer で逐次 hash する。
  controlled before/after median は book RAR5 155.346→155.431 ms、TIFF RAR5
  637.541→610.447 ms、最終 warm wall time は 0.15 / 0.61 s。以前の約 0.62 秒差は
  `swift run` の cold-start / planning 混入だった。
- memory-mapped `Data` 経路を計測する `kaito bench --data`。
- 最大 20 エントリの再現可能なランダムアクセスを計測する `kaito bench --random`。
- 圧縮方式と暗号化状態を表示する `kaito list`。
- XADArchive の cooViewer 利用面と ZIP 遅延ローカルヘッダ既定値 API を覆う薄い
  `KaitoKitCompat` 層。
- archive member に結び付けた hard link、安全な dirfd ベースのパス展開、単体・CLI テスト。
- エントリ・PAX・パス・総メタデータの上限と、ASan/UBSan ミュータント実行スクリプト。
- ユニバーサル `KaitoKit.framework` を組み立てるスクリプトと移行ガイド。
- 設計書: 要件、安全規則、実装方式、API 層、検証方針、マイルストーン。
- RAR / LHA の敵対レビュー(39 エージェント)確定 9 件の修正。RAR29 LZ は symbol ループの
  各 iteration で入力枯渇を検査し(履歴の無い symbol 258 の no-op 経路)、RAR5 filter は caller
  buffer 長に依存せず途中再開する。RAR5 の hard link (redirection type 4) / file reference (type 5)
  は body なしの 0-byte entry として一覧・読み取りでき、solid chain と総展開サイズに参加しない
  (type 4 は展開時に hard link、type 5 の copy 展開は非対応)。`ArchiveReader.extract` の
  hard link 出所 key は最寄りの既存 ancestor を解決する(未作成の `/private/tmp` と `/tmp` 表記)。
  RAR4 / RAR5 の Unix symlink は `linkTargetStoredAsData` を公開して stored target から展開し、
  LHA の `-lhd-` + `S_IFLNK` は `name|target` を `.symlink` / `linkPath` に分離する。
  `ReadLimits.maxMetadataRecordCount` は書庫累計ではなく record set 単位(LHA member の
  extension chain、RAR5 header の extra area)の上限になった。RAR4 `-p` の compressed entry は
  decoder の malformed / truncated を `.wrongPassword` に正規化し、`-hp` は物理的に短い
  envelope と後続切断を `.truncated` として区別する。`ReaderOptions.maxRAR5KDFCountPower` /
  `maxSevenZipAESCyclesPower` は代入時にも 24 / 62 へ clamp する。
- Scripts/fuzz: RAR4 LZ / PPMd-H、RAR5 LZ、LHA lh4 / lh6 / lh7 の packed-range locator と
  compressed seed 生成、`--require-payload-ranges`。RAR5 LZ seed は同梱の project-generated
  fixture(`Tests/Fixtures/rar5/lz-small.rar.b64`)から復元し、`rar` は明示指定時だけ使う。corpus 依存テストは
  `KAITOKIT_RAR4_CORPUS` / `KAITOKIT_LHA_CORPUS` などの環境変数で指定し、libarchive
  (BSD-2-Clause)/ ISC 由来の小さな fixture を `Tests/Fixtures` に base64 で固定する
  (`Tests/Fixtures/NOTICE`)。

> **Added**
>
> - A SwiftPM package with Swift 6 strict concurrency, and both static and dynamic library products.
> - Bounds-checked `ByteSource`, `ByteReader` and `BitReader`, checked arithmetic, CRC32, and read
>   limits.
> - Character encoding detection that preserves the raw name, and the public model of archives and
>   entries.
> - Streaming decode infrastructure for copy, raw deflate and bzip2.
> - A tar reader handling ustar, pax (`x` and Solaris `X`) and GNU long name and link.
> - The M4 LHA / LZH reader. It handles header levels 0, 1, 2 and 3, the byte sum of levels 0 and 1,
>   the optional 0x00 header CRC16 of levels 2 and 3, extended headers 0x00, 0x01, 0x02, 0x3f,
>   0x40 to 0x42, 0x46 and 0x50 to 0x54, 32- and 64-bit sizes, DOS, Unix and Windows timestamps, and
>   directories. It also supports a bounded SFX prefix, searching up to 1 MiB for an authenticated
>   member header.
> - Implemented the LHA `-lh0-`, `-lz4-` and `-pm0-` stored methods, `-lh1-` adaptive Huffman,
>   `-lh4-` through `-lh7-` static Huffman, `-lhx-` with a 1 MiB dictionary, the LHArk dialect of
>   `-lh7-` with an OS marker, and `-lz5-` and `-lzs-` LArc, verifying the per-member CRC16.
>   `-pm1-`, `-pm2-`, `-lh2-` and `-lh3-` are explicitly unsupported.
> - LHA legacy names are decided per archive, and codepages 932, 65001 and 936 of extension 0x46 are
>   treated as a declared encoding. Directory detection from a trailing separator, relativization of
>   a leading slash and drive prefix, NUL termination of the filename field, members with an empty
>   name, and OS/2 extended-attribute subdirectories all coexist with the normal safe entry
>   traversal. Each member is independent, with `solidGroup == -1`.
> - Accepts the level-2 header that OS-9 LHA 2.01 writes, which records 0x4B in the raw creator ID
>   (an OS/68K marker under the existing mapping) and declares two bytes too few, together with an
>   invalid DOS timestamp (`nil`), when the boundary can be validated unambiguously. An archive with
>   no zero terminator that reaches exact EOF immediately after the last boundary-validated payload
>   is accepted only when the last member is LArc, or when the archive contains at least one
>   structurally validated anonymous ordinary member.
> - For a member carrying the MacLHA Macintosh OS marker, only the data fork of an envelope that is
>   valid under the MacBinary and MacBinary II standard proposals is exposed, while the LHA CRC16 is
>   verified over the entire output including padding, the resource fork and any compatible trailing
>   extension. A Macintosh member that is not MacBinary is returned unchanged.
> - Added hand-built level 0, 1 and 2 archives, codepage and metadata cases, static and legacy
>   decoder vectors, and a SHA-256 comparison of cooViewer's `book.lzh` against lhasa. Under Swift
>   6.4 AddressSanitizer, 384 parser and container mutants plus 320 method mutants from real archive
>   seeds, 704 deterministic mutants in total, ran with zero test or sanitizer failures.
> - Of the 227 archives in the supplied corpus, the tally at the time was 203 byte-identical to
>   lhasa, 8 differing in Unix symlink semantics (extracted as `.symlink` after the review fixes
>   described above), 9 expected failures on the KaitoKit side (4 PM1 cases: 3 unsupported and 1
>   truncated; 3 unsupported PM2; 1 hitting the default 4 GiB limit on a 4.5 GiB member; 1 rejected
>   parent traversal), and 7 failures on the lhasa or oracle side (2 LH2/LH3, 1 malformed PM2, 1
>   truncated, 3 unusual link or EA cases).
> - A ZIP reader driven by the central directory, supporting ZIP64, an SFX prefix and lazy local
>   header validation.
> - The ZIP stored, deflate, Deflate64, bzip2 and raw LZMA1 methods, and UNIX symbolic links.
> - Decryption and authentication for Traditional PKWARE (ZipCrypto) and WinZip AES-128/192/256
>   (AE-1/AE-2).
> - Name recovery from UTF-8, the Info-ZIP Unicode Path and Japanese character encodings, ZIP
>   timestamps, and CRC32 verification.
> - Archive-wide character encoding detection for ZIP and tar, and `ArchiveReader.nameEncoding`.
> - A fast path that reads a large stored entry of known length directly into the final `Data`.
> - `LZMA2Decoder`, which decodes raw LZMA2 chunks and reset states incrementally while validating
>   the dictionary and chunk sizes, plus a dictionary-reset index for backward seeks.
> - A 7z reader handling plain and encoded headers, UTF-16LE names, timestamps and attributes,
>   empty and anti items, and packed, folder and substream CRCs.
> - The 7z Copy, LZMA1, LZMA2, PPMd7, Deflate and BZip2 methods, and the Delta, x86, ARM, ARMT,
>   ARM64 and PPC BCJ filters and the four-stream BCJ2 filter. PPMd7 keeps its contexts and
>   suballocator in a single bounded arena with validated offsets. The IA64 and SPARC filters are
>   explicitly unsupported.
> - Continued reading across solid and block-split folders, `solidGroup`, and backward resumption
>   from a dictionary reset in a pure LZMA2 folder.
> - The 7zAES AES-256-CBC and SHA-256 KDF, header encryption, a derived-key cache and a KDF work
>   limit. Because there is no independent authentication tag, the first CRC mismatch or an invalid
>   coder structure is reported as a wrong password.
> - The M3 RAR4 reader. It implements the main, file and end headers, the header CRC, 64-bit sizes,
>   RAR Unicode and legacy names, `EXT_TIME`, stored data, the LZ and PPMd-H of unpack version 29
>   with their block transitions, and the CRC32 of the expanded output. The RAR3 standard VM filters
>   E8, E8E9, Itanium, Delta, RGB and Audio are implemented natively, and the custom VM is
>   explicitly rejected. Compression versions other than 29, including 15, 20 and 26, are explicitly
>   unsupported.
> - RAR4 solid mode continues the window, Huffman tables, distances, filter programs and PPMd model
>   across entries, and handles forward skipping, backward resumption and encrypted solid groups.
>   RAR3 per-file AES-128-CBC and `-hp` header encryption, old (`.rar` / `.r00`) and new
>   (`.partN.rar`) multi-volume sets, a bounded SFX prefix, and the packed CRC32 of a non-final split
>   part are implemented. SFX combined with multi-volume is explicitly unsupported.
> - The M3 RAR5 reader. It implements CRC-carrying main, file, service, encryption and end headers,
>   vints and extra records, entries of unknown size, stored data and the LZ of compression
>   algorithm version 0 (methods 1 to 5), and the Delta, E8, E8E9 and ARM filters. Solid mode
>   handles mixed stored members, a per-member change of the dictionary minimum, and forward
>   skipping and backward resumption.
> - RAR5 per-file AES-256-CBC and archive `-hp` header encryption, PBKDF2-HMAC-SHA256, the password
>   check, the encrypted CRC and BLAKE2sp HashMAC, and encrypted multi-volume sets are implemented
>   end to end. This includes the packed CRC32 and BLAKE2sp of a non-final part, sibling opens from
>   a retained directory descriptor, a default limit of 128 volumes, and a `reopen()` that does not
>   re-resolve paths. The archive-header KDF bounds each individual `count` at 24 and accumulates
>   each distinct `(password, salt, count)` context across all header-encrypted volumes into the
>   public `ReadLimits.maxRAR5HeaderKDFWork`, charging `2^count + 32` HMAC-SHA256 iterations per
>   context. A key-cache hit on the same context is not charged again, and the default is four
>   contexts at the most expensive `count = 24` (`4 * (2^24 + 32)`).
> - Expanding RAR5 file-copy redirection, RAR5 SFX, volume continuation from `Data` or a custom
>   `ByteSource`, and encrypted stored entries of unknown size are explicitly unsupported.
>   Compression algorithm version 1 and versions 2 and above, methods 6 and above,
>   file-encryption record version 1 and above, and exceeding the KDF count limit are rejected when
>   the stream for that entry is created, without preventing other entries from being listed or
>   read. The default codec dictionary limit is 1 GiB.
> - Five real RAR5 archives, 431 file streams and 915,433,332 bytes were compared by SHA-256 against
>   RAR 7.23. For RAR4, 19 of 19 files of `st1200-pts.rar` and its 241,647,978-byte PPMd/LZ entry
>   matched. Across an additional 20-archive corpus, 47 regular files and 5 symlink targets matched;
>   one encrypted entry had no oracle under the known passwords, and the damaged
>   `seek_data_cursor0` was rejected by both. In total 544 unit-level deterministic mutants were run
>   for RAR4 and RAR5. A further 400 mutants from 8 RAR seeds were run against the ASan build of
>   `Scripts/fuzz/run-mutants.sh`, with zero crashes, hangs or sanitizer findings.
> - SHA-256 differential tests over 7z method, AES and solid fixtures generated with 7zz at test
>   time, a 10 MiB streaming case, and the cooViewer fixture; these are explicitly skipped where
>   `/opt/homebrew/bin/7zz` is absent.
> - The `kaito` CLI, providing detection, listing, extraction, a SHA-256 differential oracle and
>   benchmarks. `sha` hashes incrementally through a reused bounded buffer rather than holding the
>   whole entry as `Data`. The controlled before-and-after medians were 155.346 to 155.431 ms for
>   the book RAR5 and 637.541 to 610.447 ms for the TIFF RAR5, with final warm wall times of 0.15
>   and 0.61 s. The roughly 0.62 second difference seen earlier came from mixing the `swift run`
>   cold start and planning into the measurement.
> - `kaito bench --data`, which measures the memory-mapped `Data` path.
> - `kaito bench --random`, which measures reproducible random access over up to 20 entries.
> - `kaito list`, which shows the compression method and the encryption state.
> - A thin `KaitoKitCompat` layer covering the XADArchive surface that cooViewer uses and the API
>   for the ZIP lazy local header default.
> - Hard links bound to their archive member, safe dirfd-based path resolution, and unit and CLI
>   tests.
> - Limits on entries, PAX records, paths and total metadata, and the ASan/UBSan mutant runner
>   scripts.
> - A script that assembles the universal `KaitoKit.framework`, and the migration guide.
> - The design document: requirements, safety rules, implementation approach, API layers,
>   verification policy and milestones.
> - Fixes for the 9 confirmed findings of the adversarial review of RAR and LHA (39 agents). RAR29 LZ
>   checks for input exhaustion on every iteration of the symbol loop (the no-op path of symbol 258
>   with no history), and RAR5 filters resume mid-way independently of the caller's buffer length.
>   RAR5 hard links (redirection type 4) and file references (type 5) can be listed and read as
>   0-byte entries with no body, and take part in neither the solid chain nor the total expanded
>   size; type 4 becomes a hard link at extraction, and copying the referenced data for type 5 is
>   unsupported. The hard-link provenance key of `ArchiveReader.extract` resolves the nearest
>   existing ancestor, covering the uncreated `/private/tmp` and `/tmp` spellings. RAR4 and RAR5
>   Unix symbolic links expose `linkTargetStoredAsData` and are extracted from the stored target,
>   and the LHA `-lhd-` with `S_IFLNK` splits `name|target` into `.symlink` and `linkPath`.
>   `ReadLimits.maxMetadataRecordCount` became a limit per record set (the extension chain of an LHA
>   member, the extra area of a RAR5 header) rather than a per-archive total. A compressed RAR4
>   entry under `-p` normalizes the decoder's malformed and truncated errors to `.wrongPassword`,
>   while `-hp` distinguishes a physically short envelope and a later cut as `.truncated`.
>   `ReaderOptions.maxRAR5KDFCountPower` and `maxSevenZipAESCyclesPower` are clamped to 24 and 62 on
>   assignment as well.
> - Scripts/fuzz: packed-range locators and compressed seed generation for RAR4 LZ and PPMd-H, RAR5
>   LZ, and LHA lh4, lh6 and lh7, plus `--require-payload-ranges`. The RAR5 LZ seed is restored from
>   the bundled project-generated fixture (`Tests/Fixtures/rar5/lz-small.rar.b64`), and `rar` is used
>   only when explicitly specified. Corpus-dependent tests are pointed at their data through
>   environment variables such as `KAITOKIT_RAR4_CORPUS` and `KAITOKIT_LHA_CORPUS`, and small
>   fixtures derived from libarchive (BSD-2-Clause) and ISC sources are pinned in `Tests/Fixtures` as
>   base64 (`Tests/Fixtures/NOTICE`).
