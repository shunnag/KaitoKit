import Foundation
@testable import KaitoKit

struct HandLHAExtendedHeader {
    let type: UInt8
    let payload: [UInt8]

    init(_ type: UInt8, _ payload: [UInt8]) {
        self.type = type
        self.payload = payload
    }
}

struct HandLHAEntry {
    let rawName: [UInt8]
    let contents: Data
    let packedContents: Data?
    let declaredOriginalSize: UInt32?
    let method: String
    let headerLevel: UInt8
    let directoryBytes: [UInt8]?
    let codepage: UInt32?
    let creatorOS: UInt8?
    let includeLevel2HeaderCRC: Bool
    let permissions: UInt16?
    let extraHeaders: [HandLHAExtendedHeader]
    let dataCRC16: UInt16?

    init(
        name: String,
        contents: Data = Data(),
        method: String = "-lh0-",
        headerLevel: UInt8,
        directoryBytes: [UInt8]? = nil,
        codepage: UInt32? = nil,
        creatorOS: UInt8? = nil,
        includeLevel2HeaderCRC: Bool = true,
        permissions: UInt16? = 0o644,
        extraHeaders: [HandLHAExtendedHeader] = [],
        dataCRC16: UInt16? = nil,
        packedContents: Data? = nil,
        declaredOriginalSize: UInt32? = nil
    ) {
        self.init(
            rawName: Array(name.utf8),
            contents: contents,
            method: method,
            headerLevel: headerLevel,
            directoryBytes: directoryBytes,
            codepage: codepage,
            creatorOS: creatorOS,
            includeLevel2HeaderCRC: includeLevel2HeaderCRC,
            permissions: permissions,
            extraHeaders: extraHeaders,
            dataCRC16: dataCRC16,
            packedContents: packedContents,
            declaredOriginalSize: declaredOriginalSize
        )
    }

    init(
        rawName: [UInt8],
        contents: Data = Data(),
        method: String = "-lh0-",
        headerLevel: UInt8,
        directoryBytes: [UInt8]? = nil,
        codepage: UInt32? = nil,
        creatorOS: UInt8? = nil,
        includeLevel2HeaderCRC: Bool = true,
        permissions: UInt16? = 0o644,
        extraHeaders: [HandLHAExtendedHeader] = [],
        dataCRC16: UInt16? = nil,
        packedContents: Data? = nil,
        declaredOriginalSize: UInt32? = nil
    ) {
        self.rawName = rawName
        self.contents = contents
        self.packedContents = packedContents
        self.declaredOriginalSize = declaredOriginalSize
        self.method = method
        self.headerLevel = headerLevel
        self.directoryBytes = directoryBytes
        self.codepage = codepage
        self.creatorOS = creatorOS
        self.includeLevel2HeaderCRC = includeLevel2HeaderCRC
        self.permissions = permissions
        self.extraHeaders = extraHeaders
        self.dataCRC16 = dataCRC16
    }
}

enum LHATestSupport {
    static let unixTimestamp: UInt32 = 1_704_164_645
    static let dosTimestamp: UInt32 =
        (UInt32(2024 - 1980) << 25)
        | (UInt32(1) << 21)
        | (UInt32(2) << 16)
        | (UInt32(3) << 11)
        | (UInt32(4) << 5)
        | UInt32(3)

    static func makeArchive(entries: [HandLHAEntry]) throws -> Data {
        var archive = Data()
        for entry in entries {
            archive.append(try makeMember(entry))
        }
        archive.append(0)
        return archive
    }

