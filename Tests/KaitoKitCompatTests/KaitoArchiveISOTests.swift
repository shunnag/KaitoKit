import Foundation
import KaitoKit
import KaitoKitCompat
import XCTest

final class KaitoArchiveISOTests: XCTestCase {
    func testISOFormatName() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/iso/joliet.iso.gz.b64")
        let text = try String(contentsOf: url, encoding: .utf8)
        let compressed = try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters))
        let gzip = try ArchiveReader.open(data: compressed)
        let iso = try gzip.read(gzip.entries[0])
        let archive = try XCTUnwrap(KaitoArchive(data: iso))
        XCTAssertEqual(archive.formatName(), "ISO 9660")
        XCTAssertEqual(archive.numberOfEntries(), 5)
    }
}
