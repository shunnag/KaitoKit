import Foundation
import KaitoKit
import XCTest

final class LZMADecoderTests: XCTestCase {
    private enum TestError: Error {
        case invalidHex
        case noProgress
    }

    func testEndMarkedStreamWithDictionaryWrapAndTinyReads() throws {
        let compressed = try decodeHex(
            "002598492777f6198bfb55ec9f9870645187a7c68eabd4c78b5b16ef162410c2" +
            "4140807bfabb0caa78f7675954c402235e482aa24588f9b0fa9e349dfb09dd9a" +
            "037b33600bfffbbd90d6385b994ec2b712fe8e04f8e7eb2c125e32bec1e8186" +
            "5a3dea28c3ecfa16c19f1ce9c01f1408a230581994fc73bd7468d9e01fc3db4" +
            "f52b870f875744d345416bad2fffffe7e0e000"
        )
        var expected = Data()
        for _ in 0..<500 {
            expected.append(Data("KaitoKit-LZMA-streaming-".utf8))
        }
        for _ in 0..<30 {
            expected.append(contentsOf: UInt8(0)..<UInt8(64))
        }

        let decoder = try makeDecoder(
            compressed,
            dictionarySize: 4_096,
            expectedSize: nil
        )
        XCTAssertEqual(try drain(decoder, bufferSize: 7), expected)
        XCTAssertTrue(decoder.isFinished)
    }

    func testKnownSizeDoesNotRequireEndMarker() throws {
        // 最後の end marker とレンジ符号化終端を除いた raw LZMA1 データ。
        let compressed = try decodeHex("00309888aa02a643ebffffb580")
        let expected = Data("abcabcabcabcabcabc".utf8)
        let decoder = try makeDecoder(
            compressed,
            dictionarySize: 65_536,
            expectedSize: UInt64(expected.count)
        )

        XCTAssertEqual(try drain(decoder, bufferSize: 1), expected)
        XCTAssertTrue(decoder.isFinished)
    }

    func testEndMarkerBeforeKnownSizeIsMalformed() throws {
        let compressed = try decodeHex("0083fffbffffc0000000")
        let decoder = try makeDecoder(
            compressed,
            dictionarySize: 65_536,
            expectedSize: 1
        )

        XCTAssertThrowsError(try drain(decoder, bufferSize: 8)) { error in
            guard case let .malformed(reason) = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("end marker"))
        }
    }

    func testEndMarkedStreamRejectsTruncation() throws {
        let compressed = try decodeHex("00309888aa02a643ebffffb580")
        let decoder = try makeDecoder(
            compressed,
            dictionarySize: 65_536,
            expectedSize: nil
        )

        XCTAssertThrowsError(try drain(decoder, bufferSize: 2)) { error in
            XCTAssertEqual(error as? KaitoError, .truncated)
        }
    }

    func testRejectsDictionaryBeyondLimitBeforeAllocation() throws {
        let compressed = try decodeHex("00309888aa02a643ebffffb5800000")
        XCTAssertThrowsError(
            try makeDecoder(
                compressed,
                dictionarySize: 65_536,
                expectedSize: 18,
                dictionarySizeLimit: 65_535
            )
        ) { error in
            guard case .limitExceeded = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testRejectsInvalidPropertiesAndRangeInitialization() throws {
        let source = DataByteSource(Data(repeating: 0, count: 5))
        XCTAssertThrowsError(
            try LZMADecoder(
                source: source,
                offset: 0,
                compressedSize: 5,
                properties: [225, 0, 0, 1, 0],
                expectedSize: nil,
                dictionarySizeLimit: 1 << 20
            )
        ) { error in
            guard case .malformed = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let badInitialization = Data([1, 0, 0, 0, 0])
        XCTAssertThrowsError(
            try makeDecoder(
                badInitialization,
                dictionarySize: 65_536,
                expectedSize: nil
            )
        ) { error in
            guard case .malformed = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    private func makeDecoder(
        _ compressed: Data,
        dictionarySize: UInt32,
        expectedSize: UInt64?,
        dictionarySizeLimit: UInt64 = 1 << 20
    ) throws -> LZMADecoder {
        try LZMADecoder(
            source: DataByteSource(compressed),
            offset: 0,
            compressedSize: UInt64(compressed.count),
            properties: [
                0x5D,
                UInt8(dictionarySize & 0xFF),
                UInt8((dictionarySize >> 8) & 0xFF),
                UInt8((dictionarySize >> 16) & 0xFF),
                UInt8((dictionarySize >> 24) & 0xFF),
            ],
            expectedSize: expectedSize,
            dictionarySizeLimit: dictionarySizeLimit
        )
    }

    private func drain(_ decoder: any Decompressor, bufferSize: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var iterations = 0
        while !decoder.isFinished {
            let count = try buffer.withUnsafeMutableBytes { storage in
                // storage は固定長配列の全領域で、decoder はその範囲内だけを書く。
                try decoder.read(into: storage)
            }
            guard count > 0 || decoder.isFinished else {
                throw TestError.noProgress
            }
            result.append(contentsOf: buffer.prefix(count))
            iterations += 1
            guard iterations < 100_000 else {
                throw TestError.noProgress
            }
        }
        return result
    }

    private func decodeHex(_ text: String) throws -> Data {
        guard text.utf8.count.isMultiple(of: 2) else {
            throw TestError.invalidHex
        }
        var result = Data()
        var index = text.startIndex
        while index < text.endIndex {
            guard let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex),
                  let byte = UInt8(text[index..<next], radix: 16) else {
                throw TestError.invalidHex
            }
            result.append(byte)
            index = next
        }
        return result
    }
}
