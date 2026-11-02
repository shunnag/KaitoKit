import Foundation

// RAR13_FORMAT_SPECIFICATION.md §7 and UNRAR 7.23 black-box archives.
struct RAR13LegacyCipher: Sendable {
    private var key0: UInt8
    private var key1: UInt8
    private var key2: UInt8

    init(password: [UInt8]) {
        key0 = 0
        key1 = 0
        key2 = 0
        for byte in password {
            key0 &+= byte
            key1 ^= byte
            key2 &+= byte
            key2 = (key2 << 1) | (key2 >> 7)
        }
    }

    init(key0: UInt8, key1: UInt8, key2: UInt8) {
        self.key0 = key0
        self.key1 = key1
        self.key2 = key2
    }

    mutating func decrypt(_ byte: UInt8) -> UInt8 {
        key1 &+= key2
        key0 &+= key1
        return byte &- key0
    }

    static func decryptComment(_ bytes: [UInt8]) -> [UInt8] {
        var cipher = RAR13LegacyCipher(key0: 0, key1: 7, key2: 77)
        return bytes.map { cipher.decrypt($0) }
    }
}

final class RAR13EncryptedByteSource: ByteSource {
    private let source: any ByteSource
    private let offset: UInt64
    private let initialCipher: RAR13LegacyCipher
    let length: UInt64

    init(
        source: any ByteSource,
        offset: UInt64,
        length: UInt64,
        password: String
    ) throws {
        guard password.utf8.allSatisfy({ $0 < 0x80 }) else {
            throw KaitoError.unsupportedMethod("RAR1.3 password must be ASCII")
        }
        let end = try Checked.add(offset, length)
        guard end <= source.length else { throw KaitoError.truncated }
        self.source = source
        self.offset = offset
        self.length = length
        initialCipher = RAR13LegacyCipher(password: Array(password.utf8))
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, at readOffset: UInt64) throws -> Int {
        guard !buffer.isEmpty, readOffset < length else { return 0 }
        var cipher = initialCipher
        if readOffset > 0 {
            var scratch = [UInt8](repeating: 0, count: Int(min(readOffset, 64 * 1_024)))
            var remaining = readOffset
            var sourceOffset = offset
            while remaining > 0 {
                let requested = min(scratch.count, Int(remaining))
                let count = try scratch.withUnsafeMutableBytes { destination in
                    try source.read(
                        into: UnsafeMutableRawBufferPointer(rebasing: destination.prefix(requested)),
                        at: sourceOffset
                    )
                }
                guard count > 0, count <= requested else { throw KaitoError.truncated }
                for index in 0..<count { _ = cipher.decrypt(scratch[index]) }
                sourceOffset = try Checked.add(sourceOffset, UInt64(count))
                remaining -= UInt64(count)
            }
        }
        let requested = min(buffer.count, Int(length - readOffset))
        let count = try source.read(
            into: UnsafeMutableRawBufferPointer(rebasing: buffer.prefix(requested)),
            at: try Checked.add(offset, readOffset)
        )
        guard count > 0, count <= requested else { throw KaitoError.truncated }
        for index in 0..<count { buffer[index] = cipher.decrypt(buffer[index]) }
        return count
    }
}
