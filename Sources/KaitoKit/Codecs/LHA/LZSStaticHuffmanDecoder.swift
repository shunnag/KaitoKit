import Darwin
import Foundation

// Provenance (format descriptions plus the disclosed search-result snippet):
// - LHa for UNIX `header.doc.md`, method descriptions for -lh4-...-lh7-:
//   https://github.com/jca02266/lha/blob/master/header.doc.md
// - Lhasa user documentation, compression-format notes:
//   https://github.com/fragglet/lhasa/blob/master/doc/lha.1
// - Haruhiko Okumura, "History of Data Compression in Japan", describing the
//   block-static, canonical Huffman scheme and recursively coded code lengths:
//   https://okumuralab.org/~okumura/compression/history.html
// - Haruhiko Okumura's 1990 notes, including the 16-bit code-length limit:
//   https://okumuralab.org/~okumura/compression/1990.html
// - A search UI auto-displayed short ARJ/ar002 `read_pt_len` decoder snippets;
//   they were consulted only to disambiguate the coded zero-run grammar. No
//   implementation file was opened or code copied, and the behavior was
//   independently confirmed with task vectors and the lhasa black-box oracle.
// XADMaster and The Unarchiver were not used.

/// Block-static LZSS/Huffman decoder shared by LHA methods -lh4- through -lh7-.
///
/// The packed stream is a sequence of blocks. Each block declares its command
/// count, a Huffman tree that codes command-tree lengths, the command tree, and
/// the position tree. Commands 0...255 are literals; commands 256...509 are
/// length/distance matches of 3...256 bytes.
///
/// Hot-loop invariants:
/// - the packed input is retained once with an eight-byte zero sentinel;
/// - the dictionary, length arrays, and bounded two-level Huffman tables are
///   once-allocated raw buffers;
/// - bit/window/output positions and pending-match state stay loop-local and
///   are committed once per `read` call;
/// - all tree counts and run lengths are validated while crossing a block
///   boundary; symbol decoding and window copying do not throw;
/// - a logical bit bound remains separate from the physical sentinel, so a
///   padded lookup is never accepted as real compressed input.
final class LZSStaticHuffmanDecoder: Decompressor {
    private static let commandSymbolCount = 510
    private static let commandCountBitWidth = 9
    private static let codeLengthSymbolCount = 19
    private static let codeLengthCountBitWidth = 5
    private static let codeLengthSpecialIndex = 3
    private static let sentinelByteCount = 8

    private let configuration: LHAStaticConfiguration
    private let expectedSize: UInt64
    private let inputStorage: LHAPackedInputStorage
    private let windowStorage: LHAStaticWindowStorage
    private let lengthStorage: LHAStaticLengthStorage
    private let codeLengthTable: LHAStaticHuffmanTable
    private let commandTable: LHAStaticHuffmanTable
    private let positionTable: LHAStaticHuffmanTable

    private var bits: LHAStaticBitCursor
    private var windowPosition = 0
    private var produced: UInt64 = 0
    private var blockRemaining = 0
    private var pendingDistance = 0
    private var pendingLength = 0
    private var finished: Bool
    private var terminalError: KaitoError?

    var isFinished: Bool { finished && terminalError == nil }

