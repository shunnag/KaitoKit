import Foundation
@testable import KaitoKit
import XCTest

final class RAR5DecoderTests: XCTestCase {
    fileprivate enum SyntheticReadError: Error {
        case failed
    }

    func testLiteralBlocksStreamThroughOneByteReadsAndReuseTables() throws {
        let firstCount = 257
        let secondCount = 513
        let compressed = makeLiteralBlock(
            byte: 0x41,
            count: firstCount,
            includesTables: true,
            isLast: false
        ) + makeLiteralBlock(
            byte: 0x41,
            count: secondCount,
            includesTables: false,
            isLast: true
        )
        let expected = Data(repeating: 0x41, count: firstCount + secondCount)

        for sourceChunk in [1, 3, 17, compressed.count] {
            let source = RAR5DecoderShortByteSource(
                data: compressed,
                maximumReadSize: sourceChunk
            )
            let decoder = try makeDecoder(
                source: source,
                compressedSize: compressed.count,
                expectedSize: expected.count
            )

            var empty: [UInt8] = []
            XCTAssertEqual(
                try empty.withUnsafeMutableBytes { try decoder.read(into: $0) },
                0
            )
            XCTAssertEqual(try drain(decoder, bufferSize: 1), expected)
            XCTAssertTrue(decoder.isFinished)
        }
    }

