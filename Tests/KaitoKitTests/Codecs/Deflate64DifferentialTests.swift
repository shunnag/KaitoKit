import Foundation
import KaitoKit
import XCTest

final class Deflate64DifferentialTests: XCTestCase {
    private struct Stream {
        let bytes: Data
        let size: UInt64
    }

    private struct Outcome: Equatable {
        var output = Data()
        var error: KaitoError?
        var failedBuffer = Data()
        var finished = false
    }

    func testExistingFixturesAndHandBuiltStreamsMatchReference() throws {
        for stream in try fixtureStreams() + handBuiltStreams() {
            for chunk in [1, 13, 257, 262_144] {
                try compare(stream.bytes, expected: stream.size, chunk: chunk, valid: true)
            }
            // The source can return just one byte at a time, including at EOF.
            try compare(stream.bytes, expected: nil, chunk: 257, sourceChunk: 1, valid: true)
            try compare(stream.bytes + Data([0]), expected: stream.size, chunk: 257)
            try compare(stream.bytes, expected: stream.size + 1, chunk: 257)
            if stream.size > 0 {
                try compare(stream.bytes, expected: stream.size - 1, chunk: 257)
            }
        }
    }

    func testDeterministicBitFlipsAndTruncationsMatchReference() throws {
        let small = handBuiltStreams().filter { $0.size < 1_024 }
        var random = Generator(state: 0x4b61_6974_6f44_3634)
        for index in 0..<4_096 {
            let stream = small[random.int(small.count)]
            var bytes = stream.bytes
            switch index % 4 {
            case 0:
                bytes = Data(bytes.prefix(random.int(bytes.count + 1)))
            case 1, 2:
                for _ in 0..<(1 + random.int(4)) {
                    let bit = random.int(bytes.count * 8)
                    bytes[bit / 8] ^= UInt8(1 << (bit & 7))
                }
            default:
                let bit = random.int(bytes.count * 8)
                bytes[bit / 8] ^= UInt8(1 << (bit & 7))
                bytes = Data(bytes.prefix(random.int(bytes.count + 1)))
            }
            try compare(bytes, expected: stream.size + UInt64(index % 3),
                        chunk: [1, 7, 257, 1_024][index % 4], sourceChunk: index % 7 == 0 ? 1 : .max)
        }
        // Include mutations of the real dynamic streams with long distances.
        for stream in try fixtureStreams() {
            for index in 0..<64 {
                var bytes = stream.bytes
                if index % 2 == 0 {
                    let bit = random.int(bytes.count * 8)
                    bytes[bit / 8] ^= UInt8(1 << (bit & 7))
                } else {
                    bytes = Data(bytes.prefix(random.int(bytes.count + 1)))
                }
                try compare(bytes, expected: stream.size, chunk: 32_768)
            }
        }
    }

