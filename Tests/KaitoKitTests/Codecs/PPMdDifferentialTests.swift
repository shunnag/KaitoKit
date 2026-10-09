import Foundation
@testable import KaitoKit
import XCTest

// The frozen Swift implementation is an independent oracle for both bytes and
// exact KaitoError values, including bytes returned before a corrupt stream fails.
final class PPMdDifferentialTests: XCTestCase {
    private struct Stream {
        var bytes: Data
        var size: UInt64
        var properties: [UInt8] = [6, 0, 0, 0x10, 0]
        var parameter: UInt16? = nil
    }

    private struct Outcome: Equatable {
        var bytes = Data()
        var error: KaitoError?
        var finished = false
    }

    func testExistingStreamsAndCorruptionMatchFrozenDecoder() throws {
        let h = Stream(bytes: hex(
            "00620279778de882efeeaedc2f74e42e003a0d19919ed570d672bc71e6c3ce82ee"),
            size: UInt64("banana bandana banana bandana\n".utf8.count * 20))
        try compareMutations(h)
        try compare(h, chunkSize: 37, label: "short 7z source", shortReads: true)
        for name in ["text-o8-default", "text-o2-mem1m", "text-o16-mem1m",
                     "binary-o6-mem4m", "random-o16-mem1m-restart", "random-o16-mem1m-cutoff"] {
            let encoded = try Data(contentsOf: TestFixtures.url("zip-ppmd/" + name + ".zip.b64"))
            let archive = try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
            let stream = try zipStream(archive)
            try compareMutations(stream, label: name)
            try compare(stream, chunkSize: 37, label: "short ZIP source " + name, shortReads: true)
        }
    }

    func testRandomRangeStreamsMatchFrozenDecoder() throws {
        var seed: UInt64 = 0x50504D64
        for length in [0, 1, 3, 4, 5, 16, 257, 4096] {
            for iteration in 0..<8 {
                var bytes = Data((0..<length).map { _ in nextByte(&seed) })
                if !bytes.isEmpty, iteration.isMultiple(of: 2) { bytes[0] = 0 }
                for variantI in [false, true] {
                    let stream = Stream(bytes: bytes, size: 1024,
                        parameter: variantI ? UInt16(5 | (iteration % 3) << 12) : nil)
                    try compare(stream, chunkSize: 1, label: "random \(length)/\(iteration)/\(variantI)")
                }
            }
        }
    }

