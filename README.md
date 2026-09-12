# KaitoKit (解凍Kit)

KaitoKit は macOS 向けの純 Swift 書庫読み取りフレームワークです。tar、ZIP / ZIP64、7z、
RAR4 / RAR5、LHA / LZH、StuffIt classic / StuffIt 5、ISO 9660、cpio、ar（.deb を含む）、xar（.pkg を含む）、CAB、RPM に加え、gzip、bzip2、xz、zstd、UNIX compress (`.Z`) と圧縮 tar を扱います。
書庫の検出から列挙、ストリーミング読み取り、展開までを一つのパイプラインとして提供します。

- 対象: macOS 26 以上、Swift 6、Apple Silicon / Intel
- 外部依存: なし。zlib、libbz2 など OS 同梱ライブラリだけを使用
- ライセンス: MIT。XADMaster / The Unarchiver のコードは実装へ取り込んでいません

> **KaitoKit (解凍Kit)**
>
> KaitoKit is a pure-Swift archive reading framework for macOS. It handles tar, ZIP / ZIP64, 7z,
> RAR4 / RAR5, LHA / LZH, StuffIt classic / StuffIt 5, ISO 9660, cpio, ar (including `.deb`), xar (including `.pkg`), CAB and RPM,
> plus gzip, bzip2, xz, zstd, UNIX compress (`.Z`) and compressed tar.
> Detection, listing, streaming reads and extraction are provided as one pipeline.
>
> - Requires macOS 26 or later, Swift 6, Apple Silicon or Intel.
> - No external dependencies. Only OS-bundled libraries such as zlib and libbz2 are used.
> - MIT licensed. No XADMaster or The Unarchiver code is incorporated into the implementation.

## SwiftPM

```swift
import Foundation
import KaitoKit

let archive = try ArchiveReader.open(url: URL(fileURLWithPath: "/tmp/book.tar"))
for entry in archive.entries {
    print(entry.index, entry.uncompressedSize ?? 0, entry.name)
    if entry.kind == .file {
        let contents = try archive.read(entry)
        print("read \(contents.count) bytes")
    }
}

let destination = URL(fileURLWithPath: "/tmp/unpacked", isDirectory: true)
for entry in archive.entries where entry.kind != .directory {
    _ = try archive.extract(entry, to: destination)
}
let directories = archive.entries.filter { $0.kind == .directory }.sorted {
    if $0.pathComponents.count != $1.pathComponents.count {
        return $0.pathComponents.count > $1.pathComponents.count
    }
    return $0.index < $1.index
}
for entry in directories {
    _ = try archive.extract(entry, to: destination)
}
```

ディレクトリは子を展開した後に深い順で処理すると、書庫内の最終パーミッションと
更新日時を保持できます。`kaito extract` もこの順序を使用します。
本文を持たない hard link は、同じ `ArchiveReader` で同じ出力ルートへ参照先を先に
展開した場合だけ作成されます。この provenance は出力ルートを切り替えるか `reopen()`
するとリセットされるため、上のように書庫順で展開してください。
展開中の出力ルートは呼出側が排他的に所有し、別スレッドや別プロセスから変更しないでください。

`ArchiveReader` はスレッドセーフではありません。並列展開では `reopen()` で同じ
`ByteSource` を共有する独立 reader を作ってください。既存 XADMaster 利用コード向けには
`KaitoKitCompat` の `KaitoArchive` と `XADArchive` typealias もあります。
自動判定が必要な未宣言名を持つ書庫では、`nameEncoding` から書庫全体に選択された
文字コードを取得できます。自動判定時にすべての名前が形式で宣言済みまたは
厳密に有効な UTF-8 なら `nil` です。

> **Swift Package Manager**
>
> Process directories after their children, deepest first, to preserve the final permissions and
> modification dates recorded in the archive. `kaito extract` uses the same order.
> A hard link with no body of its own is created only when the same `ArchiveReader` has already
> extracted its target into the same output root. That provenance is reset when you switch output
> roots or call `reopen()`, so extract in archive order as shown above.
> The caller owns the output root exclusively during extraction; do not modify it from another
> thread or process.
>
> `ArchiveReader` is not thread-safe. For parallel extraction, use `reopen()` to create independent
> readers that share the same `ByteSource`. For existing XADMaster call sites, `KaitoKitCompat`
> provides `KaitoArchive` and an `XADArchive` typealias.
> For archives whose names are undeclared and need automatic detection, `nameEncoding` reports the
> character encoding chosen for the whole archive. It is `nil` when every name is either declared by
> the format or strictly valid UTF-8.

## 対応状況

