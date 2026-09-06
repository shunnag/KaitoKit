import Foundation

/// A forward-only stream for one archive entry.
///
/// Instances are stateful and are not thread-safe. A stream enforces the
/// reader's per-entry and in-memory limits independently of archive metadata.
public final class EntryStream {
    private let decompressor: any Decompressor
    private var bytesRemaining: UInt64
    private let inMemoryLimit: UInt64
    private let expectedCRC32: UInt32?
    private let entryIndex: Int
    private let completionCheck: (() throws -> Void)?
    private var checksum = CRC32()
    private var completionWasVerified = false

    /// The number of bytes that have not yet been read.
    public var remaining: UInt64 { bytesRemaining }

    init(
        source: any ByteSource,
        offset: UInt64,
        length: UInt64,
        limits: ReadLimits
    ) throws {
        try Checked.size(length, limit: limits.maxEntrySize)
        self.decompressor = try CopyDecompressor(
            source: source,
            offset: offset,
            compressedSize: length
        )
        self.bytesRemaining = length
        self.inMemoryLimit = limits.maxInMemorySize
        self.expectedCRC32 = nil
        self.entryIndex = -1
        self.completionCheck = nil
        if length == 0 {
            try verifyCompletion()
        }
    }

    init(
        decompressor: any Decompressor,
        length: UInt64,
        expectedCRC32: UInt32?,
        entryIndex: Int,
        limits: ReadLimits,
        completionCheck: (() throws -> Void)? = nil
    ) throws {
        try Checked.size(length, limit: limits.maxEntrySize)
        self.decompressor = decompressor
        self.bytesRemaining = length
        self.inMemoryLimit = limits.maxInMemorySize
        self.expectedCRC32 = expectedCRC32
        self.entryIndex = entryIndex
        self.completionCheck = completionCheck
        if length == 0 {
            try verifyCompletion()
        }
    }

    /// Reads up to `buffer.count` bytes and returns the number read.
    public func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty else { return 0 }
        if bytesRemaining == 0 {
            try verifyCompletion()
            return 0
        }
        let requested = min(UInt64(buffer.count), bytesRemaining)
        let count = try Checked.toInt(requested)

        // 不変条件: count は buffer.count 以下で、復号器へ公開する領域は呼出側バッファ内だけ。
        let destination = UnsafeMutableRawBufferPointer(rebasing: buffer[..<count])
        let actual = try decompressor.read(into: destination)
        guard actual >= 0, actual <= count else {
            throw KaitoError.malformed("decompressor returned an invalid byte count")
        }
        guard actual > 0 else {
            throw KaitoError.truncated
        }

        let amount = UInt64(actual)
        bytesRemaining = try Checked.sub(bytesRemaining, amount)
        checksum.update(UnsafeRawBufferPointer(rebasing: buffer[..<actual]))
        if bytesRemaining == 0 {
            // 最終チャンクを呼出側へ渡す前に、終端・認証・CRC を全て確定する。
            try verifyCompletion()
        }
        return actual
    }

    /// Reads the remaining entry bytes into one exactly sized `Data` value.
    public func readAll() throws -> Data {
        try Checked.size(bytesRemaining, limit: inMemoryLimit)
        let size = try Checked.toInt(bytesRemaining)
        guard size > 0 else {
            var byte: UInt8 = 0
            _ = try withUnsafeMutableBytes(of: &byte) { storage in
                try read(into: storage)
            }
            return Data()
        }

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

    private func verifyCompletion() throws {
        guard !completionWasVerified else { return }

        if !decompressor.isFinished {
            var byte: UInt8 = 0
            let additional = try withUnsafeMutableBytes(of: &byte) { storage in
                try decompressor.read(into: storage)
            }
            guard additional >= 0, additional <= 1 else {
                throw KaitoError.malformed("decompressor returned an invalid byte count")
            }
            guard additional == 0 else {
                throw KaitoError.malformed("entry output exceeds its declared size")
            }
            guard decompressor.isFinished else {
                throw KaitoError.truncated
            }
        }

        try completionCheck?()
        if let expectedCRC32, checksum.value != expectedCRC32 {
            throw KaitoError.checksumMismatch(entry: entryIndex)
        }
        completionWasVerified = true
    }
}
