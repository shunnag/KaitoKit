import Foundation
import KaitoKitCompat
import XCTest

final class KaitoArchiveArTests: XCTestCase {
    func testStableFormatNameWithSymbolsAndHiddenStringTable() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for (name, count) in [("lib", 2), ("ar-symtab", 3), ("ar-sysv", 5), ("ar-deb", 3)] {
            let text = try String(contentsOf: root.appendingPathComponent("Fixtures/container/\(name).a.b64"), encoding: .utf8)
            let data = try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters))
            let archive = try XCTUnwrap(KaitoArchive(data: data))
            XCTAssertEqual(archive.formatName(), "AR")
            XCTAssertEqual(archive.numberOfEntries(), Int32(count))
        }
    }
}
