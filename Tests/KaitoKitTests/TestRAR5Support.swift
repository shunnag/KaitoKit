import Foundation
@testable import KaitoKit
import XCTest

enum RAR5TestSupport {
    static let executablePath = "/opt/homebrew/bin/rar"

    struct BlockLayout {
        let offset: Int
        let sizeField: Range<Int>
        let body: Range<Int>
        let data: Range<Int>
    }

    static func requireRAR() throws {
        try ZipTestSupport.requireExecutable(
            executablePath,
            reason: "RAR fixture generator is unavailable at \(executablePath)"
        )
    }

    static func makeGeneratedArchive(
        sourceDirectory: URL,
        paths: [String],
        archiveURL: URL,
        options: [String]
    ) throws {
        try requireRAR()
        _ = try ZipTestSupport.checkedRun(
            executablePath,
            arguments: ["a", "-ma5", "-idq"] + options + [archiveURL.path] + paths,
            currentDirectory: sourceDirectory
        )
    }

    static func archive(
        mainFlags: UInt64 = 0,
        mainVolumeNumber: UInt64? = nil,
        endFlags: UInt64 = 0,
        blocks: [Data]
    ) -> Data {
        var result = Data(RAR5Reader.signature)
        var mainSpecific = vint(mainFlags)
        if mainFlags & 0x0002 != 0 {
            mainSpecific += vint(mainVolumeNumber ?? 0)
        }
        result.append(block(type: 1, specific: mainSpecific))
        for item in blocks { result.append(item) }
        result.append(block(type: 5, specific: vint(endFlags)))
        return result
    }

    static func storedFile(
        rawName: [UInt8],
        contents: Data,
        unpackedSize: UInt64? = nil,
        dataCRC32: UInt32? = nil,
        includeCRC32: Bool = true,
        hostOS: UInt64 = 1,
        fileFlags additionalFileFlags: UInt64 = 0,
        compressionInfo: UInt64 = 0,
        extra: [UInt8] = [],
        headerFlags: UInt64 = 0
    ) -> Data {
        let fileFlags = additionalFileFlags | (includeCRC32 ? 0x0004 : 0)
        var specific = vint(fileFlags)
        specific += vint(unpackedSize ?? UInt64(contents.count))
        specific += vint(0)
        if includeCRC32 {
            appendLittle(dataCRC32 ?? CRC32.checksum(contents), to: &specific)
        }
        specific += vint(compressionInfo)
        specific += vint(hostOS)
        specific += vint(UInt64(rawName.count))
        specific += rawName
        return block(
            type: 2,
            flags: headerFlags,
            specific: specific,
            extra: extra,
            data: contents
        )
    }

    static func storedFile(
        name: String,
        contents: Data,
        unpackedSize: UInt64? = nil,
        dataCRC32: UInt32? = nil,
        includeCRC32: Bool = true,
        hostOS: UInt64 = 1,
        fileFlags: UInt64 = 0,
        compressionInfo: UInt64 = 0,
        extra: [UInt8] = [],
        headerFlags: UInt64 = 0
    ) -> Data {
        storedFile(
            rawName: Array(name.utf8),
            contents: contents,
            unpackedSize: unpackedSize,
            dataCRC32: dataCRC32,
            includeCRC32: includeCRC32,
            hostOS: hostOS,
            fileFlags: fileFlags,
            compressionInfo: compressionInfo,
            extra: extra,
            headerFlags: headerFlags
        )
    }

    static func block(
        type: UInt64,
        flags suppliedFlags: UInt64 = 0,
        specific: [UInt8],
        extra: [UInt8] = [],
        data: Data = Data()
    ) -> Data {
        var flags = suppliedFlags
        if !extra.isEmpty { flags |= 0x0001 }
        if !data.isEmpty { flags |= 0x0002 }

        var body = vint(type)
        body += vint(flags)
        if flags & 0x0001 != 0 { body += vint(UInt64(extra.count)) }
        if flags & 0x0002 != 0 { body += vint(UInt64(data.count)) }
        body += specific
        body += extra

        let size = vint(UInt64(body.count))
        var covered = size
        covered += body
        var result = Data()
        var crcBytes: [UInt8] = []
        appendLittle(CRC32.checksum(covered), to: &crcBytes)
        result.append(contentsOf: crcBytes)
        result.append(contentsOf: covered)
        result.append(data)
        return result
    }