    static func makeMember(_ entry: HandLHAEntry) throws -> Data {
        guard let method = entry.method.data(using: .ascii), method.count == 5 else {
            throw KaitoError.malformed("test LHA method must be five ASCII bytes")
        }
        let packedContents = entry.packedContents ?? entry.contents
        guard packedContents.count <= Int(UInt32.max),
              entry.contents.count <= Int(UInt32.max) else {
            throw KaitoError.limitExceeded("test LHA member size")
        }
        let packedSize = UInt32(packedContents.count)
        let originalSize = entry.method == "-lhd-"
            ? UInt32(0)
            : entry.declaredOriginalSize ?? UInt32(entry.contents.count)
        let crc = entry.dataCRC16 ?? CRC16.checksum(Array(entry.contents))

        let header: Data
        switch entry.headerLevel {
        case 0:
            header = try level0Header(
                entry: entry,
                method: Array(method),
                packedSize: packedSize,
                originalSize: originalSize,
                crc: crc
            )
        case 1:
            header = try level1Header(
                entry: entry,
                method: Array(method),
                packedSize: packedSize,
                originalSize: originalSize,
                crc: crc
            )
        case 2:
            header = try level2Header(
                entry: entry,
                method: Array(method),
                packedSize: packedSize,
                originalSize: originalSize,
                crc: crc
            )
        default:
            throw KaitoError.unsupportedMethod("test LHA header level")
        }

        var result = header
        result.append(packedContents)
        return result
    }

    private static func level0Header(
        entry: HandLHAEntry,
        method: [UInt8],
        packedSize: UInt32,
        originalSize: UInt32,
        crc: UInt16
    ) throws -> Data {
        guard !entry.rawName.isEmpty, entry.rawName.count <= 230 else {
            throw KaitoError.malformed("test level-0 LHA name length")
        }
        var bytes: [UInt8] = [0, 0]
        bytes.append(contentsOf: method)
        appendUInt32LE(packedSize, to: &bytes)
        appendUInt32LE(originalSize, to: &bytes)
        appendUInt32LE(dosTimestamp, to: &bytes)
        bytes.append(entry.method == "-lhd-" ? 0x10 : 0x20)
        bytes.append(0)
        bytes.append(UInt8(entry.rawName.count))
        bytes.append(contentsOf: entry.rawName)
        appendUInt16LE(crc, to: &bytes)
        if let creatorOS = entry.creatorOS {
            bytes.append(creatorOS)
        }

        let headerSize = bytes.count - 2
        guard headerSize <= Int(UInt8.max) else {
            throw KaitoError.malformed("test level-0 LHA header is too long")
        }
        bytes[0] = UInt8(headerSize)
        bytes[1] = byteSum(bytes[2...])
        return Data(bytes)
    }

    private static func level1Header(
        entry: HandLHAEntry,
        method: [UInt8],
        packedSize: UInt32,
        originalSize: UInt32,
        crc: UInt16
    ) throws -> Data {
        guard entry.rawName.count <= 230 else {
            throw KaitoError.malformed("test level-1 LHA name length")
        }
        let extensions = extensionRecords(for: entry, includeFilename: false)
        let chain = try makeExtendedHeaderChain(extensions, sizeFieldBytes: 2)
        guard chain.bytes.count <= Int(UInt32.max) - Int(packedSize) else {
            throw KaitoError.limitExceeded("test level-1 LHA skip size")
        }

        var bytes: [UInt8] = [0, 0]
        bytes.append(contentsOf: method)
        appendUInt32LE(packedSize + UInt32(chain.bytes.count), to: &bytes)
        appendUInt32LE(originalSize, to: &bytes)
        appendUInt32LE(dosTimestamp, to: &bytes)
        bytes.append(0x20)
        bytes.append(1)
        bytes.append(UInt8(entry.rawName.count))
        bytes.append(contentsOf: entry.rawName)
        appendUInt16LE(crc, to: &bytes)
        bytes.append(entry.creatorOS ?? 0x55) // UNIX by default
        appendUInt16LE(UInt16(chain.firstSize), to: &bytes)

        let baseHeaderSize = bytes.count - 2
        guard baseHeaderSize <= Int(UInt8.max) else {
            throw KaitoError.malformed("test level-1 LHA base header is too long")
        }
        bytes[0] = UInt8(baseHeaderSize)
        bytes[1] = byteSum(bytes[2...])
        bytes.append(contentsOf: chain.bytes)
        return Data(bytes)
    }

