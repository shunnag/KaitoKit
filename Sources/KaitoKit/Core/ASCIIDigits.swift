import Foundation

/// ASCII 数字列（8・10・16 進）を符号なし整数に読む。cpio・ar・rpm の header field が使う。
/// tar の octal は NUL / space 終端と base-256 の規則を持つので TarReader が自分で読む。
enum ASCIIDigits {
    /// `0-9`、`A-F`、`a-f` を桁として読む。radix 以上の桁と他の byte は `.malformed(label)`、
    /// 桁あふれは Checked が検出する。
    static func unsigned(_ bytes: some Sequence<UInt8>, radix: UInt64, label: String) throws -> UInt64 {
        var value: UInt64 = 0
        for byte in bytes {
            let digit: UInt64
            switch byte {
            case 48...57: digit = UInt64(byte - 48)
            case 65...70: digit = UInt64(byte - 65 + 10)
            case 97...102: digit = UInt64(byte - 97 + 10)
            default: throw KaitoError.malformed(label)
            }
            guard digit < radix else { throw KaitoError.malformed(label) }
            value = try Checked.add(Checked.mul(value, radix), digit)
        }
        return value
    }
}