| 形式 | コンテナ・圧縮方式 | 暗号化 | multi-volume / multi-stream |
|---|---|---|---|
| ISO 9660 | PVD、Joliet、Rock Ridge（NM/CE/PX/SL/TF、深い階層）、multi-extent、stored | なし | 最初の session のみ |
| ar / .deb | BSD 長名、SysV/GNU 文字列表、stored | なし | symbol table を公開、長名表 `//` のみ非公開、thin archive は明示的に拒否 |
| cpio | bin（両 byte order）、odc、newc、crc、hpbin、hpodc、stored | なし | 連結書庫、symlink、宣言サイズどおりの hard link |
| xar / .pkg | TOC XML（部分集合 pull parser）、zlib / bzip2 / lzma / xz / stored の heap、入れ子ディレクトリ、symlink、hard link、`<name enctype="base64">`、macOS flat package | なし | なし。TOC checksum と `<extracted-checksum>` を検証、`<subdoc>` 内の `<file>` は entry にしない |
| CAB | CFHEADER / CFFOLDER / CFFILE / CFDATA、None / MSZIP / LZX（15〜21 bit の辞書、CFDATA をまたぐ履歴）、予約領域、UTF-8 名 (attribs 0x80) | なし | 多分割フラグがあっても手元の cabinet の file は読み、実際にまたぐ file だけ拒否。Quantum は一覧のみ |
| RPM | lead / signature header / main header、payload の cpio entry を直接公開、gzip / bzip2 / xz / lzma / zstd / stored payload | なし | codec は宣言 tag ではなく payload 先頭の magic で決定 |
| tar | POSIX/ustar、pax、GNU long name/link、stored member | なし | volume 分割なし |
| gzip | RFC 1952、FTEXT/FHCRC/FEXTRA/FNAME/FCOMMENT、DEFLATE、CRC32/ISIZE | なし | concatenated member 対応 |
| bzip2 | BZip2 block size 1〜9 | なし | concatenated stream 対応 |
| xz | XZ container、Apple Compression の LZMA、footer/padding | なし | concatenated stream 対応 |
| zstd | RFC 8878、`.zst` / `.tar.zst` / `.tzst`、RPM payload、ZIP method 93、XXH64 checksum。辞書は非対応 | なし | 連結 frame・skippable frame 対応 |
| UNIX compress (`.Z`) | LZW、9〜16 bit、block mode | なし | なし |
| LZMA_Alone (`.lzma`) | 13 byte header + raw LZMA。magic が無いため拡張子・properties・辞書サイズ・range coder 先頭 byte がすべて揃ったときだけ受理し、判定は最後に回す | なし | なし |
| 圧縮 tar | `.tgz` / `.tar.gz`、`.tbz2` / `.tar.bz2`、`.txz` / `.tar.xz`、`.tar.zst` / `.tzst`、`.tz` / `.tar.Z` を展開後に TarReader で列挙 | なし | なし |
| ZIP / ZIP64 | stored (0)、Deflate (8)、Deflate64 (9)、BZip2 (12)、LZMA (14)、Zstandard (93)、PPMd (98)、中央 directory、SFX | ZipCrypto、WinZip AES-128/192/256 (AE-1/AE-2) | `.zip.001`（7-Zip `-v` のバイト分割）対応。`.z01` など multi-disk / spanned は非対応 |
| 7z | Copy、LZMA1、LZMA2、PPMd7 var.H、Deflate、BZip2、Delta、BCJ (x86/ARM/ARMT/ARM64/PPC/SPARC/IA-64)、BCJ2、coder 連鎖 (byte を消費する coder が他 coder の出力を入力にする folder)、solid folder、上限付き Mach-O/PE SFX prefix | 7zAES-256、data/header encryption | `.001` 分割巻（7-Zip `-v`）、solid/block split 対応 |
| RAR4 | stored、unpack version 29 の LZ/PPMd-H、E8/E8E9/Itanium/Delta/RGB/Audio、solid、上限付き SFX | RAR3 AES-128 per-file、`-hp` header encryption | URL-backed old `.r00` / new `.partN.rar` |
| RAR5 | stored、compression version 0 の LZ、Delta/E8/E8E9/ARM、solid、上限付き SFX | AES-256 per-file、`-hp` header encryption、HashMAC | URL-backed `.partN.rar`、暗号化 volume 対応 |
| LHA / LZH | level 0/1/2/3、`-lh0-`/`-lh1-`/`-lh4-`〜`-lh7-`/`-lhx-`/`-lz4-`/`-lz5-`/`-lzs-`/`-pm0-`、LHArk `-lh7-`、上限付き SFX | なし | なし、全 member は独立 (`solidGroup == -1`) |
| StuffIt / `.sit` | classic・StuffIt 5、stored (0) / RLE90 (1) / LZW (2) / Huffman (3) / LZ+Huffman (13) / Arsenic (15)、MacBinary / AppleSingle / BinHex 4 の一段 unwrap | 暗号化 entry は列挙のみ | data/resource fork は別 entry。`.sea` は先頭署名で判定。`.sitx`・`.exe`・AppleDouble sidecar は非対応 |

