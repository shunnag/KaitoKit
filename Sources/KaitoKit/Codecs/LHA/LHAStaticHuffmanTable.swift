import Darwin

// Two-level canonical Huffman lookup used by LHAStaticHuffmanDecoder. Provenance and the
// hot-loop invariants it serves are documented in LHAStaticHuffmanDecoder.swift.

/// Canonical lookup with an eleven-bit primary table and a bounded pool of
/// binary nodes for longer codes. Primary leaf records store
/// `(bitCount, symbol + 1)`; node leaves store `symbol + 1`, and the high bit
/// marks a node index. Zero is therefore an invalid-prefix sentinel.
/// Degenerate one-symbol trees are represented explicitly because they consume
/// no command bits in LHA.
final class LHAStaticHuffmanTable {
    static let maximumBits = 16
    private static let primaryBits = 11
    private static let primaryCount = 1 << primaryBits
    private static let scratchCount = maximumBits + 1
    private static let branchFlag: UInt32 = 0x8000_0000
    private static let branchIndexMask: UInt32 = 0x7fff_ffff
    private static let symbolMask: UInt32 = 0x0000_ffff

    private let name: String
    private let maximumSymbolCount: Int
    private let primary: UnsafeMutablePointer<UInt32>
    private let nodes: UnsafeMutablePointer<UInt32>
    private let nodeCapacity: Int
    private let nodeEntryCapacity: Int
    private let counts: UnsafeMutablePointer<Int>
    private let nextCodes: UnsafeMutablePointer<Int>
    private var nodeCount = 0
    private var constantSymbol = -1

    init(name: String, maximumSymbolCount: Int) throws {
        guard maximumSymbolCount > 1,
              maximumSymbolCount - 1 <= Int.max / 2 else {
            throw KaitoError.limitExceeded("LHA Huffman table capacity")
        }
        let nodeCapacity = maximumSymbolCount - 1
        let nodeEntryCapacity = nodeCapacity * 2
        let primaryBytes = LHAStaticHuffmanTable.primaryCount
            * MemoryLayout<UInt32>.stride
        let nodeBytes = nodeEntryCapacity * MemoryLayout<UInt32>.stride
        let scratchBytes = LHAStaticHuffmanTable.scratchCount
            * MemoryLayout<Int>.stride
        guard let primaryRaw = malloc(primaryBytes) else {
            throw KaitoError.limitExceeded("unable to allocate LHA Huffman table")
        }
        guard let nodesRaw = malloc(nodeBytes) else {
            free(primaryRaw)
            throw KaitoError.limitExceeded("unable to allocate LHA Huffman nodes")
        }
        guard let countsRaw = malloc(scratchBytes) else {
            free(nodesRaw)
            free(primaryRaw)
            throw KaitoError.limitExceeded("unable to allocate LHA Huffman scratch table")
        }
        guard let codesRaw = malloc(scratchBytes) else {
            free(countsRaw)
            free(nodesRaw)
            free(primaryRaw)
            throw KaitoError.limitExceeded("unable to allocate LHA Huffman scratch table")
        }

        self.name = name
        self.maximumSymbolCount = maximumSymbolCount
        self.primary = primaryRaw.bindMemory(
            to: UInt32.self,
            capacity: LHAStaticHuffmanTable.primaryCount
        )
        self.nodes = nodesRaw.bindMemory(
            to: UInt32.self,
            capacity: nodeEntryCapacity
        )
        self.nodeCapacity = nodeCapacity
        self.nodeEntryCapacity = nodeEntryCapacity
        self.counts = countsRaw.bindMemory(
            to: Int.self,
            capacity: LHAStaticHuffmanTable.scratchCount
        )
        self.nextCodes = codesRaw.bindMemory(
            to: Int.self,
            capacity: LHAStaticHuffmanTable.scratchCount
        )
        primary.initialize(repeating: 0, count: LHAStaticHuffmanTable.primaryCount)
        nodes.initialize(repeating: 0, count: nodeEntryCapacity)
        counts.initialize(repeating: 0, count: LHAStaticHuffmanTable.scratchCount)
        nextCodes.initialize(repeating: 0, count: LHAStaticHuffmanTable.scratchCount)
    }

    deinit {
        primary.deinitialize(count: LHAStaticHuffmanTable.primaryCount)
        nodes.deinitialize(count: nodeEntryCapacity)
        counts.deinitialize(count: LHAStaticHuffmanTable.scratchCount)
        nextCodes.deinitialize(count: LHAStaticHuffmanTable.scratchCount)
        free(UnsafeMutableRawPointer(nextCodes))
        free(UnsafeMutableRawPointer(counts))
        free(UnsafeMutableRawPointer(nodes))
        free(UnsafeMutableRawPointer(primary))
    }

    func setConstant(_ symbol: Int) {
        constantSymbol = symbol
    }

