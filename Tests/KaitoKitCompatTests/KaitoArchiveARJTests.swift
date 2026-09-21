import Foundation
import KaitoKit
import KaitoKitCompat
import XCTest

final class KaitoArchiveARJTests: XCTestCase {
    func testARJNamesItsFormatAndReadsCompressedMembers() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Fixtures/arj/basic.arj.b64"), encoding: .utf8)
        let archive = try XCTUnwrap(KaitoArchive(data: try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters))))
        XCTAssertEqual(archive.formatName(), "ARJ")
        XCTAssertEqual(archive.numberOfEntries(), 8)
        let data = try XCTUnwrap((0..<archive.numberOfEntries()).first { archive.name(ofEntry: $0) == "DATA" })
        XCTAssertTrue(archive.entryIsDirectory(data))
        let deep = try XCTUnwrap((0..<archive.numberOfEntries()).first { archive.name(ofEntry: $0) == "DATA/SUB/DEEP.TXT" })
        XCTAssertEqual(archive.contents(ofEntry: deep), Data(String(repeating: "deep\r\n", count: 50).utf8))
        let japanese = try XCTUnwrap((0..<archive.numberOfEntries()).first { archive.name(ofEntry: $0) == "日本語.TXT" })
        XCTAssertEqual(archive.uncompressedSize(ofEntry: japanese), 1_400)
    }
}
