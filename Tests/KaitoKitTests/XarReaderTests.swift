// xar の公開形式説明・xar(1)、RFC 1950/1951、LZMA SDK lzma-specification.txt、
// XZ file-format spec に対応する利用者提供の実測 byte 表と固定 fixture に基づく検証。
// xar / libarchive / 7-Zip / XADMaster / The Unarchiver 等、他の archiver の source は参照していない。
import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest
import zlib

final class XarReaderTests: XCTestCase {
    private let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    private let linkHash = "86d7bb82c5856157d89466dc8fc8d52b8e14742702359f500dd09f0f912bb77c"
    private let lzmaHash = "4a26bca315603e8ba47688af0b94f8061a871ca95fcb3c0358fa6a357123d741"
    private let variants = ["xar-plain.xar", "xar-stored.xar", "xar-bzip2.xar", "xar-sha512.xar"]

    private struct Row: Equatable {
        let name: String
        let size: UInt64
        let sha256: String
        init(_ name: String, _ size: UInt64, _ sha256: String) {
            self.name = name; self.size = size; self.sha256 = sha256
        }
    }
    private func fixture(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Fixtures/container/\(name).b64"), encoding: .utf8)
        return try XCTUnwrap(Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func rows(_ reader: ArchiveReader) throws -> [Row] {
        try reader.entries.map { entry in
            let data = try reader.read(entry)
            XCTAssertEqual(UInt64(data.count), entry.uncompressedSize, entry.name)
            return Row(entry.name, try XCTUnwrap(entry.uncompressedSize), sha(data))
        }.sorted { $0.name < $1.name }
    }
    private func assertError(_ expected: String, _ body: () throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            let category: String
            switch error {
            case KaitoError.malformed: category = "malformed"
            case KaitoError.truncated: category = "truncated"
            case KaitoError.limitExceeded: category = "limit"
            case KaitoError.unsupportedFormat: category = "format"
            case KaitoError.unsupportedMethod(let method): category = method
            case KaitoError.notFound: category = "notFound"
            default: category = String(describing: error)
            }
            XCTAssertEqual(category, expected, file: file, line: line)
        }
    }

    func testAllTreeVariantsMatchEveryGoldenRowAndDocumentOrder() throws {
        let expected = [
            Row("日本語.txt", 3, "a10ea5adfcc15e3ead98a4fa85e9cee3cc266896a4df04511812b939d4101d22"),
            Row("a.txt", 0, emptyHash),
            Row("b.bin", 4096, "0d356260eaf09e3b3dc81a65b2ad2399aa7c4921c0274bd2cbb54c2a21c46e3b"),
            Row("empty.txt", 0, emptyHash),
            Row("hard.txt", 10, "1ddc234bae1b3930239b3d8625224117828d8a576bb8951087cbe6097387fb1e"),
            Row("link.txt", 0, emptyHash), Row("sub", 0, emptyHash), Row("sub/deep", 0, emptyHash),
            Row("sub/deep/d.txt", 5, "64896f89fd11190013b70103e603a1c5826e56b7fb7d2197ab279b0690043599"),
            Row("sub/nested.txt", 20, "5d0e5bc93dbc8febbb6b3cea0503bfd7460284e544c2f689538fd55da59accb2")
        ].sorted { $0.name < $1.name }
        var baseline: [Row]?
        for name in variants {
            let bytes = try fixture(name)
            XCTAssertEqual(try FormatDetector.detect(data: bytes), .xar, name)
            let reader = try ArchiveReader.open(data: bytes)
            XCTAssertEqual(reader.format, .xar)
            XCTAssertEqual(reader.entries.count, 10)
            let actual = try rows(reader)
            XCTAssertEqual(actual, expected, name)
            if let baseline { XCTAssertEqual(actual, baseline, name) } else { baseline = actual }
            XCTAssertEqual(reader.entries.map(\.name), ["日本語.txt", "a.txt", "sub", "sub/nested.txt", "sub/deep",
                "sub/deep/d.txt", "b.bin", "hard.txt", "link.txt", "empty.txt"])
            let sub = try XCTUnwrap(reader.entries.first { $0.name == "sub" })
            let nested = try XCTUnwrap(reader.entries.first { $0.name == "sub/nested.txt" })
            let deep = try XCTUnwrap(reader.entries.first { $0.name == "sub/deep" })
            let leaf = try XCTUnwrap(reader.entries.first { $0.name == "sub/deep/d.txt" })
            XCTAssertLessThan(sub.index, nested.index); XCTAssertLessThan(deep.index, leaf.index)
            XCTAssertEqual(sub.kind, .directory); XCTAssertEqual(deep.kind, .directory)
            let ref = try XCTUnwrap(reader.entries.first { $0.name == "a.txt" })
            XCTAssertEqual(ref.kind, .hardlink)
            XCTAssertEqual(ref.formatSpecific["linkPath"], "hard.txt")
            XCTAssertEqual(ref.formatSpecific["hardLinkTargetIndex"], "7")
            let japanese = reader.entries[0]
            XCTAssertEqual(japanese.rawName.bytes, Array("日本語.txt".utf8))
            XCTAssertEqual(japanese.posixPermissions, 0o644)
            XCTAssertNotNil(japanese.modificationDate)
            XCTAssertEqual(japanese.formatSpecific["uid"], "501")
            XCTAssertEqual(japanese.formatSpecific["gid"], "0")
            XCTAssertEqual(japanese.formatSpecific["user"], "nagash")
            XCTAssertEqual(japanese.formatSpecific["group"], "wheel")
            let method = name == "xar-stored.xar" ? "stored" : name == "xar-bzip2.xar" ? "bzip2" : "zlib"
            XCTAssertEqual(japanese.methodDescription, "xar (\(method))")
            XCTAssertEqual(try reader.reopen().entries, reader.entries)
        }
    }

    func testRemainingFixturesMatchEveryGoldenRowAndDetect() throws {
        let expected: [String: [Row]] = [
            "xar-lzma.xar": [Row("alone.txt", 1800, lzmaHash)],
            "xar-xz.xar": [Row("xz.txt", 1800, lzmaHash)],
            "xar-links.xar": [Row("orig.txt", 13, linkHash), Row("l1.txt", 0, emptyHash), Row("l2.txt", 0, emptyHash),
                Row("dangling.txt", 0, emptyHash), Row("sym.txt", 0, emptyHash)],
            "xar-subdoc.xar": [Row("real.txt", 13, linkHash), Row("a&b<c>.txt", 13, linkHash)],
            "xar-pkg.pkg": [
                Row("Bom", 35741, "70715831af6a919462e77059086f1794ff0e4f2310a0a8745d00895589bfc856"),
                Row("Payload", 161, "456c43ba1e9ef1860390c7ceecd2d5244234f09cfaf898eda4ea7d693e81c9e9"),
                Row("PackageInfo", 464, "7d610e9fb30e661955ee571d409df5a80e157a1eec577c07cfdce8b1cb52710d")]
        ]
        for (name, table) in expected {
            let bytes = try fixture(name)
            XCTAssertEqual(try FormatDetector.detect(data: bytes), .xar, name)
            let reader = try ArchiveReader.open(data: bytes)
            XCTAssertEqual(reader.entries.count, table.count, name)
            XCTAssertEqual(try rows(reader), table.sorted { $0.name < $1.name }, name)
            XCTAssertFalse(reader.entries.contains { $0.name == "ghost.txt" })
        }
    }

    func testLinksResolveChainsAndLeaveDanglingReferencesWithoutOutput() throws {
        let reader = try ArchiveReader.open(data: fixture("xar-links.xar"))
        let entries = reader.entries
        XCTAssertEqual(entries[0].kind, .file)
        for (index, path) in [(1, "orig.txt"), (2, "orig.txt"), (3, "404"), (4, "orig.txt")] {
            XCTAssertEqual(entries[index].kind, index == 4 ? .symlink : .hardlink)
            XCTAssertEqual(entries[index].formatSpecific["linkPath"], path)
            if index < 3 { XCTAssertEqual(entries[index].formatSpecific["hardLinkTargetIndex"], "0") }
            else { XCTAssertNil(entries[index].formatSpecific["hardLinkTargetIndex"]) }
            XCTAssertEqual(try reader.stream(entries[index]).readAll(), Data())
        }
    }

    func testExtractorMaterializesForwardReferencesAndChainsWithSharedInodes() throws {
        for (name, members, digest) in [
            ("xar-plain.xar", ["a.txt", "hard.txt"], "1ddc234bae1b3930239b3d8625224117828d8a576bb8951087cbe6097387fb1e"),
            ("xar-links.xar", ["orig.txt", "l1.txt", "l2.txt"], linkHash)
        ] {
            let reader = try ArchiveReader.open(data: fixture(name))
            let directory = try TarTestSupport.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            var identities: [Int: ExtractedFileIdentity] = [:]
            var failures: [String] = []
            // 単体 Extractor は展開済み実体を要求する。前方参照を含む link は最後に試す。
            let ordered = reader.entries.filter { $0.kind != .hardlink } + reader.entries.filter { $0.kind == .hardlink }
            for entry in ordered {
                do {
                    let result = try Extractor.extract(entry, from: reader, to: directory,
                        options: ExtractionOptions(), trustedTargets: identities)
                    if let identity = result.fileIdentity { identities[entry.index] = identity }
                } catch { failures.append(entry.name) }
            }
            XCTAssertEqual(failures, name == "xar-links.xar" ? ["dangling.txt"] : [])
            var inode: NSNumber?
            for member in members {
                let url = directory.appendingPathComponent(member)
                XCTAssertEqual(sha(try Data(contentsOf: url)), digest, member)
                let actual = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)
                if let inode { XCTAssertEqual(actual, inode) } else { inode = actual }
            }
        }
    }

