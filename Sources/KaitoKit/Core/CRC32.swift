import Foundation
private import zlib

/// An incremental CRC-32 calculator backed by the system zlib implementation.
///
/// The system implementation is used because the platform-tuned kernel is
/// substantially faster than a Swift lookup-table implementation.
public struct CRC32: Sendable {
    private var state: uLong

    /// Creates an empty CRC-32 calculation.
    public init() {
        self.state = zlib.crc32(0, nil, 0)
    }

    /// Current CRC-32 value.
    public var value: UInt32 {
        UInt32(truncatingIfNeeded: state)
    }

    /// Adds data to the calculation.
    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { buffer in
            update(buffer)
        }
    }

    /// Adds bytes to the calculation.
    public mutating func update(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { buffer in
            update(buffer)
        }
    }

    /// Calculates the CRC-32 of a data value.
    public static func checksum(_ data: Data) -> UInt32 {
        var checksum = CRC32()
        checksum.update(data)
        return checksum.value
    }

    /// Calculates the CRC-32 of a byte array.
    public static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var checksum = CRC32()
        checksum.update(bytes)
        return checksum.value
    }

    // 同一 module のストリームが、コピーせず caller 所有範囲を加算する。
    mutating func update(_ buffer: UnsafeRawBufferPointer) {
        guard let baseAddress = buffer.baseAddress else {
            return
        }

        var position = 0
        while position < buffer.count {
            let count = min(buffer.count - position, Int(UInt32.max))
            // position + count は buffer.count 以下で、zlib はクロージャ中だけこの領域を参照する。
            let pointer = baseAddress.advanced(by: position).assumingMemoryBound(to: Bytef.self)
            state = zlib.crc32(state, pointer, uInt(count))
            position += count
        }
    }
}
