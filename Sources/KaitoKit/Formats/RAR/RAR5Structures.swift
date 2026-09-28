import Foundation

// Format reference: RARLab, "RAR 5.0 archive format",
// https://www.rarlab.com/technote.htm (accessed 2026-09-06).
// This is a clean-room implementation of the published format description.
// RARLab/UnRAR, 7-Zip, XADMaster, and The Unarchiver source code were not used.

enum RAR5HeaderType: UInt64 {
    case main = 1
    case file = 2
    case service = 3
    case encryption = 4
    case end = 5
}

struct RAR5HeaderFlags: OptionSet, Sendable {
    let rawValue: UInt64

    static let extraArea = Self(rawValue: 0x0001)
    static let dataArea = Self(rawValue: 0x0002)
    static let skipIfUnknown = Self(rawValue: 0x0004)
    static let splitBefore = Self(rawValue: 0x0008)
    static let splitAfter = Self(rawValue: 0x0010)
    static let child = Self(rawValue: 0x0020)
    static let inheritedChild = Self(rawValue: 0x0040)
}

struct RAR5FileFlags: OptionSet, Sendable {
    let rawValue: UInt64

    static let directory = Self(rawValue: 0x0001)
    static let unixTime = Self(rawValue: 0x0002)
    static let crc32 = Self(rawValue: 0x0004)
    static let unpackedSizeUnknown = Self(rawValue: 0x0008)
}

struct RAR5ArchiveFlags: OptionSet, Sendable {
    let rawValue: UInt64

    static let volume = Self(rawValue: 0x0001)
    static let volumeNumber = Self(rawValue: 0x0002)
    static let solid = Self(rawValue: 0x0004)
    static let recovery = Self(rawValue: 0x0008)
    static let locked = Self(rawValue: 0x0010)
}

struct RAR5EndFlags: OptionSet, Sendable {
    let rawValue: UInt64

    static let moreVolumes = Self(rawValue: 0x0001)
}

/// Host OS values of the file header that change how attributes are read.
enum RAR5HostOS {
    static let windows: UInt64 = 0
    static let unix: UInt64 = 1
}

/// Record types of the file and service header extra area.
enum RAR5ExtraRecordType {
    static let encryption: UInt64 = 0x01
    static let hash: UInt64 = 0x02
    static let time: UInt64 = 0x03
    static let version: UInt64 = 0x04
    static let redirection: UInt64 = 0x05
    static let owner: UInt64 = 0x06
    static let serviceData: UInt64 = 0x07
}

/// Redirection types of the file-system redirection extra record.
enum RAR5RedirectionType {
    static let unixSymlink: UInt64 = 1
    static let windowsSymlink: UInt64 = 2
    static let junction: UInt64 = 3
    static let hardLink: UInt64 = 4
    static let fileCopy: UInt64 = 5

    /// Types published as symbolic links whose target is the record's text.
    static let symbolicLinks: ClosedRange<UInt64> = unixSymlink...junction

    /// Hard links and file copies store no data body of their own.
    static func isZeroBody(_ type: UInt64?) -> Bool {
        type == hardLink || type == fileCopy
    }
}

struct RAR5CompressionInfo: Sendable, Equatable {
    let rawValue: UInt64
    let version: UInt8
    let isSolid: Bool
    let method: UInt8
    let dictionarySize: UInt64

    init(rawValue: UInt64) throws {
        let version = UInt8(rawValue & 0x3f)
        let dictionarySize: UInt64
        if version > 1 {
            // Later layouts are listable, but their version-specific dictionary
            // fields are deliberately not interpreted before stream creation.
            dictionarySize = 128 * 1_024
        } else {
            let exponent = UInt8((rawValue >> 10) & 0x1f)
            if version == 0, exponent > 15 {
                throw KaitoError.malformed(
                    "RAR5 version 0 dictionary exponent exceeds 15"
                )
            }
            guard exponent <= 23 else {
                throw KaitoError.malformed("RAR dictionary exponent exceeds 23")
            }

            let base = try Checked.shiftLeft(128 * 1_024, by: UInt64(exponent))
            if version == 1 {
                let fraction = (rawValue >> 15) & 0x1f
                let increment = try Checked.mul(base, fraction) / 32
                dictionarySize = try Checked.add(base, increment)
            } else {
                dictionarySize = base
            }
        }
        self.rawValue = rawValue
        self.version = version
        self.isSolid = rawValue & 0x40 != 0
        self.method = UInt8((rawValue >> 7) & 0x07)
        self.dictionarySize = dictionarySize
    }
}

