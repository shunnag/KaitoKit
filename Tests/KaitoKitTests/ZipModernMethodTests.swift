import CryptoKit
import Foundation
import Synchronization
@testable import KaitoKit
import XCTest

enum ModernZIPFixtures {
    static let password = "KaitoFixture"
    static let payload = Data(String(repeating: "XZ and Zstandard ZIP interoperability 日本語\n", count: 800).utf8)
    static func data(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/zip-modern/" + name + ".b64")
        return try XCTUnwrap(Data(base64Encoded: Data(contentsOf: url), options: .ignoreUnknownCharacters))
    }
    static func payloadRange(_ bytes: Data) throws -> Range<Int> {
        let layout = try ZipTestSupport.layout(of: bytes)
        let local = try XCTUnwrap(layout.localHeaderOffsets.first)
        let central = try XCTUnwrap(layout.centralEntryOffsets.first)
        let start = local + 30 + Int(try ZipTestSupport.readUInt16(bytes, at: local + 26))
            + Int(try ZipTestSupport.readUInt16(bytes, at: local + 28))
        return start..<(start + Int(try ZipTestSupport.readUInt32(bytes, at: central + 20)))
    }
}

final class ZipModernMethodTests: XCTestCase {
    func testXZFixtureReadsThroughSmallBuffersAndReopens() throws {
        try verify("xz.zip", method: "xz")
    }

    func testLegacyAndCurrentZstandardHaveTheSameContentsAndDescription() throws {
        try verify("zstd20.zip", method: "zstd")
        try verify("zstd93.zip", method: "zstd")
    }

    func testXZZipCryptoAndAESAndLegacyZstandardAES() throws {
        for name in ["xz-aes.zip", "xz-zipcrypto.zip", "zstd-aes20.zip", "zstd-aes93.zip"] {
            try verify(name, method: name.hasPrefix("xz") ? "xz" : "zstd", password: ModernZIPFixtures.password)
            let bytes = try ModernZIPFixtures.data(name)
            let missing = try ArchiveReader.open(data: bytes)
            XCTAssertThrowsError(try missing.read(missing.entries[0])) {
                XCTAssertEqual($0 as? KaitoError, .passwordRequired)
            }
            let wrong = try ArchiveReader.open(data: bytes, options: ReaderOptions(password: "wrong"))
            XCTAssertThrowsError(try wrong.read(wrong.entries[0])) {
                XCTAssertEqual($0 as? KaitoError, .wrongPassword)
            }
        }
    }

