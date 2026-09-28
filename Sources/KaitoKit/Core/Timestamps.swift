import Foundation

// 書庫形式が使う三つの日時表現の算術だけを置く。0 や範囲外の値をどう扱うか（nil にする、
// 捨てる、error にする）は形式ごとに異なるので、呼出側がその方針を持つ。

/// Windows FILETIME: 1601-01-01 00:00:00 UTC からの 100 ns 単位。
/// ZIP の NTFS extra、7z、RAR5、LHA、WIM、CFB、StuffIt X が使う。
enum WindowsFileTime {
    static let ticksPerSecond = 10_000_000.0
    /// 1601-01-01 から 1970-01-01 までの秒数。
    static let epochOffsetSeconds = 11_644_473_600.0

    /// 1970 起点の秒。UInt64 の全域で有限値になる。
    static func secondsSince1970(ticks: UInt64) -> Double {
        Double(ticks) / ticksPerSecond - epochOffsetSeconds
    }

    static func date(ticks: UInt64) -> Date {
        Date(timeIntervalSince1970: secondsSince1970(ticks: ticks))
    }
}

/// classic Mac OS / HFS+ の日時: 1904-01-01 00:00:00 UTC からの秒。
enum MacEpoch {
    /// 1904-01-01 から 1970-01-01 までの秒数。
    static let epochOffsetSeconds = 2_082_844_800.0

    static func date(seconds: UInt64) -> Date {
        Date(timeIntervalSince1970: Double(seconds) - epochOffsetSeconds)
    }
}

/// MS-DOS の日時 field の bit 配置。date は year(7) month(4) day(5)、time は hour(5) minute(6) second/2(5)。
/// 月日の範囲や 0 の扱いは呼出側が検査する（`DOSTimestampDecoder`、LHA、ARJ）。
struct DOSDateTime {
    /// 1980 起点の値に 1980 を足した西暦。
    let year: Int
    let month: Int
    let day: Int
    let hour: Int
    let minute: Int
    /// 2 秒単位の値を秒に戻したもの。
    let second: Int

    init(date: UInt16, time: UInt16) {
        day = Int(date & 0x001F)
        month = Int((date >> 5) & 0x000F)
        year = Int((date >> 9) & 0x007F) + 1980
        second = Int(time & 0x001F) * 2
        minute = Int((time >> 5) & 0x003F)
        hour = Int((time >> 11) & 0x001F)
    }

    /// 上位 word が date、下位 word が time の packed 表現（LHA・ARJ・RAR4）。
    init(packed: UInt32) {
        self.init(date: UInt16(truncatingIfNeeded: packed >> 16), time: UInt16(truncatingIfNeeded: packed))
    }
}
