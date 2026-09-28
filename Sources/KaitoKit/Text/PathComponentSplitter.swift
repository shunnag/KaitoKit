import Darwin
import Foundation

/// 書庫内 path を `/` で component に分け、直前の entry と同じ directory 部分は分割結果を再利用する。
/// 同じ directory に並ぶ entry が多い書庫で String の生成を減らす。形式には依存しない。
struct PathComponentSplitter {
    private var ranges: [Range<Int>] = []
    private var directoryBytes: [UInt8] = []
    private var directoryComponents: [String] = []

    mutating func split(_ name: String) -> [String] {
        if let components = name.utf8.withContiguousStorageIfAvailable({ bytes -> [String] in
            ranges.removeAll(keepingCapacity: true)
            var lower = 0
            var lastSeparator: Int?
            for index in bytes.indices where bytes[index] == 0x2f {
                if lower < index { ranges.append(lower..<index) }
                lower = index + 1
                lastSeparator = index
            }
            guard let separator = lastSeparator else {
                directoryBytes = []
                directoryComponents = []
                return name.isEmpty ? [] : [name]
            }
            // String の等価比較は NFC / NFD を同一視するため、byte で比較する。
            let matches = directoryBytes.count == separator && (separator == 0 || directoryBytes.withUnsafeBytes {
                memcmp($0.baseAddress!, bytes.baseAddress!, separator) == 0
            })
            if !matches {
                directoryBytes = Array(bytes.prefix(separator))
                directoryComponents = ranges.map { String(decoding: UnsafeBufferPointer(rebasing: bytes[$0]), as: UTF8.self) }
            }
            var result = directoryComponents
            if lower < bytes.count {
                result.append(String(decoding: UnsafeBufferPointer(rebasing: bytes[lower...]), as: UTF8.self))
            }
            return result
        }) { return components }
        directoryBytes = []
        directoryComponents = []
        return name.utf8.split(separator: 0x2f, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
    }
}

// 旧名。ZipParseSharingTests が参照する。
typealias ZipPathComponentSplitter = PathComponentSplitter
