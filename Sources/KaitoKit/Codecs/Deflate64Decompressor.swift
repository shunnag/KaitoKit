import Foundation

// 参照仕様: RFC 1951 と PKWARE APPNOTE.TXT 6.3.x の Deflate64 拡張。

/// A streaming Deflate64 decompressor with a 64 KiB history window.
public final class Deflate64Decompressor: Decompressor {
    private static let chunkSize = 256 * 1_024
    private static let windowSize = 64 * 1_024

    private enum BlockMode {
        case header
        case stored
        case compressed
    }

    private let source: any ByteSource
    private let compressedEnd: UInt64
    private let expectedSize: UInt64?
    // The RFC fixed alphabets are trusted constants, built once for all entries.
    private static let fixedLiteralDecoder = try! Deflate64HuffmanDecoder(
        lengths: fixedLiteralCodeLengths(), alphabet: "fixed literal/length"
    )
    private static let fixedDistanceDecoder = try! Deflate64HuffmanDecoder(
        lengths: [UInt8](repeating: 5, count: 32), alphabet: "fixed distance", primaryBits: 7
    )

    // Only source-filled input and previously produced history may be read.
    // Neither allocation needs an initialized suffix (see the bounds proof in read).
    private let input: UnsafeMutablePointer<UInt8>
    private let inputCapacity: Int
    private let window: UnsafeMutablePointer<UInt8>
    private var state: State

    private struct State {
        var sourceOffset: UInt64
        var inputOffset = 0
        var inputCount = 0
        var bitReservoir: UInt64 = 0
        var availableBits = 0
        var bitAlignment = 0
        var windowOffset = 0
        var totalOutput: UInt64 = 0
        var matchDistance = 0
        var matchRemaining = 0
    }

    private var blockMode = BlockMode.header
    private var isFinalBlock = false
    private var storedRemaining = 0
    private var literalDecoder: Deflate64HuffmanDecoder?
    private var distanceDecoder: Deflate64HuffmanDecoder?
    private var finished = false

    /// Creates a Deflate64 stream over a validated byte-source range.
    ///
    /// - Parameters:
    ///   - source: Random-access storage containing the compressed stream.
    ///   - offset: Absolute offset of the first Deflate64 byte.
    ///   - compressedSize: Exact byte range available to the decoder.
    ///   - expectedSize: Expected uncompressed size, when known.
    public init(
        source: any ByteSource,
        offset: UInt64,
        compressedSize: UInt64,
        expectedSize: UInt64?
    ) throws {
        let compressedEnd = try Checked.add(offset, compressedSize)
        guard compressedEnd <= source.length else {
            throw KaitoError.truncated
        }

        self.source = source
        self.state = State(sourceOffset: offset)
        self.compressedEnd = compressedEnd
        self.expectedSize = expectedSize
        inputCapacity = Int(min(UInt64(Self.chunkSize), max(1, compressedSize)))
        input = .allocate(capacity: inputCapacity)
        window = .allocate(capacity: Self.windowSize)
    }

    deinit {
        input.deallocate()
        window.deallocate()
    }

    /// Indicates whether the final block and its expected output size were validated.
    public var isFinished: Bool {
        finished
    }

    /// Expands up to one 256 KiB output chunk into `buffer`.
    public func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !finished else {
            return 0
        }
        guard buffer.baseAddress != nil else {
            throw KaitoError.malformed("Deflate64 output buffer has no storage")
        }

        let outputCapacity = min(buffer.count, Self.chunkSize)
        let output = buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
        var outputOffset = 0
        // State is local for the entire call, including throwing reads. Commit the
        // consumed input and partially written history on both success and failure.
        var state = self.state
        defer { self.state = state }
        // totalOutput <= expectedSize and UInt64.max is maintained at every write.
        // Each literal's outputOffset < literalLimit proves both additions safe;
        // no checked arithmetic or optional expected-size lookup is needed per byte.
        let literalLimit = Int(min(UInt64(outputCapacity),
                                   min((expectedSize ?? .max) - state.totalOutput,
                                       UInt64.max - state.totalOutput)))