    func testGeneratedOrdersMemoryAndStructuredInputsMatchFrozenDecoder() throws {
        try SevenZipTestSupport.requireSevenZip()
        let directory = try SevenZipTestSupport.temporaryDirectory(label: "ppmd-differential")
        defer { try? FileManager.default.removeItem(at: directory) }
        var seed: UInt64 = 0x50504D64
        let randomBlock = Data((0..<4096).map { _ in nextByte(&seed) })
        let inputs = [Data(String(repeating: "the model reads a symbol and updates its context.\n", count: 350).utf8),
                      Data((0..<16384).map { UInt8(truncatingIfNeeded: ($0 / 32) ^ ($0 % 7)) }),
                      randomBlock + randomBlock + randomBlock + randomBlock]
        var cases = 0
        for order in [2, 6, 16] {
            for memory in [1, 16] {
                for (kind, input) in inputs.enumerated() {
                    try input.write(to: directory.appendingPathComponent("input.bin"))
                    for variantI in [false, true] {
                        let name = "o\(order)-m\(memory)-k\(kind)." + (variantI ? "zip" : "7z")
                        let url = directory.appendingPathComponent(name)
                        let options = variantI
                            ? ["-tzip", "-mm=PPMd:o=\(order):mem=\(memory)m:a=\(kind % 2)"]
                            : ["-t7z", "-m0=PPMd:o=\(order):mem=\(memory)m", "-mhc=off"]
                        try SevenZipTestSupport.checkedRun(arguments:
                            ["a", "-bd", "-bb0", "-y", "-mmt=1"] + options + [url.path, "input.bin"],
                            currentDirectory: directory)
                        let archive = try Data(contentsOf: url)
                        let stream = try variantI ? zipStream(archive) : sevenZipStream(archive)
                        let decoded = try compare(stream, chunkSize: 4096, label: name)
                        XCTAssertEqual(decoded.bytes, input, name)
                        XCTAssertNil(decoded.error, name)
                        // Every generated configuration exercises both truncation and bit flips.
                        try compareMutations(stream, label: name, thorough: false)
                        cases += 1
                    }
                }
            }
        }
        // Small H arenas force allocator recycling and model restarts; order 32
        // also covers the encoder's highest supported order.
        for configuration in [(order: 6, memory: "64k"), (order: 32, memory: "128k")] {
            let input = inputs[2]
            try input.write(to: directory.appendingPathComponent("input.bin"))
            let name = "o\(configuration.order)-m\(configuration.memory).7z"
            let url = directory.appendingPathComponent(name)
            try SevenZipTestSupport.checkedRun(arguments: [
                "a", "-bd", "-bb0", "-y", "-t7z", "-mmt=1", "-mhc=off",
                "-m0=PPMd:o=\(configuration.order):mem=\(configuration.memory)", url.path, "input.bin",
            ], currentDirectory: directory)
            let stream = try sevenZipStream(Data(contentsOf: url))
            let decoded = try compare(stream, chunkSize: 4096, label: name)
            XCTAssertEqual(decoded.bytes, input, name)
            XCTAssertNil(decoded.error, name)
            try compareMutations(stream, label: name, thorough: false)
            cases += 1
        }
        print("PPMd differential: \(cases) generated archives plus fixture and random corruption cases")
        XCTAssertEqual(cases, 38)
    }

    private func compareMutations(_ stream: Stream, label: String = "fixture", thorough: Bool = true) throws {
        for chunkSize in [1, 37, 4096] { try compare(stream, chunkSize: chunkSize, label: label) }
        let steps = thorough ? 8 : 2
        for i in 0..<steps {
            var flipped = stream
            let index = stream.bytes.count * i / steps
            flipped.bytes[index] ^= UInt8(1 << (i % 8))
            try compare(flipped, chunkSize: 1, label: "\(label) flip \(index)")
            var truncated = stream
            truncated.bytes = Data(stream.bytes.prefix(stream.bytes.count * i / steps))
            try compare(truncated, chunkSize: 1, label: "\(label) truncation \(i)")
        }
        var lastByte = stream
        lastByte.bytes.removeLast()
        try compare(lastByte, chunkSize: 1, label: "\(label) last byte")
        var tooLong = stream
        tooLong.size += 1
        try compare(tooLong, chunkSize: 1, label: "\(label) declared size")
    }

    @discardableResult
    private func compare(_ stream: Stream, chunkSize: Int, label: String, shortReads: Bool = false) throws -> Outcome {
        let actual = try outcome(stream, baseline: false, chunkSize: chunkSize, shortReads: shortReads)
        let reference = try outcome(stream, baseline: true, chunkSize: chunkSize, shortReads: shortReads)
        XCTAssertEqual(actual, reference, label)
        return actual
    }

