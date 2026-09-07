import Foundation
@testable import KaitoKit
import XCTest

final class SevenZipHardeningTests: XCTestCase {
    private static let signature: [UInt8] = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]

    func testTruncatedFixedAndNextHeadersAreRejected() throws {
        let valid = makeArchive(nextHeader: [SevenZipNID.header.rawValue, SevenZipNID.end.rawValue])
        XCTAssertNoThrow(try ArchiveReader.open(data: valid))

        let truncatedFixed = Data(valid.prefix(31))
        XCTAssertThrowsError(try ArchiveReader.open(data: truncatedFixed)) { error in
            XCTAssertEqual(error as? KaitoError, .truncated)
        }

        let truncatedNext = Data(valid.dropLast())
        XCTAssertThrowsError(try ArchiveReader.open(data: truncatedNext)) { error in
            guard case let .malformed(reason) = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("past end"), reason)
        }
    }

    func testNextHeaderCRCMismatchIsRejected() throws {
        let header: [UInt8] = [SevenZipNID.header.rawValue, SevenZipNID.end.rawValue]
        let incorrectCRC = CRC32.checksum(header) ^ 0xA5A5_A5A5
        let archive = makeArchive(nextHeader: header, recordedNextCRC: incorrectCRC)

        XCTAssertThrowsError(try ArchiveReader.open(data: archive)) { error in
            guard case let .malformed(reason) = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("next-header CRC"), reason)
        }
    }

    func testPackedStreamCannotOverlapNextHeader() throws {
        let header: [UInt8] = [
            SevenZipNID.header.rawValue,
            SevenZipNID.mainStreamsInfo.rawValue,
            SevenZipNID.packInfo.rawValue,
            1, // PackPos: points at the first byte of this next header
            1, // NumPackStreams
            SevenZipNID.size.rawValue,
            1,
            SevenZipNID.end.rawValue,
            SevenZipNID.unpackInfo.rawValue,
            SevenZipNID.folder.rawValue,
            1, // NumFolders
            0, // inline folders
            1, // NumCoders
            1, 0, // one Copy coder
            SevenZipNID.codersUnpackSize.rawValue,
            1,
            SevenZipNID.end.rawValue,
            SevenZipNID.end.rawValue, // MainStreamsInfo
            SevenZipNID.filesInfo.rawValue,
            1, // NumFiles
            SevenZipNID.name.rawValue,
            5, // inline flag plus UTF-16LE "a" and terminator
            0, 0x61, 0, 0, 0,
            SevenZipNID.end.rawValue,
            SevenZipNID.end.rawValue,
        ]
        let archive = makeArchive(packedData: [0x58], nextHeader: header)

        XCTAssertThrowsError(try ArchiveReader.open(data: archive)) { error in
            guard case let .malformed(reason) = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("overlaps the next header"), reason)
        }
    }

    func testDeclaredPackedStreamCRCIsVerifiedLazily() throws {
        let packed: [UInt8] = [0x58]
        let expectedCRC = CRC32.checksum(packed)
        func header(packCRC: UInt32) -> [UInt8] {
            var bytes: [UInt8] = [
                SevenZipNID.header.rawValue,
                SevenZipNID.mainStreamsInfo.rawValue,
                SevenZipNID.packInfo.rawValue,
                0, // PackPos
                1, // NumPackStreams
                SevenZipNID.size.rawValue,
                1,
                SevenZipNID.crc.rawValue,
                1, // all defined
            ]
            appendLittleEndian(packCRC, to: &bytes)
            bytes.append(contentsOf: [
                SevenZipNID.end.rawValue,
                SevenZipNID.unpackInfo.rawValue,
                SevenZipNID.folder.rawValue,
                1, 0, // one inline folder
                1, 1, 0, // one Copy coder
                SevenZipNID.codersUnpackSize.rawValue,
                1,
                SevenZipNID.end.rawValue,
                SevenZipNID.end.rawValue,
                SevenZipNID.filesInfo.rawValue,
                1,
                SevenZipNID.name.rawValue,
                5, 0, 0x61, 0, 0, 0,
                SevenZipNID.end.rawValue,
                SevenZipNID.end.rawValue,
            ])
            return bytes
        }

        let valid = try ArchiveReader.open(
            data: makeArchive(packedData: packed, nextHeader: header(packCRC: expectedCRC))
        )
        XCTAssertEqual(try valid.read(XCTUnwrap(valid.entries.first)), Data(packed))

        let corrupt = try ArchiveReader.open(
            data: makeArchive(
                packedData: packed,
                nextHeader: header(packCRC: expectedCRC ^ UInt32.max)
            )
        )
        XCTAssertThrowsError(try corrupt.read(XCTUnwrap(corrupt.entries.first))) { error in
            XCTAssertEqual(error as? KaitoError, .checksumMismatch(entry: -1))
        }
    }

    func testEncryptedEncodedHeaderStructuralFailureIsWrongPassword() throws {
        // AES-256-CBC of [kHeader, kEnd] plus zero padding. 7zAES direct-key
        // mode makes password "p" the UTF-16LE key prefix, padded with zeros.
        let ciphertext: [UInt8] = [
            0x62, 0x21, 0x7B, 0x33, 0x8E, 0x3E, 0x7C, 0x39,
            0x90, 0x2D, 0x3D, 0x15, 0x8E, 0xAA, 0x49, 0x51,
        ]
        let encodedHeader: [UInt8] = [
            SevenZipNID.encodedHeader.rawValue,
            SevenZipNID.packInfo.rawValue,
            0, // PackPos
            1, // NumPackStreams
            SevenZipNID.size.rawValue,
            16,
            SevenZipNID.end.rawValue,
            SevenZipNID.unpackInfo.rawValue,
            SevenZipNID.folder.rawValue,
            1, // NumFolders
            0, // inline folders
            1, // NumCoders
            0x24, 0x06, 0xF1, 0x07, 0x01, // AES coder with properties
            1, 0x3F, // direct-key mode
            SevenZipNID.codersUnpackSize.rawValue,
            2,
            SevenZipNID.end.rawValue,
            SevenZipNID.end.rawValue,
        ]
        let archive = makeArchive(packedData: ciphertext, nextHeader: encodedHeader)

        XCTAssertNoThrow(
            try ArchiveReader.open(data: archive, options: ReaderOptions(password: "p"))
        )
        XCTAssertThrowsError(try ArchiveReader.open(data: archive)) { error in
            XCTAssertEqual(error as? KaitoError, .passwordRequired)
        }
        XCTAssertThrowsError(
            try ArchiveReader.open(data: archive, options: ReaderOptions(password: "q"))
        ) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }
    }

    func testEmptyPackInfoMayOmitOptionalSizeProperty() throws {
        let header: [UInt8] = [
            SevenZipNID.header.rawValue,
            SevenZipNID.mainStreamsInfo.rawValue,
            SevenZipNID.packInfo.rawValue,
            0, // PackPos
            0, // NumPackStreams
            SevenZipNID.end.rawValue, // PackInfo
            SevenZipNID.end.rawValue, // MainStreamsInfo
            SevenZipNID.end.rawValue, // Header
        ]
        let reader = try ArchiveReader.open(data: makeArchive(nextHeader: header))
        XCTAssertEqual(reader.format, .sevenZip)
        XCTAssertTrue(reader.entries.isEmpty)
    }

    func testDuplicateEmptyAdditionalStreamsInfoIsRejected() throws {
        let header: [UInt8] = [
            SevenZipNID.header.rawValue,
            SevenZipNID.additionalStreamsInfo.rawValue,
            SevenZipNID.end.rawValue,
            SevenZipNID.additionalStreamsInfo.rawValue,
            SevenZipNID.end.rawValue,
            SevenZipNID.end.rawValue,
        ]
        XCTAssertThrowsError(try ArchiveReader.open(data: makeArchive(nextHeader: header))) {
            error in
            guard case let .malformed(reason) = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("additional streams"), reason)
        }
    }

    func testEmptyFileMayPrecedeEmptyStreamProperty() throws {
        let header: [UInt8] = [
            SevenZipNID.header.rawValue,
            SevenZipNID.filesInfo.rawValue,
            1, // NumFiles
            SevenZipNID.emptyFile.rawValue,
            1, 0x80,
            SevenZipNID.emptyStream.rawValue,
            1, 0x80,
            SevenZipNID.name.rawValue,
            5, 0, 0x61, 0, 0, 0,
            SevenZipNID.end.rawValue,
            SevenZipNID.end.rawValue,
        ]
        let reader = try ArchiveReader.open(data: makeArchive(nextHeader: header))
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.name, "a")
        XCTAssertEqual(entry.kind, .file)
        XCTAssertEqual(try reader.read(entry), Data())
    }

    func testCreationTimePropertyIsExposed() throws {
        let seconds: UInt64 = 1_700_000_000
        let fileTime = (seconds + 11_644_473_600) * 10_000_000
        let header = makeSingleNoStreamHeader(properties: [
            (.creationTime, inlineDefinedUInt64(fileTime)),
        ])

        let reader = try ArchiveReader.open(data: makeArchive(nextHeader: header))
        let entry = try XCTUnwrap(reader.entries.first)
        let parsed = try XCTUnwrap(
            entry.formatSpecific["creationTime"].flatMap(Double.init)
        )
        XCTAssertEqual(parsed, Double(seconds), accuracy: 0.001)
        XCTAssertNil(entry.modificationDate)
    }

    func testAccessTimePropertyIsExposed() throws {
        let seconds: UInt64 = 1_700_000_123
        let fileTime = (seconds + 11_644_473_600) * 10_000_000
        let header = makeSingleNoStreamHeader(properties: [
            (.accessTime, inlineDefinedUInt64(fileTime)),
        ])

        let reader = try ArchiveReader.open(data: makeArchive(nextHeader: header))
        let entry = try XCTUnwrap(reader.entries.first)
        let parsed = try XCTUnwrap(
            entry.formatSpecific["accessTime"].flatMap(Double.init)
        )
        XCTAssertEqual(parsed, Double(seconds), accuracy: 0.001)
        XCTAssertNil(entry.modificationDate)
    }

    func testStartPositionPropertyIsExposedWithoutTruncation() throws {
        let startPosition: UInt64 = 0x1_0000_002A
        let header = makeSingleNoStreamHeader(properties: [
            (.startPosition, inlineDefinedUInt64(startPosition)),
        ])

        let reader = try ArchiveReader.open(data: makeArchive(nextHeader: header))
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(
            entry.formatSpecific["startPosition"],
            String(startPosition)
        )
    }

    func testAntiItemMetadataIsPreserved() throws {
        let header = makeSingleNoStreamHeader(isEmptyFile: false, isAnti: true)

        let reader = try ArchiveReader.open(data: makeArchive(nextHeader: header))
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.kind, .file)
        XCTAssertEqual(entry.formatSpecific["anti"], "true")
        XCTAssertEqual(entry.formatSpecific["emptyFile"], "false")
        XCTAssertEqual(entry.formatSpecific["emptyStream"], "true")
        XCTAssertEqual(try reader.read(entry), Data())
    }

    func testHighWordUNIXModeProvidesPOSIXPermissions() throws {
        let unixMode: UInt32 = 0o100640
        let attributes = unixMode << 16 | 0x8000
        let header = makeSingleNoStreamHeader(properties: [
            (.windowsAttributes, inlineDefinedUInt32(attributes)),
        ])

        let reader = try ArchiveReader.open(data: makeArchive(nextHeader: header))
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.kind, .file)
        XCTAssertEqual(entry.posixPermissions, UInt16(0o640))
        XCTAssertEqual(entry.formatSpecific["windowsAttributes"], "0x81a08000")
    }

    func testAESByteSourceCapsTransientReadSize() throws {
        let size = 1 * 1_024 * 1_024
        let source = DataByteSource(Data(repeating: 0, count: size))
        let decrypted = try SevenZipAESByteSource(
            source: source,
            ciphertextOffset: 0,
            ciphertextSize: UInt64(size),
            plaintextSize: UInt64(size),
            key: Data(repeating: 0, count: 32),
            initializationVector: Data()
        )
        var output = [UInt8](repeating: 0, count: size)
        let count = try output.withUnsafeMutableBytes { bytes in
            try decrypted.read(into: bytes, at: 0)
        }
        XCTAssertEqual(count, 256 * 1_024)
    }

    func testExternalFolderDefinitionStreamIsParsed() throws {
        var cursor = SevenZipHeaderCursor([
            SevenZipNID.packInfo.rawValue,
            0, // PackPos
            1, // NumPackStreams
            SevenZipNID.size.rawValue,
            1,
            SevenZipNID.end.rawValue,
            SevenZipNID.unpackInfo.rawValue,
            SevenZipNID.folder.rawValue,
            1, // NumFolders
            1, // External
            0, // DataStreamIndex
            SevenZipNID.codersUnpackSize.rawValue,
            1,
            SevenZipNID.end.rawValue,
            SevenZipNID.end.rawValue,
        ])
        let folderDefinition = Data([
            1, // NumCoders
            1, 0, // one 1-in/1-out Copy coder
        ])
        let streams = try SevenZipStreamsParser.parse(
            cursor: &cursor,
            limits: ReadLimits(),
            externalStreams: [folderDefinition]
        )
        XCTAssertTrue(cursor.isAtEnd)
        XCTAssertEqual(streams.folders.count, 1)
        XCTAssertEqual(streams.folders[0].coders[0].methodID, [0])
        XCTAssertEqual(streams.substreams.first?.size, 1)
    }

    func testAbsurdFileAndFolderCountsFailBeforeAllocation() throws {
        let hugeNumber = [UInt8(0xFF)] + [UInt8](repeating: 0xFF, count: 8)
        let fileHeader = [
            SevenZipNID.header.rawValue,
            SevenZipNID.filesInfo.rawValue,
        ] + hugeNumber
        assertLimitExceeded(tryOpening: makeArchive(nextHeader: fileHeader))

        let folderHeader = [
            SevenZipNID.header.rawValue,
            SevenZipNID.mainStreamsInfo.rawValue,
            SevenZipNID.unpackInfo.rawValue,
            SevenZipNID.folder.rawValue,
        ] + hugeNumber
        assertLimitExceeded(tryOpening: makeArchive(nextHeader: folderHeader))
    }

    func testFileCountRespectsAggregateMetadataLimitBeforeAllocation() throws {
        let header: [UInt8] = [
            SevenZipNID.header.rawValue,
            SevenZipNID.filesInfo.rawValue,
            1, // NumFiles
            SevenZipNID.end.rawValue,
            SevenZipNID.end.rawValue,
        ]
        var limits = ReadLimits()
        limits.maxTotalMetadataSize = 255

        XCTAssertThrowsError(
            try ArchiveReader.open(
                data: makeArchive(nextHeader: header),
                options: ReaderOptions(limits: limits)
            )
        ) { error in
            guard case .limitExceeded = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testPackAndFolderCountsRespectMetadataLimitBeforeAllocation() throws {
        let packHeader: [UInt8] = [
            SevenZipNID.header.rawValue,
            SevenZipNID.mainStreamsInfo.rawValue,
            SevenZipNID.packInfo.rawValue,
            0, // PackPos
            1, // NumPackStreams
        ]
        var packLimits = ReadLimits()
        packLimits.maxTotalMetadataSize = 63
        assertLimitExceeded(
            tryOpening: makeArchive(nextHeader: packHeader),
            options: ReaderOptions(limits: packLimits)
        )

        let folderHeader: [UInt8] = [
            SevenZipNID.header.rawValue,
            SevenZipNID.mainStreamsInfo.rawValue,
            SevenZipNID.unpackInfo.rawValue,
            SevenZipNID.folder.rawValue,
            1, // NumFolders
        ]
        var folderLimits = ReadLimits()
        folderLimits.maxTotalMetadataSize = 255
        assertLimitExceeded(
            tryOpening: makeArchive(nextHeader: folderHeader),
            options: ReaderOptions(limits: folderLimits)
        )
    }

    func testStreamMetadataKindsShareAggregateBudget() throws {
        var cursor = SevenZipHeaderCursor([
            SevenZipNID.packInfo.rawValue,
            0, // PackPos
            1, // NumPackStreams: 64 bytes of logical metadata
            SevenZipNID.size.rawValue,
            0,
            SevenZipNID.end.rawValue,
            SevenZipNID.unpackInfo.rawValue,
            SevenZipNID.folder.rawValue,
            1, // NumFolders: another 256 bytes
        ])
        var limits = ReadLimits()
        limits.maxTotalMetadataSize = 319

        XCTAssertThrowsError(
            try SevenZipStreamsParser.parse(cursor: &cursor, limits: limits)
        ) { error in
            guard case .limitExceeded = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testParsedAndPublishedEntryMetadataShareAggregateBudget() throws {
        // Parsed FilesInfo と公開 ArchiveEntry は単独なら各 400 bytes 未満だが、
        // open 中は同時に保持されるため同じ総量予算から差し引く。
        var limits = ReadLimits()
        limits.maxTotalMetadataSize = 400
        assertLimitExceeded(
            tryOpening: makeArchive(nextHeader: makeSingleNoStreamHeader()),
            options: ReaderOptions(limits: limits)
        )
    }

    func testCyclicCoderBindGraphIsRejected() throws {
        // 3 個の 1-in/1-out Copy coder。0 -> 1 と 1 -> 0 の bind で閉路を作る。
        let header: [UInt8] = [
            SevenZipNID.header.rawValue,
            SevenZipNID.mainStreamsInfo.rawValue,
            SevenZipNID.unpackInfo.rawValue,
            SevenZipNID.folder.rawValue,
            1, // NumFolders
            0, // inline folders
            3, // NumCoders
            1, 0, // coder 0: Copy
            1, 0, // coder 1: Copy
            1, 0, // coder 2: Copy
            1, 0, // coder 0 output -> coder 1 input
            0, 1, // coder 1 output -> coder 0 input
        ]
        let archive = makeArchive(nextHeader: header)

        XCTAssertThrowsError(try ArchiveReader.open(data: archive)) { error in
            guard case let .malformed(reason) = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("cyclic"), reason)
        }
    }

    func testFolderCoderAndStreamComplexityCapIsSixtyFour() throws {
        XCTAssertEqual(SevenZipFormatLimits.maxFolderCodersAndStreams, 64)

        let maximum = SevenZipFormatLimits.maxFolderCodersAndStreams
        var bytes: [UInt8] = [
            SevenZipNID.packInfo.rawValue,
            0, // PackPos
            1, // NumPackStreams
            SevenZipNID.size.rawValue,
            1,
            SevenZipNID.end.rawValue,
            SevenZipNID.unpackInfo.rawValue,
            SevenZipNID.folder.rawValue,
            1, // NumFolders
            0, // inline folders
            UInt8(maximum),
        ]
        for _ in 0..<maximum {
            bytes.append(contentsOf: [1, 0]) // one 1-in/1-out Copy coder
        }
        for index in 1..<maximum {
            // Copy coder index - 1 feeds Copy coder index.
            bytes.append(UInt8(index))
            bytes.append(UInt8(index - 1))
        }
        bytes.append(SevenZipNID.codersUnpackSize.rawValue)
        bytes.append(contentsOf: [UInt8](repeating: 1, count: maximum))
        bytes.append(SevenZipNID.end.rawValue) // UnpackInfo
        bytes.append(SevenZipNID.end.rawValue) // StreamsInfo

        var cursor = SevenZipHeaderCursor(bytes)
        let streams = try SevenZipStreamsParser.parse(
            cursor: &cursor,
            limits: ReadLimits()
        )
        XCTAssertTrue(cursor.isAtEnd)
        XCTAssertEqual(streams.folders.first?.coders.count, maximum)
        XCTAssertEqual(streams.folders.first?.inputCount, maximum)
        XCTAssertEqual(streams.folders.first?.outputCount, maximum)

        var packedBytes: [UInt8] = [
            SevenZipNID.packInfo.rawValue,
            0, // PackPos
            UInt8(maximum),
            SevenZipNID.size.rawValue,
        ]
        packedBytes.append(contentsOf: [UInt8](repeating: 1, count: maximum))
        packedBytes.append(contentsOf: [
            SevenZipNID.end.rawValue,
            SevenZipNID.unpackInfo.rawValue,
            SevenZipNID.folder.rawValue,
            1, // NumFolders
            0, // inline folders
            1, // NumCoders
            0x11, 0, // Copy coder with explicit stream counts
            UInt8(maximum), 1, // maximum inputs, one output
        ])
        packedBytes.append(contentsOf: (0..<maximum).map(UInt8.init))
        packedBytes.append(contentsOf: [
            SevenZipNID.codersUnpackSize.rawValue,
            1,
            SevenZipNID.end.rawValue, // UnpackInfo
            SevenZipNID.end.rawValue, // StreamsInfo
        ])
        var packedCursor = SevenZipHeaderCursor(packedBytes)
        let packedStreams = try SevenZipStreamsParser.parse(
            cursor: &packedCursor,
            limits: ReadLimits()
        )
        XCTAssertTrue(packedCursor.isAtEnd)
        XCTAssertEqual(packedStreams.folders.first?.inputCount, maximum)
        XCTAssertEqual(packedStreams.folders.first?.packedIndices.count, maximum)

        var overLimit = SevenZipHeaderCursor([
            SevenZipNID.unpackInfo.rawValue,
            SevenZipNID.folder.rawValue,
            1, 0,
            UInt8(maximum + 1),
        ])
        XCTAssertThrowsError(
            try SevenZipStreamsParser.parse(cursor: &overLimit, limits: ReadLimits())
        ) { error in
            XCTAssertEqual(error as? KaitoError, .limitExceeded("7z coder count"))
        }
    }

    func testSixtyFourCoderFolderRespectsAggregateMetadataLimit() throws {
        let maximum = SevenZipFormatLimits.maxFolderCodersAndStreams
        var bytes: [UInt8] = [
            SevenZipNID.packInfo.rawValue,
            0, // PackPos
            1, // NumPackStreams
            SevenZipNID.size.rawValue,
            1,
            SevenZipNID.end.rawValue,
            SevenZipNID.unpackInfo.rawValue,
            SevenZipNID.folder.rawValue,
            1, // NumFolders
            0, // inline folders
            UInt8(maximum),
        ]
        for _ in 0..<maximum {
            bytes.append(contentsOf: [1, 0]) // one 1-in/1-out Copy coder
        }
        for index in 1..<maximum {
            bytes.append(UInt8(index))
            bytes.append(UInt8(index - 1))
        }
        bytes.append(SevenZipNID.codersUnpackSize.rawValue)
        bytes.append(contentsOf: [UInt8](repeating: 1, count: maximum))
        bytes.append(SevenZipNID.end.rawValue) // UnpackInfo
        bytes.append(SevenZipNID.end.rawValue) // StreamsInfo

        var defaultCursor = SevenZipHeaderCursor(bytes)
        XCTAssertNoThrow(
            try SevenZipStreamsParser.parse(
                cursor: &defaultCursor,
                limits: ReadLimits()
            )
        )
        XCTAssertTrue(defaultCursor.isAtEnd)

        var tightLimits = ReadLimits()
        // The old folder-only accounting used 384 logical bytes for this graph.
        tightLimits.maxTotalMetadataSize = 9 * 1_024
        var tightCursor = SevenZipHeaderCursor(bytes)
        XCTAssertThrowsError(
            try SevenZipStreamsParser.parse(
                cursor: &tightCursor,
                limits: tightLimits
            )
        ) { error in
            guard case .limitExceeded = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testFolderCoordinatorDropsCompletedDecoderAndCanRestart() throws {
        let source = DataByteSource(Data([0x41, 0x42]))
        let coder = SevenZipCoder(
            methodID: [0],
            inputCount: 1,
            outputCount: 1,
            properties: [],
            firstInput: 0,
            firstOutput: 0
        )
        let folder = SevenZipFolder(
            coders: [coder],
            bindPairs: [],
            packedIndices: [0],
            inputCount: 1,
            outputCount: 1,
            finalOutputIndex: 0,
            unpackSizes: [2],
            digest: SevenZipDigest(value: CRC32.checksum([0x41, 0x42]))
        )
        let factory = try SevenZipFolderDecoderFactory(
            source: source,
            folder: folder,
            packedRanges: [
                0: SevenZipPackRange(
                    offset: 0,
                    size: 2,
                    digest: SevenZipDigest(value: nil)
                ),
            ],
            limits: ReadLimits(),
            password: nil,
            keyCache: SevenZipAESKeyCache(),
            maximumAESCyclesPower: 24
        )
        let coordinator = SevenZipFolderCoordinator(factory: factory)

        let first = try coordinator.stream(offset: 0, length: 1)
        XCTAssertEqual(try readBytes(from: first, count: 1), [0x41])
        XCTAssertTrue(coordinator.hasRetainedDecoderState)

        let last = try coordinator.stream(offset: 1, length: 1)
        XCTAssertEqual(try readBytes(from: last, count: 1), [0x42])
        XCTAssertFalse(coordinator.hasRetainedDecoderState)

        let restarted = try coordinator.stream(offset: 0, length: 2)
        XCTAssertEqual(try readBytes(from: restarted, count: 2), [0x41, 0x42])
        XCTAssertFalse(coordinator.hasRetainedDecoderState)
    }

    func testSubstreamSizesCannotExceedFolderUnpackSize() throws {
        let header: [UInt8] = [
            SevenZipNID.header.rawValue,
            SevenZipNID.mainStreamsInfo.rawValue,

            SevenZipNID.packInfo.rawValue,
            0, // PackPos
            1, // NumPackStreams
            SevenZipNID.size.rawValue,
            1, // packed size
            SevenZipNID.end.rawValue,

            SevenZipNID.unpackInfo.rawValue,
            SevenZipNID.folder.rawValue,
            1, // NumFolders
            0, // inline folders
            1, // NumCoders
            1, 0, // one Copy coder
            SevenZipNID.codersUnpackSize.rawValue,
            5, // folder output size
            SevenZipNID.end.rawValue,

            SevenZipNID.subStreamsInfo.rawValue,
            SevenZipNID.numUnpackStream.rawValue,
            2,
            SevenZipNID.size.rawValue,
            6, // first substream alone exceeds the 5-byte folder output
            SevenZipNID.end.rawValue,
            SevenZipNID.end.rawValue, // MainStreamsInfo
            SevenZipNID.end.rawValue, // Header
        ]
        let archive = makeArchive(nextHeader: header)

        XCTAssertThrowsError(try ArchiveReader.open(data: archive)) { error in
            guard case let .malformed(reason) = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("substream sizes exceed"), reason)
        }
    }

    func testFourGiBLZMA2DictionaryFailsViaConfiguredLimit() throws {
        let source = DataByteSource(Data([0]))
        let coder = SevenZipCoder(
            methodID: [0x21],
            inputCount: 1,
            outputCount: 1,
            properties: [40], // UInt32.max-byte LZMA2 dictionary
            firstInput: 0,
            firstOutput: 0
        )
        let folder = SevenZipFolder(
            coders: [coder],
            bindPairs: [],
            packedIndices: [0],
            inputCount: 1,
            outputCount: 1,
            finalOutputIndex: 0,
            unpackSizes: [0],
            digest: SevenZipDigest(value: nil)
        )
        var limits = ReadLimits()
        limits.maxDictionarySize = 64 * 1_024 * 1_024
        let factory = try SevenZipFolderDecoderFactory(
            source: source,
            folder: folder,
            packedRanges: [
                0: SevenZipPackRange(
                    offset: 0,
                    size: 1,
                    digest: SevenZipDigest(value: nil)
                ),
            ],
            limits: limits,
            password: nil,
            keyCache: SevenZipAESKeyCache(),
            maximumAESCyclesPower: 24
        )

        XCTAssertThrowsError(try factory.makeDecoder()) { error in
            guard case .limitExceeded = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testThreeHundredEightyFourDeterministicContainerMutantsDoNotCrashOrHang() throws {
        try SevenZipTestSupport.requireSevenZip()
        let temporary = try SevenZipTestSupport.temporaryDirectory(label: "7z-mutants")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sourceDirectory = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: false
        )
        let payload = Data((0..<2_048).map { UInt8(truncatingIfNeeded: $0 &* 37) })
        _ = try SevenZipTestSupport.write(
            payload,
            relativePath: "mutant-seed.bin",
            below: sourceDirectory
        )
        let archiveURL = temporary.appendingPathComponent("seed.7z")
        try SevenZipTestSupport.makeArchive(
            sourceDirectory: sourceDirectory,
            paths: ["mutant-seed.bin"],
            archiveURL: archiveURL,
            options: ["-m0=Copy", "-ms=off", "-mhc=off"]
        )

        let seed = [UInt8](try Data(contentsOf: archiveURL))
        let headerRange = try nextHeaderRange(in: seed)
        XCTAssertFalse(headerRange.isEmpty)
        let options = ReaderOptions(
            limits: ReadLimits(
                maxEntrySize: 256 * 1_024,
                maxInMemorySize: 256 * 1_024,
                maxEntryCount: 64,
                maxMetadataSize: 128 * 1_024,
                maxMetadataRecordCount: 128,
                maxPathComponentCount: 32,
                maxTotalMetadataSize: 1 * 1_024 * 1_024,
                maxDictionarySize: 1 * 1_024 * 1_024
            ),
            maxSevenZipAESCyclesPower: 4
        )

        var completed = 0
        for mutation in 0..<320 {
            var bytes = seed
            let first = headerRange.lowerBound
                + (mutation &* 131 &+ 17) % headerRange.count
            bytes[first] ^= UInt8(1) << UInt8(mutation % 8)
            if mutation.isMultiple(of: 5), headerRange.count > 1 {
                let second = headerRange.lowerBound
                    + (mutation &* 47 &+ 3) % headerRange.count
                bytes[second] &+= UInt8(truncatingIfNeeded: mutation | 1)
            }
            repairHeaderCRCs(in: &bytes, nextHeaderRange: headerRange)
            exerciseMutant(Data(bytes), options: options)
            completed += 1
        }
        for mutation in 0..<64 {
            let removed = 1 + (mutation &* 97) % seed.count
            exerciseMutant(Data(seed.dropLast(removed)), options: options)
            completed += 1
        }
        XCTAssertEqual(completed, 384)
    }

    private func makeArchive(
        packedData: [UInt8] = [],
        nextHeader: [UInt8],
        recordedNextCRC: UInt32? = nil
    ) -> Data {
        let nextCRC = recordedNextCRC ?? CRC32.checksum(nextHeader)
        var startHeader: [UInt8] = []
        appendLittleEndian(UInt64(packedData.count), to: &startHeader)
        appendLittleEndian(UInt64(nextHeader.count), to: &startHeader)
        appendLittleEndian(nextCRC, to: &startHeader)

        var bytes = Self.signature
        bytes.append(contentsOf: [0, 4])
        appendLittleEndian(CRC32.checksum(startHeader), to: &bytes)
        bytes.append(contentsOf: startHeader)
        bytes.append(contentsOf: packedData)
        bytes.append(contentsOf: nextHeader)
        return Data(bytes)
    }

    private func makeSingleNoStreamHeader(
        properties: [(SevenZipNID, [UInt8])] = [],
        isEmptyFile: Bool = true,
        isAnti: Bool = false
    ) -> [UInt8] {
        var header: [UInt8] = [
            SevenZipNID.header.rawValue,
            SevenZipNID.filesInfo.rawValue,
            1, // NumFiles
        ]
        if isAnti {
            appendProperty(.anti, bytes: [0x80], to: &header)
        }
        for (id, bytes) in properties {
            appendProperty(id, bytes: bytes, to: &header)
        }
        appendProperty(.emptyStream, bytes: [0x80], to: &header)
        if isEmptyFile {
            appendProperty(.emptyFile, bytes: [0x80], to: &header)
        }
        appendProperty(.name, bytes: [0, 0x61, 0, 0, 0], to: &header)
        header.append(SevenZipNID.end.rawValue) // FilesInfo
        header.append(SevenZipNID.end.rawValue) // Header
        return header
    }

    private func appendProperty(
        _ id: SevenZipNID,
        bytes: [UInt8],
        to header: inout [UInt8]
    ) {
        precondition(bytes.count < 0x80)
        header.append(id.rawValue)
        header.append(UInt8(bytes.count))
        header.append(contentsOf: bytes)
    }

    private func inlineDefinedUInt32(_ value: UInt32) -> [UInt8] {
        var bytes: [UInt8] = [1, 0]
        appendLittleEndian(value, to: &bytes)
        return bytes
    }

    private func inlineDefinedUInt64(_ value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = [1, 0]
        appendLittleEndian(value, to: &bytes)
        return bytes
    }

    private func assertLimitExceeded(
        tryOpening archive: Data,
        options: ReaderOptions = ReaderOptions(),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ArchiveReader.open(data: archive, options: options),
            file: file,
            line: line
        ) { error in
            guard case .limitExceeded = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)", file: file, line: line)
            }
        }
    }

    private func exerciseMutant(_ data: Data, options: ReaderOptions) {
        do {
            let reader = try ArchiveReader.open(data: data, options: options)
            for entry in reader.entries where entry.kind == .file {
                _ = try reader.read(entry)
            }
        } catch {
            XCTAssertTrue(
                error is KaitoError,
                "mutant raised a non-Kaito error: \(error)"
            )
        }
    }

    private func readBytes(
        from decompressor: any Decompressor,
        count: Int
    ) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let actual = try bytes.withUnsafeMutableBytes { storage in
            try decompressor.read(into: storage)
        }
        XCTAssertEqual(actual, count)
        return Array(bytes.prefix(actual))
    }

    private func nextHeaderRange(in bytes: [UInt8]) throws -> Range<Int> {
        guard bytes.count >= 32 else { throw KaitoError.truncated }
        let offset = try Checked.toInt(littleUInt64(bytes, at: 12))
        let size = try Checked.toInt(littleUInt64(bytes, at: 20))
        let start = 32 + offset
        guard start >= 32, start <= bytes.count, size <= bytes.count - start else {
            throw KaitoError.truncated
        }
        return start..<(start + size)
    }

    private func repairHeaderCRCs(
        in bytes: inout [UInt8],
        nextHeaderRange: Range<Int>
    ) {
        let nextCRC = CRC32.checksum(Array(bytes[nextHeaderRange]))
        writeLittleEndian(nextCRC, to: &bytes, at: 28)
        let startCRC = CRC32.checksum(Array(bytes[12..<32]))
        writeLittleEndian(startCRC, to: &bytes, at: 8)
    }

    private func littleUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(bytes[offset + index]) << UInt64(index * 8)
        }
        return value
    }

    private func appendLittleEndian(_ value: UInt32, to bytes: inout [UInt8]) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    private func appendLittleEndian(_ value: UInt64, to bytes: inout [UInt8]) {
        for shift in stride(from: 0, to: 64, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    private func writeLittleEndian(
        _ value: UInt32,
        to bytes: inout [UInt8],
        at offset: Int
    ) {
        for index in 0..<4 {
            bytes[offset + index] = UInt8(
                truncatingIfNeeded: value >> UInt32(index * 8)
            )
        }
    }
}
