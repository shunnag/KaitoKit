import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

final class LZSStaticHuffmanDecoderTests: XCTestCase {
    private enum TestError: Error {
        case noProgress
    }

    func testConstantLiteralBlocksDecodeForEveryMethodAndTinyReads() throws {
        for method in ["-lh4-", "-lh5-", "-lh6-", "-lh7-", "-lhx-"] {
            var writer = StaticLHABitWriter()
            appendConstantBlock(
                commandCount: 257,
                commandSymbol: Int(UInt8(ascii: "K")),
                method: method,
                to: &writer
            )
            let packed = writer.finish()
            let decoder = try makeDecoder(
                method: method,
                packed: packed,
                outputSize: 257
            )

            XCTAssertEqual(
                try drain(decoder, bufferSize: 1),
                Data(repeating: UInt8(ascii: "K"), count: 257),
                method
            )
            XCTAssertTrue(decoder.isFinished, method)
        }
    }

    func testMatchUsesPriorOutputAndPositionSuffix() throws {
        var writer = StaticLHABitWriter()
        for byte in "ABCDEFGH".utf8 {
            appendConstantBlock(
                commandCount: 1,
                commandSymbol: Int(byte),
                method: "-lh5-",
                to: &writer
            )
        }
        // Command 261 has length 8. Position symbol 3 followed by suffix 3
        // encodes position 7, hence an eight-byte backward distance.
        appendConstantBlock(
            commandCount: 1,
            commandSymbol: 261,
            positionSymbol: 3,
            method: "-lh5-",
            to: &writer
        )
        writer.append(3, bitCount: 2)

        let decoder = try makeDecoder(
            method: "-lh5-",
            packed: writer.finish(),
            outputSize: 16
        )
        XCTAssertEqual(
            try drain(decoder, bufferSize: 3),
            Data("ABCDEFGHABCDEFGH".utf8)
        )
    }

    func testLHArkSixBitPositionTreeAndExtendedLengthCodes() throws {
        var writer = StaticLHABitWriter()
        for byte in "ABCDEFGH".utf8 {
            appendConstantBlock(
                commandCount: 1,
                commandSymbol: Int(byte),
                method: "-lh7-",
                lhark: true,
                to: &writer
            )
        }
        // LHArk command 264 plus suffix zero means an 11-byte match. Its
        // position symbol 5 plus suffix one means encoded offset seven, or an
        // eight-byte backward distance.
        appendConstantBlock(
            commandCount: 1,
            commandSymbol: 264,
            positionSymbol: 5,
            method: "-lh7-",
            lhark: true,
            to: &writer
        )
        writer.append(0, bitCount: 1)
        writer.append(1, bitCount: 1)

        let decoder = try makeDecoder(
            method: "-lh7-",
            packed: writer.finish(),
            outputSize: 19,
            lhark: true
        )
        XCTAssertEqual(
            try drain(decoder, bufferSize: 2),
            Data("ABCDEFGHABCDEFGHABC".utf8)
        )
    }

