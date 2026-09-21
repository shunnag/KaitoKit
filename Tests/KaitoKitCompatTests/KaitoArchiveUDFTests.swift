import Foundation
import KaitoKitCompat
import XCTest

final class KaitoArchiveUDFTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Fixtures/udf/\(name).gz.b64"), encoding: .utf8)
        let gzip = try XCTUnwrap(KaitoArchive(data: try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters))))
        return try XCTUnwrap(gzip.contents(ofEntry: 0))
    }

    func testUDFAndHybridImagesNameTheirFormat() throws {
        let pure = try XCTUnwrap(KaitoArchive(data: try fixture("pure150.iso")))
        XCTAssertEqual(pure.formatName(), "UDF")
        XCTAssertEqual(pure.numberOfEntries(), 10)
        let readme = try XCTUnwrap((0..<pure.numberOfEntries()).first { pure.name(ofEntry: $0) == "readme.txt" })
        XCTAssertTrue(pure.entryHasSize(readme))
        XCTAssertEqual(pure.uncompressedSize(ofEntry: readme), 2_880)
        XCTAssertEqual(pure.contents(ofEntry: readme)?.count, 2_880)
        let link = try XCTUnwrap((0..<pure.numberOfEntries()).first { pure.name(ofEntry: $0) == "link-to-readme" })
        XCTAssertTrue(pure.entryIsLink(link))
        XCTAssertTrue(pure.entryIsDirectory(try XCTUnwrap((0..<pure.numberOfEntries()).first { pure.name(ofEntry: $0) == "sub" })))

        // 2.01 image の resource fork stream は `..namedfork/rsrc` entry として見え、compat の
        // `entryIsResourceFork` が true になる。
        let forked = try XCTUnwrap(KaitoArchive(data: try fixture("udf201-512.img")))
        let fork = try XCTUnwrap((0..<forked.numberOfEntries()).first { forked.name(ofEntry: $0) == "forked.txt/..namedfork/rsrc" })
        XCTAssertTrue(forked.entryIsResourceFork(fork))
        XCTAssertFalse(forked.entryIsResourceFork(fork - 1))
        XCTAssertEqual(forked.contents(ofEntry: fork), Data("RSRC-FORK-CONTENT-0123456789".utf8))

        // hybrid は ISO 9660 のまま、名前は UDF の木から。
        let hybrid = try XCTUnwrap(KaitoArchive(data: try fixture("hybrid102.iso")))
        XCTAssertEqual(hybrid.formatName(), "ISO 9660")
        XCTAssertEqual(hybrid.numberOfEntries(), 10)
    }
}
