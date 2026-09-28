import Foundation
import KaitoKitCompat
import XCTest

final class KaitoArchiveWIMTests: XCTestCase {
    func testFormatNameAndEntries() throws {
        let archive = try XCTUnwrap(KaitoArchive(data: try CompatFixtures.base64("wim/lzx.wim")))
        XCTAssertEqual(archive.formatName(), "WIM")
        XCTAssertEqual(archive.numberOfEntries(), 6)
        let text56 = try XCTUnwrap((0..<archive.numberOfEntries()).first { archive.name(ofEntry: $0) == "text.txt" })
        XCTAssertTrue(archive.entryHasSize(text56))
        XCTAssertEqual(archive.uncompressedSize(ofEntry: text56), 56_270)
        XCTAssertEqual(archive.contents(ofEntry: text56)?.count, 56_270)
        XCTAssertTrue(archive.entryIsDirectory(try XCTUnwrap((0..<archive.numberOfEntries()).first { archive.name(ofEntry: $0) == "sub" })))
    }
}