> **Supported formats**
>
> The table above lists every supported format. Its columns are, in order:
> Format / Container and compression methods / Encryption / Multi-volume and multi-stream.
> Most cells are method names, version numbers and identifiers that read the same in English;
> `なし` means none. The cells that carry Japanese prose read as follows.
>
> - **ISO 9660**: PVD, Joliet, Rock Ridge (NM/CE/PX/SL/TF, deep hierarchies), multi-extent, stored.
>   First session only.
> - **ar / .deb**: BSD long names, the SysV/GNU string table, stored. The symbol table is exposed;
>   only the `//` long-name table is hidden; a thin archive is explicitly rejected.
> - **cpio**: bin (both byte orders), odc, newc, crc, hpbin, hpodc, stored. Concatenated archives,
>   symbolic links, and hard links keeping their declared size.
> - **xar / .pkg**: TOC XML through a subset pull parser; a zlib, bzip2, lzma, xz or stored heap;
>   nested directories; symbolic links; hard links; `<name enctype="base64">`; the macOS flat
>   package. No multi-volume. The TOC checksum and `<extracted-checksum>` are verified, and a
>   `<file>` inside a `<subdoc>` never becomes an entry.
> - **CAB**: CFHEADER / CFFOLDER / CFFILE / CFDATA, None, MSZIP and LZX (15–21 bit windows and
>   history across CFDATA blocks), the reserved areas, and UTF-8 names (attribs 0x80). Even when the multi-cabinet
>   flags are set, the files held in this cabinet are read normally and only a file that actually
>   spans cabinets is rejected. Quantum can be listed only.
> - **RPM**: the lead, the signature header and the main header; the cpio entries of the payload are
>   exposed directly; gzip, bzip2, xz, lzma, zstd and stored payloads. The codec is decided by the magic
>   at the start of the payload rather than by the declared tag.
> - **tar**: POSIX/ustar, pax, GNU long name and link, stored members. No volume splitting.
> - **gzip**: RFC 1952 with FTEXT/FHCRC/FEXTRA/FNAME/FCOMMENT, DEFLATE, CRC32 and ISIZE.
>   Concatenated members are supported.
> - **bzip2, xz, UNIX compress (`.Z`)**: BZip2 block sizes 1 to 9; the XZ container with Apple
>   Compression's LZMA, footer and padding; LZW 9 to 16 bit with block mode. No encryption. bzip2
>   and xz support concatenated streams; `.Z` has none.
> - **zstd**: RFC 8878 streams (`.zst`, `.tar.zst`, `.tzst`), RPM payloads and ZIP method 93,
>   including concatenated/skippable frames and XXH64 checksum verification. Dictionaries are unsupported.
> - **LZMA_Alone (`.lzma`)**: a 13-byte header plus raw LZMA. Because the format has no magic, it is
>   accepted only when the extension, the properties, the dictionary size and the first byte of the
>   range coder all agree, and detection is left until last.
> - **Compressed tar**: `.tgz` / `.tar.gz`, `.tbz2` / `.tar.bz2`, `.txz` / `.tar.xz` and
>   `.tar.zst` / `.tzst` and `.tz` / `.tar.Z` are expanded and then listed with TarReader.
> - **ZIP / ZIP64**: stored (0), Deflate (8), Deflate64 (9), BZip2 (12), LZMA (14), Zstandard (93), PPMd (98),
>   the central directory, SFX and `.zip.001` byte splits made with 7-Zip `-v` are supported; multi-disk and spanned archives such as `.z01` are not.
> - **7z**: the coder chain covers a folder in which a byte-consuming coder takes the output of
>   another coder as its input; solid folders and a bounded Mach-O/PE SFX prefix are supported.
>   `.001` byte splits made with 7-Zip `-v`, solid and block splits are supported.
> - **RAR4 / RAR5**: LZ and PPMd of the listed unpack versions, the listed filters, solid mode, and
>   a bounded SFX prefix. Multi-volume works from URL-backed input, including encrypted volumes for
>   RAR5.
> - **LHA / LZH**: header levels 0 to 3, the listed methods, the LHArk `-lh7-`, and a bounded SFX
>   prefix. No multi-volume; every member is independent (`solidGroup == -1`).

StuffIt の `ArchiveFormat` は classic / StuffIt 5 とも `.stuffIt` (`"sit"`) です。
`formatSpecific["container"]` が `classic` / `stuffit5` を示し、`macType`・`macCreator`・
`finderFlags`・`fork` を保持します。resource fork は `<名前>/..namedfork/rsrc` として公開します。
wrapper 自身の resource fork も reader が保持します。名前は `EncodingPolicy` に従い、
未宣言の旧 Mac 名には MacRoman を既定候補として使います。

名前は ZIP/RAR4/LHA/tar/gzip FNAME の undecorated bytes に対して archive-wide の UTF-8、CP932、
EUC-JP 判定を行い、format が宣言する Unicode 名を優先します。単一 file 形式の FNAME がない場合は
source file の拡張子を除いた名前を entry 名にします。

圧縮 tar の展開結果は `ReadLimits.inMemorySingleFileLimit` 以下なら memory、それより大きければ
直ちに unlink した一時 file descriptor に保持します。どちらも同じ `TarReader` API を公開します。

> **Names and compressed tar staging**
>
> Names are resolved by an archive-wide UTF-8, CP932 and EUC-JP detection over the undecorated bytes
> of ZIP, RAR4, LHA, tar and gzip FNAME, preferring any Unicode name the format declares. When a
> single-file format carries no FNAME, the entry name is the source file name with its extension
> removed.
>
> The expansion of a compressed tar is held in memory when it is at or below
> `ReadLimits.inMemorySingleFileLimit`, and otherwise in an immediately unlinked temporary file
> descriptor. Both paths expose the same `TarReader` API.

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

