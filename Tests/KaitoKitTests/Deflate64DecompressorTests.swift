import Foundation
import KaitoKit
import XCTest

final class Deflate64DecompressorTests: XCTestCase {
    private enum TestError: Error {
        case decoderMadeNoProgress
    }

    func testStoredAndFixedBlocksStreamAcrossTinyBuffers() throws {
        var writer = Deflate64TestBitWriter()

        writer.writeLSB(0, count: 1) // 最終ではない block
        writer.writeLSB(0, count: 2) // stored 方式
        writer.alignToByte()
        writer.writeUInt16LE(3)
        writer.writeUInt16LE(~UInt16(3))
        writer.writeAlignedBytes(Array("abc".utf8))

        let fixed = Self.fixedCodes()
        writer.writeLSB(1, count: 1) // 最終 block
        writer.writeLSB(1, count: 2) // 固定 Huffman
        for byte in "XYZ".utf8 {
            writer.writeHuffman(Int(byte), codes: fixed)
        }
        writer.writeHuffman(256, codes: fixed)

        let compressed = writer.data
        let decoder = try Deflate64Decompressor(
            source: DataByteSource(data: compressed),
            offset: 0,
            compressedSize: UInt64(compressed.count),
            expectedSize: 6
        )
        XCTAssertEqual(try drain(decoder, bufferSize: 1), Data("abcXYZ".utf8))
        XCTAssertTrue(decoder.isFinished)
    }

    func testDynamicLiteralOnlyBlockAllowsAbsentDistanceAlphabet() throws {
        var writer = Deflate64TestBitWriter()
        writer.writeLSB(1, count: 1) // 最終 block
        writer.writeLSB(2, count: 2) // 動的 Huffman
        writer.writeLSB(0, count: 5) // HLIT = 257
        writer.writeLSB(0, count: 5) // HDIST = 1
        writer.writeLSB(14, count: 4) // HCLEN = 18

        let codeLengthOrder = [
            16, 17, 18, 0, 8, 7, 9, 6, 10, 5,
            11, 4, 12, 3, 13, 2, 14, 1, 15,
        ]
        var codeLengthLengths = [UInt8](repeating: 0, count: 19)
        codeLengthLengths[18] = 1
        codeLengthLengths[0] = 2
        codeLengthLengths[1] = 2
        for index in 0..<18 {
            writer.writeLSB(
                UInt32(codeLengthLengths[codeLengthOrder[index]]),
                count: 3
            )
        }

        let codeLengthCodes = Self.canonicalCodes(codeLengthLengths)
        writer.writeHuffman(18, codes: codeLengthCodes)
        writer.writeLSB(54, count: 7) // 0 を 65 個
        writer.writeHuffman(1, codes: codeLengthCodes)
        writer.writeHuffman(18, codes: codeLengthCodes)
        writer.writeLSB(127, count: 7) // 0 を 138 個
        writer.writeHuffman(18, codes: codeLengthCodes)
        writer.writeLSB(41, count: 7) // 0 を 52 個
        writer.writeHuffman(1, codes: codeLengthCodes)
        writer.writeHuffman(0, codes: codeLengthCodes) // distance code 無し

        var literalLengths = [UInt8](repeating: 0, count: 257)
        literalLengths[65] = 1
        literalLengths[256] = 1
        let literalCodes = Self.canonicalCodes(literalLengths)
        writer.writeHuffman(65, codes: literalCodes)
        writer.writeHuffman(256, codes: literalCodes)

        let compressed = writer.data
        let decoder = try Deflate64Decompressor(
            source: DataByteSource(data: compressed),
            offset: 0,
            compressedSize: UInt64(compressed.count),
            expectedSize: 1
        )
        XCTAssertEqual(try drain(decoder, bufferSize: 7), Data([65]))
    }