    init(
        method: String,
        source: any ByteSource,
        offset: UInt64,
        compressedSize: UInt64,
        uncompressedSize: UInt64,
        limits: ReadLimits
    ) throws {
        let configuration = try LHAStaticConfiguration(method: method)
        let endOffset = try Checked.add(offset, compressedSize)
        guard endOffset <= source.length else { throw KaitoError.truncated }
        try Checked.size(compressedSize, limit: limits.maxEntrySize)
        try Checked.size(uncompressedSize, limit: limits.maxEntrySize)
        try Checked.size(
            UInt64(configuration.dictionarySize),
            limit: limits.maxDictionarySize
        )

        let compressedCount = try Checked.toInt(compressedSize)
        guard compressedCount <= Int.max - LZSStaticHuffmanDecoder.sentinelByteCount,
              compressedCount <= Int.max / 8 else {
            throw KaitoError.limitExceeded("LHA compressed input size")
        }

        let inputStorage = try LHAPackedInputStorage(
            source: source,
            offset: offset,
            count: compressedCount,
            sentinelCount: LZSStaticHuffmanDecoder.sentinelByteCount
        )

        self.configuration = configuration
        self.expectedSize = uncompressedSize
        self.inputStorage = inputStorage
        self.windowStorage = try LHAStaticWindowStorage(
            count: configuration.dictionarySize
        )
        self.lengthStorage = try LHAStaticLengthStorage(
            codeLengthCount: LZSStaticHuffmanDecoder.codeLengthSymbolCount,
            commandCount: LZSStaticHuffmanDecoder.commandSymbolCount
        )
        self.codeLengthTable = try LHAStaticHuffmanTable(
            name: "code-length",
            maximumSymbolCount: LZSStaticHuffmanDecoder.codeLengthSymbolCount
        )
        self.commandTable = try LHAStaticHuffmanTable(
            name: "command",
            maximumSymbolCount: LZSStaticHuffmanDecoder.commandSymbolCount
        )
        self.positionTable = try LHAStaticHuffmanTable(
            name: "position",
            maximumSymbolCount: configuration.positionSymbolCount
        )
        self.bits = LHAStaticBitCursor(
            bytes: UnsafePointer(inputStorage.bytes),
            physicalByteCount: inputStorage.physicalCount,
            logicalBitCount: compressedCount * 8
        )
        self.finished = uncompressedSize == 0
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty else { return 0 }
        if let terminalError { throw terminalError }
        guard !finished else { return 0 }
        guard let output = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            return 0
        }

        var localBits = bits
        var localWindowPosition = windowPosition
        var localProduced = produced
        var localBlockRemaining = blockRemaining
        var localPendingDistance = pendingDistance
        var localPendingLength = pendingLength
        var outputPosition = 0
        var failure: KaitoError?

        while outputPosition < buffer.count,
              localProduced < expectedSize,
              failure == nil {
            if localPendingLength > 0 {
                let before = outputPosition
                lhaCopyMatch(
                    window: windowStorage.bytes,
                    windowMask: windowStorage.mask,
                    windowPosition: &localWindowPosition,
                    distance: localPendingDistance,
                    remaining: &localPendingLength,
                    output: output,
                    outputPosition: &outputPosition,
                    outputLimit: buffer.count
                )
                localProduced += UInt64(outputPosition - before)
                continue
            }

            if localBlockRemaining == 0 {
                do {
                    localBlockRemaining = try readBlock(bits: &localBits)
                } catch let error as KaitoError {
                    failure = error
                } catch {
                    failure = KaitoError.malformed("LHA Huffman block is invalid")
                }
                continue
            }

            let command = commandTable.decode(bits: &localBits)
            guard !localBits.overrun else {
                failure = KaitoError.truncated
                continue
            }
            guard command >= 0 else {
                failure = KaitoError.malformed("invalid LHA command Huffman code")
                continue
            }
            localBlockRemaining -= 1

            if command < 256 {
                let byte = UInt8(truncatingIfNeeded: command)
                windowStorage.bytes[localWindowPosition] = byte
                localWindowPosition = (localWindowPosition + 1) & windowStorage.mask
                output[outputPosition] = byte
                outputPosition += 1
                localProduced += 1
                continue
            }

            guard command < LZSStaticHuffmanDecoder.commandSymbolCount else {
                failure = KaitoError.malformed("LHA command symbol is out of range")
                continue
            }
            let length = command - 253
            guard localProduced <= expectedSize,
                  UInt64(length) <= expectedSize - localProduced else {
                failure = KaitoError.malformed(
                    "LHA match exceeds the declared output size"
                )
                continue
            }

            let positionSymbol = positionTable.decode(bits: &localBits)
            guard !localBits.overrun else {
                failure = KaitoError.truncated
                continue
            }
            guard positionSymbol >= 0,
                  positionSymbol < configuration.positionSymbolCount else {
                failure = KaitoError.malformed("invalid LHA position Huffman code")
                continue
            }

            let encodedPosition: Int
            if positionSymbol == 0 {
                encodedPosition = 0
            } else {
                let extraBitCount = positionSymbol - 1
                let suffix = Int(localBits.read(extraBitCount))
                guard !localBits.overrun else {
                    failure = KaitoError.truncated
                    continue
                }
                encodedPosition = (1 << extraBitCount) + suffix
            }
            let distance = encodedPosition + 1
            guard distance > 0, distance <= configuration.dictionarySize else {
                failure = KaitoError.malformed(
                    "LHA match distance is outside the dictionary"
                )
                continue
            }

            localPendingDistance = distance
            localPendingLength = length
        }

