import Foundation
import XCTest
@testable import KaitoKit

final class XZResourceLimitTests: XCTestCase {
    func testRiscVXZAndTarXZReportUnsupportedMethod() throws {
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["riscv.xz", "riscv.tar.xz"] {
            let data = try fixture(name)
            let url = directory.appendingPathComponent(name)
            try data.write(to: url)
            XCTAssertThrowsError(try {
                let reader = try ArchiveReader.open(url: url)
                _ = try reader.read(reader.entries[0])
            }()) {
                XCTAssertEqual($0 as? KaitoError, .unsupportedMethod("XZ RISC-V filter"), name)
            }
        }
        // 連結 stream の後半も native decoder より先に検査する。
        XCTAssertThrowsError(try read(fixture("x86.xz") + fixture("riscv.xz"), dictionary: 1 << 20)) {
            XCTAssertEqual($0 as? KaitoError, .unsupportedMethod("XZ RISC-V filter"))
        }
    }

    func testX86XZFilterStillDecodes() throws {
        let expected = Data(String(repeating: "KaitoKit XZ filter fixture\n", count: 64).utf8) + Data(0...255)
        XCTAssertEqual(try read(fixture("x86.xz"), dictionary: 1 << 20), expected)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/singlefile/\(name).b64")
        return try XCTUnwrap(Data(base64Encoded: try String(contentsOf: url, encoding: .utf8), options: .ignoreUnknownCharacters))
    }

    func testDictionaryLimitIsAppliedToSingleStreamsAndConcatenation() throws {
        let small = try xz(dictionary: 4_096)
        let large = try xz(dictionary: 1_048_576)
        let payload = Data(repeating: 65, count: 2_048)
        XCTAssertEqual(try read(small, dictionary: 4_096), payload)
        for bytes in [small, large, small + Data(repeating: 0, count: 4) + large] {
            let limit: UInt64 = bytes == small ? 4_095 : 4_096
            XCTAssertThrowsError(try read(bytes, dictionary: limit)) { error in
                guard case .limitExceeded = error as? KaitoError else { return XCTFail("\(error)") }
            }
        }
        XCTAssertEqual(try read(small + large, dictionary: 1_048_576), payload + payload)
    }

