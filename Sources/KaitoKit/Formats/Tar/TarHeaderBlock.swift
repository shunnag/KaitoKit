import Foundation

// POSIX ustar/pax と GNU tar 拡張の公開仕様だけを参照したクリーンルーム実装。

/// tar の 512 byte header block 一つ。field の位置は POSIX ustar に従う。数値 field は NUL / space で
/// 終わる octal か、GNU の base-256（先頭 byte の最上位 bit が 1）。
struct TarHeaderBlock {
    static let size = 512

    private static let nameRange = 0..<100
    private static let modeRange = 100..<108
    private static let uidRange = 108..<116
    private static let gidRange = 116..<124
    private static let sizeRange = 124..<136
    private static let mtimeRange = 136..<148
    private static let checksumRange = 148..<156
    private static let typeFlagOffset = 156
    private static let linkNameRange = 157..<257
    private static let magicRange = 257..<263
    private static let versionRange = 263..<265
    private static let prefixRange = 345..<500

    /// `size` byte ちょうど。呼出側が長さを確かめてから作る。
    let bytes: [UInt8]

    /// typeflag。v7 の通常 file は NUL。
    var typeFlag: UInt8 { bytes[Self.typeFlagOffset] }

    /// 拡張 header では payload 長、member では本文長の宣言。
    func size() throws -> UInt64 {
        try Self.parseUnsigned(Array(bytes[Self.sizeRange]), fieldName: "size")
    }

    func mode() throws -> UInt64 {
        try Self.parseUnsigned(Array(bytes[Self.modeRange]), fieldName: "mode")
    }

    /// uid / gid は pax の値があればそちらを使うので、生の field を返して解釈は呼出側に任せる。
    var uidField: [UInt8] { Array(bytes[Self.uidRange]) }
    var gidField: [UInt8] { Array(bytes[Self.gidRange]) }

    /// 1970 起点の秒。負の値と base-256 も読む。
    func modificationTime() throws -> TimeInterval {
        try Self.parseTime(Array(bytes[Self.mtimeRange]))
    }

    /// POSIX ustar の header は prefix と name をつないだ path。old GNU・v7 と S 型は name だけ。
    var path: [UInt8] {
        let name = Self.nulTerminated(Array(bytes[Self.nameRange]))
        guard typeFlag != UInt8(ascii: "S") else { return name }
        let magic = Array(bytes[Self.magicRange])
        let version = Array(bytes[Self.versionRange])
        let prefix = Self.nulTerminated(Array(bytes[Self.prefixRange]))
        // old GNU の同位置は prefix ではないため、POSIX ustar の完全値だけを認める。
        guard magic == Array("ustar\0".utf8),
              version == Array("00".utf8),
              !prefix.isEmpty else { return name }
        return prefix + [UInt8(ascii: "/")] + name
    }

    var linkName: [UInt8] { Self.nulTerminated(Array(bytes[Self.linkNameRange])) }

    /// checksum field を space とみなした全 byte の和。歴史的な writer に合わせ、符号付きの和も認める。
    func validateChecksum() throws {
        let expected = try Self.parseUnsigned(Array(bytes[Self.checksumRange]), fieldName: "checksum")
        let checksumRange = Self.checksumRange
        var unsignedSum: UInt64 = 0
        var signedSum: Int64 = 0
        for index in bytes.indices {
            let byte: UInt8 = checksumRange.contains(index) ? 0x20 : bytes[index]
            unsignedSum = try Checked.add(unsignedSum, UInt64(byte))
            signedSum += Int64(Int8(bitPattern: byte))
        }
        let signedMatches = signedSum >= 0 && UInt64(signedSum) == expected
        guard unsignedSum == expected || signedMatches else {
            throw KaitoError.malformed("invalid tar header checksum")
        }
    }

    // 本文や拡張の解釈前に、検出に必要な member header の構造だけを検証する。
    // 数値フィールドの妥当性は parser の責務で、そこで malformed として報告する。
    // 検出側で弾くと、壊れた tar が「未対応形式」に化けて診断を失う。
    static func isPlausibleMemberHeader(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == size else { return false }
        let header = TarHeaderBlock(bytes: bytes)
        guard !header.path.isEmpty else { return false }
        do {
            try header.validateChecksum()
            return true
        } catch {
            return false
        }
    }

