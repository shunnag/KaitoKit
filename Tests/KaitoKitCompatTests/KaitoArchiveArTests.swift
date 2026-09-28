import Foundation
import KaitoKitCompat
import XCTest

final class KaitoArchiveArTests: XCTestCase {
    func testStableFormatNameWithSymbolsAndHiddenStringTable() throws {
        for (name, count) in [("lib", 2), ("ar-symtab", 3), ("ar-sysv", 5), ("ar-deb", 3)] {
            let data = try CompatFixtures.base64("container/\(name).a")
            let archive = try XCTUnwrap(KaitoArchive(data: data))
            XCTAssertEqual(archive.formatName(), "AR")
            XCTAssertEqual(archive.numberOfEntries(), Int32(count))
        }
    }
}
