import Foundation

// ECMA-167 3rd edition (1997) と OSTA UDF 2.60 の公開仕様だけを参照したクリーンルーム実装。
// 節番号は ECMA-167 を「部/節」、UDF を「UDF §」で示す。第三者 UDF 実装の source は開いていない。

enum UDFBytes {
    static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
    static func u64(_ b: [UInt8], _ o: Int) -> UInt64 { UInt64(u32(b, o)) | UInt64(u32(b, o + 4)) << 32 }

    /// 3/7.2.6: CRC-ITU-T（x^16 + x^12 + x^5 + 1）、初期値 0、反転なし。仕様の例: 70 6A 77 → 3299。
    static func crc16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    /// 1/7.4 regid の Identifier（byte 1〜23、末尾の #00 を除く）。
    static func identifier(_ b: [UInt8], _ o: Int) -> [UInt8] {
        var end = o + 24
        while end > o + 1, b[end - 1] == 0 { end -= 1 }
        return Array(b[(o + 1)..<end])
    }

    /// UDF §2.1.1 OSTA Compressed Unicode。compression ID 8 は 1 byte / 文字（Unicode 0〜255）、
    /// 16 は big endian の 2 byte / 文字。254 / 255 は削除済み FID の空名。
    static func compressedUnicode(_ b: ArraySlice<UInt8>) -> String? {
        guard let first = b.first else { return "" }
        let body = b.dropFirst()
        switch first {
        case 8:
            return String(body.map { Character(UnicodeScalar($0)) })
        case 16:
            guard body.count % 2 == 0 else { return nil }
            var units: [UInt16] = []
            units.reserveCapacity(body.count / 2)
            var index = body.startIndex
            while index < body.endIndex {
                units.append(UInt16(b[index]) << 8 | UInt16(b[index + 1]))
                index += 2
            }
            return String(decoding: units, as: UTF16.self)
        case 254, 255:
            return ""
        default:
            return nil
        }
    }

    /// 1/7.2.12（UDF §2.1.3 の 0 起点の読み替え）: 末尾 byte が使用長。全 #00 は空文字列。
    static func dstring(_ b: [UInt8], _ o: Int, length: Int) -> String? {
        let used = Int(b[o + length - 1])
        guard used <= length - 1 else { return nil }
        guard used > 0 else { return "" }
        return compressedUnicode(b[o..<(o + used)])
    }

    /// 1/7.3 timestamp。type 0 = UTC、1 = local（UDF は 1 を要求し、12 bit の分単位 offset を持つ）。
    /// -2047 は「時間帯不明」で UTC として解釈する（UDF §2.1.4 NOTE 2）。
    static func timestamp(_ b: [UInt8], _ o: Int) -> Date? {
        let typeAndZone = u16(b, o)
        let type = typeAndZone >> 12
        guard type <= 2 else { return nil }
        var zone = Int(typeAndZone & 0x0FFF)
        if zone >= 0x800 { zone -= 0x1000 }
        if type == 0 || zone == -2047 || !(-1440...1440).contains(zone) { zone = 0 }
        let year = Int(Int16(bitPattern: u16(b, o + 2)))
        let month = Int(b[o + 4]), day = Int(b[o + 5])
        let hour = Int(b[o + 6]), minute = Int(b[o + 7]), second = Int(b[o + 8])
        let centiseconds = Int(b[o + 9])
        if year == 0, month == 0, day == 0 { return nil }
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second),
              centiseconds <= 99 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: min(second, 59))
        guard let date = calendar.date(from: components), calendar.component(.day, from: date) == day else { return nil }
        return date.addingTimeInterval(Double(centiseconds) / 100 - Double(zone * 60))
    }
}

/// 3/7.2 と 4/7.2 の descriptor tag。checksum・CRC・位置を検証する。
struct UDFTag {
    let identifier: UInt16
    let version: UInt16
    let crcLength: Int
    let location: UInt32

    static let size = 16

    /// tag を解釈し、checksum と CRC を検証する。`expectedLocation` があれば Tag Location も照合する。
    /// tag identifier 0 は未記録 block（全 #00）として nil を返す。
    static func parse(_ b: [UInt8], expectedLocation: UInt32?, label: String, allowIdentifierZero: Bool = false) throws -> UDFTag? {
        guard b.count >= size else { throw KaitoError.truncated }
        let identifier = UDFBytes.u16(b, 0)
        // UDF §2.2.12 の sparing table は identifier 0 で他の field が有効な tag を持つ。
        if identifier == 0, !allowIdentifierZero { return nil }
        var sum: UInt8 = 0
        for index in 0..<16 where index != 4 { sum &+= b[index] }
        guard sum == b[4] else { throw KaitoError.malformed("udf \(label) tag checksum") }
        let crcLength = Int(UDFBytes.u16(b, 10))
        guard crcLength <= b.count - size else { throw KaitoError.malformed("udf \(label) tag CRC length") }
        // 3/7.2.6: CRC 長 0 は CRC を計算しない書き手を許す。
        if crcLength > 0 {
            guard UDFBytes.crc16(b[size..<(size + crcLength)]) == UDFBytes.u16(b, 8) else {
                throw KaitoError.malformed("udf \(label) descriptor CRC")
            }
        }
        let location = UDFBytes.u32(b, 12)
        if let expectedLocation, location != expectedLocation {
            throw KaitoError.malformed("udf \(label) tag location")
        }
        return UDFTag(identifier: identifier, version: UDFBytes.u16(b, 2), crcLength: crcLength, location: location)
    }
}

/// 3/7.1 extent_ad: 論理 sector 単位の絶対位置と byte 長。
struct UDFExtent {
    let length: UInt32
    let location: UInt32
    init(_ b: [UInt8], _ o: Int) {
        length = UDFBytes.u32(b, o)
        location = UDFBytes.u32(b, o + 4)
    }
}

/// 4/14.14.1〜14.14.3 の allocation descriptor を共通形にしたもの。
/// `type` は extent 種別（0 記録済、1 未記録・割当済、2 未割当、3 継続 extent）。
struct UDFAllocation {
    let length: UInt32
    let type: UInt8
    let block: UInt32
    let partition: UInt16?

    /// 4/14.14.1 short_ad（8 byte）。partition は記録元と同じ。
    static func short(_ b: [UInt8], _ o: Int) -> UDFAllocation {
        let raw = UDFBytes.u32(b, o)
        return UDFAllocation(length: raw & 0x3FFF_FFFF, type: UInt8(raw >> 30), block: UDFBytes.u32(b, o + 4), partition: nil)
    }

    /// 4/14.14.2 long_ad（16 byte）: 長さ、lb_addr（block 4 byte + partition 2 byte）、implementation use 6 byte。
    static func long(_ b: [UInt8], _ o: Int) -> UDFAllocation {
        let raw = UDFBytes.u32(b, o)
        return UDFAllocation(length: raw & 0x3FFF_FFFF, type: UInt8(raw >> 30),
                             block: UDFBytes.u32(b, o + 4), partition: UDFBytes.u16(b, o + 8))
    }
}
