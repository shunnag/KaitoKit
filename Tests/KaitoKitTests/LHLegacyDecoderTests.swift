import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

final class LHLegacyDecoderTests: XCTestCase {
    private enum TestError: Error {
        case noProgress
    }

    func testLZSAbsoluteMatchAndTinyReads() throws {
        // Three literals followed by (absolute ring position 2031, length 3).
        let packed = Data([0xA0, 0xD0, 0xA8, 0x6F, 0xDE, 0x20])
        let decoder = try makeLArc(packed, size: 6, method: "-lzs-")
        XCTAssertEqual(try drain(decoder, bufferSize: 1), Data("ABCABC".utf8))
        XCTAssertTrue(decoder.isFinished)
    }

    func testLZSReadsPresetSpaceHistory() throws {
        // Match absolute position zero, length two, from the preset ring.
        let decoder = try makeLArc(Data([0, 0, 0]), size: 2, method: "-lzs-")
        XCTAssertEqual(try drain(decoder, bufferSize: 8), Data(repeating: 0x20, count: 2))
    }

    func testLZ5FlagOrderMatchAndFixedWindowSeed() throws {
        // The low four flag bits are literal, literal, literal, match. Position
        // 0xfee maps through LArc's +18 bias to the first produced byte.
        let repeated = try makeLArc(
            Data([0x07, 0x41, 0x42, 0x43, 0xEE, 0xF0]),
            size: 6,
            method: "-lz5-"
        )
        XCTAssertEqual(try drain(repeated, bufferSize: 2), Data("ABCABC".utf8))

        // Encoded position 13 maps to seed position 31, the first 0x01 run.
        let seeded = try makeLArc(Data([0, 13, 0]), size: 3, method: "-lz5-")
        XCTAssertEqual(try drain(seeded, bufferSize: 1), Data([1, 1, 1]))

        // The second flag is a literal, but the first match must produce three
        // bytes and finish the declared output before that literal is read.
        let threshold = try makeLArc(
            Data([0x02, 0x0D, 0x00, 0x5A]),
            size: 3,
            method: "-lz5-"
        )
        XCTAssertEqual(try drain(threshold, bufferSize: 8), Data([1, 1, 1]))
    }

    func testLZHUFZeroAndDeterministicOracleVectors() throws {
        let zeroDecoder = try makeLZHUF(Data(repeating: 0, count: 4), size: 61)
        XCTAssertEqual(try drain(zeroDecoder, bufferSize: 3), Data(repeating: 0x74, count: 61))

        var state: UInt32 = 0x1234_5678
        var packed = Data()
        packed.reserveCapacity(4_096)
        for _ in 0..<4_096 {
            state = state &* 1_664_525 &+ 1_013_904_223
            packed.append(UInt8(truncatingIfNeeded: state >> 24))
        }
        let decoder = try makeLZHUF(packed, size: 1_000)
        let decoded = try drain(decoder, bufferSize: 7)
        XCTAssertEqual(
            hexDigest(decoded),
            "6fb9c778ac764f33e00e114963344503fde329c9dd733ab22b7da21171e4c63c"
        )
    }

    func testLZHUFLongOraclePrefixCrossesDictionaryWrap() throws {
        let decoder = try makeLZHUF(Data(repeating: 0, count: 10_000), size: 100_000)
        let decoded = try readPrefix(decoder, count: 40_000, bufferSize: 31)
        XCTAssertEqual(
            hexDigest(decoded),
            "f3593edc5e874e84cd43e7cd83cdc76788118320d48f7d05e61185b3d048e7b7"
        )
    }

