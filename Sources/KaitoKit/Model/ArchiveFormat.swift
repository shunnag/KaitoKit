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

    /// Gzip streams.
    case gzip

    /// Bzip2 streams.
    case bzip2

    /// XZ streams.
    case xz

    /// UNIX compress (`.Z`) streams.
    case compress
}
