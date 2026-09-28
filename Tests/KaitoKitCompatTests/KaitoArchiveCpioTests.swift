import Foundation
import KaitoKitCompat
import XCTest

final class KaitoArchiveCpioTests: XCTestCase {
    func testStableFormatNameForAllWriterVariants() throws {
        for name in ["newc", "odc", "bin", "crc", "bcpio", "hpbin", "hpodc"] {
            let data = try CompatFixtures.base64("container/\(name).cpio")
            let archive = try XCTUnwrap(KaitoArchive(data: data))
            XCTAssertEqual(archive.formatName(), "Cpio")
            XCTAssertEqual(archive.numberOfEntries(), ["newc", "odc", "bin"].contains(name) ? 5 : 6)
        }
    }
}