cooViewer の `book.lzh` は level 2 の `-lh0-` 4 member をすべて lhasa の black-box
出力と SHA-256 比較しています。`-lh5-` の literal / match / preset-window vector も、
hand-built archive を lhasa と KaitoKit の双方で展開して一致を確認しています。release の
`kaito bench book.lzh 9` は open 0.049 ms、合計 33,104 bytes の extract 0.189 ms でした。

RAR4 の `st1200-pts.rar` は 19 file 全件が RAR 7.23 の black-box 出力と一致し、
PPMd↔LZ 変換の 241,647,978-byte entry も一致しました。さらに RAR4 corpus 20 書庫では
47 regular file の byte count / SHA-256 と 5 symlink の名前 / target bytes が一致しました。
既知 password 集合では oracle を得られない暗号化 entry が 1 件あり、破損した
`seek_data_cursor0` 書庫は RAR 7.23 と KaitoKit の双方が拒否します。

> **Differential testing against reference tools**
>
> All four level-2 `-lh0-` members of cooViewer's `book.lzh` are compared by SHA-256 against the
> black-box output of lhasa. The `-lh5-` literal, match and preset-window vectors are also confirmed
> by extracting a hand-built archive with both lhasa and KaitoKit. A release build of
> `kaito bench book.lzh 9` measured an open of 0.049 ms and an extract of 33,104 bytes in 0.189 ms.
>
> For RAR4, all 19 files of `st1200-pts.rar` match the black-box output of RAR 7.23, including the
> 241,647,978-byte entry that exercises the PPMd/LZ transition. Across a 20-archive RAR4 corpus, the
> byte counts and SHA-256 of 47 regular files and the names and target bytes of 5 symlinks all match.
> One encrypted entry has no oracle under the known password set, and the damaged
> `seek_data_cursor0` archive is rejected by both RAR 7.23 and KaitoKit.

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

RAR5 archive header の KDF は、個々の `count` を
`ReaderOptions.maxRAR5KDFCountPower` (既定かつ上限 24) で制限します。さらに、header encryption
を使う全 volume を通した実際の派生処理を `ReadLimits.maxRAR5HeaderKDFWork` で累積します。
work は HMAC-SHA256 iteration 単位で、各 context を `2^count + 32` と数えます。既定値は
`4 * (2^24 + 32)`、つまり最大コストの `count = 24` context 4 件分です。同じ
`(password, salt, count)` context を複数 volume が
再利用すると key cache が使われ、一度だけ加算されます。異なる context は volume をまたいで
累積されます。

RAR5 のサイズ不明 entry は `uncompressedSize == nil` のまま、復号器の終端まで逐次
streaming します。`read(_:)` も宣言サイズを仮定せず、設定された上限内で段階的にバッファを
増やします。codec の辞書サイズ上限は `ReadLimits.maxDictionarySize` で設定し、既定値は
1 GiB です。

> **RAR5 key derivation and unknown sizes**
>
> The KDF for RAR5 archive headers bounds each individual `count` with
> `ReaderOptions.maxRAR5KDFCountPower`, whose default and maximum are both 24. On top of that,
> `ReadLimits.maxRAR5HeaderKDFWork` accumulates the derivations actually performed across every
> volume that uses header encryption. Work is measured in HMAC-SHA256 iterations, counting each
> context as `2^count + 32`. The default is `4 * (2^24 + 32)`, that is four contexts at the most
> expensive `count = 24`. When several volumes reuse the same `(password, salt, count)` context the
> key cache is used and the work is charged once. Different contexts accumulate across volumes.
>
> A RAR5 entry of unknown size keeps `uncompressedSize == nil` and is streamed incrementally to the
> decoder's end marker. `read(_:)` likewise assumes no declared size and grows its buffer in stages
> within the configured limits. The codec dictionary size limit is set by
> `ReadLimits.maxDictionarySize` and defaults to 1 GiB.

ZIP の DOS 日時にはタイムゾーン情報がないため、現在のローカルタイムゾーンとして解釈します。
Extended timestamp と NTFS timestamp は UTC の時刻として扱います。ZIP のローカルヘッダを
open 時にすべて検証したい場合は `ReaderOptions(lazyLocalHeaders: false)` を指定してください。

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
> 7zAES has no independent authentication tag, so KaitoKit reports `wrongPassword` when the CRC of
> the first decrypted stream does not match, or when the decrypted coder structure is invalid. As a
> consequence, corruption of the encrypted stream itself may also be reported as `wrongPassword`.
> The KDF work limit is set by `ReaderOptions.maxSevenZipAESCyclesPower`.

## 既知の制限

- ISO は Rock Ridge（NM あり）> Joliet > PVD の順で名前の木を選びます。UDF、raw sector image、
  後続 session、interleaved / sparse / zisofs の内容展開は未対応です。