        bits = localBits
        windowPosition = localWindowPosition
        produced = localProduced
        blockRemaining = localBlockRemaining
        pendingDistance = localPendingDistance
        pendingLength = localPendingLength

        if failure == nil, localBits.overrun {
            failure = KaitoError.truncated
        }
        if let failure {
            terminalError = failure
            throw failure
        }

        if produced == expectedSize {
            guard pendingLength == 0 else {
                let error = KaitoError.malformed(
                    "LHA match exceeds the declared output size"
                )
                terminalError = error
                throw error
            }
            finished = true
        }
        return outputPosition
    }

    /// Reads and validates all metadata at a block boundary. No partially
    /// filled table can enter the symbol loop.
    private func readBlock(bits: inout LHAStaticBitCursor) throws -> Int {
        let commandCount = Int(bits.read(16))
        guard !bits.overrun else { throw KaitoError.truncated }

        try readCodeLengths(
            symbolCount: LZSStaticHuffmanDecoder.codeLengthSymbolCount,
            countBitWidth: LZSStaticHuffmanDecoder.codeLengthCountBitWidth,
            specialIndex: LZSStaticHuffmanDecoder.codeLengthSpecialIndex,
            lengths: lengthStorage.codeLengths,
            table: codeLengthTable,
            bits: &bits
        )
        try readCommandLengths(bits: &bits)
        try readCodeLengths(
            symbolCount: configuration.positionSymbolCount,
            countBitWidth: configuration.positionCountBitWidth,
            specialIndex: nil,
            lengths: lengthStorage.codeLengths,
            table: positionTable,
            bits: &bits
        )
        guard !bits.overrun else { throw KaitoError.truncated }
        // Some LHA-family writers emit an unusual empty block. Its three tree
        // descriptions still consume input, and the caller immediately reads
        // the following block, so a sequence of them has guaranteed progress.
        return commandCount
    }

    /// Reads the `pt_len` grammar used by both the code-length and position
    /// alphabets. Length seven is extended by a unary run of one bits followed
    /// by zero; canonical LHA trees are limited to 16 bits.
    private func readCodeLengths(
        symbolCount: Int,
        countBitWidth: Int,
        specialIndex: Int?,
        lengths: UnsafeMutablePointer<UInt8>,
        table: LHAStaticHuffmanTable,
        bits: inout LHAStaticBitCursor
    ) throws {
        lengths.update(repeating: 0, count: symbolCount)
        let encodedCount = Int(bits.read(countBitWidth))
        guard encodedCount <= symbolCount else {
            throw KaitoError.malformed(
                "LHA Huffman length count exceeds its table"
            )
        }

        if encodedCount == 0 {
            let symbol = Int(bits.read(countBitWidth))
            guard symbol < symbolCount else {
                throw KaitoError.malformed(
                    "LHA constant Huffman symbol is out of range"
                )
            }
            guard !bits.overrun else { throw KaitoError.truncated }
            table.setConstant(symbol)
            return
        }

        var index = 0
        while index < encodedCount {
            var length = Int(bits.read(3))
            if length == 7 {
                while bits.read(1) != 0 {
                    length += 1
                    guard length <= LHAStaticHuffmanTable.maximumBits else {
                        throw KaitoError.malformed(
                            "LHA Huffman code length exceeds 16"
                        )
                    }
                }
            }
            lengths[index] = UInt8(length)
            index += 1

            if let specialIndex, index == specialIndex {
                let zeroCount = Int(bits.read(2))
                guard zeroCount <= encodedCount - index,
                      zeroCount <= symbolCount - index else {
                    throw KaitoError.malformed(
                        "LHA special zero run exceeds its length table"
                    )
                }
                if zeroCount > 0 {
                    lengths.advanced(by: index).update(
                        repeating: 0,
                        count: zeroCount
                    )
                    index += zeroCount
                }
            }
        }
        guard !bits.overrun else { throw KaitoError.truncated }
        try table.build(lengths: lengths, symbolCount: symbolCount)
    }

    /// Reads the 510 command-code lengths. Symbols 0, 1, and 2 from the first
    /// tree represent bounded zero runs of 1, 3...18, and 20...531 entries.
    private func readCommandLengths(bits: inout LHAStaticBitCursor) throws {
        let lengths = lengthStorage.commandLengths
        lengths.update(
            repeating: 0,
            count: LZSStaticHuffmanDecoder.commandSymbolCount
        )
        let encodedCount = Int(
            bits.read(LZSStaticHuffmanDecoder.commandCountBitWidth)
        )
        guard encodedCount <= LZSStaticHuffmanDecoder.commandSymbolCount else {
            throw KaitoError.malformed(
                "LHA command length count exceeds its table"
            )
        }

        if encodedCount == 0 {
            let symbol = Int(
                bits.read(LZSStaticHuffmanDecoder.commandCountBitWidth)
            )
            guard symbol < LZSStaticHuffmanDecoder.commandSymbolCount else {
                throw KaitoError.malformed(
                    "LHA constant command symbol is out of range"
                )
            }
            guard !bits.overrun else { throw KaitoError.truncated }
            commandTable.setConstant(symbol)
            return
        }

        var index = 0
        while index < encodedCount {
            let symbol = codeLengthTable.decode(bits: &bits)
            guard symbol >= 0 else {
                throw bits.overrun
                    ? KaitoError.truncated
                    : KaitoError.malformed("invalid LHA code-length Huffman code")
            }

            if symbol <= 2 {
                let zeroCount: Int
                switch symbol {
                case 0:
                    zeroCount = 1
                case 1:
                    zeroCount = Int(bits.read(4)) + 3
                default:
                    zeroCount = Int(
                        bits.read(LZSStaticHuffmanDecoder.commandCountBitWidth)
                    ) + 20
                }
                guard zeroCount <= encodedCount - index,
                      zeroCount <= LZSStaticHuffmanDecoder.commandSymbolCount - index else {
                    throw KaitoError.malformed(
                        "LHA command zero run exceeds its length table"
                    )
                }
                lengths.advanced(by: index).update(
                    repeating: 0,
                    count: zeroCount
                )
                index += zeroCount
            } else {
                let length = symbol - 2
                guard length <= LHAStaticHuffmanTable.maximumBits else {
                    throw KaitoError.malformed(
                        "LHA command Huffman length exceeds 16"
                    )
                }
                lengths[index] = UInt8(length)
                index += 1
            }
        }
        guard !bits.overrun else { throw KaitoError.truncated }
        try commandTable.build(
            lengths: lengths,
            symbolCount: LZSStaticHuffmanDecoder.commandSymbolCount
        )
    }
}

