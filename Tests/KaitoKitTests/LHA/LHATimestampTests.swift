import Foundation
@testable import KaitoKit
import XCTest

final class LHATimestampTests: XCTestCase {
    func testInvalidDOSTimestampsDoNotDiscardReadableMembers() throws {
        let invalidDates: [UInt32] = [
            0, 1, // 日付無し・時刻だけ
            packed(year: 2024, month: 2, day: 30),
            packed(year: 2100, month: 2, day: 29),
            packed(year: 2024, month: 13, day: 1),
            packed(year: 2024, month: 1, day: 1, time: 24 << 11),
        ]
        for level: UInt8 in 0...1 {
            for packedDate in invalidDates {
                let reader = try ArchiveReader.open(data: archive(level: level, packedDate: packedDate))
                let entry = try XCTUnwrap(reader.entries.first)
                XCTAssertNil(entry.modificationDate, "level=\(level), packed=\(packedDate)")
                XCTAssertEqual(try reader.read(entry), Data("payload".utf8))
            }
        }
    }

    func testLeapDayAndRepeatedDatesKeepLocalCalendarInterpretation() throws {
        let value = packed(year: 2024, month: 2, day: 29, time: (12 << 11) | (34 << 5) | 28)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let expected = calendar.date(from: DateComponents(year: 2024, month: 2, day: 29,
                                                          hour: 12, minute: 34, second: 56))
        for level: UInt8 in 0...1 {
            let member = try archive(level: level, packedDate: value).dropLast()
            var bytes = Data(member)
            bytes.append(contentsOf: member)
            bytes.append(0)
            let reader = try ArchiveReader.open(data: bytes)
            XCTAssertEqual(reader.entries.count, 2)
            XCTAssertEqual(reader.entries.map(\.modificationDate), [expected, expected])
            XCTAssertEqual(try reader.reopen().entries, reader.entries)
        }
    }

    func testUnixExtensionOverridesInvalidDOSBaseDate() throws {
        let unixDate: UInt32 = 1_704_164_645
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: unixDate >> ($0 * 8)) }
        let reader = try ArchiveReader.open(data: archive(level: 1, packedDate: 1,
            extraHeaders: [HandLHAExtendedHeader(0x54, bytes)]))
        XCTAssertEqual(reader.entries.first?.modificationDate, Date(timeIntervalSince1970: Double(unixDate)))
    }

    private func packed(year: Int, month: UInt32, day: UInt32, time: UInt32 = 0) -> UInt32 {
        (UInt32(year - 1980) << 25) | (month << 21) | (day << 16) | time
    }

    private func archive(level: UInt8, packedDate: UInt32,
                         extraHeaders: [HandLHAExtendedHeader] = []) throws -> Data {
        var bytes = try LHATestSupport.makeArchive(entries: [HandLHAEntry(
            name: "file", contents: Data("payload".utf8), headerLevel: level,
            creatorOS: 0x55, extraHeaders: extraHeaders)])
        for offset in 0..<4 { bytes[15 + offset] = UInt8(truncatingIfNeeded: packedDate >> (offset * 8)) }
        bytes[1] = bytes[2..<(Int(bytes[0]) + 2)].reduce(UInt8(0)) { $0 &+ $1 }
        return bytes
    }
}
