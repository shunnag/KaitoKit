import Foundation
import XCTest

final class ReleaseReviewDocumentationTests: XCTestCase {
    func testRelease081DocumentsAllFourteenReviewFixes() throws {
        let changelog = try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        let sections = changelog.components(separatedBy: "## [0.8.1] - 2026-09-22")
        XCTAssertEqual(sections.count, 2, "0.8.1 節が必要")
        guard sections.count == 2 else { return }
        let release = try XCTUnwrap(sections.last?.components(separatedBy: "\n## [").first)
        let path = "Documentation/verification/2026-09-22-release-review-0.8.1.md"
        let record = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        for item in 1...14 {
            XCTAssertTrue(release.contains("- R\(item)."), "0.8.1 に R\(item) の説明が必要")
            XCTAssertTrue(record.contains("## R\(item)."), "検証記録に R\(item) の見出しが必要")
        }
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(readme.contains(path), "README から検証記録へリンクする")
        XCTAssertTrue(changelog.contains(path), "変更履歴から検証記録へリンクする")
    }

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func testFollowupReviewDocumentsSFXAuxiliaryAndTAZChanges() throws {
        let changelog = try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        let release = try XCTUnwrap(changelog.components(separatedBy: "## [0.7.0]").last?
            .components(separatedBy: "\n## [").first)
        for (item, detail) in [(10, "StuffIt"), (11, "auxiliary"), (12, ".taz")] {
            XCTAssertTrue(release.contains("K\(item)") && release.contains(detail),
                          "0.7.0 must document K\(item)")
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
