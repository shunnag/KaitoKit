import Foundation
import KaitoKitCompat
import XCTest

final class KaitoArchiveMacWrapperTests: XCTestCase {
    func testWrapperFormatsNameThemselvesAndExposeTheResourceFork() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for (file, formatName) in [("readme.txt.bin", "MacBinary"), ("readme.txt.as", "AppleSingle"), ("readme.txt.hqx", "BinHex")] {
            let text = try String(contentsOf: root.appendingPathComponent("Fixtures/macwrappers/\(file).b64"), encoding: .utf8)
            let archive = try XCTUnwrap(KaitoArchive(data: try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters))), file)
            XCTAssertEqual(archive.formatName(), formatName, file)
            XCTAssertEqual(archive.numberOfEntries(), 2, file)
            XCTAssertEqual(archive.name(ofEntry: 0), "readme.txt", file)
            XCTAssertFalse(archive.entryIsResourceFork(0), file)
            XCTAssertTrue(archive.entryIsResourceFork(1), file)
            XCTAssertEqual(archive.uncompressedSize(ofEntry: 0), 823, file)
            XCTAssertEqual(archive.contents(ofEntry: 1)?.count, 416, file)
        }
    }
}