    func testDictionaryLimitsAlsoApplyAfterDecryptingXZ() throws {
        for name in ["xz.zip", "xz-aes.zip", "xz-zipcrypto.zip", "zstd20.zip", "zstd-aes20.zip"] {
            let reader = try ArchiveReader.open(data: ModernZIPFixtures.data(name), options: ReaderOptions(
                limits: ReadLimits(maxDictionarySize: 1_024), password: ModernZIPFixtures.password))
            XCTAssertThrowsError(try reader.read(reader.entries[0]), name) {
                guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("\(name): \($0)") }
            }
        }
    }

    func testXZEmptyConcatenationAndPadding() throws {
        let empty = try ModernZIPFixtures.data("empty.xz")
        let packed = try ModernZIPFixtures.data("small-dictionary.xz")
        for (compressed, plain) in [(empty, Data()),
            (empty + Data(repeating: 0, count: 4) + packed + Data(repeating: 0, count: 8), ModernZIPFixtures.payload),
            (packed + packed, ModernZIPFixtures.payload + ModernZIPFixtures.payload)] {
            let archive = try ZipTestSupport.makeArchive(entries: [HandZipEntry(
                name: "payload.txt", uncompressedData: plain, compressedData: compressed, method: 95)])
            let reader = try ArchiveReader.open(data: archive,
                options: ReaderOptions(limits: ReadLimits(maxDictionarySize: 1 << 20)))
            XCTAssertEqual(try reader.read(reader.entries[0]), plain)
        }
    }

    func testChecksumsAndDeclaredSizesRemainEnforced() throws {
        for name in ["xz.zip", "zstd20.zip"] {
            let original = try ModernZIPFixtures.data(name)
            let layout = try ZipTestSupport.layout(of: original)
            let central = try XCTUnwrap(layout.centralEntryOffsets.first)
            var crc = original
            try ZipTestSupport.writeUInt32(1, to: &crc, at: central + 16)
            let reader = try ArchiveReader.open(data: crc)
            XCTAssertThrowsError(try reader.read(reader.entries[0])) {
                XCTAssertEqual($0 as? KaitoError, .checksumMismatch(entry: 0))
            }
            for size in [ModernZIPFixtures.payload.count - 1, ModernZIPFixtures.payload.count + 1] {
                var bytes = original
                try ZipTestSupport.writeUInt32(UInt32(size), to: &bytes, at: central + 24)
                try assertCorrupt(bytes)
            }
        }
    }

    func testTruncatedAndCorruptedXZCannotConsumeTheNextMember() throws {
        let packed = try ModernZIPFixtures.data("small-dictionary.xz")
        for length in [0, 1, 11, packed.count / 2, packed.count - 1] {
            try assertCorrupt(makeXZ(Data(packed.prefix(length))))
        }
        for offset in [0, 8, 16, packed.count - 10, packed.count - 1] {
            var bytes = packed
            bytes[offset] ^= 0x80
            try assertCorrupt(makeXZ(bytes))
        }
        try assertCorrupt(makeXZ(packed + Data([0x50, 0x4b, 0, 0])))
    }

    func testAESEndAuthenticationIsNotBypassedByXZPreflight() throws {
        for name in ["xz-aes.zip", "zstd-aes20.zip"] {
            var bytes = try ModernZIPFixtures.data(name)
            let range = try ModernZIPFixtures.payloadRange(bytes)
            bytes[range.upperBound - 1] ^= 1
            let reader = try ArchiveReader.open(data: bytes, options: ReaderOptions(password: ModernZIPFixtures.password))
            XCTAssertThrowsError(try reader.read(reader.entries[0])) {
                // Match the existing WinZip AES authentication-failure contract.
                XCTAssertEqual($0 as? KaitoError, .wrongPassword)
            }
        }
    }

    func testZIP64AndAllDataDescriptorForms() throws {
        for (name, method): (String, UInt16) in [("xz.zip", 95), ("zstd20.zip", 20)] {
            let original = try ModernZIPFixtures.data(name)
            let compressed = original[try ModernZIPFixtures.payloadRange(original)]
            for wide in [false, true] {
                for signature in [false, true] {
                    var entry = HandZipEntry(name: "payload.txt", uncompressedData: ModernZIPFixtures.payload,
                        compressedData: Data(compressed), method: method, hasDataDescriptor: true)
                    entry.dataDescriptorHasSignature = signature
                    entry.dataDescriptorUsesZIP64 = wide
                    if wide {
                        entry.localExtra = try ZipTestSupport.zip64Extra(values: [UInt64(ModernZIPFixtures.payload.count), UInt64(compressed.count)])
                        entry.centralExtra = entry.localExtra
                        entry.localCompressedSize = .max; entry.localUncompressedSize = .max
                        entry.centralCompressedSize = .max; entry.centralUncompressedSize = .max
                    }
                    let bytes = try ZipTestSupport.makeArchive(entries: [entry], forceZIP64End: wide)
                    let reader = try ArchiveReader.open(data: bytes)
                    XCTAssertEqual(try reader.read(reader.entries[0]), ModernZIPFixtures.payload)
                }
            }
        }
    }

    func testCentralMethodRemainsAuthoritativeWhenLocalMethodDiffers() throws {
        for name in ["xz.zip", "zstd20.zip"] {
            var bytes = try ModernZIPFixtures.data(name)
            // Existing ZIP policy intentionally trusts the central directory.
            try ZipTestSupport.writeUInt16(8, to: &bytes, at: 8)
            let reader = try ArchiveReader.open(data: bytes)
            XCTAssertEqual(try reader.read(reader.entries[0]), ModernZIPFixtures.payload)
        }
    }

    func testShortByteSourceReadsAndByteSplitReopenAfterUnlink() throws {
        let directory = try ZipTestSupport.temporaryDirectory(label: "modern-method-splits")
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["xz.zip", "zstd20.zip", "xz-aes.zip", "zstd-aes20.zip"] {
            let bytes = try ModernZIPFixtures.data(name)
            let options = ReaderOptions(password: ModernZIPFixtures.password)
            let short = try ArchiveReader.open(source: ShortSource(bytes: bytes), options: options)
            XCTAssertEqual(try short.read(short.entries[0]), ModernZIPFixtures.payload)
            let half = bytes.count / 2
            let first = directory.appendingPathComponent(name + ".001")
            let second = directory.appendingPathComponent(name + ".002")
            try bytes.prefix(half).write(to: first)
            try bytes.suffix(bytes.count - half).write(to: second)
            let reader = try ArchiveReader.open(url: first, options: options)
            try FileManager.default.removeItem(at: first)
            try FileManager.default.removeItem(at: second)
            let reopened = try reader.reopen()
            XCTAssertEqual(try reopened.read(reopened.entries[0]), ModernZIPFixtures.payload)
        }
    }

    func testAESXZReadsCiphertextLinearlyWhenPreflightingAndDecoding() throws {
        try ZipTestSupport.requireExecutable(ZipTestSupport.sevenZipPath, reason: "7zz oracle unavailable")
        let directory = try ZipTestSupport.temporaryDirectory(label: "xz-aes-linear")
        defer { try? FileManager.default.removeItem(at: directory) }
        var payload = Data(count: 2 * 1_024 * 1_024)
        payload.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            var value: UInt64 = 0x4b6169746f
            for index in buffer.indices {
                value ^= value << 13; value ^= value >> 7; value ^= value << 17
                buffer[index] = index % 128 < 96 ? UInt8(truncatingIfNeeded: value) : 0
            }
        }
        let input = directory.appendingPathComponent("payload.bin")
        try payload.write(to: input)
        let archive = directory.appendingPathComponent("encrypted.zip")
        try ZipTestSupport.makeSevenZip(sourceDirectory: directory, paths: ["payload.bin"],
            archiveURL: archive, method: "XZ", password: ModernZIPFixtures.password)
        let bytes = try Data(contentsOf: archive)
        XCTAssertGreaterThan(bytes.count, 1_024 * 1_024, "Weakly compressible input exercises many XZ chunks")
        for memoryLimit: UInt64 in [16_384, 4 * 1_024 * 1_024] {
            let source = CountingSource(bytes: bytes)
            let reader = try ArchiveReader.open(source: source, options: ReaderOptions(
                limits: ReadLimits(inMemorySingleFileLimit: memoryLimit), password: ModernZIPFixtures.password))
            XCTAssertEqual(reader.entries[0].methodDescription, "xz", "7zz must not fall back to stored")
            XCTAssertTrue(reader.entries[0].isEncrypted)
            source.count.withLock { $0 = 0 }
            XCTAssertEqual(try reader.read(reader.entries[0]), payload)
            let readBytes = source.count.withLock { $0 }
            print("XZ AES: \(bytes.count) archive bytes, \(readBytes) bytes read, staging memory limit \(memoryLimit)")
            XCTAssertLessThanOrEqual(readBytes, bytes.count * 3, "Preflight must not reauthenticate the whole member for every XZ chunk")
        }
    }

    func testIndependentSevenZipCanReadXZAndCurrentZstandardFixtures() throws {
        try ZipTestSupport.requireExecutable(ZipTestSupport.sevenZipPath, reason: "7zz oracle unavailable")
        let directory = try ZipTestSupport.temporaryDirectory(label: "modern-method-oracle")
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["xz.zip", "xz-aes.zip", "xz-zipcrypto.zip", "zstd93.zip", "zstd-aes93.zip"] {
            let url = directory.appendingPathComponent(name)
            try ModernZIPFixtures.data(name).write(to: url)
            XCTAssertEqual(try ZipTestSupport.sevenZipData(archiveURL: url, entryName: "payload.txt",
                password: ModernZIPFixtures.password), ModernZIPFixtures.payload)
        }
    }

    private func verify(_ name: String, method: String, password: String? = nil) throws {
        let reader = try ArchiveReader.open(data: ModernZIPFixtures.data(name), options: ReaderOptions(password: password))
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.methodDescription, method)
        XCTAssertEqual(try reader.read(entry), ModernZIPFixtures.payload)
        let reopened = try reader.reopen()
        let stream = try reopened.stream(reopened.entries[0])
        var result = Data(), buffer = [UInt8](repeating: 0, count: 37)
        while true {
            let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        XCTAssertEqual(result, ModernZIPFixtures.payload)
        XCTAssertEqual(SHA256.hash(data: result).map { String(format: "%02x", $0) }.joined(),
            "16f3e0211c947966c0e1e379ac87c947174a6b227df976fe95373940be9449b4")
    }

    private func makeXZ(_ bytes: Data) throws -> Data {
        try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "payload.txt", uncompressedData: ModernZIPFixtures.payload, compressedData: bytes, method: 95),
            HandZipEntry(name: "next.txt", uncompressedData: Data("must stay separate".utf8))])
    }

    private func assertCorrupt(_ bytes: Data) throws {
        let reader = try ArchiveReader.open(data: bytes)
        XCTAssertThrowsError(try reader.read(reader.entries[0])) {
            switch $0 as? KaitoError {
            case .malformed, .truncated, .checksumMismatch: break
            default: XCTFail("Unexpected error: \($0)")
            }
        }
        if reader.entries.count > 1 {
            XCTAssertEqual(try reader.read(reader.entries[1]), Data("must stay separate".utf8))
        }
    }

    private final class CountingSource: ByteSource {
        let bytes: Data
        let count = Mutex(0)
        init(bytes: Data) { self.bytes = bytes }
        var length: UInt64 { UInt64(bytes.count) }
        func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
            guard offset < length else { return 0 }
            let size = min(buffer.count, bytes.count - Int(offset))
            bytes.withUnsafeBytes { source in
                buffer.baseAddress!.copyMemory(from: source.baseAddress!.advanced(by: Int(offset)), byteCount: size)
            }
            count.withLock { $0 += size }
            return size
        }
    }

    private struct ShortSource: ByteSource {
        let bytes: Data
        var length: UInt64 { UInt64(bytes.count) }
        func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
            guard offset < length else { return 0 }
            let count = min(3, buffer.count, bytes.count - Int(offset))
            for i in 0..<count { buffer[i] = bytes[Int(offset) + i] }
            return count
        }
    }
}
