import Darwin
import Foundation

// Provenance:
// - Haruhiko Okumura, "Data Compression Algorithms of LARC and LHarc":
//   https://gamedev.net/tutorials/programming/general-and-gameplay-programming/data-compression-algorithms-of-larc-and-lharc-r295
// - LHa for UNIX header.doc (the -lh1- method parameters):
//   https://github.com/jca02266/lha/blob/master/header.doc.md
// - LZHUF format notes (adaptive literal/length alphabet and position coding):
//   https://ciderpress2.com/formatdoc/LZHuf-notes.html
// - A search UI auto-displayed a short Debian `lzhuf.c` snippet containing the
//   exact 64-symbol position prefix-length distribution. No file was opened or
//   code copied; raw liblhasa black-box vectors independently confirmed it.
// - Lhasa's method documentation and public raw-decoder API documentation:
//   https://github.com/fragglet/lhasa/blob/master/doc/lha.1
//   https://fragglet.github.io/lhasa/
// The installed `lha`/liblhasa executable was used only as a black-box oracle.
// No Lhasa implementation source, XADMaster, or The Unarchiver was consulted.

/// Streaming decoder for the original LHarc `-lh1-` (LZHUF) method.
///
/// Literal bytes and lengths 3...60 share a 314-symbol adaptive Huffman tree.
/// A match position is a fixed prefix code for the upper six bits followed by
/// six verbatim bits. The archive member's original size terminates the stream;
/// `-lh1-` has no in-band end marker.
final class LZHUFDecoder: Decompressor {
    private static let symbolCount = 314
    private static let nodeCount = symbolCount * 2 - 1
    private static let rootNode = nodeCount - 1
    private static let leafOffset = nodeCount
    private static let maximumFrequency = 0x8000
    private static let windowSize = 4_096
    private static let windowMask = windowSize - 1
    private static let maximumMatchLength = 60

    // The fixed position alphabet is canonical in symbol order. Its code
    // lengths are: 3; 4 x3; 5 x8; 6 x12; 7 x24; 8 x16.
    private static let positionTable: [UInt16] = {
        var lengths = [Int](repeating: 0, count: 64)
        lengths[0] = 3
        for index in 1...3 { lengths[index] = 4 }
        for index in 4...11 { lengths[index] = 5 }
        for index in 12...23 { lengths[index] = 6 }
        for index in 24...47 { lengths[index] = 7 }
        for index in 48...63 { lengths[index] = 8 }

        var result = [UInt16](repeating: 0, count: 256)
        var code = 0
        var previousLength = 0
        for symbol in 0..<lengths.count {
            let length = lengths[symbol]
            code <<= length - previousLength
            let first = code << (8 - length)
            let repetitions = 1 << (8 - length)
            let packed = UInt16((symbol << 8) | length)
            for suffix in 0..<repetitions {
                result[first | suffix] = packed
            }
            code += 1
            previousLength = length
        }
        return result
    }()

    private final class AdaptiveTree {
        // One sentinel frequency follows the 627 real nodes. Parent storage
        // also addresses the 314 synthetic leaf identifiers at 627...940.
        let frequencies: UnsafeMutablePointer<Int>
        let parents: UnsafeMutablePointer<Int>
        let children: UnsafeMutablePointer<Int>

        init() {
            frequencies = UnsafeMutablePointer<Int>.allocate(
                capacity: LZHUFDecoder.nodeCount + 1
            )
            parents = UnsafeMutablePointer<Int>.allocate(
                capacity: LZHUFDecoder.nodeCount + LZHUFDecoder.symbolCount
            )
            children = UnsafeMutablePointer<Int>.allocate(
                capacity: LZHUFDecoder.nodeCount
            )
            frequencies.initialize(repeating: 0, count: LZHUFDecoder.nodeCount + 1)
            parents.initialize(
                repeating: 0,
                count: LZHUFDecoder.nodeCount + LZHUFDecoder.symbolCount
            )
            children.initialize(repeating: 0, count: LZHUFDecoder.nodeCount)

            for symbol in 0..<LZHUFDecoder.symbolCount {
                frequencies[symbol] = 1
                children[symbol] = symbol + LZHUFDecoder.leafOffset
                parents[symbol + LZHUFDecoder.leafOffset] = symbol
            }

            var child = 0
            var node = LZHUFDecoder.symbolCount
            while node <= LZHUFDecoder.rootNode {
                frequencies[node] = frequencies[child] + frequencies[child + 1]
                children[node] = child
                parents[child] = node
                parents[child + 1] = node
                child += 2
                node += 1
            }
            frequencies[LZHUFDecoder.nodeCount] = 0xFFFF
            parents[LZHUFDecoder.rootNode] = 0
        }