    func testUppercaseChecksumStylesStillVerifyDigests() throws {
        let payload = Data("digest input".utf8)
        for (style, size) in [("SHA1", 20), ("MD5", 16), ("Sha256", 32), ("sHa512", 64)] {
            let xml = member("<data><offset>0</offset><length>12</length><size>12</size><extracted-checksum style='\(style)'>\(String(repeating: "0", count: size * 2))</extracted-checksum></data>")
            let reader = try openXML(xml, heap: payload)
            XCTAssertEqual(reader.entries[0].formatSpecific["extractedChecksumStyle"], style)
            XCTAssertThrowsError(try reader.read(reader.entries[0])) { error in
                guard case KaitoError.malformed("xar checksum mismatch") = error else { return XCTFail("\(error)") }
            }
            let toc = "<xar><toc><checksum style='\(style)'><offset>0</offset><size>\(size)</size></checksum></toc></xar>"
            XCTAssertThrowsError(try openXML(toc, heap: Data(repeating: 0, count: size))) { error in
                guard case KaitoError.malformed("xar toc checksum mismatch") = error else { return XCTFail("\(error)") }
            }
        }
        let original = try fixture("xar-plain.xar")
        let uppercaseTOC = try tocText(original).replacingOccurrences(of: "style=\"sha1\"", with: "style=\"SHA1\"")
        var bytes = try replacingTOC(original, with: uppercaseTOC)
        let header = try XarHeader(source: DataByteSource(bytes))
        let hash = Insecure.SHA1.hash(data: bytes[Int(header.size)..<Int(header.heapStart)])
        bytes.replaceSubrange(Int(header.heapStart)..<Int(header.heapStart) + 20, with: Array(hash))
        XCTAssertEqual(try rows(ArchiveReader.open(data: bytes)), try rows(ArchiveReader.open(data: original)))
    }

