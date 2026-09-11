// Linux Standard Base「Package File Format」、rpm(8)、rpm.org の prose、
// RFC 1950/1951/1952 を許可資料とする利用者提供の実測 byte 表と固定 fixture に基づく検証。
// rpm / libarchive / 7-Zip / XADMaster / The Unarchiver / dpkg 等、他の実装 source は参照していない。
import Foundation
import KaitoKitCompat
import XCTest

final class KaitoArchiveRpmTests: XCTestCase {
    func testZstdFormatNameForStandaloneStream() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Fixtures/zstd/one-l3.zst.b64"), encoding: .utf8)
        let bytes = try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters))
        let archive = try XCTUnwrap(KaitoArchive(data: bytes))
        XCTAssertEqual(archive.formatName(), "Zstandard")
        XCTAssertEqual(archive.numberOfEntries(), 1)
    }

    func testStableFormatNameForEveryFixture() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for (variant, count) in [("gzip", 6), ("xz", 6), ("bzip2", 6), ("none", 6), ("src", 1), ("zstd", 6), ("v6", 1)] {
            let text = try String(contentsOf: root.appendingPathComponent("Fixtures/container/rpm-\(variant).rpm.b64"), encoding: .utf8)
            let bytes = try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters))
            let archive = try XCTUnwrap(KaitoArchive(data: bytes))
            XCTAssertEqual(archive.formatName(), "RPM", variant)
            XCTAssertEqual(archive.numberOfEntries(), Int32(count), variant)
        }
    }
}
