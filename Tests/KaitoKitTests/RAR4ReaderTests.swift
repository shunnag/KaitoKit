import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

final class RAR4ReaderTests: XCTestCase {
    func testRAR29EmptySubordinateTablesAreAllowed() throws {
        for symbolCount in [60, 17, 28] {
            let table = RAR29HuffmanTable()
            let empty = [UInt8](repeating: 0, count: symbolCount)

            XCTAssertNoThrow(try table.build(empty[...], requireSymbol: false))
            XCTAssertThrowsError(try table.build(empty[...])) { error in
                XCTAssertEqual(
                    error as? KaitoError,
                    .malformed("RAR4 Huffman table is empty")
                )
            }
        }
    }

    func testRAR29PPMdFixtureDecodesWithSingleByteReads() throws {
        // Produced by the RAR 3.00 command-line encoder with `-m5 -mct`.
        // The committed representation is base64 so the generated binary
        // fixture remains reviewable and deterministic in a text-only patch.
        let fixtureURL = ZipTestSupport.repositoryRoot
            .appendingPathComponent("Tests/Fixtures/rar4/ppmd_lorem_rar300.rar.b64")
        let encoded = try String(contentsOf: fixtureURL, encoding: .utf8)
        let archive = try XCTUnwrap(
            Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
        )
        XCTAssertEqual(
            sha256Hex(archive),
            "2c263bf552de74d0a4d36142ae83fe44563a6fc18d1910b0ffcce3958aa24574"
        )

        let reader = try ArchiveReader.open(data: archive)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(reader.entries.count, 1)
        XCTAssertEqual(entry.uncompressedSize, 130_048)
        XCTAssertEqual(entry.methodDescription, "RAR4 best")
        XCTAssertEqual(entry.formatSpecific["unpackVersion"], "29")

        let stream = try reader.stream(entry)
        var decoded = Data()
        decoded.reserveCapacity(130_048)
        var byte: UInt8 = 0
        while stream.remaining > 0 {
            let count = try withUnsafeMutableBytes(of: &byte) {
                try stream.read(into: $0)
            }
            XCTAssertEqual(count, 1)
            decoded.append(byte)
        }
        XCTAssertEqual(decoded.count, 130_048)
        XCTAssertEqual(
            sha256Hex(decoded),
            "a434d9be88dd0f9d314776f4bca0f0022695c46d09a9c59e8c77c337f843fa92"
        )
    }

    func testRAR29MalformedPPMdHeadersFailBoundedlyAndStayTerminal() throws {
        func assertTerminalFailure(
            _ packed: [UInt8],
            limits: ReadLimits = ReadLimits(),
            expected: KaitoError,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            let decoder = try RAR29Decoder(
                source: DataByteSource(data: Data(packed)),
                offset: 0,
                compressedSize: UInt64(packed.count),
                uncompressedSize: 1,
                unpackVersion: 29,
                method: 0x31,
                dictionarySize: 64 * 1_024,
                isSolid: false,
                limits: limits
            )
            for _ in 0..<2 {
                var byte: UInt8 = 0
                XCTAssertThrowsError(
                    try withUnsafeMutableBytes(of: &byte) {
                        try decoder.read(into: $0)
                    },
                    file: file,
                    line: line
                ) { error in
                    XCTAssertEqual(error as? KaitoError, expected, file: file, line: line)
                }
            }
        }

        // Continuation before a reset, reset with encoded order one, and a
        // reset whose memory request exceeds the caller's model bound.
        try assertTerminalFailure(
            [0x80, 0, 0, 0, 0],
            expected: .malformed("RAR4 PPMd continuation has no model")
        )
        try assertTerminalFailure(
            [0xa0, 0, 0, 0, 0, 0],
            expected: .malformed("RAR4 PPMd order is outside 2...64")
        )
        var oneMiBLimits = ReadLimits()
        oneMiBLimits.maxDictionarySize = 1 * 1_024 * 1_024
        try assertTerminalFailure(
            [0xa1, 1, 0, 0, 0, 0],
            limits: oneMiBLimits,
            expected: .limitExceeded("size 2097152 exceeds limit 1048576")
        )
        try assertTerminalFailure(
            [0xa1, 0, 0, 0, 0],
            expected: .truncated
        )
    }

    func testRAR29SolidLZCoordinatorSupportsSeekingAndReopen() throws {
        // RAR 3.00 `-s` fixture reduced to its first two members.  The second
        // packed stream is only three bytes and depends on the first member's
        // window, repeat state and Huffman end-marker reuse policy.
        let archive = try base64Fixture("solid_lz_rar300.rar.b64")
        XCTAssertEqual(
            sha256Hex(archive),
            "a2771b950416d3df441de579b76646d203fe75eb176536c2b8fb8e67a235a0ed"
        )
        let expected = [
            "71c66fb47aa972a496cce5ea8be77f28ceb6733a7687d3247472350dec3b0120",
            "62de6306211cb0e6bd25c6fa452659e65f759b01fce630d027f5b781b14bd858",
        ]

        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(reader.entries.map(\.solidGroup), [0, 0])
        for index in [1, 0, 1, 0] {
            XCTAssertEqual(sha256Hex(try reader.read(reader.entries[index])), expected[index])
        }

        let overlapping = try ArchiveReader.open(data: archive)
        let abandoned = try overlapping.stream(overlapping.entries[0])
        var prefix = Data(count: 7)
        let prefixCount = try prefix.withUnsafeMutableBytes {
            try abandoned.read(into: $0)
        }
        XCTAssertEqual(prefixCount, prefix.count)
        XCTAssertEqual(
            sha256Hex(try overlapping.read(overlapping.entries[1])),
            expected[1]
        )
        var staleByte: UInt8 = 0
        XCTAssertThrowsError(
            try withUnsafeMutableBytes(of: &staleByte) {
                try abandoned.read(into: $0)
            }
        ) { error in
            guard case let .malformed(reason) = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("invalidated this stream"), reason)
        }

