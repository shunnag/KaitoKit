import Compression
import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest
import zlib

final class DMGDecmpfsTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private struct Payload: Decodable { let size: UInt64; let sha256: String; let decmpfsType: UInt32; let sevenZipVerified: Bool }
    private struct Image: Decodable { let size: UInt64; let sha256: String }
    private struct Manifest: Decodable { let payload: [String: Payload]; let images: [String: Image] }

    private func fixture() throws -> (Data, Manifest) {
        let directory = Self.root.appendingPathComponent("Fixtures/dmg")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest-decmpfs.json")))
        let base64 = try String(contentsOf: directory.appendingPathComponent("hfs-decmpfs.dmg.gz.b64"), encoding: .utf8)
        let gzip = try ArchiveReader.open(data: XCTUnwrap(Data(base64Encoded: base64, options: .ignoreUnknownCharacters)))
        return (try gzip.read(gzip.entries[0]), manifest)
    }

    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func testFixtureContentsAndStreams() throws {
        let (image, manifest) = try fixture()
        XCTAssertEqual(UInt64(image.count), manifest.images["hfs-decmpfs.dmg"]?.size)
        XCTAssertEqual(sha(image), manifest.images["hfs-decmpfs.dmg"]?.sha256)
        let original = try ArchiveReader.open(data: image)
        XCTAssertEqual(Set(original.entries.map(\.name)), Set(manifest.payload.keys))
        XCTAssertEqual(Set(manifest.payload.values.map(\.decmpfsType)), [1, 3, 4, 5, 7, 8, 9, 10, 11, 12, 13])
        let reopened = try original.reopen()
        XCTAssertEqual(original.entries, reopened.entries)
        for reader in [original, reopened] {
            for entry in reader.entries {
                let want = try XCTUnwrap(manifest.payload[entry.name])
                XCTAssertEqual(entry.uncompressedSize, want.size, entry.name)
                XCTAssertEqual(entry.formatSpecific["hfsCompressed"], "true", entry.name)
                XCTAssertEqual(entry.formatSpecific["decmpfsType"], String(want.decmpfsType), entry.name)
                XCTAssertEqual(want.sevenZipVerified, [3, 4, 7, 8, 9].contains(want.decmpfsType), entry.name)
                XCTAssertNotNil(entry.compressedSize, entry.name)
                let info = try header(want.decmpfsType, want.size)
                XCTAssertEqual(entry.methodDescription, info.methodDescription, entry.name)
                if [5, 13].contains(want.decmpfsType) {
                    XCTAssertThrowsError(try reader.read(entry), entry.name) {
                        XCTAssertEqual($0 as? KaitoError, .unsupportedMethod("HFS+ decmpfs (type \(want.decmpfsType))"))
                    }
                } else {
                    XCTAssertEqual(sha(try reader.read(entry)), want.sha256, entry.name)
                }
            }
            // 逆順でも前の entry の chunk / decoder 状態を使わない。
            for entry in reader.entries.reversed() {
                let want = try XCTUnwrap(manifest.payload[entry.name])
                if [5, 13].contains(want.decmpfsType) {
                    XCTAssertThrowsError(try reader.stream(entry))
                    continue
                }
                let stream = try reader.stream(entry)
                var data = Data(), buffer = [UInt8](repeating: 0, count: 137)
                while true {
                    let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
                    if count == 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                XCTAssertEqual(stream.remaining, 0, entry.name)
                XCTAssertEqual(UInt64(data.count), want.size, entry.name)
                XCTAssertEqual(sha(data), want.sha256, entry.name)
            }
        }
    }

    func testFixtureEntrySizeLimitAtOpen() throws {
        let (image, _) = try fixture()
        XCTAssertThrowsError(try ArchiveReader.open(data: image, options: ReaderOptions(limits: ReadLimits(maxEntrySize: 299_999)))) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("予期しないエラー: \($0)") }
        }
    }

    func testInlineStoredAndRawMarkers() throws {
        let raw = Array("decmpfs の自作 vector\n".utf8)
        for type: UInt32 in [1, 3, 7, 9, 11] {
            let packed = type == 1 ? raw : [type == 7 ? 0x06 : type == 9 ? 0xCC : 0xFF] + raw
            let decoder = try DecmpfsDecompressor(header: header(type, UInt64(raw.count)), inlinePayload: packed, limits: ReadLimits())
            XCTAssertEqual(try drain(decoder), raw, "type \(type)")
        }
        let empty = try DecmpfsDecompressor(header: header(1, 0), limits: ReadLimits())
        XCTAssertTrue(empty.isFinished)
        XCTAssertEqual(try drain(empty), [])
        assertMalformed { _ = try DecmpfsDecompressor(header: self.header(9, 1), inlinePayload: [], limits: ReadLimits()) }
        assertMalformed {
            _ = try self.drain(DecmpfsDecompressor(header: self.header(3, 2), inlinePayload: [0xFF, 1], limits: ReadLimits()))
        }
        for type: UInt32 in [5, 13, 14, 99] {
            XCTAssertThrowsError(try DecmpfsDecompressor(header: header(type, 0), limits: ReadLimits())) {
                XCTAssertEqual($0 as? KaitoError, .unsupportedMethod("HFS+ decmpfs (type \(type))"))
            }
        }
    }

    func testInlineType9RequiresStoredMarker() throws {
        let raw: [UInt8] = [0xCC, 1, 2]
        XCTAssertEqual(try drain(makeDecoder(1, rawSize: raw.count, packed: raw)), raw)
        XCTAssertEqual(try drain(makeDecoder(9, rawSize: raw.count, packed: [0xCC] + raw)), raw)
        let empty = try makeDecoder(9, rawSize: 0, packed: [0xCC])
        XCTAssertTrue(empty.isFinished)
        XCTAssertEqual(try drain(empty), [])
        for packed in [raw, [0xFF] + raw, [0xCC] + raw.dropLast(), [0xCC] + raw + [0]] {
            assertMalformed { _ = try self.drain(self.makeDecoder(9, rawSize: raw.count, packed: packed)) }
        }
        for packed: [UInt8] in [[], [0xFF], [0xCC, 0]] {
            assertMalformed { _ = try self.makeDecoder(9, rawSize: 0, packed: packed) }
        }
    }

    func testInlineZlibWithAndWithoutAdlerRequiresFinalBlock() throws {
        let raw = Array(repeating: Array("decmpfs zlib\n".utf8), count: 80).flatMap { $0 }
        let packed = try zlibBytes(raw)
        for value in [packed, Array(packed.dropLast(4))] {
            let decoder = try DecmpfsDecompressor(header: header(3, UInt64(raw.count)), inlinePayload: value, limits: ReadLimits())
            XCTAssertEqual(try drain(decoder), raw)
        }
        for value in [Array(packed.dropLast(5)), packed + [0], [0x78, 0x20] + packed.dropFirst(2)] {
            assertMalformed {
                _ = try self.drain(DecmpfsDecompressor(header: self.header(3, UInt64(raw.count)), inlinePayload: value, limits: ReadLimits()))
            }
        }
        // stored Deflate の出力は揃っていても BFINAL = 0 なら未完了。
        let noFinal: [UInt8] = [0x78, 0x01, 0x00, 1, 0, 0xFE, 0xFF, 42]
        assertMalformed {
            _ = try self.drain(DecmpfsDecompressor(header: self.header(3, 1), inlinePayload: noFinal, limits: ReadLimits()))
        }
    }

    func testLZVNPaddingAndCorruption() throws {
        let raw = Array(repeating: Array("LZVN envelope / KaitoKit\n".utf8), count: 90).flatMap { $0 }
        let encoded = try lzfseBytes(raw)
        XCTAssertEqual(Array(encoded.prefix(4)), Array("bvxn".utf8))
        XCTAssertEqual(Array(encoded.suffix(4)), Array("bvx$".utf8))
        let payload = Array(encoded.dropFirst(12).dropLast(4))
        for suffix in [[UInt8](repeating: 0, count: 200), [UInt8](repeating: 0x44, count: 20)] {
            for type: UInt32 in [7, 8] {
                let decoder = try makeDecoder(type, rawSize: raw.count, packed: payload + suffix)
                XCTAssertEqual(try drain(decoder), raw, "type \(type)")
            }
        }
        let corrupt = try makeDecoder(7, rawSize: raw.count, packed: Array(payload.prefix(2)))
        assertMalformed { _ = try self.drain(corrupt) }
        XCTAssertFalse(corrupt.isFinished)
        assertMalformed { _ = try self.drain(corrupt) }
    }

    func testLZFSEInlineAndResourceChunks() throws {
        let raw = Array(repeating: Array("LZFSE vector\n".utf8), count: 6_000).flatMap { $0 }
        let small = Array(raw.prefix(840))
        XCTAssertEqual(try drain(makeDecoder(11, rawSize: small.count, packed: lzfseBytes(small))), small)
        let chunks = [try lzfseBytes(Array(raw.prefix(65_536))), try lzfseBytes(Array(raw.dropFirst(65_536)))]
        let decoder = try DecmpfsDecompressor(header: header(12, UInt64(raw.count)), resourceFork: resource(offsetFork(chunks)), limits: ReadLimits())
        XCTAssertEqual(try drain(decoder), raw)
        XCTAssertEqual(try drain(makeDecoder(12, rawSize: small.count, packed: [0xFF] + small)), small)
    }

    func testZlibResourceMixedChunksAndEnvelopeOffset() throws {
        let raw = (0..<(2 * 65_536 + 97)).map { UInt8($0 % 113) }
        let chunks = [try zlibBytes(Array(raw.prefix(65_536))),
                      Array(try zlibBytes(Array(raw[65_536..<(2 * 65_536)])).dropLast(4)),
                      [0xFF] + raw.suffix(97)]
        // dataOffset は 0x100 固定ではない。
        let bytes = zlibFork(chunks, dataOffset: 64)
        let decoder = try DecmpfsDecompressor(header: header(4, UInt64(raw.count)), resourceFork: resource(bytes), limits: ReadLimits())
        XCTAssertEqual(try drain(decoder), raw)
    }

    func testMalformedResourceTables() throws {
        var badOffset = zlibFork([[0xFF, 1]])
        putLE(UInt64(badOffset.count), &badOffset, 64 + 8)
        assertMalformed {
            _ = try self.drain(DecmpfsDecompressor(header: self.header(4, 1), resourceFork: self.resource(badOffset), limits: ReadLimits()))
        }
        var inTable = zlibFork([[0xFF, 1]])
        putLE(0, &inTable, 64 + 8)
        assertMalformed {
            _ = try self.drain(DecmpfsDecompressor(header: self.header(4, 1), resourceFork: self.resource(inTable), limits: ReadLimits()))
        }
        let twoChunks = zlibFork([[0xFF, 1], [0xFF, 2]])
        assertMalformed {
            _ = try DecmpfsDecompressor(header: self.header(4, 1), resourceFork: self.resource(twoChunks), limits: ReadLimits())
        }
        let backwards: [UInt8] = [8, 0, 0, 0, 7, 0, 0, 0]
        assertMalformed {
            _ = try self.drain(DecmpfsDecompressor(header: self.header(8, 1), resourceFork: self.resource(backwards), limits: ReadLimits()))
        }
        for table: [UInt8] in [[4, 0, 0, 0], [9, 0, 0, 0], [0xFC, 0xFF, 0xFF, 0xFF]] {
            assertMalformed {
                _ = try DecmpfsDecompressor(header: self.header(8, 1), resourceFork: self.resource(table), limits: ReadLimits())
            }
        }
        let empty = try DecmpfsDecompressor(header: header(8, 0), resourceFork: resource([4, 0, 0, 0]), limits: ReadLimits())
        XCTAssertTrue(empty.isFinished)
        assertMalformed {
            _ = try DecmpfsDecompressor(header: self.header(8, 0), resourceFork: self.resource(self.offsetFork([[0x06]])), limits: ReadLimits())
        }
    }

    func testChunksAreReadOnDemandAndAllocationsAreBounded() throws {
        let raw = [UInt8](repeating: 42, count: 65_536) + [UInt8](repeating: 19, count: 127)
        let bytes = offsetFork([[0xCC] + raw.prefix(65_536), [0xCC] + raw.suffix(127)])
        var reads: [(UInt64, Int)] = []
        let fork = DecmpfsDecompressor.ResourceFork(length: UInt64(bytes.count)) { offset, count in
            reads.append((offset, count))
            return Array(bytes[Int(offset)..<(Int(offset) + count)])
        }
        let decoder = try DecmpfsDecompressor(header: header(10, UInt64(raw.count)), resourceFork: fork, limits: ReadLimits())
        XCTAssertEqual(reads.count, 1)
        var first = [UInt8](repeating: 0, count: 13)
        XCTAssertEqual(try first.withUnsafeMutableBytes { try decoder.read(into: $0) }, 13)
        XCTAssertEqual(reads.map(\.0), [0, 0, 12])
        XCTAssertFalse(decoder.isFinished)
        XCTAssertEqual(first + (try drain(decoder)), raw)
        XCTAssertTrue(decoder.isFinished)
        XCTAssertEqual(try first.withUnsafeMutableBytes { try decoder.read(into: $0) }, 0)

        let oversized = DecmpfsDecompressor.ResourceFork(length: 80_000) { offset, count in
            XCTAssertEqual(offset, 0)
            XCTAssertLessThanOrEqual(count, 8)
            var table = [UInt8](repeating: 0, count: 8)
            self.putLE(8, &table, 0); self.putLE(80_000, &table, 4)
            return Array(table.prefix(count))
        }
        assertMalformed {
            _ = try self.drain(DecmpfsDecompressor(header: self.header(8, 1), resourceFork: oversized, limits: ReadLimits()))
        }
        XCTAssertThrowsError(try DecmpfsDecompressor(header: header(7, 300_000), limits: ReadLimits(maxEntrySize: 299_999))) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("予期しないエラー: \($0)") }
        }
        let limited = try DecmpfsDecompressor(header: header(3, 1024), inlinePayload: zlibBytes([UInt8](repeating: 0, count: 1024)),
                                             limits: ReadLimits(maxInMemorySize: 512))
        XCTAssertThrowsError(try drain(limited)) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("予期しないエラー: \($0)") }
        }
    }

    private func assertMalformed(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            guard case .malformed = $0 as? KaitoError else { return XCTFail("予期しないエラー: \($0)", file: file, line: line) }
        }
    }

    private func header(_ type: UInt32, _ size: UInt64) throws -> DecmpfsHeader {
        var bytes = Array("fpmc".utf8) + [UInt8](repeating: 0, count: 12)
        putLE(UInt64(type), &bytes, 4); putLE(size, &bytes, 8, width: 8)
        return try DecmpfsHeader(attribute: bytes)
    }

    private func putLE(_ value: UInt64, _ bytes: inout [UInt8], _ offset: Int, width: Int = 4) {
        for i in 0..<width { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
    }

    private func putBE(_ value: UInt64, _ bytes: inout [UInt8], _ offset: Int, width: Int = 4) {
        for i in 0..<width { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> ((width - 1 - i) * 8)) }
    }

    private func resource(_ bytes: [UInt8]) -> DecmpfsDecompressor.ResourceFork {
        DecmpfsDecompressor.ResourceFork(length: UInt64(bytes.count)) { offset, count in
            Array(bytes[Int(offset)..<(Int(offset) + count)])
        }
    }

    private func makeDecoder(_ type: UInt32, rawSize: Int, packed: [UInt8]) throws -> DecmpfsDecompressor {
        let info = try header(type, UInt64(rawSize))
        return try DecmpfsDecompressor(header: info, inlinePayload: info.usesResourceFork ? [] : packed,
                                      resourceFork: info.usesResourceFork ? resource(offsetFork([packed])) : nil, limits: ReadLimits())
    }

    private func drain(_ decoder: any Decompressor) throws -> [UInt8] {
        var result: [UInt8] = [], buffer = [UInt8](repeating: 0, count: 131)
        while true {
            let count = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        XCTAssertTrue(decoder.isFinished)
        return result
    }

    private func offsetFork(_ chunks: [[UInt8]]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: (chunks.count + 1) * 4)
        for (index, chunk) in chunks.enumerated() {
            putLE(UInt64(bytes.count), &bytes, index * 4)
            bytes += chunk
        }
        putLE(UInt64(bytes.count), &bytes, chunks.count * 4)
        return bytes
    }

    private func zlibFork(_ chunks: [[UInt8]], dataOffset: Int = 64) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: dataOffset + 8 + chunks.count * 8)
        putBE(UInt64(dataOffset), &bytes, 0)
        putLE(UInt64(chunks.count), &bytes, dataOffset + 4)
        for (index, chunk) in chunks.enumerated() {
            putLE(UInt64(bytes.count - dataOffset - 4), &bytes, dataOffset + 8 + index * 8)
            putLE(UInt64(chunk.count), &bytes, dataOffset + 12 + index * 8)
            bytes += chunk
        }
        putBE(UInt64(bytes.count), &bytes, 4)
        putBE(UInt64(bytes.count - dataOffset), &bytes, 8)
        putBE(UInt64(bytes.count - dataOffset - 4), &bytes, dataOffset)
        return bytes
    }

    private func zlibBytes(_ raw: [UInt8]) throws -> [UInt8] {
        var length = compressBound(uLong(raw.count))
        var result = [UInt8](repeating: 0, count: Int(length))
        let status = raw.withUnsafeBufferPointer { src in
            result.withUnsafeMutableBufferPointer { dst in compress2(dst.baseAddress!, &length, src.baseAddress!, uLong(raw.count), 6) }
        }
        XCTAssertEqual(status, Z_OK)
        return Array(result.prefix(Int(length)))
    }

    private func lzfseBytes(_ raw: [UInt8]) throws -> [UInt8] {
        var result = [UInt8](repeating: 0, count: raw.count + 4096)
        let count = raw.withUnsafeBufferPointer { src in
            result.withUnsafeMutableBufferPointer { dst in
                compression_encode_buffer(dst.baseAddress!, dst.count, src.baseAddress!, src.count, nil, COMPRESSION_LZFSE)
            }
        }
        XCTAssertGreaterThan(count, 0)
        return Array(result.prefix(count))
    }
}
