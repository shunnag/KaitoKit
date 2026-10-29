import Foundation
@testable import KaitoKit
import XCTest

// Project-owned vectors and black-box lz4 CLI output only; no reference source.
final class LZ4DifferentialTests: XCTestCase {
    private struct Outcome: Equatable {
        var bytes = Data()
        var error: KaitoError?
        var failedBuffer = Data()
        var finished = false
    }

    func testTinyBlockInFourMiBFrameKeepsOutputCapacitySmall() throws {
        let payload: [UInt8] = [65, 66, 67, 68, 69]
        let bytes = frame([0x50] + payload, flags: 0x70, blockDescriptor: 0x70)
        for maximum: UInt64 in [5, 64, 4 * 1_024 * 1_024] {
            let decoder = try LZ4FrameDecompressor(
                source: DataByteSource(bytes), limits: ReadLimits(maxEntrySize: maximum)
            )
            XCTAssertEqual(decoder.decodedCapacity, 0)
            var output = [UInt8](repeating: 0, count: 7)
            let count = try output.withUnsafeMutableBytes { try decoder.read(into: $0) }
            XCTAssertEqual(Array(output.prefix(count)), payload)
            XCTAssertLessThanOrEqual(decoder.decodedCapacity, 64)
            XCTAssertEqual(try output.withUnsafeMutableBytes { try decoder.read(into: $0) }, 0)
            XCTAssertTrue(decoder.isFinished)
            XCTAssertLessThanOrEqual(decoder.decodedCapacity, 64)
        }
    }

    func testRoutingAndExistingFramesMatchFrozenSwiftDecoder() throws {
        for independent in [false, true] {
            for block in [false, true] {
                for content in [false, true] {
                    XCTAssertEqual(LZ4AppleBlockDecoder.isEligible(independent: independent,
                                                                  blockChecksum: block, contentChecksum: content),
                                   independent && (block || content))
                }
            }
        }
        let root = TestFixtures.url("lz4-frame")
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasSuffix(".lz4.b64") {
            let encoded = try Data(contentsOf: url)
            let bytes = try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
            for output in [4_096, 65_537, 262_144] {
                try compare(bytes, chunk: output, inputChunk: 7, valid: true)
            }
            if url.lastPathComponent.contains("tiny") || url.lastPathComponent.contains("empty") {
                for output in [1, 7] { try compare(bytes, chunk: output, inputChunk: 1, valid: true) }
            }
        }
    }

    func testMalformedBlocksWithRecomputedChecksumsAndLimitsMatchSwift() throws {
        let denseSequence: [UInt8] = [0x14, 65, 1, 0]
        let densePrefix = Array(repeating: denseSequence, count: 32).flatMap { $0 }
        let blocks: [[UInt8]] = [[], [0], [0xf0], [0x10], [0x10, 65, 0, 0], [0x00, 1, 0],
            [0x10, 65, 1, 0], // ends immediately after a match
            [0x18, 65, 1, 0, 0x40, 66, 67, 68, 69], // fewer than five final literals
            [0x10, 65, 1, 0, 0x50, 66, 67, 68, 69, 70], // last match too close to end
            [0x18, 65, 1, 0, 0x50, 66, 67, 68, 69, 70], // valid overlap
            [0x1f, 65, 1, 0, 255, 255],
            densePrefix, densePrefix + [0x50, 66, 67, 68, 69, 70],
            densePrefix + [0x40, 66, 67, 68, 69]]
        for block in blocks {
            for flags: UInt8 in [0x60, 0x64, 0x70, 0x74, 0x40, 0x44, 0x50] {
                let bytes = frame(block, flags: flags)
                for output in [1, 7, 4_096] {
                    try compare(bytes, chunk: output)
                    for maximum: UInt64 in [0, 1, 4, 17, 18, 65_536] {
                        try compare(bytes, chunk: output, limits: ReadLimits(maxEntrySize: maximum))
                    }
                }
            }
            let legacy = word(0x184c2102) + word(UInt32(block.count)) + Data(block)
            try compare(legacy, chunk: 7)
        }
        // A zero result from Apple is ambiguous: this valid empty block must
        // re-decode successfully in Swift, while the empty encoded input rejects.
        let decoder = LZ4AppleBlockDecoder(), buffer = LZ4BlockBuffer()
        try [UInt8(0)].withUnsafeBytes {
            try decoder.decode($0, into: buffer, blockMaximum: 65_536, maximumSize: 0)
        }
        XCTAssertEqual(buffer.outputCount, 0)
        // Expanded size exceeds block max by one: Swift's limit error wins.
        var oversized: [UInt8] = [0x1f, 65, 1, 0]
        oversized += [UInt8](repeating: 255, count: 256)
        oversized += [232, 0x50, 66, 67, 68, 69, 70]
        try compare(frame(oversized, flags: 0x70), chunk: 4_096)
    }