- cpio は PWB / newcx、HP-UX device number の解釈、device node の再作成に対応しません。
  hard link の 0-byte placeholder は内容を補完しません。圧縮 cpio の自動連鎖は対象外です。
- CAB は None / MSZIP / LZX を展開します。Quantum は一覧できますが、読み取り時に
  `unsupportedMethod` になります。複数 cabinet にまたがる file も同様です。
- RPM は rpm 6 の簡略 cpio (`07070X`)、drpm、cpio でない payload を展開せず、
  圧縮済み payload を 1 entry として公開します。
- ARJ、ACE、StuffIt X (`.sitx`) は未対応です。StuffIt の method 4〜12・14 と暗号化 fork は一覧取得後、読み取り時に `unsupportedMethod` を返します。
- ZIP は multi-disk/spanned と method 95 (xz)、96 (JPEG) を扱いません。
- zstd の外部辞書は非対応です。Dictionary_ID が非零なら `unsupportedMethod` になります。
- 7z は zstd method と RISC-V filter (method 0x0B) を扱いません。
- RAR4 は unpack version 15/20/26、custom VM、dictionary size が変わる solid 構成、SFX と multi-volume の組合せを
  扱いません。RAR5 は compression version 1、file-copy redirection、SFX と multi-volume の組合せ、
  サイズ不明の暗号化 stored entry を扱いません。
- LHA は `-pm1-` / `-pm2-` / `-lh2-` / `-lh3-` を一覧できますが、読み取り時に
  `unsupportedMethod` になります。resource fork は separate entry として公開しません。
- XZ は Apple Compression が扱う XZ container が対象で、同 liblzma が知らない RISC-V filter 付き
  stream は読めません。raw `.lzma` (LZMA_Alone) は `.lzma` 拡張子付きのときだけ対象です。gzip/bzip2/xz の
  concatenated stream は一つの entry として連結した出力を返します。
- gzip/bzip2/xz/`.Z` の出力サイズは読み終えるまで不明です。modern API では `nil`、compat API では
  `entryHasSize == false` / `Int64.max` になります。
- 圧縮 tar の判定には URL の拡張子 hint を使います。filename を持たない Data/任意 `ByteSource` は
  単一 file stream として開きます。
- 組込み cancellation token は未提供です。incremental 処理は caller が `EntryStream` の read loop を
  終了して制御します。
- 破損書庫の救済は既定で無効です。`ReaderOptions.recoverDamagedArchives = true` にすると、
  ZIP（中央ディレクトリを失ったもの）・tar・LHA・RAR5 から読める entry を取り出せます。救済対象は
  「EOCD が見つからない ZIP」であり、EOCD はあるが中央ディレクトリが壊れている ZIP は
  従来どおり `malformed` です。7z はヘッダが末尾にあるため切り詰められた書庫を救済できません。
  切れた entry は `ArchiveEntry.isIncomplete` が `true` になり、**CRC-32 / WinZip AES の HMAC /
  MacBinary の CRC-16 をいずれも検証しません**。暗号化 entry から救済した byte は認証されて
  いないため、信頼できない入力として扱ってください（password verifier は救済時も働くので、
  誤ったパスワードは従来どおり `wrongPassword` になります）。完全な entry と健全な書庫の
  読み取り結果は、この設定を有効にしても変わりません。
- RAR5 の救済には意図的な制限が 2 つあります。後続巻が欠けた multi-volume 書庫は救済せず
  従来どおり失敗します（次巻へまたがる entry を「完全」と偽らないため）。solid 群で切れた
  member は `isIncomplete` として一覧に出ますが、読むと `truncated` になります（復号状態が
  後続 member と連続するため）。なお暗号化された不完全 RAR5 entry は、認証されない byte を
  返さず何も返しません。

