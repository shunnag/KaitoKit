import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

final class RAR4ReaderTests: XCTestCase {
    func testStoredFileListsAndStreamsWithCRC() throws {
        let contents = Data("stored RAR4 payload".utf8)
        let archive = makeArchive(files: [
            FileFixture(name: Array("folder\\payload.txt".utf8), contents: contents),
        ])
        let reader = try RAR4Reader(
            source: DataByteSource(data: archive),
            options: ReaderOptions()
        )

        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.name, "folder/payload.txt")
        XCTAssertEqual(entry.pathComponents, ["folder", "payload.txt"])
        XCTAssertEqual(entry.kind, .file)
        XCTAssertEqual(entry.uncompressedSize, UInt64(contents.count))
        XCTAssertEqual(entry.methodDescription, "stored")
        XCTAssertEqual(
            try reader.stream(for: entry, limits: ReadLimits()).readAll(),
            contents
        )
    }

    func testStoredPayloadCRCMismatchIsRejectedAtEndOfRead() throws {
        let fixture = FileFixture(
            name: Array("corrupt.txt".utf8),
            contents: Data("original stored payload".utf8)
        )
        var archive = Data(RAR4Reader.signature)
        archive.append(contentsOf: makeMainHeader())
        archive.append(contentsOf: makeFileHeader(fixture))
        let payloadOffset = archive.count
        archive.append(fixture.contents)
        archive.append(contentsOf: makeHeader(type: 0x7b, flags: 0, fields: []))
        archive[payloadOffset] ^= 0x01

        let reader = try RAR4Reader(
            source: DataByteSource(data: archive),
            options: ReaderOptions()
        )
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertThrowsError(
            try reader.stream(for: entry, limits: ReadLimits()).readAll()
        ) { error in
            XCTAssertEqual(error as? KaitoError, .checksumMismatch(entry: 0))
        }
    }

    func testCompressedUnicodeNameDecodesAllFourFlagSlots() throws {
        // Fallback "??\\a.txt", then HighByte 0 and two interleaved flag
        // groups. Modes are [2,2,0,0] and [0,0,0,0].
        let encodedName: [UInt8] = Array("??\\a.txt".utf8) + [
            0x00, 0x00,
            0xa0, 0xe5, 0x65, 0x2c, 0x67, 0x5c, 0x61,
            0x00, 0x2e, 0x74, 0x78, 0x74,
        ]
        let archive = makeArchive(files: [
            FileFixture(
                name: encodedName,
                contents: Data("x".utf8),
                flags: 0x0200
            ),
        ])
        let reader = try RAR4Reader(
            source: DataByteSource(data: archive),
            options: ReaderOptions()
        )

        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.name, "日本/a.txt")
        XCTAssertEqual(entry.rawName.bytes, encodedName)
        XCTAssertEqual(entry.formatSpecific["nameSource"], "unicode")
    }

    func testMalformedCompressedUnicodeFallsBackToLegacyName() throws {
        let malformed = Array("fallback.txt".utf8) + [0, 0, 0x80, 0x41]
        let archive = makeArchive(files: [
            FileFixture(name: malformed, contents: Data(), flags: 0x0200),
        ])
        let reader = try RAR4Reader(
            source: DataByteSource(data: archive),
            options: ReaderOptions(encodingPolicy: .utf8Only)
        )
        XCTAssertEqual(reader.entries.first?.name, "fallback.txt")
        XCTAssertEqual(reader.entries.first?.formatSpecific["nameSource"], "legacy")
    }

    func testExtractionIrrelevantSubheaderIsSkippedByBoundedSize() throws {
        var archive = Data(RAR4Reader.signature)
        archive.append(contentsOf: makeMainHeader())
        archive.append(contentsOf: makeHeader(type: 0x75, flags: 0, fields: [1, 2, 3]))
        let fixture = FileFixture(
            name: Array("after.txt".utf8),
            contents: Data("after".utf8)
        )
        archive.append(contentsOf: makeFileHeader(fixture))
        archive.append(fixture.contents)
        archive.append(contentsOf: makeHeader(type: 0x7b, flags: 0, fields: []))

        let reader = try RAR4Reader(
            source: DataByteSource(data: archive),
            options: ReaderOptions()
        )
        XCTAssertEqual(reader.entries.map(\.name), ["after.txt"])
    }

    func testUnknownSkipIfUnknownBlockIsBoundedlySkipped() throws {
        var archive = Data(RAR4Reader.signature)
        archive.append(contentsOf: makeMainHeader())

        let opaqueData = Data([0xde, 0xad, 0xbe, 0xef])
        var unknownFields: [UInt8] = []
        appendLittle(UInt32(opaqueData.count), to: &unknownFields)
        unknownFields.append(contentsOf: [0x12, 0x34])
        archive.append(contentsOf: makeHeader(
            type: 0x7c,
            flags: 0x4000 | 0x8000,
            fields: unknownFields
        ))
        archive.append(opaqueData)

        let contents = Data("stored after unknown block".utf8)
        let fixture = FileFixture(name: Array("after-unknown.txt".utf8), contents: contents)
        archive.append(contentsOf: makeFileHeader(fixture))
        archive.append(contents)
        archive.append(contentsOf: makeHeader(type: 0x7b, flags: 0, fields: []))

        let reader = try RAR4Reader(
            source: DataByteSource(data: archive),
            options: ReaderOptions()
        )
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(reader.entries.map(\.name), ["after-unknown.txt"])
        XCTAssertEqual(
            try reader.stream(for: entry, limits: ReadLimits()).readAll(),
            contents
        )
    }

    func testRAR29PackedInputLimitIsCheckedBeforeReadingSource() throws {
        let source = RAR4ReadTrackingByteSource(length: 2)
        var limits = ReadLimits()
        limits.maxEntrySize = 1

        XCTAssertThrowsError(
            try RAR29Decoder(
                source: source,
                offset: 0,
                compressedSize: 2,
                uncompressedSize: 1,
                unpackVersion: 29,
                method: 0x31,
                dictionarySize: 64 * 1_024,
                isSolid: false,
                limits: limits
            )
        ) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .limitExceeded("size 2 exceeds limit 1")
            )
        }
        XCTAssertEqual(source.readCount, 0)
    }

    func testHeaderCRCMismatchIsRejectedAtOpen() throws {
        var bytes = [UInt8](makeArchive(files: [
            FileFixture(name: Array("a".utf8), contents: Data("x".utf8)),
        ]))
        bytes[7] ^= 0x01
        XCTAssertThrowsError(
            try RAR4Reader(
                source: DataByteSource(data: Data(bytes)),
                options: ReaderOptions()
            )
        ) { error in
            guard case let .malformed(reason) = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("header CRC"), reason)
        }
    }

    func testZeroHeaderSizeCannotPreventForwardProgress() throws {
        var archive = Data(RAR4Reader.signature)
        let body: [UInt8] = [0x73, 0, 0, 0, 0]
        appendLittle(UInt16(truncatingIfNeeded: CRC32.checksum(body)), to: &archive)
        archive.append(contentsOf: body)

        XCTAssertThrowsError(
            try RAR4Reader(
                source: DataByteSource(data: archive),
                options: ReaderOptions()
            )
        ) { error in
            guard case let .malformed(reason) = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("header size"), reason)
        }
    }

    func testEndHeaderAdditionalSizeIsPhysicallyBounded() throws {
        var archive = Data(RAR4Reader.signature)
        archive.append(contentsOf: makeMainHeader())
        archive.append(contentsOf: makeHeader(
            type: 0x7b,
            flags: 0x8000,
            fields: [1, 0, 0, 0]
        ))

        XCTAssertThrowsError(
            try RAR4Reader(
                source: DataByteSource(data: archive),
                options: ReaderOptions()
            )
        ) { error in
            guard case .truncated = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testSolidGroupsFollowFileContinuationsAndExcludeDirectories() throws {
        let archive = makeArchive(
            files: [
                FileFixture(name: Array("a".utf8), contents: Data("a".utf8)),
                FileFixture(name: Array("folder".utf8), contents: Data(), flags: 0x00e0),
                FileFixture(name: Array("b".utf8), contents: Data("b".utf8), flags: 0x0010),
                FileFixture(name: Array("c".utf8), contents: Data("c".utf8)),
                FileFixture(name: Array("d".utf8), contents: Data("d".utf8), flags: 0x0010),
            ],
            mainFlags: 0x0008
        )
        let reader = try RAR4Reader(
            source: DataByteSource(data: archive),
            options: ReaderOptions()
        )

        XCTAssertEqual(reader.entries.map(\.solidGroup), [0, -1, 0, 3, 3])
        XCTAssertEqual(reader.entries[1].kind, .directory)
    }

    func testRealRAR4HeadersParseWhenOracleArchiveExists() throws {
        let url = URL(fileURLWithPath: "/Users/nagash/Downloads/st1200-pts.rar")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("RAR4 oracle archive is absent")
        }
        let reader = try RAR4Reader(
            source: FileByteSource(url: url),
            options: ReaderOptions()
        )
        XCTAssertFalse(reader.entries.isEmpty)
        XCTAssertTrue(reader.entries.allSatisfy { !$0.name.isEmpty })
    }

    func testAdditionalRAR4FixturesMatchBlackBoxOracleWhenPresent() throws {
        let fixtureDirectory = ZipTestSupport.repositoryRoot
            .appendingPathComponent("Tests/Fixtures/rar4", isDirectory: true)
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: fixtureDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension.lowercased() == "rar" }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        } ?? []
        guard !candidates.isEmpty else {
            throw XCTSkip(
                "no additional RAR4 fixtures in Tests/Fixtures/rar4; differential skipped"
            )
        }
        try RAR5TestSupport.requireRAR()

        for archiveURL in candidates {
            let reader = try ArchiveReader.open(url: archiveURL)
            for entry in reader.entries where entry.kind != .directory {
                let decoded = try reader.read(entry)
                let oracle = try ZipTestSupport.checkedRun(
                    RAR5TestSupport.executablePath,
                    arguments: ["p", "-inul", archiveURL.path, entry.name]
                ).standardOutput
                XCTAssertTrue(
                    SHA256.hash(data: decoded).elementsEqual(SHA256.hash(data: oracle)),
                    "\(archiveURL.lastPathComponent):\(entry.index):\(entry.name)"
                )
            }
        }
    }

    func testOneHundredTwentyEightDeterministicMutantsDoNotCrashOrHang() throws {
        let original = [UInt8](makeArchive(files: [
            FileFixture(
                name: Array("mutant.txt".utf8),
                contents: Data("bounded mutation payload".utf8)
            ),
        ]))
        var limits = ReadLimits()
        limits.maxEntrySize = 1 * 1_024 * 1_024
        limits.maxInMemorySize = 1 * 1_024 * 1_024
        limits.maxMetadataSize = 64 * 1_024
        limits.maxTotalMetadataSize = 128 * 1_024
        limits.maxDictionarySize = 1 * 1_024 * 1_024
        let options = ReaderOptions(limits: limits)
        var state: UInt64 = 0x4b61_6974_6f52_4152
        var executed = 0

        for mutation in 0..<128 {
            var bytes = original
            let editCount = 1 + mutation % 3
            for _ in 0..<editCount {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                let position = Int(state % UInt64(bytes.count))
                state = state &* 6_364_136_223_846_793_005 &+ 1
                bytes[position] ^= UInt8(truncatingIfNeeded: state >> 32) | 1
            }

            do {
                let reader = try RAR4Reader(
                    source: DataByteSource(data: Data(bytes)),
                    options: options
                )
                for entry in reader.entries {
                    _ = try? reader.stream(for: entry, limits: limits).readAll()
                }
            } catch {
                // Structured rejection is the expected outcome for most cases.
            }
            executed += 1
        }
        XCTAssertEqual(executed, 128)
    }

    private struct FileFixture {
        let name: [UInt8]
        let contents: Data
        let flags: UInt16

        init(name: [UInt8], contents: Data, flags: UInt16 = 0) {
            self.name = name
            self.contents = contents
            self.flags = flags
        }
    }

    private func makeArchive(
        files: [FileFixture],
        mainFlags: UInt16 = 0
    ) -> Data {
        var archive = Data(RAR4Reader.signature)
        archive.append(contentsOf: makeMainHeader(flags: mainFlags))
        for file in files {
            archive.append(contentsOf: makeFileHeader(file))
            archive.append(file.contents)
        }
        archive.append(contentsOf: makeHeader(type: 0x7b, flags: 0, fields: []))
        return archive
    }

    private func makeMainHeader(flags: UInt16 = 0) -> [UInt8] {
        makeHeader(type: 0x73, flags: flags, fields: [0, 0, 0, 0, 0, 0])
    }

    private func makeFileHeader(_ file: FileFixture) -> [UInt8] {
        let crc = CRC32.checksum(file.contents)
        var fields: [UInt8] = []
        appendLittle(UInt32(file.contents.count), to: &fields)
        appendLittle(UInt32(file.contents.count), to: &fields)
        fields.append(2) // Windows
        appendLittle(crc, to: &fields)
        appendLittle(UInt32(0), to: &fields) // no DOS timestamp
        fields.append(29)
        fields.append(0x30)
        appendLittle(UInt16(file.name.count), to: &fields)
        appendLittle(UInt32(0x20), to: &fields)
        fields.append(contentsOf: file.name)
        return makeHeader(
            type: 0x74,
            flags: file.flags | 0x8000,
            fields: fields
        )
    }

    private func makeHeader(
        type: UInt8,
        flags: UInt16,
        fields: [UInt8]
    ) -> [UInt8] {
        var body: [UInt8] = [type]
        appendLittle(flags, to: &body)
        appendLittle(UInt16(7 + fields.count), to: &body)
        body.append(contentsOf: fields)
        var result: [UInt8] = []
        appendLittle(UInt16(truncatingIfNeeded: CRC32.checksum(body)), to: &result)
        result.append(contentsOf: body)
        return result
    }

    private func appendLittle<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private func appendLittle<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
    }
}

private final class RAR4ReadTrackingByteSource: ByteSource, @unchecked Sendable {
    let length: UInt64

    private let lock = NSLock()
    private var reads = 0

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    init(length: UInt64) {
        self.length = length
    }

    func read(
        into buffer: UnsafeMutableRawBufferPointer,
        at offset: UInt64
    ) throws -> Int {
        lock.lock()
        reads += 1
        lock.unlock()
        return 0
    }
}
