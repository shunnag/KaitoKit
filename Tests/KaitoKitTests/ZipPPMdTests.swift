import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

final class ZipPPMdTests: XCTestCase {
    private struct Expected {
        let name: String
        let size: UInt64
        let crc: UInt32
        let sha: String
        let method: UInt16
    }
    private static let fixtures: [(String, [Expected])] = [
        ("text-o8-default", [
            Expected(name: "payload.bin", size: 32768, crc: 0x7d64299a,
                     sha: "2ff68d77335ddd5b329c258fd9d49904a79e473515f7b115b2103b395bc64fde", method: 98),
        ]),
        ("text-o2-mem1m", [
            Expected(name: "payload.bin", size: 32768, crc: 0x7d64299a,
                     sha: "2ff68d77335ddd5b329c258fd9d49904a79e473515f7b115b2103b395bc64fde", method: 98),
        ]),
        ("text-o16-mem1m", [
            Expected(name: "payload.bin", size: 32768, crc: 0x7d64299a,
                     sha: "2ff68d77335ddd5b329c258fd9d49904a79e473515f7b115b2103b395bc64fde", method: 98),
        ]),
        ("binary-o6-mem4m", [
            Expected(name: "payload.bin", size: 262144, crc: 0x979bcff3,
                     sha: "d7ea2086df6d45c818b770d33f2965ce3f2fa95ed58da61f1f1763088e0fd434", method: 98),
        ]),
        ("random-o16-mem1m-restart", [
            Expected(name: "payload.bin", size: 57344, crc: 0xe1d7c1a4,
                     sha: "a3eb3985f9fb59fd87e620c87adbc05b8cacc59e8567963f8932b0b0b3932ebe", method: 98),
        ]),
        ("random-o16-mem1m-cutoff", [
            Expected(name: "payload.bin", size: 57344, crc: 0xe1d7c1a4,
                     sha: "a3eb3985f9fb59fd87e620c87adbc05b8cacc59e8567963f8932b0b0b3932ebe", method: 98),
        ]),
        ("mixed", [
            Expected(name: "stored.txt", size: 22, crc: 0xca86f7b4,
                     sha: "66df510e772aceb93b856a9cb41f8666474dab2268a93f9bc2c6604e88a2005d", method: 0),
            Expected(name: "text.txt", size: 32768, crc: 0x7d64299a,
                     sha: "2ff68d77335ddd5b329c258fd9d49904a79e473515f7b115b2103b395bc64fde", method: 98),
            Expected(name: "empty-stored.bin", size: 0, crc: 0x00000000,
                     sha: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", method: 0),
            Expected(name: "empty-ppmd.bin", size: 0, crc: 0x00000000,
                     sha: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", method: 98),
        ]),
    ]

    func testTextDefaultFixture() throws { try checkFixture(0) }
    func testTextOrder2Fixture() throws { try checkFixture(1) }
    func testTextOrder16Fixture() throws { try checkFixture(2) }
    func testBinaryFixture() throws { try checkFixture(3) }
    func testRestartFixture() throws { try checkFixture(4) }
    func testCutOffFixture() throws { try checkFixture(5) }
    func testMixedFixtureIncludingEmptyPPMd() throws { try checkFixture(6) }

    private func checkFixture(_ index: Int) throws {
        let (name, expected) = Self.fixtures[index]
        let reader = try ArchiveReader.open(data: fixture(name))
        XCTAssertEqual(reader.entries.count, expected.count)
        for (entry, expected) in zip(reader.entries, expected) {
            XCTAssertEqual(entry.name, expected.name)
            XCTAssertEqual(entry.uncompressedSize, expected.size)
            XCTAssertEqual(entry.crc32, expected.crc)
            XCTAssertEqual(entry.methodDescription, expected.method == 98 ? "ppmd" : "stored")
            XCTAssertEqual(hash(try reader.read(entry)), expected.sha, name)
        }
        let reopened = try reader.reopen()
        for (entry, expected) in zip(reopened.entries, expected) {
            XCTAssertEqual(hash(try reopened.read(entry)), expected.sha, name)
            let stream = try reopened.stream(entry)
            var bytes = [UInt8](repeating: 0, count: 37)
            var digest = SHA256()
            while true {
                let n = try bytes.withUnsafeMutableBytes { try stream.read(into: $0) }
                if n == 0 { break }
                digest.update(data: Data(bytes.prefix(n)))
            }
            XCTAssertEqual(digest.finalize().map { String(format: "%02x", $0) }.joined(), expected.sha, name)
        }
    }

    func testMemoryRestorationBranchesAndArenaRelease() throws {
        for index in [4, 5] {
            let packed = try packedFixture(index)
            let decoder = try makeDecoder(packed)
            let output = try drain(decoder, chunkSize: 113)
            XCTAssertEqual(hash(output), Self.fixtures[index].1[0].sha)
            if index == 4 { XCTAssertGreaterThanOrEqual(decoder.model.restartCount, 1) }
            else { XCTAssertGreaterThanOrEqual(decoder.model.cutOffCount, 1) }
            XCTAssertTrue(decoder.model.isArenaReleased)
            print("PPMd restoration: \(Self.fixtures[index].0), restart=\(decoder.model.restartCount), cutOff=\(decoder.model.cutOffCount)")
        }
    }


    func testGeneratedOrderMemoryInputAndRestorationMatrix() throws {
        try SevenZipTestSupport.requireSevenZip()
        let directory = try SevenZipTestSupport.temporaryDirectory(label: "zip-ppmd-matrix")
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = Data(String(repeating: "the quick archive reader decodes a page of text.\n", count: 1400).utf8).prefix(64 * 1024)
        var binary = Data(), random = Data()
        var value: UInt64 = 0x50504D49
        for i in 0..<(64 * 1024) {
            binary.append(UInt8(truncatingIfNeeded: (i / 32) ^ (i % 7)))
            value ^= value << 13
            value ^= value >> 7
            value ^= value << 17
            if i < 32 * 1024 { random.append(UInt8(truncatingIfNeeded: value)) }
        }
        let inputs = [Data(text), binary, random, Data(repeating: 0x41, count: 128 * 1024)]
        var cases = 0, ppmdCases = 0
        let started = Date()
        for order in [2, 4, 8, 16] {
            for memory in ["1m", "16m"] {
                for restore in [0, 1] {
                    for (kind, input) in inputs.enumerated() {
                        let name = "o\(order)-m\(memory)-a\(restore)-k\(kind).zip"
                        let archive = directory.appendingPathComponent(name)
                        try input.write(to: directory.appendingPathComponent("input.bin"))
                        try SevenZipTestSupport.checkedRun(arguments: [
                            "a", "-tzip", "-mm=PPMd:o=\(order):mem=\(memory):a=\(restore)",
                            "-bd", "-bb0", "-y", archive.path, "input.bin",
                        ], currentDirectory: directory)
                        let reader = try ArchiveReader.open(url: archive)
                        let entry = try XCTUnwrap(reader.entries.first)
                        XCTAssertEqual(try reader.read(entry), input, name)
                        if entry.methodDescription == "ppmd" { ppmdCases += 1 }
                        cases += 1
                    }
                }
            }
        }
        XCTAssertEqual(cases, 64)
        XCTAssertGreaterThanOrEqual(ppmdCases, 48)
        print("PPMd matrix: \(cases) archives, \(ppmdCases) method 98, \(Date().timeIntervalSince(started)) seconds")
    }

    func testTruncatedStreams() throws {
        let original = try packedFixture(0)
        for length in [original.bytes.count / 4, original.bytes.count / 2,
                       original.bytes.count * 9 / 10, original.bytes.count - 1] {
            var truncated = original
            truncated.bytes = Data(original.bytes.prefix(length))
            // 元の宣言サイズを保持し、物理的に失われた末尾を ZIP の範囲検証に渡す。
            XCTAssertThrowsError(try {
                let reader = try ArchiveReader.open(data: archive(
                    truncated, declaredCompressedSize: UInt32(original.bytes.count + 2)
                ))
                return try reader.read(reader.entries[0])
            }()) { self.assertDecodeError($0) }
            if length < original.bytes.count - 1 {
                // 大幅な切断はメタデータを整合させても decoder 自身が拒否する。
                try assertCorrupt(truncated)
            }
        }
    }

    func testFlippedStreamBytes() throws {
        let original = try packedFixture(0)
        for position in 0..<16 {
            var changed = original
            changed.bytes[changed.bytes.count * position / 16] ^= 0xFF
            try assertCorrupt(changed)
        }
    }

    func testParameterValidationAndMemoryLimits() throws {
        let original = try packedFixture(0)
        for word in [original.parameter & ~0xF, (original.parameter & ~0x3000) | 0x3000] {
            var changed = original
            changed.parameter = word
            let archive = try archive(changed)
            let reader = try ArchiveReader.open(data: archive)
            XCTAssertThrowsError(try reader.read(reader.entries[0])) {
                guard case .malformed = $0 as? KaitoError else { return XCTFail("\($0)") }
            }
        }
        var changed = original
        changed.parameter = 0x0017
        let reader = try ArchiveReader.open(data: archive(changed),
                                           options: ReaderOptions(limits: ReadLimits(maxDictionarySize: 1 << 20)))
        XCTAssertThrowsError(try reader.read(reader.entries[0])) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("\($0)") }
        }
        // 初回 symbol は辞書サイズに依存しないため、上限値の実割当ても検証する。
        changed.parameter = 0x0FF7
        changed.size = 1
        let decoder = try makeDecoder(changed, limit: ReadLimits().maxDictionarySize)
        XCTAssertEqual(try drain(decoder).first, UInt8(ascii: "r"))
        XCTAssertTrue(decoder.model.isArenaReleased)
    }

