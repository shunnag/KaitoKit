import Foundation
import KaitoKitCompat
import XCTest

/// 2026-09-20 に追加した単一 stream 形式（lzip / brotli / pbzx）の XADMaster 互換名と size 有無。
final class KaitoArchiveSingleFileNamesTests: XCTestCase {
    private func fixture(_ relativePath: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Fixtures/\(relativePath)"), encoding: .utf8)
        return try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters))
    }

    func testFormatNamesAndSizeAvailability() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaito-compat-single-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        // lzip は trailer に展開後サイズを持つので size がある。
        let lzip = try XCTUnwrap(KaitoArchive(data: try fixture("lzip/one.lz.b64")))
        XCTAssertEqual(lzip.formatName(), "Lzip")
        XCTAssertEqual(lzip.numberOfEntries(), 1)
        XCTAssertTrue(lzip.entryHasSize(0))

        // brotli は拡張子でしか判別できず、サイズも持たない。
        let brotliURL = temporary.appendingPathComponent("one.br")
        try fixture("brotli/one.br.b64").write(to: brotliURL)
        let brotli = try XCTUnwrap(KaitoArchive(fileURL: brotliURL))
        XCTAssertEqual(brotli.formatName(), "Brotli")
        XCTAssertEqual(brotli.numberOfEntries(), 1)
        XCTAssertFalse(brotli.entryHasSize(0))
        XCTAssertNil(KaitoArchive(data: try fixture("brotli/one.br.b64")), "brotli needs a file name to be detected")

        // pbzx は chunk header の合計から size が決まる。
        let pbzx = try XCTUnwrap(KaitoArchive(data: try fixture("pbzx/text.pbzx.b64")))
        XCTAssertEqual(pbzx.formatName(), "pbzx")
        XCTAssertEqual(pbzx.numberOfEntries(), 1)
        XCTAssertTrue(pbzx.entryHasSize(0))
    }
}
