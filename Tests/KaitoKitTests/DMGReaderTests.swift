import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

/// Apple disk image（UDIF + HFS+）。fixture は Tests/Fixtures/dmg（hdiutil が書き、mount と 7-Zip で照合、generate.sh）。
final class DMGReaderTests: XCTestCase {
    func testR5SectorByteOverflowIsRejected() throws {
        var table = Data(repeating: 0, count: 244)
        func put(_ value: UInt64, in data: inout Data, at offset: Int, width: Int = 8) {
            for i in 0..<width { data[offset + i] = UInt8(truncatingIfNeeded: value >> ((width - i - 1) * 8)) }
        }
        table.replaceSubrange(0..<4, with: "mish".utf8)
        put(1, in: &table, at: 4, width: 4)
        put(1 << 55, in: &table, at: 16)
        put(1, in: &table, at: 200, width: 4)
        put(1, in: &table, at: 204, width: 4)
        put(1 << 55, in: &table, at: 220)
        let xml = try PropertyListSerialization.data(fromPropertyList: ["resource-fork": ["blkx": [["Data": table]]]], format: .xml, options: 0)
        var trailer = Data(repeating: 0, count: 512)
        trailer.replaceSubrange(0..<4, with: "koly".utf8)
        put(4, in: &trailer, at: 4, width: 4)
        put(512, in: &trailer, at: 8, width: 4)
        put(UInt64(xml.count), in: &trailer, at: 224)
        put(1 << 55, in: &trailer, at: 492)
        XCTAssertThrowsError(try ArchiveReader.open(data: xml + trailer)) {
            XCTAssertEqual($0 as? KaitoError, .malformed("unsigned integer multiplication overflow"))
        }
    }