struct RAR5EncryptionRecord: Sendable, Equatable {
    let version: UInt64
    let flags: UInt64
    let kdfCount: UInt8
    let salt: [UInt8]
    let initializationVector: [UInt8]
    let checkValue: [UInt8]?

    var usesTweakedChecksums: Bool { flags & 0x0002 != 0 }
}

struct RAR5HashRecord: Sendable, Equatable {
    let type: UInt64
    let digest: [UInt8]
}

struct RAR5RedirectionRecord: Sendable, Equatable {
    let type: UInt64
    let flags: UInt64
    let target: String
}

/// A cursor over a previously bounded RAR header. Subcursors share the same
/// copy-on-write byte allocation and cannot advance outside their declared range.
struct RAR5ByteCursor {
    private let bytes: [UInt8]
    private(set) var offset: Int
    private let upperBound: Int

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.offset = 0
        self.upperBound = bytes.count
    }

    private init(bytes: [UInt8], offset: Int, upperBound: Int) {
        self.bytes = bytes
        self.offset = offset
        self.upperBound = upperBound
    }

    var remaining: Int { upperBound - offset }
    var isAtEnd: Bool { offset == upperBound }

    mutating func readUInt8() throws -> UInt8 {
        guard remaining >= 1 else { throw KaitoError.truncated }
        let value = bytes[offset]
        offset += 1
        return value
    }

    mutating func readUInt32LE() throws -> UInt32 {
        var value: UInt32 = 0
        for shift in stride(from: 0, to: 32, by: 8) {
            value |= UInt32(try readUInt8()) << shift
        }
        return value
    }

    mutating func readUInt64LE() throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, to: 64, by: 8) {
            value |= UInt64(try readUInt8()) << shift
        }
        return value
    }

    /// Reads the RAR little-endian base-128 integer. The format intentionally
    /// defines values wider than 64 bits as their low 64 bits; only an eleventh
    /// byte is invalid. Padding such as 80 80 80 00 is therefore accepted.
    mutating func readVInt() throws -> UInt64 {
        var value: UInt64 = 0
        for byteIndex in 0..<10 {
            let byte = try readUInt8()
            let payload = UInt64(byte & 0x7f)
            let shift = byteIndex * 7
            if shift < 64 {
                let useful = min(7, 64 - shift)
                let mask = (UInt64(1) << useful) - 1
                value |= (payload & mask) << shift
            }
            if byte & 0x80 == 0 { return value }
        }
        throw KaitoError.malformed("RAR vint exceeds 10 bytes")
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= remaining else { throw KaitoError.truncated }
        let end = offset + count
        let result = Array(bytes[offset..<end])
        offset = end
        return result
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, count <= remaining else { throw KaitoError.truncated }
        offset += count
    }

    mutating func readSubcursor(_ count: Int) throws -> RAR5ByteCursor {
        guard count >= 0, count <= remaining else { throw KaitoError.truncated }
        let start = offset
        offset += count
        return RAR5ByteCursor(bytes: bytes, offset: start, upperBound: start + count)
    }
}

enum RAR5VInt {
    /// Reads a vint directly from the archive while retaining its encoded bytes
    /// for the header CRC. Values wider than 64 bits retain only their low bits.
    static func read(from reader: inout ByteReader) throws -> (value: UInt64, bytes: [UInt8]) {
        var value: UInt64 = 0
        var encoded: [UInt8] = []
        encoded.reserveCapacity(10)

        for byteIndex in 0..<10 {
            let byte = try reader.readUInt8()
            encoded.append(byte)
            let payload = UInt64(byte & 0x7f)
            let shift = byteIndex * 7
            if shift < 64 {
                let useful = min(7, 64 - shift)
                let mask = (UInt64(1) << useful) - 1
                value |= (payload & mask) << shift
            }
            if byte & 0x80 == 0 { return (value, encoded) }
        }
        throw KaitoError.malformed("RAR vint exceeds 10 bytes")
    }
}

// MARK: - Parse state and read plans

/// One CRC-verified header block: its specific and extra areas as bounded
/// cursors, and the data area that follows (possibly cut short by EOF).
struct RAR5Block {
    let offset: UInt64
    let typeValue: UInt64
    let flags: RAR5HeaderFlags
    let specific: RAR5ByteCursor
    let extra: RAR5ByteCursor
    let dataOffset: UInt64
    let dataSize: UInt64
    let availableDataSize: UInt64
    let isDataTruncated: Bool
    let nextOffset: UInt64
}