    func testHandcraftedLegacyArchiveAgainstLhasa() throws {
        guard let lhasaURL = LHATestSupport.lhasaExecutableURL else {
            throw XCTSkip("set KAITOKIT_LHA_EXECUTABLE or install lhasa")
        }

        let repeated = Data("ABCABC".utf8)
        let archiveData = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "lh1.bin",
                contents: Data(repeating: 0x74, count: 61),
                method: "-lh1-",
                headerLevel: 0,
                packedContents: Data(repeating: 0, count: 4)
            ),
            HandLHAEntry(
                name: "lzs.bin",
                contents: repeated,
                method: "-lzs-",
                headerLevel: 0,
                packedContents: Data([0xA0, 0xD0, 0xA8, 0x6F, 0xDE, 0x20])
            ),
            HandLHAEntry(
                name: "lz5.bin",
                contents: repeated,
                method: "-lz5-",
                headerLevel: 0,
                packedContents: Data([0x07, 0x41, 0x42, 0x43, 0xEE, 0xF0])
            ),
        ])

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KaitoKit-LHA-legacy-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let archiveURL = directory.appendingPathComponent("legacy.lzh")
        try archiveData.write(to: archiveURL)

        let reader = try ArchiveReader.open(url: archiveURL)
        XCTAssertEqual(
            reader.entries.map(\.methodDescription),
            ["-lh1-", "-lzs-", "-lz5-"]
        )
        for entry in reader.entries {
            let decoded = try reader.read(entry)
            let oracle = try lhasaMember(
                executable: lhasaURL,
                archive: archiveURL,
                name: entry.name
            )
            XCTAssertTrue(
                SHA256.hash(data: decoded).elementsEqual(SHA256.hash(data: oracle)),
                "digest differs for \(entry.methodDescription):\(entry.name)"
            )
        }
    }

    func testLegacyDecodersRejectTruncationOvershootAndLimits() throws {
        let truncatedLZS = try makeLArc(Data([0x80]), size: 1, method: "-lzs-")
        XCTAssertThrowsError(try drain(truncatedLZS, bufferSize: 1)) {
            XCTAssertEqual($0 as? KaitoError, KaitoError.truncated)
        }

        let oversizedMatch = try makeLArc(Data([0, 0, 0]), size: 1, method: "-lz5-")
        XCTAssertThrowsError(try drain(oversizedMatch, bufferSize: 1)) { error in
            guard case .malformed = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(
            try LZHUFDecoder(
                source: DataByteSource(Data([0])),
                offset: 0,
                compressedSize: 1,
                uncompressedSize: 1,
                limits: ReadLimits(maxDictionarySize: 4_095)
            )
        ) { error in
            guard case .limitExceeded = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    private func makeLArc(
        _ packed: Data,
        size: UInt64,
        method: String
    ) throws -> LArcDecoder {
        try LArcDecoder(
            source: DataByteSource(packed),
            offset: 0,
            compressedSize: UInt64(packed.count),
            uncompressedSize: size,
            method: method,
            limits: ReadLimits()
        )
    }

    private func makeLZHUF(_ packed: Data, size: UInt64) throws -> LZHUFDecoder {
        try LZHUFDecoder(
            source: DataByteSource(packed),
            offset: 0,
            compressedSize: UInt64(packed.count),
            uncompressedSize: size,
            limits: ReadLimits()
        )
    }

    private func drain(_ decoder: any Decompressor, bufferSize: Int) throws -> Data {
        var result = Data()
        var storage = [UInt8](repeating: 0, count: bufferSize)
        while !decoder.isFinished {
            let count = try storage.withUnsafeMutableBytes { try decoder.read(into: $0) }
            guard count > 0 else { throw TestError.noProgress }
            result.append(contentsOf: storage[..<count])
        }
        return result
    }

    private func readPrefix(
        _ decoder: any Decompressor,
        count expectedCount: Int,
        bufferSize: Int
    ) throws -> Data {
        var result = Data()
        var storage = [UInt8](repeating: 0, count: bufferSize)
        while result.count < expectedCount {
            let requested = min(bufferSize, expectedCount - result.count)
            let count = try storage.withUnsafeMutableBytes {
                try decoder.read(
                    into: UnsafeMutableRawBufferPointer(rebasing: $0[..<requested])
                )
            }
            guard count > 0 else { throw TestError.noProgress }
            result.append(contentsOf: storage[..<count])
        }
        return result
    }

    private func hexDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func lhasaMember(
        executable: URL,
        archive: URL,
        name: String
    ) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = ["-pq", archive.path, name]
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let decoded = output.fileHandleForReading.readDataToEndOfFile()
        let diagnostic = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == Process.TerminationReason.exit,
              process.terminationStatus == 0 else {
            throw KaitoError.malformed(
                "lhasa rejected \(name): \(String(decoding: diagnostic, as: UTF8.self))"
            )
        }
        return decoded
    }
}
