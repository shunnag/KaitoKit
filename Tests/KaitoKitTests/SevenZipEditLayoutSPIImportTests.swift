import Foundation
@_spi(SevenZipEditLayout) internal import KaitoKit
import XCTest

final class SevenZipEditLayoutSPIImportTests: XCTestCase {
    func testSPIWithoutTestableImport() throws {
        var options = ReaderOptions(password: "secret")
        XCTAssertFalse(options.recordsSevenZipEditLayout)
        options.recordsSevenZipEditLayout = true
        let reader = try ArchiveReader.open(url: SevenZipGoldenCorpus.root.appendingPathComponent("g_aesh.7z"), options: options)
        let snapshot: SevenZipEditingSnapshot = try XCTUnwrap(reader.sevenZipEditingSnapshot())
        let header: SevenZipEditHeader = snapshot.header
        let folder: SevenZipEditFolder = try XCTUnwrap(snapshot.folders.first)
        let coder: SevenZipEditCoder = try XCTUnwrap(folder.coders.first)
        let _: [SevenZipEditBindPair] = folder.bindPairs
        let _: [SevenZipEditPack] = snapshot.packs
        let _: [SevenZipEditSubstream] = snapshot.substreams
        let _: [SevenZipEditFile] = snapshot.files
        let _: SevenZipEditUnrepresentedReason? = snapshot.unrepresentedReason
        XCTAssertTrue(header.isEncrypted)
        XCTAssertTrue(coder.isAES)
        XCTAssertFalse(try reader.sevenZipDecryptedPackedStream(folder: 0, packedInput: 0).readAll().isEmpty)
    }
}
