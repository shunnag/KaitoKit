import Foundation
import KaitoKit
import KaitoKitCompat
import XCTest

final class KaitoArchiveDMGTests: XCTestCase {
    func testDiskImageNamesItsFormatAndReadsTheHFSVolume() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Fixtures/dmg/hfs-zlib.dmg.gz.b64"), encoding: .utf8)
        let gzip = try ArchiveReader.open(data: try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters)))
        let archive = try XCTUnwrap(KaitoArchive(data: try gzip.read(gzip.entries[0])))
        XCTAssertEqual(archive.formatName(), "Apple Disk Image")
        XCTAssertEqual(archive.numberOfEntries(), 15)
        let sub = try XCTUnwrap((0..<archive.numberOfEntries()).first { archive.name(ofEntry: $0) == "sub" })
        XCTAssertTrue(archive.entryIsDirectory(sub))
        let readme = try XCTUnwrap((0..<archive.numberOfEntries()).first { archive.name(ofEntry: $0) == "readme.txt" })
        XCTAssertEqual(archive.contents(ofEntry: readme), Data("hello dmg\n".utf8))
        let fork = try XCTUnwrap((0..<archive.numberOfEntries()).first { archive.name(ofEntry: $0) == "readme.txt/..namedfork/rsrc" })
        XCTAssertTrue(archive.entryIsResourceFork(fork))
        XCTAssertEqual(archive.contents(ofEntry: fork), Data("RSRC-FORK-0123456789".utf8))
        let link = try XCTUnwrap((0..<archive.numberOfEntries()).first { archive.name(ofEntry: $0) == "link-to-nested" })
        XCTAssertTrue(archive.entryIsLink(link))
    }
}
