import Darwin
import Foundation

/// Materializes a decoded single-file or decrypted compressed ZIP stream as a
/// random-access source. Small streams remain in memory; larger streams are moved
/// to an already-unlinked temporary file whose descriptor owns its lifetime.
enum SingleFileMaterializer {
    private static let bufferSize = 256 * 1_024
    private static let writeBufferSize = 4 * 1_024 * 1_024
    private static let spaceCheckInterval = 256 * 1_024 * 1_024

    // A task-local dependency keeps deterministic volume tests isolated from
    // other readers, including concurrent opens.
    @TaskLocal static var availableTemporarySpace: @Sendable () throws -> UInt64 = {
        var information = statvfs()
        guard statvfs(NSTemporaryDirectory(), &information) == 0 else {
            throw KaitoError.io(errno)
        }
        return try Checked.mul(UInt64(information.f_bavail), UInt64(information.f_frsize))
    }

    static func materialize(
        _ stream: EntryStream,
        limits: ReadLimits,
        inMemoryLimit: UInt64? = nil,
        sizeHint: UInt64? = nil
    ) throws -> any ByteSource {
        let memoryLimit = min(inMemoryLimit ?? limits.inMemorySingleFileLimit, limits.inMemorySingleFileLimit)
        // Declared sizes and the validated XZ layout select storage, but the stream
        // remains responsible for validating the actual output and its checksums.
        let boundedHint = sizeHint.flatMap { $0 <= limits.maxEntrySize ? $0 : nil }
        let knownSize = stream.remaining == UInt64.max ? boundedHint : stream.remaining
        let startsOnDisk = knownSize.map { $0 > memoryLimit } ?? false
        var memory = Data()
        let reserve = startsOnDisk ? 0 : min(memoryLimit, knownSize ?? UInt64(Self.bufferSize), limits.maxEntrySize)
        memory.reserveCapacity(try Checked.toInt(reserve))

        var descriptor: Int32 = -1
        var bytesSinceSpaceCheck = 0
        var decodedSize: UInt64 = 0
        var deferredWriteError: (any Error)?
        // Keep each decode call at its original size, but coalesce short output
        // chunks directly in a bounded buffer instead of writing each one.
        let capacity = startsOnDisk ? Int(min(knownSize!, UInt64(writeBufferSize))) : bufferSize
        var buffer = [UInt8](repeating: 0, count: capacity)
        var pendingCount = 0
        func flushPending() throws {
            let count = pendingCount
            pendingCount = 0 // A failed / partial write must never be retried by the outer catch.
            try buffer.withUnsafeBytes {
                try writeStaged(UnsafeRawBufferPointer(rebasing: $0[..<count]), to: descriptor,
                                limits: limits, bytesSinceSpaceCheck: &bytesSinceSpaceCheck)
            }
        }
        defer {
            if descriptor >= 0 {
                _ = Darwin.close(descriptor)
            }
        }

        do {
            while true {
                try Task.checkCancellation()
                let requested = min(bufferSize, buffer.count - pendingCount)
                let count = try buffer.withUnsafeMutableBytes { storage in
                    try stream.read(into: UnsafeMutableRawBufferPointer(
                        rebasing: storage[pendingCount..<(pendingCount + requested)]))
                }
                guard count >= 0, count <= requested else {
                    throw KaitoError.malformed("single-file stream returned an invalid byte count")
                }
                guard count > 0 else { break }

                let previousSize = decodedSize
                decodedSize = try Checked.add(decodedSize, UInt64(count))
                // A spooling failure must not mask a decode error in the prefix
                // that previously stayed in memory. Keep its historical spill point.
                if let deferredWriteError {
                    if decodedSize > memoryLimit { throw deferredWriteError }
                    continue
                }
                if descriptor < 0, !startsOnDisk, decodedSize <= memoryLimit {
                    memory.append(contentsOf: buffer[..<count])
                    continue
                }

                do {
                    if descriptor < 0 {
                        try checkTemporarySpace(limits: limits)
                        descriptor = try openUnlinkedTemporaryFile()
                        try memory.withUnsafeBytes { bytes in
                            try writeStaged(bytes, to: descriptor, limits: limits,
                                            bytesSinceSpaceCheck: &bytesSinceSpaceCheck)
                        }
                        memory.removeAll(keepingCapacity: false)
                    }
                    pendingCount += count
                    if !startsOnDisk || pendingCount == buffer.count
                        || (previousSize <= memoryLimit && decodedSize > memoryLimit) {
                        try flushPending()
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    pendingCount = 0
                    guard startsOnDisk, decodedSize <= memoryLimit else { throw error }
                    deferredWriteError = error
                }
            }
        } catch {
            // After the old spill point, earlier acknowledged output was written
            // before the next decode / cancellation check. Flush that prefix first
            // so an I/O failure keeps the same precedence over a later read error.
            if decodedSize > memoryLimit, deferredWriteError == nil, pendingCount > 0 {
                try flushPending()
            }
            throw error
        }

        if let deferredWriteError { throw deferredWriteError }
        try flushPending()
        guard descriptor >= 0 else {
            return DataByteSource(data: memory)
        }
        let source = FileByteSource(
            takingOwnershipOfValidatedDescriptor: descriptor,
            length: decodedSize
        )
        descriptor = -1
        return source
    }

    private static func checkTemporarySpace(limits: ReadLimits) throws {
        guard try availableTemporarySpace() >= limits.stagingFreeSpaceReserve else {
            throw KaitoError.limitExceeded("staging free space")
        }
    }

    private static func writeStaged(
        _ bytes: UnsafeRawBufferPointer,
        to descriptor: Int32,
        limits: ReadLimits,
        bytesSinceSpaceCheck: inout Int
    ) throws {
        var offset = 0
        while offset < bytes.count {
            if bytesSinceSpaceCheck == spaceCheckInterval {
                try checkTemporarySpace(limits: limits)
                bytesSinceSpaceCheck = 0
            }
            // The initial in-memory prefix can itself exceed an interval.
            // Bound each write so that spilling that prefix also checks space.
            let count = min(bytes.count - offset, spaceCheckInterval - bytesSinceSpaceCheck)
            try writeAll(UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + count)]),
                         to: descriptor)
            bytesSinceSpaceCheck += count
            offset += count
        }
    }

    private static func openUnlinkedTemporaryFile() throws -> Int32 {
        let directory = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        )
        // O_EXCL makes each candidate private to this process. Unlinking it
        // immediately leaves the returned descriptor as its only lifetime.
        for _ in 0..<16 {
            let path = directory
                .appendingPathComponent("KaitoKit-\(UUID().uuidString).tmp")
                .path
            let descriptor = Darwin.open(
                path,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC,
                mode_t(0o600)
            )
            if descriptor >= 0 {
                guard Darwin.unlink(path) == 0 else {
                    let code = errno
                    _ = Darwin.close(descriptor)
                    throw KaitoError.io(code)
                }
                return descriptor
            }
            if errno != EEXIST {
                throw KaitoError.io(errno)
            }
        }
        throw KaitoError.io(EEXIST)
    }
}