        while outputOffset < outputCapacity, !finished {
            if state.matchRemaining > 0 {
                try copyMatch(into: output, outputOffset: &outputOffset,
                              limit: outputCapacity, state: &state)
                continue
            }

            switch blockMode {
            case .header:
                try beginBlock(state: &state)

            case .stored:
                if storedRemaining == 0 {
                    try finishBlock(state: &state)
                    continue
                }
                // Reservoir bytes precede buffered source bytes, even when a
                // compressed block speculatively prefetched a stored header.
                if state.availableBits >= 8 || outputOffset == literalLimit {
                    let byte = UInt8(truncatingIfNeeded: try readBits(8, state: &state))
                    try emit(byte, into: output, at: &outputOffset, limit: literalLimit, state: &state)
                    storedRemaining -= 1
                    continue
                }
                if state.inputOffset == state.inputCount { try refillInput(state: &state) }
                guard state.inputOffset < state.inputCount else { throw KaitoError.truncated }
                let count = min(storedRemaining, min(literalLimit - outputOffset,
                                                     state.inputCount - state.inputOffset))
                // count fits the caller, initialized input prefix, and remaining
                // output budget. Split history at its ring edge; count <= 65535.
                let source = input.advanced(by: state.inputOffset)
                output.advanced(by: outputOffset).update(from: source, count: count)
                let first = min(count, Self.windowSize - state.windowOffset)
                window.advanced(by: state.windowOffset).update(from: source, count: first)
                if first < count { window.update(from: source.advanced(by: first), count: count - first) }
                state.inputOffset += count
                state.windowOffset = (state.windowOffset + count) & (Self.windowSize - 1)
                state.totalOutput &+= UInt64(count)
                outputOffset += count
                storedRemaining -= count

            case .compressed:
                guard let literalDecoder else {
                    throw KaitoError.malformed("Deflate64 block has no literal decoder")
                }
                // Keep the table and state borrowed across literal runs.
                try literalDecoder.table.withUnsafeBufferPointer { table in
                    while outputOffset < outputCapacity, blockMode == .compressed {
                        let symbol = try decode(using: literalDecoder, table: table, state: &state)
                        switch symbol {
                        case 0...255:
                            try emit(UInt8(symbol), into: output, at: &outputOffset,
                                     limit: literalLimit, state: &state)
                        case 256:
                            try finishBlock(state: &state)
                            return
                        case 257...285:
                            let length = try decodeLength(symbol: symbol, state: &state)
                            guard let distanceDecoder else {
                                throw KaitoError.malformed("Deflate64 length appears without a distance alphabet")
                            }
                            let distanceSymbol = try decode(using: distanceDecoder, state: &state)
                            let distance = try decodeDistance(symbol: distanceSymbol, state: &state)
                            guard UInt64(distance) <= min(state.totalOutput, UInt64(Self.windowSize)) else {
                                throw KaitoError.malformed("Deflate64 match refers beyond available history")
                            }
                            state.matchDistance = distance
                            state.matchRemaining = length
                            return
                        case 286, 287:
                            throw KaitoError.malformed("reserved Deflate64 literal/length symbol \(symbol)")
                        default:
                            throw KaitoError.malformed("invalid Deflate64 literal/length symbol \(symbol)")
                        }
                    }
                }
            }
        }
        return outputOffset
    }

    private func beginBlock(state: inout State) throws {
        isFinalBlock = try readBits(1, state: &state) != 0
        let blockType = try readBits(2, state: &state)

        switch blockType {
        case 0:
            try alignToByte(state: &state)
            let length = UInt16(truncatingIfNeeded: try readBits(16, state: &state))
            let complement = UInt16(truncatingIfNeeded: try readBits(16, state: &state))
            guard length == ~complement else {
                throw KaitoError.malformed("invalid Deflate64 stored-block length")
            }
            storedRemaining = Int(length)
            literalDecoder = nil
            distanceDecoder = nil
            blockMode = .stored

        case 1:
            literalDecoder = Self.fixedLiteralDecoder
            distanceDecoder = Self.fixedDistanceDecoder
            blockMode = .compressed

        case 2:
            let decoders = try readDynamicDecoders(state: &state)
            literalDecoder = decoders.literal
            distanceDecoder = decoders.distance
            blockMode = .compressed

        case 3:
            throw KaitoError.malformed("reserved Deflate64 block type")

        default:
            throw KaitoError.malformed("invalid Deflate64 block type")
        }
    }

    private func finishBlock(state: inout State) throws {
        storedRemaining = 0
        literalDecoder = nil
        distanceDecoder = nil

        if isFinalBlock {
            if let expectedSize, state.totalOutput != expectedSize {
                throw KaitoError.malformed(
                    "Deflate64 output size \(state.totalOutput) does not match expected size \(expectedSize)"
                )
            }
            // 最終 block の残り 0...7 bit は byte packing の余白として許すが、
            // BFINAL の後に完全な byte が残る圧縮範囲は一つの data stream ではない。
            guard state.availableBits < 8,
                  state.inputOffset == state.inputCount,
                  state.sourceOffset == compressedEnd else {
                throw KaitoError.malformed("trailing bytes after final Deflate64 block")
            }
            finished = true
        } else {
            blockMode = .header
        }
    }

    @inline(__always)
    private func emit(_ byte: UInt8, into output: UnsafeMutablePointer<UInt8>,
                      at outputOffset: inout Int, limit: Int, state: inout State) throws {
        guard outputOffset < limit else {
            if state.totalOutput == .max {
                throw KaitoError.malformed("unsigned integer addition overflow")
            }
            throw KaitoError.malformed("Deflate64 output exceeds the expected size")
        }
        // outputOffset < limit <= outputCapacity; ring index is always masked.
        output[outputOffset] = byte
        window[state.windowOffset] = byte
        outputOffset &+= 1
        state.totalOutput &+= 1
        state.windowOffset = (state.windowOffset &+ 1) & (Self.windowSize - 1)
    }

    private func copyMatch(into output: UnsafeMutablePointer<UInt8>, outputOffset: inout Int,
                           limit: Int, state: inout State) throws {
        // The token checked 1...65536 and distance <= produced history. Therefore
        // every old seed byte is initialized, including distance 65536 at wrap.
        var count = min(state.matchRemaining, limit - outputOffset)
        if let expectedSize { count = Int(min(UInt64(count), expectedSize - state.totalOutput)) }
        let nextOutput = try Checked.add(state.totalOutput, UInt64(count))
        let copyLimit = outputOffset + count
        // Deflate64's maximum match is 65538. The shared primitive copies at
        // most one ring turn; a second call handles the remaining two bytes.
        while outputOffset < copyLimit {
            copyLZMatchThroughWindow(window: window, windowMask: Self.windowSize - 1,
                                     windowPosition: &state.windowOffset, distance: state.matchDistance,
                                     remaining: &state.matchRemaining, output: output,
                                     outputPosition: &outputOffset, outputLimit: copyLimit)
        }
        state.totalOutput = nextOutput
        if state.matchRemaining > 0, outputOffset < limit {
            throw KaitoError.malformed("Deflate64 output exceeds the expected size")
        }
        if state.matchRemaining == 0 { state.matchDistance = 0 }
    }

    private func decodeLength(symbol: Int, state: inout State) throws -> Int {
        if symbol == 285 {
            // APPNOTE: 3 + 16 bits, hence 3...65538 (fits Int).
            return 3 + Int(try readBits(16, state: &state))
        }
        let index = symbol - 257  // caller proved 257...284
        return Self.lengthBases[index] + Int(try readBits(Self.lengthExtraBits[index], state: &state))
    }

    private func decodeDistance(symbol: Int, state: inout State) throws -> Int {
        guard symbol >= 0, symbol < Self.distanceBases.count else {
            throw KaitoError.malformed("invalid Deflate64 distance symbol \(symbol)")
        }
        // All 32 bases + their 0...14 extra bits are within 1...65536.
        return Self.distanceBases[symbol] + Int(try readBits(Self.distanceExtraBits[symbol], state: &state))
    }

    private func readDynamicDecoders(state: inout State) throws -> (
        literal: Deflate64HuffmanDecoder,
        distance: Deflate64HuffmanDecoder?
    ) {
        let literalCount = Int(try readBits(5, state: &state)) + 257
        let distanceCount = Int(try readBits(5, state: &state)) + 1
        let codeLengthCount = Int(try readBits(4, state: &state)) + 4
        guard (257...286).contains(literalCount),
              (1...32).contains(distanceCount),
              (4...19).contains(codeLengthCount) else {
            throw KaitoError.malformed("invalid Deflate64 dynamic alphabet counts")
        }

        let order = [
            16, 17, 18, 0, 8, 7, 9, 6, 10, 5,
            11, 4, 12, 3, 13, 2, 14, 1, 15,
        ]
        var codeLengthLengths = [UInt8](repeating: 0, count: 19)
        for index in 0..<codeLengthCount {
            codeLengthLengths[order[index]] = UInt8(truncatingIfNeeded: try readBits(3, state: &state))
        }
        let codeLengthDecoder = try Deflate64HuffmanDecoder(
            lengths: codeLengthLengths,
            alphabet: "code-length",
            primaryBits: 7
        )

        let totalCount = literalCount + distanceCount
        var lengths = [UInt8]()
        lengths.reserveCapacity(totalCount)
        while lengths.count < totalCount {
            let symbol = try decode(using: codeLengthDecoder, state: &state)
            switch symbol {
            case 0...15:
                lengths.append(UInt8(symbol))

            case 16:
                guard let previous = lengths.last else {
                    throw KaitoError.malformed(
                        "Deflate64 repeat code has no previous length"
                    )
                }
                let repeatCount = Int(try readBits(2, state: &state)) + 3
                try appendRepeated(
                    previous,
                    count: repeatCount,
                    totalCount: totalCount,
                    to: &lengths
                )

            case 17:
                let repeatCount = Int(try readBits(3, state: &state)) + 3
                try appendRepeated(
                    0,
                    count: repeatCount,
                    totalCount: totalCount,
                    to: &lengths
                )

            case 18:
                let repeatCount = Int(try readBits(7, state: &state)) + 11
                try appendRepeated(
                    0,
                    count: repeatCount,
                    totalCount: totalCount,
                    to: &lengths
                )

            default:
                throw KaitoError.malformed(
                    "invalid Deflate64 code-length symbol \(symbol)"
                )
            }
        }

        let literalLengths = Array(lengths[..<literalCount])
        guard literalLengths[256] != 0 else {
            throw KaitoError.malformed("Deflate64 literal alphabet has no end marker")
        }
        let literal = try Deflate64HuffmanDecoder(
            lengths: literalLengths,
            alphabet: "literal/length"
        )

        let distanceLengths = Array(lengths[literalCount..<totalCount])
        let distance: Deflate64HuffmanDecoder?
        if distanceLengths.allSatisfy({ $0 == 0 }) {
            // RFC 1951 の全リテラル特殊形は、HDIST が一個でその長さが 0 の場合だけ。
            guard distanceCount == 1 else {
                throw KaitoError.malformed(
                    "Deflate64 empty distance alphabet has more than one code"
                )
            }
            distance = nil
        } else {
            distance = try Deflate64HuffmanDecoder(
                lengths: distanceLengths,
                alphabet: "distance",
                primaryBits: 7
            )
        }
        return (literal, distance)
    }

    private func appendRepeated(
        _ value: UInt8,
        count: Int,
        totalCount: Int,
        to lengths: inout [UInt8]
    ) throws {
        guard count > 0, lengths.count <= totalCount - count else {
            throw KaitoError.malformed("Deflate64 code-length repeat overruns its alphabet")
        }
        lengths.append(contentsOf: repeatElement(value, count: count))
    }

    @inline(__always)
    private func decode(using decoder: Deflate64HuffmanDecoder, state: inout State) throws -> Int {
        try decoder.table.withUnsafeBufferPointer { table in
            try decode(using: decoder, table: table, state: &state)
        }
    }

    @inline(__always)
    private func decode(using decoder: Deflate64HuffmanDecoder,
                        table: UnsafeBufferPointer<Deflate64HuffmanDecoder.Entry>,
                        state: inout State) throws -> Int {
        // Speculative refill uses only bytes already fetched by readBits/refillInput.
        // Never read the source just for lookahead: a short terminal code or an
        // invalid prefix must win over a later truncation or source error.
        if state.availableBits < decoder.maximumLength {
            while state.availableBits <= 56, state.inputOffset < state.inputCount {
                state.bitReservoir |= UInt64(input[state.inputOffset]) << state.availableBits
                state.inputOffset += 1
                state.availableBits += 8
            }
        }
        // The constructor fills 1 << primaryBits root slots and appends every
        // secondary suffix range in full. Masks therefore stay inside this table;
        // no input bits can manufacture a table offset or an out-of-range symbol.
        while true {
            var entry = table[Int(state.bitReservoir & decoder.primaryMask)]
            if state.availableBits >= Int(entry.bitCount), entry.value <= -2 {
                let offset = Int(-entry.value - 2)
                let mask = (UInt64(1) << entry.lookupBits) - 1
                entry = table[offset + Int((state.bitReservoir >> decoder.primaryBits) & mask)]
            }
            let count = Int(entry.bitCount)
            if state.availableBits < count {
                // Zero padding a lookup is safe only when all bits needed by that
                // result are present. Invalid slots carry the first missing edge's
                // depth, preserving malformed versus truncated for incomplete trees.
                let byte = try readCompressedByte(state: &state)
                state.bitReservoir |= UInt64(byte) << state.availableBits
                state.availableBits += 8
                continue
            }
            state.bitReservoir >>= count
            state.availableBits -= count
            state.bitAlignment = (state.bitAlignment + count) & 7
            guard entry.value >= 0 else {
                throw KaitoError.malformed("invalid Deflate64 \(decoder.alphabet) Huffman code")
            }
            return Int(entry.value)
        }
    }

    private func alignToByte(state: inout State) throws {
        let count = (8 - state.bitAlignment) & 7
        _ = try readBits(count, state: &state)
    }

    private func readBits(_ count: Int, state: inout State) throws -> UInt32 {
        guard (0...32).contains(count) else {
            throw KaitoError.malformed("invalid Deflate64 bit count")
        }
        guard count > 0 else {
            return 0
        }

        while state.availableBits < count {
            let byte = try readCompressedByte(state: &state)
            guard state.availableBits <= 56 else {
                throw KaitoError.malformed("Deflate64 bit reservoir overflow")
            }
            state.bitReservoir |= UInt64(byte) << state.availableBits
            state.availableBits += 8
        }

        let mask: UInt64
        if count == 32 {
            mask = UInt64(UInt32.max)
        } else {
            mask = (UInt64(1) << count) - 1
        }
        let value = UInt32(truncatingIfNeeded: state.bitReservoir & mask)
        state.bitReservoir >>= count
        state.availableBits -= count
        state.bitAlignment = (state.bitAlignment + count) & 7
        return value
    }

    private func readCompressedByte(state: inout State) throws -> UInt8 {
        if state.inputOffset == state.inputCount {
            try refillInput(state: &state)
        }
        guard state.inputOffset < state.inputCount else {
            throw KaitoError.truncated
        }
        let byte = input[state.inputOffset]
        state.inputOffset += 1
        return byte
    }

    private func refillInput(state: inout State) throws {
        guard state.sourceOffset < compressedEnd else {
            state.inputOffset = 0
            state.inputCount = 0
            return
        }

        let remaining = try Checked.sub(compressedEnd, state.sourceOffset)
        let requested = try Checked.toInt(min(UInt64(inputCapacity), remaining))
        let count = try source.read(into: UnsafeMutableRawBufferPointer(start: input, count: requested),
                                    at: state.sourceOffset)
        guard count >= 0, count <= requested else {
            throw KaitoError.malformed("ByteSource returned an invalid byte count")
        }
        guard count != 0 else {
            throw KaitoError.truncated
        }

        state.sourceOffset = try Checked.add(state.sourceOffset, UInt64(count))
        state.inputOffset = 0
        state.inputCount = count
    }

    private static func fixedLiteralCodeLengths() -> [UInt8] {
        var lengths = [UInt8](repeating: 0, count: 288)
        for symbol in 0...143 {
            lengths[symbol] = 8
        }
        for symbol in 144...255 {
            lengths[symbol] = 9
        }
        for symbol in 256...279 {
            lengths[symbol] = 7
        }
        for symbol in 280...287 {
            lengths[symbol] = 8
        }
        return lengths
    }

    private static let lengthBases = [
        3, 4, 5, 6, 7, 8, 9, 10,
        11, 13, 15, 17,
        19, 23, 27, 31,
        35, 43, 51, 59,
        67, 83, 99, 115,
        131, 163, 195, 227,
    ]

    private static let lengthExtraBits = [
        0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1,
        2, 2, 2, 2,
        3, 3, 3, 3,
        4, 4, 4, 4,
        5, 5, 5, 5,
    ]

    private static let distanceBases = [
        1, 2, 3, 4,
        5, 7, 9, 13,
        17, 25, 33, 49,
        65, 97, 129, 193,
        257, 385, 513, 769,
        1_025, 1_537, 2_049, 3_073,
        4_097, 6_145, 8_193, 12_289,
        16_385, 24_577, 32_769, 49_153,
    ]

    private static let distanceExtraBits = [
        0, 0, 0, 0,
        1, 1, 2, 2,
        3, 3, 4, 4,
        5, 5, 6, 6,
        7, 7, 8, 8,
        9, 9, 10, 10,
        11, 11, 12, 12,
        13, 13, 14, 14,
    ]
}

