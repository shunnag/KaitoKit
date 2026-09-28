import Foundation

// Bit readers and range decoders in KaitoKit
//
// Each codec owns its reader: the hot loops depend on the reader's backing and on
// how it reports reading past the input, so the readers are deliberately not
// unified. Each line gives the type, then bit order; backing; behaviour past the
// input; user. The types document the details.
//
// Bit readers
// - LSBFirstBitReader (public): LSB first; [UInt8]; missing bits read as zero and
//   set a sticky `overrun`; API clients.
// - MSBFirstBitReader (public): MSB first; [UInt8] or a borrowed pointer; missing
//   bits read as zero and set a sticky `overrun`; LZHUFDecoder, LArcDecoder.
// - LHAStaticBitCursor: MSB first; pointer plus 8 sentinel bytes; sticky `overrun`
//   with the cursor clamped; the LHA static-Huffman decoder.
// - RAR29RawBitCursor: MSB first; pointer plus 8 sentinel bytes; `peek` never
//   fails, consuming past the end sets a sticky `overrun`; RAR29Decoder.
// - RAR5RawBitReader: MSB first; pointer plus 8 sentinel bytes; `read` returns nil
//   because the symbol loop keeps failures in a tag; RAR5Decoder.
// - RAR3MemoryBitCursor: MSB first; [UInt8] filter payload; throws; RAR29Decoder
//   filter tokens.
// - LZXBitReader: 16-bit little-endian words, MSB first; [UInt8] of one frame;
//   zero-padded peek, consuming past the end throws; LZXDecoder.
// - XpressHuffmanDecoder (inline): 16-bit little-endian words, MSB first; [UInt8]
//   of one block; zero words past the end, overrun checked once per block; XPRESS.
// - ZstdBitReader, ZstdPaddedBitReader: backward from the end marker; borrowed
//   buffer (the padded one has 8 front bytes); checked reads throw, unchecked reads
//   rely on validated widths and `refill` rejects underflow; zstd.
// - ZstdForwardBits: LSB first, forward; borrowed buffer; throws; zstd FSE tables.
// - ZipLegacyBitReader: LSB first; ByteSource through a 64 KiB buffer; throws;
//   ZIP Shrink, Reduce and Implode.
// - Deflate64Decompressor (inline): LSB first; ByteSource; throws; Deflate64.
// - StuffItPackedInput: LSB or MSB first per method; ByteSource through a 16 KiB
//   buffer; a refill error is deferred until its bits are consumed; StuffIt codecs.
// - StuffItXBitReader: LSB first; ByteSource through a 16 KiB buffer; throws;
//   StuffIt X.
//
// Range decoders
// - LZMARangeDecoder with LZMAHotRangeState: LZMA binary coder with 11-bit
//   probabilities; pointer plus a zero sentinel; overrun is deferred and checked at
//   batch boundaries; LZMADecoder, LZMA2Decoder.
// - BCJ2Decompressor (inline): the same binary coder; its fourth input stream;
//   throws; 7z BCJ2.
// - PPMd7RangeDecoder: 7z's PPMd coder (zero marker byte, no `low`);
//   ByteSource through a 64 KiB buffer; throws; PPMd7Decoder.
// - RARPPMdRangeDecoder: RAR's carry-less coder with `low`; packed block in memory;
//   throws; RAR29Decoder PPMd blocks.
// - PPMdVarIRangeDecoder: Shkarin's carry-less coder with `low` and `scale`;
//   ByteSource through a 64 KiB buffer; throws; PPMdVarIDecoder (ZIP method 98).
// - StuffItArsenicArithmetic: StuffIt Arsenic arithmetic coder; StuffItPackedInput;
//   StuffIt Arsenic.
// - StuffItXRangeDecoder: StuffIt X range coder; StuffItXBitReader; throws;
//   StuffIt X.

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
    private struct BorrowedBuffer: @unchecked Sendable {
        let baseAddress: UnsafePointer<UInt8>
        let count: Int

        init(baseAddress: UnsafePointer<UInt8>, count: Int) {
            self.baseAddress = baseAddress
            self.count = count
        }
    }

    private let bytes: [UInt8]
    private let borrowedBuffer: BorrowedBuffer?
    private let byteCount: Int
    private var byteOffset: Int
    private var reservoir: UInt64
    private var availableBits: Int
    private var alignment: Int

    /// Indicates that an operation requested bits beyond the input buffer.
    public private(set) var overrun: Bool

    /// Indicates that no real input bits remain.
    public var isExhausted: Bool {
        byteOffset >= byteCount && availableBits == 0
    }

    /// Creates a reader over a byte array.
    public init(bytes: [UInt8]) {
        self.bytes = bytes
        self.borrowedBuffer = nil
        self.byteCount = bytes.count
        self.byteOffset = 0
        self.reservoir = 0
        self.availableBits = 0
        self.alignment = 0
        self.overrun = false
    }

    /// Creates a reader over storage whose owner guarantees that the pointer
    /// remains valid for the reader's lifetime. Internal high-throughput
    /// decoders use this to avoid an additional Array/COW layer.
    init(borrowing bytes: UnsafePointer<UInt8>, count: Int) {
        precondition(count >= 0)
        self.bytes = []
        self.borrowedBuffer = BorrowedBuffer(baseAddress: bytes, count: count)
        self.byteCount = count
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
        while availableBits < requested, byteOffset < byteCount {
            // availableBits は refill 開始時に 0...31 なので、左詰め位置は常に 0...63 の範囲内。
            let shift = 56 - availableBits
            let byte = borrowedBuffer?.baseAddress[byteOffset] ?? bytes[byteOffset]
            reservoir |= UInt64(byte) << shift
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