    func testFreezeParameterAndCorruptRestoration() throws {
        var text = try packedFixture(0)
        text.parameter |= 0x2000
        XCTAssertEqual(hash(try drain(makeDecoder(text))), Self.fixtures[0].1[0].sha)
        var random = try packedFixture(4)
        random.parameter = (random.parameter & ~0x3000) | 0x2000
        let decoder = try makeDecoder(random)
        do {
            let output = try drain(decoder)
            XCTAssertNotEqual(CRC32.checksum(output), random.crc)
        } catch { assertDecodeError(error) }
        XCTAssertGreaterThanOrEqual(decoder.model.freezeCount, 1)
    }

    func testShortParameterHeaderAndEmptyEntry() throws {
        for count in [0, 1] {
            let data = try ZipTestSupport.makeArchive(entries: [
                HandZipEntry(name: "short", compressedData: Data(repeating: 0, count: count), method: 98),
            ])
            let reader = try ArchiveReader.open(data: data)
            XCTAssertThrowsError(try reader.read(reader.entries[0])) {
                XCTAssertEqual($0 as? KaitoError, .truncated)
            }
        }
        for restore in 0...2 {
            let packed = Packed(bytes: Data([0xFF, 0xFF, 0xFF, 0xFF]),
                                parameter: UInt16(7 | restore << 12), size: 0, crc: 0)
            let reader = try ArchiveReader.open(data: archive(packed))
            XCTAssertEqual(try reader.read(reader.entries[0]), Data())
            let decoder = try makeDecoder(packed)
            XCTAssertTrue(decoder.isFinished)
            XCTAssertTrue(decoder.model.isArenaReleased)
        }
    }