private struct LHAStaticConfiguration {
    let dictionarySize: Int
    let positionSymbolCount: Int
    let positionCountBitWidth: Int

    init(method: String) throws {
        let dictionaryBits: Int
        switch method {
        case "-lh4-":
            dictionaryBits = 12
            positionCountBitWidth = 4
        case "-lh5-":
            dictionaryBits = 13
            positionCountBitWidth = 4
        case "-lh6-":
            dictionaryBits = 15
            positionCountBitWidth = 5
        case "-lh7-":
            dictionaryBits = 16
            positionCountBitWidth = 5
        default:
            throw KaitoError.unsupportedMethod(method)
        }
        dictionarySize = 1 << dictionaryBits
        positionSymbolCount = dictionaryBits + 1
    }
}

private final class LHAStaticWindowStorage {
    let bytes: UnsafeMutablePointer<UInt8>
    let count: Int
    let mask: Int

    init(count: Int) throws {
        guard count > 0, count.nonzeroBitCount == 1 else {
            throw KaitoError.malformed("LHA dictionary is not a power of two")
        }
        guard let raw = malloc(count) else {
            throw KaitoError.limitExceeded("unable to allocate LHA dictionary")
        }
        bytes = raw.bindMemory(to: UInt8.self, capacity: count)
        self.count = count
        self.mask = count - 1
        // Okumura's LZSS dictionary starts as spaces; early matches may refer
        // to this initialized history before the first literal is produced.
        bytes.initialize(repeating: 0x20, count: count)
    }

    deinit {
        bytes.deinitialize(count: count)
        free(UnsafeMutableRawPointer(bytes))
    }
}

private final class LHAStaticLengthStorage {
    let bytes: UnsafeMutablePointer<UInt8>
    let count: Int
    let codeLengths: UnsafeMutablePointer<UInt8>
    let commandLengths: UnsafeMutablePointer<UInt8>