> **Known limitations**
>
> - ISO selects its name tree in the order Rock Ridge (with NM) > Joliet > PVD. UDF, raw sector
>   images, later sessions, and interleaved, sparse or zisofs content expansion are unsupported.
> - cpio does not support PWB or newcx, HP-UX device number interpretation, or recreating device
>   nodes. A 0-byte hard-link placeholder is not filled in with its target's content. Automatic
>   chaining of compressed cpio is out of scope.
> - CAB extracts None, MSZIP and LZX. Quantum can be listed but fails with `unsupportedMethod`
>   when read, as does a file that spans several cabinets.
> - RPM does not expand the simplified rpm 6 cpio (`07070X`), drpm, or a payload
>   that is not cpio; it exposes the compressed payload as a single entry instead.
> - ARJ, ACE and StuffIt X (`.sitx`) are unsupported. StuffIt methods 4–12 and 14, and encrypted forks, can be listed but throw `unsupportedMethod` when read.
> - ZIP does not handle multi-disk or spanned archives, nor methods 95 (xz)
>   and 96 (JPEG).
> - External zstd dictionaries are unsupported; a nonzero Dictionary_ID produces `unsupportedMethod`.
> - 7z does not handle the zstd method or the RISC-V filter (method 0x0B).
> - RAR4 does not handle unpack versions 15, 20 and 26, the custom VM, solid configurations whose
>   dictionary size changes, or SFX combined with multi-volume. RAR5 does not handle compression
>   version 1, file-copy redirection, SFX combined with multi-volume, or an encrypted stored entry
>   of unknown size.
> - LHA can list `-pm1-`, `-pm2-`, `-lh2-` and `-lh3-` but fails with `unsupportedMethod` when
>   reading them. Resource forks are not exposed as separate entries.
> - XZ covers the XZ container that Apple Compression handles; a stream carrying a RISC-V filter that
>   its liblzma does not know cannot be read. Raw `.lzma` (LZMA_Alone) is covered only with a
>   `.lzma` extension. A concatenated gzip, bzip2 or xz stream is returned as one entry whose output
>   is the concatenation.
> - The output size of gzip, bzip2, xz and `.Z` is unknown until the read completes. The modern API
>   reports `nil`; the compat API reports `entryHasSize == false` and `Int64.max`.
> - Compressed tar detection uses the extension hint of the URL. A `Data` or custom `ByteSource`
>   with no filename is opened as a single-file stream.
> - No built-in cancellation token is provided. Incremental work is controlled by the caller ending
>   the `EntryStream` read loop.
> - Recovery of damaged archives is disabled by default. Setting
>   `ReaderOptions.recoverDamagedArchives = true` recovers the readable entries of ZIP (with a lost
>   central directory), tar, LHA and RAR5. Recovery applies to a ZIP whose EOCD cannot be found; a
>   ZIP that has an EOCD but a corrupt central directory is still `malformed`. 7z keeps its header at
>   the end, so a truncated 7z archive cannot be recovered. A truncated entry sets
>   `ArchiveEntry.isIncomplete` to `true` and **verifies none of CRC-32, the WinZip AES HMAC, or the
>   MacBinary CRC-16**. Bytes recovered from an encrypted entry are unauthenticated, so treat them as
>   untrusted input. The password verifier still runs during recovery, so a wrong password is still
>   reported as `wrongPassword`. Results for complete entries and undamaged archives are unchanged by
>   this setting.
> - RAR5 recovery has two deliberate limits. A multi-volume archive missing a later volume is not
>   recovered and fails as before, so that an entry continuing into the next volume is never
>   presented as complete. A truncated member of a solid group is listed as `isIncomplete` but
>   returns `truncated` when read, because its decoder state is continuous with the following
>   members. An incomplete encrypted RAR5 entry returns nothing at all rather than unauthenticated
>   bytes.

## 組み込みの注意

`ArchiveReader` と `EntryStream` は thread-safe ではありません。一つの instance の操作は actor や
serial queue で直列化し、並列展開には `reopen()` で作った独立 reader を使ってください。同じ
`solidGroup >= 0` の entry は同じ worker へ割り当て、`solidGroup == -1` は entry 単位で並列化できます。

`ReadLimits` は `maxEntrySize`、`maxTotalUncompressedSize`、`maxInMemorySize`、
`inMemorySingleFileLimit`、entry/metadata/path/dictionary/volume 上限などをまとめます。利用する corpus と
端末の memory budget に合わせて open 前に設定してください。`read(_:)` より大きい entry は
`EntryStream` で処理し、最後の 0 または error まで読み切って CRC と stream footer を確定します。

`Data(contentsOf:options:.mappedIfSafe)` は、呼出中に内容が変わらないローカルの単一 file で使います。
RAR multi-volume は sibling file を解決できる `ArchiveReader.open(url:)` を使い、nested archive のように
既に memory 上にある bytes は `open(data:)` を使います。SFX prefix scan は URL open で有効、Data と
任意 `ByteSource` では `ReaderOptions.scanForSFXInData` が既定 `false` です。

展開先 root は処理中に caller が排他的に所有し、別 thread/process から名前や directory を変更しないで
ください。directory entry は子を展開した後、深い順に処理すると archive の最終日時と permissions を
保持できます。

> **Integration notes**
>
> `ArchiveReader` and `EntryStream` are not thread-safe. Serialize the operations of one instance
> with an actor or a serial queue, and use independent readers created by `reopen()` for parallel
> extraction. Assign entries sharing the same `solidGroup >= 0` to the same worker; entries with
> `solidGroup == -1` can be parallelized one entry at a time.
>
> `ReadLimits` collects `maxEntrySize`, `maxTotalUncompressedSize`, `maxInMemorySize`,
> `inMemorySingleFileLimit`, and the entry, metadata, path, dictionary and volume limits. Configure
> it before opening, to match your corpus and the device's memory budget. Handle entries larger than
> `read(_:)` allows with `EntryStream`, reading through to the final 0 or error so that the CRC and
> the stream footer are finalized.
>
> Use `Data(contentsOf:options:.mappedIfSafe)` only for a local single file whose contents do not
> change during the call. Use `ArchiveReader.open(url:)` for multi-volume RAR so that sibling files
> can be resolved, and `open(data:)` for bytes already in memory, such as a nested archive. The SFX
> prefix scan is enabled for URL opens; for `Data` and custom `ByteSource` inputs,
> `ReaderOptions.scanForSFXInData` defaults to `false`.
>
> The caller owns the destination root exclusively while extraction is in progress; do not rename or
> restructure it from another thread or process. Processing directory entries after their children,
> deepest first, preserves the final dates and permissions recorded in the archive.