    func testRFC6713AndCaseInsensitiveMIMEStyles() throws {
        let original = try ArchiveReader.open(data: fixture("xar-lzma.xar"))
        let payload = try original.read(original.entries[0])
        let packed = try zlib(payload)
        for style in ["application/zlib", "Application/ZLIB", "APPLICATION/X-GZIP"] {
            let xml = member("<data><size>1800</size><offset>0</offset><length>\(packed.count)</length><encoding style='\(style)'/></data>")
            let reader = try openXML(xml, heap: packed)
            XCTAssertEqual(try rows(reader), [Row("a", 1800, lzmaHash)])
            XCTAssertEqual(reader.entries[0].methodDescription, "xar (zlib)")
            XCTAssertEqual(reader.entries[0].formatSpecific["encoding"], style)
        }
        for (fixtureName, style) in [("xar-stored.xar", "application/octet-stream"), ("xar-bzip2.xar", "application/x-bzip2"),
                                      ("xar-lzma.xar", "application/x-lzma"), ("xar-xz.xar", "application/x-xz")] {
            let original = try fixture(fixtureName)
            let xml = try tocText(original).replacingOccurrences(of: style, with: style.uppercased())
                .replacingOccurrences(of: "<checksum style=\"sha1\">", with: "<checksum style=\"none\">")
            let reader = try ArchiveReader.open(data: replacingTOC(original, with: xml))
            XCTAssertEqual(try rows(reader), try rows(ArchiveReader.open(data: original)))
        }
        assertError("malformed") {
            _ = try openXML(member("<data><offset>0</offset><length>1</length><size>2</size><encoding style='APPLICATION/OCTET-STREAM'/></data>"), heap: Data([1]))
        }
    }

