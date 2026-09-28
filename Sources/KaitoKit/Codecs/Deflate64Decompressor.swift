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
    private let fixedLiteralDecoder: Deflate64HuffmanDecoder
    private let fixedDistanceDecoder: Deflate64HuffmanDecoder

    private var sourceOffset: UInt64
    private var input = [UInt8](repeating: 0, count: chunkSize)
    private var inputOffset = 0
    private var inputCount = 0

    private var bitReservoir: UInt64 = 0
    private var availableBits = 0
    private var bitAlignment = 0

    // Deflate64 の辞書は常に 64 KiB。未検証の展開サイズで確保しない。
    private var window = [UInt8](repeating: 0, count: windowSize)
    private var windowOffset = 0
    private var totalOutput: UInt64 = 0

    private var blockMode = BlockMode.header
    private var isFinalBlock = false
    private var storedRemaining = 0
    private var literalDecoder: Deflate64HuffmanDecoder?
    private var distanceDecoder: Deflate64HuffmanDecoder?
    private var matchDistance = 0
    private var matchRemaining = 0
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
        self.sourceOffset = offset
        self.compressedEnd = compressedEnd
        self.expectedSize = expectedSize
        self.fixedLiteralDecoder = try Deflate64HuffmanDecoder(
            lengths: Self.fixedLiteralCodeLengths(),
            alphabet: "fixed literal/length"
        )
        self.fixedDistanceDecoder = try Deflate64HuffmanDecoder(
            lengths: [UInt8](repeating: 5, count: 32),
            alphabet: "fixed distance"
        )
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
        var outputOffset = 0

        while outputOffset < outputCapacity, !finished {
            if matchRemaining > 0 {
                try copyMatch(into: buffer, outputOffset: &outputOffset, limit: outputCapacity)
                continue
            }

            switch blockMode {
            case .header:
                try beginBlock()

            case .stored:
                if storedRemaining == 0 {
                    try finishBlock()
                    continue
                }

                let byte = UInt8(truncatingIfNeeded: try readBits(8))
                try emit(byte, into: buffer, at: &outputOffset)
                storedRemaining -= 1

            case .compressed:
                guard let literalDecoder else {
                    throw KaitoError.malformed("Deflate64 block has no literal decoder")
                }
                let symbol = try decode(using: literalDecoder)
                switch symbol {
                case 0...255:
                    try emit(UInt8(symbol), into: buffer, at: &outputOffset)

                case 256:
                    try finishBlock()

                case 257...285:
                    let length = try decodeLength(symbol: symbol)
                    guard let distanceDecoder else {
                        throw KaitoError.malformed(
                            "Deflate64 length appears without a distance alphabet"
                        )
                    }
                    let distanceSymbol = try decode(using: distanceDecoder)
                    let distance = try decodeDistance(symbol: distanceSymbol)
                    let availableHistory = min(totalOutput, UInt64(Self.windowSize))
                    guard UInt64(distance) <= availableHistory else {
                        throw KaitoError.malformed(
                            "Deflate64 match refers beyond available history"
                        )
                    }
                    matchDistance = distance
                    matchRemaining = length

                case 286, 287:
                    throw KaitoError.malformed(
                        "reserved Deflate64 literal/length symbol \(symbol)"
                    )

                default:
                    throw KaitoError.malformed(
                        "invalid Deflate64 literal/length symbol \(symbol)"
                    )
                }
            }
        }

        return outputOffset
    }

    private func beginBlock() throws {
        isFinalBlock = try readBits(1) != 0
        let blockType = try readBits(2)

        switch blockType {
        case 0:
            try alignToByte()
            let length = UInt16(truncatingIfNeeded: try readBits(16))
            let complement = UInt16(truncatingIfNeeded: try readBits(16))
            guard length == ~complement else {
                throw KaitoError.malformed("invalid Deflate64 stored-block length")
            }
            storedRemaining = Int(length)
            literalDecoder = nil
            distanceDecoder = nil
            blockMode = .stored

        case 1:
            literalDecoder = fixedLiteralDecoder
            distanceDecoder = fixedDistanceDecoder
            blockMode = .compressed

        case 2:
            let decoders = try readDynamicDecoders()
            literalDecoder = decoders.literal
            distanceDecoder = decoders.distance
            blockMode = .compressed

        case 3:
            throw KaitoError.malformed("reserved Deflate64 block type")

        default:
            throw KaitoError.malformed("invalid Deflate64 block type")
        }
    }

    private func finishBlock() throws {
        storedRemaining = 0
        literalDecoder = nil
        distanceDecoder = nil

        if isFinalBlock {
            if let expectedSize, totalOutput != expectedSize {
                throw KaitoError.malformed(
                    "Deflate64 output size \(totalOutput) does not match expected size \(expectedSize)"
                )
            }
            // 最終 block の残り 0...7 bit は byte packing の余白として許すが、
            // BFINAL の後に完全な byte が残る圧縮範囲は一つの data stream ではない。
            guard availableBits < 8,
                  inputOffset == inputCount,
                  sourceOffset == compressedEnd else {
                throw KaitoError.malformed("trailing bytes after final Deflate64 block")
            }
            finished = true
        } else {
            blockMode = .header
        }
    }

    private func emit(
        _ byte: UInt8,
        into buffer: UnsafeMutableRawBufferPointer,
        at outputOffset: inout Int
    ) throws {
        let nextOutput = try Checked.add(totalOutput, 1)
        if let expectedSize, nextOutput > expectedSize {
            throw KaitoError.malformed("Deflate64 output exceeds the expected size")
        }
        guard outputOffset < buffer.count else {
            throw KaitoError.malformed("Deflate64 output accounting exceeded its buffer")
        }

        // outputOffset は buffer.count 未満、windowOffset は 0..<64KiB に維持する。
        buffer[outputOffset] = byte
        window[windowOffset] = byte
        outputOffset += 1
        totalOutput = nextOutput

        windowOffset += 1
        if windowOffset == Self.windowSize {
            windowOffset = 0
        }
    }

    private func copyMatch(
        into buffer: UnsafeMutableRawBufferPointer,
        outputOffset: inout Int,
        limit: Int
    ) throws {
        guard matchDistance > 0, matchDistance <= Self.windowSize else {
            throw KaitoError.malformed("invalid Deflate64 match distance")
        }

        while matchRemaining > 0, outputOffset < limit {
            let sourceOffset: Int
            if windowOffset >= matchDistance {
                sourceOffset = windowOffset - matchDistance
            } else {
                sourceOffset = windowOffset + Self.windowSize - matchDistance
            }
            let byte = window[sourceOffset]
            try emit(byte, into: buffer, at: &outputOffset)
            matchRemaining -= 1
        }

        if matchRemaining == 0 {
            matchDistance = 0
        }
    }

    private func decodeLength(symbol: Int) throws -> Int {
        if symbol == 285 {
            // Deflate64 では 285 が 3 + 16 bit。RFC 1951 の固定 258 とは異なる。
            let extra = UInt64(try readBits(16))
            return try Checked.toInt(try Checked.add(3, extra))
        }

        let index = symbol - 257
        guard index >= 0, index < Self.lengthBases.count else {
            throw KaitoError.malformed("invalid Deflate64 length symbol")
        }
        let extraBitCount = Self.lengthExtraBits[index]
        let extra = UInt64(try readBits(extraBitCount))
        return try Checked.toInt(
            try Checked.add(UInt64(Self.lengthBases[index]), extra)
        )
    }

    private func decodeDistance(symbol: Int) throws -> Int {
        guard symbol >= 0, symbol < Self.distanceBases.count else {
            throw KaitoError.malformed("invalid Deflate64 distance symbol \(symbol)")
        }
        let extraBitCount = Self.distanceExtraBits[symbol]
        let extra = UInt64(try readBits(extraBitCount))
        let distance = try Checked.add(UInt64(Self.distanceBases[symbol]), extra)
        guard distance >= 1, distance <= UInt64(Self.windowSize) else {
            throw KaitoError.malformed("Deflate64 distance exceeds 64 KiB")
        }
        return try Checked.toInt(distance)
    }

    private func readDynamicDecoders() throws -> (
        literal: Deflate64HuffmanDecoder,
        distance: Deflate64HuffmanDecoder?
    ) {
        let literalCount = Int(try readBits(5)) + 257
        let distanceCount = Int(try readBits(5)) + 1
        let codeLengthCount = Int(try readBits(4)) + 4
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
            codeLengthLengths[order[index]] = UInt8(truncatingIfNeeded: try readBits(3))
        }
        let codeLengthDecoder = try Deflate64HuffmanDecoder(
            lengths: codeLengthLengths,
            alphabet: "code-length"
        )

        let totalCount = literalCount + distanceCount
        var lengths = [UInt8]()
        lengths.reserveCapacity(totalCount)
        while lengths.count < totalCount {
            let symbol = try decode(using: codeLengthDecoder)
            switch symbol {
            case 0...15:
                lengths.append(UInt8(symbol))

            case 16:
                guard let previous = lengths.last else {
                    throw KaitoError.malformed(
                        "Deflate64 repeat code has no previous length"
                    )
                }
                let repeatCount = Int(try readBits(2)) + 3
                try appendRepeated(
                    previous,
                    count: repeatCount,
                    totalCount: totalCount,
                    to: &lengths
                )

            case 17:
                let repeatCount = Int(try readBits(3)) + 3
                try appendRepeated(
                    0,
                    count: repeatCount,
                    totalCount: totalCount,
                    to: &lengths
                )

            case 18:
                let repeatCount = Int(try readBits(7)) + 11
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
                alphabet: "distance"
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

    private func decode(using decoder: Deflate64HuffmanDecoder) throws -> Int {
        try decoder.decode {
            UInt8(truncatingIfNeeded: try self.readBits(1))
        }
    }

    private func alignToByte() throws {
        let count = (8 - bitAlignment) & 7
        _ = try readBits(count)
    }

    private func readBits(_ count: Int) throws -> UInt32 {
        guard (0...32).contains(count) else {
            throw KaitoError.malformed("invalid Deflate64 bit count")
        }
        guard count > 0 else {
            return 0
        }

        while availableBits < count {
            let byte = try readCompressedByte()
            guard availableBits <= 56 else {
                throw KaitoError.malformed("Deflate64 bit reservoir overflow")
            }
            bitReservoir |= UInt64(byte) << availableBits
            availableBits += 8
        }

        let mask: UInt64
        if count == 32 {
            mask = UInt64(UInt32.max)
        } else {
            mask = (UInt64(1) << count) - 1
        }
        let value = UInt32(truncatingIfNeeded: bitReservoir & mask)
        bitReservoir >>= count
        availableBits -= count
        bitAlignment = (bitAlignment + count) & 7
        return value
    }

    private func readCompressedByte() throws -> UInt8 {
        if inputOffset == inputCount {
            try refillInput()
        }
        guard inputOffset < inputCount else {
            throw KaitoError.truncated
        }
        let byte = input[inputOffset]
        inputOffset += 1
        return byte
    }

    private func refillInput() throws {
        guard sourceOffset < compressedEnd else {
            inputOffset = 0
            inputCount = 0
            return
        }

        let remaining = try Checked.sub(compressedEnd, sourceOffset)
        let requested = try Checked.toInt(min(UInt64(Self.chunkSize), remaining))
        let count = try input.withUnsafeMutableBytes { bytes -> Int in
            // requested は input.count 以下で、圧縮データ範囲の残量だけを公開する。
            let destination = UnsafeMutableRawBufferPointer(rebasing: bytes[..<requested])
            return try source.read(into: destination, at: sourceOffset)
        }
        guard count >= 0, count <= requested else {
            throw KaitoError.malformed("ByteSource returned an invalid byte count")
        }
        guard count != 0 else {
            throw KaitoError.truncated
        }

        sourceOffset = try Checked.add(sourceOffset, UInt64(count))
        inputOffset = 0
        inputCount = count
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

private struct Deflate64HuffmanDecoder {
    private struct Node {
        var zeroChild: Int?
        var oneChild: Int?
        var symbol: Int?
    }

    private let nodes: [Node]
    private let maximumLength: Int
    private let alphabet: String

    init(lengths: [UInt8], alphabet: String) throws {
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

        self.nodes = nodes
        self.maximumLength = maximumLength
        self.alphabet = alphabet
    }

    func decode(nextBit: () throws -> UInt8) throws -> Int {
        var nodeIndex = 0
        for _ in 0..<maximumLength {
            let bit = try nextBit()
            guard bit <= 1 else {
                throw KaitoError.malformed("invalid Deflate64 bit value")
            }
            let child = bit == 0
                ? nodes[nodeIndex].zeroChild
                : nodes[nodeIndex].oneChild
            guard let child else {
                throw KaitoError.malformed(
                    "invalid Deflate64 \(alphabet) Huffman code"
                )
            }
            nodeIndex = child
            if let symbol = nodes[nodeIndex].symbol {
                return symbol
            }
        }
        throw KaitoError.malformed(
            "unterminated Deflate64 \(alphabet) Huffman code"
        )
    }
}
