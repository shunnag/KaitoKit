import Darwin
import Foundation

// Provenance (format descriptions plus the disclosed search-result snippet):
// - LHa for UNIX `header.doc.md`, method descriptions for -lh4-...-lh7-:
//   https://github.com/jca02266/lha/blob/master/header.doc.md
// - Lhasa user documentation, compression-format notes:
//   https://github.com/fragglet/lhasa/blob/master/doc/lha.1
// - Jason Summers, "Notes on LHARK compression format", documenting the
//   six-bit position-tree count and LHARK's length/offset post-processing:
//   https://entropymine.wordpress.com/2020/12/24/notes-on-lhark-compression-format/
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

/// Block-static LZSS/Huffman decoder shared by LHA methods -lh4- through -lh7-
/// and UNLHA32's -lhx-, including the OS-marked LHArk dialect of -lh7-.
///
/// The packed stream is a sequence of blocks. Each block declares its command
/// count, a Huffman tree that codes command-tree lengths, the command tree, and
/// the position tree. Standard commands 0...255 are literals and 256...509 are
/// 3...256-byte matches; LHArk uses its documented 289-symbol alphabet and
/// match-length mapping through 514 bytes. LArc's `-lzs-` is a different
/// method and is decoded by `LArcDecoder`.
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
final class LHAStaticHuffmanDecoder: Decompressor {
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
        lhark: Bool = false,
        limits: ReadLimits
    ) throws {
        let configuration = try LHAStaticConfiguration(
            method: method,
            lhark: lhark
        )
        let endOffset = try Checked.add(offset, compressedSize)
        guard endOffset <= source.length else { throw KaitoError.truncated }
        try Checked.size(compressedSize, limit: limits.maxEntrySize)
        try Checked.size(uncompressedSize, limit: limits.maxEntrySize)
        try Checked.size(
            UInt64(configuration.dictionarySize),
            limit: limits.maxDictionarySize
        )

        let compressedCount = try Checked.toInt(compressedSize)
        guard compressedCount <= Int.max - LHAStaticHuffmanDecoder.sentinelByteCount,
              compressedCount <= Int.max / 8 else {
            throw KaitoError.limitExceeded("LHA compressed input size")
        }

        let inputStorage = try LHAPackedInputStorage(
            source: source,
            offset: offset,
            count: compressedCount,
            sentinelCount: LHAStaticHuffmanDecoder.sentinelByteCount
        )

        self.configuration = configuration
        self.expectedSize = uncompressedSize
        self.inputStorage = inputStorage
        self.windowStorage = try LHAStaticWindowStorage(
            count: configuration.dictionarySize
        )
        self.lengthStorage = try LHAStaticLengthStorage(
            codeLengthCount: max(
                LHAStaticHuffmanDecoder.codeLengthSymbolCount,
                configuration.positionSymbolCount
            ),
            commandCount: configuration.commandSymbolCount
        )
        self.codeLengthTable = try LHAStaticHuffmanTable(
            name: "code-length",
            maximumSymbolCount: LHAStaticHuffmanDecoder.codeLengthSymbolCount
        )
        self.commandTable = try LHAStaticHuffmanTable(
            name: "command",
            maximumSymbolCount: configuration.commandSymbolCount
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

        let window = windowStorage.bytes
        let windowMask = windowStorage.mask
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
                copyLZMatchThroughWindow(
                    window: window,
                    windowMask: windowMask,
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
                window[localWindowPosition] = byte
                localWindowPosition = (localWindowPosition + 1) & windowMask
                output[outputPosition] = byte
                outputPosition += 1
                localProduced += 1
                continue
            }

            guard command < configuration.commandSymbolCount else {
                failure = KaitoError.malformed("LHA command symbol is out of range")
                continue
            }
            let length: Int
            do {
                length = try configuration.matchLength(
                    command: command,
                    bits: &localBits
                )
            } catch let error as KaitoError {
                failure = error
                continue
            } catch {
                failure = KaitoError.malformed("invalid LHA match length")
                continue
            }
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
            do {
                encodedPosition = try configuration.position(
                    symbol: positionSymbol,
                    bits: &localBits
                )
            } catch let error as KaitoError {
                failure = error
                continue
            } catch {
                failure = KaitoError.malformed("invalid LHA match position")
                continue
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
            symbolCount: LHAStaticHuffmanDecoder.codeLengthSymbolCount,
            countBitWidth: LHAStaticHuffmanDecoder.codeLengthCountBitWidth,
            specialIndex: LHAStaticHuffmanDecoder.codeLengthSpecialIndex,
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

    /// Reads the configured command-code lengths. Symbols 0, 1, and 2 from
    /// the first tree represent bounded zero runs.
    private func readCommandLengths(bits: inout LHAStaticBitCursor) throws {
        let lengths = lengthStorage.commandLengths
        lengths.update(
            repeating: 0,
            count: configuration.commandSymbolCount
        )
        let encodedCount = Int(
            bits.read(LHAStaticHuffmanDecoder.commandCountBitWidth)
        )
        guard encodedCount <= configuration.commandSymbolCount else {
            throw KaitoError.malformed(
                "LHA command length count exceeds its table"
            )
        }

        if encodedCount == 0 {
            let symbol = Int(
                bits.read(LHAStaticHuffmanDecoder.commandCountBitWidth)
            )
            guard symbol < configuration.commandSymbolCount else {
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
                        bits.read(LHAStaticHuffmanDecoder.commandCountBitWidth)
                    ) + 20
                }
                guard zeroCount <= encodedCount - index,
                      zeroCount <= configuration.commandSymbolCount - index else {
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
            symbolCount: configuration.commandSymbolCount
        )
    }
}

private struct LHAStaticConfiguration {
    let dictionarySize: Int
    let positionSymbolCount: Int
    let positionCountBitWidth: Int
    let commandSymbolCount: Int
    let isLHArk: Bool

    init(method: String, lhark: Bool) throws {
        let dictionaryBits: Int
        if lhark, method != "-lh7-" {
            throw KaitoError.malformed("LHArk marker used with a non-LH7 method")
        }
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
            positionCountBitWidth = lhark ? 6 : 5
        case "-lhx-":
            // The public Lhasa format note specifies a 1 MiB UNLHA32 window.
            // The supplied archives resolve the otherwise undocumented
            // position-table count as five bits: that interpretation produces
            // complete canonical tables and byte-identical oracle output.
            dictionaryBits = 20
            positionCountBitWidth = 5
        default:
            throw KaitoError.unsupportedMethod(method)
        }
        dictionarySize = 1 << dictionaryBits
        // LHArk encodes the count in six bits but defines only offset-code
        // symbols 0...31. Standard static LHA trees need the symbols that can
        // address their dictionary.
        positionSymbolCount = lhark ? 32 : dictionaryBits + 1
        commandSymbolCount = lhark ? 289 : 510
        isLHArk = lhark
    }

    func matchLength(
        command: Int,
        bits: inout LHAStaticBitCursor
    ) throws -> Int {
        guard isLHArk else { return command - 253 }
        if command < 264 {
            return command - 253
        }
        if command == 288 {
            return 514
        }
        guard command < 288 else {
            throw KaitoError.malformed("LHArk match symbol is out of range")
        }
        let extraBitCount = (command - 260) / 4
        let suffix = Int(bits.read(extraBitCount))
        guard !bits.overrun else { throw KaitoError.truncated }
        return ((4 + command % 4) << extraBitCount) + suffix + 3
    }

    func position(
        symbol: Int,
        bits: inout LHAStaticBitCursor
    ) throws -> Int {
        if !isLHArk {
            guard symbol > 0 else { return 0 }
            let extraBitCount = symbol - 1
            let suffix = Int(bits.read(extraBitCount))
            guard !bits.overrun else { throw KaitoError.truncated }
            return (1 << extraBitCount) + suffix
        }

        guard symbol >= 4 else { return symbol }
        let extraBitCount = (symbol - 2) / 2
        let suffix = Int(bits.read(extraBitCount))
        guard !bits.overrun else { throw KaitoError.truncated }
        return ((2 + symbol % 2) << extraBitCount) + suffix
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