## コマンドライン

```console
$ swift run kaito detect samples/book.tar
tar
$ swift run kaito list samples/book.zip
0\t12345\tfile\tdeflate\tplain\t表紙.jpg
$ swift run kaito list samples/book.zip --raw
$ swift run kaito list samples/book-encrypted.7z -p secret
$ swift run kaito extract samples/book.tar -o /tmp/book
$ swift run kaito sha samples/book.tar
$ swift run kaito sha samples/book-encrypted.7z -p secret
$ swift run kaito bench samples/book.tar 5
$ swift run kaito bench --data samples/book.tar 5
$ swift run kaito bench --random samples/book-solid.7z 5
$ swift run kaito bench --random samples/book-encrypted.7z 5 -p secret
```

`sha` はエントリ順の SHA-256 と総合ダイジェストを出力し、別の展開実装との
差分テストに利用できます。`sha` / `extract` は entry ごとの失敗を stderr へ報告して後続を処理し、
失敗が一件でもあれば終了コード 1 を返します。`sha` の失敗行は `index<TAB>ERROR<TAB>message<TAB>name`、
末尾は成功 entry だけを集計した `partial` となり、完全な `total` は出力しません。`list` は index、size、kind、method、暗号方式 (`plain`、
`ZipCrypto`、`AES-128/192/256`、`7zAES-256`)、name の順でタブ区切り表示し、LHA では
末尾に `level=N` を追加します。`--raw` は
名前の format 上の論理バイト列を末尾へ 16 進数で併記します。LHA の 0x02 directory + 0x01
filename は一つの path に組み立て、0xFF directory 区切りは `/` に正規化されます。
`bench --data` は `mappedIfSafe` で作った `Data`
から書庫を開き、map 作成を含む `open-median-ms` を表示します。`bench --random` は
固定 seed で選んだ最大 20 件の非ディレクトリエントリをランダム順に読み、solid 書庫の
後方シークを含むアクセスを再現可能な条件で計測します。表示する `bytes` は選択した
エントリの合計です。

StuffIt の `list` は末尾に `fork=data` / `fork=resource` を追加します。
`sha` は支給 XADMaster オラクルに合わせ、既定では data fork のみを検証・表示します。
resource だけのファイルは空 data fork の行を表示します。`sha --forks` は公開 entry の
全 fork を検証・表示します。StuffIt の失敗詳細は stderr にだけ出し、stdout の行は数値サイズを保ちます。
これにより支給 `compare.py` を変更せず利用できます。暗号はこの段階では未実装です。

`bench` の時間は process 内の open / extract だけを複数回計測した median で、process 起動、
SHA-256、標準出力は含みません。`swift run` には SwiftPM の planning / build も含まれるため、
CLI 全体の性能は release build 済みの `.build/release/kaito` を直接実行して比較します。
`sha` は再利用する 4 MiB buffer で逐次 hash します。release binary を warm 条件で直接測ると、
変更前→変更後の median は book RAR5 が 155.346→155.431 ms、TIFF RAR5 が
637.541→610.447 ms でした。最終確認の wall time はそれぞれ 0.15 / 0.61 s です。
以前観測した約 0.62 秒の差は decoder ではなく、`swift run` の cold-start / build planning を
測定へ混ぜたことが原因でした。

`list`、`extract`、`sha`、`bench` は `-p <password>` を受け付けます。ヘッダも暗号化された
7z / RAR は、一覧やベンチマークの開始時にも password が必要です。
RAR3 は長いパスワードの旧 SHA-1 入力更新規則に対応します。
writer と同じ最大127文字（UTF-16 候補は127 code units、Unix 候補は127 scalars）で区切ります。BMP 外の文字を含む RAR3 password は
UTF-16 を先に試し、検証失敗時に Unix RAR の Unicode scalar 下位 16 bit 表現へ再試行します。
file data は独立した stream で CRC を最後まで検証してから公開するため、この場合だけ追加の展開が生じます。

RAR5 は先頭127 Unicode scalars の UTF-8 を優先し、有効な password 検査値が一致しなければ
入力全体の UTF-8 を試します。127 scalars 以下の password は変更しません。

