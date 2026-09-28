import Foundation

/// テストに埋め込む 16 進文字列をバイト列へ戻す。空白と改行は読み飛ばす。
enum Hex {
    struct DecodingError: Error, CustomStringConvertible {
        let description: String
    }

    /// 奇数桁、または 16 進として読めない文字があれば throw する。
    static func bytes(_ text: String) throws -> [UInt8] {
        let digits = Array(text.utf8.filter { !Self.isWhitespace($0) })
        guard digits.count.isMultiple(of: 2) else {
            throw DecodingError(description: "odd test hex length: \(digits.count)")
        }
        var result = [UInt8]()
        result.reserveCapacity(digits.count / 2)
        var index = 0
        while index < digits.count {
            guard let high = value(of: digits[index]), let low = value(of: digits[index + 1]) else {
                throw DecodingError(description: "invalid test hex at offset \(index)")
            }
            result.append(high << 4 | low)
            index += 2
        }
        return result
    }

    static func data(_ text: String) throws -> Data {
        Data(try bytes(text))
    }

    private static func value(of digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): digit - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): digit - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}
