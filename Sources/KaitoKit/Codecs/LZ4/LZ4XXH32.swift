// XXH32, seed 0, from the public xxhash_spec.md (version 0.2.0).
// Retains at most the final 15 bytes; the input is never collected as a whole.
struct LZ4XXH32 {
    private static let p1: UInt32 = 0x9e3779b1
    private static let p2: UInt32 = 0x85ebca77
    private static let p3: UInt32 = 0xc2b2ae3d
    private static let p4: UInt32 = 0x27d4eb2f
    private static let p5: UInt32 = 0x165667b1
    private var a = p1 &+ p2
    private var b = p2
    private var c: UInt32 = 0
    private var d = 0 &- p1
    private var length: UInt32 = 0
    private var hasStripe = false
    private var tail: [UInt8] = []

    private static func rotate(_ value: UInt32, _ shift: Int) -> UInt32 {
        (value << shift) | (value >> (32 - shift))
    }

    private static func word(_ bytes: ArraySlice<UInt8>, _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private static func round(_ accumulator: UInt32, _ lane: UInt32) -> UInt32 {
        rotate(accumulator &+ lane &* p2, 13) &* p1
    }

    private mutating func stripe(_ bytes: ArraySlice<UInt8>, _ offset: Int) {
        a = Self.round(a, Self.word(bytes, offset))
        b = Self.round(b, Self.word(bytes, offset + 4))
        c = Self.round(c, Self.word(bytes, offset + 8))
        d = Self.round(d, Self.word(bytes, offset + 12))
        hasStripe = true
    }

    mutating func update(_ bytes: ArraySlice<UInt8>) {
        length &+= UInt32(truncatingIfNeeded: bytes.count)
        var offset = bytes.startIndex
        if !tail.isEmpty {
            let count = min(16 - tail.count, bytes.count)
            tail.append(contentsOf: bytes[offset..<(offset + count)])
            offset += count
            if tail.count == 16 {
                stripe(tail[...], 0)
                tail.removeAll(keepingCapacity: true)
            }
        }
        while bytes.endIndex - offset >= 16 {
            stripe(bytes, offset)
            offset += 16
        }
        tail.append(contentsOf: bytes[offset...])
    }

    var value: UInt32 {
        var hash = hasStripe
            ? Self.rotate(a, 1) &+ Self.rotate(b, 7) &+ Self.rotate(c, 12) &+ Self.rotate(d, 18)
            : Self.p5
        hash &+= length
        var offset = 0
        while tail.count - offset >= 4 {
            hash = Self.rotate(hash &+ Self.word(tail[...], offset) &* Self.p3, 17) &* Self.p4
            offset += 4
        }
        while offset < tail.count {
            hash = Self.rotate(hash &+ UInt32(tail[offset]) &* Self.p5, 11) &* Self.p1
            offset += 1
        }
        hash = (hash ^ (hash >> 15)) &* Self.p2
        hash = (hash ^ (hash >> 13)) &* Self.p3
        return hash ^ (hash >> 16)
    }

    static func digest(_ bytes: [UInt8]) -> UInt32 {
        var hash = Self()
        hash.update(bytes[...])
        return hash.value
    }
}