        deinit {
            frequencies.deinitialize(count: LZHUFDecoder.nodeCount + 1)
            parents.deinitialize(
                count: LZHUFDecoder.nodeCount + LZHUFDecoder.symbolCount
            )
            children.deinitialize(count: LZHUFDecoder.nodeCount)
            frequencies.deallocate()
            parents.deallocate()
            children.deallocate()
        }
    }

    private let expectedSize: UInt64
    private let inputStorage: LHAPackedInputStorage
    private let window: UnsafeMutablePointer<UInt8>
    private let tree: AdaptiveTree
    private var bits: MSBFirstBitReader

    private var windowPosition = LZHUFDecoder.windowSize
        - LZHUFDecoder.maximumMatchLength
    private var produced: UInt64 = 0
    private var pendingDistance = 0
    private var pendingLength = 0
    private var finished: Bool

    /// Creates an `-lh1-` decoder over one exactly bounded member payload.
    init(
        source: any ByteSource,
        offset: UInt64,
        compressedSize: UInt64,
        uncompressedSize: UInt64,
        limits: ReadLimits
    ) throws {
        try Checked.size(compressedSize, limit: limits.maxEntrySize)
        try Checked.size(uncompressedSize, limit: limits.maxEntrySize)
        try Checked.size(UInt64(Self.windowSize), limit: limits.maxDictionarySize)
        let end = try Checked.add(offset, compressedSize)
        guard end <= source.length else { throw KaitoError.truncated }

        let inputCount = try Checked.toInt(compressedSize)
        let inputStorage = try LHAPackedInputStorage(
            source: source,
            offset: offset,
            count: inputCount
        )
        guard let allocation = malloc(Self.windowSize) else {
            throw KaitoError.limitExceeded("unable to allocate LZHUF dictionary")
        }
        let window = allocation.bindMemory(to: UInt8.self, capacity: Self.windowSize)
        // The LHarc ring begins at N-F with a preset space history. Filling the
        // whole allocation also makes unusual positions deterministic.
        window.initialize(repeating: 0x20, count: Self.windowSize)

        self.expectedSize = uncompressedSize
        self.inputStorage = inputStorage
        self.window = window
        self.tree = AdaptiveTree()
        self.bits = MSBFirstBitReader(
            borrowing: UnsafePointer(inputStorage.bytes),
            count: inputStorage.logicalCount
        )
        self.finished = uncompressedSize == 0
    }

    deinit {
        window.deinitialize(count: Self.windowSize)
        free(UnsafeMutableRawPointer(window))
    }