> **Command line**
>
> `sha` prints the SHA-256 of each entry in order plus an overall digest, which can be used for
> differential testing against another extraction implementation. `sha` and `extract` report a
> per-entry failure on stderr, continue with the remaining entries, and exit with status 1 if any
> entry failed. A failing `sha` line is `index<TAB>ERROR<TAB>message<TAB>name`, and the final line is
> a `partial` covering only the successful entries; no complete `total` is printed. `list` prints
> index, size, kind, method, encryption (`plain`, `ZipCrypto`, `AES-128/192/256`, `7zAES-256`) and
> name, separated by tabs, appending `level=N` for LHA. `--raw` also prints the format-level logical
> bytes of the name in hexadecimal at the end of the line. An LHA 0x02 directory plus 0x01 filename
> is assembled into one path, and the 0xFF directory separator is normalized to `/`.
> `bench --data` opens the archive from a `Data` created with `mappedIfSafe` and reports an
> `open-median-ms` that includes creating the map. `bench --random` reads up to 20 non-directory
> entries chosen with a fixed seed, in random order, so that access patterns including backward seeks
> in a solid archive are measured reproducibly. The reported `bytes` is the total of the selected
> entries.
>
> `bench` times only the in-process open and extract, repeated and reported as a median; process
> startup, SHA-256 and standard output are excluded. `swift run` also includes SwiftPM planning and
> building, so compare whole-CLI performance by running a release-built `.build/release/kaito`
> directly. `sha` hashes incrementally through a reused 4 MiB buffer. Measuring the release binary
> directly under warm conditions, the before-to-after medians were 155.346 to 155.431 ms for the book
> RAR5 and 637.541 to 610.447 ms for the TIFF RAR5, with final wall times of 0.15 and 0.61 s. The
> roughly 0.62 second difference observed earlier came not from the decoder but from mixing the
> `swift run` cold start and build planning into the measurement.
>
> `list`, `extract`, `sha` and `bench` accept `-p <password>`. A 7z or RAR archive whose headers are
> also encrypted needs the password even to start listing or benchmarking.
> RAR3 supports the old SHA-1 input update rule for long passwords.
> The password is cut at the same maximum of 127 characters as the writer uses (127 code units for
> the UTF-16 candidate, 127 scalars for the Unix candidate). A RAR3 password containing characters
> outside the BMP tries UTF-16 first and, if verification fails, retries with the low 16 bits of the
> Unicode scalars as Unix RAR represents them. File data is published only after its CRC has been
> verified to the end on an independent stream, so this case alone performs an extra expansion.
>
> RAR5 prefers the UTF-8 of the first 127 Unicode scalars and, if no valid password check value
> matches, tries the UTF-8 of the whole input. Passwords of 127 scalars or fewer are unchanged.

## 開発

```console
swift build
swift test
swift build -c release
bash -n Scripts/build-framework.sh Scripts/fuzz/*.sh
python3 -m py_compile Scripts/fuzz/mutate.py
```

7zz / xz を使う差分テストは、`KAITO_7ZZ` / `KAITO_XZ`、`PATH`、既知の Homebrew path
の順で executable を探します。通常は tool が無ければ該当テストを skip します。CI と同じく
不足を failure にする場合は次のように実行します。

```console
brew install sevenzip xz
KAITO_REQUIRE_7ZZ=1 KAITO_REQUIRE_XZ=1 swift test
```

圧縮 payload を含む ZIP / 7z seed を実際の 7zz で作り、malformed / unusual archive の
robustness mutant を ASan/UBSan build で走らせる手順は次のとおりです。AES seed の password は
`KaitoFuzz` で、`--password` は暗号化されていない seed と同じ directory に対しても指定できます。

```console
Scripts/fuzz/make-compressed-seeds.sh /tmp/kaito-compressed-seeds
Scripts/fuzz/run-mutants.sh --count 200 --password KaitoFuzz \
  --require-payload-ranges /tmp/kaito-compressed-seeds
```

`Scripts/build-framework.sh` は Apple Silicon / Intel 両対応のユニバーサル `KaitoKit.framework` を生成します。SwiftPM を介さず利用する場合は、ネストされた `KaitoKitCompat` モジュールを見つけられるよう `-I Frameworks/KaitoKit.framework/Modules` も指定してください。

設計判断、堅牢性規則、参照可能な仕様は [Documentation/design.md](Documentation/design.md)、
XADMaster からの移行状況は
[Documentation/migration-from-xadmaster.md](Documentation/migration-from-xadmaster.md) を参照してください。
設計書が引く性能・安定性の実測ログは
[Documentation/verification/](Documentation/verification/README.md) にあります。

> **Development**
>
> Differential tests that use 7zz and xz look for the executables in the order `KAITO_7ZZ` and
> `KAITO_XZ`, then `PATH`, then the known Homebrew paths. By default the affected tests are skipped
> when a tool is absent. To make a missing tool a failure, as CI does, run the commands shown above
> after installing them.
>
> The commands above also show how to build ZIP and 7z seeds containing compressed payloads with a
> real 7zz, then run malformed and unusual archive robustness mutants against an ASan/UBSan build.
> The password for AES seeds is `KaitoFuzz`, and `--password` may also be given for a directory of
> seeds that are not encrypted.
>
> `Scripts/build-framework.sh` produces a universal `KaitoKit.framework` for both Apple Silicon and
> Intel. When using it without SwiftPM, also pass `-I Frameworks/KaitoKit.framework/Modules` so that
> the nested `KaitoKitCompat` module can be found.
>
> For design decisions, robustness rules and the specifications that may be consulted, see
> [Documentation/design.md](Documentation/design.md); for the state of migration from XADMaster, see
> [Documentation/migration-from-xadmaster.md](Documentation/migration-from-xadmaster.md).
> The measured performance and stability logs cited by the design document are in
> [Documentation/verification/](Documentation/verification/README.md).
