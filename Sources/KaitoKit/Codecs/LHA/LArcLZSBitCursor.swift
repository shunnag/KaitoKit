struct LArcLZSBitCursor {
    private let bytes: UnsafePointer<UInt8>
    private let byteCount: Int
    private var byteOffset = 0
    private var reservoir: UInt64 = 0
    private var availableBits = 0
    private(set) var overrun = false

    init(borrowing bytes: UnsafePointer<UInt8>, count: Int) {
        precondition(count >= 0)
        self.bytes = bytes
        self.byteCount = count
    }

    @inline(__always)
    mutating func read(_ count: Int) -> UInt32 {
        precondition((0...32).contains(count))
        guard count > 0 else { return 0 }
        while availableBits < count, byteOffset < byteCount {
            reservoir |= UInt64(bytes[byteOffset]) << (56 - availableBits)
            byteOffset += 1
            availableBits += 8
        }
        guard availableBits >= count else {
            overrun = true
            reservoir = 0
            availableBits = 0
            return 0
        }
        let value = UInt32(truncatingIfNeeded: reservoir >> (64 - count))
        reservoir <<= count
        availableBits -= count
        return value
    }
}