    /// octal（NUL / space 終端）または GNU base-256 の符号なし数値 field。
    static func parseUnsigned(
        _ field: [UInt8],
        fieldName: String
    ) throws -> UInt64 {
        guard !field.isEmpty else {
            throw KaitoError.malformed("empty tar \(fieldName) field")
        }
        if field[0] & 0x80 != 0 {
            guard field[0] & 0x40 == 0 else {
                throw KaitoError.malformed("negative tar \(fieldName) field")
            }
            var value: UInt64 = 0
            for index in field.indices {
                let byte = index == field.startIndex ? field[index] & 0x7f : field[index]
                value = try Checked.mul(value, 256)
                value = try Checked.add(value, UInt64(byte))
            }
            return value
        }

        var value: UInt64 = 0
        var sawDigit = false
        var sawTrailingPadding = false
        var sawNULTerminator = false
        for byte in field {
            if byte == 0 {
                sawNULTerminator = true
                continue
            }
            if byte == 0x20 {
                if sawDigit { sawTrailingPadding = true }
                continue
            }
            guard !sawNULTerminator,
                  !sawTrailingPadding,
                  byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "7") else {
                throw KaitoError.malformed("invalid octal tar \(fieldName) field")
            }
            sawDigit = true
            value = try Checked.mul(value, 8)
            value = try Checked.add(value, UInt64(byte - UInt8(ascii: "0")))
        }
        return value
    }

    /// mtime field。octal の先頭に `-` を置いた負の値と、符号付き base-256 も読む。
    static func parseTime(_ field: [UInt8]) throws -> TimeInterval {
        guard !field.isEmpty else { throw KaitoError.malformed("empty tar mtime") }
        if field[0] & 0x80 != 0 {
            if field[0] & 0x40 == 0 {
                return Double(try parseUnsigned(field, fieldName: "mtime"))
            }
            // 64 bit より上位は全て符号拡張でなければ表現範囲外として拒否する。
            if field.count > 8 {
                let prefix = field.dropLast(8)
                guard let first = prefix.first,
                      first & 0x7f == 0x7f,
                      prefix.dropFirst().allSatisfy({ $0 == 0xff }) else {
                    throw KaitoError.malformed("tar mtime is out of range")
                }
                var low: UInt64 = 0
                for byte in field.suffix(8) {
                    low = try Checked.mul(low, 256)
                    low = try Checked.add(low, UInt64(byte))
                }
                let signed = Int64(bitPattern: low)
                guard signed < 0 else { throw KaitoError.malformed("invalid tar mtime sign") }
                return Double(signed)
            }

            var encoded: UInt64 = 0
            for index in field.indices {
                let byte = index == field.startIndex ? field[index] & 0x7f : field[index]
                encoded = try Checked.mul(encoded, 256)
                encoded = try Checked.add(encoded, UInt64(byte))
            }
            let width = UInt64(field.count * 8 - 1)
            let modulus = try Checked.shiftLeft(1, by: width)
            guard encoded < modulus else { throw KaitoError.malformed("invalid tar mtime") }
            return Double(encoded) - Double(modulus)
        }

        guard let firstNonSpace = field.firstIndex(where: { $0 != 0x20 }) else {
            return 0
        }
        if field[firstNonSpace] == UInt8(ascii: "-") {
            let magnitudeField = Array(field[field.index(after: firstNonSpace)...])
            let magnitude = try parseUnsigned(magnitudeField, fieldName: "mtime")
            guard magnitudeField.contains(where: {
                $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "7")
            }) else {
                throw KaitoError.malformed("invalid tar mtime")
            }
            return -Double(magnitude)
        }
        return Double(try parseUnsigned(field, fieldName: "mtime"))
    }

    static func nulTerminated(_ field: [UInt8]) -> [UInt8] {
        guard let end = field.firstIndex(of: 0) else { return field }
        return Array(field[..<end])
    }

    static func entryKind(for type: UInt8) -> EntryKind {
        switch type {
        case 0, UInt8(ascii: "0"), UInt8(ascii: "7"), UInt8(ascii: "S"):
            return .file
        case UInt8(ascii: "5"):
            return .directory
        case UInt8(ascii: "2"):
            return .symlink
        case UInt8(ascii: "1"):
            return .hardlink
        default:
            return .other
        }
    }

    /// `formatSpecific["typeFlag"]` の表記。印字可能な ASCII はその文字、NUL は "NUL"、他は 16 進。
    static func typeDescription(_ type: UInt8) -> String {
        if type == 0 { return "NUL" }
        if type >= 0x20, type <= 0x7e { return String(UnicodeScalar(type)) }
        return String(format: "0x%02x", type)
    }
}
