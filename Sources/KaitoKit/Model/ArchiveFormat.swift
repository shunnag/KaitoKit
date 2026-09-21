/// Archive container formats recognized by KaitoKit.
public enum ArchiveFormat: String, Sendable, CaseIterable {
    /// ZIP and ZIP-derived containers.
    case zip

    /// RAR version 4 or 5 containers.
    case rar

    /// 7-Zip containers.
    case sevenZip = "7z"

    /// LHA/LZH containers.
    case lha

    /// classic StuffIt と StuffIt 5 の容器。
    case stuffIt = "sit"

    /// StuffIt X のバイナリ容器。
    case stuffItX = "sitx"

    /// POSIX, pax, or GNU tar containers.
    case tar

    /// Binary, odc, newc, or additive-checksum cpio containers.
    case cpio

    /// Unix `ar` archives, including `.deb` packages.
    case ar

    /// ISO 9660 optical disc images, including ISO 9660 / UDF hybrids (the UDF tree is preferred
    /// when it is present and readable).
    case iso

    /// UDF (ECMA-167 / OSTA UDF 1.02-2.60) disc images without ISO 9660 structures.
    case udf

    /// Windows Imaging (`.wim`, first part of `.swm`) with stored, XPRESS or LZX resources.
    case wim

    /// Microsoft Compound File Binary ([MS-CFB], OLE2 structured storage: `.msi`, `.doc`, `.xls`,
    /// `.ppt`, `.msg`, `Thumbs.db`). Storages are directories and streams are stored files.
    case compoundFile = "cfb"

    /// Microsoft HTML Help (`.chm`, ITSF / ITSS): the user files of the help project, stored or in an
    /// LZX-compressed section.
    case chm

    /// ARJ archives (Robert K. Jung / ARJ Software), including DOS self-extractors: stored files and
    /// methods 1-3 (LZ77 + static Huffman). Method 4, garbled files and multi-volume sets are listed
    /// but cannot be read.
    case arj

    /// Apple disk images: UDIF `.dmg` (zlib / bzip2 / lzfse / lzma / raw chunks) and raw HFS+ images,
    /// listing the HFS Plus / HFSX volume, or the ISO 9660 / UDF volume of a hybrid image.
    case dmg

    /// A MacBinary (I / II / III) file whose payload is not a StuffIt archive: one file with its
    /// data fork and, when present, a `..namedfork/rsrc` resource fork entry.
    case macBinary = "macbinary"

    /// An AppleSingle file whose payload is not a StuffIt archive (see ``macBinary``).
    case appleSingle = "applesingle"

    /// A BinHex 4.0 file whose payload is not a StuffIt archive (see ``macBinary``).
    case binHex = "binhex"

    /// Microsoft Cabinet containers.
    case cab

    /// RPM packages containing a compressed or stored cpio payload.
    case rpm

    /// eXtensible ARchive containers, including macOS flat installer packages.
    case xar

    /// Gzip streams.
    case gzip

    /// Bzip2 streams.
    case bzip2

    /// XZ streams.
    case xz

    /// Zstandard ストリーム。/ Zstandard streams.
    case zstd

    /// Modern and legacy LZ4 frames, including linked blocks and concatenation.
    case lz4

    /// LZMA_Alone (`.lzma`) streams.
    case lzma

    /// lzip (`.lz`) member streams, including multimember files.
    case lzip

    /// brotli (`.br`) streams decoded by Apple Compression.
    case brotli

    /// pbzx chunked XZ containers (the `Payload` of Apple flat packages); a cpio payload is
    /// listed directly as `.cpio`.
    case pbzx

    /// UNIX compress (`.Z`) streams.
    case compress
}
