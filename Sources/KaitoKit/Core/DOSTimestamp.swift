import Foundation

// DOS 日時（1980 起点、2 秒単位）の復号。ZIP・CAB・RAR4 が共有し、不正な値を error にするか捨てるかは
// 呼出側が選ぶ。bit 配置は Core/Timestamps.swift の DOSDateTime、月日の検査と Calendar 変換はここ。

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
        let dos = DOSDateTime(date: date, time: time)
        let year = dos.year, month = dos.month, day = dos.day
        let hour = dos.hour, minute = dos.minute, second = dos.second
        guard (1...31).contains(day),
              (1...12).contains(month),
              (0...59).contains(second),
              (0...59).contains(minute),
              (0...23).contains(hour) else {
            throw KaitoError.malformed("invalid DOS timestamp")
        }
        // Calendar の月日正規化だけを防ぐ。DST の欠落・重複時刻は Calendar の解釈に任せる。
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
            throw KaitoError.malformed("invalid DOS timestamp")
        }
        // 同じ日時が連続する書庫を定数メモリで高速化する。
        cached = (key, result)
        return result
    }
}