    var isFinished: Bool { finished }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !finished else { return 0 }
        guard let output = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            throw KaitoError.malformed("LZHUF output buffer has no storage")
        }

        let remainingOutput = try Checked.sub(expectedSize, produced)
        let outputLimit = try Checked.toInt(min(UInt64(buffer.count), remainingOutput))
        var outputPosition = 0

        while outputPosition < outputLimit {
            if pendingLength > 0 {
                let before = outputPosition
                lhaCopyMatch(
                    window: window,
                    windowMask: Self.windowMask,
                    windowPosition: &windowPosition,
                    distance: pendingDistance,
                    remaining: &pendingLength,
                    output: output,
                    outputPosition: &outputPosition,
                    outputLimit: outputLimit
                )
                produced = try Checked.add(produced, UInt64(outputPosition - before))
                if pendingLength == 0 { pendingDistance = 0 }
                continue
            }

            let symbol = try decodeSymbol()
            if symbol < 256 {
                try emit(UInt8(symbol), into: output, outputPosition: &outputPosition)
                continue
            }

            let length = symbol - 253
            guard (3...Self.maximumMatchLength).contains(length) else {
                throw KaitoError.malformed("invalid LZHUF match length")
            }
            let distance = try decodePosition() + 1
            guard (1...Self.windowSize).contains(distance) else {
                throw KaitoError.malformed("invalid LZHUF match distance")
            }
            let remaining = try Checked.sub(expectedSize, produced)
            guard UInt64(length) <= remaining else {
                throw KaitoError.malformed("LZHUF match exceeds the declared output size")
            }
            pendingDistance = distance
            pendingLength = length
        }

        if produced == expectedSize {
            guard pendingLength == 0 else {
                throw KaitoError.malformed("LZHUF match exceeds the declared output size")
            }
            finished = true
        }
        return outputPosition
    }

    private func emit(
        _ byte: UInt8,
        into output: UnsafeMutablePointer<UInt8>,
        outputPosition: inout Int
    ) throws {
        guard produced < expectedSize else {
            throw KaitoError.malformed("LZHUF output exceeds the declared size")
        }
        output[outputPosition] = byte
        outputPosition += 1
        window[windowPosition] = byte
        windowPosition = (windowPosition + 1) & Self.windowMask
        produced = try Checked.add(produced, 1)
    }

    private func decodeSymbol() throws -> Int {
        var node = tree.children[Self.rootNode]
        while node < Self.nodeCount {
            guard node >= 0, node + 1 < Self.nodeCount else {
                throw KaitoError.malformed("invalid LZHUF adaptive tree")
            }
            node += Int(try readBits(1))
            node = tree.children[node]
        }
        let symbol = node - Self.leafOffset
        guard (0..<Self.symbolCount).contains(symbol) else {
            throw KaitoError.malformed("invalid LZHUF adaptive symbol")
        }
        try updateTree(for: symbol)
        return symbol
    }

    private func decodePosition() throws -> Int {
        let prefix = Int(try bits.peek(8))
        guard !bits.overrun else { throw KaitoError.truncated }
        let entry = Self.positionTable[prefix]
        let length = Int(entry & 0x00FF)
        let upper = Int(entry >> 8)
        guard (3...8).contains(length), (0..<64).contains(upper) else {
            throw KaitoError.malformed("invalid LZHUF position prefix")
        }
        try bits.consume(length)
        guard !bits.overrun else { throw KaitoError.truncated }
        let lower = Int(try readBits(6))
        return (upper << 6) | lower
    }

    private func readBits(_ count: Int) throws -> UInt32 {
        let value = try bits.read(count)
        guard !bits.overrun else { throw KaitoError.truncated }
        return value
    }

    private func updateTree(for symbol: Int) throws {
        if tree.frequencies[Self.rootNode] >= Self.maximumFrequency {
            try reconstructTree()
        }

        var node = tree.parents[symbol + Self.leafOffset]
        while true {
            // Node zero is a real (usually low-frequency) tree node. The
            // zero stored as the root's parent is distinguished by checking
            // it only after processing the current node.
            guard node >= 0, node <= Self.rootNode else {
                throw KaitoError.malformed("invalid LZHUF adaptive parent")
            }
            let newFrequency = tree.frequencies[node] + 1
            tree.frequencies[node] = newFrequency

            if newFrequency > tree.frequencies[node + 1] {
                var target = node + 1
                while newFrequency > tree.frequencies[target + 1] {
                    target += 1
                    guard target <= Self.rootNode else {
                        throw KaitoError.malformed("invalid LZHUF frequency ordering")
                    }
                }

                tree.frequencies[node] = tree.frequencies[target]
                tree.frequencies[target] = newFrequency

                let firstChildren = tree.children[node]
                try setParent(of: firstChildren, to: target)
                let secondChildren = tree.children[target]
                tree.children[target] = firstChildren
                try setParent(of: secondChildren, to: node)
                tree.children[node] = secondChildren
                node = target
            }
            let parent = tree.parents[node]
            if parent == 0 { break }
            node = parent
        }
    }

    private func reconstructTree() throws {
        var leafCount = 0
        for node in 0..<Self.nodeCount where tree.children[node] >= Self.leafOffset {
            guard leafCount < Self.symbolCount else {
                throw KaitoError.malformed("too many LZHUF leaves")
            }
            tree.frequencies[leafCount] = (tree.frequencies[node] + 1) >> 1
            tree.children[leafCount] = tree.children[node]
            leafCount += 1
        }
        guard leafCount == Self.symbolCount else {
            throw KaitoError.malformed("incomplete LZHUF adaptive tree")
        }

        var child = 0
        var nextNode = Self.symbolCount
        while nextNode < Self.nodeCount {
            guard child + 1 < nextNode else {
                throw KaitoError.malformed("invalid LZHUF reconstruction pair")
            }
            let frequency = tree.frequencies[child] + tree.frequencies[child + 1]
            var insertion = nextNode
            while insertion > 0, frequency < tree.frequencies[insertion - 1] {
                tree.frequencies[insertion] = tree.frequencies[insertion - 1]
                tree.children[insertion] = tree.children[insertion - 1]
                insertion -= 1
            }
            guard insertion > child else {
                throw KaitoError.malformed("invalid LZHUF reconstruction order")
            }
            tree.frequencies[insertion] = frequency
            tree.children[insertion] = child
            child += 2
            nextNode += 1
        }

        for node in 0..<Self.nodeCount {
            try setParent(of: tree.children[node], to: node)
        }
        tree.frequencies[Self.nodeCount] = 0xFFFF
        tree.parents[Self.rootNode] = 0
    }

    private func setParent(of children: Int, to parent: Int) throws {
        if children >= Self.leafOffset {
            let maximumLeaf = Self.leafOffset + Self.symbolCount
            guard children < maximumLeaf else {
                throw KaitoError.malformed("invalid LZHUF leaf identifier")
            }
            tree.parents[children] = parent
            return
        }

        guard children >= 0, children + 1 < Self.nodeCount else {
            throw KaitoError.malformed("invalid LZHUF child pair")
        }
        tree.parents[children] = parent
        tree.parents[children + 1] = parent
    }
}
