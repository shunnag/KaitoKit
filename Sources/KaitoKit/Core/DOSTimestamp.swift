// Microsoft [MS-CAB]、RFC 1951、zlib manual と利用者提供の実測 byte 表を許可資料とする。
// 他の archiver の実装 source は参照していない。
// ZIP の既存検証をそのまま共有し、呼出側で metadata 失敗時の方針を選ぶ。
import Foundation

func dosModificationDate(date: UInt16, time: UInt16) throws -> Date? {
    var decoder = DOSTimestampDecoder()
    return try decoder.modificationDate(date: date, time: time)
}

struct DOSTimestampDecoder {
    private let calendar: Calendar
    private var cached: (key: UInt32, date: Date)?

    init(timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        // パースごとに現在の timezone を採り、entry 間では Calendar を共有する。
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    mutating func modificationDate(date: UInt16, time: UInt16) throws -> Date? {
        guard date != 0 else { return nil }
        let key = UInt32(date) << 16 | UInt32(time)
        if let cached, cached.key == key { return cached.date }
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
        // Calendar の月日正規化だけを防ぐ。DST の欠落・重複時刻の扱いは従来どおり。
        let daysInMonth: Int
        switch month {
        case 2:
            let leapYear = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
            daysInMonth = leapYear ? 29 : 28
        case 4, 6, 9, 11: daysInMonth = 30
        default: daysInMonth = 31
        }
        guard day <= daysInMonth,
              let result = calendar.date(from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                second: second
              )) else {
            throw KaitoError.malformed("invalid ZIP DOS timestamp")
        }
        // 同じ日時が連続する書庫を定数メモリで高速化する。
        cached = (key, result)
        return result
    }
}