    func build(
        lengths: UnsafePointer<UInt8>,
        symbolCount: Int
    ) throws {
        guard symbolCount > 0, symbolCount <= maximumSymbolCount else {
            throw KaitoError.malformed(
                "LHA \(name) Huffman symbol count exceeds its table"
            )
        }
        constantSymbol = -1
        nodeCount = 0
        primary.update(
            repeating: 0,
            count: LHAStaticHuffmanTable.primaryCount
        )
        counts.update(repeating: 0, count: LHAStaticHuffmanTable.scratchCount)

        var populatedCount = 0
        for symbol in 0..<symbolCount {
            let length = Int(lengths[symbol])
            guard length <= LHAStaticHuffmanTable.maximumBits else {
                throw KaitoError.malformed(
                    "LHA \(name) Huffman length exceeds 16"
                )
            }
            if length > 0 {
                counts[length] += 1
                populatedCount += 1
            }
        }
        guard populatedCount > 0 else {
            throw KaitoError.malformed("LHA \(name) Huffman table is empty")
        }

        var available = 1
        for bitCount in 1...LHAStaticHuffmanTable.maximumBits {
            available = (available << 1) - counts[bitCount]
            guard available >= 0 else {
                throw KaitoError.malformed(
                    "oversubscribed LHA \(name) Huffman table"
                )
            }
        }
        guard available == 0 else {
            throw KaitoError.malformed(
                "incomplete LHA \(name) Huffman table"
            )
        }

        nextCodes.update(repeating: 0, count: LHAStaticHuffmanTable.scratchCount)
        var code = 0
        for bitCount in 1...LHAStaticHuffmanTable.maximumBits {
            code = (code + counts[bitCount - 1]) << 1
            nextCodes[bitCount] = code
        }

        for symbol in 0..<symbolCount {
            let bitCount = Int(lengths[symbol])
            guard bitCount > 0 else { continue }
            let canonicalCode = nextCodes[bitCount]
            nextCodes[bitCount] += 1
            guard canonicalCode < 1 << bitCount else {
                throw KaitoError.malformed(
                    "invalid LHA \(name) canonical Huffman code"
                )
            }

            if bitCount <= LHAStaticHuffmanTable.primaryBits {
                let first = canonicalCode
                    << (LHAStaticHuffmanTable.primaryBits - bitCount)
                let repetitions = 1
                    << (LHAStaticHuffmanTable.primaryBits - bitCount)
                let record = UInt32(bitCount) << 16 | UInt32(symbol + 1)
                for index in first..<(first + repetitions) {
                    guard primary[index] == 0 else {
                        throw invalidCanonicalCode()
                    }
                    primary[index] = record
                }
                continue
            }

            let suffixBitCount = bitCount - LHAStaticHuffmanTable.primaryBits
            let prefix = canonicalCode >> suffixBitCount
            var nodeIndex: Int
            let primaryRecord = primary[prefix]
            if primaryRecord == 0 {
                nodeIndex = try allocateNode()
                primary[prefix] = branchRecord(nodeIndex)
            } else {
                guard isBranch(primaryRecord) else {
                    throw invalidCanonicalCode()
                }
                nodeIndex = branchIndex(primaryRecord)
            }

            for shift in stride(from: suffixBitCount - 1, through: 0, by: -1) {
                let bit = (canonicalCode >> shift) & 1
                let childIndex = nodeIndex * 2 + bit
                let child = nodes[childIndex]
                if shift == 0 {
                    guard child == 0 else { throw invalidCanonicalCode() }
                    nodes[childIndex] = UInt32(symbol + 1)
                } else if child == 0 {
                    let nextNode = try allocateNode()
                    nodes[childIndex] = branchRecord(nextNode)
                    nodeIndex = nextNode
                } else {
                    guard isBranch(child) else {
                        throw invalidCanonicalCode()
                    }
                    nodeIndex = branchIndex(child)
                }
            }
        }

        // A complete prefix code fills every primary slot and both children of
        // every allocated node. Keeping this invariant explicit ensures the
        // hot decoder never follows an uninitialized prefix.
        for index in 0..<LHAStaticHuffmanTable.primaryCount {
            guard primary[index] != 0 else { throw invalidCanonicalCode() }
        }
        for index in 0..<nodeCount {
            guard nodes[index * 2] != 0, nodes[index * 2 + 1] != 0 else {
                throw invalidCanonicalCode()
            }
        }
    }

    @inline(__always)
    func decode(bits: inout LHAStaticBitCursor) -> Int {
        if constantSymbol >= 0 { return constantSymbol }
        var record = primary[Int(bits.peek(LHAStaticHuffmanTable.primaryBits))]
        guard record != 0 else { return -1 }

        if !isBranch(record) {
            let bitCount = Int(record >> 16)
            let symbol = Int(record & LHAStaticHuffmanTable.symbolMask)
            // Build validates every leaf and child before publishing the table.
            bits.consume(bitCount)
            return symbol - 1
        }

        bits.consume(LHAStaticHuffmanTable.primaryBits)
        var depth = LHAStaticHuffmanTable.primaryBits
        while depth < LHAStaticHuffmanTable.maximumBits {
            let nodeIndex = branchIndex(record)
            let bit = Int(bits.read(1))
            depth += 1
            record = nodes[nodeIndex * 2 + bit]
            guard record != 0 else { return -1 }
            if !isBranch(record) {
                let symbol = Int(record & LHAStaticHuffmanTable.symbolMask)
                return symbol - 1
            }
        }
        return -1
    }

    private func allocateNode() throws -> Int {
        guard nodeCount < nodeCapacity else { throw invalidCanonicalCode() }
        let index = nodeCount
        nodeCount += 1
        nodes[index * 2] = 0
        nodes[index * 2 + 1] = 0
        return index
    }

    @inline(__always)
    private func branchRecord(_ index: Int) -> UInt32 {
        LHAStaticHuffmanTable.branchFlag | UInt32(index)
    }

    @inline(__always)
    private func isBranch(_ record: UInt32) -> Bool {
        record & LHAStaticHuffmanTable.branchFlag != 0
    }

    @inline(__always)
    private func branchIndex(_ record: UInt32) -> Int {
        Int(record & LHAStaticHuffmanTable.branchIndexMask)
    }

    private func invalidCanonicalCode() -> KaitoError {
        KaitoError.malformed(
            "invalid LHA \(name) canonical Huffman code"
        )
    }
}
