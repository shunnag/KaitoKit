import Foundation

// Provenance:
// - RAR 1.5-4.x unofficial format notes:
//   https://github.com/bitplane/rar-research/blob/master/doc/RAR15_40_FORMAT_SPECIFICATION.md
// - libarchive's BSD-2-licensed archive_read_support_format_rar.c was consulted
//   for format behaviour, not for code or structure.
// No 7-Zip Rar29, unrar source, XADMaster, or The Unarchiver source was used.

/// HOST_OS values of the RAR4 file header.
enum RAR4HostOS {
    static let msDOS: UInt8 = 0
    static let os2: UInt8 = 1
    static let windows: UInt8 = 2
    static let unix: UInt8 = 3
    static let macOS: UInt8 = 4
    static let beOS: UInt8 = 5
    static let winCE: UInt8 = 6

    /// Hosts whose attribute field holds DOS attributes (bit 0x10 = directory).
    static func usesDOSAttributes(_ host: UInt8) -> Bool {
        host <= windows
    }

    /// Hosts whose attribute field holds Unix mode bits.
    static func usesUnixMode(_ host: UInt8) -> Bool {
        host == unix || host == macOS || host == beOS
    }
}

/// METHOD values of the RAR4 file header. Every compressed level uses the same
/// unpack algorithm; the level only records the writer's setting.
enum RAR4Method {
    static let stored: UInt8 = 0x30
    static let fastest: UInt8 = 0x31
    static let fast: UInt8 = 0x32
    static let normal: UInt8 = 0x33
    static let good: UInt8 = 0x34
    static let best: UInt8 = 0x35

    static let compressed: ClosedRange<UInt8> = fastest...best
}
