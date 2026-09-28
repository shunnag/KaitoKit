import Foundation
@testable import KaitoKit
import XCTest

extension ZstdTuning {
    // T2: インスタンスごとの設定だけで全 Huffman 経路を強制する。
    static var huffmanTestVariants: [Self] {
        [0, Self.defaultPairTableThreshold, Int.max].flatMap { threshold in
            [true, false].map { Self(pairTableThreshold: threshold, huffmanFastLoop: $0) }
        }
    }
}

final class ZstdDifferentialTests: XCTestCase {
    private func tool() throws -> String {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        guard let path = paths.map({ $0 + "/zstd" }).first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { throw XCTSkip("zstd CLI がありません") }
        return path
    }

    private func decode(_ encoded: Data, chunk: Int = 65_536, tuning: ZstdTuning = .default) throws -> Data {
        let limits = ReadLimits(maxEntrySize: 8 << 20, maxDictionarySize: 128 << 20)
        let decoder = try ZstdDecompressor(source: DataByteSource(encoded), limits: limits, tuning: tuning)
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

    private func blockTypes(_ encoded: Data) throws -> Set<ZstdFrameHeader.BlockType> {
        let input = try ZstdInput(source: DataByteSource(encoded), offset: 4, size: UInt64(encoded.count - 4))
        let header = try ZstdFrameHeader(input: input, limits: ReadLimits())
        var types = Set<ZstdFrameHeader.BlockType>()
        while true {
            let block = try header.blockHeader(input)
            types.insert(block.type)
            try input.skip(UInt64(block.type == .rle ? 1 : block.size))
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
                if index == 1 { XCTAssertTrue(try blockTypes(encoded).contains(.rle)) }
                if index == 2 { XCTAssertTrue(try blockTypes(encoded).contains(.raw)) }
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

    private func wordText(_ count: Int) -> Data {
        let syllables = ["ka", "ito", "archive", "fu", "mo", "ri", "ta", "shi", "block", "bytes", "read", "ki"]
        var state: UInt64 = 0x8878_4b61_6974_6f
        var result = Data()
        while result.count < count {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            let word = syllables[Int(state % UInt64(syllables.count))]
                + syllables[Int((state >> 8) % UInt64(syllables.count))]
            result.append(contentsOf: (word + (state & 7 == 0 ? "\n" : " ")).utf8)
        }
        return Data(result.prefix(count))
    }

    func testStage1SequenceShapesAndForcedMatchPathsAgainstCLI() throws {
        let tool = try tool()
        var inputs: [Data] = []
        for period in 1...40 {
            let pattern = [UInt8](randomBytes(period))
            inputs.append(Data((0..<4_099).map { pattern[$0 % period] }))
        }
        var separated = Data()
        let repeated = wordText(193)
        for count in 1...70 {
            separated.append(repeated)
            separated.append(randomBytes(count))
            separated.append(repeated)
        }
        inputs.append(separated)
        inputs += [256, 1_024, 4_096, 1 << 20].map { wordText($0) }
        var concatenated = Data(), concatenatedOutput = Data()
        for level in [1, 3, 19] {
            for input in inputs {
                let encoded = try compress(input, tool: tool, options: ["-\(level)"])
                let oracle = try ZipTestSupport.checkedRun(tool, arguments: ["-q", "-d", "-c"],
                                                           standardInput: encoded).standardOutput
                XCTAssertEqual(oracle, input)
                for path: ZstdTuning.MatchPath in [.automatic, .eightByteChunks, .byteThenPeriod] {
                    let tuning = ZstdTuning(matchPath: path)
                    XCTAssertEqual(try decode(encoded, tuning: tuning), oracle)
                    if input.count <= 65_536 {
                        for chunk in [1, 7, 31] { XCTAssertEqual(try decode(encoded, chunk: chunk, tuning: tuning), oracle) }
                    }
                }
                for tuning in ZstdTuning.huffmanTestVariants {
                    XCTAssertEqual(try decode(encoded, tuning: tuning), oracle)
                    if input.count <= 65_536 {
                        for chunk in [1, 7, 31] { XCTAssertEqual(try decode(encoded, chunk: chunk, tuning: tuning), oracle) }
                    }
                }
                if input.count == 256 {
                    concatenated.append(encoded)
                    concatenatedOutput.append(input)
                }
            }
            let input = wordText(1 << 20)
            let encoded = try compress(input, tool: tool, options: ["-\(level)", "--long=27", "--no-content-size"])
            try compare(encoded, expected: input, tool: tool)
            for path: ZstdTuning.MatchPath in [.eightByteChunks, .byteThenPeriod] {
                XCTAssertEqual(try decode(encoded, tuning: ZstdTuning(matchPath: path)), input)
            }
            for tuning in ZstdTuning.huffmanTestVariants {
                XCTAssertEqual(try decode(encoded, tuning: tuning), input)
            }
        }
        for chunk in [1, 7, 31] {
            for path: ZstdTuning.MatchPath in [.automatic, .eightByteChunks, .byteThenPeriod] {
                XCTAssertEqual(try decode(concatenated, chunk: chunk, tuning: ZstdTuning(matchPath: path)),
                               concatenatedOutput)
            }
            for tuning in ZstdTuning.huffmanTestVariants {
                XCTAssertEqual(try decode(concatenated, chunk: chunk, tuning: tuning), concatenatedOutput)
            }
        }
    }

    func testStage1PaddedReaderRefillsExactEndAndOverread() throws {
        let random = [UInt8](randomBytes(96))
        for start in 0...7 {
            for length in 1...80 {
                var bytes = random
                bytes[start + length - 1] = 0xa5
                try ZstdScratchBuffer.withPaddedCopy(of: bytes) { padded in
                    for width in 0...31 {
                        var reader = try ZstdPaddedBitReader(padded, range: start..<(start + length))
                        var remaining = length * 8 - 1
                        XCTAssertEqual(reader.readUnchecked(0), 0)
                        while remaining > 0 {
                            let count = min(max(1, width), remaining)
                            if reader.consumed + count > 63 { try reader.refill() }
                            var expected = 0
                            for bit in stride(from: remaining - 1, through: remaining - count, by: -1) {
                                expected = (expected << 1) | Int((bytes[start + bit / 8] >> (bit % 8)) & 1)
                            }
                            if count <= 12 {
                                XCTAssertEqual(reader.peekUnchecked(count), expected)
                                var dropped = reader
                                dropped.dropUnchecked(count)
                                XCTAssertEqual(dropped.remaining, remaining - count)
                            }
                            XCTAssertEqual(reader.readUnchecked(count), expected)
                            remaining -= count
                            XCTAssertEqual(reader.remaining, remaining)
                            XCTAssertLessThanOrEqual(reader.consumed, 63)
                        }
                        try reader.refill()
                        XCTAssertEqual(reader.remaining, 0)
                        _ = reader.readUnchecked(1)
                        XCTAssertNotEqual(reader.remaining, 0)
                    }
                }
            }
        }
        // s == F。64 ビット以上を過剰消費しても、前余白の外を読む前に必ず拒否する。
        try ZstdScratchBuffer.withPaddedCopy(of: [1]) { padded in
            var reader = try ZstdPaddedBitReader(padded, range: 0..<1)
            var overread = 0
            XCTAssertThrowsError(try {
                for _ in 0..<10 {
                    try reader.refill()
                    _ = reader.readUnchecked(31)
                    _ = reader.readUnchecked(31)
                    overread += 62
                }
            }()) { XCTAssertEqual($0 as? KaitoError, .malformed("zstd bitstream underflow")) }
            XCTAssertGreaterThanOrEqual(overread, 62)
        }
        for bytes: [UInt8] in [[], [0]] {
            try ZstdScratchBuffer.withPaddedCopy(of: bytes) { padded in
                XCTAssertThrowsError(try ZstdPaddedBitReader(padded, range: 0..<bytes.count)) {
                    XCTAssertEqual($0 as? KaitoError, .malformed("zstd bitstream end marker"))
                }
            }
        }
        XCTAssertEqual(MemoryLayout<ZstdSequenceCell>.size, 8)
        XCTAssertEqual(MemoryLayout<ZstdSequenceCell>.stride, 8)
    }

    func testStage1FiveHundredIndependentFramesAllocateByNeed() throws {
        let tool = try tool()
        let directory = try TestFixtures.makeTemporaryDirectory(label: "zstd-frames")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("input")
        let words = wordText(4_096), random = randomBytes(4_096)
        var peakScratch = 0
        for index in 0..<500 {
            let size = index < 8 ? [0, 1, 2, 7, 31, 256, 1_024, 4_096][index] : (index * 197) % 4_097
            let expected: Data
            switch (index / 12) % 3 {
            case 0: expected = Data(words.prefix(size))
            case 1: expected = Data(random.prefix(size))
            default: expected = Data(repeating: UInt8(truncatingIfNeeded: index), count: size)
            }
            try expected.write(to: file)
            let noSize = (index / 6) % 2 != 0
            let noCheck = (index / 3) % 2 != 0
            let encoded = try ZipTestSupport.checkedRun(tool, arguments: [
                "-q", "-c", "--single-thread", "-\([1, 3, 19][index % 3])",
                noCheck ? "--no-check" : "--check", noSize ? "--no-content-size" : "--content-size", file.path
            ]).standardOutput
            let input = try ZstdInput(source: DataByteSource(encoded), offset: 4, size: UInt64(encoded.count - 4))
            let header = try ZstdFrameHeader(input: input, limits: ReadLimits())
            XCTAssertEqual(header.checksum, !noCheck)
            XCTAssertEqual(header.contentSize, noSize ? nil : UInt64(size))
            if noSize { XCTAssertEqual(encoded[4] & 32, 0) }
            XCTAssertTrue(try header.blockHeader(input).last)
            let decoder = try ZstdDecompressor(source: DataByteSource(encoded), offset: 0,
                                               compressedSize: UInt64(encoded.count), expectedSize: UInt64(size))
            var buffer = [UInt8](repeating: 0, count: 997)
            var decoded = Data()
            while true {
                let count = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
                peakScratch = max(peakScratch, decoder.allocatedScratchBytes)
                XCTAssertLessThanOrEqual(decoder.allocatedScratchBytes, 64 << 10)
                XCTAssertLessThanOrEqual(decoder.allocatedBufferBytes, header.maximumBlockSize + ZstdFrameDecoder.outputSlack)
                if count == 0 { break }
                decoded.append(contentsOf: buffer.prefix(count))
            }
            XCTAssertEqual(decoded, expected)
            var actual = XXH64(), reference = XXH64()
            actual.update([UInt8](decoded)[...]); reference.update([UInt8](expected)[...])
            XCTAssertEqual(actual.value, reference.value)
        }
        print("P11 Stage 1: 500 independent frames; peak scratch \(peakScratch) bytes")
    }


    private struct MutationSections {
        let header: Int
        let end: Int
        let literalSection: Range<Int>
        let jumpTable: Range<Int>
        let sequenceCount: Range<Int>
        let tables: Range<Int>
        let stream: Range<Int>
        let maximumBlockSize: Int
    }

    private func mutationSections(_ encoded: Data) throws -> MutationSections? {
        let input = try ZstdInput(source: DataByteSource(encoded), offset: 4, size: UInt64(encoded.count - 4))
        let header = try ZstdFrameHeader(input: input, limits: ReadLimits())
        while true {
            let blockHeader = Int(input.position)
            let block = try header.blockHeader(input)
            let blockStart = Int(input.position)
            if block.type != .compressed {
                try input.skip(UInt64(block.type == .rle ? 1 : block.size))
                if block.last { return nil }
                continue
            }
            return try ZstdByteReader.withPaddedCopy(of: input.read(block.size)) { reader -> MutationSections? in
                let first = try reader.byte(), type = first & 3, format = (first >> 2) & 3
                var jump = 0..<0
                if type < 2 {
                    let size: Int
                    if format & 1 == 0 { size = first >> 3 }
                    else if format == 1 { size = (first >> 4) | (try reader.byte() << 4) }
                    else { size = (first >> 4) | (Int(try reader.integer(2)) << 4) }
                    _ = try reader.take(type == 1 ? 1 : size)
                } else {
                    let width = [10, 10, 14, 18][format]
                    let value = UInt64(first) | (try reader.integer([3, 3, 4, 5][format] - 1) << 8)
                    var section = try reader.subreader(Int(value >> (4 + width)))
                    if type == 2 { _ = try ZstdHuffman.read(from: &section) }
                    if format != 0 { jump = section.position..<(section.position + 6) }
                }
                let countStart = reader.position
                let firstCount = try reader.byte()
                if firstCount == 0 { return nil }
                if firstCount == 255 { _ = try reader.take(2) }
                else if firstCount >= 128 { _ = try reader.take(1) }
                let countEnd = reader.position
                let modes = try reader.byte()
                let tableStart = reader.position
                for (shift, log, symbol) in [(6, 9, 35), (4, 8, 31), (2, 9, 52)] {
                    switch (modes >> shift) & 3 {
                    case 1: _ = try reader.byte()
                    case 2: _ = try ZstdFSE.read(from: &reader, maximumLog: log, maximumSymbol: symbol)
                    default: break
                    }
                }
                func absolute(_ range: Range<Int>) -> Range<Int> {
                    (blockStart + range.lowerBound)..<(blockStart + range.upperBound)
                }
                return MutationSections(header: blockHeader, end: blockStart + block.size,
                                        literalSection: absolute(0..<countStart), jumpTable: absolute(jump),
                                        sequenceCount: absolute(countStart..<countEnd),
                                        tables: absolute(tableStart..<reader.position),
                                        stream: absolute(reader.position..<reader.end), maximumBlockSize: header.maximumBlockSize)
            }
        }
    }

    func testStage1TargetedEntropyMutationsAreBoundedAndTyped() throws {
        let tool = try tool()
        var cases = 0, jumps = 0, tableBytes = 0
        let started = Date()
        for level in [1, 3, 19] {
            for size in [256, 4_096, 32_768] {
                let encoded = try compress(wordText(size), tool: tool, options: ["-\(level)"])
                guard let parts = try mutationSections(encoded) else { continue }
                jumps += parts.jumpTable.count
                tableBytes += parts.tables.count
                var bits = Set<Int>()
                for range in [parts.jumpTable, parts.tables,
                              parts.stream.lowerBound..<min(parts.stream.lowerBound + 8, parts.stream.upperBound),
                              max(parts.stream.lowerBound, parts.stream.upperBound - 8)..<parts.stream.upperBound] {
                    for byte in range { for bit in 0..<8 { bits.insert(byte * 8 + bit) } }
                }
                let all = parts.literalSection.lowerBound..<parts.end
                for index in 0..<256 { bits.insert(all.lowerBound * 8 + (index * 104_729) % (all.count * 8)) }
                for bit in bits.sorted() {
                    var mutated = encoded
                    mutated[bit / 8] ^= 1 << (bit & 7)
                    do { _ = try decode(mutated) }
                    catch { XCTAssertTrue(error is KaitoError, "\(bit): \(error)") }
                    cases += 1
                }
                let maximum = parts.maximumBlockSize / 3
                let count: [UInt8] = maximum < 128 ? [UInt8(maximum)] : maximum < 0x7f00
                    ? [UInt8(128 + (maximum >> 8)), UInt8(truncatingIfNeeded: maximum)]
                    : [255, UInt8(truncatingIfNeeded: maximum - 0x7f00), UInt8((maximum - 0x7f00) >> 8)]
                var body = Data(encoded[parts.literalSection])
                body.append(contentsOf: count)
                body.append(encoded[parts.sequenceCount.upperBound..<parts.stream.lowerBound])
                body.append(1)
                let oldHeader = Int(encoded[parts.header])
                let newHeader = (body.count << 3) | (oldHeader & 7)
                var mutated = Data(encoded.prefix(parts.header))
                mutated.append(contentsOf: (0..<3).map { UInt8(truncatingIfNeeded: newHeader >> ($0 * 8)) })
                mutated.append(body)
                mutated.append(encoded.suffix(from: parts.end))
                let start = Date()
                XCTAssertThrowsError(try decode(mutated)) { XCTAssertTrue($0 is KaitoError) }
                XCTAssertLessThan(Date().timeIntervalSince(start), 1)
            }
        }
        XCTAssertGreaterThan(jumps, 0)
        XCTAssertGreaterThan(tableBytes, 0)
        XCTAssertGreaterThan(cases, 1_000)
        let elapsed = Date().timeIntervalSince(started)
        print("P11 Stage 1: \(cases) targeted entropy mutations in \(elapsed) seconds")
        XCTAssertLessThan(elapsed, 30)
    }

}
