import Foundation
import KaitoKitCompat
import XCTest

/// Finder 製 ZIP の `__MACOSX/._name` は既定で畳まれ、resource fork は fork entry として見える。
final class KaitoArchiveAppleDoubleTests: XCTestCase {
    func testFinderZipListsNoMACOSXEntriesAndExposesResourceForks() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Fixtures/appledouble/finder.zip.b64"), encoding: .utf8)
        let archive = try XCTUnwrap(KaitoArchive(data: try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters))))
        XCTAssertEqual(archive.formatName(), "Zip")
        let names = (0..<archive.numberOfEntries()).compactMap { archive.name(ofEntry: $0) }
        XCTAssertFalse(names.contains { $0.hasPrefix("__MACOSX") })
        let fork = try XCTUnwrap((0..<archive.numberOfEntries()).first { archive.name(ofEntry: $0) == "folder/rsrc.txt/..namedfork/rsrc" })
        XCTAssertTrue(archive.entryIsResourceFork(fork))
        XCTAssertFalse(archive.entryIsResourceFork(fork - 1))
        XCTAssertEqual(archive.contents(ofEntry: fork), Data("RSRC-DATA-1234\n".utf8))
    }
}
