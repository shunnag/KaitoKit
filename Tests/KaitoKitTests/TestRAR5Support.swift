import Foundation
@testable import KaitoKit
import XCTest

enum RAR5TestSupport {
    static let executablePath = resolveRARExecutablePath()

    struct BlockLayout {
        let offset: Int
        let sizeField: Range<Int>
        let body: Range<Int>
        let data: Range<Int>
    }

    private static func resolveRARExecutablePath() -> String {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["KAITOKIT_RAR_EXECUTABLE"],
           !configured.isEmpty {
            return configured
        }
        if let path = environment["PATH"] {
            for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
                let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                    .appendingPathComponent("rar").path
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        for candidate in ["/opt/homebrew/bin/rar", "/usr/local/bin/rar"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "/opt/homebrew/bin/rar"
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
        attributes: UInt64 = 0,
        fileFlags additionalFileFlags: UInt64 = 0,
        compressionInfo: UInt64 = 0,
        extra: [UInt8] = [],
        headerFlags: UInt64 = 0
    ) -> Data {
        let fileFlags = additionalFileFlags | (includeCRC32 ? 0x0004 : 0)
        var specific = vint(fileFlags)
        specific += vint(unpackedSize ?? UInt64(contents.count))
        specific += vint(attributes)
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
        attributes: UInt64 = 0,
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
            attributes: attributes,
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

    static func fileEncryptionCheckRange(
        in bytes: [UInt8],
        layout: BlockLayout
    ) throws -> Range<Int>? {
        var cursor = layout.body.lowerBound
        guard try readVInt(bytes, offset: &cursor) == 2 else {
            throw ZipTestSupportError.fixture("RAR5 fixture block is not a file header")
        }
        let headerFlags = try readVInt(bytes, offset: &cursor)
        let extraSize = headerFlags & 0x0001 != 0
            ? try readVInt(bytes, offset: &cursor)
            : 0
        if headerFlags & 0x0002 != 0 {
            _ = try readVInt(bytes, offset: &cursor)
        }

        let fileFlags = try readVInt(bytes, offset: &cursor)
        _ = try readVInt(bytes, offset: &cursor) // unpacked size
        _ = try readVInt(bytes, offset: &cursor) // attributes
        if fileFlags & 0x0004 != 0 {
            cursor = try checkedIndex(cursor, adding: 4, limit: layout.body.upperBound)
        }
        _ = try readVInt(bytes, offset: &cursor) // compression info
        _ = try readVInt(bytes, offset: &cursor) // host OS
        let nameSize = try readVInt(bytes, offset: &cursor)
        cursor = try checkedIndex(cursor, adding: nameSize, limit: layout.body.upperBound)
        let extrasEnd = try checkedIndex(
            cursor,
            adding: extraSize,
            limit: layout.body.upperBound
        )

        while cursor < extrasEnd {
            let recordSize = try readVInt(bytes, offset: &cursor)
            let recordEnd = try checkedIndex(cursor, adding: recordSize, limit: extrasEnd)
            let type = try readVInt(bytes, offset: &cursor)
            if type == 1 {
                _ = try readVInt(bytes, offset: &cursor) // version
                let flags = try readVInt(bytes, offset: &cursor)
                cursor = try checkedIndex(cursor, adding: 33, limit: recordEnd)
                if flags & 0x0001 == 0 { return nil }
                let end = try checkedIndex(cursor, adding: 12, limit: recordEnd)
                return cursor..<end
            }
            cursor = recordEnd
        }
        return nil
    }

    /// Removes the optional twelve-byte verifier from a generated file
    /// encryption record while keeping every surrounding vint at its original
    /// width. Returning the shifted layout lets callers continue to mutate the
    /// same block if needed.
    @discardableResult
    static func removeFileEncryptionCheck(
        _ bytes: inout [UInt8],
        layout: BlockLayout
    ) throws -> BlockLayout {
        var headerSizeCursor = layout.sizeField.lowerBound
        let headerSize = try readVInt(bytes, offset: &headerSizeCursor)
        guard headerSizeCursor == layout.sizeField.upperBound,
              headerSize == UInt64(layout.body.count) else {
            throw ZipTestSupportError.fixture("RAR5 fixture header layout is inconsistent")
        }

        var cursor = layout.body.lowerBound
        guard try readVInt(bytes, offset: &cursor) == 2 else {
            throw ZipTestSupportError.fixture("RAR5 fixture block is not a file header")
        }
        let headerFlags = try readVInt(bytes, offset: &cursor)
        guard headerFlags & 0x0001 != 0 else {
            throw ZipTestSupportError.fixture("RAR5 fixture file header has no extra area")
        }
        let extraSizeStart = cursor
        let extraSize = try readVInt(bytes, offset: &cursor)
        let extraSizeField = extraSizeStart..<cursor
        if headerFlags & 0x0002 != 0 {
            _ = try readVInt(bytes, offset: &cursor)
        }

        let fileFlags = try readVInt(bytes, offset: &cursor)
        _ = try readVInt(bytes, offset: &cursor) // unpacked size
        _ = try readVInt(bytes, offset: &cursor) // attributes
        if fileFlags & 0x0002 != 0 {
            cursor = try checkedIndex(cursor, adding: 4, limit: layout.body.upperBound)
        }
        if fileFlags & 0x0004 != 0 {
            cursor = try checkedIndex(cursor, adding: 4, limit: layout.body.upperBound)
        }
        _ = try readVInt(bytes, offset: &cursor) // compression info
        _ = try readVInt(bytes, offset: &cursor) // host OS
        let nameSize = try readVInt(bytes, offset: &cursor)
        cursor = try checkedIndex(cursor, adding: nameSize, limit: layout.body.upperBound)
        let extrasEnd = try checkedIndex(
            cursor,
            adding: extraSize,
            limit: layout.body.upperBound
        )

        while cursor < extrasEnd {
            let recordSizeStart = cursor
            let recordSize = try readVInt(bytes, offset: &cursor)
            let recordSizeField = recordSizeStart..<cursor
            let recordEnd = try checkedIndex(cursor, adding: recordSize, limit: extrasEnd)
            let type = try readVInt(bytes, offset: &cursor)
            guard type == 1 else {
                cursor = recordEnd
                continue
            }

            _ = try readVInt(bytes, offset: &cursor) // version
            let encryptionFlagsStart = cursor
            let encryptionFlags = try readVInt(bytes, offset: &cursor)
            let encryptionFlagsField = encryptionFlagsStart..<cursor
            guard encryptionFlags & 0x0001 != 0 else {
                throw ZipTestSupportError.fixture(
                    "RAR5 fixture file encryption record has no password check"
                )
            }
            cursor = try checkedIndex(cursor, adding: 1 + 16 + 16, limit: recordEnd)
            let checkEnd = try checkedIndex(cursor, adding: 12, limit: recordEnd)
            let check = cursor..<checkEnd

            try writeVInt(
                encryptionFlags & ~UInt64(0x0001),
                into: encryptionFlagsField,
                bytes: &bytes
            )
            try writeVInt(recordSize - 12, into: recordSizeField, bytes: &bytes)
            try writeVInt(extraSize - 12, into: extraSizeField, bytes: &bytes)
            try writeVInt(headerSize - 12, into: layout.sizeField, bytes: &bytes)
            bytes.removeSubrange(check)

            let result = BlockLayout(
                offset: layout.offset,
                sizeField: layout.sizeField,
                body: layout.body.lowerBound..<(layout.body.upperBound - 12),
                data: (layout.data.lowerBound - 12)..<(layout.data.upperBound - 12)
            )
            repairHeaderCRC(&bytes, layout: result)
            return result
        }
        throw ZipTestSupportError.fixture(
            "RAR5 fixture file header has no encryption record"
        )
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

    private static func writeVInt(
        _ suppliedValue: UInt64,
        into range: Range<Int>,
        bytes: inout [UInt8]
    ) throws {
        guard !range.isEmpty, range.upperBound <= bytes.count else {
            throw ZipTestSupportError.fixture("RAR5 fixture vint range is invalid")
        }
        var value = suppliedValue
        for (offset, index) in range.enumerated() {
            let isLast = offset == range.count - 1
            bytes[index] = UInt8(value & 0x7f) | (isLast ? 0 : 0x80)
            value >>= 7
        }
        guard value == 0 else {
            throw ZipTestSupportError.fixture("RAR5 fixture vint no longer fits its field")
        }
    }

    private static func appendLittle(_ value: UInt32, to bytes: inout [UInt8]) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }
}
