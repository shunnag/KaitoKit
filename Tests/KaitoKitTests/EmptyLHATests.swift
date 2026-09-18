import Foundation
import XCTest
@testable import KaitoKit

final class EmptyLHATests: XCTestCase {
    func testSingleTerminatorNeedsLHAFileNameAndReopensWithoutPath() throws {
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for suffix in ["lha", "lzh", "LHA", "LZH"] {
            let url = directory.appendingPathComponent("empty." + suffix)
            try Data([0]).write(to: url)
            XCTAssertEqual(try FormatDetector.detect(url: url), .lha)
            let reader = try ArchiveReader.open(url: url)
            XCTAssertEqual(reader.format, .lha)
            XCTAssertTrue(reader.entries.isEmpty)
            try FileManager.default.removeItem(at: url)
            let reopened = try reader.reopen()
            XCTAssertEqual(reopened.format, .lha)
            XCTAssertTrue(reopened.entries.isEmpty)
        }
    }

    func testHintDoesNotAcceptOtherShortInputsOrOverrideContent() throws {
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("empty.lzh")
        for bytes: [UInt8] in [[], [1], [0, 0], [0, 1], Array(repeating: 0, count: 1_024)] {
            try Data(bytes).write(to: url)
            XCTAssertThrowsError(try FormatDetector.detect(url: url), "\(bytes.count) bytes")
            XCTAssertThrowsError(try ArchiveReader.open(url: url), "\(bytes.count) bytes")
        }
        for name in ["empty", "empty.bin", "empty.lz", "empty.lzh.bak"] {
            let unhinted = directory.appendingPathComponent(name)
            try Data([0]).write(to: unhinted)
            XCTAssertThrowsError(try FormatDetector.detect(url: unhinted))
            XCTAssertThrowsError(try ArchiveReader.open(url: unhinted))
        }
        XCTAssertThrowsError(try FormatDetector.detect(data: Data([0])))
        XCTAssertThrowsError(try ArchiveReader.open(data: Data([0])))
        try Data([0x50, 0x4b, 3, 4]).write(to: url)
        XCTAssertEqual(try FormatDetector.detect(url: url), .zip)
    }
}