    private func outcome(_ stream: Stream, baseline: Bool, chunkSize: Int, shortReads: Bool) throws -> Outcome {
        var result = Outcome()
        do {
            let source: any ByteSource = shortReads ? ShortSource(stream.bytes) : DataByteSource(stream.bytes)
            let offset: UInt64 = shortReads ? 17 : 0
            let decoder: any Decompressor
            if let word = stream.parameter {
                decoder = try baseline
                    ? BaselinePPMdVarIDecoder(source: source, offset: offset, compressedSize: UInt64(stream.bytes.count),
                        parameterWord: word, expectedSize: stream.size, memorySizeLimit: 256 << 20)
                    : PPMdVarIDecoder(source: source, offset: offset, compressedSize: UInt64(stream.bytes.count),
                        parameterWord: word, expectedSize: stream.size, memorySizeLimit: 256 << 20)
            } else {
                decoder = try baseline
                    ? BaselinePPMd7Decoder(source: source, offset: offset, compressedSize: UInt64(stream.bytes.count),
                        properties: stream.properties, expectedSize: stream.size, memorySizeLimit: 256 << 20)
                    : PPMd7Decoder(source: source, offset: offset, compressedSize: UInt64(stream.bytes.count),
                        properties: stream.properties, expectedSize: stream.size, memorySizeLimit: 256 << 20)
            }
            var bytes = [UInt8](repeating: 0, count: chunkSize)
            while true {
                let count = try bytes.withUnsafeMutableBytes { try decoder.read(into: $0) }
                if count == 0 { break }
                result.bytes.append(contentsOf: bytes.prefix(count))
            }
            result.finished = decoder.isFinished
        } catch let error as KaitoError { result.error = error }
        return result
    }

    private struct ShortSource: ByteSource {
        let bytes: Data
        let end: Int
        var length: UInt64 { UInt64(bytes.count) }
        init(_ packed: Data) {
            end = 17 + packed.count
            bytes = Data(repeating: 0xA5, count: 17) + packed + Data(repeating: 0x5A, count: 19)
        }
        func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
            guard offset >= 17, offset <= end, buffer.count <= end - Int(offset) else {
                throw KaitoError.malformed("PPMd differential source read crossed its packed range")
            }
            let count = min(3, buffer.count)
            for i in 0..<count { buffer[i] = bytes[Int(offset) + i] }
            return count
        }
    }

    private func zipStream(_ archive: Data) throws -> Stream {
        XCTAssertEqual(u16(archive, 8), 98)
        let start = 30 + Int(u16(archive, 26)) + Int(u16(archive, 28))
        let end = start + Int(u32(archive, 18))
        return Stream(bytes: Data(archive[(start + 2)..<end]), size: UInt64(u32(archive, 22)),
                      parameter: u16(archive, start))
    }

    private func sevenZipStream(_ archive: Data) throws -> Stream {
        let headerOffset = 32 + Int(u64(archive, 12))
        let headerSize = Int(u64(archive, 20))
        let limits = ReadLimits()
        let header = try SevenZipHeaderParser.parse(bytes: Array(archive[headerOffset..<(headerOffset + headerSize)]),
            limits: limits, budget: SevenZipMetadataBudget(limit: limits.maxMetadataSize)) { _, _ in
                throw KaitoError.malformed("unexpected compressed differential-test header")
            }
        let streams = try XCTUnwrap(header.streams)
        let folder = try XCTUnwrap(streams.folders.first)
        let coder = try XCTUnwrap(folder.coders.first)
        XCTAssertEqual(coder.methodID, [3, 4, 1])
        let start = 32 + Int(streams.packInfo.position)
        let end = start + Int(try XCTUnwrap(streams.packInfo.sizes.first))
        return Stream(bytes: Data(archive[start..<end]), size: try XCTUnwrap(folder.unpackSizes.first),
                      properties: coder.properties)
    }

    private func nextByte(_ seed: inout UInt64) -> UInt8 {
        seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
        return UInt8(truncatingIfNeeded: seed)
    }
    private func hex(_ value: String) -> Data {
        let chars = Array(value)
        return Data(stride(from: 0, to: chars.count, by: 2).map {
            UInt8(String(chars[$0...($0 + 1)]), radix: 16)!
        })
    }
    private func u16(_ data: Data, _ i: Int) -> UInt16 { UInt16(data[i]) | UInt16(data[i + 1]) << 8 }
    private func u32(_ data: Data, _ i: Int) -> UInt32 { UInt32(u16(data, i)) | UInt32(u16(data, i + 2)) << 16 }
    private func u64(_ data: Data, _ i: Int) -> UInt64 { UInt64(u32(data, i)) | UInt64(u32(data, i + 4)) << 32 }
}