    func testRandomCLIFramesBitFlipsAndTruncationsMatchSwift() throws {
        guard let cli = ["/opt/homebrew/bin/lz4", "/usr/local/bin/lz4", "/usr/bin/lz4"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("lz4 CLI is not installed")
        }
        let temporary = try TestFixtures.makeTemporaryDirectory(label: "lz4-wave2")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var random = Generator(state: 0x2026_1029_1a4)
        let modes = [["-BI", "-BX"], ["-BI"], ["-BI", "--no-frame-crc"],
                     ["-BD", "-BX"], ["-l"], ["-BI", "-BX", "--no-frame-crc"]]
        for index in 0..<18 {
            let count = index < 6 ? 65_549 : 31 + random.int(4_096)
            let period = (0..<(1 + random.int(257))).map { _ in UInt8(random.int(256)) }
            let payload = Data((0..<count).map { offset in
                index % 3 == 0 ? UInt8(random.int(256)) : period[offset % period.count]
            })
            let source = temporary.appendingPathComponent("input")
            let target = temporary.appendingPathComponent("output.lz4")
            try payload.write(to: source)
            try ZipTestSupport.checkedRun(cli, arguments: ["-q", "-f", "-B4"] + modes[index % modes.count]
                                            + [source.path, target.path])
            let bytes = try Data(contentsOf: target)
            for output in [1, 7, 4_096, 65_537] {
                let actual = try compare(bytes, chunk: output, inputChunk: [1, 7, 4_096][index % 3], valid: true)
                XCTAssertEqual(actual.bytes, payload)
            }
            for mutation in 0..<96 {
                var changed = bytes
                if mutation % 3 == 0 {
                    changed = Data(bytes.prefix(random.int(bytes.count + 1)))
                } else {
                    for _ in 0..<(1 + random.int(3)) {
                        let bit = random.int(changed.count * 8)
                        changed[bit / 8] ^= UInt8(1 << (bit & 7))
                    }
                }
                try compare(changed, chunk: [1, 7, 4_096, 65_537][mutation % 4],
                            inputChunk: [1, 7, 4_096][mutation % 3])
            }
        }
    }

    func testTokenWalkMatchesSwiftOnArbitraryBlocks() throws {
        var random = Generator(state: 0x2026_1029_44)
        for index in 0..<8_192 {
            let block = (0..<random.int(128)).map { _ in UInt8(random.int(256)) }
            let maximum = [0, 7, 64, 65_536][index % 4]
            var swiftCount: Int?, swiftError: KaitoError?
            do { swiftCount = try LZ4BlockDecoder.decode(block, history: [], maximumSize: maximum).count }
            catch { swiftError = try XCTUnwrap(error as? KaitoError) }
            do {
                let count = try block.withUnsafeBytes { try LZ4AppleBlockDecoder.validatedSize($0, maximumSize: maximum) }
                XCTAssertNil(swiftError)
                XCTAssertEqual(count, swiftCount)
            } catch {
                XCTAssertEqual(error as? KaitoError, swiftError)
            }
        }
    }

    @discardableResult
    private func compare(_ bytes: Data, chunk: Int, inputChunk: Int = .max,
                         limits: ReadLimits = ReadLimits(), valid: Bool = false,
                         file: StaticString = #filePath, line: UInt = #line) throws -> Outcome {
        let source = ShortSource(bytes: bytes, maximum: inputChunk)
        let old = try LZ4HEADFrameDecompressor(source: source, limits: limits)
        let new = try LZ4FrameDecompressor(source: source, limits: limits)
        let reference = try outcome(old, chunk: chunk)
        let actual = try outcome(new, chunk: chunk)
        XCTAssertEqual(actual, reference, "chunk=\(chunk), input=\(bytes.prefix(32) as NSData)", file: file, line: line)
        if valid { XCTAssertNil(actual.error, file: file, line: line); XCTAssertTrue(actual.finished, file: file, line: line) }
        return actual
    }

    private func outcome(_ decoder: any Decompressor, chunk: Int) throws -> Outcome {
        var result = Outcome(), buffer = [UInt8](repeating: 0xa5, count: chunk)
        for _ in 0..<1_000_000 {
            do {
                let count = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
                result.bytes.append(contentsOf: buffer.prefix(count))
                if count == 0 { result.finished = decoder.isFinished; return result }
            } catch {
                result.error = try XCTUnwrap(error as? KaitoError)
                result.failedBuffer = Data(buffer)
                result.finished = decoder.isFinished
                return result
            }
        }
        XCTFail("decoder did not terminate")
        throw KaitoError.limitExceeded("differential read count")
    }

    private func word(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    private func frame(_ block: [UInt8], flags: UInt8, blockDescriptor: UInt8 = 0x40) -> Data {
        let descriptor = [flags, blockDescriptor]
        var result = word(0x184d2204) + Data(descriptor)
        result.append(UInt8(truncatingIfNeeded: XXH32.digest(descriptor) >> 8))
        result += word(UInt32(block.count)) + Data(block)
        if flags & 16 != 0 { result += word(XXH32.digest(block)) }
        result += word(0)
        if flags & 4 != 0 { result += word(0) } // grammar errors must precede this checksum
        return result
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
        mutating func int(_ upper: Int) -> Int {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Int(state % UInt64(upper))
        }
    }
}
