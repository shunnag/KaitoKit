import Foundation
import XCTest

final class ReleaseReviewDocumentationTests: XCTestCase {
    private func document(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func release090() throws -> String {
        try XCTUnwrap(document("CHANGELOG.md").components(separatedBy: "## [0.9.0] - 2026-09-22").last?
            .components(separatedBy: "\n## [").first)
    }

    func testRelease090DocumentsAllElevenReviewFixes() throws {
        let release = try release090()
        let path = "Documentation/verification/2026-09-22-release-review-0.9.0.md"
        for item in 1...11 { XCTAssertTrue(release.contains("- R\(item)."), "0.9.0 に R\(item) の説明が必要") }
        for name in ["README.md", "CHANGELOG.md"] {
            XCTAssertTrue(try document(name).contains(path), "\(name) から検証記録へリンクする")
        }
        let index = try document("Documentation/verification/README.md")
        let row = try XCTUnwrap(index.components(separatedBy: "\n").first { $0.contains("2026-09-22-release-review-0.9.0.md") })
        XCTAssertTrue(row.contains("v0.9.0"))
        let record = try document(path)
        for item in 1...11 {
            let section = try XCTUnwrap(record.components(separatedBy: "## R\(item).").dropFirst().first?
                .components(separatedBy: "\n## ").first, "検証記録に R\(item) の見出しが必要")
            for label in ["再現", "原因", "修正", "回帰テスト"] { XCTAssertTrue(section.contains(label), "R\(item): \(label)") }
        }
    }

    func testR4ReviewChangelogExplainsNonGNUMagicErrorClass() throws {
        let bullet = try XCTUnwrap(release090().components(separatedBy: "\n").first { $0.hasPrefix("- tar ") })
        for text in ["非 GNU", "`S`", "unsupportedMethod(\"GNU tar sparse entries\")", "malformed"] {
            XCTAssertTrue(bullet.contains(text), "tar の変更履歴に \(text) が必要")
        }
    }

    func testR8ReviewReleasedDMGRecordPointsToDecmpfsFollowup() throws {
        let record = try document("Documentation/verification/2026-09-22-dmg.md")
        XCTAssertTrue(record.contains("2026-09-22-hfsplus-decmpfs.md"), "旧記録から decmpfs 追補へリンクする")
        XCTAssertTrue(record.contains("v0.8.0"), "旧記録の時点を明記する")
        XCTAssertTrue(record.contains("HFS+ compressed (decmpfs)"), "当時の記録は残す")
    }

    func testR9ReviewEnglishTarSupportIncludesOldGNU() throws {
        let readme = try document("README.md")
        let row = try XCTUnwrap(readme.components(separatedBy: "> - **tar**:").dropFirst().first?
            .components(separatedBy: "> - **").first)
        XCTAssertTrue(row.contains("old GNU") && row.contains("typeflag `S`"), "英語の対応状況にも旧 GNU S 型が必要")
    }

    func testR10ReviewChangelogExplainsDecmpfsEntryMetadata() throws {
        let bullet = try XCTUnwrap(release090().components(separatedBy: "\n").first { $0.hasPrefix("- HFS+ ") })
        for text in ["methodDescription", "HFS+ compressed (decmpfs)", "HFS+ decmpfs (", "uncompressedSize", "compressedSize", "nil"] {
            XCTAssertTrue(bullet.contains(text), "decmpfs の変更履歴に \(text) が必要")
        }
    }

    func testR11ReviewRecordsUsePortablePathsAndMergedWorktreeStatus() throws {
        for name in ["sevenzip-deflate64", "small-method-gaps", "rpm-stripped-payload", "hfsplus-decmpfs", "release-review-0.9.0"] {
            let path = "Documentation/verification/2026-09-22-\(name).md"
            // 新規記録の存在は一覧・リンクのテストで検査する。
            if name == "release-review-0.9.0", !FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) { continue }
            let record = try document(path)
            XCTAssertFalse(record.contains("/Users/"), "\(name): home 絶対パスを置換する")
            XCTAssertFalse(record.contains("/var/folders/"), "\(name): 一時 directory の固有パスを置換する")
            if name == "small-method-gaps" {
                XCTAssertFalse(record.contains("KaitoKit-wt/small") || record.contains("`wt/small`"))
                XCTAssertTrue(record.contains("一時 worktree") && record.contains("release/0.9.0") && record.contains("統合"))
            }
        }
    }

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
