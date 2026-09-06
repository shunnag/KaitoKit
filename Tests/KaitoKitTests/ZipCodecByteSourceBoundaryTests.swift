import Foundation
import KaitoKit
import XCTest

final class ZipCodecByteSourceBoundaryTests: XCTestCase {
    func testDeflate64KeepsShortReadsInsideCompressedRange() throws {
        // "abc" を格納した最終 stored block。
        let compressed = Data([0x01, 0x03, 0x00, 0xFC, 0xFF, 0x61, 0x62, 0x63])
        let source = try RangeCheckingShortByteSource(
            prefix: Data(repeating: 0xA5, count: 7),
            compressed: compressed,
            suffix: Data(repeating: 0x5A, count: 41),
            maximumReadSize: 2
        )
        let decoder = try Deflate64Decompressor(
            source: source,
            offset: source.compressedOffset,
            compressedSize: UInt64(compressed.count),
            expectedSize: 3
        )

        XCTAssertEqual(try drain(decoder, bufferSize: 1), Data("abc".utf8))
        XCTAssertGreaterThan(source.readCount, 1)
    }

    func testDeflate64RejectsWholeBytesAfterFinalBlock() throws {
        // 完全な最終 stored block の後ろに data stream 外の一バイトを付ける。
        var compressed = Data([0x01, 0x03, 0x00, 0xFC, 0xFF, 0x61, 0x62, 0x63])
        compressed.append(0xA5)
        let decoder = try Deflate64Decompressor(
            source: DataByteSource(compressed),
            offset: 0,
            compressedSize: UInt64(compressed.count),
            expectedSize: 3
        )

        XCTAssertThrowsError(try drain(decoder, bufferSize: 1)) { error in
            guard case let .malformed(reason) = error as? KaitoError else {
                return XCTFail("expected malformed, got \(error)")
            }
            XCTAssertTrue(reason.contains("trailing bytes"))
        }
    }

    func testLZMAKeepsBufferedShortReadsInsideCompressedRange() throws {
        // "abcabcabcabcabcabc" の EOS marker 無し raw LZMA1。
        let compressed = try decodeHex("00309888aa02a643ebffffb580")
        let source = try RangeCheckingShortByteSource(
            prefix: Data(repeating: 0xC3, count: 11),
            compressed: compressed,
            suffix: Data(repeating: 0x3C, count: 257),
            maximumReadSize: 2
        )
        let decoder = try makeLZMADecoder(
            source: source,
            offset: source.compressedOffset,
            compressedSize: UInt64(compressed.count)
        )

        XCTAssertEqual(
            try drain(decoder, bufferSize: 1),
            Data("abcabcabcabcabcabc".utf8)
        )
        XCTAssertGreaterThan(source.readCount, 1)
    }

    func testSevenZipAESLZMACombinationDecodesAfterHeaderReads() throws {
        try ZipTestSupport.requireExecutable(
            ZipTestSupport.sevenZipPath,
            reason: "7zz is unavailable; AES + LZMA integration fixture skipped"
        )
        let temporary = try ZipTestSupport.temporaryDirectory(label: "aes-lzma")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sourceDirectory = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: false
        )
        let payload = Data(repeating: 0x4B, count: 70_001)
            + Data("AES LZMA 日本語\n".utf8)
        _ = try ZipTestSupport.write(
            payload,
            relativePath: "payload.bin",
            below: sourceDirectory
        )
        let archive = temporary.appendingPathComponent("aes-lzma.zip")
        try ZipTestSupport.makeSevenZip(
            sourceDirectory: sourceDirectory,
            paths: ["payload.bin"],
            archiveURL: archive,
            method: "LZMA",
            password: "fixed-password"
        )

        let reader = try ArchiveReader.open(
            url: archive,
            options: ReaderOptions(password: "fixed-password")
        )
        let entry = try XCTUnwrap(reader.entries.first { $0.name == "payload.bin" })
        XCTAssertEqual(entry.methodDescription, "lzma")
        XCTAssertEqual(entry.formatSpecific["encryption"], "AES-256")
        XCTAssertEqual(try reader.read(entry), payload)
        XCTAssertEqual(
            try ZipTestSupport.sevenZipData(
                archiveURL: archive,
                entryName: "payload.bin",
                password: "fixed-password"
            ),
            payload
        )
    }

    private func makeLZMADecoder(
        source: any ByteSource,
        offset: UInt64,
        compressedSize: UInt64
    ) throws -> LZMADecoder {
        try LZMADecoder(
            source: source,
            offset: offset,
            compressedSize: compressedSize,
            properties: [0x5D, 0x00, 0x00, 0x01, 0x00],
            expectedSize: 18,
            dictionarySizeLimit: 1 << 20
        )
    }

    private func drain(_ decoder: any Decompressor, bufferSize: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while !decoder.isFinished {
            let count = try buffer.withUnsafeMutableBytes { storage in
                try decoder.read(into: storage)
            }
            guard count > 0 || decoder.isFinished else {
                throw KaitoError.malformed("codec test decoder made no progress")
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    private func decodeHex(_ text: String) throws -> Data {
        guard text.utf8.count.isMultiple(of: 2) else {
            throw KaitoError.malformed("odd test hex length")
        }
        var result = Data()
        var index = text.startIndex
        while index < text.endIndex {
            guard let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex),
                  let byte = UInt8(text[index..<next], radix: 16) else {
                throw KaitoError.malformed("invalid test hex")
            }
            result.append(byte)
            index = next
        }
        return result
    }
}

private final class RangeCheckingShortByteSource: ByteSource, @unchecked Sendable {
    private let source: DataByteSource
    private let allowedRange: Range<UInt64>
    private let maximumReadSize: Int
    private let lock = NSLock()
    private var reads = 0

    let compressedOffset: UInt64
    let length: UInt64

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    init(
        prefix: Data,
        compressed: Data,
        suffix: Data,
        maximumReadSize: Int
    ) throws {
        guard maximumReadSize > 0 else {
            throw KaitoError.malformed("invalid test short-read size")
        }
        var storage = prefix
        storage.append(compressed)
        storage.append(suffix)
        self.source = DataByteSource(storage)
        self.compressedOffset = UInt64(prefix.count)
        let compressedEnd = try Checked.add(
            UInt64(prefix.count),
            UInt64(compressed.count)
        )
        self.allowedRange = UInt64(prefix.count)..<compressedEnd
        self.maximumReadSize = maximumReadSize
        self.length = UInt64(storage.count)
    }

    func read(
        into buffer: UnsafeMutableRawBufferPointer,
        at offset: UInt64
    ) throws -> Int {
        guard !buffer.isEmpty, offset < length else { return 0 }
        let requestedEnd = try Checked.add(offset, UInt64(buffer.count))
        guard offset >= allowedRange.lowerBound,
              requestedEnd <= allowedRange.upperBound else {
            throw KaitoError.malformed("codec read crossed its compressed range")
        }
        let count = min(buffer.count, maximumReadSize)
        lock.lock()
        reads += 1
        lock.unlock()
        return try source.read(
            into: UnsafeMutableRawBufferPointer(rebasing: buffer[..<count]),
            at: offset
        )
    }
}
