import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

final class LHASFXTests: XCTestCase {
    private static let corpusRoot = URL(
        fileURLWithPath: "/private/tmp/claude-501/-Users-nagash-cooViewer/37ef55f3-9116-4440-88b8-9a15060856ad/scratchpad/lha-corpus",
        isDirectory: true
    )

    func testNineCorpusSelfExtractorsMatchLhasa() throws {
        let relativePaths = [
            "explzh_723/declha_sfx_ansi.exe",
            "explzh_723/declha_sfx_unicode.exe",
            "lh2_222/sfx.exe",
            "lha213/sfx.exe",
            "lha255e/sfx.exe",
            "lhmelt_16536/sfx_winsfx32_213.exe",
            "lhmelt_16536/sfx_winsfx32m_250.exe",
            "lhmelt_16536/sfx_winsfx_213.exe",
            "lhmelt_16536/sfx_winsfxm_250.exe",
        ]
        let archives = relativePaths.map { Self.corpusRoot.appendingPathComponent($0) }
        guard archives.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("read-only lhasa compatibility corpus is unavailable")
        }
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/lha") else {
            throw XCTSkip("lhasa executable is unavailable")
        }

        for archive in archives {
            let reader = try ArchiveReader.open(url: archive)
            XCTAssertEqual(reader.format, ArchiveFormat.lha, archive.path)
            let files = reader.entries.filter { $0.kind != EntryKind.directory }
            XCTAssertFalse(files.isEmpty, archive.path)
            for entry in files {
                let actual = try reader.read(entry)
                // Lhasa presents MS-DOS-origin names in lowercase and applies
                // that spelling to member selection.
                let expected = try lhasaMember(
                    archive: archive,
                    name: entry.name.lowercased()
                )
                XCTAssertEqual(
                    SHA256.hash(data: actual),
                    SHA256.hash(data: expected),
                    "SFX member differs: \(archive.path):\(entry.name)"
                )
            }
        }
    }

    func testSFXScanAuthenticatesCandidatesAndIsBounded() throws {
        let payload = Data("bounded LHA self-extractor".utf8)
        let archive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(name: "payload.txt", contents: payload, headerLevel: 1),
        ])

        var damagedCandidate = archive
        damagedCandidate[damagedCandidate.startIndex + 1] ^= 0x80
        var prefixed = Data([0x4D, 0x5A])
        prefixed.append(damagedCandidate.dropLast())
        prefixed.append(Data(repeating: 0xCC, count: 31))
        prefixed.append(archive)
        let reader = try ArchiveReader.open(data: prefixed)
        XCTAssertEqual(reader.entries.map(\.name), ["payload.txt"])
        XCTAssertEqual(try reader.read(reader.entries[0]), payload)

        var beyondBound = Data(repeating: 0x90, count: Int(FormatDetector.maximumLHASFXSize) + 1)
        beyondBound.append(archive)
        XCTAssertThrowsError(try ArchiveReader.open(data: beyondBound)) { error in
            XCTAssertEqual(error as? KaitoError, KaitoError.unsupportedFormat)
        }
    }

    func testSFXScanResumesAfterStructurallyInvalidLevel2Candidate() throws {
        let falseArchive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "decoy.txt",
                contents: Data("decoy".utf8),
                headerLevel: 2,
                includeLevel2HeaderCRC: false
            ),
        ])
        let payload = Data("real member after level-2 decoy".utf8)
        let realArchive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(name: "real.txt", contents: payload, headerLevel: 1),
        ])

        var prefixed = Data([0x4D, 0x5A])
        // Removing the terminator leaves an authenticated, internally bounded
        // level-2 header whose following bytes cannot form another member.
        prefixed.append(falseArchive.dropLast())
        prefixed.append(Data(repeating: 0xCC, count: 17))
        prefixed.append(realArchive)

        let reader = try ArchiveReader.open(data: prefixed)
        XCTAssertEqual(reader.entries.map(\.name), ["real.txt"])
        XCTAssertEqual(try reader.read(reader.entries[0]), payload)
    }

    private func lhasaMember(archive: URL, name: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/lha")
        process.arguments = ["-pq", archive.path, name]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let diagnostic = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            XCTFail(
                "lhasa rejected \(archive.path):\(name): "
                    + String(decoding: diagnostic, as: UTF8.self)
            )
            return Data()
        }
        return data
    }
}
