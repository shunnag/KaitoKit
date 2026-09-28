import Foundation

extension Data {
    /// `value` を little endian の `T.bitWidth / 8` バイトとして末尾に足す。
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        for shift in stride(from: 0, to: T.bitWidth, by: 8) {
            append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }
}

extension Array where Element == UInt8 {
    /// `value` を little endian の `T.bitWidth / 8` バイトとして末尾に足す。
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        for shift in stride(from: 0, to: T.bitWidth, by: 8) {
            append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }
}
