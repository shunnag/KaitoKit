import Foundation

// Provenance / algorithm references:
// - RFC 7693, "The BLAKE2 Cryptographic Hash and Message Authentication Code".
// - The BLAKE2 paper and official CC0 BLAKE2 test-vector repository at
//   https://www.blake2.net/ (BLAKE2sp tree parameters and stripe layout).
// - RARLab, "RAR 5.0 archive format" technote (BLAKE2sp file-hash record).
// This is an independent Swift implementation. No archive decoder source was
// consulted for BLAKE2s or BLAKE2sp.

/// Incremental unkeyed BLAKE2s-256, including the tree parameters BLAKE2sp needs.
struct Blake2s: Sendable {
    private static let blockSize = 64
    private static let outputSize = 32
    private static let initializationVector = SIMD8<UInt32>(
        0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A,
        0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19
    )
    private static let permutations: [[UInt8]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
    ]

    private var chainingValue: SIMD8<UInt32>
    private var buffered = SIMD8<UInt64>(repeating: 0)
    private var bufferedCount = 0
    private var compressedByteCount: UInt64 = 0
    private let isLastNode: Bool
    private var finalDigest: Data?

    init() {
        self.init(
            fanout: 1,
            depth: 1,
            nodeOffset: 0,
            nodeDepth: 0,
            innerHashLength: 0,
            isLastNode: false
        )
    }

    fileprivate init(
        fanout: UInt8,
        depth: UInt8,
        nodeOffset: UInt64,
        nodeDepth: UInt8,
        innerHashLength: UInt8,
        isLastNode: Bool
    ) {
        precondition(nodeOffset < (UInt64(1) << 48))
        var parameters = [UInt8](repeating: 0, count: 32)
        parameters[0] = UInt8(Self.outputSize)
        parameters[2] = fanout
        parameters[3] = depth
        for byte in 0..<6 {
            parameters[8 + byte] = UInt8(
                truncatingIfNeeded: nodeOffset >> UInt64(byte * 8)
            )
        }
        parameters[14] = nodeDepth
        parameters[15] = innerHashLength

        var state = Self.initializationVector
        for word in 0..<8 {
            state[word] ^= Self.loadUInt32LE(parameters, word * 4)
        }
        self.chainingValue = state
        self.isLastNode = isLastNode
    }

