import Foundation
import KaitoKit
import KaitoKitCompat
import XCTest

final class KaitoArchiveCHMTests: XCTestCase {
    func testCHMNamesItsFormatAndReadsCompressedFiles() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Fixtures/chm/basic.chm.gz.b64"), encoding: .utf8)
        let gzip = try ArchiveReader.open(data: try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters)))
        let archive = try XCTUnwrap(KaitoArchive(data: try gzip.read(gzip.entries[0])))
        XCTAssertEqual(archive.formatName(), "CHM")
        XCTAssertEqual(archive.numberOfEntries(), 15)
        let topics = try XCTUnwrap((0..<archive.numberOfEntries()).first { archive.name(ofEntry: $0) == "topics" })
        XCTAssertTrue(archive.entryIsDirectory(topics))
        let style = try XCTUnwrap((0..<archive.numberOfEntries()).first { archive.name(ofEntry: $0) == "style.css" })
        XCTAssertEqual(archive.contents(ofEntry: style), Data(String(repeating: "body { font-family: sans-serif; }\n", count: 40).utf8))
        let japanese = try XCTUnwrap((0..<archive.numberOfEntries()).first { archive.name(ofEntry: $0) == "日本語/目次.htm" })
        XCTAssertEqual(archive.uncompressedSize(ofEntry: japanese), 4227)
    }
}
