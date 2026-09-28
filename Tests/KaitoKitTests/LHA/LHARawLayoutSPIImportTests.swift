import Foundation
@_spi(LHARawLayout) internal import KaitoKit
import XCTest

final class LHARawLayoutSPIImportTests: XCTestCase {
    func testSPIWithoutTestableImport() throws {
        let data = try LHATestSupport.makeArchive(entries: [HandLHAEntry(name: "entry", headerLevel: 1)])
        let reader = try ArchiveReader.open(data: data)
        let layout: LHAArchiveLayout = try XCTUnwrap(reader.lhaRawLayout())
        let member: LHAMemberLayout = try layout.member(at: 0)
        let terminator: LHAArchiveTerminator = .zeroByte(offset: UInt64(data.count - 1))
        let trailing: LHATrailingBytes = .none
        XCTAssertEqual(layout.terminator, terminator)
        XCTAssertEqual(layout.trailingBytes, trailing)
        XCTAssertEqual(layout.archiveLength, UInt64(data.count))
        XCTAssertEqual(layout.firstHeaderOffset, 0)
        XCTAssertEqual(layout.endOfMembersOffset, member.dataRange.upperBound)
        XCTAssertEqual(layout.memberCount, 1)
        XCTAssertEqual(layout.unpublishedMemberCount, 0)
        XCTAssertEqual(member.headerRange.lowerBound, 0)
        XCTAssertEqual(member.dataRange.count, 0)
        XCTAssertEqual(member.headerLevel, 1)
        XCTAssertEqual(member.method, "-lh0-")
        XCTAssertEqual(member.osID, 0x55)
        XCTAssertEqual(member.crc16, 0)
        XCTAssertEqual(member.entryIndex, 0)
    }
}
