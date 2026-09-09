// Microsoft [MS-CAB]、RFC 1951、zlib manual と利用者提供の実測 byte 表を許可資料とする。
// 他の archiver の実装 source は参照していない。
// ZIP の既存検証をそのまま共有し、呼出側で metadata 失敗時の方針を選ぶ。
import Foundation

func dosModificationDate(date: UInt16, time: UInt16) throws -> Date? {
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
        throw KaitoError.malformed("invalid ZIP DOS timestamp")
    }
    var calendar = Calendar(identifier: .gregorian)
    // DOS 日時には timezone が無いため、APPNOTE の慣例どおり現在のローカル時刻として解釈する。
    calendar.timeZone = .current
    // Calendar.date(from:) は 2 月 31 日などを翌月へ正規化するため、先に月内の日数を検証する。
    guard let monthStart = calendar.date(from: DateComponents(
        year: year,
        month: month,
        day: 1
    )),
        let validDays = calendar.range(of: .day, in: .month, for: monthStart),
        validDays.contains(day)
    else {
        throw KaitoError.malformed("invalid ZIP DOS timestamp")
    }
    guard let result = calendar.date(from: DateComponents(
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute,
        second: second
    )) else {
        throw KaitoError.malformed("invalid ZIP DOS timestamp")
    }
    return result
}

