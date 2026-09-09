// Microsoft [MS-CAB]、RFC 1951、zlib manual と利用者提供の実測 byte 表・固定 fixture に基づく検証。
// 他の archiver の実装 source は開かず、参照・引用していない。
import Foundation
import KaitoKitCompat
import XCTest

final class KaitoArchiveCabTests: XCTestCase {
    func testStableFormatNameForEveryFixture() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for (variant, count) in [("stored", 6), ("mszip", 6), ("reserve", 6), ("next", 6), ("multiblock", 2), ("utf8", 2)] {
            let text = try String(contentsOf: root.appendingPathComponent("Fixtures/container/cab-\(variant).cab.b64"), encoding: .utf8)
            let bytes = try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters))
            let archive = try XCTUnwrap(KaitoArchive(data: bytes))
            XCTAssertEqual(archive.formatName(), "CAB", variant)
            XCTAssertEqual(archive.numberOfEntries(), Int32(count), variant)
        }
    }
}
