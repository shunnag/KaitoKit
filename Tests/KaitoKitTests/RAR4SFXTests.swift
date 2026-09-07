import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

final class RAR4SFXTests: XCTestCase {
    private static let archive = URL(
        fileURLWithPath: "/private/tmp/claude-501/-Users-nagash-cooViewer/37ef55f3-9116-4440-88b8-9a15060856ad/scratchpad/rar4-corpus/test_read_format_rar_sfx.exe"
    )

    func testRealSFXPrefixIsBoundedlyLocatedAndExtractsExactly() throws {
        guard FileManager.default.fileExists(atPath: Self.archive.path) else {
            throw XCTSkip("RAR4 SFX corpus is absent")
        }
        try RAR5TestSupport.requireRAR()

        let source = try FileByteSource(url: Self.archive)
        let match = try XCTUnwrap(FormatDetector.findRARSignature(source: source))
        XCTAssertEqual(match.offset, 98_816)
        XCTAssertEqual(match.version, .rar4)
        XCTAssertEqual(try FormatDetector.detect(source: source), .rar)

        let reader = try ArchiveReader.open(url: Self.archive)
        XCTAssertEqual(reader.entries.count, 5)
        for entry in reader.entries where entry.kind != .directory {
            let decoded = try reader.read(entry)
            let oracle = try ZipTestSupport.checkedRun(
                RAR5TestSupport.executablePath,
                arguments: ["p", "-inul", Self.archive.path, entry.name]
            ).standardOutput
            XCTAssertEqual(
                SHA256.hash(data: decoded),
                SHA256.hash(data: oracle),
                "\(entry.index):\(entry.name)"
            )
        }
    }

    func testMarkerBeyondMaximumSFXPrefixIsNotDetected() throws {
        let count = try Checked.toInt(FormatDetector.maximumRARSFXSize + 1)
        var bytes = [UInt8](repeating: 0, count: count)
        bytes.append(contentsOf: RAR4Reader.signature)
        let source = DataByteSource(data: Data(bytes))
        XCTAssertNil(try FormatDetector.findRARSignature(source: source))
    }
}
