import Foundation

/// A buffered cursor over a random-access byte source.
public struct ByteReader {
    /// Size of the internal read buffer.
    public static let bufferSize = 256 * 1_024

    private let source: any ByteSource
    private var buffer: [UInt8]
    private var bufferStart: UInt64
    private var bufferCount: Int
    private var bufferOffset: Int

    /// Current absolute cursor offset.
    public private(set) var offset: UInt64

    /// Number of bytes remaining after the cursor.
    public var remaining: UInt64 {
        source.length >= offset ? source.length - offset : 0
    }

    /// Creates a buffered reader positioned at an absolute offset.
    public init(source: any ByteSource, offset: UInt64 = 0) throws {
        try self.init(source: source, offset: offset, bufferCapacity: Self.bufferSize)
    }

    /// Internal cursors can use a smaller, caller-bounded read-ahead window.
    /// A one-byte minimum permits scalar header validation even with a zero
    /// metadata budget; no archive-declared size controls this allocation.
    init(source: any ByteSource, offset: UInt64 = 0, bufferCapacity: Int) throws {
        guard offset <= source.length else {
            throw KaitoError.truncated
        }
        self.source = source
        self.buffer = [UInt8](repeating: 0, count: max(1, min(Self.bufferSize, bufferCapacity)))
        self.bufferStart = offset
        self.bufferCount = 0
        self.bufferOffset = 0
        self.offset = offset
    }

    /// Moves the cursor to an absolute offset.
    public mutating func seek(to newOffset: UInt64) throws {
        guard newOffset <= source.length else {
            throw KaitoError.truncated
        }

        let bufferEnd = try Checked.add(bufferStart, UInt64(bufferCount))
        if newOffset >= bufferStart, newOffset <= bufferEnd {
            bufferOffset = try Checked.toInt(try Checked.sub(newOffset, bufferStart))
        } else {
            bufferStart = newOffset
            bufferCount = 0
            bufferOffset = 0
        }
        offset = newOffset
    }

    /// Reads one byte.
    public mutating func readUInt8() throws -> UInt8 {
        if bufferOffset >= bufferCount {
            try refill()
        }
        guard bufferOffset < bufferCount else {
            throw KaitoError.truncated
        }

        let value = buffer[bufferOffset]
        bufferOffset += 1
        offset = try Checked.add(offset, 1)
        return value
    }

    /// Reads a little-endian 16-bit unsigned integer.
    public mutating func readUInt16LE() throws -> UInt16 {
        var value: UInt16 = 0
        for shift in stride(from: 0, to: 16, by: 8) {
            value |= UInt16(try readUInt8()) << shift
        }
        return value
    }

    /// Reads a big-endian 16-bit unsigned integer.
    public mutating func readUInt16BE() throws -> UInt16 {
        var value: UInt16 = 0
        for _ in 0..<2 {
            value = (value << 8) | UInt16(try readUInt8())
        }
        return value
    }

    /// Reads a little-endian 32-bit unsigned integer.
    public mutating func readUInt32LE() throws -> UInt32 {
        var value: UInt32 = 0
        for shift in stride(from: 0, to: 32, by: 8) {
            value |= UInt32(try readUInt8()) << shift
        }
        return value
    }

    /// Reads a big-endian 32-bit unsigned integer.
    public mutating func readUInt32BE() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            value = (value << 8) | UInt32(try readUInt8())
        }
        return value
    }

    /// Reads a little-endian 64-bit unsigned integer.
    public mutating func readUInt64LE() throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, to: 64, by: 8) {
            value |= UInt64(try readUInt8()) << shift
        }
        return value
    }

    /// Reads a big-endian 64-bit unsigned integer.
    public mutating func readUInt64BE() throws -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<8 {
            value = (value << 8) | UInt64(try readUInt8())
        }
        return value
    }

    /// Reads an exact number of bytes.
    public mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0 else {
            throw KaitoError.malformed("negative byte count")
        }
        guard UInt64(count) <= remaining else {
            throw KaitoError.truncated
        }
        if count == 0 {
            return Data()
        }

        var result = Data()
        result.reserveCapacity(count)
        var needed = count
        while needed > 0 {
            if bufferOffset >= bufferCount {
                try refill()
            }
            guard bufferOffset < bufferCount else {
                throw KaitoError.truncated
            }

            let available = bufferCount - bufferOffset
            let amount = min(needed, available)
            result.append(contentsOf: buffer[bufferOffset..<(bufferOffset + amount)])
            bufferOffset += amount
            offset = try Checked.add(offset, UInt64(amount))
            needed -= amount
        }
        return result
    }

    private mutating func refill() throws {
        guard offset < source.length else {
            throw KaitoError.truncated
        }

        bufferStart = offset
        bufferOffset = 0
        let source = self.source
        let currentOffset = offset
        // buffer は固定長で、クロージャの間は再確保されず rawBuffer 全域が書き込み可能。
        let count = try buffer.withUnsafeMutableBytes { rawBuffer in
            try source.read(into: rawBuffer, at: currentOffset)
        }
        let available = try Checked.sub(source.length, currentOffset)
        let maximum = try Checked.toInt(min(UInt64(buffer.count), available))
        guard count > 0, count <= maximum else {
            throw KaitoError.truncated
        }
        bufferCount = count
    }
}
