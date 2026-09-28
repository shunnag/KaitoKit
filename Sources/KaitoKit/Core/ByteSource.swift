import Foundation

/// A random-access source of immutable archive bytes.
public protocol ByteSource: Sendable {
    /// Total number of readable bytes.
    var length: UInt64 { get }

    /// Reads bytes at an absolute offset without changing shared cursor state.
    ///
    /// The method returns zero at end of input and never reads beyond `length`.
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int
}

// 形式 parser が検証済みの一範囲を一括取得するための共通 primitive。
// 通常の FileByteSource では最初の pread が全範囲を返し、短い実装だけ継続する。
func readByteRange(
    source: any ByteSource,
    offset: UInt64,
    count: Int
) throws -> [UInt8] {
    guard count >= 0 else {
        throw KaitoError.malformed("negative byte-range size")
    }
    let end = try Checked.add(offset, UInt64(count))
    guard end <= source.length else { throw KaitoError.truncated }
    guard count > 0 else { return [] }

    var result = [UInt8](repeating: 0, count: count)
    var filled = 0
    while filled < count {
        let readOffset = try Checked.add(offset, UInt64(filled))
        let actual = try result.withUnsafeMutableBytes { storage in
            // filled..<count は未充填の確保済み領域で、source へそれ以外を公開しない。
            try source.read(
                into: UnsafeMutableRawBufferPointer(rebasing: storage[filled..<count]),
                at: readOffset
            )
        }
        guard actual > 0, actual <= count - filled else {
            throw KaitoError.truncated
        }
        filled += actual
    }
    return result
}
