import Foundation

/// A byte source that retains a `Data` value without copying its storage.
public final class DataByteSource: ByteSource {
    // internal にして、テストでは COW ストレージの同一性を直接確認できるようにする。
    let data: Data

    /// Total number of bytes in the retained data.
    public var length: UInt64 {
        UInt64(data.count)
    }

    /// Retains a data value using `Data` copy-on-write semantics.
    public init(data: Data) {
        self.data = data
    }

    /// Retains a data value using `Data` copy-on-write semantics.
    public convenience init(_ data: Data) {
        self.init(data: data)
    }

    /// Copies a requested range into the caller-provided buffer.
    public func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        guard !buffer.isEmpty, offset < length else {
            return 0
        }

        let available = try Checked.sub(length, offset)
        let count = try Checked.toInt(min(UInt64(buffer.count), available))
        let start = try Checked.toInt(offset)
        guard count > 0, let destination = buffer.baseAddress else {
            return 0
        }

        return data.withUnsafeBytes { sourceBuffer in
            guard let source = sourceBuffer.baseAddress else {
                return 0
            }
            // start + count は上の length 検証済みで、両ポインタの有効領域は count バイト以上。
            destination.copyMemory(from: source.advanced(by: start), byteCount: count)
            return count
        }
    }
}
