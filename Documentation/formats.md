# 対応形式と形式ごとの挙動

[README](../README.md#対応状況) の概要を補う完全な対応表です。読み取り範囲と未対応方式は
[制限](limitations.md)、安全な展開と上限設定は [組み込みガイド](embedding.md) を参照してください。

## 対応状況

| 形式 | コンテナ・圧縮方式 | 暗号化 | multi-volume / multi-stream |
|---|---|---|---|
| ISO 9660 / BIN・CUE | PVD、Joliet、Rock Ridge（NM/CE/PX/SL/TF/ZF、深い階層）、multi-extent、stored、zisofs（ZF version 1 / `pz`、32〜128 KiB block の zlib、0 埋め block）。UDF との hybrid は UDF の木を優先。生 sector image（ECMA-130 の 2352 byte sector、Mode 1 / Mode 2 と 8 byte sub-header、2448 byte の sub-channel 付き、2336 byte 版。`.bin` `.img` `.mdf`）も同じ `iso` / `udf` として開き、`.cue` の URL は data track の image を辿る | なし | 最初の session のみ。EDC / ECC は検証しない |
| MacBinary / AppleSingle / BinHex 4 | payload が StuffIt でない wrapper を、data fork（entry 0）と resource fork（`name/..namedfork/rsrc`）の 1 file 書庫として公開。名前・type / creator・Finder flags・日時（MacBinary は 1904 起点、AppleSingle は File Dates Info）を header から取る。payload が StuffIt なら従来どおり StuffIt として開く | なし | 一段だけ剥がす（MacBinary の中の ZIP は file として公開） |
| WIM / `.wim` `.swm` | Windows Imaging 1.13（`MSWIM`）、stored / XPRESS（[MS-XCA] LZ77+Huffman、chunk 4〜64 KiB の 2 冪）/ LZX（WIM 変種: chunk 32 KiB、E8 変換 12,000,000）、複数 image（`1/` `2/` の前置）、alternate data stream（`name:stream`）、hard link 群、symbolic link / junction の reparse point（[MS-FSCC]）、resource ごとの SHA-1 検証 | なし | 分割 `.swm` は先頭 part の metadata だけ（他 part の resource は `unsupportedMethod`）。solid / ESD（LZMS、version 0.14）は非対応 |
| Compound File / `.msi` `.doc` `.xls` `.ppt` `.msg` | [MS-CFB] version 3（512 byte sector）/ 4（4096 byte sector、64 bit サイズ）、FAT / DIFAT（header 外の DIFAT sector を含む）/ mini FAT と mini stream、storage を directory、stream を stored file として公開。storage の CLSID（`formatSpecific["clsid"]`）と更新日時、制御文字で始まる名前は 7-Zip と同じ `[5]SummaryInformation` の綴り。Windows Installer の詰め込み名（`!_Tables`、`setup.cab` など）は 7-Zip と同じ写像で戻し、元の UTF-16 名は `formatSpecific["storedName"]` | なし | MSI 内の cabinet や Office の property set は解釈しない |
| CHM / `.chm` | HTML Help（ITSF version 3、ITSP directory の PMGL chunk 連鎖）、section 0 の stored file と `MSCompressed` section の LZX（window 32 KiB〜2 MiB、reset interval ごとの全状態 reset、0x8000 byte block の reset table、E8 変換）。`/` 以下の利用者 file と `#SYSTEM` などの format file を公開し、`::DataSpace/…` の内部 file は出さない（7-Zip と同じ） | なし | 直近の reset interval 1 つを cache して file 単位の random access に応える。version 2 header は Russotto の記述どおりに読むが標本が無く未検証 |
| ARJ / `.arj` `.exe` | main header / local file header（version 1〜11、ARJ32）、stored（0）と method 1〜3（LHA lh6 と同じ LZ77 + 静的 Huffman、窓 26 KB）、directory（file type 3）、DOS の `\` 区切りと PATHSYM 名、書庫全体の名前 encoding 判定（CP932 など）、comment、DOS 日時、CRC-32、DOS SFX（MZ の後ろの main header を technote の手順で探す）、method 8 / 9（no data） | なし（garbled は一覧のみ） | method 4（compressed fastest）、garbled（暗号化）、multi-volume の続き file は `unsupportedMethod`。extended header は読み飛ばす |
| Apple Disk Image / `.dmg` `.img` | UDIF（koly + blkx: zero-fill / raw / zlib / bzip2 / lzfse / lzma(xz) の chunk、直近 4 chunk の cache）と生の HFS+ image（GPT / Apple Partition Map / bare volume）。HFS Plus / HFSX の catalog（file、directory、symlink、hard link は indirect node の本文、resource fork は `name/..namedfork/rsrc`）、extents overflow、更新日時、permissions、type / creator。decmpfs（zlib / LZVN / LZFSE / stored、type 1 は raw、type 9 は `0xCC` + raw）。type 3 / 4 / 7 / 8 / 9 は 7-Zip 26.03 でも展開して原本と照合済み。UDIF に包まれた ISO 9660 / UDF はその reader へ | なし | ADC（UDCO）chunk と APFS は `unsupportedMethod`。decmpfs（UF_COMPRESSED）は type 1 / 3 / 4 / 7 / 8 / 9 / 10 / 11 / 12（stored / zlib / LZVN / LZFSE、inline xattr または resource fork の 64 KiB chunk）を読める。type 5 / 13 / 14・未知の type・fork 格納の属性は一覧のみ。複数 volume は最初の HFS+ だけ。app 配布 DMG の `/Applications` への絶対 symlink は extractor の方針で作らない |
| UDF / `.udf` `.iso` `.img` | ECMA-167 / OSTA UDF 1.02〜2.60、block 512〜4096、type 1 / sparable（sparing table）/ virtual（VAT、1.50 形式と 2.x 形式）/ metadata partition（mirror へ fallback）、FE / EFE、inline data、複数 entry の ICB（strategy 4。strategy 4096 の indirect entry は仕様どおり実装したが macOS の driver が拒むため未検証）、symlink（path component 列と hdiutil の生 path）、`*UDF Macintosh Resource Fork` named stream を `..namedfork/rsrc` として公開 | なし | 単一 volume。tag checksum / CRC / 位置を検証 |
| ar / .deb | BSD 長名、SysV/GNU 文字列表、stored | なし | symbol table を公開、長名表 `//` のみ非公開、thin archive は明示的に拒否 |
| cpio | bin（両 byte order）、odc、newc、crc、hpbin、hpodc、stored。`.cpgz` / `.cpio.<codec>`（gz / bz2 / xz / zst / lz4 / lzma / lz / br / Z）と pbzx の Payload は展開後に CpioReader で列挙 | なし | 連結書庫、symlink、宣言サイズどおりの hard link |
| xar / .pkg | TOC XML（部分集合 pull parser）、zlib / bzip2 / lzma / xz / stored の heap、入れ子ディレクトリ、symlink、hard link、`<name enctype="base64">`、macOS flat package | なし | なし。TOC checksum と `<extracted-checksum>` を検証、`<subdoc>` 内の `<file>` は entry にしない |
| CAB | CFHEADER / CFFOLDER / CFFILE / CFDATA、None / MSZIP / LZX（15〜21 bit の辞書、CFDATA をまたぐ履歴）、予約領域、UTF-8 名 (attribs 0x80)、上限付き PE / Mach-O SFX prefix | なし | 多分割フラグがあっても手元の cabinet の file は読み、実際にまたぐ file だけ拒否。Quantum は一覧のみ |
| RPM | lead / signature header / main header、classic cpio と stripped `07070X`（rpm ≥ 4.12 の 4 GB 超 file、rpm 6 の既定）の entry を直接公開、gzip / bzip2 / xz / lzma / zstd / stored payload | なし | stripped の名前・サイズ・mode は header tags から復元。hard link は非 ghost の最大 index に本文、他は 0 byte。ghost は省略。codec は payload の magic で決定 |
| tar | POSIX/ustar、pax、GNU long name/link、stored member、GNU sparse（旧 GNU `S` 型、pax 0.0 / 0.1 / 1.0。穴は 0 で埋め、実サイズと `GNU.sparse.name` の名前を公開）。macOS tar の `._name` AppleDouble sidecar は既定で resource fork に統合 | なし | volume 分割なし |
| gzip | RFC 1952、FTEXT/FHCRC/FEXTRA/FNAME/FCOMMENT、DEFLATE、CRC32/ISIZE | なし | concatenated member 対応 |
| bzip2 | BZip2 block size 1〜9 | なし | concatenated stream 対応 |
| xz | XZ container、Apple Compression の LZMA、footer/padding | なし | concatenated stream 対応 |
| zstd | RFC 8878、`.zst` / `.tar.zst` / `.tzst`、RPM payload、ZIP method 20/93、XXH64 checksum。辞書は非対応 | なし | 連結 frame・skippable frame 対応 |
| LZ4 frame | `.lz4` / `.tar.lz4`、独立／連続block、stored block、header/block/contentのXXH32、宣言サイズ、legacy 8 MiB block | なし | 連結・skippable frame対応。外部辞書は非対応。legacyにはchecksum・宣言サイズがない |
| UNIX compress (`.Z`) | LZW、9〜16 bit、block mode | なし | なし |
| LZMA_Alone (`.lzma` / `.tlz`) | 13 byte header + raw LZMA。magic が無いため拡張子・properties・辞書サイズ・range coder 先頭 byte がすべて揃ったときだけ受理し、判定は最後に回す | なし | なし |
| pbzx | `pbzx` + chunk size、chunk ごとの展開後サイズ / 格納長、XZ stream または生の chunk（macOS `pkgbuild --compression latest` の Payload、OTA）。展開結果が cpio なら cpio として列挙し、そうでなければ単一 stream | なし | なし。chunk ごとの宣言サイズを検証 |
| lzip (`.lz` / `.tar.lz`) | `LZIP` + version 1 + 辞書サイズ 1 byte + LZMA-302eos（lc=3/lp=0/pb=2、end marker）+ CRC-32 / data size / member size の trailer。末尾の member size を辿って索引を作り、展開後サイズを open 時に確定 | なし | multimember 対応。member ごとに CRC-32・data size・LZMA stream の消費長を検証。末尾の余分な byte は `malformed` |
| brotli (`.br` / `.tar.br` / `.tbr`) | RFC 7932 の stream（Apple Compression `COMPRESSION_BROTLI` で復号）。RFC 9841 の large window header（WBITS 10〜62）を解釈し、window を `maxDictionarySize` と照合。magic・サイズ・checksum が無いため、`.br` / `.tbr` の名前と有効な header、先頭 64 KiB の試し復号がそろったときだけ受理し、判定は最後に回す | なし | なし。単一 stream で、END 後の余分な byte は `malformed` |
| 圧縮 tar | `.tgz` / `.tar.gz`、`.tbz` / `.tbz2` / `.tar.bz2`、`.tar.lzma` / `.tlz`、`.txz` / `.tar.xz`、`.tar.zst` / `.tzst`、`.tar.lz4`、`.tar.lz`（`.tlz` は署名で LZMA_Alone / lzip を判別）、`.tar.br` / `.tbr`、`.taz` / `.tz` / `.tar.Z` を展開後に TarReader で列挙 | なし | なし |
| ZIP / ZIP64 | stored (0)、Shrink (1、連続する部分クリア後も未使用 code を再利用)、Reduce (2〜5)、Implode (6)、Deflate (8)、Deflate64 (9)、BZip2 (12)、LZMA (14)、Zstandard (20/93)、XZ (95)、PPMd (98)、中央 directory、SFX。Finder / ditto の `__MACOSX/._name` AppleDouble sidecar は既定で resource fork に統合（`ReaderOptions.appleDoublePolicy`） | ZipCrypto、WinZip AES-128/192/256 (AE-1/AE-2) | `.zip.001` のバイト分割、`.z01`…`.zip` / `.zx01`…`.zipx` の split ZIP（ZIP64・100 巻以上）対応。最終巻・途中巻から URL open |
| 7z | Copy、LZMA1、LZMA2、PPMd7 var.H、Deflate、Deflate64、BZip2、Zstandard（7-Zip ZS / NanaZip / libarchive の coder 04F71101）、Delta、Swap2/Swap4、BCJ (x86/ARM/ARMT/ARM64/PPC/SPARC/IA-64)、BCJ2、coder 連鎖 (byte を消費する coder が他 coder の出力を入力にする folder)、solid folder、上限付き Mach-O/PE SFX prefix | 7zAES-256、data/header encryption | `.001` 分割巻（7-Zip `-v`）、solid/block split 対応 |
| RAR4 | stored、unpack version 29 の LZ/PPMd-H、E8/E8E9/Itanium/Delta/RGB/Audio、solid、上限付き SFX | RAR3 AES-128 per-file、`-hp` header encryption | URL-backed old `.r00` / new `.partN.rar` |
| RAR5 | stored、compression version 0 の LZ、Delta/E8/E8E9/ARM、solid、上限付き SFX、file copy（`rar -oi` の参照。同一内容の先行 entry の本文を返す `.file`） | AES-256 per-file、`-hp` header encryption、HashMAC | URL-backed `.partN.rar`、暗号化 volume 対応 |
| LHA / LZH | level 0/1/2/3、`-lh0-`/`-lh1-`/`-lh4-`〜`-lh7-`/`-lhx-`/`-lz4-`/`-lz5-`/`-lzs-`/`-pm0-`、LHArk `-lh7-`、上限付き SFX | なし | なし、全 member は独立 (`solidGroup == -1`) |
| StuffIt / `.sit` | classic・StuffIt 5、method 0/1/2/3/5/6/8/13/14/15、MacBinary / AppleSingle / BinHex 4 の一段 unwrap | StuffIt 5 RC4、classic 改変 DES（wrapper の MKey が必要） | data/resource fork は別 entry。`.sea` は先頭署名、MZ `.exe` は header 検証付き走査。classic の分割セット（100 byte header の part、URL open で同じ directory の兄弟 part を番号順に連結し、resource fork も復元。既定上限 128 巻ちょうどの完結セットを受理）。AppleDouble sidecar は非対応 |
| StuffIt X / `.sitx` | `StuffIt!`、未圧縮、Brimstone、Cyanide、Darkhorse、Deflate（window 10〜25）、Blend（全 4 submethod）、RC4-stored、Iron（BWT/ST4）、JPEG（mode 0/1/2） | AES / Blowfish / DES の CFB、RC4、複数暗号層、暗号化 catalog | solid・data/resource fork、MZ `.exe`。English（辞書組み込み）と x86 前処理。[下記の制約](#stuffit-classicstuffit-5stuffit-x)を参照 |

> **Supported formats**
>
> The table above lists every supported format. Its columns are, in order:
> Format / Container and compression methods / Encryption / Multi-volume and multi-stream.
> Most cells are method names, version numbers and identifiers that read the same in English;
> `なし` means none. The cells that carry Japanese prose read as follows.
>
> - **ISO 9660 / BIN+CUE**: PVD, Joliet, Rock Ridge (NM/CE/PX/SL/TF/ZF, deep hierarchies), multi-extent, stored,
>   and zisofs (ZF version 1 / `pz`, zlib blocks of 32–128 KiB, zero-filled blocks). A hybrid with UDF
>   prefers the UDF tree. Raw-sector images (ECMA-130 2352-byte sectors in Mode 1 or Mode 2 with an
>   8-byte sub-header, 2448-byte sectors with sub-channel data, and 2336-byte sectors; `.bin`, `.img`,
>   `.mdf`) open as the same `iso` / `udf`, and a `.cue` URL follows its data track's image. First
>   session only; EDC / ECC are not verified.
> - **MacBinary / AppleSingle / BinHex 4**: a wrapper whose payload is not a StuffIt archive is
>   published as a one-file archive: the data fork (entry 0) and the resource fork
>   (`name/..namedfork/rsrc`). Name, type / creator, Finder flags and dates (MacBinary since 1904,
>   AppleSingle's File Dates Info) come from the header. A StuffIt payload still opens as StuffIt. Only
>   one layer is removed (a ZIP inside a MacBinary is published as a file).
> - **WIM**: Windows Imaging 1.13 (`MSWIM`), stored / XPRESS ([MS-XCA] LZ77+Huffman) / LZX (the WIM
>   variant: 32 KiB chunks, E8 translation size 12,000,000), several images (prefixed `1/`, `2/`),
>   alternate data streams (`name:stream`), hard-link groups, symbolic-link and junction reparse points
>   ([MS-FSCC]), and per-resource SHA-1 verification. Split `.swm` sets expose only the first part's
>   metadata (resources in other parts are `unsupportedMethod`); solid / ESD (LZMS, version 0.14) is unsupported.
> - **Compound File** (`.msi`, `.doc`, `.xls`, `.ppt`, `.msg`): [MS-CFB] version 3 (512-byte sectors) and 4
>   (4096-byte sectors, 64-bit sizes), FAT / DIFAT (including DIFAT sectors beyond the header) / mini FAT
>   and mini stream; storages are directories and streams are stored files. Storage CLSIDs
>   (`formatSpecific["clsid"]`) and modification times are exposed, and a name that starts with a control
>   character is spelled like 7-Zip's `[5]SummaryInformation`. Windows Installer's packed stream names
>   (`!_Tables`, `setup.cab`, …) are unpacked with the same mapping 7-Zip uses, keeping the stored UTF-16
>   name in `formatSpecific["storedName"]`. Cabinets inside MSI and Office property sets are not interpreted.
> - **CHM**: HTML Help (ITSF version 3, the PMGL chunk chain of the ITSP directory), stored files of section 0
>   and the LZX `MSCompressed` section (windows of 32 KiB–2 MiB, a full LZX reset at every reset interval,
>   the 0x8000-byte block reset table, E8 translation). The user files under `/` and the `#SYSTEM`-style
>   format files are listed, the `::DataSpace/…` internals are not (as in 7-Zip). The most recent reset
>   interval is cached so files can be read in any order. Version 2 headers are parsed as Russotto
>   describes them but no sample exists.
> - **ARJ** (`.arj`, DOS `.exe` self-extractors): main and local file headers (versions 1–11, ARJ32),
>   stored (0) and methods 1–3 (the LHA lh6 LZ77 + static Huffman stream with a 26 KB window),
>   directories, DOS `\` and PATHSYM names with archive-wide encoding detection (CP932 …), comments,
>   DOS dates, CRC-32, the technote's header search after an MZ stub, and methods 8 / 9 (no data).
>   Method 4 (compressed fastest), garbled (encrypted) files and continued multi-volume members are
>   listed but read as `unsupportedMethod`; extended headers are skipped.
> - **Apple Disk Image** (`.dmg`, `.img`): UDIF (koly trailer + blkx tables with zero-fill / raw / zlib /
>   bzip2 / lzfse / lzma-in-xz chunks, the last four chunks cached) and raw HFS+ images (GPT, Apple
>   Partition Map or a bare volume). The HFS Plus / HFSX catalog is listed with files, directories,
>   symbolic links, hard links (resolved to the indirect node's content), resource forks as
>   `name/..namedfork/rsrc`, extents overflow, modification dates, permissions and type / creator; an ISO
>   9660 / UDF volume inside UDIF goes to those readers. ADC (UDCO) chunks and APFS are `unsupportedMethod`;
>   decmpfs-compressed files (UF_COMPRESSED) support types 1 / 3 / 4 / 7 / 8 / 9 / 10 / 11 / 12
>   (stored / zlib / LZVN / LZFSE, inline xattrs or 64 KiB resource-fork chunks). Type 1 stores raw bytes;
>   inline type 9 requires a `0xCC` prefix. Types 3 / 4 / 7 / 8 / 9 also extract byte-exactly with 7-Zip 26.03.
>   Types 5 / 13 / 14,
>   unknown types and fork-stored attributes are listed but read as `unsupportedMethod`;
>   only the first HFS+ volume of a multi-volume image is listed, and the extractor keeps refusing absolute
>   symbolic-link targets such as the `/Applications` link of application images.
> - **UDF**: ECMA-167 / OSTA UDF 1.02–2.60, block sizes 512–4096, type 1 / sparable (sparing table) /
>   virtual (VAT, both the 1.50 and the 2.x layout) / metadata partitions (falling back to the mirror
>   file), file entries and extended file entries, inline data, multi-entry ICBs (strategy 4; strategy
>   4096 indirect entries are implemented from the specification but unverified because macOS's driver
>   rejects them), symbolic
>   links (path components and hdiutil's raw paths), and the `*UDF Macintosh Resource Fork` named
>   stream exposed as `..namedfork/rsrc`. Single volume; tag checksums, CRCs and locations are verified.
> - **ar / .deb**: BSD long names, the SysV/GNU string table, stored. The symbol table is exposed;
>   only the `//` long-name table is hidden; a thin archive is explicitly rejected.
> - **cpio**: bin (both byte orders), odc, newc, crc, hpbin, hpodc, stored. Concatenated archives,
>   symbolic links, and hard links keeping their declared size. `.cpgz` / `.cpio.<codec>` (gz / bz2 /
>   xz / zst / lz4 / lzma / lz / br / Z) and pbzx payloads are expanded and listed with CpioReader.
> - **xar / .pkg**: TOC XML through a subset pull parser; a zlib, bzip2, lzma, xz or stored heap;
>   nested directories; symbolic links; hard links; `<name enctype="base64">`; the macOS flat
>   package. No multi-volume. The TOC checksum and `<extracted-checksum>` are verified, and a
>   `<file>` inside a `<subdoc>` never becomes an entry.
> - **CAB**: CFHEADER / CFFOLDER / CFFILE / CFDATA, None, MSZIP and LZX (15–21 bit windows and
>   history across CFDATA blocks), the reserved areas, and UTF-8 names (attribs 0x80). Even when the multi-cabinet
>   flags are set, the files held in this cabinet are read normally and only a file that actually
>   spans cabinets is rejected. Quantum can be listed only. A cabinet behind a bounded PE / Mach-O
>   self-extractor prefix is found by the same signature scan as ZIP / RAR / 7z.
> - **RPM**: the lead, the signature header and the main header; the cpio entries of the payload are
>   exposed directly, including stripped `07070X` (files over 4 GB since rpm 4.12; the default in rpm 6).
>   Names, sizes and modes come from header tags. The highest non-ghost file index in each hard-link set
>   carries the data; other members have zero bytes and ghosts are omitted. SHA-256 file digests are
>   checked on complete reads of members carrying data. gzip, bzip2, xz, lzma, zstd and stored payloads
>   share the same reader; the codec is decided by the magic at the start of the payload.
> - **tar**: POSIX/ustar, pax, GNU long name and link, stored members, and GNU sparse entries
>   (old GNU typeflag `S`, pax 0.0 / 0.1 / 1.0; holes are zero-filled and the real size is published). The `._name`
>   AppleDouble sidecars written by macOS tar are merged into resource forks by default. No volume splitting.
> - **gzip**: RFC 1952 with FTEXT/FHCRC/FEXTRA/FNAME/FCOMMENT, DEFLATE, CRC32 and ISIZE.
>   Concatenated members are supported.
> - **bzip2, xz, UNIX compress (`.Z`)**: BZip2 block sizes 1 to 9; the XZ container with Apple
>   Compression's LZMA, footer and padding; LZW 9 to 16 bit with block mode. No encryption. bzip2
>   and xz support concatenated streams; `.Z` has none.
> - **zstd**: RFC 8878 streams (`.zst`, `.tar.zst`, `.tzst`), RPM payloads and ZIP method 20/93,
>   including concatenated/skippable frames and XXH64 checksum verification. Dictionaries are unsupported.
> - **LZ4 frame**: `.lz4` and `.tar.lz4`, independent/linked blocks, stored blocks,
>   XXH32 header/block/content checksums, concatenated/skippable frames, and legacy 8 MiB
>   blocks. External dictionaries are unsupported. Legacy frames have no checksum or declared size.
> - **LZMA_Alone (`.lzma` / `.tlz`)**: a 13-byte header plus raw LZMA. Because the format has no magic, it is
>   accepted only when the extension, the properties, the dictionary size and the first byte of the
>   range coder all agree, and detection is left until last.
> - **pbzx**: `pbzx` + chunk size, then per chunk an unpacked size, a stored length and an XZ stream or
>   raw bytes (the `Payload` of macOS `pkgbuild --compression latest` packages and OTA updates). A cpio
>   result is listed as cpio; anything else is a single stream. Every chunk's declared size is verified.
> - **lzip (`.lz` / `.tar.lz`)**: `LZIP`, version 1, one coded dictionary-size byte, an LZMA-302eos stream
>   (lc=3 / lp=0 / pb=2, end marker) and a trailer of CRC-32, data size and member size. The member sizes
>   are walked backwards to index the file, so the expanded size is known at open. Multimember files are
>   supported; every member's CRC-32, data size and consumed stream length are verified, and trailing bytes
>   are `malformed`.
> - **brotli (`.br` / `.tar.br` / `.tbr`)**: RFC 7932 streams decoded by Apple Compression's
>   `COMPRESSION_BROTLI`. The RFC 9841 large-window header (WBITS 10–62) is parsed and the window is checked
>   against `maxDictionarySize`. The format has no magic, size or checksum, so it is accepted only when a
>   `.br` / `.tbr` name, a valid header and a trial decode of the first 64 KiB all agree, and detection is
>   left until last. One stream only; bytes after the end are `malformed`.
> - **Compressed tar**: `.tgz` / `.tar.gz`, `.tbz` / `.tbz2` / `.tar.bz2`, `.tar.lzma` / `.tlz`, `.txz` / `.tar.xz` and
>   `.tar.zst` / `.tzst`, `.tar.lz4`, `.tar.lz` (`.tlz` is resolved to LZMA_Alone or lzip by signature),
>   `.tar.br` / `.tbr` and `.taz` / `.tz` / `.tar.Z` are expanded and then listed with TarReader.
> - **ZIP / ZIP64**: stored (0), Shrink (1), Reduce (2-5), Implode (6), Deflate (8), Deflate64 (9), BZip2 (12), LZMA (14),
>   Zstandard (20/93), XZ (95), PPMd (98), the central directory, SFX, `.zip.001` byte splits and split ZIP sets (`.z01`…`.zip`, `.zx01`…`.zipx`)
>   are supported, including ZIP64 and more than 99 segments. Open the last or a numbered segment by URL.
>   The `__MACOSX/._name` AppleDouble sidecars of Finder / ditto are merged into resource forks by
>   default (`ReaderOptions.appleDoublePolicy`).
> - **7z**: the coder chain covers a folder in which a byte-consuming coder takes the output of
>   another coder as its input; Deflate64 (040109), the Zstandard coder 04F71101 written by 7-Zip ZS / NanaZip / libarchive,
>   Swap2/Swap4 byte-order filters, solid folders and a bounded Mach-O/PE SFX prefix are supported.
>   `.001` byte splits made with 7-Zip `-v`, solid and block splits are supported.
> - **RAR4 / RAR5**: LZ and PPMd of the listed unpack versions, the listed filters, solid mode, and
>   a bounded SFX prefix. Multi-volume works from URL-backed input, including encrypted volumes for
>   RAR5. RAR5 file copies (`rar -oi` references) are exposed as `.file` entries that return the
>   contents of the identical earlier entry.
> - **LHA / LZH**: header levels 0 to 3, the listed methods, the LHArk `-lh7-`, and a bounded SFX
>   prefix. No multi-volume; every member is independent (`solidGroup == -1`).
> - **StuffIt / `.sit`**: classic split sets (parts with a 100-byte header) are reassembled from sibling
>   parts in the same directory when opened by URL, restoring both the data fork and the resource fork
>   that classic encryption needs.

## StuffIt classic・StuffIt 5・StuffIt X

classic StuffIt の分割セット（各 part が署名 `B0 56` の 100 byte header を持つ）は、URL で開いた part の
名前に含まれる part 番号の桁列を差し替えて同じ directory の兄弟（`name.sit.1` / `name.1.sit` /
`name.sit.01` など）を 1 から順に集め、header を外して連結した [0, R) を resource fork、[R, R+D) を
data fork として通常の StuffIt reader に渡します。どの part から開いても同じ結果で、`reopen()` は
保持した part の handle を使います。Data からは、単独の part が R+D を覆う場合だけ開けます。
`ReadLimits.maxVolumeCount` は既定 128 巻で、上限ちょうどの完結セットも受理します。次の part が
実在するときに上限超過を報告し、上限 1 なら完結した `name.sit.1` を URL から開けます。

StuffIt の `ArchiveFormat` は classic / StuffIt 5 とも `.stuffIt` (`"sit"`) です。
`formatSpecific["container"]` が `classic` / `stuffit5` を示し、`macType`・`macCreator`・
`finderFlags`・`fork` を保持します。resource fork は `<名前>/..namedfork/rsrc` として公開します。
classic / StuffIt 5 も `ArchiveEntry.name` は親フォルダを含む完全な相対パスです。
classic / StuffIt 5 で書庫の名前判定が Shift_JIS の場合、CP932 で読めない個別名だけ
MacJapanese で再試行します。`nameEncoding` は `.shiftJIS` のままです。
wrapper 自身の resource fork も reader が保持し、`SitC` または StuffIt 5 の書庫コメントを
最初の entry の `formatSpecific["comment"]` に公開します。名前は `EncodingPolicy` に従い、
未宣言の旧 Mac 名には MacRoman を既定候補として使います。

password は UTF-8 bytes を使います。classic の暗号化 fork は wrapper 自身の `MKey` が必要で、
resource fork のない素の `.sit` / `.sea` は
`unsupportedMethod("StuffIt encryption without archive resource fork")` を返します。
復号に必要な情報があれば、password 未設定は `passwordRequired`、検証値の不一致は
`wrongPassword` です。復号後も `isEncrypted` は変わらず、展開後の CRC を検証します。
classic の 8 バイト password は資料の 2 block 派生を優先し、CC0 の 4.5 書庫で確認した
1 block 派生も MKey 検証付きで扱います。詳細は
[slice 2 検証記録](verification/2026-09-13-stuffit-slice2.md) を参照してください。

StuffIt X は `.stuffItX` (`"sitx"`) として署名で判別し、同じ wrapper を一段だけ剥がします。
名前は `EncodingPolicy` に従い、有効な UTF-8 を既定候補とします。catalog の key 10 の整列、
type 9 に続く書庫コメント、kind 3 の補助 stream の実長を扱います。
solid stream は前方を読み捨て、後方 seek で再起動し、全体の終端で CRC-32 または MD5 を検証します。
途中の fork の読み取りだけでは stream 全体の checksum は確定しません。

StuffIt X の password は正規化しない UTF-8 bytes です。AES（16/24/32 バイト鍵）、
Blowfish（5〜56）、DES（8）、RC4（1〜1,024）を扱い、複数層は合計鍵長（最大 65,536）で
一度派生して記録順に分割し、逆順に復号します。鍵は後方 seek 時も再利用します。
データ暗号化は password なしで列挙でき、stream 取得時に `passwordRequired`、
verifier 不一致は `wrongPassword` です。catalog が暗号化されている場合は open 時に
password が必要で、未設定なら `PasswordProvider` を呼びます。

MZ `.exe` は `maximumSFXScanSize`（既定・上限 1 MiB）内の候補を位置順に検証し、
最初に header 検証を通る classic / StuffIt 5 / StuffIt X を開きます。
ファイル URL では自動、Data / 任意 ByteSource では `scanForSFXInData: true` で有効です。
classic の暗号化 `.exe` は書庫 resource fork がないため `unsupportedMethod` です。
実行形式 stub 自体を実行することはありません。

Brimstone (0) の catalog と data、Iron (6)、English (0) / x86 (2) 前処理を扱います。
English 辞書は本体に組み込み、初回展開時に SHA-256 を検査します。resource bundle や追加ダウンロードは不要です。
前処理は解凍後の要素全体に適用し、checksum 検証と fork 分割へ渡します。
Iron は native の固定頻度上限 `(64,64,256)`、x86 は候補に 6 バイトを要求する native 末尾規則を採用します。
Cyanide の tail-model byte は n=0〜255 を受理し、実際に復号した rank が 256 以上のときだけ `malformed` とします。
JPEG (7) は mode 0 の保存、mode 1 の色 baseline、mode 2 の baseline / progressive を扱い、
元の JPEG バイト列を復元します。restart、padding、tail、scan 間の表更新も保持します。
出力・入力は `maxEntrySize`、係数ブロック数は `ReadLimits.maxJPEGBlocks`（既定 2,097,152）で制限します。
24 MP の 4:4:4 と 48 MP の 4:2:0 はそれぞれ 1,125,000 ブロックで、既定の範囲に収まります。
progressive の量子化係数 plane は最大 512 MiB です。
entry 読み取り時の入力不足は `truncated`、構造の破損は `malformed`、未対応 profile は `unsupportedMethod` になります。
Iron version 1 (33)、その他の前処理、Root 暗号、recovery、segment、base-N transport は後続対応です。
単一の最終出力 digest と JPEG の key-6 入力 digest を検証します。後者は単層暗号にも対応します。
反復 compression / preprocessing・複数 digest scope・JPEG の多層暗号中の key-6 digest は `unsupportedMethod` とします。
CC0 の対象 20 書庫と、SMSSenderPro3osx.sitx の全 95 entry の名前・長さ・SHA-256 が支給期待値と一致しました。
旧 vector と native 規則の差、支給比較スクリプトのオラクル範囲の差は
[slice 4 検証記録](verification/2026-09-13-stuffit-slice4.md) に記載しています。

## LHA のディレクトリと MacLHA

LHA の directory 属性は method だけでなく末尾 separator と MS-DOS directory bit からも判定します。
このため OS/2 の extended-attribute payload を持つ subdirectory も子 entry の親として扱えます。
先頭 slash と drive prefix は除いて相対名にしますが、`..` は解決せず、展開層で従来どおり
拒否します。古い writer が filename field の NUL より後ろへ付けた metadata は pathname に含めません。
level 0〜3 の 0xFF と、文字コード復号後の backslash は directory separator として扱い、
CP932 の二バイト文字の一部である 0x5C は保持します。level-0 Unix `U` 拡張の
mtime / permissions / uid / gid も公開します。

MacLHA の Macintosh OS marker を持つ member は、MacBinary / MacBinary II standard proposals に基づいて
復号後の header が有効と確認できた場合だけ、data fork を `stream(_:)` / `read(_:)` に公開します。
LHA CRC16 は padding と resource fork を含む MacBinary 全体と compatible trailing extension について検証し、
MacBinary ではない member はそのまま返します。公開 `uncompressedSize` は互換性のため LHA header が
宣言した envelope size を保持します。

> **LHA directories and MacLHA**
>
> LHA directory status is decided not only by the method but also by a trailing separator and the
> MS-DOS directory bit. A subdirectory carrying an OS/2 extended-attribute payload can therefore act
> as the parent of its child entries.
> A leading slash and a drive prefix are removed to make the name relative, but `..` is not resolved
> and is rejected by the extraction layer as before. Metadata that old writers appended after the NUL
> in the filename field is not included in the pathname.
> The 0xFF byte in levels 0 to 3, and a backslash after character-encoding decoding, are treated as
> directory separators, while 0x5C as the trail byte of a two-byte CP932 character is preserved.
> The mtime, permissions, uid and gid of the level-0 Unix `U` extension are also exposed.
>
> For a member carrying the MacLHA Macintosh OS marker, the data fork is exposed through
> `stream(_:)` and `read(_:)` only when the decoded header is confirmed valid against the MacBinary
> and MacBinary II standard proposals. The LHA CRC16 is verified over the whole MacBinary envelope,
> including padding and the resource fork, and over any compatible trailing extension; a member that
> is not MacBinary is returned as is. The published `uncompressedSize` keeps the envelope size
> declared by the LHA header, for compatibility.

## RAR の分割巻

RAR4 / RAR5 の URL-backed multi-volume は、最初の volume と同じ directory の deterministic
sibling 名だけを、保持した directory descriptor から symlink を追わず regular file として開き、
既定 128 volume の `ReadLimits.maxVolumeCount` で制限します。RAR4 は old / new numbering、
RAR5 は `.partN.rar` と暗号化 data / header の継続に対応します。`reopen()` は検証済みの全
volume handle を共有し、path を再解決しません。Data / 任意 `ByteSource` は sibling volume を
一意に特定できないため、未解決の分割 entry を読むと
`unsupportedMethod("multi-volume from Data")` を返します。

> **Multi-volume RAR**
>
> URL-backed multi-volume RAR4 and RAR5 open only deterministic sibling names in the same directory
> as the first volume. They are opened as regular files from a retained directory descriptor without
> following symbolic links, and are bounded by `ReadLimits.maxVolumeCount`, which defaults to 128
> volumes. RAR4 supports old and new numbering; RAR5 supports `.partN.rar` and the continuation of
> encrypted data and headers. `reopen()` shares all verified volume handles and does not re-resolve
> paths. `Data` and custom `ByteSource` inputs cannot identify sibling volumes uniquely, so reading
> an unresolved split entry returns `unsupportedMethod("multi-volume from Data")`.

## バイト分割セット

`.7z.001` / `.zip.001` などのバイト分割セットは、`ArchiveReader.open(url:)` と
`FormatDetector.detect(url:)` が形式検出の前に連結します。空でない名前に続く 3 桁以上の
ASCII 数字で値 1 の拡張子から開始し、桁幅を保持して `.999` の次は `.1000` へ進みます。
欠番で探索を停止し、7z の末尾巻・中間巻の欠落は `truncated` になります。余分な末尾巻は
末尾ゴミとして許容します（ZIP は末尾探索の 1 MiB 上限内）。既定上限は同じ
`ReadLimits.maxVolumeCount = 128` で、探索可能な先頭巻では 0 以下を拒否し、1 以上は
実在する巻数が上限を超えると `limitExceeded("split volume count")` を返します。
兄弟巻は保持した親 descriptor から symlink を追わず regular file として開きます。
先頭巻が symlink または identity 不一致なら兄弟探索をせず単独扱いにし、兄弟がない
単巻 `.001` でも `.tar.gz` 等の拡張子ヒントを使います。`reopen()` は全巻の削除後も
保持済み source を使います。`.002` 等から先頭へは戻らず、Data / 任意 `ByteSource` では
兄弟を探索しません。分割セットの `rawRecord(of:)` は `nil` です。連結した RAR に volume
フラグがある場合も一覧と完結 entry は読めますが、RAR 独自の続巻探索はせず、未解決の
分割 entry は `unsupportedMethod("multi-volume from Data")` になります。

> **Byte-split volume sets**
>
> `ArchiveReader.open(url:)` and `FormatDetector.detect(url:)` concatenate `.7z.001`, `.zip.001`
> and other byte splits before format detection. A nonempty stem and an ASCII numeric suffix of
> at least three digits with value 1 are required. Width is preserved, growing from `.999` to
> `.1000`. Discovery stops at the first gap; missing 7z volumes produce `truncated`. Stale trailing
> volumes are tolerated (within ZIP's 1 MiB end-search bound). `ReadLimits.maxVolumeCount` defaults
> to 128; discoverable sets reject zero or negative limits, and an existing volume beyond a positive
> limit produces `limitExceeded("split volume count")`. Siblings must be regular files opened
> without following symlinks under the retained directory descriptor. A symlink or changed first
> volume is treated as a single file without sibling discovery. Even a single `.001` keeps extension
> hints such as `.tar.gz`. `reopen()` retains the sources after all paths are deleted. Continuations
> such as `.002` do not rewind; Data/custom-source opens do not discover siblings. `rawRecord(of:)`
> returns `nil` for concatenated sets. A byte-split RAR bearing volume flags can list and read complete
> entries, but unresolved RAR split entries return `unsupportedMethod("multi-volume from Data")`.

## ZIP の日時と暗号化エラー

ZIP の DOS 日時にはタイムゾーン情報がないため、現在のローカルタイムゾーンとして解釈します。
Extended timestamp と NTFS timestamp は UTC の時刻として扱います。ZIP のローカルヘッダを
open 時にすべて検証したい場合は `ReaderOptions(lazyLocalHeaders: false)` を指定してください。

完全な ZipCrypto entry は 1 byte のヘッダ検査を通過した後の CRC 不一致・decoder の破損／入力不足を `wrongPassword` として報告するため、暗号化 stream 自体の破損も誤ったパスワードと判定される場合がありますが、WinZip AES は HMAC による区別を維持します。

7zAES には独立した認証 tag がないため、KaitoKit は最初に復号した stream の CRC 不一致、
または復号後の coder 構造が不正な場合を `wrongPassword` と判定します。このため、暗号化
stream 自体の破損も `wrongPassword` として報告される場合があります。KDF の計算量上限は
`ReaderOptions.maxSevenZipAESCyclesPower` で設定できます。

> **ZIP timestamps and 7zAES**
>
> A ZIP DOS timestamp carries no timezone, so it is interpreted in the current local timezone.
> Extended timestamps and NTFS timestamps are treated as UTC. To validate every ZIP local header at
> open time, pass `ReaderOptions(lazyLocalHeaders: false)`.
>
> For complete ZipCrypto entries, CRC mismatches and malformed or truncated decoder output after
> the one-byte header check passes are reported as `wrongPassword`, so corruption of the encrypted
> stream may also be reported as a wrong password, while WinZip AES keeps its HMAC-based distinction.
>
> 7zAES has no independent authentication tag, so KaitoKit reports `wrongPassword` when the CRC of
> the first decrypted stream does not match, or when the decrypted coder structure is invalid. As a
> consequence, corruption of the encrypted stream itself may also be reported as `wrongPassword`.
> The KDF work limit is set by `ReaderOptions.maxSevenZipAESCyclesPower`.

## XZ の事前検査と空の LHA

XZ は全 block と連結 stream の辞書を `maxDictionarySize` で制限します。
AES暗号化されたZIP XZは、認証済み圧縮入力を最大4 MiB（`inMemorySingleFileLimit`がより小さければその値）まで
メモリに保持し、それ以上は作成直後unlinkする非公開一時ファイルへ送ります。これにより全blockの事前検査が
暗号文全体を繰り返し読み直すことを防ぎます。詳細は[ZIP追加検証](verification/2026-09-18-zip-methods.md)を参照。
空の LHA は正確な1 byteの終端と `.lha` / `.lzh` の名前 hint が必要です。
名前のない Data / ByteSource からは終端だけで形式を識別しません。
修正・全件検証は[リリース前横断検証](verification/2026-09-17-release-hardening.md)を参照。

> XZ checks every block and concatenated stream against `maxDictionarySize` before native decoding.
> AES-encrypted ZIP XZ stages its authenticated compressed input once, retaining at most the lesser
> of 4 MiB and `inMemorySingleFileLimit`; larger inputs use a private, immediately unlinked temporary
> file. This keeps preflight reads linear and requires temporary disk space for large encrypted members.
> An empty LHA requires exactly one terminator byte and a `.lha` / `.lzh` filename hint;
> an unnamed Data / ByteSource cannot identify it from that ambiguous byte alone.