    private static func level2Header(
        entry: HandLHAEntry,
        method: [UInt8],
        packedSize: UInt32,
        originalSize: UInt32,
        crc: UInt16
    ) throws -> Data {
        var extensions: [HandLHAExtendedHeader] = []
        if entry.includeLevel2HeaderCRC {
            extensions.append(HandLHAExtendedHeader(0x00, [0, 0]))
        }
        extensions.append(contentsOf: extensionRecords(for: entry, includeFilename: true))
        let chain = try makeExtendedHeaderChain(extensions, sizeFieldBytes: 2)

        var bytes: [UInt8] = [0, 0]
        bytes.append(contentsOf: method)
        appendUInt32LE(packedSize, to: &bytes)
        appendUInt32LE(originalSize, to: &bytes)
        appendUInt32LE(unixTimestamp, to: &bytes)
        bytes.append(0x20)
        bytes.append(2)
        appendUInt16LE(crc, to: &bytes)
        bytes.append(entry.creatorOS ?? 0x55) // UNIX by default
        appendUInt16LE(UInt16(chain.firstSize), to: &bytes)
        bytes.append(contentsOf: chain.bytes)

        guard bytes.count <= Int(UInt16.max), bytes.count & 0xff != 0 else {
            throw KaitoError.malformed("test level-2 LHA header size")
        }
        writeUInt16LE(UInt16(bytes.count), in: &bytes, at: 0)

        if entry.includeLevel2HeaderCRC {
            // The common extension is first: its two payload bytes are at 27...28.
            guard bytes.count >= 29, bytes[26] == 0 else {
                throw KaitoError.malformed("test level-2 common header layout")
            }
            bytes[27] = 0
            bytes[28] = 0
            let headerCRC = CRC16.checksum(bytes)
            writeUInt16LE(headerCRC, in: &bytes, at: 27)
        }
        return Data(bytes)
    }

    private static func extensionRecords(
        for entry: HandLHAEntry,
        includeFilename: Bool
    ) -> [HandLHAExtendedHeader] {
        var result: [HandLHAExtendedHeader] = []
        if let directoryBytes = entry.directoryBytes {
            result.append(HandLHAExtendedHeader(0x02, directoryBytes))
        }
        if includeFilename {
            result.append(HandLHAExtendedHeader(0x01, entry.rawName))
        }
        if let codepage = entry.codepage {
            var payload: [UInt8] = []
            appendUInt32LE(codepage, to: &payload)
            result.append(HandLHAExtendedHeader(0x46, payload))
        }
        if let permissions = entry.permissions {
            var payload: [UInt8] = []
            appendUInt16LE(permissions, to: &payload)
            result.append(HandLHAExtendedHeader(0x50, payload))
        }
        result.append(contentsOf: entry.extraHeaders)
        return result
    }

    private static func makeExtendedHeaderChain(
        _ records: [HandLHAExtendedHeader],
        sizeFieldBytes: Int
    ) throws -> (firstSize: Int, bytes: [UInt8]) {
        guard sizeFieldBytes == 2 else {
            throw KaitoError.unsupportedMethod("test LHA extended-header size field")
        }
        var nextSize = 0
        var chain: [UInt8] = []
        for record in records.reversed() {
            let recordSize = 1 + record.payload.count + sizeFieldBytes
            guard recordSize <= Int(UInt16.max) else {
                throw KaitoError.limitExceeded("test LHA extended header")
            }
            var encoded = [record.type]
            encoded.append(contentsOf: record.payload)
            appendUInt16LE(UInt16(nextSize), to: &encoded)
            encoded.append(contentsOf: chain)
            chain = encoded
            nextSize = recordSize
        }
        return (nextSize, chain)
    }

    private static func byteSum(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        bytes.reduce(UInt8(0)) { $0 &+ $1 }
    }

    static func appendUInt16LE(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    static func appendUInt32LE(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    static func appendUInt64LE(_ value: UInt64, to bytes: inout [UInt8]) {
        appendUInt32LE(UInt32(truncatingIfNeeded: value), to: &bytes)
        appendUInt32LE(UInt32(truncatingIfNeeded: value >> 32), to: &bytes)
    }

    private static func writeUInt16LE(
        _ value: UInt16,
        in bytes: inout [UInt8],
        at offset: Int
    ) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }
}
