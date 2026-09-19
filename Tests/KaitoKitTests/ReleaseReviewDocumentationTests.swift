import Foundation
import XCTest

final class ReleaseReviewDocumentationTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func testFollowupReviewDocumentsSFXAuxiliaryAndTAZChanges() throws {
        let changelog = try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        let unreleased = try XCTUnwrap(changelog.components(separatedBy: "## [Unreleased]").last?
            .components(separatedBy: "\n## [").first)
        for (item, detail) in [(10, "StuffIt"), (11, "auxiliary"), (12, ".taz")] {
            XCTAssertTrue(unreleased.contains("K\(item)") && unreleased.contains(detail),
                          "Unreleased must document K\(item)")
        }
        let record = try String(contentsOf: root.appendingPathComponent(
            "Documentation/verification/2026-09-19-release-review.md"), encoding: .utf8)
        for item in 10...13 {
            XCTAssertTrue(record.contains("## K\(item)."), "verification record must cover K\(item)")
        }
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        for aliases in readme.components(separatedBy: "\n") where aliases.contains("`.tz` / `.tar.Z`") {
            XCTAssertTrue(aliases.contains("`.taz`"), "compressed-tar alias documentation must include .taz")
        }
    }

    func testReadmeIntroductionsAndIntegrationNotesDocumentFormatsAndSafetyLimits() throws {
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        let introduction = try XCTUnwrap(readme.components(separatedBy: "## SwiftPM").first)
        let introParts = introduction.components(separatedBy: "> **KaitoKit (解凍Kit)**")
        XCTAssertEqual(introParts.count, 2)
        for (language, text) in zip(["Japanese", "English"], introParts) {
            for format in ["LZ4", "LZMA", ".lzma", ".tlz"] {
                XCTAssertTrue(text.contains(format), "\(language) introduction must list \(format)")
            }
        }
        let integration = try XCTUnwrap(readme.components(separatedBy: "## 組み込みの注意").last)
        let integrationParts = integration.components(separatedBy: "> **Integration notes**")
        XCTAssertEqual(integrationParts.count, 2)
        for (language, text) in zip(["Japanese", "English"], integrationParts) {
            for limit in ["stagingFreeSpaceReserve", "maxSevenZipHeaderKDFWork"] {
                XCTAssertTrue(text.contains(limit), "\(language) integration notes must document \(limit)")
            }
        }
    }

    func testReleaseReviewRecordExistsAndIsLinkedFromChangelog() throws {
        let path = "Documentation/verification/2026-09-19-release-review.md"
        let changelog = try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        XCTAssertTrue(changelog.contains(path), "changelog must link the release-review verification record")
        let exists = FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
        XCTAssertTrue(exists, "release-review verification record must exist")
        guard exists else { return }
        let record = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        for item in 1...8 {
            XCTAssertTrue(record.contains("## K\(item)."), "verification record must cover K\(item)")
        }
        XCTAssertTrue(record.contains("RAR4") && record.contains("accepted limitation"))
    }
}
