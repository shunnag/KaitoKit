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

    @inline(__always)
    private mutating func stripe(_ bytes: UnsafeRawBufferPointer, at offset: Int) {
        // 呼出側で offset から 32 バイトあることを検査済み。アラインメントは不要。
        a = Self.round(a, UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)))
        b = Self.round(b, UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 8, as: UInt64.self)))
        c = Self.round(c, UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 16, as: UInt64.self)))
        d = Self.round(d, UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 24, as: UInt64.self)))
    }

    mutating func update(_ bytes: ArraySlice<UInt8>) {
        bytes.withUnsafeBytes { update($0) }
    }

    // D11: 呼出中に有効な実 byte の view。stripe / tail の算術は配列版と同じで、余白は含めない。
    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        length &+= UInt64(bytes.count)
        var offset = 0
        if !tail.isEmpty {
            let count = min(32 - tail.count, bytes.count)
            tail.append(contentsOf: bytes[offset..<(offset + count)])
            offset += count
            if tail.count == 32 {
                tail.withUnsafeBytes { stripe($0, at: 0) }
                tail.removeAll(keepingCapacity: true)
            }
        }
        while bytes.count - offset >= 32 {
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
        tail.withUnsafeBytes { bytes in
            // 各 load の幅は残量検査以下。
            while tail.count - offset >= 8 {
                hash ^= Self.round(0, UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)))
                hash = (Self.rotate(hash, 27) &* Self.p1) &+ Self.p4
                offset += 8
            }
            if tail.count - offset >= 4 {
                hash ^= UInt64(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) &* Self.p1
                hash = (Self.rotate(hash, 23) &* Self.p2) &+ Self.p3
                offset += 4
            }
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
