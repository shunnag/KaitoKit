import Darwin
import Foundation

/// Materializes a decoded single-file stream as a random-access source for a
/// container reader. Small streams remain in memory; larger streams are moved
/// to an already-unlinked temporary file whose descriptor owns its lifetime.
enum SingleFileMaterializer {
    private static let bufferSize = 256 * 1_024

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
        var decodedSize: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        defer {
            if descriptor >= 0 {
                _ = Darwin.close(descriptor)
            }
        }

        while true {
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
                descriptor = try openUnlinkedTemporaryFile()
                try memory.withUnsafeBytes { bytes in
                    try writeAll(bytes, to: descriptor)
                }
                memory.removeAll(keepingCapacity: false)
            }
            try buffer.withUnsafeBytes { bytes in
                try writeAll(
                    UnsafeRawBufferPointer(rebasing: bytes[..<count]),
                    to: descriptor
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