    func testSolidStateCarriesDictionaryTablesDistancesAndLastLength() throws {
        let blocks = makeSyntheticSolidStateBlocks()
        let state = try RAR5Decoder.SolidState(dictionarySize: 128 * 1_024)
        let first = try RAR5Decoder(
            source: DataByteSource(data: blocks.first),
            offset: 0,
            compressedSize: UInt64(blocks.first.count),
            unpackedSize: 22,
            dictionarySize: 128 * 1_024,
            limits: ReadLimits(),
            solidState: state
        )
        XCTAssertEqual(
            try drain(first, bufferSize: 3),
            Data("ABCDEFGHHHQRQRSTRSUVRS".utf8)
        )

        // The continuation has no table description. Its first token repeats
        // the prior file's last length/distance, then index-three repeats walk
        // all four carried distances while literals keep results observable.
        let continuation = try RAR5Decoder(
            source: DataByteSource(data: blocks.continuation),
            offset: 0,
            compressedSize: UInt64(blocks.continuation.count),
            unpackedSize: 18,
            dictionarySize: 128 * 1_024,
            limits: ReadLimits(),
            solidState: state
        )
        XCTAssertEqual(
            try drain(continuation, bufferSize: 1),
            Data("UVWXXXYZYZabZacdZa".utf8)
        )

        XCTAssertThrowsError(
            try RAR5Decoder(
                source: DataByteSource(data: blocks.continuation),
                offset: 0,
                compressedSize: UInt64(blocks.continuation.count),
                unpackedSize: 18,
                dictionarySize: 128 * 1_024,
                limits: ReadLimits()
            )
        ) { error in
            guard case let .malformed(reason) = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("no Huffman tables"), reason)
        }
    }

    func testGeneratedMatchStreamHandlesShortSourceAndTinyOutputReads() throws {
        try RAR5TestSupport.requireRAR()
        let temporary = try ZipTestSupport.temporaryDirectory(label: "rar5-decoder-stream")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sourceDirectory = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: false
        )
        let repeated = Data(String(repeating: "RAR5 match history 日本語\n", count: 2_048).utf8)
        let payload = repeated
            + RAR5TestSupport.deterministicPayload(count: 8_193, seed: 0x52_41_52_35)
            + repeated
        _ = try ZipTestSupport.write(payload, relativePath: "payload.bin", below: sourceDirectory)
        let archiveURL = temporary.appendingPathComponent("payload.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: sourceDirectory,
            paths: ["payload.bin"],
            archiveURL: archiveURL,
            options: ["-m5", "-s-", "-qo-", "-md1m"]
        )

        let archive = try Data(contentsOf: archiveURL)
        let layouts = try RAR5TestSupport.blockLayouts(in: [UInt8](archive))
        let packedRange = try XCTUnwrap(layouts.first { !$0.data.isEmpty }?.data)
        let packed = archive.subdata(in: packedRange)
        let reader = try ArchiveReader.open(data: archive)
        let entry = try XCTUnwrap(reader.entries.first)
        let dictionarySize = try XCTUnwrap(
            UInt64(try XCTUnwrap(entry.formatSpecific["dictionarySize"]))
        )

        for (sourceChunk, outputChunk) in [(1, 1), (3, 7), (31, 257), (packed.count, 65_537)] {
            let prefix = Data(repeating: 0xa5, count: 13)
            let container = prefix + packed + Data(repeating: 0x5a, count: 11)
            let source = RAR5DecoderShortByteSource(
                data: container,
                maximumReadSize: sourceChunk
            )
            let decoder = try RAR5Decoder(
                source: source,
                offset: UInt64(prefix.count),
                compressedSize: UInt64(packed.count),
                unpackedSize: UInt64(payload.count),
                dictionarySize: dictionarySize,
                limits: ReadLimits()
            )
            XCTAssertEqual(try drain(decoder, bufferSize: outputChunk), payload)
            XCTAssertTrue(decoder.isFinished)
        }
    }

    func testSourceFailuresAndInvalidCountsAreThrownWithoutAborting() throws {
        let compressed = makeLiteralBlock(
            byte: 0x58,
            count: 16,
            includesTables: true,
            isLast: true
        )

        for _ in 0..<4 {
            let throwing = RAR5DecoderAdversarialByteSource(
                data: compressed,
                behavior: .throwAfterFirstRead
            )
            XCTAssertThrowsError(
                try makeDecoder(
                    source: throwing,
                    compressedSize: compressed.count,
                    expectedSize: 16
                )
            ) { error in
                guard case SyntheticReadError.failed = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }

        for behavior in [
            RAR5DecoderAdversarialByteSource.Behavior.zero,
            .negative,
            .tooLarge,
        ] {
            let source = RAR5DecoderAdversarialByteSource(
                data: compressed,
                behavior: behavior
            )
            XCTAssertThrowsError(
                try makeDecoder(
                    source: source,
                    compressedSize: compressed.count,
                    expectedSize: 16
                )
            ) { error in
                XCTAssertEqual(error as? KaitoError, .truncated)
            }
        }
    }

    func testMalformedBlockHeadersAndTablesAreRejected() throws {
        var badChecksum = makeRawBlock(
            payload: [0],
            validBitCount: 8,
            includesTables: true,
            isLast: true
        )
        badChecksum[1] ^= 0xff
        assertDecoderInitThrows(
            badChecksum,
            category: "malformed",
            containing: "checksum"
        )

        let zeroSizeFlags: UInt8 = 0xc7
        let zeroSize = Data([
            zeroSizeFlags,
            0x5a ^ zeroSizeFlags,
            0,
        ])
        assertDecoderInitThrows(
            zeroSize,
            category: "malformed",
            containing: "size is zero"
        )

        let missingTables = makeRawBlock(
            payload: [0],
            validBitCount: 8,
            includesTables: false,
            isLast: true
        )
        assertDecoderInitThrows(
            missingTables,
            category: "malformed",
            containing: "no Huffman tables"
        )

        let truncatedTables = makeRawBlock(
            payload: [0],
            validBitCount: 8,
            includesTables: true,
            isLast: true
        )
        assertDecoderInitThrows(truncatedTables, category: "truncated")

        var excessiveRun = RAR5DecoderBitWriter()
        for _ in 0..<19 { excessiveRun.append(0, count: 4) }
        excessiveRun.append(15, count: 4)
        excessiveRun.append(1, count: 4)
        let excessiveRunBlock = makeRawBlock(
            payload: excessiveRun.bytes,
            validBitCount: excessiveRun.validBitsInFinalByte,
            includesTables: true,
            isLast: true
        )
        assertDecoderInitThrows(
            excessiveRunBlock,
            category: "malformed",
            containing: "bit-length run exceeds"
        )
    }

    func testMalformedAndUnsupportedFilterParametersAreRejected() throws {
        let excessiveLength = makeFilterBlock(
            relativeStart: 0,
            length: 4 * 1_024 * 1_024 + 1,
            type: 0,
            channelsMinusOne: 0
        )
        assertDecoderReadThrows(
            excessiveLength,
            expectedSize: nil,
            category: "malformed",
            containing: "filter parameters"
        )

        let beyondOutput = makeFilterBlock(
            relativeStart: 0,
            length: 2,
            type: 0,
            channelsMinusOne: 0
        )
        assertDecoderReadThrows(
            beyondOutput,
            expectedSize: 1,
            category: "malformed",
            containing: "filter range exceeds output"
        )

        let unsupportedType = makeFilterBlock(
            relativeStart: 0,
            length: 1,
            type: 4,
            channelsMinusOne: nil
        )
        assertDecoderReadThrows(
            unsupportedType,
            expectedSize: nil,
            category: "unsupported",
            containing: "filter type 4"
        )

        var limits = ReadLimits()
        limits.maxMetadataRecordCount = 0
        let decoder = try makeDecoder(
            source: DataByteSource(data: makeFilterBlock(
                relativeStart: 0,
                length: 1,
                type: 0,
                channelsMinusOne: 0
            )),
            compressedSize: makeFilterBlock(
                relativeStart: 0,
                length: 1,
                type: 0,
                channelsMinusOne: 0
            ).count,
            expectedSize: nil,
            limits: limits
        )
        XCTAssertThrowsError(try drain(decoder, bufferSize: 8)) { error in
            guard case let .limitExceeded(reason) = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("filter count"), reason)
        }
    }

    func testUnknownSizeFutureFilterFailsTruncatedAfterRawStreamEnds() throws {
        let futureFilter = makeFilterBlock(
            relativeStart: 1,
            length: 1,
            type: 1,
            channelsMinusOne: nil
        )
        assertDecoderReadThrows(
            futureFilter,
            expectedSize: nil,
            category: "truncated",
            containing: ""
        )
    }

    func testDeltaFilterOutputResumesAcrossArbitraryBufferSizes() throws {
        let filteredLength = 200_123
        let compressed = makeRepeatingLiteralFilterBlock(
            byte: 1,
            count: filteredLength,
            type: 0,
            channelsMinusOne: 0
        )
        var expectedBytes: [UInt8] = []
        expectedBytes.reserveCapacity(filteredLength)
        var sample: UInt8 = 0
        for _ in 0..<filteredLength {
            sample &-= 1
            expectedBytes.append(sample)
        }
        let expected = Data(expectedBytes)

        for outputChunk in [4_096, 100_000, 65_537] {
            let decoder = try makeDecoder(
                source: DataByteSource(data: compressed),
                compressedSize: compressed.count,
                expectedSize: filteredLength
            )
            XCTAssertEqual(try drain(decoder, bufferSize: outputChunk), expected)
            XCTAssertTrue(decoder.isFinished)
        }
    }

    func testE8FilterOutputResumesAcrossArbitraryBufferSizes() throws {
        let encoded = [[UInt8]](
            repeating: [0xe8, 0, 0, 0, 0],
            count: 40_025
        ).flatMap { $0 }
        let compressed = makeLiteralSequenceFilterBlock(
            encoded,
            type: 1
        )
        var expectedBytes = encoded
        try RARStandardFilters.e8(
            &expectedBytes,
            fileOffset: 0,
            includeE9: false
        )
        XCTAssertNotEqual(expectedBytes, encoded)
        let expected = Data(expectedBytes)

        for outputChunk in [4_096, 100_000, 65_537] {
            let decoder = try makeDecoder(
                source: DataByteSource(data: compressed),
                compressedSize: compressed.count,
                expectedSize: encoded.count
            )
            XCTAssertEqual(try drain(decoder, bufferSize: outputChunk), expected)
            XCTAssertTrue(decoder.isFinished)
        }
    }

    func testDeterministicFilterPayloadMutantsCompleteBoundedly() throws {
        let expectedSize = 4_097
        let seed = makeRepeatingLiteralFilterBlock(
            byte: 1,
            count: expectedSize,
            type: 0,
            channelsMinusOne: 0
        )
        let limits = ReadLimits(
            maxEntrySize: 8 * 1_024,
            maxTotalUncompressedSize: 8 * 1_024,
            maxInMemorySize: 8 * 1_024,
            inMemorySingleFileLimit: 8 * 1_024,
            maxEntryCount: 1,
            maxMetadataSize: 8 * 1_024,
            maxMetadataRecordCount: 16,
            maxPathComponentCount: 4,
            maxTotalMetadataSize: 8 * 1_024,
            maxDictionarySize: 128 * 1_024,
            maxVolumeCount: 1,
            maxRAR5HeaderKDFWork: 1
        )
        let mutationCount = 128
        let batch = BoundedPayloadMutationBatch {
            var completed = 0
            for mutation in 0..<mutationCount {
                var bytes = [UInt8](seed)
                let first = (mutation &* 131 &+ 17) % bytes.count
                bytes[first] ^= UInt8(1) << UInt8(mutation % 8)
                if mutation.isMultiple(of: 7), bytes.count > 1 {
                    let second = (mutation &* 43 &+ 5) % bytes.count
                    bytes[second] ^= 0x80
                }

                do {
                    let decoder = try RAR5Decoder(
                        source: DataByteSource(data: Data(bytes)),
                        offset: 0,
                        compressedSize: UInt64(bytes.count),
                        unpackedSize: UInt64(expectedSize),
                        dictionarySize: 128 * 1_024,
                        limits: limits
                    )
                    try PayloadMutationTestSupport.drain(
                        decoder,
                        bufferSize: 257,
                        maximumIterations: 8_192
                    )
                } catch is KaitoError {
                    // A structured rejection is expected for most packed mutations.
                } catch {
                    return .unexpected("RAR5 filter mutation (mutation): \(error)")
                }
                completed += 1
            }
            return .completed(completed)
        }
        batch.start()
        guard let outcome = batch.wait(timeout: .now() + 10) else {
            return XCTFail("RAR5 filter mutation batch exceeded 10 seconds")
        }
        switch outcome {
        case let .completed(completed):
            XCTAssertEqual(completed, mutationCount)
        case let .unexpected(description):
            XCTFail(description)
        }
    }

    private func makeDecoder(
        source: any ByteSource,
        compressedSize: Int,
        expectedSize: Int?,
        limits: ReadLimits = ReadLimits()
    ) throws -> RAR5Decoder {
        try RAR5Decoder(
            source: source,
            offset: 0,
            compressedSize: UInt64(compressedSize),
            unpackedSize: expectedSize.map(UInt64.init),
            dictionarySize: 128 * 1_024,
            limits: limits
        )
    }

    private func drain(_ decoder: any Decompressor, bufferSize: Int) throws -> Data {
        precondition(bufferSize > 0)
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var iterations = 0
        while !decoder.isFinished {
            let count = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
            guard count > 0 || decoder.isFinished else {
                throw KaitoError.malformed("RAR5 test decoder made no progress")
            }
            result.append(contentsOf: buffer.prefix(count))
            iterations += 1
            guard iterations <= 1_000_000 else {
                throw KaitoError.malformed("RAR5 test decoder did not terminate")
            }
        }
        return result
    }

    private func makeLiteralBlock(
        byte: UInt8,
        count: Int,
        includesTables: Bool,
        isLast: Bool
    ) -> Data {
        precondition(count > 0)
        var bits = RAR5DecoderBitWriter()
        if includesTables {
            appendSingleMainSymbolTables(symbol: Int(byte), to: &bits)
        }
        for _ in 0..<count { bits.append(0, count: 1) }
        return makeRawBlock(
            payload: bits.bytes,
            validBitCount: bits.validBitsInFinalByte,
            includesTables: includesTables,
            isLast: isLast
        )
    }

    private func makeSyntheticSolidStateBlocks() -> (
        first: Data,
        continuation: Data
    ) {
        let mainSymbols = Array(65...72)
            + Array(81...90)
            + Array(97...100)
            + [257, 261, 262]
        precondition(mainSymbols.count <= 32)
        let sortedMainSymbols = mainSymbols.sorted()

        func appendMain(_ symbol: Int, to bits: inout RAR5DecoderBitWriter) {
            let code = sortedMainSymbols.firstIndex(of: symbol)!
            bits.append(code, count: 5)
        }
        func appendNewMatch(
            distanceSlot: Int,
            to bits: inout RAR5DecoderBitWriter
        ) {
            appendMain(262, to: &bits) // length slot zero => length two
            bits.append(distanceSlot, count: 2)
        }
        func appendRepeatIndexThree(to bits: inout RAR5DecoderBitWriter) {
            appendMain(261, to: &bits)
            bits.append(0, count: 1) // repeat-length slot zero => length two
        }

        var first = RAR5DecoderBitWriter()
        // Code-length alphabet: symbols 0, 1, 2 and 5 use canonical two-bit
        // codes 00, 01, 10 and 11 respectively.
        for symbol in 0..<20 {
            first.append([0, 1, 2, 5].contains(symbol) ? 2 : 0, count: 4)
        }
        let repeatLengthStart = 306 + 64 + 16
        for index in 0..<430 {
            let length: Int
            if index < 306, sortedMainSymbols.contains(index) {
                length = 5
            } else if (306..<(306 + 4)).contains(index) {
                length = 2
            } else if index == repeatLengthStart {
                length = 1
            } else {
                length = 0
            }
            let code: Int
            switch length {
            case 0: code = 0
            case 1: code = 1
            case 2: code = 2
            case 5: code = 3
            default: preconditionFailure("unexpected synthetic table length")
            }
            first.append(code, count: 2)
        }

        for literal in 65...72 { appendMain(literal, to: &first) }
        appendNewMatch(distanceSlot: 0, to: &first)
        for literal in 81...82 { appendMain(literal, to: &first) }
        appendNewMatch(distanceSlot: 1, to: &first)
        for literal in 83...84 { appendMain(literal, to: &first) }
        appendNewMatch(distanceSlot: 2, to: &first)
        for literal in 85...86 { appendMain(literal, to: &first) }
        appendNewMatch(distanceSlot: 3, to: &first)

        var continuation = RAR5DecoderBitWriter()
        appendMain(257, to: &continuation)
        for pair in [(87, 88), (89, 90), (97, 98), (99, 100)] {
            appendMain(pair.0, to: &continuation)
            appendMain(pair.1, to: &continuation)
            appendRepeatIndexThree(to: &continuation)
        }

        return (
            makeRawBlock(
                payload: first.bytes,
                validBitCount: first.validBitsInFinalByte,
                includesTables: true,
                isLast: true
            ),
            makeRawBlock(
                payload: continuation.bytes,
                validBitCount: continuation.validBitsInFinalByte,
                includesTables: false,
                isLast: true
            )
        )
    }

    private func makeFilterBlock(
        relativeStart: UInt32,
        length: UInt32,
        type: Int,
        channelsMinusOne: Int?
    ) -> Data {
        var bits = RAR5DecoderBitWriter()
        appendSingleMainSymbolTables(symbol: 256, to: &bits)
        bits.append(0, count: 1) // The sole main-table symbol is filter (256).
        appendFilterInteger(relativeStart, to: &bits)
        appendFilterInteger(length, to: &bits)
        bits.append(type, count: 3)
        if let channelsMinusOne { bits.append(channelsMinusOne, count: 5) }
        return makeRawBlock(
            payload: bits.bytes,
            validBitCount: bits.validBitsInFinalByte,
            includesTables: true,
            isLast: true
        )
    }

    private func makeRepeatingLiteralFilterBlock(
        byte: UInt8,
        count: Int,
        type: Int,
        channelsMinusOne: Int?
    ) -> Data {
        precondition(count > 0 && count <= Int(UInt32.max))
        var bits = RAR5DecoderBitWriter()
        appendTwoMainSymbolTables(first: Int(byte), second: 256, to: &bits)
        bits.append(1, count: 1) // Symbol 256 schedules the filter at offset zero.
        appendFilterInteger(0, to: &bits)
        appendFilterInteger(UInt32(count), to: &bits)
        bits.append(type, count: 3)
        if let channelsMinusOne { bits.append(channelsMinusOne, count: 5) }
        for _ in 0..<count {
            bits.append(0, count: 1) // The lower main symbol is the literal byte.
        }
        return makeRawBlock(
            payload: bits.bytes,
            validBitCount: bits.validBitsInFinalByte,
            includesTables: true,
            isLast: true
        )
    }

    private func makeLiteralSequenceFilterBlock(
        _ bytes: [UInt8],
        type: Int
    ) -> Data {
        precondition(!bytes.isEmpty && bytes.count <= Int(UInt32.max))
        let symbols = Array(Set(bytes.map(Int.init)).union([256])).sorted()
        precondition(symbols.count == 3)

        var bits = RAR5DecoderBitWriter()
        // Code-length symbols 0 and 2 form one-bit codes. The three main
        // symbols then receive canonical two-bit codes 00, 01, and 10.
        for index in 0..<20 {
            bits.append(index == 0 || index == 2 ? 1 : 0, count: 4)
        }
        for index in 0..<430 {
            bits.append(symbols.contains(index) ? 1 : 0, count: 1)
        }
        func appendSymbol(_ symbol: Int) {
            bits.append(symbols.firstIndex(of: symbol)!, count: 2)
        }

        appendSymbol(256)
        appendFilterInteger(0, to: &bits)
        appendFilterInteger(UInt32(bytes.count), to: &bits)
        bits.append(type, count: 3)
        for byte in bytes { appendSymbol(Int(byte)) }

        return makeRawBlock(
            payload: bits.bytes,
            validBitCount: bits.validBitsInFinalByte,
            includesTables: true,
            isLast: true
        )
    }

    private func appendSingleMainSymbolTables(
        symbol: Int,
        to bits: inout RAR5DecoderBitWriter
    ) {
        precondition((0..<306).contains(symbol))
        // The bit-length alphabet has two one-bit codes: 0 -> 0 and 1 -> 1.
        for index in 0..<20 { bits.append(index < 2 ? 1 : 0, count: 4) }
        for index in 0..<430 { bits.append(index == symbol ? 1 : 0, count: 1) }
    }

    private func appendTwoMainSymbolTables(
        first: Int,
        second: Int,
        to bits: inout RAR5DecoderBitWriter
    ) {
        precondition((0..<306).contains(first))
        precondition((0..<306).contains(second))
        precondition(first < second)
        // The bit-length alphabet has two one-bit codes: 0 -> 0 and 1 -> 1.
        for index in 0..<20 { bits.append(index < 2 ? 1 : 0, count: 4) }
        for index in 0..<430 {
            bits.append(index == first || index == second ? 1 : 0, count: 1)
        }
    }

    private func appendFilterInteger(
        _ value: UInt32,
        to bits: inout RAR5DecoderBitWriter
    ) {
        let byteCount: Int
        if value <= 0xff {
            byteCount = 1
        } else if value <= 0xffff {
            byteCount = 2
        } else if value <= 0xff_ffff {
            byteCount = 3
        } else {
            byteCount = 4
        }
        bits.append(byteCount - 1, count: 2)
        for index in 0..<byteCount {
            bits.append(Int((value >> UInt32(index * 8)) & 0xff), count: 8)
        }
    }

    private func makeRawBlock(
        payload: [UInt8],
        validBitCount: Int,
        includesTables: Bool,
        isLast: Bool
    ) -> Data {
        precondition(!payload.isEmpty)
        precondition((1...8).contains(validBitCount))
        precondition(payload.count <= 0xff_ffff)
        let sizeByteCount: Int
        if payload.count <= 0xff {
            sizeByteCount = 1
        } else if payload.count <= 0xffff {
            sizeByteCount = 2
        } else {
            sizeByteCount = 3
        }
        var flags = UInt8(validBitCount - 1)
        flags |= UInt8(sizeByteCount - 1) << 3
        if isLast { flags |= 0x40 }
        if includesTables { flags |= 0x80 }

        var sizeBytes: [UInt8] = []
        for index in 0..<sizeByteCount {
            sizeBytes.append(UInt8(truncatingIfNeeded: payload.count >> (index * 8)))
        }
        var checksum = UInt8(0x5a) ^ flags
        for byte in sizeBytes { checksum ^= byte }
        return Data([flags, checksum] + sizeBytes + payload)
    }

    private func assertDecoderInitThrows(
        _ compressed: Data,
        category: String,
        containing fragment: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try makeDecoder(
                source: DataByteSource(data: compressed),
                compressedSize: compressed.count,
                expectedSize: nil
            ),
            file: file,
            line: line
        ) { error in
            assert(error, category: category, containing: fragment, file: file, line: line)
        }
    }

    private func assertDecoderReadThrows(
        _ compressed: Data,
        expectedSize: Int?,
        category: String,
        containing fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNoThrow(
            try makeDecoder(
                source: DataByteSource(data: compressed),
                compressedSize: compressed.count,
                expectedSize: expectedSize
            ),
            file: file,
            line: line
        )
        do {
            let decoder = try makeDecoder(
                source: DataByteSource(data: compressed),
                compressedSize: compressed.count,
                expectedSize: expectedSize
            )
            XCTAssertThrowsError(try drain(decoder, bufferSize: 8), file: file, line: line) {
                assert($0, category: category, containing: fragment, file: file, line: line)
            }
        } catch {
            XCTFail("decoder initialization failed unexpectedly: \(error)", file: file, line: line)
        }
    }

    private func assert(
        _ error: Error,
        category: String,
        containing fragment: String?,
        file: StaticString,
        line: UInt
    ) {
        switch (category, error as? KaitoError) {
        case ("truncated", .truncated):
            return
        case ("malformed", let .malformed(reason)),
             ("unsupported", let .unsupportedMethod(reason)):
            if let fragment {
                XCTAssertTrue(reason.contains(fragment), reason, file: file, line: line)
            }
        default:
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }
}