        let independent = try ArchiveReader.open(data: archive)
        let originalStream = try independent.stream(independent.entries[0])
        var original = Data(count: 5)
        _ = try original.withUnsafeMutableBytes { try originalStream.read(into: $0) }
        let reopened = try independent.reopen()
        XCTAssertEqual(
            sha256Hex(try reopened.read(reopened.entries[1])),
            expected[1]
        )
        original.append(try originalStream.readAll())
        XCTAssertEqual(sha256Hex(original), expected[0])

        // The returned stream owns the coordinator, immutable records and
        // packed sources it needs; it must not depend on the reader's lifetime.
        let detachedStream: EntryStream
        do {
            let shortLivedReader = try ArchiveReader.open(data: archive)
            detachedStream = try shortLivedReader.stream(shortLivedReader.entries[1])
        }
        XCTAssertEqual(sha256Hex(try detachedStream.readAll()), expected[1])
    }

    func testRAR29SolidPPMdModelPersistsWhenFixtureIsAvailable() throws {
        let url = URL(
            fileURLWithPath: "/private/tmp/claude-501/-Users-nagash-cooViewer/37ef55f3-9116-4440-88b8-9a15060856ad/scratchpad/rarppmd/ppmd_solid_rar300.rar"
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("RAR3 solid PPMd fixture is absent")
        }
        let expected = [
            "5fd15ccd2fd256f2491c20c6736c6634907004b6a7b4415036885e469b457a44",
            "49252795557688b56e90755d0e8bc17e633d4c1f3bb8a7c5b9716d1abe23a1fd",
        ]
        let reader = try ArchiveReader.open(url: url)
        XCTAssertEqual(reader.entries.map(\.solidGroup), [0, 0])
        for index in [1, 0, 1] {
            XCTAssertEqual(sha256Hex(try reader.read(reader.entries[index])), expected[index])
        }
    }

    func testRAR29EncryptedSolidCorpusWhenAvailable() throws {
        let directory = URL(
            fileURLWithPath: "/private/tmp/claude-501/-Users-nagash-cooViewer/37ef55f3-9116-4440-88b8-9a15060856ad/scratchpad/rar4-corpus",
            isDirectory: true
        )
        let names = [
            "test_read_format_rar4_solid_encrypted.rar",
            "test_read_format_rar4_solid_encrypted_filenames.rar",
        ]
        guard names.allSatisfy({
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent($0).path
            )
        }) else {
            throw XCTSkip("libarchive RAR4 encrypted-solid fixtures are absent")
        }
        let expected = [
            "02dc86d8b326a1cd07526f75b66bb7207c43376b21d9ac2c20bfedf510898861",
            "7ff61dd11ab812fc7f28f4f3b2e2ddf482148942a10ee079ac19295076ff741e",
            "0b8a3f12dc4e493b99fb5e0699c96006b51b05c0461c2e048f25d86a50a58eb8",
            "7e57320eb71e376207695ee851ed2f339cb2000fa3359a19de4c494b472699e1",
        ]

        for name in names {
            let reader = try ArchiveReader.open(
                url: directory.appendingPathComponent(name),
                options: ReaderOptions(password: "password")
            )
            XCTAssertEqual(reader.entries.map(\.solidGroup), [0, 0, 0, 0])
            for index in [3, 1, 0, 2] {
                XCTAssertEqual(
                    sha256Hex(try reader.read(reader.entries[index])),
                    expected[index],
                    name
                )
            }
        }
    }

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

    func testRealRAR29FiltersAndTableTransitionsMatchRAR723WhenAvailable() throws {
        let url = URL(fileURLWithPath: "/Users/nagash/Downloads/st1200-pts.rar")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("RAR4 oracle archive is absent")
        }
        try RAR5TestSupport.requireRAR()
        let reader = try RAR4Reader(
            source: FileByteSource(url: url),
            options: ReaderOptions()
        )
        let files = reader.entries.filter { $0.kind != .directory }
        XCTAssertEqual(files.count, 19)

        for entry in files {
            let decoded = try reader.stream(
                for: entry,
                limits: ReadLimits()
            ).readAll()
            let oracle = try ZipTestSupport.checkedRun(
                RAR5TestSupport.executablePath,
                arguments: ["p", "-inul", url.path, entry.name]
            ).standardOutput
            XCTAssertEqual(
                decoded.count,
                Int(try XCTUnwrap(entry.uncompressedSize))
            )
            XCTAssertTrue(
                SHA256.hash(data: decoded).elementsEqual(SHA256.hash(data: oracle)),
                "\(entry.index):\(entry.name)"
            )
        }
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

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func base64Fixture(_ name: String) throws -> Data {
        let url = ZipTestSupport.repositoryRoot
            .appendingPathComponent("Tests/Fixtures/rar4", isDirectory: true)
            .appendingPathComponent(name)
        let encoded = try String(contentsOf: url, encoding: .utf8)
        return try XCTUnwrap(
            Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
        )
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
