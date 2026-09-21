import Foundation
import KaitoKitCompat
import XCTest

final class KaitoArchiveWIMTests: XCTestCase {
    func testFormatNameAndEntries() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Fixtures/wim/lzx.wim.b64"), encoding: .utf8)
        let archive = try XCTUnwrap(KaitoArchive(data: try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters))))
        XCTAssertEqual(archive.formatName(), "WIM")
        XCTAssertEqual(archive.numberOfEntries(), 6)
        let text56 = try XCTUnwrap((0..<archive.numberOfEntries()).first { archive.name(ofEntry: $0) == "text.txt" })
        XCTAssertTrue(archive.entryHasSize(text56))
        XCTAssertEqual(archive.uncompressedSize(ofEntry: text56), 56_270)
        XCTAssertEqual(archive.contents(ofEntry: text56)?.count, 56_270)
        XCTAssertTrue(archive.entryIsDirectory(try XCTUnwrap((0..<archive.numberOfEntries()).first { archive.name(ofEntry: $0) == "sub" })))
    }
}
