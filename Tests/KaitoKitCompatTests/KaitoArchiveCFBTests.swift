import Foundation
import KaitoKit
import KaitoKitCompat
import XCTest

final class KaitoArchiveCFBTests: XCTestCase {
    func testCompoundFileNamesItsFormatAndListsStoragesAsDirectories() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Fixtures/cfb/v3.cfb.gz.b64"), encoding: .utf8)
        let gzip = try ArchiveReader.open(data: try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters)))
        let archive = try XCTUnwrap(KaitoArchive(data: try gzip.read(gzip.entries[0])))
        XCTAssertEqual(archive.formatName(), "Compound File")
        XCTAssertEqual(archive.numberOfEntries(), 14)
        let storage = try XCTUnwrap((0..<archive.numberOfEntries()).first { archive.name(ofEntry: $0) == "Storage One" })
        XCTAssertTrue(archive.entryIsDirectory(storage))
        let inner = try XCTUnwrap((0..<archive.numberOfEntries()).first { archive.name(ofEntry: $0) == "Storage One/inner.txt" })
        XCTAssertEqual(archive.contents(ofEntry: inner), Data("nested stream\n".utf8))
        let summary = try XCTUnwrap((0..<archive.numberOfEntries()).first { archive.name(ofEntry: $0) == "[5]SummaryInformation" })
        XCTAssertEqual(archive.uncompressedSize(ofEntry: summary), 100)
    }
}
