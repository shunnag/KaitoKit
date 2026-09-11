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

    /// POSIX, pax, or GNU tar containers.
    case tar

    /// Binary, odc, newc, or additive-checksum cpio containers.
    case cpio

    /// Unix `ar` archives, including `.deb` packages.
    case ar

    /// ISO 9660 optical disc images.
    case iso

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

    /// LZMA_Alone (`.lzma`) streams.
    case lzma

    /// UNIX compress (`.Z`) streams.
    case compress
}
