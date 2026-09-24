import Foundation
@testable import KaitoKit
import XCTest

final class ZstdDifferentialTests: XCTestCase {
    private func tool() throws -> String {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        guard let path = paths.map({ $0 + "/zstd" }).first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { throw XCTSkip("zstd CLI がありません") }
        return path
    }

    private func decode(_ encoded: Data, chunk: Int = 65_536) throws -> Data {
        let limits = ReadLimits(maxEntrySize: 8 << 20, maxDictionarySize: 128 << 20)
        let decoder = try ZstdDecompressor(source: DataByteSource(encoded), limits: limits)
        var buffer = [UInt8](repeating: 0, count: chunk)
        var result = Data()
        while true {
            let count = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
            if count == 0 { return result }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    private func randomBytes(_ count: Int) -> Data {
        var state: UInt64 = 0x4b6169746f
        return Data((0..<count).map { _ in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return UInt8(truncatingIfNeeded: state >> 24)
        })
    }

    private func compress(_ input: Data, tool: String, options: [String]) throws -> Data {
        try ZipTestSupport.checkedRun(tool, arguments: ["-q", "-c", "--single-thread", "-C"] + options,
                                      standardInput: input).standardOutput
    }

    private func compare(_ encoded: Data, expected: Data, tool: String, chunk: Int = 65_536) throws {
        let reference = try ZipTestSupport.checkedRun(tool, arguments: ["-q", "-d", "-c"],
                                                     standardInput: encoded).standardOutput
        XCTAssertEqual(reference, expected)
        XCTAssertEqual(try decode(encoded, chunk: chunk), reference)
    }

    private func blockTypes(_ encoded: Data) throws -> Set<Int> {
        let input = try ZstdInput(source: DataByteSource(encoded), offset: 4, size: UInt64(encoded.count - 4))
        let header = try ZstdFrameHeader(input: input, limits: ReadLimits())
        var types = Set<Int>()
        while true {
            let block = try header.blockHeader(input)
            types.insert(block.type)
            try input.skip(UInt64(block.type == 1 ? 1 : block.size))
            if block.last { return types }
        }
    }

    func testGeneratedLevelsWindowsRawRLEAndConcatenationAgainstCLI() throws {
        let tool = try tool()
        let random = randomBytes(262_177)
        var text = Data()
        for index in 0..<8_000 {
            text.append(contentsOf: "KaitoKit row \(index): the quick brown fox visits archive \(index % 137).\n".utf8)
        }
        let runs = Data(repeating: 0x61, count: 524_291) + Data(repeating: 0x62, count: 131_071)
        var frames: [(Data, Data)] = []
        for options in [["-1"], ["-3"], ["-9"], ["-19"], ["-3", "--long=27", "--no-content-size"],
                        ["--ultra", "-22"]] {
            for (index, input) in [text, runs, random].enumerated() {
                let encoded = try compress(input, tool: tool, options: options)
                try compare(encoded, expected: input, tool: tool)
                if index == 1 { XCTAssertTrue(try blockTypes(encoded).contains(1)) }
                if index == 2 { XCTAssertTrue(try blockTypes(encoded).contains(0)) }
                if options.contains("--long=27") {
                    let input = try ZstdInput(source: DataByteSource(encoded), offset: 4, size: UInt64(encoded.count - 4))
                    XCTAssertEqual(try ZstdFrameHeader(input: input, limits: ReadLimits()).windowSize, 1 << 27)
                }
                if options == ["-3"] { frames.append((encoded, input)) }
            }
        }
        // 小さい window を何周も使い、履歴とブロック内の参照をまたぐ。
        for log in [10, 11, 14, 17] {
            let encoded = try compress(text, tool: tool,
                                       options: ["-3", "--zstd=wlog=\(log)", "--no-content-size"])
            try compare(encoded, expected: text, tool: tool, chunk: 127)
        }
        for count in [0, 1, 2, 3, 7, 8, 9, 15, 16, 17, 31, 32, 33] {
            let input = random.prefix(count)
            let encoded = try compress(input, tool: tool, options: ["-3"])
            try compare(encoded, expected: input, tool: tool, chunk: 1)
            frames.append((encoded, input))
        }
        var concatenated = Data()
        var expected = Data()
        for index in 0..<160 {
            let (encoded, input) = frames[index < 3 ? index : 3 + index % (frames.count - 3)]
            concatenated.append(contentsOf: [0x50 + UInt8(index % 16), 0x2a, 0x4d, 0x18, 3, 0, 0, 0, 1, 2, 3])
            concatenated.append(encoded)
            expected.append(input)
        }
        try compare(concatenated, expected: expected, tool: tool, chunk: 31)
    }

    func testGeneratedFramesMutationsAndTruncationsAreTyped() throws {
        let tool = try tool()
        let random = randomBytes(4_099)
        let inputs = [Data(repeating: 97, count: 32_771), random,
                      Data((0..<200).flatMap { Array("row \($0) repeated archive text\n".utf8) })]
        for input in inputs {
            let encoded = try compress(input, tool: tool, options: ["-3"])
            let cuts = Set([0, 1, 2, 3, encoded.count - 1] + (0..<64).map { $0 * encoded.count / 64 })
            for count in cuts {
                XCTAssertThrowsError(try decode(encoded.prefix(count))) {
                    XCTAssertTrue($0 is KaitoError, "\($0)")
                }
            }
            for index in 0..<256 {
                var changed = encoded
                let offset = (index * 104_729) % changed.count
                changed[offset] ^= 1 << (index % 8)
                do { _ = try decode(changed) }
                catch { XCTAssertTrue(error is KaitoError, "\(offset): \(error)") }
            }
        }
    }

    func testBackwardReaderWordRefillsAndUnalignedTails() throws {
        let input = [UInt8](randomBytes(96))
        for start in 0..<8 {
            for length in 1...80 {
                var bytes = input
                bytes[start + length - 1] = 0xa5
                try bytes.withUnsafeBytes { buffer in
                    for width in 1...31 {
                        var reader = try ZstdBitReader(buffer, range: start..<(start + length))
                        var remaining = length * 8 - 1
                        while remaining > 0 {
                            let count = min(width, remaining)
                            var expected = 0
                            for bit in stride(from: remaining - 1, through: remaining - count, by: -1) {
                                expected = (expected << 1) | Int((bytes[start + bit / 8] >> (bit % 8)) & 1)
                            }
                            XCTAssertEqual(try reader.read(count), expected)
                            remaining -= count
                            XCTAssertEqual(reader.remaining, remaining)
                        }
                        XCTAssertEqual(reader.peekPadded(11), 0)
                        XCTAssertThrowsError(try reader.read(1)) { XCTAssertTrue($0 is KaitoError) }
                    }
                }
            }
        }
    }
}
