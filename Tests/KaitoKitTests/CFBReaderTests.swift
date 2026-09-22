import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

/// [MS-CFB] compound file。fixture は Tests/Fixtures/cfb（自作 writer、7-Zip が同じ内容に展開）。
final class CFBReaderTests: XCTestCase {
    func testR2RootMiniStreamSizeOverflowIsRejected() throws {
        var bytes = try Self.fixture("v4.cfb")
        let directory = (Int(CFBBytes.u32([UInt8](bytes), 48)) + 1) * 4096
        bytes.replaceSubrange((directory + 120)..<(directory + 128), with: repeatElement(UInt8(255), count: 8))
        XCTAssertThrowsError(try ArchiveReader.open(data: bytes)) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("予期しないエラー: \($0)") }
        }
        // 上限を外しても切り上げ加算で trap せず、実 chain の不足を拒否する。
        XCTAssertThrowsError(try ArchiveReader.open(data: bytes, options: ReaderOptions(limits: ReadLimits(maxEntrySize: .max)))) {
            guard case .malformed = $0 as? KaitoError else { return XCTFail("予期しないエラー: \($0)") }
        }
    }

    func testR3DeepSiblingTreeDoesNotUseTheCallStack() throws {
        let count = 4_000
        let directorySectors = (count + 1 + 3) / 4
        let fatSectors = (directorySectors + 126) / 127
        var bytes = Data(repeating: 0, count: (1 + directorySectors + fatSectors) * 512)
        func put(_ value: UInt64, at offset: Int, width: Int = 4) {
            for i in 0..<width { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
        }
        bytes.replaceSubrange(0..<8, with: CFBHeader.signature)
        put(3, at: 26, width: 2); put(0xFFFE, at: 28, width: 2)
        put(9, at: 30, width: 2); put(6, at: 32, width: 2)
        put(UInt64(fatSectors), at: 44); put(4096, at: 56)
        put(0xFFFF_FFFE, at: 60); put(0xFFFF_FFFE, at: 68)
        for i in 0..<109 { put(i < fatSectors ? UInt64(directorySectors + i) : 0xFFFF_FFFF, at: 76 + i * 4) }
        for i in 0..<(fatSectors * 128) {
            let next: UInt64 = i < directorySectors - 1 ? UInt64(i + 1)
                : i == directorySectors - 1 ? 0xFFFF_FFFE
                : i < directorySectors + fatSectors ? 0xFFFF_FFFD : 0xFFFF_FFFF
            put(next, at: (1 + directorySectors) * 512 + i * 4)
        }
        for i in 0...count {
            let base = 512 + i * 128
            let name = Array((i == 0 ? "Root Entry" : "f\(i)").utf16)
            for (j, unit) in name.enumerated() { put(UInt64(unit), at: base + j * 2, width: 2) }
            put(UInt64((name.count + 1) * 2), at: base + 64, width: 2)
            bytes[base + 66] = i == 0 ? 5 : 2
            put(i > 0 && i < count ? UInt64(i + 1) : 0xFFFF_FFFF, at: base + 68)
            put(0xFFFF_FFFF, at: base + 72)
            put(i == 0 ? 1 : 0xFFFF_FFFF, at: base + 76)
            put(0xFFFF_FFFE, at: base + 116)
        }
        let reader = try ArchiveReader.open(data: bytes)
        XCTAssertEqual(reader.entries.count, count)
        XCTAssertEqual(reader.entries.first?.name, "f4000")
        XCTAssertEqual(reader.entries.last?.name, "f1")
        XCTAssertEqual(try reader.read(reader.entries[0]), Data())
        XCTAssertThrowsError(try ArchiveReader.open(data: bytes, options: ReaderOptions(limits: ReadLimits(maxEntryCount: 10)))) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("予期しないエラー: \($0)") }
        }
        // 最深部から既訪問の entry へ戻る循環も検出する。
        put(1, at: 512 + count * 128 + 68)
        XCTAssertThrowsError(try ArchiveReader.open(data: bytes)) {
            guard case .malformed = $0 as? KaitoError else { return XCTFail("予期しないエラー: \($0)") }
        }
    }

    func testR10NativeCFBSignatureWinsOverPayloadBinHexText() throws {
        var bytes = try Self.fixture("v3.cfb")
        let original = try ArchiveReader.open(data: bytes)
        let directory = (Int(CFBBytes.u32([UInt8](bytes), 48)) + 1) * 512
        let stream = try XCTUnwrap(stride(from: directory, to: directory + 512, by: 128).first {
            bytes[$0 + 66] == 2 && CFBBytes.u32([UInt8](bytes), $0 + 120) >= 4096
        })
        let offset = (Int(CFBBytes.u32([UInt8](bytes), stream + 116)) + 1) * 512
        let banner = Data("(This file must be converted with BinHex 4.0)".utf8)
        XCTAssertLessThan(offset + banner.count, 65_536)
        bytes.replaceSubrange(offset..<(offset + banner.count), with: banner)
        XCTAssertEqual(try FormatDetector.detect(data: bytes), .compoundFile)
        let reader = try ArchiveReader.open(data: bytes)
        XCTAssertEqual(reader.entries, original.entries)
        let name = try CFBDirectoryEntry([UInt8](bytes), stream, majorVersion: 3).name
        let entry = try XCTUnwrap(reader.entries.first { $0.name == CFBReader.publishedName(name) })
        XCTAssertEqual(try reader.read(entry).prefix(banner.count), banner)
    }

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private struct Payload: Decodable { let size: UInt64; let sha256: String }
    private struct Archive: Decodable { let size: UInt64; let sha256: String; let files: [String] }
    private static func manifest() throws -> (payload: [String: Payload], archives: [String: Archive]) {
        let data = try Data(contentsOf: root.appendingPathComponent("Fixtures/cfb/manifest.json"))
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
        let base64 = try String(contentsOf: root.appendingPathComponent("Fixtures/cfb/\(name).gz.b64"), encoding: .utf8)
        let gzip = try ArchiveReader.open(data: XCTUnwrap(Data(base64Encoded: base64, options: .ignoreUnknownCharacters)))
        return try gzip.read(gzip.entries[0])
    }
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    /// 7-Zip と同じ綴り: 制御文字は `[n]`。
    private static func published(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).map { CFBReader.publishedName(String($0)) }.joined(separator: "/")
    }

    func testFixturesListStoragesAndStreamsAndMatchSevenZip() throws {
        let manifest = try Self.manifest()
        for name in ["v3.cfb", "v3-interleaved.cfb", "v4.cfb", "v3-difat.cfb", "msi-names.cfb"] {
            let bytes = try Self.fixture(name)
            XCTAssertEqual(sha(bytes), manifest.archives[name]?.sha256, name)
            XCTAssertEqual(try FormatDetector.detect(data: bytes), .compoundFile, name)
            let reader = try ArchiveReader.open(data: bytes)
            XCTAssertEqual(reader.format, .compoundFile, name)
            let files = try XCTUnwrap(manifest.archives[name]).files
            let streams = reader.entries.filter { $0.kind == .file }
            XCTAssertEqual(Set(streams.map(\.name)), Set(files.map(Self.published)), name)
            if name != "msi-names.cfb" {
                XCTAssertEqual(Set(reader.entries.filter { $0.kind == .directory }.map(\.name)),
                               ["Storage One", "Storage One/Deeper", "日本語ストレージ"], name)
            }
            for entry in streams {
                let original = try XCTUnwrap(files.first { Self.published($0) == entry.name }, entry.name)
                let want = try XCTUnwrap(manifest.payload[original])
                XCTAssertEqual(entry.uncompressedSize, want.size, "\(name): \(entry.name)")
                XCTAssertEqual(entry.methodDescription, "stored", entry.name)
                XCTAssertEqual(sha(try reader.read(entry)), want.sha256, "\(name): \(entry.name)")
            }
            if name == "msi-names.cfb" {
                // 詰め込み名は 7-Zip と同じ綴りに戻り、元の UTF-16 名は storedName に残る。
                let tables = try XCTUnwrap(reader.entries.first { $0.name == "!_Tables" })
                XCTAssertEqual(tables.formatSpecific["storedName"], "䡀㽿䅤䈯䠶")
                XCTAssertNil(reader.entries.first { $0.name == "plain-name.txt" }?.formatSpecific["storedName"])
                continue
            }
            // storage は CLSID と更新日時を持ち、stream は持たない。
            let storage = try XCTUnwrap(reader.entries.first { $0.name == "Storage One" })
            XCTAssertEqual(storage.formatSpecific["clsid"]?.count, 38, name)
            XCTAssertTrue(storage.formatSpecific["clsid"]?.hasPrefix("{") ?? false, name)
            XCTAssertNotNil(storage.modificationDate, name)
            XCTAssertNil(streams[0].formatSpecific["clsid"], name)
            // 断片化した大きい stream を小さな buffer で読む。
            let large = try XCTUnwrap(reader.entries.first { $0.name == "large-a.bin" })
            let stream = try reader.stream(large)
            var result = Data(), buffer = [UInt8](repeating: 0, count: 100)
            while true {
                let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
                if count == 0 { break }
                result.append(contentsOf: buffer.prefix(count))
            }
            XCTAssertEqual(sha(result), manifest.payload["large-a.bin"]?.sha256, name)
            let reopened = try reader.reopen()
            XCTAssertEqual(reopened.entries, reader.entries, name)
            XCTAssertEqual(try reopened.read(reopened.entries[3]), try reader.read(reader.entries[3]), name)
        }
        // 1 byte ずつ返す source（sector をまたぐ読み取り）。
        let short = try ArchiveReader.open(source: ShortSource(try Self.fixture("v3-interleaved.cfb")))
        let large = try XCTUnwrap(short.entries.first { $0.name == "large-b.txt" })
        XCTAssertEqual(sha(try short.read(large)), manifest.payload["large-b.txt"]?.sha256)
    }

    func testPublishedNamesEscapeControlCharactersAndSlashes() {
        XCTAssertEqual(CFBReader.publishedName("\u{05}SummaryInformation"), "[5]SummaryInformation")
        XCTAssertEqual(CFBReader.publishedName("plain"), "plain")
        XCTAssertEqual(CFBReader.publishedName("a/b\u{7F}"), "a[47]b[127]")
        XCTAssertEqual(CFBReader.publishedName(""), "[]")
    }

    /// Windows Installer の詰め込み名。期待値は 7-Zip 26.03 の一覧（実物の MSI と自作 file の探り）。
    func testMSINamesUnpackLikeSevenZip() {
        XCTAssertEqual(CFBReader.unpackMSIName("䡀䈖䌧䠤"), "!Media")
        XCTAssertEqual(CFBReader.unpackMSIName("䌋䄱䜵䀾䄵䓳䇨䛎䠨"), "Binary.WrappedExe")
        XCTAssertEqual(CFBReader.unpackMSIName("㡀㣂㥄㧆㩈"), "0123456789")
        XCTAssertEqual(CFBReader.unpackMSIName("\u{47FF}"), "__")
        XCTAssertEqual(CFBReader.unpackMSIName("\u{4840}\u{4840}\u{4805}"), "!!5")
        XCTAssertEqual(CFBReader.unpackMSIName("a\u{4801}"), "a1")
        XCTAssertEqual(CFBReader.unpackMSIName("\u{4841}\u{4802}"), "\u{4841}2")
        XCTAssertEqual(CFBReader.unpackMSIName("\u{3400}\u{4803}"), "\u{3400}3")
        XCTAssertEqual(CFBReader.unpackMSIName("日本語"), "日本語")
    }

    func testDamagedFilesAreRejected() throws {
        let original = try Self.fixture("v3.cfb")
        let header = try CFBHeader([UInt8](original.prefix(512)))
        let directoryOffset = Int(header.firstDirectorySector + 1) * 512
        func entryOffset(_ id: Int) -> Int { directoryOffset + id * 128 }
        // version 5 は未対応、byte order の誤りは malformed。
        var version = original; version[26] = 5
        XCTAssertThrowsError(try ArchiveReader.open(data: version)) { XCTAssertEqual($0 as? KaitoError, .unsupportedFormat) }
        var order = original; order[28] = 0xFF; order[29] = 0xFE
        assertMalformed(order, "byte order")
        // root entry の型が違う。
        var root = original; root[entryOffset(0) + 66] = 2
        assertMalformed(root, "root type")
        // directory の木に循環: id 1 の右の兄弟を自分にする。
        var cycle = original
        for (index, byte) in [1, 0, 0, 0].enumerated() { cycle[entryOffset(1) + 72 + index] = UInt8(byte) }
        assertMalformed(cycle, "tree cycle")
        // 名前長が奇数。
        var odd = original; odd[entryOffset(1) + 64] = 7
        assertMalformed(odd, "name length")
        // stream の chain が宣言サイズより短い（large-a.bin の 2 番目の sector を ENDOFCHAIN に）。
        let reader = try ArchiveReader.open(data: original)
        let large = try XCTUnwrap(reader.entries.first { $0.name == "large-a.bin" })
        let directory = try CFBDirectoryEntry([UInt8](original), entryOffset(try Self.streamID(named: "large-a.bin", in: original, header: header)), majorVersion: 3)
        let fatSector = Int(header.headerDIFAT[0] + 1) * 512
        var shortChain = original
        let fatEntry = fatSector + Int(directory.startSector) * 4
        shortChain.replaceSubrange(fatEntry..<(fatEntry + 4), with: [0xFE, 0xFF, 0xFF, 0xFF])
        let shortReader = try ArchiveReader.open(data: shortChain)
        XCTAssertThrowsError(try shortReader.read(shortReader.entries[large.index])) { XCTAssertEqual($0 as? KaitoError, .truncated) }
        // FAT の chain に循環（start sector が自分を指す）。
        var fatCycle = original
        fatCycle.replaceSubrange(fatEntry..<(fatEntry + 4), with: withUnsafeBytes(of: directory.startSector.littleEndian) { Array($0) })
        let cycleReader = try ArchiveReader.open(data: fatCycle)
        XCTAssertThrowsError(try cycleReader.read(cycleReader.entries[large.index])) {
            guard case .malformed = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        // mini stream の外を指す mini sector（small.txt の start を大きな値に）。
        var mini = original
        let smallOffset = entryOffset(try Self.streamID(named: "small.txt", in: original, header: header))
        mini.replaceSubrange((smallOffset + 116)..<(smallOffset + 120), with: [0xF0, 0x00, 0x00, 0x00])
        let miniReader = try ArchiveReader.open(data: mini)
        let small = try XCTUnwrap(miniReader.entries.first { $0.name == "small.txt" })
        XCTAssertThrowsError(try miniReader.read(small)) {
            guard case .malformed = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        // 切り詰め: directory sector に届かない。
        XCTAssertThrowsError(try ArchiveReader.open(data: original.prefix(directoryOffset))) {
            XCTAssertEqual($0 as? KaitoError, .truncated)
        }
        // 上限: entry 数、path の深さ、metadata の大きさ。
        for (limits, label) in [(ReadLimits(maxEntryCount: 3), "entry count"), (ReadLimits(maxPathComponentCount: 1), "depth"),
                                (ReadLimits(maxMetadataSize: 1_024), "metadata")] {
            XCTAssertThrowsError(try ArchiveReader.open(data: original, options: ReaderOptions(limits: limits)), label) {
                guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("\(label): \($0)") }
            }
        }
    }

    /// directory entry を走査して名前から stream ID を求める（v3 fixture の directory chain は連続）。
    private static func streamID(named name: String, in bytes: Data, header: CFBHeader) throws -> Int {
        let array = [UInt8](bytes)
        let start = Int(header.firstDirectorySector + 1) * 512
        for id in 0..<64 where start + (id + 1) * 128 <= array.count {
            let entry = try CFBDirectoryEntry(array, start + id * 128, majorVersion: 3)
            if entry.name == name { return id }
        }
        throw KaitoError.notFound(name)
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
