import Darwin
import Foundation

/// Materializes a decoded single-file or decrypted compressed ZIP stream as a
/// random-access source. Small streams remain in memory; larger streams are moved
/// to an already-unlinked temporary file whose descriptor owns its lifetime.
enum SingleFileMaterializer {
    private static let bufferSize = 256 * 1_024
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
        limits: ReadLimits
    ) throws -> any ByteSource {
        var memory = Data()
        let reserve = min(
            limits.inMemorySingleFileLimit,
            UInt64(Self.bufferSize)
        )
        memory.reserveCapacity(try Checked.toInt(reserve))

        var descriptor: Int32 = -1
        var bytesSinceSpaceCheck = 0
        var decodedSize: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        defer {
            if descriptor >= 0 {
                _ = Darwin.close(descriptor)
            }
        }

        while true {
            try Task.checkCancellation()
            let count = try buffer.withUnsafeMutableBytes { storage in
                try stream.read(into: storage)
            }
            guard count >= 0, count <= buffer.count else {
                throw KaitoError.malformed("single-file stream returned an invalid byte count")
            }
            guard count > 0 else { break }

            decodedSize = try Checked.add(decodedSize, UInt64(count))
            if descriptor < 0,
               decodedSize <= limits.inMemorySingleFileLimit {
                memory.append(contentsOf: buffer[..<count])
                continue
            }

            if descriptor < 0 {
                try checkTemporarySpace(limits: limits)
                descriptor = try openUnlinkedTemporaryFile()
                try memory.withUnsafeBytes { bytes in
                    try writeStaged(bytes, to: descriptor, limits: limits,
                                    bytesSinceSpaceCheck: &bytesSinceSpaceCheck)
                }
                memory.removeAll(keepingCapacity: false)
            }
            try buffer.withUnsafeBytes { bytes in
                try writeStaged(
                    UnsafeRawBufferPointer(rebasing: bytes[..<count]),
                    to: descriptor,
                    limits: limits,
                    bytesSinceSpaceCheck: &bytesSinceSpaceCheck
                )
            }
        }

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

    private static func writeAll(
        _ bytes: UnsafeRawBufferPointer,
        to descriptor: Int32
    ) throws {
        guard !bytes.isEmpty else { return }
        guard let baseAddress = bytes.baseAddress else {
            throw KaitoError.malformed("temporary-file buffer has no storage")
        }

        var written = 0
        while written < bytes.count {
            let result = Darwin.write(
                descriptor,
                baseAddress.advanced(by: written),
                bytes.count - written
            )
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { throw KaitoError.io(errno) }
            written += result
        }
    }
}
