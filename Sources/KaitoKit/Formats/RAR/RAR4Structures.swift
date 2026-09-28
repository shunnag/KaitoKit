import Foundation

// Provenance:
// - RAR 1.5-4.x unofficial format notes:
//   https://github.com/bitplane/rar-research/blob/master/doc/RAR15_40_FORMAT_SPECIFICATION.md
// - libarchive's BSD-2-licensed archive_read_support_format_rar.c was consulted
//   for format behaviour, not for code or structure.
// No 7-Zip Rar29, unrar source, XADMaster, or The Unarchiver source was used.

/// HEAD_TYPE of a block header.
enum RAR4HeaderType: UInt8 {
    case main = 0x73
    case file = 0x74
    case comment = 0x75
    case authenticity = 0x76
    case subblock = 0x77
    case recovery = 0x78
    case signature = 0x79
    case newSubblock = 0x7a
    case end = 0x7b
}

/// HEAD_FLAGS bits of the main (archive) header.
enum RAR4MainFlag {
    static let volume: UInt16 = 0x0001
    static let solid: UInt16 = 0x0008
    static let newNumbering: UInt16 = 0x0010
    static let encryptedHeaders: UInt16 = 0x0080
    static let firstVolume: UInt16 = 0x0100
    static let encryptionVersion: UInt16 = 0x0200
}

/// HEAD_FLAGS bits of a file header. The dictionary bits 0x00e0 all set mark
/// a directory; `additionalSize` (LONG_BLOCK) is common to every block type.
enum RAR4FileFlag {
    static let splitBefore: UInt16 = 0x0001
    static let splitAfter: UInt16 = 0x0002
    static let encrypted: UInt16 = 0x0004
    static let solid: UInt16 = 0x0010
    static let dictionaryMask: UInt16 = 0x00e0
    static let large: UInt16 = 0x0100
    static let unicode: UInt16 = 0x0200
    static let salt: UInt16 = 0x0400
    static let version: UInt16 = 0x0800
    static let extendedTime: UInt16 = 0x1000
    static let additionalSize: UInt16 = 0x8000
}

/// HEAD_FLAGS bits shared by every block header.
enum RAR4CommonFlag {
    static let skipIfUnknown: UInt16 = 0x4000
}

/// HEAD_FLAGS bits of the end-of-archive header.
enum RAR4EndFlag {
    static let nextVolume: UInt16 = 0x0001
}

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

// MARK: - Parse state and read plans

/// The archive flags every later header of the volume is read against.
struct RAR4MainHeader {
    let flags: UInt16

    var isVolume: Bool { flags & RAR4MainFlag.volume != 0 }
    var isSolid: Bool { flags & RAR4MainFlag.solid != 0 }
    var hasEncryptedHeaders: Bool {
        flags & RAR4MainFlag.encryptedHeaders != 0
    }
}

/// One CRC-checked (and possibly decrypted) header and the first physical
/// byte after its padded representation.
struct RAR4ParsedHeader {
    let bytes: [UInt8]
    let physicalEnd: UInt64
}

/// The fields of one FILE_HEAD header after bounds, name and timestamp
/// decoding, together with where the header and its data sit.
struct RAR4FileHeaderFields {
    let headerOffset: UInt64
    let dataOffset: UInt64
    let flags: UInt16
    let rawName: [UInt8]
    let decodedName: (fallback: [UInt8], unicode: String?, declared: String.Encoding?)
    let kind: EntryKind
    let packedSize: UInt64
    let unpackedSize: UInt64
    let modificationDate: Date?
    let permissions: UInt16?
    let hostOS: UInt8
    let attributes: UInt32
    let unpackVersion: UInt8
    let method: UInt8
    let dictionarySize: UInt64
    let salt: [UInt8]?
    let fileCRC: UInt32
}

/// One file header, or split headers joined across volumes, before its name
/// encoding is resolved and it is published.
struct RAR4PendingEntry {
    let rawName: [UInt8]
    let fallbackName: [UInt8]
    let decodedUnicodeName: String?
    let declaredEncoding: String.Encoding?
    let kind: EntryKind
    let unpackedSize: UInt64
    let packedSize: UInt64
    let modificationDate: Date?
    let permissions: UInt16?
    let isEncrypted: Bool
    let crc32: UInt32
    let methodDescription: String
    let formatSpecific: [String: String]
}

/// Read plan kept beside each published entry: packed ranges, per-part CRCs,
/// and the parameters the decoders need.
struct RAR4EntryRecord {
    let packedSegments: [SourceSegment]
    let packedPartCRC32: [UInt32?]
    let packedSize: UInt64
    let unpackedSize: UInt64
    let crc32: UInt32
    let firstFlags: UInt16
    let lastFlags: UInt16
    let unpackVersion: UInt8
    let method: UInt8
    let dictionarySize: UInt64
    let salt: [UInt8]?

    var isEncrypted: Bool { firstFlags & RAR4FileFlag.encrypted != 0 }
    var isSplit: Bool {
        firstFlags & RAR4FileFlag.splitBefore != 0 ||
            lastFlags & RAR4FileFlag.splitAfter != 0
    }
}

/// What `RAR4VolumeParser.parseVolume` collects from one volume.
struct RAR4ParsedVolume {
    let pendingEntries: [RAR4PendingEntry]
    let records: [RAR4EntryRecord]
    let mainHeader: RAR4MainHeader
    let requestsNextVolume: Bool
}

/// The published entries of a whole volume set, with their read plans.
struct RAR4ParsedArchive {
    let entries: [ArchiveEntry]
    let records: [RAR4EntryRecord]
    let nameEncoding: String.Encoding?
    let resolvedPassword: String?
}
