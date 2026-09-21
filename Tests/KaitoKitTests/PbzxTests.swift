import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

/// pbzx（Apple flat package の Payload / OTA の chunked xz container）。layout は macOS 27.2 の
/// pkgbuild 出力の黒箱計測。fixture は Tests/Fixtures/pbzx（pkgbuild 製 + 同じ cpio を包み直した合成）。
final class PbzxTests: XCTestCase {
    private struct Manifest: Decodable {
        struct Chunk: Decodable { let kind: String; let unpacked: Int; let stored: Int }
        struct Fixture: Decodable {
            let file: String
            let size: Int
            let sha256: String
            let chunkSize: Int
            let chunks: [Chunk]
            let cpioSize: Int?
            let cpioSHA256: String?
            let dataSize: Int?
            let dataSHA256: String?
        }
        struct File: Decodable { let size: Int; let sha256: String }
        let files: [String: File]
        let fixtures: [Fixture]
    }

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/pbzx")
    }

    private func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
    }

    private func fixture(_ file: String) throws -> Data {
        try XCTUnwrap(Data(base64Encoded: Data(contentsOf: root.appendingPathComponent(file)), options: .ignoreUnknownCharacters))
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func decode(_ bytes: Data, chunk: Int = 8_191, limits: ReadLimits = ReadLimits()) throws -> Data {
        let decoder = try PbzxDecompressor(source: DataByteSource(bytes), limits: limits)
        var result = Data(), buffer = [UInt8](repeating: 0, count: chunk)
        XCTAssertEqual(try decoder.read(into: UnsafeMutableRawBufferPointer(start: nil, count: 0)), 0)
        while true {
            let count = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
            if count == 0 { break }
            result.append(contentsOf: buffer[..<count])
        }
        XCTAssertTrue(decoder.isFinished)
        return result
    }

    private func bigEndian(_ value: UInt64) -> [UInt8] { (0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) } }

    func testFixturesDecodeChunkByChunkAndDeclareTheirSizes() throws {
        for item in try manifest().fixtures {
            let bytes = try fixture(item.file)
            XCTAssertEqual(bytes.count, item.size, item.file)
            XCTAssertEqual(sha(bytes), item.sha256, item.file)
            let expectedSize = item.cpioSize ?? item.dataSize
            let expectedSHA = item.cpioSHA256 ?? item.dataSHA256
            XCTAssertEqual(try PbzxDecompressor.contentSize(source: DataByteSource(bytes), limits: ReadLimits()), UInt64(expectedSize!), item.file)
            for chunk in [1_000, 65_537] {
                let output = try decode(bytes, chunk: chunk)
                XCTAssertEqual(output.count, expectedSize, "\(item.file) chunk \(chunk)")
                XCTAssertEqual(sha(output), expectedSHA, "\(item.file) chunk \(chunk)")
            }
        }
    }

    func testPackagePayloadIsExposedAsCpioAndPlainStreamAsSingleFile() throws {
        let manifest = try manifest()
        for file in ["payload-xz.pbzx.b64", "payload-raw-xz.pbzx.b64"] {
            let bytes = try fixture(file)
            XCTAssertEqual(try FormatDetector.detect(data: bytes), .pbzx, file)
            let reader = try ArchiveReader.open(data: bytes)
            // 展開結果が cpio なら pkg の Payload として中身を直接列挙する。
            XCTAssertEqual(reader.format, .cpio, file)
            let names = Set(reader.entries.map(\.name))
            for (name, info) in manifest.files {
                let entry = try XCTUnwrap(reader.entries.first { $0.name == name || $0.name == "./" + name }, "\(file) \(name)")
                XCTAssertEqual(entry.uncompressedSize, UInt64(info.size), name)
                XCTAssertEqual(sha(try reader.read(entry)), info.sha256, name)
            }
            XCTAssertTrue(names.contains { $0.hasSuffix("kaito-hello") }, file)
            let reopened = try reader.reopen()
            XCTAssertEqual(reopened.entries.map(\.name), reader.entries.map(\.name), file)
            for entry in reopened.entries where entry.kind == .file {
                XCTAssertEqual(try reopened.read(entry), try reader.read(entry), "\(file) \(entry.name)")
            }
        }
        // cpio でない中身は単一 stream として公開する。
        let text = try fixture("text.pbzx.b64")
        let single = try ArchiveReader.open(data: text)
        XCTAssertEqual(single.format, .pbzx)
        XCTAssertEqual(single.entries.count, 1)
        XCTAssertEqual(single.entries[0].name, "data")
        XCTAssertEqual(single.entries[0].methodDescription, "XZ (pbzx)")
        XCTAssertEqual(single.entries[0].uncompressedSize, 18_000)
        XCTAssertEqual(sha(try single.read(single.entries[0])), manifest.files["usr/local/share/kaito/text.txt"]?.sha256)
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let url = temporary.appendingPathComponent("Payload")
        try text.write(to: url)
        let named = try ArchiveReader.open(url: url)
        XCTAssertEqual(named.entries[0].name, "Payload")
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(try named.reopen().read(named.entries[0]).count, 18_000)
    }

    func testStructuralCorruptionAndLimitsAreRejected() throws {
        let text = try fixture("text.pbzx.b64")
        var badMagic = text
        badMagic[0] = 0x70; badMagic[1] = 0x62; badMagic[2] = 0x7A; badMagic[3] = 0x79
        XCTAssertThrowsError(try FormatDetector.detect(data: badMagic))
        XCTAssertThrowsError(try PbzxDecompressor(source: DataByteSource(badMagic), limits: ReadLimits()))

        // chunk size 0 / chunk が上限を超える / 格納長が file を超える / raw chunk の長さ不一致 / 切り詰め。
        var zeroChunk = text
        zeroChunk.replaceSubrange(4..<12, with: bigEndian(0))
        XCTAssertThrowsError(try PbzxDecompressor(source: DataByteSource(zeroChunk), limits: ReadLimits())) {
            guard case .malformed = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        var smallChunk = text
        smallChunk.replaceSubrange(4..<12, with: bigEndian(1_024))
        XCTAssertThrowsError(try decode(smallChunk)) {
            guard case .malformed = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        var hugeStored = text
        hugeStored.replaceSubrange(20..<28, with: bigEndian(1 << 40))
        XCTAssertThrowsError(try decode(hugeStored)) { XCTAssertEqual($0 as? KaitoError, .truncated) }
        for cutoff in [3, 11, 27, 40, text.count / 2, text.count - 1] {
            XCTAssertThrowsError(try decode(Data(text.prefix(cutoff))), "cutoff \(cutoff)")
        }
        // 展開後サイズが宣言と違う xz chunk。
        var wrongUnpacked = text
        wrongUnpacked.replaceSubrange(12..<20, with: bigEndian(9_000 + 1))
        XCTAssertThrowsError(try decode(wrongUnpacked)) {
            guard case .malformed = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        // raw chunk は格納長 == 展開後サイズが必須。
        let raw = Data([0x70, 0x62, 0x7A, 0x78]) + Data(bigEndian(1 << 20)) + Data(bigEndian(4)) + Data(bigEndian(3)) + Data("abc".utf8)
        XCTAssertThrowsError(try decode(raw)) {
            guard case .malformed = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        let good = Data([0x70, 0x62, 0x7A, 0x78]) + Data(bigEndian(1 << 20)) + Data(bigEndian(3)) + Data(bigEndian(3)) + Data("abc".utf8)
        XCTAssertEqual(try decode(good), Data("abc".utf8))
        // 空の chunk（U = L = 0）は許し、本文を持つ空 chunk は拒否する。
        let emptyChunk = Data([0x70, 0x62, 0x7A, 0x78]) + Data(bigEndian(1 << 20)) + Data(bigEndian(0)) + Data(bigEndian(0)) + good.dropFirst(12)
        XCTAssertEqual(try decode(emptyChunk), Data("abc".utf8))
        // header だけ（chunk なし）は空の出力。
        XCTAssertEqual(try decode(Data([0x70, 0x62, 0x7A, 0x78]) + Data(bigEndian(1 << 20))), Data())

        // 上限: entry サイズと chunk 数。
        XCTAssertThrowsError(try PbzxDecompressor.contentSize(source: DataByteSource(text), limits: ReadLimits(maxEntrySize: 17_999))) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertThrowsError(try PbzxDecompressor.contentSize(source: DataByteSource(text), limits: ReadLimits(maxMetadataRecordCount: 1))) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertThrowsError(try ArchiveReader.open(data: text, options: ReaderOptions(limits: ReadLimits(maxEntrySize: 17_999)))) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
    }
}
