import Foundation

/// A forward-only stream for one archive entry.
///
/// Instances are stateful and are not thread-safe. A stream enforces the
/// reader's per-entry and in-memory limits independently of archive metadata.
public final class EntryStream {
    private let source: any ByteSource
    private var offset: UInt64
    private var bytesRemaining: UInt64
    private let inMemoryLimit: UInt64

    /// The number of bytes that have not yet been read.
    public var remaining: UInt64 { bytesRemaining }

    init(
        source: any ByteSource,
        offset: UInt64,
        length: UInt64,
        limits: ReadLimits
    ) throws {
        try Checked.size(length, limit: limits.maxEntrySize)
        let end = try Checked.add(offset, length)
        guard end <= source.length else {
            throw KaitoError.truncated
        }
        self.source = source
        self.offset = offset
        self.bytesRemaining = length
        self.inMemoryLimit = limits.maxInMemorySize
    }

    /// Reads up to `buffer.count` bytes and returns the number read.
    public func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, bytesRemaining > 0 else { return 0 }
        let requested = min(UInt64(buffer.count), bytesRemaining)
        let count = try Checked.toInt(requested)

        // 不変条件: count は buffer.count 以下で、渡す領域は必ず呼出側バッファ内に収まる。
        let destination = UnsafeMutableRawBufferPointer(rebasing: buffer[..<count])
        let actual = try source.read(into: destination, at: offset)
        guard actual >= 0, actual <= count else {
            throw KaitoError.malformed("ByteSource returned an invalid byte count")
        }
        guard actual > 0 else {
            throw KaitoError.truncated
        }

        let amount = UInt64(actual)
        offset = try Checked.add(offset, amount)
        bytesRemaining = try Checked.sub(bytesRemaining, amount)
        return actual
    }

    /// Reads the remaining entry bytes into one exactly sized `Data` value.
    public func readAll() throws -> Data {
        try Checked.size(bytesRemaining, limit: inMemoryLimit)
        let size = try Checked.toInt(bytesRemaining)
        guard size > 0 else { return Data() }

        var result = Data(count: size)
        var written = 0
        try result.withUnsafeMutableBytes { storage in
            // 不変条件: written...size は確保済み Data の範囲で、read は残量以下しか書かない。
            while written < size {
                let destination = UnsafeMutableRawBufferPointer(rebasing: storage[written..<size])
                let count = try read(into: destination)
                guard count > 0 else { throw KaitoError.truncated }
                written += count
            }
        }
        return result
    }
}
