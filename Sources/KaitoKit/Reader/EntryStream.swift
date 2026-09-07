import Foundation

/// A forward-only stream for one archive entry.
///
/// Instances are stateful and are not thread-safe. A stream enforces the
/// reader's per-entry and in-memory limits independently of archive metadata.
public final class EntryStream {
    private let decompressor: any Decompressor
    private var bytesRemaining: UInt64?
    private var bytesProduced: UInt64 = 0
    private let entrySizeLimit: UInt64
    private let inMemoryLimit: UInt64
    private let expectedCRC32: UInt32?
    private let expectedCRC16: UInt16?
    private let entryIndex: Int
    private let completionCheck: (() throws -> Void)?
    private let checksumMismatchIsWrongPassword: Bool
    private let crc32Transform: ((UInt32) -> UInt32)?
    private var checksum = CRC32()
    private var checksum16 = CRC16()
    private var completionWasVerified = false
    private var terminalError: Error?

    /// The number of bytes that have not yet been read.
    /// For streams whose format does not declare a size, this is `UInt64.max`
    /// until the decoder reaches its authenticated end marker, then zero.
    public var remaining: UInt64 {
        bytesRemaining ?? (completionWasVerified ? 0 : UInt64.max)
    }

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
        self.entrySizeLimit = limits.maxEntrySize
        self.inMemoryLimit = limits.maxInMemorySize
        self.expectedCRC32 = nil
        self.expectedCRC16 = nil
        self.entryIndex = -1
        self.completionCheck = nil
        self.checksumMismatchIsWrongPassword = false
        self.crc32Transform = nil
        if length == 0 {
            try verifyCompletion()
        }
    }

    init(
        decompressor: any Decompressor,
        length: UInt64?,
        expectedCRC32: UInt32?,
        expectedCRC16: UInt16? = nil,
        entryIndex: Int,
        limits: ReadLimits,
        completionCheck: (() throws -> Void)? = nil,
        checksumMismatchIsWrongPassword: Bool = false,
        crc32Transform: ((UInt32) -> UInt32)? = nil
    ) throws {
        if let length {
            try Checked.size(length, limit: limits.maxEntrySize)
        }
        self.decompressor = decompressor
        self.bytesRemaining = length
        self.entrySizeLimit = limits.maxEntrySize
        self.inMemoryLimit = limits.maxInMemorySize
        self.expectedCRC32 = expectedCRC32
        self.expectedCRC16 = expectedCRC16
        self.entryIndex = entryIndex
        self.completionCheck = completionCheck
        self.checksumMismatchIsWrongPassword = checksumMismatchIsWrongPassword
        self.crc32Transform = crc32Transform
        if length == 0 || (length == nil && decompressor.isFinished) {
            try verifyCompletion()
        }
    }

    /// Reads up to `buffer.count` bytes and returns the number read.
    public func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if let terminalError { throw terminalError }
        do {
            return try readOnce(into: buffer)
        } catch {
            terminalError = error
            throw error
        }
    }

    private func readOnce(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty else { return 0 }
        if bytesRemaining == 0 {
            try verifyCompletion()
            return 0
        }
        let remainingLimit = try Checked.sub(entrySizeLimit, bytesProduced)
        if bytesRemaining == nil, remainingLimit == 0 {
            try verifyUnknownLengthAtLimit()
            return 0
        }
        let requested = min(
            UInt64(buffer.count),
            bytesRemaining ?? remainingLimit
        )
        let count = try Checked.toInt(requested)

        // 不変条件: count は buffer.count 以下で、復号器へ公開する領域は呼出側バッファ内だけ。
        let destination = UnsafeMutableRawBufferPointer(rebasing: buffer[..<count])
        let actual = try decompressor.read(into: destination)
        guard actual >= 0, actual <= count else {
            throw KaitoError.malformed("decompressor returned an invalid byte count")
        }
        guard actual > 0 else {
            if bytesRemaining == nil, decompressor.isFinished {
                try verifyCompletion()
                return 0
            }
            throw KaitoError.truncated
        }

        let amount = UInt64(actual)
        if let remaining = bytesRemaining {
            bytesRemaining = try Checked.sub(remaining, amount)
        }
        bytesProduced = try Checked.add(bytesProduced, amount)
        try Checked.size(bytesProduced, limit: entrySizeLimit)
        checksum.update(UnsafeRawBufferPointer(rebasing: buffer[..<actual]))
        if expectedCRC16 != nil {
            checksum16.update(UnsafeRawBufferPointer(rebasing: buffer[..<actual]))
        }
        if bytesRemaining == 0 || (bytesRemaining == nil && decompressor.isFinished) {
            // 最終チャンクを呼出側へ渡す前に、終端・認証・CRC を全て確定する。
            try verifyCompletion()
        }
        return actual
    }

    /// Reads the remaining entry bytes into one exactly sized `Data` value.
    public func readAll() throws -> Data {
        if let terminalError { throw terminalError }
        guard let bytesRemaining else {
            do {
                return try readAllUnknownLength()
            } catch {
                // Unknown-length reads may discover an in-memory limit only
                // after consuming decoder output. Keep that failure terminal
                // just like errors raised by read(into:).
                terminalError = error
                throw error
            }
        }
        try Checked.size(bytesRemaining, limit: inMemoryLimit)
        let size = try Checked.toInt(bytesRemaining)
        guard size > 0 else {
            var byte: UInt8 = 0
            _ = try withUnsafeMutableBytes(of: &byte) { storage in
                try read(into: storage)
            }
            return Data()
        }

        if size >= CopyDecompressor.directReadMinimumSize,
           let copy = decompressor as? CopyDecompressor {
            do {
                return try readAllDirectly(from: copy, size: size)
            } catch {
                terminalError = error
                throw error
            }
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

    private func readAllDirectly(
        from decompressor: CopyDecompressor,
        size: Int
    ) throws -> Data {
        // Data(count:) の初期化書込みを避ける。Data がこの一つの allocation を
        // 引き取り、ByteSource は最終返却領域へ直接書き込む。
        let allocation = UnsafeMutableRawPointer.allocate(
            byteCount: size,
            alignment: MemoryLayout<UInt64>.alignment
        )
        var result = Data(
            bytesNoCopy: allocation,
            count: size,
            deallocator: .custom { pointer, _ in pointer.deallocate() }
        )
        let written = try result.withUnsafeMutableBytes { storage in
            try decompressor.readDirectly(into: storage) { [self] bytes in
                // bytes は result の初期化済み部分だけを指す。CRC は返却前に逐次更新する。
                guard let currentRemaining = bytesRemaining else {
                    throw KaitoError.malformed("direct read used for an unknown-size entry")
                }
                let remaining = try Checked.sub(currentRemaining, UInt64(bytes.count))
                checksum.update(bytes)
                if expectedCRC16 != nil {
                    checksum16.update(bytes)
                }
                bytesRemaining = remaining
                bytesProduced = try Checked.add(bytesProduced, UInt64(bytes.count))
            }
        }
        guard written == size else { throw KaitoError.truncated }

        // Copy の範囲終端、暗号認証、CRC を Data の公開前に全て確定する。
        try verifyCompletion()
        return result
    }

    private func readAllUnknownLength() throws -> Data {
        let effectiveLimit = min(entrySizeLimit, inMemoryLimit)
        var result = Data()
        result.reserveCapacity(try Checked.toInt(min(effectiveLimit, 256 * 1_024)))
        var buffer = [UInt8](repeating: 0, count: 256 * 1_024)

        while !completionWasVerified {
            let count = try buffer.withUnsafeMutableBytes { storage in
                try read(into: storage)
            }
            guard count > 0 else { break }
            let newCount = try Checked.add(UInt64(result.count), UInt64(count))
            try Checked.size(newCount, limit: effectiveLimit)
            result.append(contentsOf: buffer[..<count])
        }
        return result
    }

    private func verifyUnknownLengthAtLimit() throws {
        guard !decompressor.isFinished else {
            try verifyCompletion()
            return
        }
        var byte: UInt8 = 0
        let additional = try withUnsafeMutableBytes(of: &byte) { storage in
            try decompressor.read(into: storage)
        }
        guard additional >= 0, additional <= 1 else {
            throw KaitoError.malformed("decompressor returned an invalid byte count")
        }
        if additional != 0 {
            throw KaitoError.limitExceeded("entry size")
        }
        guard decompressor.isFinished else { throw KaitoError.truncated }
        try verifyCompletion()
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
        let actualCRC32 = crc32Transform?(checksum.value) ?? checksum.value
        if let expectedCRC32, actualCRC32 != expectedCRC32 {
            if checksumMismatchIsWrongPassword {
                // 7zAES は独立した認証 tag を持たないため CRC を password 判定に使う。
                throw KaitoError.wrongPassword
            }
            throw KaitoError.checksumMismatch(entry: entryIndex)
        }
        if let expectedCRC16, checksum16.value != expectedCRC16 {
            throw KaitoError.checksumMismatch(entry: entryIndex)
        }
        completionWasVerified = true
    }
}
