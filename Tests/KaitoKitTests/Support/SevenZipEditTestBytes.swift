import Foundation
@testable import KaitoKit

/// 7z の編集用 snapshot の検査で、手組みの header から書庫のバイト列を作る helper。
enum SevenZipEditTestBytes {
    static func hex(_ string: String) -> [UInt8] {
        do {
            return try Hex.bytes(string)
        } catch {
            preconditionFailure("invalid 7z test hex: \(error)")
        }
    }
    static func little<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
    static func archive(header: [UInt8], packed: [UInt8] = []) -> Data {
        let start = little(UInt64(packed.count)) + little(UInt64(header.count)) + little(CRC32.checksum(header))
        return Data([0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c, 0, 4] + little(CRC32.checksum(start)) + start + packed + header)
    }
}