    func testDeclaredSizeBeyondEndMarker() throws {
        let original = try fixture(Self.fixtures[0].0)
        var changed = original
        let signature = Data([0x50, 0x4B, 0x01, 0x02])
        let central = try XCTUnwrap(changed.range(of: signature)).lowerBound
        let size = u32(changed, central + 24) + 1
        for i in 0..<4 { changed[central + 24 + i] = UInt8(truncatingIfNeeded: size >> (i * 8)) }
        let reader = try ArchiveReader.open(data: changed)
        XCTAssertThrowsError(try reader.read(reader.entries[0])) { self.assertDecodeError($0) }
        // ローカルヘッダの整合性検査とは別に、model の root escape も検証する。
        var packed = try packedFixture(0)
        packed.size += 1
        XCTAssertThrowsError(try drain(makeDecoder(packed))) {
            XCTAssertEqual($0 as? KaitoError, .truncated)
        }
    }

    func testShortByteSourceReadsStayInsideCompressedRange() throws {
        let packed = try packedFixture(0)
        let prefix = Data(repeating: 0xA5, count: 17)
        let source = ShortSource(bytes: prefix + packed.bytes + Data(repeating: 0x5A, count: 19),
                                 start: prefix.count, end: prefix.count + packed.bytes.count)
        let decoder = try PPMdVarIDecoder(source: source, offset: UInt64(source.start),
                                         compressedSize: UInt64(packed.bytes.count), parameterWord: packed.parameter,
                                         expectedSize: packed.size, memorySizeLimit: 1 << 20)
        XCTAssertEqual(hash(try drain(decoder, chunkSize: 1)), Self.fixtures[0].1[0].sha)
    }

