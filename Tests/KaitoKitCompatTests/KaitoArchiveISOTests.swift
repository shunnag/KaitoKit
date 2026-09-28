import Foundation
import KaitoKit
import KaitoKitCompat
import XCTest

final class KaitoArchiveISOTests: XCTestCase {
    func testISOFormatName() throws {
        let iso = try CompatFixtures.gzipBase64("iso/joliet.iso")
        let archive = try XCTUnwrap(KaitoArchive(data: iso))
        XCTAssertEqual(archive.formatName(), "ISO 9660")
        XCTAssertEqual(archive.numberOfEntries(), 5)
    }

    /// BIN/CUE の生 sector image は ISO 9660 として開き、`.cue` の path は data track の image を辿る。
    func testRawSectorImageAndCueSheetOpenAsISO() throws {
        let raw = try CompatFixtures.gzipBase64("bincue/mode2-subheader.bin")
        let archive = try XCTUnwrap(KaitoArchive(data: raw))
        XCTAssertEqual(archive.formatName(), "ISO 9660")
        XCTAssertEqual(archive.numberOfEntries(), 6)
        XCTAssertEqual(archive.contents(ofEntry: 1)?.count, 4096)

        let directory = try CompatFixtures.makeTemporaryDirectory(label: "cue")
        defer { try? FileManager.default.removeItem(at: directory) }
        try raw.write(to: directory.appendingPathComponent("mode2-subheader.bin"))
        let cue = directory.appendingPathComponent("multi.cue")
        try FileManager.default.copyItem(at: CompatFixtures.url("bincue/multi.cue"), to: cue)
        let fromCue = try XCTUnwrap(KaitoArchive(file: cue.path))
        XCTAssertEqual(fromCue.formatName(), "ISO 9660")
        XCTAssertEqual(fromCue.numberOfEntries(), 6)
        XCTAssertEqual(fromCue.name(ofEntry: 1), "data.bin")
    }
}