    static func extraRecord(type: UInt64, payload: [UInt8] = []) -> [UInt8] {
        let record = vint(type) + payload
        return vint(UInt64(record.count)) + record
    }

    static func vint(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    static func blockLayouts(in bytes: [UInt8]) throws -> [BlockLayout] {
        var layouts: [BlockLayout] = []
        var offset = RAR5Reader.signature.count
        while offset < bytes.count {
            guard bytes.count - offset >= 5 else { throw KaitoError.truncated }
            var cursor = offset + 4
            let sizeStart = cursor
            let headerSize = try readVInt(bytes, offset: &cursor)
            let sizeEnd = cursor
            let bodyEnd = try checkedIndex(cursor, adding: headerSize, limit: bytes.count)

            var bodyCursor = cursor
            _ = try readVInt(bytes, offset: &bodyCursor)
            let flags = try readVInt(bytes, offset: &bodyCursor)
            if flags & 0x0001 != 0 { _ = try readVInt(bytes, offset: &bodyCursor) }
            let dataSize = flags & 0x0002 != 0
                ? try readVInt(bytes, offset: &bodyCursor)
                : 0
            let dataEnd = try checkedIndex(bodyEnd, adding: dataSize, limit: bytes.count)
            layouts.append(BlockLayout(
                offset: offset,
                sizeField: sizeStart..<sizeEnd,
                body: cursor..<bodyEnd,
                data: bodyEnd..<dataEnd
            ))
            offset = dataEnd
        }
        return layouts
    }

    static func repairHeaderCRC(_ bytes: inout [UInt8], layout: BlockLayout) {
        let covered = Array(bytes[layout.sizeField.lowerBound..<layout.body.upperBound])
        let checksum = CRC32.checksum(covered)
        for index in 0..<4 {
            bytes[layout.offset + index] = UInt8(truncatingIfNeeded: checksum >> (index * 8))
        }
    }

    static func markFileUnpackedSizeUnknown(
        _ bytes: inout [UInt8],
        layout: BlockLayout
    ) throws {
        var cursor = layout.body.lowerBound
        guard try readVInt(bytes, offset: &cursor) == 2 else {
            throw ZipTestSupportError.fixture("RAR5 fixture block is not a file header")
        }
        let headerFlags = try readVInt(bytes, offset: &cursor)
        if headerFlags & 0x0001 != 0 { _ = try readVInt(bytes, offset: &cursor) }
        if headerFlags & 0x0002 != 0 { _ = try readVInt(bytes, offset: &cursor) }
        guard cursor < layout.body.upperBound else {
            throw ZipTestSupportError.fixture("RAR5 fixture file flags are missing")
        }

        // File flag 0x0008 makes the following unpacked-size vint advisory.
        // It lives in the low seven bits of the first vint byte, so setting it
        // cannot change the encoded field width or any subsequent offsets.
        bytes[cursor] |= 0x08
        repairHeaderCRC(&bytes, layout: layout)
    }

    static func deterministicPayload(count: Int, seed: UInt64) -> Data {
        var state = seed
        return Data((0..<count).map { index in
            state &+= 0x9e37_79b9_7f4a_7c15 &+ UInt64(index)
            state ^= state >> 30
            state &*= 0xbf58_476d_1ce4_e5b9
            state ^= state >> 27
            state &*= 0x94d0_49bb_1331_11eb
            state ^= state >> 31
            return UInt8(truncatingIfNeeded: state)
        })
    }

    private static func readVInt(_ bytes: [UInt8], offset: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<10 {
            guard offset < bytes.count else { throw KaitoError.truncated }
            let byte = bytes[offset]
            offset += 1
            let shift = index * 7
            if shift < 64 {
                let useful = min(7, 64 - shift)
                value |= (UInt64(byte & 0x7f) & ((UInt64(1) << useful) - 1)) << shift
            }
            if byte & 0x80 == 0 { return value }
        }
        throw KaitoError.malformed("test fixture vint exceeds 10 bytes")
    }

    private static func checkedIndex(
        _ offset: Int,
        adding count: UInt64,
        limit: Int
    ) throws -> Int {
        guard count <= UInt64(Int.max - offset) else { throw KaitoError.truncated }
        let result = offset + Int(count)
        guard result <= limit else { throw KaitoError.truncated }
        return result
    }

    private static func appendLittle(_ value: UInt32, to bytes: inout [UInt8]) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }
}
