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
    private static let initializationVector: [UInt32] = [
        0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A,
        0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19,
    ]
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

    private var chainingValue: [UInt32]
    private var buffered: [UInt8] = []
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
        for word in 0..<state.count {
            state[word] ^= Self.loadUInt32LE(parameters, word * 4)
        }
        self.chainingValue = state
        self.isLastNode = isLastNode
        buffered.reserveCapacity(Self.blockSize)
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
        let source = input.bindMemory(to: UInt8.self)
        var inputIndex = 0

        if !buffered.isEmpty {
            let needed = Self.blockSize - buffered.count
            let copied = min(needed, input.count)
            buffered.append(contentsOf: source[..<copied])
            inputIndex += copied
            if buffered.count < Self.blockSize || inputIndex == input.count {
                return
            }
            // Copy before mutating `self`: the array storage must not remain
            // borrowed while `compress` updates the chaining value.
            let block = buffered
            compressedByteCount &+= UInt64(Self.blockSize)
            block.withUnsafeBytes { compress($0, isFinalBlock: false) }
            buffered.removeAll(keepingCapacity: true)
        }

        // Preserve the final full block so finalization can set its last-block bit.
        while input.count - inputIndex > Self.blockSize {
            let end = inputIndex + Self.blockSize
            compressedByteCount &+= UInt64(Self.blockSize)
            compress(
                UnsafeRawBufferPointer(rebasing: input[inputIndex..<end]),
                isFinalBlock: false
            )
            inputIndex = end
        }
        if inputIndex < input.count {
            buffered.append(contentsOf: source[inputIndex..<input.count])
        }
    }

    mutating func finalize() -> Data {
        if let finalDigest { return finalDigest }

        compressedByteCount &+= UInt64(buffered.count)
        var finalBlock = [UInt8](repeating: 0, count: Self.blockSize)
        if !buffered.isEmpty {
            finalBlock.replaceSubrange(0..<buffered.count, with: buffered)
        }
        finalBlock.withUnsafeBytes { compress($0, isFinalBlock: true) }

        var digest = [UInt8](repeating: 0, count: Self.outputSize)
        for word in chainingValue.indices {
            let value = chainingValue[word]
            let offset = word * 4
            digest[offset] = UInt8(truncatingIfNeeded: value)
            digest[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
            digest[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
            digest[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
        }
        let result = Data(digest)
        finalDigest = result
        buffered.removeAll(keepingCapacity: false)
        return result
    }

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
        let bytes = block.bindMemory(to: UInt8.self)
        var message = [UInt32](repeating: 0, count: 16)
        for word in 0..<message.count {
            let offset = word * 4
            message[word] = UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
        }

        var working = chainingValue + Self.initializationVector
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
        for index in chainingValue.indices {
            chainingValue[index] ^= working[index] ^ working[index + 8]
        }
    }

    private func mix(
        _ state: inout [UInt32],
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
    private static let lanes = 8
    private static let blockSize = 64

    private var leaves: [Blake2s]
    private var pending: [UInt8] = []
    private var stripedBlockCount: UInt64 = 0
    private var finalDigest: Data?

    init() {
        leaves = (0..<Self.lanes).map { lane in
            Blake2s(
                fanout: UInt8(Self.lanes),
                depth: 2,
                nodeOffset: UInt64(lane),
                nodeDepth: 0,
                innerHashLength: 32,
                isLastNode: lane == Self.lanes - 1
            )
        }
        pending.reserveCapacity(Self.blockSize)
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
            let count = min(Self.blockSize - pending.count, input.count)
            pending.append(contentsOf: bytes[..<count])
            offset += count
            if pending.count == Self.blockSize {
                // `submitBlock` mutates a leaf, so end the pending-array borrow
                // before entering it.
                let block = pending
                block.withUnsafeBytes { submitBlock($0) }
                pending.removeAll(keepingCapacity: true)
            }
        }

        while input.count - offset >= Self.blockSize {
            let end = offset + Self.blockSize
            submitBlock(UnsafeRawBufferPointer(rebasing: input[offset..<end]))
            offset = end
        }
        if offset < input.count {
            pending.append(contentsOf: bytes[offset..<input.count])
        }
    }

    mutating func finalize() -> Data {
        if let finalDigest { return finalDigest }
        if !pending.isEmpty {
            let block = pending
            block.withUnsafeBytes { block in
                let lane = Int(stripedBlockCount & UInt64(Self.lanes - 1))
                leaves[lane].update(block)
                stripedBlockCount &+= 1
            }
            pending.removeAll(keepingCapacity: false)
        }

        var root = Blake2s(
            fanout: UInt8(Self.lanes),
            depth: 2,
            nodeOffset: 0,
            nodeDepth: 1,
            innerHashLength: 32,
            isLastNode: true
        )
        for index in leaves.indices {
            root.update(leaves[index].finalize())
        }
        let result = root.finalize()
        finalDigest = result
        return result
    }

    static func checksum(_ data: Data) -> Data {
        var hash = Blake2sp()
        hash.update(data)
        return hash.finalize()
    }

    private mutating func submitBlock(_ block: UnsafeRawBufferPointer) {
        precondition(block.count == Self.blockSize)
        let lane = Int(stripedBlockCount & UInt64(Self.lanes - 1))
        leaves[lane].update(block)
        stripedBlockCount &+= 1
    }
}
