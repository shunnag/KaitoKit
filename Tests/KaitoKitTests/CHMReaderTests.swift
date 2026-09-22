import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

/// HTML Help（CHM / ITSF）。fixture は Tests/Fixtures/chm（自作 writer + CAB LZX encoder、7-Zip が同じ内容に展開）。
final class CHMReaderTests: XCTestCase {
    func testR4SectionIDBeyondIntIsRejected() throws {
        var bytes = try Self.fixture("uncompressed.chm")
        let header = try CHMHeader([UInt8](bytes.prefix(0x60)), sourceLength: UInt64(bytes.count))
        let directory = Int(header.directoryOffset)
        let base = directory + Int(CHMBytes.u32([UInt8](bytes), directory + 8))
        let chunkSize = Int(CHMBytes.u32([UInt8](bytes), directory + 0x10))
        // /x、section = 2^63（10 byte ENCINT）、offset = length = 0。
        let record: [UInt8] = [2, 0x2F, 0x78, 0x81] + Array(repeating: 0x80, count: 8) + [0, 0, 0]
        bytes.replaceSubrange((base + 20)..<(base + 20 + record.count), with: record)
        withUnsafeBytes(of: UInt32(chunkSize - 20 - record.count).littleEndian) {
            bytes.replaceSubrange((base + 4)..<(base + 8), with: $0)
        }
        bytes[base + chunkSize - 2] = 1; bytes[base + chunkSize - 1] = 0
        let entries = try CHMReader.directory(source: DataByteSource(bytes), header: header, limits: ReadLimits())
        XCTAssertEqual(entries.first?.section, 1 << 63)
        XCTAssertThrowsError(try ArchiveReader.open(data: bytes)) {
            guard case .malformed = $0 as? KaitoError else { return XCTFail("予期しないエラー: \($0)") }
        }
    }

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private struct Payload: Decodable { let size: UInt64; let sha256: String }
    private struct Archive: Decodable { let size: UInt64; let sha256: String; let files: [String] }
    private static func manifest() throws -> (payload: [String: Payload], archives: [String: Archive]) {
        let data = try Data(contentsOf: root.appendingPathComponent("Fixtures/chm/manifest.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var payload: [String: Payload] = [:], archives: [String: Archive] = [:]
        for (key, value) in object {
            let encoded = try JSONSerialization.data(withJSONObject: value)
            if key == "payload" { payload = try JSONDecoder().decode([String: Payload].self, from: encoded) }
            else { archives[key] = try JSONDecoder().decode(Archive.self, from: encoded) }
        }
        return (payload, archives)
    }
    private static func fixture(_ name: String) throws -> Data {
        let base64 = try String(contentsOf: root.appendingPathComponent("Fixtures/chm/\(name).gz.b64"), encoding: .utf8)
        let gzip = try ArchiveReader.open(data: XCTUnwrap(Data(base64Encoded: base64, options: .ignoreUnknownCharacters)))
        return try gzip.read(gzip.entries[0])
    }
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func testFixturesMatchSevenZipAndTheManifest() throws {
        let manifest = try Self.manifest()
        for name in ["basic.chm", "reset1-w17.chm", "mixed-blocks.chm", "e8.chm", "multi-chunk.chm", "uncompressed.chm"] {
            let bytes = try Self.fixture(name)
            XCTAssertEqual(sha(bytes), manifest.archives[name]?.sha256, name)
            XCTAssertEqual(try FormatDetector.detect(data: bytes), .chm, name)
            let reader = try ArchiveReader.open(data: bytes)
            XCTAssertEqual(reader.format, .chm, name)
            let files = try XCTUnwrap(manifest.archives[name]).files          // "/index.htm" の形
            let published = Set(files.map { String($0.dropFirst()) })
            XCTAssertEqual(Set(reader.entries.filter { $0.kind == .file }.map(\.name)), published, name)
            // directory は path から導かれる（"/topics/sub/deep.htm" → topics、topics/sub）。
            var directories = Set<String>()
            for file in files {
                let parts = file.dropFirst().split(separator: "/").map(String.init)
                for depth in 1..<max(parts.count, 1) { directories.insert(parts[..<depth].joined(separator: "/")) }
            }
            XCTAssertEqual(Set(reader.entries.filter { $0.kind == .directory }.map(\.name)), directories, name)
            // 後ろの file から読んでも（group の切り替え）、小さな buffer でも同じ内容。
            for entry in reader.entries.filter({ $0.kind == .file }).reversed() {
                let want = try XCTUnwrap(manifest.payload["/" + entry.name], entry.name)
                XCTAssertEqual(entry.uncompressedSize, want.size, "\(name): \(entry.name)")
                XCTAssertEqual(sha(try reader.read(entry)), want.sha256, "\(name): \(entry.name)")
                let expectedMethod = entry.name.hasPrefix("#") || name == "uncompressed.chm" ? "stored" : "LZX"
                XCTAssertEqual(entry.methodDescription, expectedMethod, "\(name): \(entry.name)")
            }
            if let logo = reader.entries.first(where: { $0.name == "images/logo.bin" }) {
                let stream = try reader.stream(logo)
                var result = Data(), buffer = [UInt8](repeating: 0, count: 1_000)
                while true {
                    let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
                    if count == 0 { break }
                    result.append(contentsOf: buffer.prefix(count))
                }
                XCTAssertEqual(sha(result), manifest.payload["/images/logo.bin"]?.sha256, name)
            }
            let reopened = try reader.reopen()
            XCTAssertEqual(reopened.entries, reader.entries, name)
        }
        let short = try ArchiveReader.open(source: ShortSource(try Self.fixture("basic.chm")))
        let logo = try XCTUnwrap(short.entries.first { $0.name == "images/logo.bin" })
        XCTAssertEqual(sha(try short.read(logo)), manifest.payload["/images/logo.bin"]?.sha256)
    }

    func testDamagedFilesAreRejected() throws {
        let original = try Self.fixture("basic.chm")
        // version 4 / 署名違いは unsupportedFormat（検出も外れる）。
        var version = original; version[4] = 4
        XCTAssertThrowsError(try ArchiveReader.open(data: version)) { XCTAssertEqual($0 as? KaitoError, .unsupportedFormat) }
        // directory の署名。
        var itsp = original; itsp[0x78] = UInt8(ascii: "X")
        assertMalformed(itsp, "ITSP signature")
        var pmgl = original; pmgl[0x78 + 0x54] = UInt8(ascii: "X")
        assertMalformed(pmgl, "PMGL signature")
        // content を途中で切る: 圧縮 section の file は truncated、section 0 の file は読める範囲なら通る。
        let header = try CHMHeader([UInt8](original.prefix(0x60)), sourceLength: UInt64(original.count))
        let directory = try CHMReader.directory(source: DataByteSource(data: original), header: header, limits: ReadLimits())
        let content = try XCTUnwrap(directory.first { $0.name == "::DataSpace/Storage/MSCompressed/Content" })
        let cut = original.prefix(Int(header.contentOffset + content.offset + content.length / 2))
        XCTAssertThrowsError(try ArchiveReader.open(data: cut)) { XCTAssertEqual($0 as? KaitoError, .truncated) }
        // ControlData の識別子を変えると圧縮 section の file は unsupportedMethod、section 0 の file は読める。
        let control = try XCTUnwrap(directory.first { $0.name == "::DataSpace/Storage/MSCompressed/ControlData" })
        var other = original
        other[Int(header.contentOffset + control.offset) + 4] = UInt8(ascii: "Q")
        let reader = try ArchiveReader.open(data: other)
        let index = try XCTUnwrap(reader.entries.first { $0.name == "index.htm" })
        XCTAssertEqual(index.methodDescription, "unknown")
        XCTAssertThrowsError(try reader.read(index)) {
            guard case .unsupportedMethod = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        let system = try XCTUnwrap(reader.entries.first { $0.name == "#SYSTEM" })
        XCTAssertEqual(try reader.read(system).count, 68)
        // reset table の entry 数を減らすと section の大きさに足りず malformed。
        let table = try XCTUnwrap(directory.first { $0.name.hasSuffix("/ResetTable") })
        var shortTable = original
        shortTable[Int(header.contentOffset + table.offset) + 4] = 1
        assertMalformed(shortTable, "reset table")
        // 上限: entry 数、辞書（window 64 KiB）、metadata。
        for (limits, label) in [(ReadLimits(maxEntryCount: 3), "entry count"), (ReadLimits(maxDictionarySize: 32_768), "dictionary"),
                                (ReadLimits(maxMetadataSize: 1_024), "metadata")] {
            XCTAssertThrowsError(try ArchiveReader.open(data: original, options: ReaderOptions(limits: limits)), label) {
                guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("\(label): \($0)") }
            }
        }
    }

    func testEncodedIntegers() throws {
        var index = 0
        XCTAssertEqual(try CHMBytes.encint([0xEA, 0x15], &index, end: 2), 0x3515)
        XCTAssertEqual(index, 2)
        index = 0
        XCTAssertEqual(try CHMBytes.encint([0x7F], &index, end: 1), 0x7F)
        index = 0
        XCTAssertThrowsError(try CHMBytes.encint([0x80, 0x80], &index, end: 2))
    }

    private func assertMalformed(_ bytes: Data, _ label: String) {
        XCTAssertThrowsError(try ArchiveReader.open(data: bytes), label) {
            guard case .malformed = $0 as? KaitoError else { return XCTFail("\(label): unexpected error \($0)") }
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