    func testDynamicLiteralOnlyBlockRejectsMultipleEmptyDistanceCodes() throws {
        var writer = Deflate64TestBitWriter()
        writer.writeLSB(1, count: 1) // 最終 block
        writer.writeLSB(2, count: 2) // 動的 Huffman
        writer.writeLSB(0, count: 5) // HLIT = 257
        writer.writeLSB(1, count: 5) // HDIST = 2
        writer.writeLSB(14, count: 4) // HCLEN = 18

        let codeLengthOrder = [
            16, 17, 18, 0, 8, 7, 9, 6, 10, 5,
            11, 4, 12, 3, 13, 2, 14, 1, 15,
        ]
        var codeLengthLengths = [UInt8](repeating: 0, count: 19)
        codeLengthLengths[18] = 1
        codeLengthLengths[0] = 2
        codeLengthLengths[1] = 2
        for index in 0..<18 {
            writer.writeLSB(
                UInt32(codeLengthLengths[codeLengthOrder[index]]),
                count: 3
            )
        }

        let codeLengthCodes = Self.canonicalCodes(codeLengthLengths)
        writer.writeHuffman(18, codes: codeLengthCodes)
        writer.writeLSB(54, count: 7) // 0 を 65 個
        writer.writeHuffman(1, codes: codeLengthCodes)
        writer.writeHuffman(18, codes: codeLengthCodes)
        writer.writeLSB(127, count: 7) // 0 を 138 個
        writer.writeHuffman(18, codes: codeLengthCodes)
        writer.writeLSB(41, count: 7) // 0 を 52 個
        writer.writeHuffman(1, codes: codeLengthCodes)
        writer.writeHuffman(0, codes: codeLengthCodes)
        writer.writeHuffman(0, codes: codeLengthCodes) // 空の distance code が二個

        let compressed = writer.data
        let decoder = try Deflate64Decompressor(
            source: DataByteSource(data: compressed),
            offset: 0,
            compressedSize: UInt64(compressed.count),
            expectedSize: 1
        )

        XCTAssertThrowsError(try drain(decoder, bufferSize: 7)) { error in
            guard case KaitoError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
    }

    func testLength258HasBothCode284AndDeflate64Code285Forms() throws {
        var writer = Deflate64TestBitWriter()
        let literalCodes = Self.fixedCodes()
        let distanceCodes = Self.canonicalCodes([UInt8](repeating: 5, count: 32))
        writer.writeLSB(1, count: 1)
        writer.writeLSB(1, count: 2)
        writer.writeHuffman(66, codes: literalCodes)

        writer.writeHuffman(284, codes: literalCodes)
        writer.writeLSB(31, count: 5) // 227 + 31 = 258
        writer.writeHuffman(0, codes: distanceCodes) // 距離 1

        writer.writeHuffman(285, codes: literalCodes)
        writer.writeLSB(255, count: 16) // Deflate64 では 3 + 255 = 258
        writer.writeHuffman(0, codes: distanceCodes)
        writer.writeHuffman(256, codes: literalCodes)

        let compressed = writer.data
        let decoder = try Deflate64Decompressor(
            source: DataByteSource(data: compressed),
            offset: 0,
            compressedSize: UInt64(compressed.count),
            expectedSize: 517
        )
        XCTAssertEqual(
            try drain(decoder, bufferSize: 13),
            Data(repeating: 66, count: 517)
        )
    }

    func testMaximumLengthAndDistanceCodesCrossWindowBoundary() throws {
        var writer = Deflate64TestBitWriter()
        let literalCodes = Self.fixedCodes()
        let distanceCodes = Self.canonicalCodes([UInt8](repeating: 5, count: 32))
        writer.writeLSB(1, count: 1)
        writer.writeLSB(1, count: 2)
        writer.writeHuffman(65, codes: literalCodes)
        writer.writeHuffman(285, codes: literalCodes)
        writer.writeLSB(UInt32(UInt16.max), count: 16) // 長さ 65,538
        writer.writeHuffman(0, codes: distanceCodes) // 距離 1
        writer.writeHuffman(257, codes: literalCodes) // 長さ 3
        writer.writeHuffman(31, codes: distanceCodes)
        writer.writeLSB(16_383, count: 14) // 距離 65,536
        writer.writeHuffman(256, codes: literalCodes)

        let expectedCount = 65_542
        let compressed = writer.data
        let decoder = try Deflate64Decompressor(
            source: DataByteSource(data: compressed),
            offset: 0,
            compressedSize: UInt64(compressed.count),
            expectedSize: UInt64(expectedCount)
        )
        XCTAssertEqual(
            try drain(decoder, bufferSize: 257),
            Data(repeating: 65, count: expectedCount)
        )
    }

    func testReservedLiteralLengthSymbolIsRejected() throws {
        var writer = Deflate64TestBitWriter()
        writer.writeLSB(1, count: 1)
        writer.writeLSB(1, count: 2)
        writer.writeHuffman(286, codes: Self.fixedCodes())
        let compressed = writer.data
        let decoder = try Deflate64Decompressor(
            source: DataByteSource(data: compressed),
            offset: 0,
            compressedSize: UInt64(compressed.count),
            expectedSize: nil
        )

        XCTAssertThrowsError(try drain(decoder, bufferSize: 8)) { error in
            guard case KaitoError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
    }

    func testMatchCannotReferBeforeProducedHistory() throws {
        var writer = Deflate64TestBitWriter()
        let literalCodes = Self.fixedCodes()
        let distanceCodes = Self.canonicalCodes([UInt8](repeating: 5, count: 32))
        writer.writeLSB(1, count: 1)
        writer.writeLSB(1, count: 2)
        writer.writeHuffman(257, codes: literalCodes) // length 3 before any literal
        writer.writeHuffman(0, codes: distanceCodes) // distance 1, but history is empty

        let compressed = writer.data
        let decoder = try Deflate64Decompressor(
            source: DataByteSource(data: compressed),
            offset: 0,
            compressedSize: UInt64(compressed.count),
            expectedSize: 3
        )
        XCTAssertThrowsError(try drain(decoder, bufferSize: 8)) { error in
            guard case KaitoError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
    }

    func testTruncationAndExpectedSizeMismatchAreRejected() throws {
        var writer = Deflate64TestBitWriter()
        let codes = Self.fixedCodes()
        writer.writeLSB(1, count: 1)
        writer.writeLSB(1, count: 2)
        writer.writeHuffman(65, codes: codes)
        writer.writeHuffman(256, codes: codes)
        let compressed = writer.data

        let truncated = Data(compressed.dropLast())
        let truncatedDecoder = try Deflate64Decompressor(
            source: DataByteSource(data: truncated),
            offset: 0,
            compressedSize: UInt64(truncated.count),
            expectedSize: 1
        )
        XCTAssertThrowsError(try drain(truncatedDecoder, bufferSize: 8)) { error in
            XCTAssertEqual(error as? KaitoError, .truncated)
        }

        let mismatchedDecoder = try Deflate64Decompressor(
            source: DataByteSource(data: compressed),
            offset: 0,
            compressedSize: UInt64(compressed.count),
            expectedSize: 2
        )
        XCTAssertThrowsError(try drain(mismatchedDecoder, bufferSize: 8)) { error in
            guard case KaitoError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
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
            guard count > 0 || decoder.isFinished else {
                throw TestError.decoderMadeNoProgress
            }
            result.append(contentsOf: buffer.prefix(count))
            iterations += 1
            guard iterations < 10_000 else {
                throw TestError.decoderMadeNoProgress
            }
        }
        return result
    }

    private static func fixedCodes() -> [Deflate64TestCode] {
        var lengths = [UInt8](repeating: 0, count: 288)
        for symbol in 0...143 { lengths[symbol] = 8 }
        for symbol in 144...255 { lengths[symbol] = 9 }
        for symbol in 256...279 { lengths[symbol] = 7 }
        for symbol in 280...287 { lengths[symbol] = 8 }
        return canonicalCodes(lengths)
    }

    private static func canonicalCodes(_ lengths: [UInt8]) -> [Deflate64TestCode] {
        var counts = [Int](repeating: 0, count: 16)
        for length in lengths where length != 0 {
            counts[Int(length)] += 1
        }
        var nextCode = [Int](repeating: 0, count: 16)
        var code = 0
        for bitLength in 1...15 {
            code = (code + counts[bitLength - 1]) << 1
            nextCode[bitLength] = code
        }

        var result = [Deflate64TestCode](
            repeating: Deflate64TestCode(bits: 0, length: 0),
            count: lengths.count
        )
        for (symbol, lengthByte) in lengths.enumerated() where lengthByte != 0 {
            let length = Int(lengthByte)
            result[symbol] = Deflate64TestCode(bits: nextCode[length], length: length)
            nextCode[length] += 1
        }
        return result
    }
}

private struct Deflate64TestCode {
    let bits: Int
    let length: Int
}

private struct Deflate64TestBitWriter {
    private var bytes: [UInt8] = []
    private var currentByte: UInt8 = 0
    private var bitOffset = 0

    var data: Data {
        var copy = self
        copy.alignToByte()
        return Data(copy.bytes)
    }

    mutating func writeLSB(_ value: UInt32, count: Int) {
        for shift in 0..<count {
            writeBit(Int((value >> shift) & 1))
        }
    }

    mutating func writeHuffman(_ symbol: Int, codes: [Deflate64TestCode]) {
        let code = codes[symbol]
        for shift in stride(from: code.length - 1, through: 0, by: -1) {
            writeBit((code.bits >> shift) & 1)
        }
    }

    mutating func alignToByte() {
        if bitOffset != 0 {
            bytes.append(currentByte)
            currentByte = 0
            bitOffset = 0
        }
    }

    mutating func writeUInt16LE(_ value: UInt16) {
        alignToByte()
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func writeAlignedBytes(_ value: [UInt8]) {
        alignToByte()
        bytes.append(contentsOf: value)
    }

    private mutating func writeBit(_ bit: Int) {
        if bit != 0 {
            currentByte |= UInt8(1 << bitOffset)
        }
        bitOffset += 1
        if bitOffset == 8 {
            bytes.append(currentByte)
            currentByte = 0
            bitOffset = 0
        }
    }
}