    init(codeLengthCount: Int, commandCount: Int) throws {
        guard codeLengthCount > 0,
              commandCount > 0,
              codeLengthCount <= Int.max - commandCount else {
            throw KaitoError.limitExceeded("LHA Huffman length storage")
        }
        let count = codeLengthCount + commandCount
        guard let raw = malloc(count) else {
            throw KaitoError.limitExceeded("unable to allocate LHA Huffman lengths")
        }
        let bytes = raw.bindMemory(to: UInt8.self, capacity: count)
        bytes.initialize(repeating: 0, count: count)
        self.bytes = bytes
        self.count = count
        self.codeLengths = bytes
        self.commandLengths = bytes.advanced(by: codeLengthCount)
    }

    deinit {
        bytes.deinitialize(count: count)
        free(UnsafeMutableRawPointer(bytes))
    }
}

/// Canonical lookup with an eight-bit primary table and a bounded pool of
/// binary nodes for longer codes. Primary leaf records store
/// `(bitCount, symbol + 1)`; node leaves store `symbol + 1`, and the high bit
/// marks a node index. Zero is therefore an invalid-prefix sentinel.
/// Degenerate one-symbol trees are represented explicitly because they consume
/// no command bits in LHA.
private final class LHAStaticHuffmanTable {
    static let maximumBits = 16
    private static let primaryBits = 8
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
            guard bitCount > 0,
                  bitCount <= LHAStaticHuffmanTable.primaryBits,
                  symbol > 0,
                  symbol <= maximumSymbolCount else {
                return -1
            }
            bits.consume(bitCount)
            return symbol - 1
        }

        bits.consume(LHAStaticHuffmanTable.primaryBits)
        var depth = LHAStaticHuffmanTable.primaryBits
        while depth < LHAStaticHuffmanTable.maximumBits {
            let nodeIndex = branchIndex(record)
            guard nodeIndex >= 0, nodeIndex < nodeCount else { return -1 }
            let bit = Int(bits.read(1))
            depth += 1
            record = nodes[nodeIndex * 2 + bit]
            guard record != 0 else { return -1 }
            if !isBranch(record) {
                let symbol = Int(record & LHAStaticHuffmanTable.symbolMask)
                guard symbol > 0, symbol <= maximumSymbolCount else { return -1 }
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

/// Logical-bound wrapper around the package MSB-first reader. Its borrowed raw
/// allocation includes the decoder's physical sentinel, while
/// `logicalBitCount` excludes it. Lookahead may enter the sentinel; only
/// consumed real bits are accepted.
private struct LHAStaticBitCursor {
    private var reader: MSBFirstBitReader
    private let logicalBitCount: Int
    private var bitOffset: Int
    private var didOverrun: Bool

    var overrun: Bool { didOverrun || reader.overrun }

    init(
        bytes: UnsafePointer<UInt8>,
        physicalByteCount: Int,
        logicalBitCount: Int
    ) {
        self.reader = MSBFirstBitReader(
            borrowing: bytes,
            count: physicalByteCount
        )
        self.logicalBitCount = logicalBitCount
        self.bitOffset = 0
        self.didOverrun = false
    }

    @inline(__always)
    mutating func peek(_ count: Int) -> UInt32 {
        guard (0...32).contains(count) else {
            didOverrun = true
            return 0
        }
        do {
            return try reader.peek(count)
        } catch {
            didOverrun = true
            return 0
        }
    }

    @inline(__always)
    mutating func read(_ count: Int) -> UInt32 {
        guard (0...32).contains(count), bitOffset <= Int.max - count else {
            didOverrun = true
            return 0
        }
        let value: UInt32
        do {
            value = try reader.read(count)
        } catch {
            didOverrun = true
            return 0
        }
        bitOffset += count
        if bitOffset > logicalBitCount { didOverrun = true }
        return value
    }

    @inline(__always)
    mutating func consume(_ count: Int) {
        guard (0...32).contains(count), bitOffset <= Int.max - count else {
            didOverrun = true
            return
        }
        do {
            try reader.consume(count)
        } catch {
            didOverrun = true
            return
        }
        bitOffset += count
        if bitOffset > logicalBitCount { didOverrun = true }
    }
}
