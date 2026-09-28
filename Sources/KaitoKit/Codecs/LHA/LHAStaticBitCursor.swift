// MSB-first bit cursor used by LHAStaticHuffmanDecoder and LHAStaticHuffmanTable. Provenance and
// the hot-loop invariants it serves are documented in LHAStaticHuffmanDecoder.swift.

/// Loop-local MSB reservoir over a once-allocated input plus eight sentinel
/// bytes. Refill loads eight bytes at the current logical byte position; the
/// final load is inside the allocation even for an empty logical suffix.
/// Consuming beyond real input marks failure and clamps the cursor, so repeated
/// malformed reads cannot walk past the sentinel or overflow the bit offset.
struct LHAStaticBitCursor {
    private let bytes: UnsafePointer<UInt8>
    private let logicalBitCount: Int
    private var bitOffset = 0
    private var reservoir: UInt64 = 0
    private var available = 0
    private(set) var overrun = false

    init(
        bytes: UnsafePointer<UInt8>,
        physicalByteCount: Int,
        logicalBitCount: Int
    ) {
        precondition(physicalByteCount >= logicalBitCount / 8 + 8)
        self.bytes = bytes
        self.logicalBitCount = logicalBitCount
    }

    @inline(__always)
    mutating func peek(_ count: Int) -> UInt32 {
        // All callers use validated table lengths or grammar widths in 0...32.
        guard count > 0 else { return 0 }
        if available < count {
            let intraByte = bitOffset & 7
            let word = UnsafeRawPointer(bytes + (bitOffset >> 3))
                .loadUnaligned(as: UInt64.self)
            reservoir = UInt64(bigEndian: word) << intraByte
            available = 64 - intraByte
        }
        return UInt32(truncatingIfNeeded: reservoir >> (64 - count))
    }

    @inline(__always)
    mutating func read(_ count: Int) -> UInt32 {
        let value = peek(count)
        consume(count)
        return value
    }

    @inline(__always)
    mutating func consume(_ count: Int) {
        // Consume can follow a shorter primary peek on the long-code path.
        if available < count { _ = peek(count) }
        reservoir <<= count
        available -= count
        if count > logicalBitCount - bitOffset {
            overrun = true
            bitOffset = logicalBitCount
            available = 0
        } else {
            bitOffset += count
        }
    }
}