    // Resume a leaf after the shared SIMD stripes; final partial blocks still
    // use the same BLAKE2s finalization and last-node rules as standalone hashes.
    fileprivate init(chainingValue: SIMD8<UInt32>, compressedByteCount: UInt64,
                     isLastNode: Bool) {
        self.chainingValue = chainingValue
        self.compressedByteCount = compressedByteCount
        self.isLastNode = isLastNode
    }

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }

    mutating func update(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { update($0) }
    }

    mutating func update(_ input: UnsafeRawBufferPointer) {
        precondition(finalDigest == nil, "cannot update a finalized BLAKE2s")
        guard !input.isEmpty else { return }
        var inputIndex = 0
        if bufferedCount > 0 {
            let copied = min(Self.blockSize - bufferedCount, input.count)
            appendToBuffer(UnsafeRawBufferPointer(rebasing: input[..<copied]))
            inputIndex += copied
            if bufferedCount < Self.blockSize || inputIndex == input.count { return }
            compressBufferedBlock()
        }
        // Only compress a full block when at least one more byte follows.
        while input.count - inputIndex > Self.blockSize {
            compressedByteCount &+= UInt64(Self.blockSize)
            compress(UnsafeRawBufferPointer(rebasing: input[inputIndex..<(inputIndex + Self.blockSize)]),
                     isFinalBlock: false)
            inputIndex += Self.blockSize
        }
        appendToBuffer(UnsafeRawBufferPointer(rebasing: input[inputIndex...]))
    }

    private mutating func appendToBuffer(_ bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty else { return }
        withUnsafeMutableBytes(of: &buffered) { target in
            target.baseAddress!.advanced(by: bufferedCount).copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        bufferedCount += bytes.count
    }

    private mutating func compressBufferedBlock() {
        var block = buffered
        compressedByteCount &+= UInt64(Self.blockSize)
        withUnsafeBytes(of: &block) { compress($0, isFinalBlock: false) }
        bufferedCount = 0
    }

    // A full stripe block can be compressed directly if this leaf has more
    // input in the same call. Only the last block per leaf needs retaining.
    fileprivate mutating func updateBlock(_ block: UnsafeRawBufferPointer, moreFollows: Bool) {
        precondition(finalDigest == nil && block.count == Self.blockSize)
        precondition(bufferedCount == 0 || bufferedCount == Self.blockSize)
        if bufferedCount == Self.blockSize { compressBufferedBlock() }
        if moreFollows {
            compressedByteCount &+= UInt64(Self.blockSize)
            compress(block, isFinalBlock: false)
        } else {
            appendToBuffer(block)
        }
    }

    mutating func finalize() -> Data {
        if let finalDigest { return finalDigest }

        compressedByteCount &+= UInt64(bufferedCount)
        var finalBlock = buffered
        withUnsafeMutableBytes(of: &finalBlock) { bytes in
            bytes[bufferedCount...].initializeMemory(as: UInt8.self, repeating: 0)
            compress(UnsafeRawBufferPointer(bytes), isFinalBlock: true)
        }

        var digest = [UInt8](repeating: 0, count: Self.outputSize)
        for word in 0..<8 {
            let value = chainingValue[word]
            let offset = word * 4
            digest[offset] = UInt8(truncatingIfNeeded: value)
            digest[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
            digest[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
            digest[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
        }
        let result = Data(digest)
        finalDigest = result
        bufferedCount = 0
        return result
    }

    // テスト専用の一括ハッシュ計算。読取経路は update と finalize による逐次処理を使う。
    static func checksum(_ data: Data) -> Data {
        var hash = Blake2s()
        hash.update(data)
        return hash.finalize()
    }

    private mutating func compress(
        _ block: UnsafeRawBufferPointer,
        isFinalBlock: Bool
    ) {
        precondition(block.count == Self.blockSize)
        var message = SIMD16<UInt32>(repeating: 0)
        var working = SIMD16<UInt32>(repeating: 0)
        for word in 0..<16 {
            message[word] = UInt32(littleEndian: block.loadUnaligned(fromByteOffset: word * 4, as: UInt32.self))
        }
        for word in 0..<8 {
            working[word] = chainingValue[word]
            working[word + 8] = Self.initializationVector[word]
        }
        working[12] ^= UInt32(truncatingIfNeeded: compressedByteCount)
        working[13] ^= UInt32(truncatingIfNeeded: compressedByteCount >> 32)
        if isFinalBlock {
            working[14] = ~working[14]
            if isLastNode {
                working[15] = ~working[15]
            }
        }

        for round in 0..<10 {
            let permutation = Self.permutations[round]
            mix(&working, 0, 4, 8, 12, message[Int(permutation[0])], message[Int(permutation[1])])
            mix(&working, 1, 5, 9, 13, message[Int(permutation[2])], message[Int(permutation[3])])
            mix(&working, 2, 6, 10, 14, message[Int(permutation[4])], message[Int(permutation[5])])
            mix(&working, 3, 7, 11, 15, message[Int(permutation[6])], message[Int(permutation[7])])
            mix(&working, 0, 5, 10, 15, message[Int(permutation[8])], message[Int(permutation[9])])
            mix(&working, 1, 6, 11, 12, message[Int(permutation[10])], message[Int(permutation[11])])
            mix(&working, 2, 7, 8, 13, message[Int(permutation[12])], message[Int(permutation[13])])
            mix(&working, 3, 4, 9, 14, message[Int(permutation[14])], message[Int(permutation[15])])
        }
        for index in 0..<8 {
            chainingValue[index] ^= working[index] ^ working[index + 8]
        }
    }

    @inline(__always)
    private func mix(
        _ state: inout SIMD16<UInt32>,
        _ ai: Int,
        _ bi: Int,
        _ ci: Int,
        _ di: Int,
        _ firstMessage: UInt32,
        _ secondMessage: UInt32
    ) {
        var a = state[ai]
        var b = state[bi]
        var c = state[ci]
        var d = state[di]
        a = a &+ b &+ firstMessage
        d = Self.rotateRight(d ^ a, 16)
        c = c &+ d
        b = Self.rotateRight(b ^ c, 12)
        a = a &+ b &+ secondMessage
        d = Self.rotateRight(d ^ a, 8)
        c = c &+ d
        b = Self.rotateRight(b ^ c, 7)
        state[ai] = a
        state[bi] = b
        state[ci] = c
        state[di] = d
    }

    private static func rotateRight(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }

    private static func loadUInt32LE(_ bytes: [UInt8], _ index: Int) -> UInt32 {
        UInt32(bytes[index])
            | UInt32(bytes[index + 1]) << 8
            | UInt32(bytes[index + 2]) << 16
            | UInt32(bytes[index + 3]) << 24
    }
}

/// Incremental BLAKE2sp-256 used by the RAR5 file-hash extra record.
struct Blake2sp: Sendable {
    private static let stripeSize = 8 * 64

    // Structure of arrays: lane i in each word is leaf i. The node offset
    // occupies parameter word 2; all other parameters are shared by the leaves.
    private var h0 = SIMD8<UInt32>(repeating: 0x6A09_E667 ^ 0x0208_0020)
    private var h1 = SIMD8<UInt32>(repeating: 0xBB67_AE85)
    private var h2 = SIMD8<UInt32>(repeating: 0x3C6E_F372) ^ SIMD8<UInt32>(0, 1, 2, 3, 4, 5, 6, 7)
    private var h3 = SIMD8<UInt32>(repeating: 0xA54F_F53A ^ 0x2000_0000)
    private var h4 = SIMD8<UInt32>(repeating: 0x510E_527F)
    private var h5 = SIMD8<UInt32>(repeating: 0x9B05_688C)
    private var h6 = SIMD8<UInt32>(repeating: 0x1F83_D9AB)
    private var h7 = SIMD8<UInt32>(repeating: 0x5BE0_CD19)
    private var compressedByteCount: UInt64 = 0 // Per leaf, not per stripe.
    private var pending: [UInt8] = []
    private var finalDigest: Data?

    init() {
        pending.reserveCapacity(2 * Self.stripeSize)
    }

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }

    mutating func update(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { update($0) }
    }

    mutating func update(_ input: UnsafeRawBufferPointer) {
        precondition(finalDigest == nil, "cannot update a finalized BLAKE2sp")
        guard !input.isEmpty else { return }
        let bytes = input.bindMemory(to: UInt8.self)
        var offset = 0
        if !pending.isEmpty {
            let count = min(2 * Self.stripeSize - pending.count, input.count)
            pending.append(contentsOf: bytes[..<count])
            offset = count
            guard pending.count == 2 * Self.stripeSize else { return }
            // A complete following stripe proves that every leaf has another
            // block. An incomplete stripe cannot establish that for all lanes.
            let buffered = pending
            buffered.withUnsafeBytes {
                compressStripe(UnsafeRawBufferPointer(rebasing: $0[..<Self.stripeSize]))
            }
            if input.count - offset >= Self.stripeSize {
                buffered.withUnsafeBytes {
                    compressStripe(UnsafeRawBufferPointer(rebasing: $0[Self.stripeSize...]))
                }
                pending.removeAll(keepingCapacity: true)
            } else {
                pending = Array(buffered[Self.stripeSize...])
                pending.append(contentsOf: bytes[offset...])
                return
            }
        }
        while input.count - offset >= 2 * Self.stripeSize {
            compressStripe(UnsafeRawBufferPointer(rebasing: input[offset..<(offset + Self.stripeSize)]))
            offset += Self.stripeSize
        }
        pending.append(contentsOf: bytes[offset...])
    }

    mutating func finalize() -> Data {
        if let finalDigest { return finalDigest }
        var root = Blake2s(fanout: 8, depth: 2, nodeOffset: 0, nodeDepth: 1,
                          innerHashLength: 32, isLastNode: true)
        // At most two blocks remain per leaf. Scalar finalization handles the
        // different final byte counts, including empty leaves, without padding
        // the logical input or compressing a leaf's final block too early.
        pending.withUnsafeBytes { bytes in
            for lane in 0..<8 {
                let state = SIMD8<UInt32>(h0[lane], h1[lane], h2[lane], h3[lane],
                                          h4[lane], h5[lane], h6[lane], h7[lane])
                var leaf = Blake2s(chainingValue: state, compressedByteCount: compressedByteCount,
                                   isLastNode: lane == 7)
                for stripe in stride(from: 0, to: bytes.count, by: Self.stripeSize) {
                    let start = stripe + lane * 64
                    if start < bytes.count {
                        leaf.update(UnsafeRawBufferPointer(rebasing: bytes[start..<min(start + 64, bytes.count)]))
                    }
                }
                root.update(leaf.finalize())
            }
        }
        let result = root.finalize()
        finalDigest = result
        pending.removeAll(keepingCapacity: false)
        return result
    }

    // テスト専用の一括ハッシュ計算。読取経路は update と finalize による逐次処理を使う。
    static func checksum(_ data: Data) -> Data {
        var hash = Blake2sp()
        hash.update(data)
        return hash.finalize()
    }

    @inline(__always)
    private static func loadWord(_ bytes: UnsafeRawBufferPointer, _ word: Int) -> SIMD8<UInt32> {
        func load(_ lane: Int) -> UInt32 {
            UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: lane * 64 + word * 4, as: UInt32.self))
        }
        return SIMD8<UInt32>(load(0), load(1), load(2), load(3), load(4), load(5), load(6), load(7))
    }

    private mutating func compressStripe(_ bytes: UnsafeRawBufferPointer) {
        precondition(bytes.count == Self.stripeSize)
        compressedByteCount &+= 64
        let m0 = Self.loadWord(bytes, 0)
        let m1 = Self.loadWord(bytes, 1)
        let m2 = Self.loadWord(bytes, 2)
        let m3 = Self.loadWord(bytes, 3)
        let m4 = Self.loadWord(bytes, 4)
        let m5 = Self.loadWord(bytes, 5)
        let m6 = Self.loadWord(bytes, 6)
        let m7 = Self.loadWord(bytes, 7)
        let m8 = Self.loadWord(bytes, 8)
        let m9 = Self.loadWord(bytes, 9)
        let m10 = Self.loadWord(bytes, 10)
        let m11 = Self.loadWord(bytes, 11)
        let m12 = Self.loadWord(bytes, 12)
        let m13 = Self.loadWord(bytes, 13)
        let m14 = Self.loadWord(bytes, 14)
        let m15 = Self.loadWord(bytes, 15)

        var v0 = h0
        var v1 = h1
        var v2 = h2
        var v3 = h3
        var v4 = h4
        var v5 = h5
        var v6 = h6
        var v7 = h7
        var v8 = SIMD8<UInt32>(repeating: 0x6A09_E667)
        var v9 = SIMD8<UInt32>(repeating: 0xBB67_AE85)
        var v10 = SIMD8<UInt32>(repeating: 0x3C6E_F372)
        var v11 = SIMD8<UInt32>(repeating: 0xA54F_F53A)
        var v12 = SIMD8<UInt32>(repeating: 0x510E_527F ^ UInt32(truncatingIfNeeded: compressedByteCount))
        var v13 = SIMD8<UInt32>(repeating: 0x9B05_688C ^ UInt32(truncatingIfNeeded: compressedByteCount >> 32))
        var v14 = SIMD8<UInt32>(repeating: 0x1F83_D9AB)
        var v15 = SIMD8<UInt32>(repeating: 0x5BE0_CD19)

        // RFC 7693 sigma schedule, unrolled so each message and working word
        // stays in a SIMD value with no dynamic array indexing in the rounds.
        Self.mix(&v0, &v4, &v8, &v12, m0, m1)
        Self.mix(&v1, &v5, &v9, &v13, m2, m3)
        Self.mix(&v2, &v6, &v10, &v14, m4, m5)
        Self.mix(&v3, &v7, &v11, &v15, m6, m7)
        Self.mix(&v0, &v5, &v10, &v15, m8, m9)
        Self.mix(&v1, &v6, &v11, &v12, m10, m11)
        Self.mix(&v2, &v7, &v8, &v13, m12, m13)
        Self.mix(&v3, &v4, &v9, &v14, m14, m15)

        Self.mix(&v0, &v4, &v8, &v12, m14, m10)
        Self.mix(&v1, &v5, &v9, &v13, m4, m8)
        Self.mix(&v2, &v6, &v10, &v14, m9, m15)
        Self.mix(&v3, &v7, &v11, &v15, m13, m6)
        Self.mix(&v0, &v5, &v10, &v15, m1, m12)
        Self.mix(&v1, &v6, &v11, &v12, m0, m2)
        Self.mix(&v2, &v7, &v8, &v13, m11, m7)
        Self.mix(&v3, &v4, &v9, &v14, m5, m3)

        Self.mix(&v0, &v4, &v8, &v12, m11, m8)
        Self.mix(&v1, &v5, &v9, &v13, m12, m0)
        Self.mix(&v2, &v6, &v10, &v14, m5, m2)
        Self.mix(&v3, &v7, &v11, &v15, m15, m13)
        Self.mix(&v0, &v5, &v10, &v15, m10, m14)
        Self.mix(&v1, &v6, &v11, &v12, m3, m6)
        Self.mix(&v2, &v7, &v8, &v13, m7, m1)
        Self.mix(&v3, &v4, &v9, &v14, m9, m4)

        Self.mix(&v0, &v4, &v8, &v12, m7, m9)
        Self.mix(&v1, &v5, &v9, &v13, m3, m1)
        Self.mix(&v2, &v6, &v10, &v14, m13, m12)
        Self.mix(&v3, &v7, &v11, &v15, m11, m14)
        Self.mix(&v0, &v5, &v10, &v15, m2, m6)
        Self.mix(&v1, &v6, &v11, &v12, m5, m10)
        Self.mix(&v2, &v7, &v8, &v13, m4, m0)
        Self.mix(&v3, &v4, &v9, &v14, m15, m8)

        Self.mix(&v0, &v4, &v8, &v12, m9, m0)
        Self.mix(&v1, &v5, &v9, &v13, m5, m7)
        Self.mix(&v2, &v6, &v10, &v14, m2, m4)
        Self.mix(&v3, &v7, &v11, &v15, m10, m15)
        Self.mix(&v0, &v5, &v10, &v15, m14, m1)
        Self.mix(&v1, &v6, &v11, &v12, m11, m12)
        Self.mix(&v2, &v7, &v8, &v13, m6, m8)
        Self.mix(&v3, &v4, &v9, &v14, m3, m13)

        Self.mix(&v0, &v4, &v8, &v12, m2, m12)
        Self.mix(&v1, &v5, &v9, &v13, m6, m10)
        Self.mix(&v2, &v6, &v10, &v14, m0, m11)
        Self.mix(&v3, &v7, &v11, &v15, m8, m3)
        Self.mix(&v0, &v5, &v10, &v15, m4, m13)
        Self.mix(&v1, &v6, &v11, &v12, m7, m5)
        Self.mix(&v2, &v7, &v8, &v13, m15, m14)
        Self.mix(&v3, &v4, &v9, &v14, m1, m9)

        Self.mix(&v0, &v4, &v8, &v12, m12, m5)
        Self.mix(&v1, &v5, &v9, &v13, m1, m15)
        Self.mix(&v2, &v6, &v10, &v14, m14, m13)
        Self.mix(&v3, &v7, &v11, &v15, m4, m10)
        Self.mix(&v0, &v5, &v10, &v15, m0, m7)
        Self.mix(&v1, &v6, &v11, &v12, m6, m3)
        Self.mix(&v2, &v7, &v8, &v13, m9, m2)
        Self.mix(&v3, &v4, &v9, &v14, m8, m11)

        Self.mix(&v0, &v4, &v8, &v12, m13, m11)
        Self.mix(&v1, &v5, &v9, &v13, m7, m14)
        Self.mix(&v2, &v6, &v10, &v14, m12, m1)
        Self.mix(&v3, &v7, &v11, &v15, m3, m9)
        Self.mix(&v0, &v5, &v10, &v15, m5, m0)
        Self.mix(&v1, &v6, &v11, &v12, m15, m4)
        Self.mix(&v2, &v7, &v8, &v13, m8, m6)
        Self.mix(&v3, &v4, &v9, &v14, m2, m10)

        Self.mix(&v0, &v4, &v8, &v12, m6, m15)
        Self.mix(&v1, &v5, &v9, &v13, m14, m9)
        Self.mix(&v2, &v6, &v10, &v14, m11, m3)
        Self.mix(&v3, &v7, &v11, &v15, m0, m8)
        Self.mix(&v0, &v5, &v10, &v15, m12, m2)
        Self.mix(&v1, &v6, &v11, &v12, m13, m7)
        Self.mix(&v2, &v7, &v8, &v13, m1, m4)
        Self.mix(&v3, &v4, &v9, &v14, m10, m5)

        Self.mix(&v0, &v4, &v8, &v12, m10, m2)
        Self.mix(&v1, &v5, &v9, &v13, m8, m4)
        Self.mix(&v2, &v6, &v10, &v14, m7, m6)
        Self.mix(&v3, &v7, &v11, &v15, m1, m5)
        Self.mix(&v0, &v5, &v10, &v15, m15, m11)
        Self.mix(&v1, &v6, &v11, &v12, m9, m14)
        Self.mix(&v2, &v7, &v8, &v13, m3, m12)
        Self.mix(&v3, &v4, &v9, &v14, m13, m0)

        h0 ^= v0 ^ v8
        h1 ^= v1 ^ v9
        h2 ^= v2 ^ v10
        h3 ^= v3 ^ v11
        h4 ^= v4 ^ v12
        h5 ^= v5 ^ v13
        h6 ^= v6 ^ v14
        h7 ^= v7 ^ v15
    }

    @inline(__always)
    private static func mix(_ a: inout SIMD8<UInt32>, _ b: inout SIMD8<UInt32>,
                            _ c: inout SIMD8<UInt32>, _ d: inout SIMD8<UInt32>,
                            _ x: SIMD8<UInt32>, _ y: SIMD8<UInt32>) {
        a = a &+ b &+ x
        d ^= a
        d = (d &>> 16) | (d &<< 16)
        c = c &+ d
        b ^= c
        b = (b &>> 12) | (b &<< 20)
        a = a &+ b &+ y
        d ^= a
        d = (d &>> 8) | (d &<< 24)
        c = c &+ d
        b ^= c
        b = (b &>> 7) | (b &<< 25)
    }
}