private struct Deflate64HuffmanDecoder: Sendable {
    private struct Node {
        var zeroChild: Int?
        var oneChild: Int?
        var symbol: Int?
    }

    // Nonnegative value: symbol; -1: invalid prefix; <= -2: secondary offset.
    struct Entry: Sendable {
        let value: Int32
        let bitCount: UInt8
        let lookupBits: UInt8
    }

    let table: [Entry]
    let primaryBits: Int
    let primaryMask: UInt64
    let maximumLength: Int
    let alphabet: String

    init(lengths: [UInt8], alphabet: String, primaryBits: Int = 9) throws {
        var counts = [Int](repeating: 0, count: 16)
        var maximumLength = 0
        for lengthByte in lengths {
            let length = Int(lengthByte)
            guard length <= 15 else {
                throw KaitoError.malformed(
                    "Deflate64 \(alphabet) code length exceeds 15 bits"
                )
            }
            if length > 0 {
                counts[length] += 1
                maximumLength = max(maximumLength, length)
            }
        }
        guard maximumLength > 0 else {
            throw KaitoError.malformed("Deflate64 \(alphabet) alphabet is empty")
        }

        // Kraft の不等式で過剩割り当てを確保前に拒否する。不完全木は RFC 1951 互換のため許す。
        var remainingCodes = 1
        for bitLength in 1...15 {
            remainingCodes *= 2
            guard counts[bitLength] <= remainingCodes else {
                throw KaitoError.malformed(
                    "Deflate64 \(alphabet) alphabet is oversubscribed"
                )
            }
            remainingCodes -= counts[bitLength]
        }

        var nextCode = [Int](repeating: 0, count: 16)
        var code = 0
        if maximumLength > 0 {
            for bitLength in 1...maximumLength {
                code = (code + counts[bitLength - 1]) << 1
                nextCode[bitLength] = code
            }
        }

        var nodes = [Node(zeroChild: nil, oneChild: nil, symbol: nil)]
        for (symbol, lengthByte) in lengths.enumerated() where lengthByte != 0 {
            let length = Int(lengthByte)
            let assignedCode = nextCode[length]
            nextCode[length] += 1
            var nodeIndex = 0

            for shift in stride(from: length - 1, through: 0, by: -1) {
                guard nodes[nodeIndex].symbol == nil else {
                    throw KaitoError.malformed(
                        "Deflate64 \(alphabet) alphabet has a prefix collision"
                    )
                }

                let bit = (assignedCode >> shift) & 1
                let existing = bit == 0
                    ? nodes[nodeIndex].zeroChild
                    : nodes[nodeIndex].oneChild
                if let existing {
                    nodeIndex = existing
                } else {
                    let childIndex = nodes.count
                    nodes.append(Node(zeroChild: nil, oneChild: nil, symbol: nil))
                    if bit == 0 {
                        nodes[nodeIndex].zeroChild = childIndex
                    } else {
                        nodes[nodeIndex].oneChild = childIndex
                    }
                    nodeIndex = childIndex
                }
            }

            guard nodes[nodeIndex].symbol == nil,
                  nodes[nodeIndex].zeroChild == nil,
                  nodes[nodeIndex].oneChild == nil else {
                throw KaitoError.malformed(
                    "Deflate64 \(alphabet) alphabet has duplicate codes"
                )
            }
            nodes[nodeIndex].symbol = symbol
        }

        // Keep the original canonical-tree validation above, including its error
        // messages and acceptance of incomplete alphabets. The tree is used only
        // to construct tables and is not retained by the streaming decoder.
        let rootBits = min(primaryBits, maximumLength)
        let invalid = Entry(value: -1, bitCount: 0, lookupBits: 0)
        var table = [Entry](repeating: invalid, count: 1 << rootBits)

        func lookup(node: Int, bits: Int, count: Int, depth: Int) -> (Entry, Int?) {
            var index = node
            for step in 0..<count {
                let bit = (bits >> step) & 1
                let child = bit == 0 ? nodes[index].zeroChild : nodes[index].oneChild
                guard let child else {
                    return (Entry(value: -1, bitCount: UInt8(depth + step + 1), lookupBits: 0), nil)
                }
                index = child
                if let symbol = nodes[index].symbol {
                    return (Entry(value: Int32(symbol), bitCount: UInt8(depth + step + 1), lookupBits: 0), nil)
                }
            }
            return (invalid, index)
        }

        func depthBelow(_ index: Int) -> Int {
            if nodes[index].symbol != nil { return 0 }
            return 1 + max(nodes[index].zeroChild.map(depthBelow) ?? 0,
                           nodes[index].oneChild.map(depthBelow) ?? 0)
        }

        for prefix in 0..<(1 << rootBits) {
            let (entry, node) = lookup(node: 0, bits: prefix, count: rootBits, depth: 0)
            guard let node else {
                table[prefix] = entry
                continue
            }
            let extraBits = depthBelow(node)
            let offset = table.count
            table[prefix] = Entry(value: -Int32(offset) - 2,
                                  bitCount: UInt8(rootBits), lookupBits: UInt8(extraBits))
            for suffix in 0..<(1 << extraBits) {
                table.append(lookup(node: node, bits: suffix, count: extraBits, depth: rootBits).0)
            }
        }
        self.table = table
        self.primaryBits = rootBits
        self.primaryMask = UInt64((1 << rootBits) - 1)
        self.maximumLength = maximumLength
        self.alphabet = alphabet
    }
}
