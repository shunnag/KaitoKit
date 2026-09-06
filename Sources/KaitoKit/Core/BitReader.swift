import Foundation

/// A bit reader whose first bit is the least-significant bit of each byte.
///
/// Reads may request from zero through 32 bits. Reading beyond the supplied
/// buffer returns zero for missing bits and sets `overrun`; callers must check
/// that flag before accepting parsed data.
public struct LSBFirstBitReader: Sendable {
    private let bytes: [UInt8]
    private var byteOffset: Int
    private var reservoir: UInt64
    private var availableBits: Int
    private var alignment: Int

    /// Indicates that an operation requested bits beyond the input buffer.
    public private(set) var overrun: Bool

    /// Indicates that no real input bits remain.
    public var isExhausted: Bool {
        byteOffset >= bytes.count && availableBits == 0
    }

    /// Creates a reader over a byte array.
    public init(bytes: [UInt8]) {
        self.bytes = bytes
        self.byteOffset = 0
        self.reservoir = 0
        self.availableBits = 0
        self.alignment = 0
        self.overrun = false
    }

    /// Creates a reader over a data value.
    public init(data: Data) {
        self.init(bytes: Array(data))
    }

    /// Returns upcoming bits without advancing the logical position.
    public mutating func peek(_ count: Int) throws -> UInt32 {
        try validateBitCount(count)
        guard count > 0 else {
            return 0
        }
        refill(for: count)
        if availableBits < count {
            overrun = true
        }
        let mask = (UInt64(1) << count) - 1
        return UInt32(truncatingIfNeeded: reservoir & mask)
    }

    /// Advances over a number of bits.
    public mutating func consume(_ count: Int) throws {
        try validateBitCount(count)
        consumeValidated(count)
    }

    /// Reads and advances over a number of bits.
    public mutating func read(_ count: Int) throws -> UInt32 {
        let value = try peek(count)
        try consume(count)
        return value
    }

    /// Advances to the next byte boundary.
    public mutating func byteAlign() {
        let count = (8 - alignment) & 7
        consumeValidated(count)
    }

    private mutating func refill(for requested: Int) {
        while availableBits < requested, byteOffset < bytes.count {
            // availableBits は refill 開始時に 0...31 なので、64 bit reservoir 内へのシフトになる。
            reservoir |= UInt64(bytes[byteOffset]) << availableBits
            byteOffset += 1
            availableBits += 8
        }
    }

    private mutating func consumeValidated(_ count: Int) {
        guard count > 0 else {
            return
        }
        refill(for: count)
        alignment = (alignment + count) & 7
        if count >= availableBits {
            if count > availableBits {
                overrun = true
            }
            reservoir = 0
            availableBits = 0
        } else {
            reservoir >>= count
            availableBits -= count
        }
    }
}

/// A bit reader whose first bit is the most-significant bit of each byte.
///
/// Reads may request from zero through 32 bits. Reading beyond the supplied
/// buffer returns zero for missing bits and sets `overrun`; callers must check
/// that flag before accepting parsed data.
public struct MSBFirstBitReader: Sendable {
    private let bytes: [UInt8]
    private var byteOffset: Int
    private var reservoir: UInt64
    private var availableBits: Int
    private var alignment: Int

    /// Indicates that an operation requested bits beyond the input buffer.
    public private(set) var overrun: Bool

    /// Indicates that no real input bits remain.
    public var isExhausted: Bool {
        byteOffset >= bytes.count && availableBits == 0
    }

    /// Creates a reader over a byte array.
    public init(bytes: [UInt8]) {
        self.bytes = bytes
        self.byteOffset = 0
        self.reservoir = 0
        self.availableBits = 0
        self.alignment = 0
        self.overrun = false
    }

    /// Creates a reader over a data value.
    public init(data: Data) {
        self.init(bytes: Array(data))
    }

    /// Returns upcoming bits without advancing the logical position.
    public mutating func peek(_ count: Int) throws -> UInt32 {
        try validateBitCount(count)
        guard count > 0 else {
            return 0
        }
        refill(for: count)
        if availableBits < count {
            overrun = true
        }
        return UInt32(truncatingIfNeeded: reservoir >> (64 - count))
    }

    /// Advances over a number of bits.
    public mutating func consume(_ count: Int) throws {
        try validateBitCount(count)
        consumeValidated(count)
    }

    /// Reads and advances over a number of bits.
    public mutating func read(_ count: Int) throws -> UInt32 {
        let value = try peek(count)
        try consume(count)
        return value
    }

    /// Advances to the next byte boundary.
    public mutating func byteAlign() {
        let count = (8 - alignment) & 7
        consumeValidated(count)
    }

    private mutating func refill(for requested: Int) {
        while availableBits < requested, byteOffset < bytes.count {
            // availableBits は refill 開始時に 0...31 なので、左詰め位置は常に 0...63 の範囲内。
            let shift = 56 - availableBits
            reservoir |= UInt64(bytes[byteOffset]) << shift
            byteOffset += 1
            availableBits += 8
        }
    }

    private mutating func consumeValidated(_ count: Int) {
        guard count > 0 else {
            return
        }
        refill(for: count)
        alignment = (alignment + count) & 7
        if count >= availableBits {
            if count > availableBits {
                overrun = true
            }
            reservoir = 0
            availableBits = 0
        } else {
            reservoir <<= count
            availableBits -= count
        }
    }
}

private func validateBitCount(_ count: Int) throws {
    guard (0...32).contains(count) else {
        throw KaitoError.malformed("bit count must be between 0 and 32")
    }
}