    private struct ShortSource: ByteSource {
        let bytes: Data
        let start: Int
        let end: Int
        var length: UInt64 { UInt64(bytes.count) }
        func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
            guard offset >= start, offset <= end, buffer.count <= end - Int(offset) else {
                throw KaitoError.malformed("PPMd source read crossed compressed range")
            }
            let n = min(3, buffer.count)
            for i in 0..<n { buffer[i] = bytes[Int(offset) + i] }
            return n
        }
    }

    private func archive(_ packed: Packed, declaredCompressedSize: UInt32? = nil) throws -> Data {
        let header = Data([UInt8(truncatingIfNeeded: packed.parameter), UInt8(packed.parameter >> 8)])
        return try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "payload.bin", compressedData: header + packed.bytes, method: 98,
                         centralCRC32: packed.crc, centralCompressedSize: declaredCompressedSize,
                         centralUncompressedSize: UInt32(packed.size),
                         localCRC32: packed.crc, localCompressedSize: declaredCompressedSize,
                         localUncompressedSize: UInt32(packed.size)),
        ])
    }
    private func assertCorrupt(_ packed: Packed, file: StaticString = #filePath, line: UInt = #line) throws {
        let reader = try ArchiveReader.open(data: archive(packed))
        XCTAssertThrowsError(try reader.read(reader.entries[0]), file: file, line: line) { self.assertDecodeError($0) }
    }
    private func assertDecodeError(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        switch error as? KaitoError {
        case .truncated, .malformed, .checksumMismatch: break
        default: XCTFail("unexpected decoder error: \(error)", file: file, line: line)
        }
    }

    private struct Packed {
        var bytes: Data
        var parameter: UInt16
        var size: UInt64
        var crc: UInt32
    }

    private func packedFixture(_ index: Int) throws -> Packed {
        let archive = try fixture(Self.fixtures[index].0)
        let offset = 30 + Int(u16(archive, 26)) + Int(u16(archive, 28))
        let compressedSize = Int(u32(archive, 18))
        return Packed(bytes: Data(archive[(offset + 2)..<(offset + compressedSize)]),
                      parameter: u16(archive, offset), size: UInt64(u32(archive, 22)), crc: u32(archive, 14))
    }

    private func makeDecoder(_ packed: Packed, limit: UInt64 = 1 << 30) throws -> PPMdVarIDecoder {
        try PPMdVarIDecoder(source: DataByteSource(packed.bytes), offset: 0,
                           compressedSize: UInt64(packed.bytes.count), parameterWord: packed.parameter,
                           expectedSize: packed.size, memorySizeLimit: limit)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/zip-ppmd/" + name + ".zip.b64")
        let encoded = try Data(contentsOf: url)
        XCTAssertLessThanOrEqual(encoded.count, 40 * 1024)
        return try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
    }

    private func drain(_ decoder: any Decompressor, chunkSize: Int = 4096) throws -> Data {
        var output = Data(), bytes = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let n = try bytes.withUnsafeMutableBytes { try decoder.read(into: $0) }
            if n == 0 { return output }
            output.append(contentsOf: bytes.prefix(n))
        }
    }
    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }
    private func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(u16(data, offset)) | (UInt32(u16(data, offset + 2)) << 16)
    }
}