    // Opt-in, release-only micro-measurement; fixtures are generated in a temporary
    // directory by the available 7zz binary, without depending on its source code.
    func testDeflate64ThroughputMeasurement() throws {
        guard ProcessInfo.processInfo.environment["M1B_DEFLATE64_BENCHMARK"] == "1" else {
            throw XCTSkip("set M1B_DEFLATE64_BENCHMARK=1 for the 64 MiB release measurement")
        }
        let temporary = try ZipTestSupport.temporaryDirectory(label: "deflate64-throughput")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let line = Data("KaitoKit streams archive entries through a bounded history window. Huffman codes, long matches, and short reads must preserve every byte.\n".utf8)
        let size = 64 * 1_024 * 1_024
        var text = Data()
        text.reserveCapacity(size)
        while text.count < size { text.append(line.prefix(size - text.count)) }
        try text.write(to: temporary.appendingPathComponent("text.txt"))
        let archive = temporary.appendingPathComponent("text.zip")
        try ZipTestSupport.makeSevenZip(sourceDirectory: temporary, paths: ["text.txt"],
                                       archiveURL: archive, method: "Deflate64")
        let zip = try Data(contentsOf: archive)
        func u16(_ offset: Int) -> Int { Int(zip[offset]) | Int(zip[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
        XCTAssertEqual(u16(8), 9)
        let start = 30 + u16(26) + u16(28)
        let compressed = Data(zip[start..<(start + u32(18))])
        let source = DataByteSource(compressed)
        var buffer = [UInt8](repeating: 0, count: 262_144)
        for reference in [true, false] {
            var times = [Double]()
            for _ in 0..<3 {
                let decoder: any Decompressor = reference
                    ? try Deflate64ReferenceDecoder(source: source, offset: 0, compressedSize: source.length, expectedSize: UInt64(size))
                    : try Deflate64Decompressor(source: source, offset: 0, compressedSize: source.length, expectedSize: UInt64(size))
                var offset = 0
                let start = ContinuousClock.now
                while !decoder.isFinished {
                    let count = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
                    // Compare against the original text while timing both implementations.
                    XCTAssertEqual(Data(buffer.prefix(count)), text.subdata(in: offset..<(offset + count)))
                    offset += count
                }
                let elapsed = start.duration(to: .now).components
                times.append(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
                XCTAssertEqual(offset, size)
            }
            let seconds = times.sorted()[1]
            print(String(format: "M1B Deflate64 %@: median %.6f s, %.2f MiB/s (64 MiB, 3 runs)",
                         reference ? "reference" : "table", seconds, 64 / seconds))
        }
    }

    private func compare(_ bytes: Data, expected: UInt64?, chunk: Int, sourceChunk: Int = .max, valid: Bool = false,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        let source = ShortSource(bytes: bytes, maximum: sourceChunk)
        let old = try Deflate64ReferenceDecoder(source: source, offset: 0, compressedSize: source.length, expectedSize: expected)
        let new = try Deflate64Decompressor(source: source, offset: 0, compressedSize: source.length, expectedSize: expected)
        let reference = try outcome(old, chunk: chunk)
        let actual = try outcome(new, chunk: chunk)
        if valid {
            XCTAssertNil(reference.error, file: file, line: line)
            XCTAssertTrue(reference.finished, file: file, line: line)
            if let expected { XCTAssertEqual(UInt64(reference.output.count), expected, file: file, line: line) }
        }
        XCTAssertEqual(actual.error, reference.error, "input=\(bytes.prefix(32).map { String(format: "%02x", $0) }.joined()), chunk=\(chunk)", file: file, line: line)
        XCTAssertEqual(actual.output, reference.output, file: file, line: line)
        XCTAssertEqual(actual.failedBuffer, reference.failedBuffer, file: file, line: line)
        XCTAssertEqual(actual.finished, reference.finished, file: file, line: line)
    }

    private func outcome(_ decoder: any Decompressor, chunk: Int) throws -> Outcome {
        var result = Outcome()
        var buffer = [UInt8](repeating: 0xA5, count: chunk)
        for _ in 0..<1_000_000 {
            // Include the caller's partially written buffer on a throwing read.
            _ = buffer.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0xA5) }
            do {
                let count = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
                result.output.append(contentsOf: buffer.prefix(count))
                if count == 0 || decoder.isFinished {
                    result.finished = decoder.isFinished
                    return result
                }
            } catch let error as KaitoError {
                result.error = error
                result.failedBuffer = Data(buffer)
                result.finished = decoder.isFinished
                return result
            }
        }
        XCTFail("decoder did not terminate")
        throw KaitoError.limitExceeded("differential test reads")
    }

    private func fixtureStreams() throws -> [Stream] {
        struct Manifest: Decodable {
            struct Fixture: Decodable {
                struct Packed: Decodable { let offset: Int; let size: Int; let unpackedSize: UInt64 }
                let file: String
                let packedStreams: [Packed]
            }
            let fixtures: [Fixture]
        }
        let root = TestFixtures.url("sevenzip-deflate64")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        return try manifest.fixtures.flatMap { fixture in
            let encoded = try Data(contentsOf: root.appendingPathComponent(fixture.file))
            let archive = try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
            return fixture.packedStreams.map {
                Stream(bytes: Data(archive[$0.offset..<($0.offset + $0.size)]), size: $0.unpackedSize)
            }
        }
    }

    private func handBuiltStreams() -> [Stream] {
        let fixed = Deflate64DecompressorTests.fixedCodes()
        let distance = Deflate64DecompressorTests.canonicalCodes([UInt8](repeating: 5, count: 32))
        var stored = Deflate64TestBitWriter()
        stored.writeLSB(1, count: 1); stored.writeLSB(0, count: 2); stored.alignToByte()
        stored.writeUInt16LE(4); stored.writeUInt16LE(~UInt16(4))
        stored.writeAlignedBytes([65, 66, 67, 68])
        var matches = Deflate64TestBitWriter()
        matches.writeLSB(1, count: 1); matches.writeLSB(1, count: 2)
        for byte in "abcdefgh".utf8 { matches.writeHuffman(Int(byte), codes: fixed) }
        for symbol in 0..<8 {
            matches.writeHuffman(285, codes: fixed); matches.writeLSB(34, count: 16)
            matches.writeHuffman(symbol, codes: distance)
            matches.writeLSB(0, count: symbol < 4 ? 0 : symbol < 6 ? 1 : 2)
        }
        matches.writeHuffman(256, codes: fixed)
        var maximum = Deflate64TestBitWriter()
        maximum.writeLSB(1, count: 1); maximum.writeLSB(1, count: 2)
        maximum.writeHuffman(65, codes: fixed)
        maximum.writeHuffman(285, codes: fixed); maximum.writeLSB(65_535, count: 16)
        maximum.writeHuffman(0, codes: distance)
        for code in [30, 31] {
            maximum.writeHuffman(257, codes: fixed); maximum.writeHuffman(code, codes: distance)
            maximum.writeLSB(code == 30 ? 0 : 16_383, count: 14)
        }
        maximum.writeHuffman(256, codes: fixed)

        // Incomplete alphabets with 10/15-bit codes force secondary lookups and
        // missing edges. Code-length alphabet is deliberately incomplete too.
        var dynamic = Deflate64TestBitWriter()
        dynamic.writeLSB(1, count: 1); dynamic.writeLSB(2, count: 2)
        dynamic.writeLSB(0, count: 5); dynamic.writeLSB(0, count: 5); dynamic.writeLSB(15, count: 4)
        let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var codeLengths = [UInt8](repeating: 0, count: 19)
        for symbol in [0, 1, 10, 15] { codeLengths[symbol] = 4 }
        for symbol in order { dynamic.writeLSB(UInt32(codeLengths[symbol]), count: 3) }
        let codes = Deflate64DecompressorTests.canonicalCodes(codeLengths)
        var lengths = [UInt8](repeating: 0, count: 258)
        lengths[65] = 1; lengths[66] = 10; lengths[256] = 15
        for length in lengths { dynamic.writeHuffman(Int(length), codes: codes) }
        let literals = Deflate64DecompressorTests.canonicalCodes(Array(lengths.prefix(257)))
        for symbol in [65, 66, 65, 256] { dynamic.writeHuffman(symbol, codes: literals) }
        return [Stream(bytes: stored.data, size: 4), Stream(bytes: matches.data, size: 304),
                Stream(bytes: maximum.data, size: 65_545), Stream(bytes: dynamic.data, size: 3),
                secondaryDistanceStream()]
    }

    private func secondaryDistanceStream() -> Stream {
        var writer = Deflate64TestBitWriter()
        let history = (0..<65_536).map { UInt8(truncatingIfNeeded: $0 * 37 + $0 / 257) }
        for bytes in [Array(history.prefix(65_535)), Array(history.suffix(1))] {
            writer.writeLSB(0, count: 1); writer.writeLSB(0, count: 2); writer.alignToByte()
            writer.writeUInt16LE(UInt16(bytes.count)); writer.writeUInt16LE(~UInt16(bytes.count))
            writer.writeAlignedBytes(bytes)
        }
        writer.writeLSB(1, count: 1); writer.writeLSB(2, count: 2)
        writer.writeLSB(29, count: 5); writer.writeLSB(31, count: 5); writer.writeLSB(15, count: 4)
        let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var codeLengths = [UInt8](repeating: 0, count: 19)
        for symbol in [0, 1, 8, 10, 15] { codeLengths[symbol] = 3 }
        for symbol in order { writer.writeLSB(UInt32(codeLengths[symbol]), count: 3) }
        let codes = Deflate64DecompressorTests.canonicalCodes(codeLengths)
        var literals = [UInt8](repeating: 0, count: 286)
        literals[65] = 1; literals[257] = 10; literals[285] = 10; literals[256] = 15
        var distances = [UInt8](repeating: 0, count: 32)
        distances[0] = 1; distances[30] = 8; distances[31] = 15
        for length in literals + distances { writer.writeHuffman(Int(length), codes: codes) }
        let literalCodes = Deflate64DecompressorTests.canonicalCodes(literals)
        let distanceCodes = Deflate64DecompressorTests.canonicalCodes(distances)
        writer.writeHuffman(285, codes: literalCodes); writer.writeLSB(65_535, count: 16)
        writer.writeHuffman(31, codes: distanceCodes); writer.writeLSB(16_383, count: 14)
        writer.writeHuffman(257, codes: literalCodes)
        writer.writeHuffman(30, codes: distanceCodes); writer.writeLSB(16_383, count: 14)
        writer.writeHuffman(256, codes: literalCodes)
        return Stream(bytes: writer.data, size: 131_077)
    }

    private struct ShortSource: ByteSource {
        let bytes: Data
        let maximum: Int
        var length: UInt64 { UInt64(bytes.count) }
        func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
            try DataByteSource(bytes).read(into: UnsafeMutableRawBufferPointer(rebasing: buffer.prefix(maximum)), at: offset)
        }
    }

    private struct Generator {
        var state: UInt64
        mutating func int(_ upperBound: Int) -> Int {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Int(state % UInt64(upperBound))
        }
    }
}
