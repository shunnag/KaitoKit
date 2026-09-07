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

struct RAR5CompressionInfo: Sendable, Equatable {
    let rawValue: UInt64
    let version: UInt8
    let isSolid: Bool
    let method: UInt8
    let dictionarySize: UInt64

    init(rawValue: UInt64) throws {
        let version = UInt8(rawValue & 0x3f)
        guard version <= 1 else {
            throw KaitoError.unsupportedMethod("RAR compression version \(version)")
        }

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
        var dictionarySize = base
        if version == 1 {
            let fraction = (rawValue >> 15) & 0x1f
            let increment = try Checked.mul(base, fraction) / 32
            dictionarySize = try Checked.add(base, increment)
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