    func testLHArkPositionAlphabetAccepts31AndRejects32() throws {
        var boundaryWriter = StaticLHABitWriter()
        appendConstantBlock(
            commandCount: 1,
            commandSymbol: 256,
            positionSymbol: 31,
            method: "-lh7-",
            lhark: true,
            to: &boundaryWriter
        )
        // Position symbol 31 followed by its largest fourteen-bit suffix
        // addresses the full 64 KiB backward distance.
        boundaryWriter.append((1 << 14) - 1, bitCount: 14)
        let boundary = try makeDecoder(
            method: "-lh7-",
            packed: boundaryWriter.finish(),
            outputSize: 3,
            lhark: true
        )
        XCTAssertEqual(
            try drain(boundary, bufferSize: 3),
            Data(repeating: 0x20, count: 3)
        )

        var invalidWriter = StaticLHABitWriter()
        appendConstantBlock(
            commandCount: 1,
            commandSymbol: Int(UInt8(ascii: "A")),
            positionSymbol: 32,
            method: "-lh7-",
            lhark: true,
            to: &invalidWriter
        )
        let invalid = try makeDecoder(
            method: "-lh7-",
            packed: invalidWriter.finish(),
            outputSize: 1,
            lhark: true
        )
        XCTAssertThrowsError(try drain(invalid, bufferSize: 1)) { error in
            guard case let KaitoError.malformed(reason) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("constant Huffman symbol"))
        }
    }

    func testLHArkRejectsPositionLengthCountAboveItsAlphabet() throws {
        var writer = StaticLHABitWriter()
        writer.append(1, bitCount: 16)
        writer.append(0, bitCount: 5)
        writer.append(0, bitCount: 5)
        writer.append(0, bitCount: 9)
        writer.append(Int(UInt8(ascii: "A")), bitCount: 9)
        writer.append(33, bitCount: 6)

        let decoder = try makeDecoder(
            method: "-lh7-",
            packed: writer.finish(),
            outputSize: 1,
            lhark: true
        )
        XCTAssertThrowsError(try drain(decoder, bufferSize: 1)) { error in
            guard case let KaitoError.malformed(reason) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("length count exceeds"))
        }
    }

    func testLHArkMaximumCommandProduces514ByteMatch() throws {
        var writer = StaticLHABitWriter()
        appendConstantBlock(
            commandCount: 1,
            commandSymbol: 288,
            positionSymbol: 0,
            method: "-lh7-",
            lhark: true,
            to: &writer
        )
        let decoder = try makeDecoder(
            method: "-lh7-",
            packed: writer.finish(),
            outputSize: 514,
            lhark: true
        )
        XCTAssertEqual(
            try drain(decoder, bufferSize: 37),
            Data(repeating: 0x20, count: 514)
        )
    }

    func testLHXPositionAlphabetReachesOneMiBAndRejectsSymbol21() throws {
        var boundaryWriter = StaticLHABitWriter()
        appendConstantBlock(
            commandCount: 1,
            commandSymbol: 256,
            positionSymbol: 20,
            method: "-lhx-",
            to: &boundaryWriter
        )
        boundaryWriter.append((1 << 19) - 1, bitCount: 19)
        let boundary = try makeDecoder(
            method: "-lhx-",
            packed: boundaryWriter.finish(),
            outputSize: 3
        )
        XCTAssertEqual(
            try drain(boundary, bufferSize: 3),
            Data(repeating: 0x20, count: 3)
        )

        var invalidWriter = StaticLHABitWriter()
        appendConstantBlock(
            commandCount: 1,
            commandSymbol: Int(UInt8(ascii: "A")),
            positionSymbol: 21,
            method: "-lhx-",
            to: &invalidWriter
        )
        let invalid = try makeDecoder(
            method: "-lhx-",
            packed: invalidWriter.finish(),
            outputSize: 1
        )
        XCTAssertThrowsError(try drain(invalid, bufferSize: 1)) { error in
            guard case let KaitoError.malformed(reason) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("constant Huffman symbol"))
        }
    }

    func testInitialDictionaryContainsSpaces() throws {
        var writer = StaticLHABitWriter()
        appendConstantBlock(
            commandCount: 1,
            commandSymbol: 256,
            method: "-lh4-",
            to: &writer
        )
        let decoder = try makeDecoder(
            method: "-lh4-",
            packed: writer.finish(),
            outputSize: 3
        )
        XCTAssertEqual(try drain(decoder, bufferSize: 8), Data(repeating: 0x20, count: 3))
    }

    func testCanonicalCommandTreeAndLongZeroRun() throws {
        var writer = StaticLHABitWriter()
        writer.append(4, bitCount: 16)

        // Code-length alphabet: only symbols 2 and 3, both one bit. The
        // special zero insertion occurs after the third transmitted length.
        writer.append(4, bitCount: 5)
        writer.append(0, bitCount: 3)
        writer.append(0, bitCount: 3)
        writer.append(1, bitCount: 3)
        writer.append(0, bitCount: 2)
        writer.append(1, bitCount: 3)

        // Command symbols 0...64 are zero length (symbol 2, suffix 45), while
        // symbols 65 ('A') and 66 ('B') both have one-bit canonical codes.
        writer.append(67, bitCount: 9)
        writer.append(0, bitCount: 1)
        writer.append(45, bitCount: 9)
        writer.append(1, bitCount: 1)
        writer.append(1, bitCount: 1)

        appendConstantPositionTree(method: "-lh5-", symbol: 0, to: &writer)
        writer.append(0b0110, bitCount: 4)

        let decoder = try makeDecoder(
            method: "-lh5-",
            packed: writer.finish(),
            outputSize: 4
        )
        XCTAssertEqual(try drain(decoder, bufferSize: 2), Data("ABBA".utf8))
    }

    func testMaximumLengthCommandCodesDecodeThroughSecondaryNodes() throws {
        let commandLengths = Array(1...15) + [16, 16]
        var writer = StaticLHABitWriter()
        appendCanonicalCommandBlock(
            commandSymbols: [15, 16, 0, 15],
            commandLengths: commandLengths,
            to: &writer
        )

        let decoder = try makeDecoder(
            method: "-lh5-",
            packed: writer.finish(),
            outputSize: 4
        )
        XCTAssertEqual(
            try drain(decoder, bufferSize: 1),
            Data([15, 16, 0, 15])
        )
    }

    func testTruncatedMaximumLengthCodeCannotUseLookaheadPadding() throws {
        let commandLengths = Array(1...15) + [16, 16]
        var writer = StaticLHABitWriter()
        appendCanonicalCommandBlock(
            commandSymbols: [16],
            commandLengths: commandLengths,
            to: &writer
        )
        var packed = writer.finish()
        packed.removeLast()

        let decoder = try makeDecoder(
            method: "-lh5-",
            packed: packed,
            outputSize: 1
        )
        XCTAssertThrowsError(try drain(decoder, bufferSize: 1)) { error in
            XCTAssertEqual(error as? KaitoError, KaitoError.truncated)
        }
    }

    func testRejectsIncompleteLongTreeWithInvalidPrefixSpace() throws {
        // A maximally skewed complete tree needs two leaves at depth 16. With
        // only one, one 16-bit prefix remains invalid and the table is rejected
        // before it can enter the symbol loop.
        let incompleteLengths = Array(1...16)
        var writer = StaticLHABitWriter()
        appendCanonicalCommandBlock(
            commandSymbols: [15],
            commandLengths: incompleteLengths,
            to: &writer
        )

        let decoder = try makeDecoder(
            method: "-lh5-",
            packed: writer.finish(),
            outputSize: 1
        )
        XCTAssertThrowsError(try drain(decoder, bufferSize: 1)) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .malformed("incomplete LHA command Huffman table")
            )
        }
    }

    func testLiteralMatchAndPresetWindowVectorsMatchLhasaOracleWhenAvailable() throws {
        guard let executable = LHATestSupport.lhasaExecutableURL else {
            throw XCTSkip("set KAITOKIT_LHA_EXECUTABLE or install lhasa")
        }

        var literalWriter = StaticLHABitWriter()
        appendCanonicalABBlock(commandBits: [0, 1, 1, 0], to: &literalWriter)
        let literalExpected = Data("ABBA".utf8)
        let literalPacked = literalWriter.finish()

        var matchWriter = StaticLHABitWriter()
        for byte in "ABCDEFGH".utf8 {
            appendConstantBlock(
                commandCount: 1,
                commandSymbol: Int(byte),
                method: "-lh5-",
                to: &matchWriter
            )
        }
        appendConstantBlock(
            commandCount: 1,
            commandSymbol: 261,
            positionSymbol: 3,
            method: "-lh5-",
            to: &matchWriter
        )
        matchWriter.append(3, bitCount: 2)
        let matchExpected = Data("ABCDEFGHABCDEFGH".utf8)
        let matchPacked = matchWriter.finish()

        var presetWriter = StaticLHABitWriter()
        appendConstantBlock(
            commandCount: 1,
            commandSymbol: 256,
            method: "-lh5-",
            to: &presetWriter
        )
        let presetExpected = Data(repeating: 0x20, count: 3)
        let presetPacked = presetWriter.finish()

        let archive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "literal.bin",
                contents: literalExpected,
                method: "-lh5-",
                headerLevel: 0,
                packedContents: literalPacked,
                declaredOriginalSize: UInt32(literalExpected.count)
            ),
            HandLHAEntry(
                name: "match.bin",
                contents: matchExpected,
                method: "-lh5-",
                headerLevel: 0,
                packedContents: matchPacked,
                declaredOriginalSize: UInt32(matchExpected.count)
            ),
            HandLHAEntry(
                name: "preset.bin",
                contents: presetExpected,
                method: "-lh5-",
                headerLevel: 0,
                packedContents: presetPacked,
                declaredOriginalSize: UInt32(presetExpected.count)
            )
        ])

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KaitoKit-LH5-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let archiveURL = directory.appendingPathComponent("vectors.lzh")
        try archive.write(to: archiveURL, options: Data.WritingOptions.atomic)
        let archiveReader = try ArchiveReader.open(data: archive)

        for (name, packed, expected) in [
            ("literal.bin", literalPacked, literalExpected),
            ("match.bin", matchPacked, matchExpected),
            ("preset.bin", presetPacked, presetExpected),
        ] {
            let standardOutput = Pipe()
            let standardError = Pipe()
            let process = Process()
            process.executableURL = executable
            process.arguments = ["-pq", archiveURL.path, name]
            process.standardOutput = standardOutput
            process.standardError = standardError
            try process.run()
            let oracle = standardOutput.fileHandleForReading.readDataToEndOfFile()
            let diagnostic = standardError.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(
                process.terminationStatus,
                0,
                String(data: diagnostic, encoding: .utf8) ?? "lhasa failed"
            )
            XCTAssertEqual(
                Data(SHA256.hash(data: oracle)),
                Data(SHA256.hash(data: expected)),
                name
            )

            let decoder = try makeDecoder(
                method: "-lh5-",
                packed: packed,
                outputSize: UInt64(expected.count)
            )
            XCTAssertEqual(
                Data(SHA256.hash(data: try drain(decoder, bufferSize: 1))),
                Data(SHA256.hash(data: oracle)),
                name
            )
            let entry = try XCTUnwrap(
                archiveReader.entries.first { $0.name == name }
            )
            XCTAssertEqual(
                Data(SHA256.hash(data: try archiveReader.read(entry))),
                Data(SHA256.hash(data: oracle)),
                name
            )
        }
    }

    func testRejectsCommandZeroRunBeyondDeclaredTableCountAndStaysTerminal() throws {
        var writer = StaticLHABitWriter()
        writer.append(1, bitCount: 16)
        writer.append(0, bitCount: 5)
        writer.append(2, bitCount: 5) // code-length tree is constant symbol 2
        writer.append(1, bitCount: 9)
        writer.append(0x1ff, bitCount: 9) // run is 531, declared count is one

        let decoder = try makeDecoder(
            method: "-lh5-",
            packed: writer.finish(),
            outputSize: 1
        )
        for _ in 0..<2 {
            var byte: UInt8 = 0
            XCTAssertThrowsError(
                try withUnsafeMutableBytes(of: &byte) { try decoder.read(into: $0) }
            ) { error in
                XCTAssertEqual(
                    error as? KaitoError,
                    .malformed("LHA command zero run exceeds its length table")
                )
            }
        }
        XCTAssertFalse(decoder.isFinished)
    }

    func testRejectsSpecialCodeLengthZeroRunBeyondDeclaredCount() throws {
        var writer = StaticLHABitWriter()
        writer.append(1, bitCount: 16)
        writer.append(3, bitCount: 5)
        writer.append(0, bitCount: 3)
        writer.append(0, bitCount: 3)
        writer.append(0, bitCount: 3)
        writer.append(1, bitCount: 2)

        let decoder = try makeDecoder(
            method: "-lh5-",
            packed: writer.finish(),
            outputSize: 1
        )
        XCTAssertThrowsError(try drain(decoder, bufferSize: 1)) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .malformed("LHA special zero run exceeds its length table")
            )
        }
    }

    func testRejectsCodeLengthUnaryRunBeyondSixteenBits() throws {
        var writer = StaticLHABitWriter()
        writer.append(1, bitCount: 16)
        writer.append(1, bitCount: 5)
        writer.append(0b111, bitCount: 3)
        // Seven plus ten unary extensions reaches the disallowed length 17.
        for _ in 0..<10 {
            writer.append(1, bitCount: 1)
        }

        let decoder = try makeDecoder(
            method: "-lh5-",
            packed: writer.finish(),
            outputSize: 1
        )
        XCTAssertThrowsError(try drain(decoder, bufferSize: 1)) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .malformed("LHA Huffman code length exceeds 16")
            )
        }
    }

    func testZeroCommandBlockMakesBoundedForwardProgress() throws {
        var writer = StaticLHABitWriter()
        appendConstantBlock(
            commandCount: 0,
            commandSymbol: Int(UInt8(ascii: "X")),
            method: "-lh4-",
            to: &writer
        )
        appendConstantBlock(
            commandCount: 1,
            commandSymbol: Int(UInt8(ascii: "Y")),
            method: "-lh4-",
            to: &writer
        )
        let decoder = try makeDecoder(
            method: "-lh4-",
            packed: writer.finish(),
            outputSize: 1
        )
        XCTAssertEqual(try drain(decoder, bufferSize: 1), Data("Y".utf8))
    }

    func testRejectsTruncatedBlockMetadata() throws {
        let truncated = try makeDecoder(
            method: "-lh4-",
            packed: Data([0]),
            outputSize: 1
        )
        XCTAssertThrowsError(try drain(truncated, bufferSize: 1)) { error in
            XCTAssertEqual(error as? KaitoError, KaitoError.truncated)
        }
    }

    func testValidatesMethodAndDictionaryLimitBeforeDecoding() throws {
        XCTAssertThrowsError(
            try makeDecoder(method: "-lh3-", packed: Data(), outputSize: 0)
        ) { error in
            XCTAssertEqual(error as? KaitoError, .unsupportedMethod("-lh3-"))
        }

        var limits = ReadLimits()
        limits.maxDictionarySize = 4_095
        XCTAssertThrowsError(
            try LZSStaticHuffmanDecoder(
                method: "-lh4-",
                source: DataByteSource(Data()),
                offset: 0,
                compressedSize: 0,
                uncompressedSize: 0,
                limits: limits
            )
        ) { error in
            guard case .limitExceeded = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        limits.maxDictionarySize = 1_048_575
        XCTAssertThrowsError(
            try LZSStaticHuffmanDecoder(
                method: "-lhx-",
                source: DataByteSource(Data()),
                offset: 0,
                compressedSize: 0,
                uncompressedSize: 0,
                limits: limits
            )
        ) { error in
            guard case .limitExceeded = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testSharedWindowCopyCapsOneCallToOneRingTurn() {
        let window = UnsafeMutablePointer<UInt8>.allocate(capacity: 8)
        window.initialize(from: Array("abcdefgh".utf8), count: 8)
        defer {
            window.deinitialize(count: 8)
            window.deallocate()
        }
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: 20)
        output.initialize(repeating: 0, count: 20)
        defer {
            output.deinitialize(count: 20)
            output.deallocate()
        }

        var windowPosition = 0
        var outputPosition = 0
        var remaining = 20
        var callCount = 0
        while remaining > 0 {
            lhaCopyMatch(
                window: window,
                windowMask: 7,
                windowPosition: &windowPosition,
                distance: 3,
                remaining: &remaining,
                output: output,
                outputPosition: &outputPosition,
                outputLimit: 20
            )
            callCount += 1
            XCTAssertLessThan(callCount, 10)
        }

        XCTAssertEqual(callCount, 3)
        XCTAssertEqual(
            Data(bytes: output, count: 20),
            Data("fghfghfghfghfghfghfg".utf8)
        )
    }

    private func makeDecoder(
        method: String,
        packed: Data,
        outputSize: UInt64,
        lhark: Bool = false,
        limits: ReadLimits = ReadLimits()
    ) throws -> LZSStaticHuffmanDecoder {
        try LZSStaticHuffmanDecoder(
            method: method,
            source: DataByteSource(packed),
            offset: 0,
            compressedSize: UInt64(packed.count),
            uncompressedSize: outputSize,
            lhark: lhark,
            limits: limits
        )
    }

    private func drain(
        _ decoder: any Decompressor,
        bufferSize: Int
    ) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var iterations = 0
        while !decoder.isFinished {
            let count = try buffer.withUnsafeMutableBytes { storage in
                try decoder.read(into: storage)
            }
            guard count > 0 || decoder.isFinished else { throw TestError.noProgress }
            result.append(contentsOf: buffer.prefix(count))
            iterations += 1
            guard iterations < 100_000 else { throw TestError.noProgress }
        }
        return result
    }

    private func appendConstantBlock(
        commandCount: Int,
        commandSymbol: Int,
        positionSymbol: Int = 0,
        method: String,
        lhark: Bool = false,
        to writer: inout StaticLHABitWriter
    ) {
        writer.append(commandCount, bitCount: 16)
        writer.append(0, bitCount: 5)
        writer.append(0, bitCount: 5)
        writer.append(0, bitCount: 9)
        writer.append(commandSymbol, bitCount: 9)
        appendConstantPositionTree(
            method: method,
            symbol: positionSymbol,
            lhark: lhark,
            to: &writer
        )
    }

    private func appendCanonicalABBlock(
        commandBits: [Int],
        to writer: inout StaticLHABitWriter
    ) {
        writer.append(commandBits.count, bitCount: 16)

        // Code-length alphabet: symbols 2 and 3 have one-bit codes.
        writer.append(4, bitCount: 5)
        writer.append(0, bitCount: 3)
        writer.append(0, bitCount: 3)
        writer.append(1, bitCount: 3)
        writer.append(0, bitCount: 2)
        writer.append(1, bitCount: 3)

        // Skip command symbols 0...64, then assign length one to A and B.
        writer.append(67, bitCount: 9)
        writer.append(0, bitCount: 1)
        writer.append(45, bitCount: 9)
        writer.append(1, bitCount: 1)
        writer.append(1, bitCount: 1)
        appendConstantPositionTree(method: "-lh5-", symbol: 0, to: &writer)
        for bit in commandBits {
            writer.append(bit, bitCount: 1)
        }
    }

    /// Writes a block whose command alphabet uses the supplied canonical
    /// lengths. The recursively coded length alphabet contains all symbols
    /// 0...18: thirteen four-bit codes and six five-bit codes form a complete
    /// tree and can therefore describe command lengths through sixteen.
    private func appendCanonicalCommandBlock(
        commandSymbols: [Int],
        commandLengths: [Int],
        to writer: inout StaticLHABitWriter
    ) {
        precondition(!commandSymbols.isEmpty)
        precondition(!commandLengths.isEmpty)
        precondition(commandLengths.count <= 510)
        precondition(commandLengths.allSatisfy { (1...16).contains($0) })
        precondition(commandSymbols.allSatisfy {
            commandLengths.indices.contains($0)
        })

        writer.append(commandSymbols.count, bitCount: 16)

        let codeLengthAlphabetLengths =
            Array(repeating: 4, count: 13) + Array(repeating: 5, count: 6)
        writer.append(codeLengthAlphabetLengths.count, bitCount: 5)
        for (index, length) in codeLengthAlphabetLengths.enumerated() {
            writer.append(length, bitCount: 3)
            if index == 2 {
                writer.append(0, bitCount: 2)
            }
        }

        writer.append(commandLengths.count, bitCount: 9)
        for length in commandLengths {
            appendCanonicalSymbol(
                length + 2,
                lengths: codeLengthAlphabetLengths,
                to: &writer
            )
        }
        appendConstantPositionTree(method: "-lh5-", symbol: 0, to: &writer)

        for symbol in commandSymbols {
            appendCanonicalSymbol(
                symbol,
                lengths: commandLengths,
                to: &writer
            )
        }
    }

    private func appendCanonicalSymbol(
        _ symbol: Int,
        lengths: [Int],
        to writer: inout StaticLHABitWriter
    ) {
        precondition(lengths.indices.contains(symbol))
        var counts = [Int](repeating: 0, count: 17)
        for length in lengths where length > 0 {
            counts[length] += 1
        }

        var nextCodes = [Int](repeating: 0, count: 17)
        var code = 0
        for bitCount in 1...16 {
            code = (code + counts[bitCount - 1]) << 1
            nextCodes[bitCount] = code
        }

        for candidate in lengths.indices {
            let bitCount = lengths[candidate]
            guard bitCount > 0 else { continue }
            let candidateCode = nextCodes[bitCount]
            nextCodes[bitCount] += 1
            if candidate == symbol {
                writer.append(candidateCode, bitCount: bitCount)
                return
            }
        }
        preconditionFailure("canonical symbol has no code")
    }

    private func appendConstantPositionTree(
        method: String,
        symbol: Int,
        lhark: Bool = false,
        to writer: inout StaticLHABitWriter
    ) {
        let bitCount = lhark
            ? 6
            : (method == "-lh4-" || method == "-lh5-" ? 4 : 5)
        writer.append(0, bitCount: bitCount)
        writer.append(symbol, bitCount: bitCount)
    }
}

private struct StaticLHABitWriter {
    private var bytes: [UInt8]
    private var currentByte: UInt8
    private var usedBitCount: Int

    init() {
        self.bytes = []
        self.currentByte = 0
        self.usedBitCount = 0
    }

    mutating func append(_ value: Int, bitCount: Int) {
        precondition((0...31).contains(bitCount))
        precondition(value >= 0)
        if bitCount < Int.bitWidth {
            precondition(value < 1 << bitCount || bitCount == 0)
        }
        guard bitCount > 0 else { return }

        for shift in stride(from: bitCount - 1, through: 0, by: -1) {
            let bit = UInt8((value >> shift) & 1)
            currentByte |= bit << UInt8(7 - usedBitCount)
            usedBitCount += 1
            if usedBitCount == 8 {
                bytes.append(currentByte)
                currentByte = 0
                usedBitCount = 0
            }
        }
    }

    mutating func finish() -> Data {
        if usedBitCount > 0 {
            bytes.append(currentByte)
            currentByte = 0
            usedBitCount = 0
        }
        return Data(bytes)
    }
}
