// inbox/zstd/xxhash_spec.md の XXH64 algorithm description から実装。
// 32 バイト未満の端数だけを保持し、フレーム全体を確保しない。
struct ZstdXXH64 {
    private static let p1: UInt64 = 0x9e3779b185ebca87
    private static let p2: UInt64 = 0xc2b2ae3d27d4eb4f
    private static let p3: UInt64 = 0x165667b19e3779f9
    private static let p4: UInt64 = 0x85ebca77c2b2ae63
    private static let p5: UInt64 = 0x27d4eb2f165667c5
    private var a = p1 &+ p2
    private var b = p2
    private var c: UInt64 = 0
    private var d = 0 &- p1
    private var length: UInt64 = 0
    private var tail: [UInt8] = []

    @inline(__always)
    private static func rotate(_ value: UInt64, _ shift: Int) -> UInt64 {
        (value << shift) | (value >> (64 - shift))
    }

    @inline(__always)
    private static func round(_ accumulator: UInt64, _ lane: UInt64) -> UInt64 {
        rotate(accumulator &+ (lane &* p2), 31) &* p1
    }

    private static func word(_ bytes: ArraySlice<UInt8>, at offset: Int, count: Int = 8) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<count { value |= UInt64(bytes[offset + i]) << (8 * i) }
        return value
    }

    private mutating func stripe(_ bytes: ArraySlice<UInt8>, at offset: Int) {
        a = Self.round(a, Self.word(bytes, at: offset))
        b = Self.round(b, Self.word(bytes, at: offset + 8))
        c = Self.round(c, Self.word(bytes, at: offset + 16))
        d = Self.round(d, Self.word(bytes, at: offset + 24))
    }

    mutating func update(_ bytes: ArraySlice<UInt8>) {
        length &+= UInt64(bytes.count)
        var offset = bytes.startIndex
        if !tail.isEmpty {
            let count = min(32 - tail.count, bytes.count)
            tail.append(contentsOf: bytes[offset..<(offset + count)])
            offset += count
            if tail.count == 32 {
                stripe(tail[...], at: 0)
                tail.removeAll(keepingCapacity: true)
            }
        }
        while bytes.endIndex - offset >= 32 {
            stripe(bytes, at: offset)
            offset += 32
        }
        tail.append(contentsOf: bytes[offset...])
    }

    var value: UInt64 {
        var hash: UInt64
        if length >= 32 {
            hash = Self.rotate(a, 1) &+ Self.rotate(b, 7) &+ Self.rotate(c, 12) &+ Self.rotate(d, 18)
            for accumulator in [a, b, c, d] {
                hash = ((hash ^ Self.round(0, accumulator)) &* Self.p1) &+ Self.p4
            }
        } else { hash = Self.p5 }
        hash &+= length
        var offset = 0
        while tail.count - offset >= 8 {
            hash ^= Self.round(0, Self.word(tail[...], at: offset))
            hash = (Self.rotate(hash, 27) &* Self.p1) &+ Self.p4
            offset += 8
        }
        if tail.count - offset >= 4 {
            hash ^= Self.word(tail[...], at: offset, count: 4) &* Self.p1
            hash = (Self.rotate(hash, 23) &* Self.p2) &+ Self.p3
            offset += 4
        }
        while offset < tail.count {
            hash ^= UInt64(tail[offset]) &* Self.p5
            hash = Self.rotate(hash, 11) &* Self.p1
            offset += 1
        }
        hash = (hash ^ (hash >> 33)) &* Self.p2
        hash = (hash ^ (hash >> 29)) &* Self.p3
        return hash ^ (hash >> 32)
    }
}