/// Extra-area records of one file header.
struct RAR5FileExtras {
    var encryption: RAR5EncryptionRecord?
    var hash: RAR5HashRecord?
    var modificationDate: Date?
    var creationDate: Date?
    var accessDate: Date?
    var version: UInt64?
    var redirection: RAR5RedirectionRecord?
    var ownerName: String?
    var groupName: String?
    var ownerID: UInt64?
    var groupID: UInt64?
}

/// Integrity values attached to one packed range. RAR5 defines CRC32 and
/// BLAKE2sp in every non-final split header over that header's packed data;
/// the final header carries the checksum/hash of the complete unpacked file.
struct RAR5PackedPartIntegrity {
    let crc32: UInt32?
    let hash: RAR5HashRecord?
    let usesTweakedChecksums: Bool
}

/// One file header, or split headers joined across volumes, before publication.
struct RAR5PendingEntry {
    let rawName: [UInt8]
    let name: String
    let pathComponents: [String]
    let kind: EntryKind
    let unpackedSize: UInt64?
    let packedSize: UInt64
    var availablePackedSize: UInt64? = nil
    var isIncomplete = false
    let modificationDate: Date?
    let permissions: UInt16?
    let crc32: UInt32?
    let compression: RAR5CompressionInfo
    let firstHeaderFlags: RAR5HeaderFlags
    let lastHeaderFlags: RAR5HeaderFlags
    let packedSegments: [SourceSegment]
    let packedPartIntegrity: [RAR5PackedPartIntegrity]
    let firstVolumeNumber: UInt64
    let lastVolumeNumber: UInt64
    let attributes: UInt64
    let hostOS: UInt64
    let extras: RAR5FileExtras

    var splitBefore: Bool { firstHeaderFlags.contains(.splitBefore) }
    var splitAfter: Bool { lastHeaderFlags.contains(.splitAfter) }
    var isMultiVolume: Bool {
        packedSegments.count > 1 || splitBefore || splitAfter
    }
}

/// Read plan kept beside each published entry: packed ranges, integrity
/// values, and the parameters the decoders need.
struct RAR5EntryRecord {
    let packedSegments: [SourceSegment]
    let packedPartIntegrity: [RAR5PackedPartIntegrity]
    let packedSize: UInt64
    var availablePackedSize: UInt64? = nil
    var isIncomplete = false
    let unpackedSize: UInt64?
    let compression: RAR5CompressionInfo
    let encryption: RAR5EncryptionRecord?
    let hash: RAR5HashRecord?
    let redirectionType: UInt64?
    let requiresPreviousVolume: Bool
    let requiresNextVolume: Bool
}

/// Header key of an encrypted archive and whether its password check verified it.
struct RAR5ArchiveEncryptionContext {
    let key: Data
    let passwordWasVerified: Bool
}

/// Bounds the aggregate work of archive-header key derivations. The parse
/// cache is sized to retain every context reachable within maxVolumeCount,
/// so each distinct context here corresponds to one actual derivation.
struct RAR5HeaderKDFWorkBudget {
    let limit: UInt64
    private(set) var used: UInt64 = 0
    private var contexts: Set<RAR5KeyCacheKey> = []

    // Explicit because the private stored properties make the implicit
    // memberwise initializer private as well.
    init(limit: UInt64) {
        self.limit = limit
    }

    mutating func charge(
        passwordUTF8: Data,
        salt: [UInt8],
        count: UInt8
    ) throws {
        let context = RAR5KeyCacheKey(
            passwordUTF8: passwordUTF8,
            salt: Data(salt),
            count: count
        )
        guard !contexts.contains(context) else { return }

        let work = (UInt64(1) << UInt64(count)) + 32
        let (total, overflow) = used.addingReportingOverflow(work)
        guard !overflow, total <= limit else {
            throw KaitoError.limitExceeded("RAR5 header encryption KDF work")
        }
        used = total
        contexts.insert(context)
    }
}

/// What `RAR5VolumeParser.parseVolume` collects from one volume.
struct RAR5VolumeParseState {
    var pending: [RAR5PendingEntry] = []
    var archiveFlags = RAR5ArchiveFlags()
    var volumeNumber: UInt64 = 0
    var headersEncrypted = false
    var sawMainHeader = false
    var sawEndHeader = false
    var endFlags = RAR5EndFlags()
    var serviceHeaderCount = 0
    var retainedMetadataSize: UInt64 = 0
}
