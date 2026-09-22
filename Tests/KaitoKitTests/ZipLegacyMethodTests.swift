import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

/// PKZIP 1.x の Shrink（1）/ Reduce（2〜5）/ Implode（6）。fixture は Tests/Fixtures/zip-legacy（自作 encoder、
/// unzip / 7zz / deark で独立に照合）。
final class ZipLegacyMethodTests: XCTestCase {
    func testR12SuccessivePartialClearsRetainUnusedCodes() throws {
        var compressed = Data(), accumulator: UInt64 = 0
        var bits = 0
        for code: UInt64 in [65, 66, 67, 256, 2, 256, 2, 68, 257] {
            accumulator |= code << bits; bits += 9
            while bits >= 8 { compressed.append(UInt8(accumulator & 255)); accumulator >>= 8; bits -= 8 }
        }
        if bits > 0 { compressed.append(UInt8(accumulator & 255)) }
        let expected = Data("ABCDCD".utf8)
        let bytes = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "clears.txt", uncompressedData: expected, compressedData: compressed, method: 1),
        ])
        let reader = try ArchiveReader.open(data: bytes)
        XCTAssertEqual(try reader.read(reader.entries[0]), expected)
        let stream = try reader.stream(reader.entries[0])
        var output = Data(), byte: UInt8 = 0
        while try withUnsafeMutableBytes(of: &byte, { try stream.read(into: $0) }) > 0 { output.append(byte) }
        XCTAssertEqual(output, expected)
    }

    private struct Payload: Decodable { let size: UInt64; let sha256: String }
    private struct Manifest: Decodable { let payload: [String: Payload]; let clearPayload: [String: Payload] }
    private static func manifest() throws -> Manifest {
        let url = ZipTestSupport.repositoryRoot.appendingPathComponent("Tests/Fixtures/zip-legacy/manifest.json")
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }
    private static func fixture(_ name: String) throws -> Data { try ZipTestSupport.checkedInFixture("zip-legacy/\(name)") }
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static let fixtures: [(file: String, method: String)] = [
        ("shrink.zip", "shrink"), ("reduce1.zip", "reduce1"), ("reduce2.zip", "reduce2"), ("reduce3.zip", "reduce3"),
        ("reduce4.zip", "reduce4"), ("reduce-empty-sets.zip", "reduce1"), ("implode-4k-2trees.zip", "implode"),
        ("implode-8k-3trees.zip", "implode"), ("implode-4k-3trees.zip", "implode"), ("implode-8k-2trees.zip", "implode"),
    ]

    func testFixturesDecodeToTheIndependentlyVerifiedPayloads() throws {
        let expected = try Self.manifest().payload
        for item in Self.fixtures {
            let reader = try ArchiveReader.open(data: try Self.fixture(item.file))
            XCTAssertEqual(reader.entries.count, expected.count, item.file)
            for entry in reader.entries {
                let want = try XCTUnwrap(expected[entry.name], "\(item.file): \(entry.name)")
                XCTAssertEqual(entry.methodDescription, item.method, "\(item.file): \(entry.name)")
                XCTAssertEqual(entry.uncompressedSize, want.size, "\(item.file): \(entry.name)")
                XCTAssertEqual(sha(try reader.read(entry)), want.sha256, "\(item.file): \(entry.name)")
            }
            // 小さな buffer での streaming と、1 byte ずつしか返さない source でも同じ内容になる。
            let stream = try reader.stream(reader.entries[3])
            var result = Data(), buffer = [UInt8](repeating: 0, count: 61)
            while true {
                let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
                if count == 0 { break }
                result.append(contentsOf: buffer.prefix(count))
            }
            XCTAssertEqual(sha(result), expected["mixed.bin"]?.sha256, item.file)
            let short = try ArchiveReader.open(source: ShortSource(try Self.fixture(item.file)))
            XCTAssertEqual(sha(try short.read(short.entries[0])), expected["text.txt"]?.sha256, item.file)
            let reopened = try reader.reopen()
            XCTAssertEqual(reopened.entries, reader.entries, item.file)
        }
    }

    /// 表が満杯になったときの部分クリア（256,2）と、解放された code の再利用。
    func testShrinkPartialClearReusesFreedCodes() throws {
        let expected = try XCTUnwrap(try Self.manifest().clearPayload["words.txt"])
        let reader = try ArchiveReader.open(data: try Self.fixture("shrink-clear.zip"))
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.methodDescription, "shrink")
        XCTAssertEqual(entry.uncompressedSize, expected.size)
        XCTAssertEqual(sha(try reader.read(entry)), expected.sha256)
    }

    func testCorruptionIsRejectedAndDoesNotLeakIntoTheNextMember() throws {
        let payload = try XCTUnwrap(try Self.manifest().payload["text.txt"])
        for item in Self.fixtures {
            let original = try Self.fixture(item.file)
            let layout = try ZipTestSupport.layout(of: original)
            let local = try XCTUnwrap(layout.localHeaderOffsets.first)
            let central = try XCTUnwrap(layout.centralEntryOffsets.first)
            let flags = try ZipTestSupport.readUInt16(original, at: central + 8)
            let method = try ZipTestSupport.readUInt16(original, at: central + 10)
            let start = local + 30 + Int(try ZipTestSupport.readUInt16(original, at: local + 26))
                + Int(try ZipTestSupport.readUInt16(original, at: local + 28))
            let compressed = original[start..<(start + Int(try ZipTestSupport.readUInt32(original, at: central + 20)))]
            let plain = try ArchiveReader.open(data: original).read(ArchiveReader.open(data: original).entries[0])
            XCTAssertEqual(UInt64(plain.count), payload.size)
            func archive(_ bytes: Data, size: Int = plain.count) throws -> Data {
                var entry = HandZipEntry(name: "text.txt", uncompressedData: plain, compressedData: bytes, method: method, flags: flags)
                entry.centralUncompressedSize = UInt32(size); entry.localUncompressedSize = UInt32(size)
                return try ZipTestSupport.makeArchive(entries: [entry,
                    HandZipEntry(name: "next.txt", uncompressedData: Data("must stay separate".utf8))])
            }
            XCTAssertEqual(try ArchiveReader.open(data: archive(compressed)).read(ArchiveReader.open(data: archive(compressed)).entries[0]), plain, item.file)
            // 途中で切れた stream、ビット反転、宣言サイズの食い違い。
            for length in [0, 1, 5, compressed.count / 2, compressed.count - 1] {
                try assertCorrupt(archive(compressed.prefix(length)), item.file)
            }
            // 終端記号が無いので、最後の copy の長さを伸ばすだけの反転は宣言サイズで切られて元と同じ出力になる。
            // その場合は CRC が通るが、出力が元と一致することを確かめる（他の反転は検出される）。
            for offset in [0, 3, compressed.count / 3, compressed.count - 2] {
                var bytes = compressed
                bytes[bytes.startIndex + offset] ^= 0x55
                try assertCorrupt(archive(bytes), item.file, intactOutput: plain)
            }
            try assertCorrupt(archive(compressed, size: plain.count - 1), item.file)
            try assertCorrupt(archive(compressed, size: plain.count + 1), item.file)
        }
    }

    func testUnknownEscapeAndBrokenImplodeTreeAreMalformed() throws {
        // Shrink: 256,3 は定義されていない。
        var shrink = Data()
        var acc: UInt64 = 0, n = 0
        for code in [UInt64(0x41), 256, 3] {
            acc |= code << UInt64(n); n += 9
            while n >= 8 { shrink.append(UInt8(acc & 0xFF)); acc >>= 8; n -= 8 }
        }
        shrink.append(UInt8(acc & 0xFF))
        try assertCorrupt(try ZipTestSupport.makeArchive(entries: [HandZipEntry(name: "a", uncompressedData: Data("AB".utf8),
            compressedData: shrink, method: 1, flags: 0)]), "shrink escape", expectMalformed: true)
        // Implode: 長さ表に 64 個ではなく 65 個の symbol がある木。
        let tree = Data([1, 0xF0, 0x00])          // 2 byte: 16 × 長さ 1 + 1 × 長さ 1 = 17 symbol
        try assertCorrupt(try ZipTestSupport.makeArchive(entries: [HandZipEntry(name: "a", uncompressedData: Data("AB".utf8),
            compressedData: tree + Data(count: 16), method: 6, flags: 0)]), "implode tree", expectMalformed: true)
        // 旧 method は宣言サイズが無いと展開できない。method 7（Tokenize）は未対応のまま。
        let reader = try ArchiveReader.open(data: try ZipTestSupport.makeArchive(entries: [HandZipEntry(name: "a", uncompressedData: Data("AB".utf8),
            compressedData: Data(count: 4), method: 7, flags: 0)]))
        XCTAssertEqual(reader.entries[0].methodDescription, "method 7")
        XCTAssertThrowsError(try reader.read(reader.entries[0])) {
            guard case .unsupportedMethod = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    /// PKZIP 1.x 時代の暗号化書庫: ZipCrypto の header + Shrink / Implode stream。unzip -P が読めることも確認する。
    func testZipCryptoWrappedLegacyMethods() throws {
        let payload = try XCTUnwrap(try Self.manifest().payload["text.txt"])
        let directory = try ZipTestSupport.temporaryDirectory(label: "zip-legacy-crypto")
        defer { try? FileManager.default.removeItem(at: directory) }
        for item in [Self.fixtures[0], Self.fixtures[7]] {
            let original = try Self.fixture(item.file)
            let layout = try ZipTestSupport.layout(of: original)
            let local = try XCTUnwrap(layout.localHeaderOffsets.first)
            let central = try XCTUnwrap(layout.centralEntryOffsets.first)
            let flags = try ZipTestSupport.readUInt16(original, at: central + 8)
            let method = try ZipTestSupport.readUInt16(original, at: central + 10)
            let crc = try ZipTestSupport.readUInt32(original, at: central + 16)
            let start = local + 30 + Int(try ZipTestSupport.readUInt16(original, at: local + 26))
                + Int(try ZipTestSupport.readUInt16(original, at: local + 28))
            let compressed = original[start..<(start + Int(try ZipTestSupport.readUInt32(original, at: central + 20)))]
            let plain = try ArchiveReader.open(data: original).read(ArchiveReader.open(data: original).entries[0])
            // APPNOTE §6.1: 12 byte header の末尾は CRC-32 の最上位 byte（bit 3 なし）。
            var cipher = ReferenceZipCrypto(password: "legacy")
            let header = Data((0..<11).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }) + Data([UInt8(truncatingIfNeeded: crc >> 24)])
            let encrypted = cipher.encrypt(header) + cipher.encrypt(Data(compressed))
            let archive = try ZipTestSupport.makeArchive(entries: [HandZipEntry(name: "text.txt", uncompressedData: plain,
                compressedData: encrypted, method: method, flags: flags | 0x0001)])
            let url = directory.appendingPathComponent("crypto-" + item.file)
            try archive.write(to: url)
            if FileManager.default.isExecutableFile(atPath: ZipTestSupport.unzipPath) {
                let result = try ZipTestSupport.run(ZipTestSupport.unzipPath, arguments: ["-P", "legacy", "-p", url.path])
                XCTAssertTrue(result.succeeded, "\(item.file): \(String(decoding: result.standardError, as: UTF8.self))")
                XCTAssertEqual(sha(result.standardOutput), payload.sha256, item.file)
            }
            let reader = try ArchiveReader.open(data: archive, options: ReaderOptions(password: "legacy"))
            XCTAssertTrue(reader.entries[0].isEncrypted, item.file)
            XCTAssertEqual(reader.entries[0].methodDescription, item.method, item.file)
            XCTAssertEqual(sha(try reader.read(reader.entries[0])), payload.sha256, item.file)
            let wrong = try ArchiveReader.open(data: archive, options: ReaderOptions(password: "wrong"))
            XCTAssertThrowsError(try wrong.read(wrong.entries[0]), item.file) { XCTAssertEqual($0 as? KaitoError, .wrongPassword) }
            let missing = try ArchiveReader.open(data: archive)
            XCTAssertThrowsError(try missing.read(missing.entries[0]), item.file) { XCTAssertEqual($0 as? KaitoError, .passwordRequired) }
        }
    }

    private struct ReferenceZipCrypto {
        private var key0: UInt32 = 0x1234_5678, key1: UInt32 = 0x2345_6789, key2: UInt32 = 0x3456_7890
        init(password: String) { for byte in password.utf8 { update(byte) } }
        mutating func encrypt(_ plaintext: Data) -> Data {
            var result = Data()
            for byte in plaintext {
                let temporary = key2 | 2
                result.append(byte ^ UInt8(truncatingIfNeeded: (temporary &* (temporary ^ 1)) >> 8))
                update(byte)
            }
            return result
        }
        private mutating func update(_ byte: UInt8) {
            key0 = Self.crc(key0, byte)
            key1 = (key1 &+ (key0 & 0xFF)) &* 134_775_813 &+ 1
            key2 = Self.crc(key2, UInt8(truncatingIfNeeded: key1 >> 24))
        }
        private static func crc(_ crc: UInt32, _ byte: UInt8) -> UInt32 {
            var value = crc ^ UInt32(byte)
            for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xEDB8_8320) }
            return value
        }
    }

    private func assertCorrupt(_ bytes: Data, _ label: String, expectMalformed: Bool = false, intactOutput: Data? = nil) throws {
        let reader = try ArchiveReader.open(data: bytes)
        do {
            let output = try reader.read(reader.entries[0])
            XCTAssertNotNil(intactOutput, "\(label): corrupt member decoded")
            XCTAssertEqual(output, intactOutput, label)
        } catch {
            switch error as? KaitoError {
            case .malformed: break
            case .truncated, .checksumMismatch: if expectMalformed { XCTFail("\(label): \(error)") }
            default: XCTFail("\(label): unexpected error \(error)")
            }
        }
        if reader.entries.count > 1 {
            XCTAssertEqual(try reader.read(reader.entries[1]), Data("must stay separate".utf8), label)
        }
    }

    private final class ShortSource: ByteSource {
        let data: Data
        init(_ data: Data) { self.data = data }
        var length: UInt64 { UInt64(data.count) }
        func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
            guard offset < length, !buffer.isEmpty else { return 0 }
            buffer[0] = data[Int(offset)]; return 1
        }
    }
}
