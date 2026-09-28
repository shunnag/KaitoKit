import Foundation
import KaitoKit
import KaitoKitCompat
import XCTest

final class KaitoArchiveCFBTests: XCTestCase {
    func testCompoundFileNamesItsFormatAndListsStoragesAsDirectories() throws {
        let archive = try XCTUnwrap(KaitoArchive(data: try CompatFixtures.gzipBase64("cfb/v3.cfb")))
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
