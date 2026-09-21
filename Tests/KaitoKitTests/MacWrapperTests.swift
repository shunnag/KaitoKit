import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

/// MacBinary / AppleSingle / BinHex 4 の wrapper を、payload が StuffIt でないとき 1 file の書庫として公開する。
/// fixture は Tests/Fixtures/macwrappers（自作 writer、The Unarchiver の lsar / unar で fork まで照合）。
final class MacWrapperTests: XCTestCase {
    private static func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/macwrappers/\(name).b64")
        return try XCTUnwrap(Data(base64Encoded: try String(contentsOf: url, encoding: .utf8), options: .ignoreUnknownCharacters))
    }
    private struct Payload: Decodable { let size: UInt64; let sha256: String }
    private struct Manifest: Decodable { let data: Payload; let resource: Payload }
    private static func manifest() throws -> Manifest {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/macwrappers/manifest.json")
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func testWrappersExposeDataAndResourceForks() throws {
        let manifest = try Self.manifest()
        let data = manifest.data, resource = manifest.resource
        let cases: [(file: String, format: ArchiveFormat, name: String, method: String, forks: Int)] = [
            ("readme.txt.bin", .macBinary, "readme.txt", "MacBinary (stored)", 2),
            ("kanji.bin", .macBinary, "テスト.txt", "MacBinary (stored)", 2),
            ("readme.txt.as", .appleSingle, "readme.txt", "AppleSingle (stored)", 2),
            ("readme-le.txt.as", .appleSingle, "readme.txt", "AppleSingle (stored)", 2),
            ("readme.txt.hqx", .binHex, "readme.txt", "BinHex 4.0 (RLE90)", 2),
            ("noresource.bin", .macBinary, "plain.txt", "MacBinary (stored)", 1),
        ]
        for item in cases {
            let bytes = try Self.fixture(item.file)
            XCTAssertEqual(try FormatDetector.detect(data: bytes), item.format, item.file)
            let reader = try ArchiveReader.open(data: bytes)
            XCTAssertEqual(reader.format, item.format, item.file)
            XCTAssertEqual(reader.entries.count, item.forks, item.file)
            let main = reader.entries[0]
            XCTAssertEqual(main.name, item.name, item.file)
            XCTAssertEqual(main.kind, .file, item.file)
            XCTAssertEqual(main.uncompressedSize, data.size, item.file)
            XCTAssertEqual(main.methodDescription, item.method, item.file)
            XCTAssertEqual(main.formatSpecific["fork"], "data", item.file)
            XCTAssertEqual(main.formatSpecific["wrapper"], item.format == .macBinary ? "macBinary" : (item.format == .appleSingle ? "appleSingle" : "binHex"), item.file)
            XCTAssertEqual(main.formatSpecific["macType"], "TEXT", item.file)
            XCTAssertEqual(main.formatSpecific["macCreator"], "ttxt", item.file)
            XCTAssertEqual(sha(try reader.read(main)), data.sha256, item.file)
            if item.forks == 2 {
                let fork = reader.entries[1]
                XCTAssertEqual(fork.name, item.name + "/..namedfork/rsrc", item.file)
                XCTAssertEqual(fork.formatSpecific["fork"], "resource", item.file)
                XCTAssertEqual(fork.uncompressedSize, resource.size, item.file)
                XCTAssertEqual(sha(try reader.read(fork)), resource.sha256, item.file)
            }
            // MacBinary / AppleSingle は作成・更新日時（1904 起点 / 2000 起点）を持ち、BinHex は持たない。
            if item.format == .binHex {
                XCTAssertNil(main.modificationDate, item.file)
            } else {
                XCTAssertEqual(main.modificationDate, Date(timeIntervalSince1970: 3_650_000_000 - 2_082_844_800), item.file)
                XCTAssertEqual(main.formatSpecific["created"], ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 3_600_000_000 - 2_082_844_800)), item.file)
            }
            let reopened = try reader.reopen()
            XCTAssertEqual(reopened.entries, reader.entries, item.file)
        }
        // Shift_JIS の名前は書庫名判定で復元される。
        XCTAssertEqual(try ArchiveReader.open(data: try Self.fixture("kanji.bin")).nameEncoding, .shiftJIS)
    }

    func testExtractionRestoresTheResourceFork() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let reader = try ArchiveReader.open(data: try Self.fixture("readme.txt.bin"))
        for entry in reader.entries { _ = try reader.extract(entry, to: temporary) }
        let manifest = try Self.manifest()
        XCTAssertEqual(sha(try Data(contentsOf: temporary.appendingPathComponent("readme.txt"))), manifest.data.sha256)
        XCTAssertEqual(sha(try Data(contentsOf: temporary.appendingPathComponent("readme.txt/..namedfork/rsrc"))), manifest.resource.sha256)
    }

    func testStuffItPayloadsStillOpenAsStuffItAndNamesFallBackToTheFileName() throws {
        // 既存 corpus の MacBinary / AppleSingle / BinHex wrapper は payload が StuffIt なので従来どおり。
        let corpus = StuffItCorpusTests()
        for name in ["testfile.stuffit45_dlx.mac9.sit.bin", "testfile.stuffit45_dlx.mac9.sit.AS"] {
            XCTAssertEqual(try ArchiveReader.open(data: try corpus.fixture(name)).format, .stuffIt, name)
        }
        // Real Name entry の無い AppleSingle は file 名から拡張子を外して名付ける。
        var bytes = [UInt8](try Self.fixture("readme.txt.as"))
        // entry 表の Real Name（id 3）を id 0 に変えて無効化する。
        for offset in stride(from: 26, to: 26 + 12 * 5, by: 12) where bytes[offset + 3] == 3 && bytes[offset] == 0 { bytes[offset + 3] = 0 }
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let url = temporary.appendingPathComponent("archive.as")
        try Data(bytes).write(to: url)
        XCTAssertEqual(try ArchiveReader.open(url: url).entries[0].name, "archive")
        XCTAssertEqual(try ArchiveReader.open(data: Data(bytes)).entries[0].name, "data")
    }

    func testDamagedWrappersAreRejected() throws {
        // MacBinary: CRC を壊し、fallback の零検査も通らないようにする（version byte を非零に）。
        var macBinary = [UInt8](try Self.fixture("readme.txt.bin"))
        macBinary[124] ^= 0xFF
        macBinary[100] = 1
        XCTAssertThrowsError(try ArchiveReader.open(data: Data(macBinary)))
        // AppleSingle: descriptor が file の外を指す。
        var appleSingle = [UInt8](try Self.fixture("readme.txt.as"))
        appleSingle[26 + 4] = 0x7F      // entry 0 の offset を file の外へ
        XCTAssertThrowsError(try ArchiveReader.open(data: Data(appleSingle))) {
            guard case .malformed = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        // BinHex: 本文の 1 文字を変えると fork CRC が合わない。
        var binHex = [UInt8](try Self.fixture("readme.txt.hqx"))
        let colon = try XCTUnwrap(binHex.firstIndex(of: UInt8(ascii: ":")))
        binHex[colon + 40] = binHex[colon + 40] == UInt8(ascii: "!") ? UInt8(ascii: "\"") : UInt8(ascii: "!")
        XCTAssertThrowsError(try ArchiveReader.open(data: Data(binHex))) {
            guard case .malformed = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        // 上限: data fork が maxEntrySize を超える。
        XCTAssertThrowsError(try ArchiveReader.open(data: try Self.fixture("readme.txt.bin"), options: ReaderOptions(limits: ReadLimits(maxEntrySize: 100)))) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
    }
}
