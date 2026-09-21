import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

/// Windows Imaging（WIM）。fixture は Tests/Fixtures/wim（自作 writer の stored / XPRESS / LZX、7-Zip の stored）。
/// 全 fixture は生成時に 7-Zip が展開して原本と一致している。実物の LZX WIM（Microsoft 製 boot.wim）は
/// 検証記録に記した開発時の照合で、ここには含めない。
final class WIMReaderTests: XCTestCase {
    private static func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/wim/\(name).b64")
        return try XCTUnwrap(Data(base64Encoded: try String(contentsOf: url, encoding: .utf8), options: .ignoreUnknownCharacters))
    }

    private static let manifest: [String: (size: UInt64, sha: String)] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/wim/manifest.json")
        let json = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var result: [String: (UInt64, String)] = [:]
        for (name, value) in json["payload"] as! [String: [String: Any]] {
            result[name] = (UInt64(value["size"] as! Int), value["sha256"] as! String)
        }
        return result
    }()

    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// lookup table から entry の resource header を引く（`formatSpecific["sha1"]` 経由）。
    private func resource(in data: Data, for entry: ArchiveEntry) throws -> WIMResourceHeader {
        let bytes = [UInt8](data)
        let header = try WIMHeader(Array(bytes[0..<WIMHeader.size]))
        let table = Array(bytes[Int(header.lookupTable.offset)..<Int(header.lookupTable.offset + header.lookupTable.packedSize)])
        let hash = try XCTUnwrap(entry.formatSpecific["sha1"])
        for offset in stride(from: 0, to: table.count, by: WIMLookupEntry.size) {
            let candidate = WIMLookupEntry(table, offset)
            if candidate.hash.map({ String(format: "%02x", $0) }).joined() == hash { return candidate.header }
        }
        throw KaitoError.notFound("resource for \(entry.name)")
    }

    private func read(_ stream: EntryStream, chunk: Int) throws -> Data {
        var output = Data(), buffer = [UInt8](repeating: 0, count: chunk)
        while stream.remaining > 0 {
            let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
            guard count > 0 else { throw KaitoError.truncated }
            output.append(contentsOf: buffer.prefix(count))
        }
        return output
    }

    func testStoredFixturesExposeStreamsLinksAndHardLinks() throws {
        for name in ["stored.wim", "sevenzip-copy.wim"] {
            let reader = try ArchiveReader.open(data: try Self.fixture(name))
            XCTAssertEqual(reader.format, .wim, name)
            XCTAssertEqual(try FormatDetector.detect(data: try Self.fixture(name)), .wim, name)
            for file in ["readme.txt", "empty.bin", "same.txt", "same-copy.txt", "sub/nested/deep.txt", "sub/日本語.txt"] {
                let entry = try XCTUnwrap(reader.entries.first { $0.name == file }, "\(name) \(file)")
                let expected = try XCTUnwrap(Self.manifest[file])
                XCTAssertEqual(entry.kind, .file, file)
                XCTAssertEqual(entry.uncompressedSize, expected.size, file)
                XCTAssertEqual(entry.methodDescription, "WIM (stored)", file)
                XCTAssertEqual(sha(try reader.read(entry)), expected.sha, "\(name) \(file)")
                XCTAssertEqual(sha(try read(reader.stream(entry), chunk: 7)), expected.sha, "\(name) \(file) chunk 7")
            }
            XCTAssertEqual(reader.entries.filter { $0.kind == .directory }.map(\.name).sorted(), ["sub", "sub/nested"], name)
            XCTAssertLessThan(try XCTUnwrap(reader.entries.firstIndex { $0.name == "sub" }),
                              try XCTUnwrap(reader.entries.firstIndex { $0.name == "sub/nested/deep.txt" }), name)
            for entry in reader.entries {
                XCTAssertNotNil(entry.modificationDate, "\(name) \(entry.name)")
                XCTAssertEqual(entry.formatSpecific["image"], "1", entry.name)
                XCTAssertNotNil(entry.formatSpecific["attributes"], entry.name)
            }
            if name == "stored.wim" {
                let stream = try XCTUnwrap(reader.entries.first { $0.name == "readme.txt:Zone.Identifier" })
                XCTAssertEqual(stream.formatSpecific["stream"], "Zone.Identifier")
                XCTAssertEqual(try reader.read(stream), Data("[ZoneTransfer]\r\nZoneId=3\r\n".utf8))
                let link = try XCTUnwrap(reader.entries.first { $0.name == "link" })
                XCTAssertEqual(link.kind, .symlink)
                XCTAssertEqual(link.formatSpecific["linkPath"], "readme.txt")
                XCTAssertEqual(link.formatSpecific["reparseTag"], "0xa000000c")
                XCTAssertNil(link.formatSpecific["linkTargetAbsolute"])
                XCTAssertEqual(try reader.read(link), Data())
                let same = try XCTUnwrap(reader.entries.first { $0.name == "same.txt" })
                XCTAssertEqual(same.formatSpecific["hardLinkGroup"], "7")
                XCTAssertEqual(reader.entries.first { $0.name == "same-copy.txt" }?.formatSpecific["hardLinkGroup"], "7")
            }
            let reopened = try reader.reopen()
            XCTAssertEqual(reopened.entries, reader.entries, name)
        }
    }

    func testCompressedFixturesDecodeEveryChunkAndVerifySHA1() throws {
        for (name, method) in [("xpress.wim", "WIM XPRESS"), ("lzx.wim", "WIM LZX"), ("lzx-raw.wim", "WIM LZX")] {
            let data = try Self.fixture(name)
            let reader = try ArchiveReader.open(data: data)
            XCTAssertEqual(reader.format, .wim, name)
            for file in ["text.txt", "e8.bin", "mixed.bin", "random.bin", "sub/small.txt"] {
                let entry = try XCTUnwrap(reader.entries.first { $0.name == file }, "\(name) \(file)")
                let expected = try XCTUnwrap(Self.manifest[file])
                XCTAssertEqual(entry.uncompressedSize, expected.size, file)
                XCTAssertEqual(entry.methodDescription, method, "\(name) \(file)")
                XCTAssertEqual(sha(try reader.read(entry)), expected.sha, "\(name) \(file)")
                XCTAssertEqual(sha(try read(reader.stream(entry), chunk: 1_000)), expected.sha, "\(name) \(file) chunk 1000")
                XCTAssertEqual(sha(try read(reader.stream(entry), chunk: 1)), expected.sha, "\(name) \(file) chunk 1")
            }
            // random.bin は 1 chunk が縮まないので生格納。packed size == original で見分ける。
            let random = try XCTUnwrap(reader.entries.first { $0.name == "random.bin" })
            XCTAssertEqual(random.compressedSize, random.uncompressedSize, name)
            // 圧縮 chunk を壊すと SHA-1 検証か復号が失敗する。
            var damaged = data
            let text = try XCTUnwrap(reader.entries.first { $0.name == "text.txt" })
            let textResource = try resource(in: data, for: text)
            damaged[Int(textResource.offset) + 40] ^= 0x5A
            let damagedReader = try ArchiveReader.open(data: damaged)
            XCTAssertThrowsError(try damagedReader.read(damagedReader.entries[text.index]), name) {
                switch $0 as? KaitoError {
                case .checksumMismatch, .malformed, .truncated: break
                default: XCTFail("Unexpected error: \($0)")
                }
            }
        }
    }

    func testTwoImagesArePrefixedWithTheirIndex() throws {
        let reader = try ArchiveReader.open(data: try Self.fixture("two-images.wim"))
        let names = reader.entries.map(\.name)
        // 7-Zip も同じ `1/` `2/` の前置で一覧する（manifest の two-images-7zz-paths）。
        XCTAssertEqual(names.filter { $0.hasPrefix("1/") }.count, 8)
        XCTAssertEqual(names.filter { $0.hasPrefix("2/") }.count, 2)
        XCTAssertEqual(reader.entries.first { $0.name == "1" }?.kind, .directory)
        XCTAssertEqual(reader.entries.first { $0.name == "2/only-in-2.txt" }?.formatSpecific["image"], "2")
        let readme1 = try XCTUnwrap(reader.entries.first { $0.name == "1/readme.txt" })
        let readme2 = try XCTUnwrap(reader.entries.first { $0.name == "2/readme.txt" })
        XCTAssertEqual(try reader.read(readme1), try reader.read(readme2))
        XCTAssertEqual(sha(try reader.read(readme2)), Self.manifest["readme.txt"]?.sha)
    }

    func testStructuralDamageAndLimits() throws {
        let data = try Self.fixture("stored.wim")
        // header の署名以外: version 0.14（solid / LZMS）は unsupportedMethod。
        var solid = data
        solid[12] = 0x00; solid[13] = 0x0E; solid[14] = 0; solid[15] = 0
        XCTAssertThrowsError(try ArchiveReader.open(data: solid)) {
            guard case .unsupportedMethod(let reason) = $0 as? KaitoError, reason.contains("LZMS") else { return XCTFail("Unexpected error: \($0)") }
        }
        // part 2 of 3 は先頭 part を開くように促す。
        var part = data
        part[40] = 2; part[42] = 3
        XCTAssertThrowsError(try ArchiveReader.open(data: part)) {
            guard case .unsupportedMethod(let reason) = $0 as? KaitoError, reason.contains("spanned") else { return XCTFail("Unexpected error: \($0)") }
        }
        // lookup table の長さが 50 の倍数でない。
        var table = data
        table[48] = data[48] &- 1
        XCTAssertThrowsError(try ArchiveReader.open(data: table)) {
            guard case .malformed = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        // 切り詰め: lookup table より前で切ると truncated。
        XCTAssertThrowsError(try ArchiveReader.open(data: Data(data.prefix(300)))) {
            guard case .truncated = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        // 上限。
        XCTAssertThrowsError(try ArchiveReader.open(data: data, options: ReaderOptions(limits: ReadLimits(maxEntryCount: 3)))) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertThrowsError(try ArchiveReader.open(data: data, options: ReaderOptions(limits: ReadLimits(maxPathComponentCount: 1)))) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertThrowsError(try ArchiveReader.open(data: data, options: ReaderOptions(limits: ReadLimits(maxTotalMetadataSize: 500)))) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        // resource の SHA-1 を書き換えると読み取りが checksumMismatch。
        let reader = try ArchiveReader.open(data: data)
        let readme = try XCTUnwrap(reader.entries.first { $0.name == "readme.txt" })
        let resource = try resource(in: data, for: readme)
        var corrupt = data
        corrupt[Int(resource.offset) + 3] ^= 0x01
        let corruptReader = try ArchiveReader.open(data: corrupt)
        XCTAssertThrowsError(try corruptReader.read(corruptReader.entries[readme.index])) {
            XCTAssertEqual($0 as? KaitoError, .checksumMismatch(entry: readme.index))
        }
    }

    func testXpressAndLZXChunkDecodersRejectGarbage() throws {
        XCTAssertThrowsError(try XpressHuffmanDecoder.decode([UInt8](repeating: 0, count: 300), outputSize: 10)) {
            guard case .malformed = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertThrowsError(try XpressHuffmanDecoder.decode([UInt8](repeating: 0, count: 100), outputSize: 10)) {
            XCTAssertEqual($0 as? KaitoError, .truncated)
        }
        // 全 symbol が 4 bit（256 個 × 2^11 = 2^19 > 2^15）は表が溢れる。
        XCTAssertThrowsError(try XpressHuffmanDecoder.decode([UInt8](repeating: 0x44, count: 300), outputSize: 10)) {
            guard case .malformed(let reason) = $0 as? KaitoError, reason.contains("table") else { return XCTFail("Unexpected error: \($0)") }
        }
        let decoder = try LZXDecoder(windowBits: 15, outputSize: 100, dictionarySizeLimit: 1 << 20,
                                     intelHeader: false, fixedTranslationSize: 12_000_000, wimVariant: true)
        XCTAssertThrowsError(try decoder.decodeFrame(input: [UInt8](repeating: 0xFF, count: 64), outputSize: 100))
    }
}
