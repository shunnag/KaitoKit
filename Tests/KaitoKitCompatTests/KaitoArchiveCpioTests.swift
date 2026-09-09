import Foundation
import KaitoKitCompat
import XCTest

final class KaitoArchiveCpioTests: XCTestCase {
    func testStableFormatNameForAllWriterVariants() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for name in ["newc", "odc", "bin", "crc", "bcpio", "hpbin", "hpodc"] {
            let text = try String(contentsOf: root.appendingPathComponent("Fixtures/container/\(name).cpio.b64"), encoding: .utf8)
            let data = try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters))
            let archive = try XCTUnwrap(KaitoArchive(data: data))
            XCTAssertEqual(archive.formatName(), "cpio")
            XCTAssertEqual(archive.numberOfEntries(), ["newc", "odc", "bin"].contains(name) ? 5 : 6)
        }
    }
}