    func testDictionaryLimitReachesXZInsideXar() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let base64 = try String(contentsOf: root.appendingPathComponent("Fixtures/container/xar-xz.xar.b64"), encoding: .utf8)
        let bytes = try XCTUnwrap(Data(base64Encoded: base64, options: .ignoreUnknownCharacters))
        let reader = try ArchiveReader.open(data: bytes, options: ReaderOptions(limits: ReadLimits(maxDictionarySize: 4_095)))
        XCTAssertThrowsError(try reader.read(reader.entries[0])) { error in
            guard case .limitExceeded = error as? KaitoError else { return XCTFail("\(error)") }
        }
    }

    func testLaterBlocksCannotBypassDictionaryLimit() throws {
        let bytes = try commandXZ(["--filters=lzma2:dict=4KiB", "--filters1=lzma2:dict=1MiB",
                                   "--block-list=0:1024,1:1024"])
        XCTAssertEqual(try read(bytes, dictionary: 1_048_576), Data(repeating: 65, count: 2_048))
        XCTAssertThrowsError(try read(bytes, dictionary: 4_096)) { error in
            guard case .limitExceeded = error as? KaitoError else { return XCTFail("\(error)") }
        }
    }

    func testAllCheckTypesEmptyStreamsAndRawChunksRetainCompatibility() throws {
        for check in ["none", "crc32", "crc64", "sha256"] {
            let bytes = try commandXZ(["--check=" + check, "--lzma2=dict=4KiB", "--block-size=511"])
            XCTAssertEqual(try read(bytes, dictionary: 4_096), Data(repeating: 65, count: 2_048), check)
        }
        let empty = try commandXZ(["--lzma2=dict=4KiB"], payload: Data())
        XCTAssertEqual(try read(empty, dictionary: 0), Data())
        // Incompressible input forces raw LZMA2 chunks, not just compressed ones.
        var state: UInt64 = 0x584a_2026
        let raw = Data((0..<150_000).map { _ in
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        })
        let bytes = try commandXZ(["--lzma2=dict=4KiB", "--block-size=70000"], payload: raw)
        XCTAssertEqual(try read(bytes, dictionary: 4_096), raw)
        let filtered = try commandXZ(["--delta=dist=2", "--lzma2=dict=4KiB"], payload: raw)
        XCTAssertEqual(try read(filtered, dictionary: 4_096), raw)
    }

    func testStructuralDamageTruncationAndBoundedSourcesAreRejected() throws {
        let bytes = try xz(dictionary: 4_096)
        for end in 0..<bytes.count {
            XCTAssertThrowsError(try read(Data(bytes.prefix(end)), dictionary: 4_096), "end=\(end)")
        }
        for padding in [1, 2, 3, 5] {
            XCTAssertThrowsError(try read(bytes + Data(repeating: 0, count: padding), dictionary: 4_096))
        }
        // Recompute header CRC so reserved flags, properties, and VLIs reach the parser.
        let blockSize = (Int(bytes[12]) + 1) * 4
        for (index, value): (Int, UInt8) in [(13, 4), (14, 0x80), (15, 0xff), (16, 41), (17, 1)] {
            var invalid = bytes
            invalid[index] = value
            let crc = CRC32.checksum(Data(invalid[12..<(12 + blockSize - 4)]))
            for byte in 0..<4 { invalid[12 + blockSize - 4 + byte] = UInt8(truncatingIfNeeded: crc >> (8 * byte)) }
            XCTAssertThrowsError(try read(invalid, dictionary: 4_096), "index=\(index)")
        }
        // Respect the caller's range and small source reads, including a nonzero base.
        let wrapped = Data(repeating: 0xff, count: 7) + bytes + Data(repeating: 0xff, count: 7)
        let source = TinySource(bytes: wrapped)
        let decoder = try XZDecompressor(source: source, offset: 7, compressedSize: UInt64(bytes.count),
                                        limits: ReadLimits(maxDictionarySize: 4_096))
        var output = Data(), buffer = [UInt8](repeating: 0, count: 17)
        while !decoder.isFinished {
            let count = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
            output.append(contentsOf: buffer.prefix(count))
        }
        XCTAssertEqual(output, Data(repeating: 65, count: 2_048))
    }

    private struct TinySource: ByteSource {
        let bytes: Data
        var length: UInt64 { UInt64(bytes.count) }
        func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
            guard offset < length else { return 0 }
            let count = min(3, buffer.count, Int(length - offset))
            bytes.copyBytes(to: UnsafeMutableRawBufferPointer(rebasing: buffer[..<count]),
                            from: Int(offset)..<(Int(offset) + count))
            return count
        }
    }

    private func commandXZ(_ arguments: [String], payload: Data = Data(repeating: 65, count: 2_048)) throws -> Data {
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input")
        try payload.write(to: input)
        let xz = ZipTestSupport.xzPath
        try ZipTestSupport.requireExecutable(xz)
        _ = try ZipTestSupport.checkedRun(xz,
            arguments: ["--threads=1", "--keep"] + arguments + [input.path], currentDirectory: directory)
        let output = input.appendingPathExtension("xz")
        _ = try ZipTestSupport.checkedRun(xz, arguments: ["--test", output.path], currentDirectory: directory)
        return try Data(contentsOf: output)
    }

    private func read(_ bytes: Data, dictionary: UInt64) throws -> Data {
        let reader = try ArchiveReader.open(data: bytes,
            options: ReaderOptions(limits: ReadLimits(maxDictionarySize: dictionary)))
        return try reader.read(reader.entries[0])
    }

    private func xz(dictionary: Int) throws -> Data {
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("fixture.xz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import lzma,pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(lzma.compress(b'A'*2048, filters=[{'id':lzma.FILTER_LZMA2,'dict_size':int(sys.argv[2])}]))", output.path, String(dictionary)]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try Data(contentsOf: output)
    }
}