    func testDeflateDiagnosticDistinguishesZlibFromRawStreams() throws {
        for wrapped in [false, true] {
            let decoder = try DeflateDecompressor(source: DataByteSource(Data([0xFF, 0xFF])), offset: 0, compressedSize: 2, zlibWrapped: wrapped)
            var buffer = [UInt8](repeating: 0, count: 16)
            XCTAssertThrowsError(try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }) { error in
                guard case KaitoError.malformed(let reason) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(reason, "invalid \(wrapped ? "zlib" : "raw DEFLATE") stream (zlib -3)")
            }
        }
    }

    // 固定 fixture は変更せず、テスト中だけ header / TOC / heap を差し替える。
    private func writeBE(_ value: UInt64, into bytes: inout Data, at offset: Int, count: Int) {
        for i in 0..<count { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> ((count - 1 - i) * 8)) }
    }
    private func zlib(_ input: Data) throws -> Data {
        var length = compressBound(uLong(input.count))
        var output = Data(count: Int(length))
        let status = output.withUnsafeMutableBytes { destination in
            input.withUnsafeBytes { source in
                compress2(destination.bindMemory(to: UInt8.self).baseAddress, &length,
                    source.bindMemory(to: UInt8.self).baseAddress, uLong(input.count), Z_BEST_COMPRESSION)
            }
        }
        XCTAssertEqual(status, Z_OK)
        output.count = Int(length)
        return output
    }
    private func tocText(_ data: Data) throws -> String {
        let source = DataByteSource(data)
        let header = try XarHeader(source: source)
        let decoder = try DeflateDecompressor(source: source, offset: header.size,
            compressedSize: header.compressedTOCLength, zlibWrapped: true)
        let stream = try EntryStream(decompressor: decoder, length: header.uncompressedTOCLength,
            expectedCRC32: nil, entryIndex: 0, limits: ReadLimits())
        return try XCTUnwrap(String(data: stream.readAll(), encoding: .utf8))
    }
    private func replacingTOC(_ original: Data, with xml: String, heap: Data? = nil, headerSize: Int = 28) throws -> Data {
        let header = try XarHeader(source: DataByteSource(original))
        let packed = try zlib(Data(xml.utf8))
        var output = Data(original.prefix(28))
        output.append(Data(repeating: 0, count: headerSize - 28))
        writeBE(UInt64(headerSize), into: &output, at: 4, count: 2)
        writeBE(UInt64(packed.count), into: &output, at: 8, count: 8)
        writeBE(UInt64(xml.utf8.count), into: &output, at: 16, count: 8)
        writeBE(0, into: &output, at: 24, count: 4)
        output.append(packed)
        output.append(heap ?? Data(original.dropFirst(Int(header.heapStart))))
        return output
    }
    private func synthetic(_ xml: String, heap: Data = Data(), headerSize: Int = 28) throws -> Data {
        try replacingTOC(fixture("xar-links.xar"), with: xml, heap: heap, headerSize: headerSize)
    }
    private func openXML(_ xml: String, heap: Data = Data(), limits: ReadLimits = ReadLimits()) throws -> ArchiveReader {
        try ArchiveReader.open(data: synthetic(xml, heap: heap), options: ReaderOptions(limits: limits))
    }
    private func member(_ fields: String, name: String = "a") -> String {
        "<xar><toc><file id='1'><name>\(name)</name><type>file</type>\(fields)</file></toc></xar>"
    }

    func testHeaderAndTOCCorruptionAreBoundedAndTyped() throws {
        let start = Date()
        let fixture = try fixture("xar-plain.xar")
        var damaged = fixture
        damaged[28] ^= 1
        assertError("malformed") { _ = try ArchiveReader.open(data: damaged) }
        damaged = fixture
        writeBE(UInt64(fixture.count + 1), into: &damaged, at: 8, count: 8)
        assertError("truncated") { _ = try ArchiveReader.open(data: damaged) }
        damaged = fixture
        writeBE(1 << 40, into: &damaged, at: 16, count: 8)
        let absurdStart = Date()
        assertError("limit") { _ = try ArchiveReader.open(data: damaged) }
        XCTAssertLessThan(Date().timeIntervalSince(absurdStart), 1)
        damaged = fixture
        writeBE(2, into: &damaged, at: 6, count: 2)
        assertError("format") { _ = try ArchiveReader.open(data: damaged) }
        damaged = fixture
        writeBE(27, into: &damaged, at: 4, count: 2)
        assertError("malformed") { _ = try XarReader(source: DataByteSource(damaged), options: ReaderOptions()) }
        let header = try XarHeader(source: DataByteSource(fixture))
        damaged = fixture
        damaged[Int(header.heapStart)] ^= 1
        XCTAssertThrowsError(try ArchiveReader.open(data: damaged)) { error in
            guard case KaitoError.malformed("xar toc checksum mismatch") = error else { return XCTFail("\(error)") }
        }
        let valid = try synthetic(member(""))
        for delta in [-1, 1] {
            damaged = valid
            let size = try XarHeader(source: DataByteSource(valid)).uncompressedTOCLength
            writeBE(UInt64(Int(size) + delta), into: &damaged, at: 16, count: 8)
            assertError("malformed") { _ = try ArchiveReader.open(data: damaged) }
        }
        assertError("malformed") { _ = try openXML("<!DOCTYPE xar [<!ENTITY x 'boom'>]><xar><toc/></xar>") }
        assertError("truncated") { _ = try openXML(member("<data><offset>1</offset><length>1</length><size>1</size></data>"), heap: Data([0])) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testStoredPayloadChecksumFailsOnStreamCompletion() throws {
        var bytes = try fixture("xar-pkg.pkg")
        let header = try XarHeader(source: DataByteSource(bytes))
        let toc = try XarTOC(bytes: Array(tocText(bytes).utf8), limits: ReadLimits())
        let payload = try XCTUnwrap(toc.files.first { $0.name == Array("Payload".utf8) }?.data)
        XCTAssertEqual(payload.encoding, "application/octet-stream")
        bytes[Int(header.heapStart + payload.offset)] ^= 1
        let reader = try ArchiveReader.open(data: bytes)
        let entry = try XCTUnwrap(reader.entries.first { $0.name == "Payload" })
        let stream = try reader.stream(entry)
        var firstByte = [UInt8](repeating: 0, count: 1)
        XCTAssertEqual(try firstByte.withUnsafeMutableBytes { try stream.read(into: $0) }, 1)
        XCTAssertThrowsError(try stream.readAll()) { error in
            guard case KaitoError.malformed("xar checksum mismatch") = error else { return XCTFail("\(error)") }
        }
        assertError("malformed") { _ = try stream.readAll() }
    }

    func testModificationDatesMatchLegacyFormatter() throws {
        // 切替前の暦・可変桁年・往復検査も含めて、従来の受理範囲と秒値を固定する。
        let reference = DateFormatter()
        reference.locale = Locale(identifier: "en_US_POSIX")
        reference.calendar = Calendar(identifier: .gregorian)
        reference.timeZone = TimeZone(secondsFromGMT: 0)
        reference.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        reference.isLenient = false
        func legacy(_ mtime: String) -> Date? {
            let text = mtime.trimmingCharacters(in: .whitespacesAndNewlines)
            let plain = text.hasSuffix("Z") ? String(text.dropLast()) : text
            if let parsed = reference.date(from: plain), reference.string(from: parsed) == plain { return parsed }
            return nil
        }
        var candidates: [String] = []
        for year in [1, 4, 100, 400, 1500, 1582, 1583, 1600, 1700, 1800, 1900,
                     1969, 1970, 1999, 2000, 2023, 2024, 2100, 2400, 9999, 10000] {
            for month in 1...12 {
                for day in 1...31 {
                    for time in ["00:00:00", "12:34:56", "23:59:59"] {
                        candidates.append(String(format: "%04d-%02d-%02dT", year, month, day) + time)
                    }
                }
            }
        }
        let edgeCases = [
            "2023-02-29T12:34:56", "2024-02-29T12:34:56", "2024-02-30T12:34:56",
            "2024-00-01T00:00:00", "2024-13-01T00:00:00", "2024-01-00T00:00:00",
            "2024-01-32T00:00:00", "2024-01-01T24:00:00", "2024-01-01T23:60:00",
            "2024-01-01T23:59:60", "2024-01-01T23:59:59", "2024-01-0123:59:59",
            "2024-01-01 23:59:59", "2024/01/01T23:59:59", "2024-01-01T23-59-59",
            "2024-01-01T23:59:5", "2024-01-01T23:59:599", "", "Z", "ZZ",
            "abcd-ef-ghTij:kl:mn", "２０２４-01-01T23:59:59", "2024-01-01t23:59:59",
            "1500-02-29T00:00:00", "1582-10-04T00:00:00", "1582-10-10T00:00:00",
            "1582-10-15T00:00:00", "1583-01-01T00:00:00", "10000-01-01T00:00:00",
            "0000-01-01T00:00:00", "2024-01-01T23:59:59z", "2024-01-01T23:59:59ZZ"
        ]
        for text in edgeCases {
            candidates += [text, text + "Z", " \t\n" + text, text + "\r\n ",
                           "\u{00A0}" + text + "Z\u{2003}"]
        }
        // 各位置の誤字が算術経路へ紛れ込まないことも確認する。
        let valid = Array("2024-02-29T23:59:59".utf8)
        for index in valid.indices {
            for byte: UInt8 in [0, 32, 47, 58, 65, 90, 127] {
                var changed = valid
                changed[index] = byte
                candidates.append(String(decoding: changed, as: UTF8.self))
            }
        }
        var formatter: DateFormatter?
        for text in candidates {
            XCTAssertEqual(XarReader.parseModificationDate(text, formatter: &formatter), legacy(text), text.debugDescription)
        }
        // TOC からの呼出しでも前処理と任意の末尾 Z を保持する。
        for text in edgeCases {
            let reader = try openXML(member("<mtime> \n\(text)\t </mtime>"))
            XCTAssertEqual(reader.entries[0].modificationDate, legacy(text), text.debugDescription)
        }
    }

    func testModificationDateFormatterIsCreatedOnlyForFallback() throws {
        var formatter: DateFormatter?
        XCTAssertEqual(XarReader.parseModificationDate("1970-01-01T00:00:00Z", formatter: &formatter),
                       Date(timeIntervalSince1970: 0))
        XCTAssertNotNil(XarReader.parseModificationDate("1583-01-01T00:00:00", formatter: &formatter))
        XCTAssertNil(XarReader.parseModificationDate("2024-02-30T00:00:00", formatter: &formatter))
        XCTAssertNil(formatter)
        XCTAssertNotNil(XarReader.parseModificationDate("1500-02-29T00:00:00", formatter: &formatter))
        let fallback = try XCTUnwrap(formatter)
        XCTAssertNotNil(XarReader.parseModificationDate("10000-01-01T00:00:00", formatter: &formatter))
        XCTAssertTrue(formatter === fallback)
    }

    func testXMLSubsetAndUnknownSubtrees() throws {
        let xml = """
        <?xml version='1.0' encoding='uTf-8'?><?test arbitrary text?>
        <xar><toc><subdoc><file><name>ghost.txt</name></file><nested><file/></nested></subdoc>
        <signature><file><name>also-ghost</name></file></signature>
        <file id='&#49;'><name><![CDATA[a&]]>&lt;b&gt;&quot;&apos;&#65;&#x65E5;.txt</name>
        <type>file</type><!--ignored--><ea><nested><file/></nested></ea><mode>0100644</mode>
        <mtime>2026-09-09T08:14:35</mtime><FinderCreateTime>1900-01-00T18:20:48</FinderCreateTime>
        </file></toc></xar>
        """
        let reader = try openXML(xml)
        XCTAssertEqual(reader.entries.map(\.name), ["a&<b>\"'A日.txt"])
        XCTAssertEqual(reader.entries[0].formatSpecific["fileID"], "1")
        XCTAssertEqual(reader.entries[0].posixPermissions, 0o644)
        XCTAssertNotNil(reader.entries[0].modificationDate)
        XCTAssertEqual(try reader.read(reader.entries[0]), Data())
        let invalidDate = try openXML(member("<mtime>1900-01-00T18:20:48</mtime><mode>08xx</mode>"))
        XCTAssertNil(invalidDate.entries[0].modificationDate); XCTAssertNil(invalidDate.entries[0].posixPermissions)
        for encoding in ["UTF-16", "ISO-8859-1"] {
            assertError("format") { _ = try openXML("<?xml version='1.0' encoding='\(encoding)'?><xar><toc/></xar>") }
        }
        for xml in ["<xar><toc></xar>", "<xar><toc/>", "<xar><toc/></xar><xar/>",
                    "<xar><toc a='1' a='2'/></xar>", "<xar><toc a=1/></xar>",
                    "<xar><toc a='1'b='2'/></xar>", "<xar><toc/></xar>bad", "<xar><toc><!--a--b--></toc></xar>",
                    "<xar><toc><![CDATA[no end</toc></xar>", "<xar><toc>]]></toc></xar>",
                    "<xar><toc><subdoc><!DOCTYPE foo></subdoc></toc></xar>"] {
            assertError("malformed") { _ = try openXML(xml) }
        }
        for entity in ["&bad;", "&amp", "&#0;", "&#xD800;", "&#x110000;", "&#-1;", "&#x;", "&#999999999999999999999;"] {
            assertError("malformed") { _ = try openXML(member("", name: entity)) }
            assertError("malformed") { _ = try openXML("<xar><toc><subdoc value='\(entity)'/></toc></xar>") }
        }
        let allowed = "<xar><toc>" + String(repeating: "<unknown>", count: 254) + String(repeating: "</unknown>", count: 254) + "</toc></xar>"
        XCTAssertEqual(try openXML(allowed).entries.count, 0)
        assertError("limit") { _ = try openXML(allowed.replacingOccurrences(of: "<toc>", with: "<toc><unknown>").replacingOccurrences(of: "</toc>", with: "</unknown></toc>")) }
    }

    func testResourceLimitsNumericOverflowAndExtendedHeader() throws {
        let fixture = try fixture("xar-plain.xar")
        for limits in [ReadLimits(maxEntryCount: 9), ReadLimits(maxEntrySize: 4095), ReadLimits(maxMetadataSize: 16),
                       ReadLimits(maxTotalMetadataSize: 300), ReadLimits(maxPathComponentCount: 2)] {
            assertError("limit") { _ = try ArchiveReader.open(data: fixture, options: ReaderOptions(limits: limits)) }
        }
        let reader = try ArchiveReader.open(data: synthetic(member(""), headerSize: 40))
        XCTAssertEqual(reader.entries.map(\.name), ["a"])
        for number in ["18446744073709551616", "-1", "+1", "1x", "", "1 2"] {
            assertError("malformed") { _ = try openXML(member("<data><offset>\(number)</offset><length>0</length><size>0</size></data>")) }
        }
        assertError("malformed") { _ = try openXML(member("<data><offset>18446744073709551615</offset><length>1</length><size>1</size></data>")) }
        assertError("malformed") { _ = try openXML(member("<data><offset>0</offset><length>1</length><size>2</size></data>"), heap: Data([1])) }
        assertError("limit") { _ = try openXML(member("", name: "a/b"), limits: ReadLimits(maxPathComponentCount: 1)) }
        let foreign = try ArchiveReader.open(data: fixture)
        let direct = try XarReader(source: DataByteSource(synthetic(member(""))), options: ReaderOptions())
        assertError("notFound") { _ = try direct.stream(for: foreign.entries[0], limits: ReadLimits()) }
    }

    func testEncodingToleranceUnknownMethodsAndBoundedXZ() throws {
        let original = try fixture("xar-xz.xar")
        var xml = try tocText(original)
        xml = xml.replacingOccurrences(of: "application/x-xz", with: "application/x-lzma")
        // checksum の宣言だけを無効化し、元の member digest と heap を維持する。
        xml = xml.replacingOccurrences(of: "<checksum style=\"sha1\">", with: "<checksum style=\"none\">")
        var bytes = try replacingTOC(original, with: xml)
        bytes.append(Data("unrelated following heap bytes".utf8))
        let reader = try ArchiveReader.open(data: bytes)
        XCTAssertEqual(try rows(reader), [Row("xz.txt", 1800, lzmaHash)])
        XCTAssertEqual(reader.entries[0].methodDescription, "xar (lzma)")
        let unsupported = try openXML(member("<data><size>1</size><offset>0</offset><encoding style='application/future'/><length>1</length></data>"), heap: Data([7]))
        XCTAssertEqual(unsupported.entries.count, 1)
        assertError("xar encoding application/future") { _ = try unsupported.stream(unsupported.entries[0]) }
        let stored = try openXML(member("<data><length>1</length><size>1</size><offset>0</offset></data>"), heap: Data([7]))
        XCTAssertEqual(try stored.read(stored.entries[0]), Data([7]))
        XCTAssertNil(stored.entries[0].formatSpecific["encoding"])
        XCTAssertEqual(stored.entries[0].methodDescription, "xar (stored)")
        let source = try BoundedByteSource(source: DataByteSource(Data([1, 2, 3, 4])), baseOffset: 1, length: 2)
        XCTAssertEqual(try readByteRange(source: source, offset: 0, count: 2), [2, 3])
        var buffer = [UInt8](repeating: 0, count: 10)
        XCTAssertEqual(try buffer.withUnsafeMutableBytes { try source.read(into: $0, at: 1) }, 1)
        XCTAssertEqual(buffer[0], 3)
        XCTAssertEqual(try buffer.withUnsafeMutableBytes { try source.read(into: $0, at: 2) }, 0)
        assertError("truncated") { _ = try BoundedByteSource(source: source, baseOffset: 1, length: 2) }
    }

    func testDigestAlgorithmsAndUnknownChecksumStyles() throws {
        let payload = Data("digest input".utf8)
        let hashes: [(String, [UInt8])] = [
            ("sha1", Array(Insecure.SHA1.hash(data: payload))), ("md5", Array(Insecure.MD5.hash(data: payload))),
            ("sha256", Array(SHA256.hash(data: payload))), ("sha512", Array(SHA512.hash(data: payload)))
        ]
        for (style, digest) in hashes {
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            let data = "<data><length>12</length><size>12</size><offset>0</offset><extracted-checksum style='\(style)'>\(hex.uppercased())</extracted-checksum></data>"
            let reader = try openXML(member(data), heap: payload)
            XCTAssertEqual(try reader.read(reader.entries[0]), payload)
            let bad = try openXML(member(data.replacingOccurrences(of: hex.uppercased(), with: String(repeating: "0", count: hex.count))), heap: payload)
            assertError("malformed") { _ = try bad.read(bad.entries[0]) }
            let tocXML = "<xar><toc><checksum style='\(style)'><offset>3</offset><size>\(digest.count)</size></checksum></toc></xar>"
            let packed = try zlib(Data(tocXML.utf8))
            let tocDigest: [UInt8]
            switch style {
            case "sha1": tocDigest = Array(Insecure.SHA1.hash(data: packed))
            case "md5": tocDigest = Array(Insecure.MD5.hash(data: packed))
            case "sha256": tocDigest = Array(SHA256.hash(data: packed))
            default: tocDigest = Array(SHA512.hash(data: packed))
            }
            XCTAssertEqual(try openXML(tocXML, heap: Data([0, 0, 0] + tocDigest)).entries.count, 0)
        }
        for style in ["none", "future"] {
            let xml = member("<data><length>1</length><size>1</size><offset>0</offset><extracted-checksum style='\(style)'>not hex</extracted-checksum></data>")
                .replacingOccurrences(of: "<toc>", with: "<toc><checksum style='\(style)'/>")
            let reader = try openXML(xml, heap: Data([7]))
            XCTAssertEqual(try reader.read(reader.entries[0]), Data([7]))
        }
    }

    func testForwardChainsPathLinksAndCycles() throws {
        let xml = """
        <xar><toc>
        <file id='1'><name>l2</name><type link='2'>hardlink</type></file>
        <file id='2'><name>l1</name><type link='3'>hardlink</type></file>
        <file id='3'><name>orig</name><type link='original'>hardlink</type></file>
        <file><name>path</name><type link='orig'>hardlink</type></file>
        <file id='4'><name>c1</name><type link='5'>hardlink</type></file>
        <file id='5'><name>c2</name><type link='4'>hardlink</type></file>
        <file id='6'><name>self</name><type link='6'>hardlink</type></file>
        <file><name>fifo</name><type>fifo</type></file>
        </toc></xar>
        """
        let reader = try openXML(xml)
        XCTAssertEqual(reader.entries[0].formatSpecific["linkPath"], "orig")
        for index in [0, 1, 3] { XCTAssertEqual(reader.entries[index].formatSpecific["hardLinkTargetIndex"], "2") }
        for index in [4, 5, 6] { XCTAssertNil(reader.entries[index].formatSpecific["hardLinkTargetIndex"]) }
        XCTAssertEqual(reader.entries[7].kind, .other)
    }
}