private struct RAR5DecoderBitWriter {
    private(set) var bytes: [UInt8] = []
    private(set) var bitCount = 0

    var validBitsInFinalByte: Int {
        precondition(bitCount > 0)
        return (bitCount - 1) % 8 + 1
    }

    mutating func append(_ value: Int, count: Int) {
        precondition((0...32).contains(count))
        if count < Int.bitWidth { precondition(value >= 0 && value < 1 << count) }
        for shift in stride(from: count - 1, through: 0, by: -1) {
            if bitCount.isMultiple(of: 8) { bytes.append(0) }
            if value & (1 << shift) != 0 {
                bytes[bytes.count - 1] |= 1 << (7 - bitCount % 8)
            }
            bitCount += 1
        }
    }
}

private final class RAR5DecoderShortByteSource: ByteSource {
    private let source: DataByteSource
    private let maximumReadSize: Int

    var length: UInt64 { source.length }

    init(data: Data, maximumReadSize: Int) {
        precondition(maximumReadSize > 0)
        self.source = DataByteSource(data: data)
        self.maximumReadSize = maximumReadSize
    }

    func read(
        into buffer: UnsafeMutableRawBufferPointer,
        at offset: UInt64
    ) throws -> Int {
        let count = min(buffer.count, maximumReadSize)
        return try source.read(
            into: UnsafeMutableRawBufferPointer(rebasing: buffer[..<count]),
            at: offset
        )
    }
}

private final class RAR5DecoderAdversarialByteSource: ByteSource, @unchecked Sendable {
    enum Behavior {
        case throwAfterFirstRead
        case zero
        case negative
        case tooLarge
    }

    private let data: Data
    private let behavior: Behavior
    private let lock = NSLock()
    private var readCount = 0

    var length: UInt64 { UInt64(data.count) }

    init(data: Data, behavior: Behavior) {
        self.data = data
        self.behavior = behavior
    }

    func read(
        into buffer: UnsafeMutableRawBufferPointer,
        at offset: UInt64
    ) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        switch behavior {
        case .throwAfterFirstRead:
            guard readCount == 0 else { throw RAR5DecoderTests.SyntheticReadError.failed }
            readCount += 1
            let count = min(buffer.count, 3)
            return data.withUnsafeBytes { bytes in
                guard count > 0,
                      let destination = buffer.baseAddress,
                      let source = bytes.baseAddress else { return 0 }
                destination.copyMemory(
                    from: source.advanced(by: Int(offset)),
                    byteCount: count
                )
                return count
            }
        case .zero:
            return 0
        case .negative:
            return -1
        case .tooLarge:
            return buffer.count + 1
        }
    }
}
