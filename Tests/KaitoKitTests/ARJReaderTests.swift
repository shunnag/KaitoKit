import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

/// ARJ。fixture は Tests/Fixtures/arj（自作 writer + lh6 互換 encoder、7-Zip / deark / unar が同じ内容に展開）。
final class ARJReaderTests: XCTestCase {
    func testR1ShortCRCValidMainHeaderDoesNotCrash() throws {
        let bytes = Data([0x60, 0xEA, 1, 0, 0, 0x8D, 0xEF, 2, 0xD2])
        XCTAssertThrowsError(try FormatDetector.detect(data: bytes)) {
            XCTAssertEqual($0 as? KaitoError, .unsupportedFormat)
        }
        XCTAssertThrowsError(try ArchiveReader.open(data: bytes)) {
            XCTAssertEqual($0 as? KaitoError, .unsupportedFormat)
        }
    }

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private struct Payload: Decodable { let size: UInt64; let sha256: String }
    private static func manifest() throws -> [String: Payload] {
        let data = try Data(contentsOf: root.appendingPathComponent("Fixtures/arj/manifest.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try JSONDecoder().decode([String: Payload].self, from: JSONSerialization.data(withJSONObject: object["payload"] as Any))
    }
    private static func fixture(_ name: String) throws -> Data { try ZipTestSupport.checkedInFixture("arj/\(name)") }
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static let names = ["README.TXT", "DATA/TABLE.BIN", "DATA/SUB/DEEP.TXT", "EMPTY.TXT", "STORED.BIN", "日本語.TXT"]

    func testFixturesMatchTheIndependentReaders() throws {
        let payload = try Self.manifest()
        for name in ["basic.arj", "backslash.arj", "sfx.exe", "nodata.arj"] {
            let bytes = try Self.fixture(name)
            // Data からの SFX 走査は opt-in（URL open は既定で走査する）。
            let options = ReaderOptions(scanForSFXInData: name.hasSuffix(".exe"))
            XCTAssertEqual(try FormatDetector.detect(data: bytes, options: options), .arj, name)
            let reader = try ArchiveReader.open(data: bytes, options: options)
            XCTAssertEqual(reader.format, .arj, name)
            XCTAssertEqual(reader.nameEncoding, .shiftJIS, name)
            XCTAssertEqual(reader.entries.filter { $0.kind == .directory }.map(\.name), ["DATA", "DATA/SUB"], name)
            let files = reader.entries.filter { $0.kind == .file }
            XCTAssertEqual(files.map(\.name), Self.names + (name == "nodata.arj" ? ["NODATA.TXT"] : []), name)
            for entry in files {
                let want = payload[entry.name] ?? Payload(size: 0, sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
                XCTAssertEqual(entry.uncompressedSize, want.size, "\(name): \(entry.name)")
                XCTAssertEqual(sha(try reader.read(entry)), want.sha256, "\(name): \(entry.name)")
                let expectedMethod = entry.name == "STORED.BIN" || entry.name == "EMPTY.TXT" ? "stored"
                    : entry.name == "NODATA.TXT" ? "no data" : "compressed most"
                XCTAssertEqual(entry.methodDescription, expectedMethod, "\(name): \(entry.name)")
                XCTAssertEqual(entry.formatSpecific["hostOS"], "MS-DOS", entry.name)
                XCTAssertNotNil(entry.modificationDate, entry.name)
                XCTAssertFalse(entry.isEncrypted, entry.name)
            }
            // 30 KB の file は 26 KB の窓をまたぐ。小さな buffer で読む。
            let table = try XCTUnwrap(files.first { $0.name == "DATA/TABLE.BIN" })
            let stream = try reader.stream(table)
            var result = Data(), buffer = [UInt8](repeating: 0, count: 777)
            while true {
                let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
                if count == 0 { break }
                result.append(contentsOf: buffer.prefix(count))
            }
            XCTAssertEqual(sha(result), payload["DATA/TABLE.BIN"]?.sha256, name)
            let reopened = try reader.reopen()
            XCTAssertEqual(reopened.entries, reader.entries, name)
        }
        // SFX は URL から開くと data 走査の opt-in 無しでも検出される。
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sfx.exe")
        try Self.fixture("sfx.exe").write(to: url)
        XCTAssertEqual(try FormatDetector.detect(url: url), .arj)
        XCTAssertEqual(try ArchiveReader.open(url: url).entries.count, 8)
        XCTAssertThrowsError(try FormatDetector.detect(data: Self.fixture("sfx.exe"))) { XCTAssertEqual($0 as? KaitoError, .unsupportedFormat) }
    }

    func testGarbledFilesAreListedAsEncryptedAndRefused() throws {
        let reader = try ArchiveReader.open(data: try Self.fixture("garbled.arj"))
        let readme = try XCTUnwrap(reader.entries.first { $0.name == "README.TXT" })
        XCTAssertTrue(readme.isEncrypted)
        XCTAssertThrowsError(try ArchiveReader.open(data: try Self.fixture("garbled.arj"), options: ReaderOptions(password: "x")).read(readme)) {
            guard case .unsupportedMethod = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        let table = try XCTUnwrap(reader.entries.first { $0.name == "DATA/TABLE.BIN" })
        XCTAssertEqual(try reader.read(table).count, 30_000)
    }

    func testDamagedArchivesAreRejected() throws {
        let original = try Self.fixture("basic.arj")
        // main header の CRC が合わない → 検出も open も外れる。
        var crc = original; crc[6] ^= 0xFF
        XCTAssertThrowsError(try ArchiveReader.open(data: crc)) { XCTAssertEqual($0 as? KaitoError, .unsupportedFormat) }
        // 2 つ目の header の CRC を壊す → malformed。
        let mainSize = Int(original[2]) | Int(original[3]) << 8
        let second = 4 + mainSize + 4 + 2
        var fileCRC = original; fileCRC[second + 4 + 1] ^= 0xFF
        XCTAssertThrowsError(try ArchiveReader.open(data: fileCRC)) {
            guard case .malformed = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        // 末尾の切り詰め: 最後の file の本文が欠ける → open が truncated。
        XCTAssertThrowsError(try ArchiveReader.open(data: original.prefix(original.count - 30))) {
            XCTAssertEqual($0 as? KaitoError, .truncated)
        }
        // 圧縮 stream のビット反転 → CRC 不一致か malformed。
        let reader = try ArchiveReader.open(data: original)
        let readme = try XCTUnwrap(reader.entries.first { $0.name == "README.TXT" })
        var flipped = original
        let nameRange = try XCTUnwrap(original.range(of: Data("README.TXT\0".utf8)))
        let payloadStart = nameRange.upperBound + 1 + 4 + 2          // comment terminator, header CRC, extended size 0
        flipped[payloadStart + 40] ^= 0x55
        let damaged = try ArchiveReader.open(data: flipped)
        XCTAssertThrowsError(try damaged.read(damaged.entries[readme.index])) {
            switch $0 as? KaitoError {
            case .checksumMismatch, .malformed, .truncated: break
            default: XCTFail("Unexpected error: \($0)")
            }
        }
        // 上限: entry 数。
        XCTAssertThrowsError(try ArchiveReader.open(data: original, options: ReaderOptions(limits: ReadLimits(maxEntryCount: 2)))) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        // 未対応 method 4 は一覧できるが読めない。
        var method4 = original
        let readmeHeader = nameRange.lowerBound - 30          // first_hdr_size 30: method byte は header 先頭から 4 + 5
        method4[readmeHeader + 5] = 4
        // header CRC を再計算する（basic header = first_hdr_size .. comment）。
        let basicStart = readmeHeader, basicSize = Int(original[readmeHeader - 2]) | Int(original[readmeHeader - 1]) << 8
        var checksum = CRC32(); checksum.update([UInt8](method4[basicStart..<(basicStart + basicSize)]))
        withUnsafeBytes(of: checksum.value.littleEndian) { method4.replaceSubrange((basicStart + basicSize)..<(basicStart + basicSize + 4), with: $0) }
        let m4 = try ArchiveReader.open(data: method4)
        let entry = try XCTUnwrap(m4.entries.first { $0.name == "README.TXT" })
        XCTAssertEqual(entry.methodDescription, "compressed fastest")
        XCTAssertThrowsError(try m4.read(entry)) {
            guard case .unsupportedMethod = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func testDOSDates() {
        // 2001-09-18 12:34:56 = (21 << 25) | (9 << 21) | (18 << 16) | (12 << 11) | (34 << 5) | 28
        let date = ARJReader.dosDate((21 << 25) | (9 << 21) | (18 << 16) | (12 << 11) | (34 << 5) | 28)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date ?? Date(timeIntervalSince1970: 0))
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second], [2001, 9, 18, 12, 34, 56])
        XCTAssertNil(ARJReader.dosDate(0))
        XCTAssertNil(ARJReader.dosDate(13 << 21))
    }
}
