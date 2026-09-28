import Foundation
@testable import KaitoKit
import XCTest

final class DOSTimestampTests: XCTestCase {
    func testEveryDOSDateWordMatchesLegacyCalendarValidation() throws {
        let times: [UInt16] = [
            0, (2 << 11) | (30 << 5), (23 << 11) | (59 << 5) | 29,
            24 << 11, 60 << 5, 30, 31, .max,
        ]
        for identifier in ["UTC", "America/New_York", "Europe/Berlin", "Asia/Tokyo"] {
            let zone = try XCTUnwrap(TimeZone(identifier: identifier))
            var decoder = DOSTimestampDecoder(timeZone: zone)
            // 全 128 年 × 16 月 × 32 日。未定義の月・日も含める。
            for date in UInt16.min...UInt16.max {
                for time in times {
                    let expected = outcome { try legacyDOSDate(date: date, time: time, timeZone: zone) }
                    let actual = outcome { try decoder.modificationDate(date: date, time: time) }
                    guard actual == expected else {
                        return XCTFail("\(identifier), date=\(date), time=\(time): \(actual) != \(expected)")
                    }
                }
            }
        }
    }

    func testEveryDOSTimeWordMatchesLegacyCalendarConversion() throws {
        for identifier in ["UTC", "America/New_York", "Europe/Berlin", "Asia/Tokyo"] {
            let zone = try XCTUnwrap(TimeZone(identifier: identifier))
            var decoder = DOSTimestampDecoder(timeZone: zone)
            // DST の欠落・重複時刻を含む日で Calendar の正規化を維持する。
            for date: UInt16 in [(44 << 9) | (3 << 5) | 10, (44 << 9) | (11 << 5) | 3] {
                for time in UInt16.min...UInt16.max {
                    let expected = outcome { try legacyDOSDate(date: date, time: time, timeZone: zone) }
                    let actual = outcome { try decoder.modificationDate(date: date, time: time) }
                    guard actual == expected else {
                        return XCTFail("\(identifier), date=\(date), time=\(time): \(actual) != \(expected)")
                    }
                }
            }
        }
    }

    func testCacheAndTimeZonesAreLocalToEachDecoder() throws {
        let date: UInt16 = (44 << 9) | (7 << 5) | 1
        let time: UInt16 = 12 << 11
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        var first = DOSTimestampDecoder(timeZone: utc)
        var second = DOSTimestampDecoder(timeZone: tokyo)
        let expected = try legacyDOSDate(date: date, time: time, timeZone: utc)
        for _ in 0..<3 {
            XCTAssertEqual(try first.modificationDate(date: date, time: time), expected)
        }
        XCTAssertNil(try first.modificationDate(date: 0, time: .max))
        XCTAssertThrowsError(try first.modificationDate(date: date, time: 24 << 11))
        XCTAssertEqual(try first.modificationDate(date: date, time: time), expected)
        XCTAssertEqual(try second.modificationDate(date: date, time: time),
                       try legacyDOSDate(date: date, time: time, timeZone: tokyo))
        XCTAssertNotEqual(try second.modificationDate(date: date, time: time), expected)
        XCTAssertEqual(try dosModificationDate(date: date, time: time),
                       try legacyDOSDate(date: date, time: time, timeZone: .current))
    }

    private func outcome(_ body: () throws -> Date?) -> Result<Date?, KaitoError> {
        do { return .success(try body()) }
        catch let error as KaitoError { return .failure(error) }
        catch {
            XCTFail("Unexpected error: \(error)")
            return .failure(.malformed("unexpected error"))
        }
    }

    // 変更前のアルゴリズム。テストだけ timezone を注入する。
    private func legacyDOSDate(date: UInt16, time: UInt16, timeZone: TimeZone) throws -> Date? {
        guard date != 0 else { return nil }
        let day = Int(date & 0x001f)
        let month = Int((date >> 5) & 0x000f)
        let year = Int((date >> 9) & 0x007f) + 1980
        let second = Int(time & 0x001f) * 2
        let minute = Int((time >> 5) & 0x003f)
        let hour = Int((time >> 11) & 0x001f)
        guard (1...31).contains(day),
              (1...12).contains(month),
              (0...59).contains(second),
              (0...59).contains(minute),
              (0...23).contains(hour) else {
            throw KaitoError.malformed("invalid DOS timestamp")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let monthStart = calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: 1
        )),
            let validDays = calendar.range(of: .day, in: .month, for: monthStart),
            validDays.contains(day)
        else {
            throw KaitoError.malformed("invalid DOS timestamp")
        }
        guard let result = calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )) else {
            throw KaitoError.malformed("invalid DOS timestamp")
        }
        return result
    }
}
