import Foundation
@_spi(ZipRawLayout) internal import KaitoKit
import XCTest

final class ZipRawLayoutSPIImportTests: XCTestCase {
    func testSPIWithoutTestableImport() throws {
        let reader = try ArchiveReader.open(data: ZipTestSupport.makeArchive(entries: [HandZipEntry(name: "entry")]))
        let layout: ZipRawRecordLayout = try XCTUnwrap(reader.zipRawRecordLayout(at: 0))
        let record = try XCTUnwrap(reader.rawRecord(of: reader.entries[0]))
        XCTAssertEqual(layout.recordRange, record.recordRange)
        XCTAssertEqual(layout.payloadRange, record.payloadRange)
        XCTAssertEqual(layout.isZIP64, layout.centralHasZIP64Extra || layout.localHasZIP64Extra)
    }
}
