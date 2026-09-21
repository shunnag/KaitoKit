import Foundation
import KaitoKit
import KaitoKitCompat
import XCTest

final class KaitoArchiveISOTests: XCTestCase {
    func testISOFormatName() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/iso/joliet.iso.gz.b64")
        let text = try String(contentsOf: url, encoding: .utf8)
        let compressed = try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters))
        let gzip = try ArchiveReader.open(data: compressed)
        let iso = try gzip.read(gzip.entries[0])
        let archive = try XCTUnwrap(KaitoArchive(data: iso))
        XCTAssertEqual(archive.formatName(), "ISO 9660")
        XCTAssertEqual(archive.numberOfEntries(), 5)
    }

    /// BIN/CUE の生 sector image は ISO 9660 として開き、`.cue` の path は data track の image を辿る。
    func testRawSectorImageAndCueSheetOpenAsISO() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Fixtures/bincue/mode2-subheader.bin.gz.b64"), encoding: .utf8)
        let gzip = try ArchiveReader.open(data: try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters)))
        let raw = try gzip.read(gzip.entries[0])
        let archive = try XCTUnwrap(KaitoArchive(data: raw))
        XCTAssertEqual(archive.formatName(), "ISO 9660")
        XCTAssertEqual(archive.numberOfEntries(), 6)
        XCTAssertEqual(archive.contents(ofEntry: 1)?.count, 4096)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kaito-compat-cue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try raw.write(to: directory.appendingPathComponent("mode2-subheader.bin"))
        let cue = directory.appendingPathComponent("multi.cue")
        try FileManager.default.copyItem(at: root.appendingPathComponent("Fixtures/bincue/multi.cue"), to: cue)
        let fromCue = try XCTUnwrap(KaitoArchive(file: cue.path))
        XCTAssertEqual(fromCue.formatName(), "ISO 9660")
        XCTAssertEqual(fromCue.numberOfEntries(), 6)
        XCTAssertEqual(fromCue.name(ofEntry: 1), "data.bin")
    }
}