    func testR9CompressedChunkMustReachValidatedEnd() throws {
        let original = try Self.fixture("hfs-lzma.dmg")
        let source = DataByteSource(original)
        let trailer = try XCTUnwrap(try UDIFTrailer.read(source: source))
        let disk = try UDIFDiskByteSource(file: source, trailer: trailer, limits: ReadLimits())
        let chunk = try XCTUnwrap(disk.chunks.first {
            if case .xz = $0.kind { return $0.byteCount >= 1 << 20 }; return false
        })
        var corrupt = original
        // footer 自体は既存の事前検査が拒否する。展開完了時に検証する Index CRC を反転する。
        corrupt[Int(chunk.dataOffset + chunk.dataLength - 16)] ^= 1
        let stream = corrupt[Int(chunk.dataOffset)..<Int(chunk.dataOffset + chunk.dataLength)]
        XCTAssertThrowsError(try {
            let reader = try ArchiveReader.open(data: Data(stream))
            return try reader.read(reader.entries[0])
        }())
        let damaged = try UDIFDiskByteSource(file: DataByteSource(corrupt), trailer: trailer, limits: ReadLimits())
        // 二度読んでも拒否し、不正な chunk を cache しない。
        for _ in 0..<2 {
            XCTAssertThrowsError(try readByteRange(source: damaged, offset: chunk.byteOffset, count: 1)) {
                guard case .malformed = $0 as? KaitoError else { return XCTFail("予期しないエラー: \($0)") }
            }
        }
        // 有効な XZ stream の出力より 1 sector 短い宣言にする。
        // 宣言長だけ読んで cache すると、残った 512 byte と終端を検証せず成功してしまう。
        let xml = original[Int(trailer.xmlOffset)..<Int(trailer.xmlOffset + trailer.xmlLength)]
        var plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(xml), format: nil) as? [String: Any])
        var resources = try XCTUnwrap(plist["resource-fork"] as? [String: Any])
        var blocks = try XCTUnwrap(resources["blkx"] as? [[String: Any]])
        var changed = false
        for i in blocks.indices {
            var table = try XCTUnwrap(blocks[i]["Data"] as? Data)
            let bytes = [UInt8](table)
            for j in 0..<Int(UDIFBytes.u32(bytes, 200)) {
                let offset = 204 + j * 40
                if UDIFBytes.u32(bytes, offset) == 0x8000_0008,
                   UDIFBytes.u64(bytes, offset + 24) + trailer.dataForkOffset == chunk.dataOffset {
                    withUnsafeBytes(of: (chunk.sectorCount - 1).bigEndian) {
                        table.replaceSubrange((offset + 16)..<(offset + 24), with: $0)
                    }
                    changed = true
                }
            }
            blocks[i]["Data"] = table
        }
        XCTAssertTrue(changed)
        resources["blkx"] = blocks; plist["resource-fork"] = resources
        let shorterXML = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        var shorterTrailer = Data(original.suffix(512))
        withUnsafeBytes(of: UInt64(shorterXML.count).bigEndian) {
            shorterTrailer.replaceSubrange(224..<232, with: $0)
        }
        let shorter = DataByteSource(original.prefix(Int(trailer.xmlOffset)) + shorterXML + shorterTrailer)
        let shorterDisk = try UDIFDiskByteSource(file: shorter, trailer: XCTUnwrap(UDIFTrailer.read(source: shorter)), limits: ReadLimits())
        for _ in 0..<2 {
            XCTAssertThrowsError(try readByteRange(source: shorterDisk, offset: chunk.byteOffset, count: 1)) {
                XCTAssertEqual($0 as? KaitoError, .malformed("udif chunk output exceeds its declared size"))
            }
        }
    }

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private struct Payload: Decodable { let size: UInt64?; let sha256: String?; let symlink: String?; let decmpfs: Bool? }
    private struct Image: Decodable { let size: UInt64; let sha256: String; let note: String }
    private struct Manifest: Decodable { let payload: [String: Payload]; let images: [String: Image] }
    private static func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("Fixtures/dmg/manifest.json")))
    }
    private static func fixture(_ name: String) throws -> Data {
        let base64 = try String(contentsOf: root.appendingPathComponent("Fixtures/dmg/\(name).gz.b64"), encoding: .utf8)
        let gzip = try ArchiveReader.open(data: XCTUnwrap(Data(base64Encoded: base64, options: .ignoreUnknownCharacters)))
        return try gzip.read(gzip.entries[0])
    }
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func testCompressedImagesListTheHFSVolumeLikeTheMountedDisk() throws {
        let manifest = try Self.manifest()
        for name in ["hfs-zlib.dmg", "hfs-bzip2.dmg", "hfs-lzfse.dmg", "hfs-lzma.dmg"] {
            let bytes = try Self.fixture(name)
            XCTAssertEqual(sha(bytes), manifest.images[name]?.sha256, name)
            XCTAssertEqual(try FormatDetector.detect(data: bytes), .dmg, name)
            let reader = try ArchiveReader.open(data: bytes)
            XCTAssertEqual(reader.format, .dmg, name)
            // directory を除いた名前の集合は payload と一致する（symlink、resource fork、decmpfs を含む）。
            let names = Set(reader.entries.filter { $0.kind != .directory }.map(\.name))
            XCTAssertEqual(names, Set(manifest.payload.keys), name)
            XCTAssertEqual(Set(reader.entries.filter { $0.kind == .directory }.map(\.name)), ["sub", "sub/deeper"], name)
            for entry in reader.entries where entry.kind != .directory {
                let want = try XCTUnwrap(manifest.payload[entry.name], entry.name)
                if let target = want.symlink {
                    XCTAssertEqual(entry.kind, .symlink, entry.name)
                    XCTAssertEqual(entry.formatSpecific["linkTargetStoredAsData"], "true", entry.name)
                    XCTAssertEqual(String(decoding: try reader.read(entry), as: UTF8.self), target, entry.name)
                } else if want.decmpfs == true {
                    XCTAssertEqual(entry.methodDescription, "HFS+ compressed (decmpfs)", entry.name)
                    XCTAssertNil(entry.uncompressedSize, entry.name)
                    XCTAssertThrowsError(try reader.read(entry), entry.name) {
                        guard case .unsupportedMethod = $0 as? KaitoError else { return XCTFail("\(name): \($0)") }
                    }
                } else {
                    XCTAssertEqual(entry.uncompressedSize, want.size, "\(name): \(entry.name)")
                    XCTAssertEqual(sha(try reader.read(entry)), want.sha256, "\(name): \(entry.name)")
                    XCTAssertEqual(entry.methodDescription, "HFS+ (stored)", entry.name)
                }
                XCTAssertNotNil(entry.modificationDate, entry.name)
                XCTAssertEqual(entry.formatSpecific["volumeName"], "KaitoTest", entry.name)
            }
            let script = try XCTUnwrap(reader.entries.first { $0.name == "script.sh" })
            XCTAssertEqual(script.posixPermissions, 0o755, name)
            let hardlink = try XCTUnwrap(reader.entries.first { $0.name == "hardlink-to-readme" })
            XCTAssertNotNil(hardlink.formatSpecific["hardLink"], name)
            XCTAssertEqual(reader.entries.first { $0.name == "readme.txt/..namedfork/rsrc" }?.formatSpecific["fork"], "resource", name)
            // 49 extent の file を小さな buffer で読む。
            let fragmented = try XCTUnwrap(reader.entries.first { $0.name == "fragmented.bin" })
            let stream = try reader.stream(fragmented)
            var result = Data(), buffer = [UInt8](repeating: 0, count: 3_000)
            while true {
                let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
                if count == 0 { break }
                result.append(contentsOf: buffer.prefix(count))
            }
            XCTAssertEqual(sha(result), manifest.payload["fragmented.bin"]?.sha256, name)
            let reopened = try reader.reopen()
            XCTAssertEqual(reopened.entries, reader.entries, name)
        }
        // 1 byte ずつ返す source（chunk cache と extent をまたぐ読み取り）。
        let short = try ArchiveReader.open(source: ShortSource(try Self.fixture("hfs-zlib.dmg")))
        let data = try XCTUnwrap(short.entries.first { $0.name == "data.bin" })
        XCTAssertEqual(sha(try short.read(data)), manifest.payload["data.bin"]?.sha256)
    }

    func testRawImageISOInsideUDIFAndUnsupportedVolumes() throws {
        let manifest = try Self.manifest()
        // UDRO: raw と zero-fill の chunk だけ。
        let raw = try ArchiveReader.open(data: try Self.fixture("hfs-raw.dmg"))
        XCTAssertEqual(raw.format, .dmg)
        XCTAssertEqual(raw.entries.map(\.name), ["readme.txt", "readme.txt/..namedfork/rsrc", "sub", "sub/nested.txt"])
        XCTAssertEqual(sha(try raw.read(raw.entries[0])), manifest.payload["readme.txt"]?.sha256)
        XCTAssertEqual(raw.entries[0].formatSpecific["volumeName"], "KaitoRaw")
        // Apple Partition Map と、partition 表の無い bare volume。
        for (name, volume) in [("hfs-apm-zlib.dmg", "KaitoAPM"), ("hfs-bare-zlib.dmg", "KaitoBare")] {
            let reader = try ArchiveReader.open(data: try Self.fixture(name))
            XCTAssertEqual(reader.entries.map(\.name), ["readme.txt", "readme.txt/..namedfork/rsrc", "sub", "sub/nested.txt"], name)
            XCTAssertEqual(sha(try reader.read(reader.entries[3])), manifest.payload["sub/nested.txt"]?.sha256, name)
            XCTAssertEqual(reader.entries[0].formatSpecific["volumeName"], volume, name)
        }
        // UDIF に包まれた ISO 9660 は ISO reader に渡す。
        let iso = try ArchiveReader.open(data: try Self.fixture("iso-zlib.dmg"))
        XCTAssertEqual(iso.format, .dmg)
        XCTAssertEqual(iso.entries.map(\.name), ["readme.txt", "sub", "sub/nested.txt"])
        XCTAssertEqual(sha(try iso.read(iso.entries[2])), manifest.payload["sub/nested.txt"]?.sha256)
        // ADC（UDCO）と APFS は名前付きで拒む。
        for (name, needle) in [("hfs-adc.dmg", "ADC"), ("apfs-zlib.dmg", "APFS")] {
            let bytes = try Self.fixture(name)
            XCTAssertEqual(try FormatDetector.detect(data: bytes), .dmg, name)
            XCTAssertThrowsError(try ArchiveReader.open(data: bytes), name) {
                guard case .unsupportedMethod(let reason) = $0 as? KaitoError else { return XCTFail("\(name): \($0)") }
                XCTAssertTrue(reason.contains(needle), reason)
            }
        }
    }

    func testDamagedImagesAreRejected() throws {
        let original = try Self.fixture("hfs-zlib.dmg")
        let kolyOffset = original.count - 512
        // koly の version が 4 でない。
        var version = original; version[kolyOffset + 7] = 5
        XCTAssertThrowsError(try ArchiveReader.open(data: version)) {
            guard case .unsupportedMethod = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        // koly の署名を壊すと単なる zlib data でもなく unsupportedFormat。
        var signature = original; signature[kolyOffset] = UInt8(ascii: "x")
        XCTAssertThrowsError(try ArchiveReader.open(data: signature)) { XCTAssertEqual($0 as? KaitoError, .unsupportedFormat) }
        // plist の途中で切る（koly は失われる）→ unsupportedFormat、plist を壊す → malformed。
        var plist = original
        let xmlOffset = Int(original[(kolyOffset + 216)..<(kolyOffset + 224)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        plist.replaceSubrange(xmlOffset..<(xmlOffset + 8), with: Array("<broken>".utf8))
        XCTAssertThrowsError(try ArchiveReader.open(data: plist)) {
            guard case .malformed = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        // 圧縮 chunk の data を壊す → 展開が失敗する（malformed / truncated / checksum）。
        var chunk = original
        for index in 100..<140 { chunk[index] ^= 0xFF }
        XCTAssertThrowsError(try ArchiveReader.open(data: chunk)) {
            switch $0 as? KaitoError {
            case .malformed, .truncated, .unsupportedMethod: break
            default: XCTFail("Unexpected error: \($0)")
            }
        }
        // 上限。
        for (limits, label) in [(ReadLimits(maxEntryCount: 3), "entry count"), (ReadLimits(maxMetadataSize: 2_048), "metadata")] {
            XCTAssertThrowsError(try ArchiveReader.open(data: original, options: ReaderOptions(limits: limits)), label) {
                guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("\(label): \($0)") }
            }
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
