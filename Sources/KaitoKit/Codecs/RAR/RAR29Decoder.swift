import Darwin
import Foundation

// Provenance:
// - RAR 1.5-4.x unofficial format notes, especially sections 18-20:
//   https://github.com/bitplane/rar-research/blob/master/doc/RAR15_40_FORMAT_SPECIFICATION.md
// - libarchive's BSD-2-licensed archive_read_support_format_rar.c was consulted
//   for behaviour (block/table transitions, match state, and validation), not
//   for code or structure:
//   https://github.com/libarchive/libarchive/blob/master/libarchive/archive_read_support_format_rar.c
// No 7-Zip Rar29, unrar source, XADMaster, or The Unarchiver source was used.

/// RAR 2.9/3.x LZ decoder.
///
/// This implementation deliberately accepts only independent `UNP_VER == 29`
/// LZ blocks. PPMd, solid continuation, and RARVM filters are rejected at the
/// exact token that introduces them, so unsupported data can never be confused
/// with successfully decoded output.
///
/// Performance invariants:
/// - compressed input, the power-of-two window, and Huffman lookup tables are
///   once-allocated raw buffers;
/// - the compressed input has eight zero sentinel bytes, so a bounded 40-bit
///   peek cannot physically overread even when logical input is truncated;
/// - the per-symbol loop keeps bit position, window position, repeat distances,
///   and pending-match state in local variables, writing them back once;
/// - logical input and match bounds are checked at table/match boundaries; the
///   symbol loop records a failure and throws only after leaving the loop;
/// - non-wrapping, non-dependent match chunks use `copyMemory` through the
///   caller buffer, with byte copying retained for overlapping repetitions.
final class RAR29Decoder: Decompressor {
    private static let mainSymbolCount = 299
    private static let distanceSymbolCount = 60
    private static let lowDistanceSymbolCount = 17
    private static let lengthSymbolCount = 28
    private static let combinedLengthCount = 404
    private static let sentinelByteCount = 8

    private static let lengthBases: [Int] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20,
        24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224,
    ]
    private static let lengthBits: [Int] = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2,
        2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5,
    ]
    private static let distanceBases: [Int] = [
        0, 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48,
        64, 96, 128, 192, 256, 384, 512, 768, 1_024, 1_536,
        2_048, 3_072, 4_096, 6_144, 8_192, 12_288, 16_384, 24_576,
        32_768, 49_152, 65_536, 98_304, 131_072, 196_608,
        262_144, 327_680, 393_216, 458_752, 524_288, 589_824,
        655_360, 720_896, 786_432, 851_968, 917_504, 983_040,
        1_048_576, 1_310_720, 1_572_864, 1_835_008, 2_097_152, 2_359_296,
        2_621_440, 2_883_584, 3_145_728, 3_407_872, 3_670_016, 3_932_160,
    ]
    private static let distanceBits: [Int] = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4,
        5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10,
        11, 11, 12, 12, 13, 13, 14, 14, 15, 15, 16, 16,
        16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16,
        18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18,
    ]
    private static let shortBases = [0, 4, 8, 16, 32, 64, 128, 192]
    private static let shortBits = [2, 2, 3, 4, 5, 6, 6, 6]

    private enum DecodeFailure {
        case truncated
        case malformed(String)
        case unsupported(String)
    }

    private let input: UnsafeMutablePointer<UInt8>
    private let inputCount: Int
    private let window: UnsafeMutablePointer<UInt8>
    private let windowSize: Int
    private let windowMask: Int
    private let expectedSize: UInt64

    private let mainTable = RAR29HuffmanTable()
    private let distanceTable = RAR29HuffmanTable()
    private let lowDistanceTable = RAR29HuffmanTable()
    private let lengthTable = RAR29HuffmanTable()
    private let levelTable = RAR29HuffmanTable()
    private var previousLengths = [UInt8](repeating: 0, count: combinedLengthCount)

    private var bitOffset = 0
    private var produced: UInt64 = 0
    private var oldOffset0 = 0
    private var oldOffset1 = 0
    private var oldOffset2 = 0
    private var oldOffset3 = 0
    private var lastOffset = 0
    private var lastLength = 0
    private var lastLowOffset = 0
    private var lowOffsetRepeatCount = 0
    private var pendingDistance = 0
    private var pendingLength = 0
    private var needsInitialTables = true
    private var finished = false
    private var terminalFailure: DecodeFailure?

    var isFinished: Bool { finished && terminalFailure == nil }

    init(
        source: any ByteSource,
        offset: UInt64,
        compressedSize: UInt64,
        uncompressedSize: UInt64,
        unpackVersion: UInt8,
        method: UInt8,
        dictionarySize: UInt64,
        isSolid: Bool,
        limits: ReadLimits
    ) throws {
        let end = try Checked.add(offset, compressedSize)
        guard end <= source.length else { throw KaitoError.truncated }
        try Checked.size(uncompressedSize, limit: limits.maxEntrySize)
        // The decoder retains the complete packed stream in one raw buffer.
        // Bound that attacker-controlled allocation independently of the much
        // smaller declared output before converting it to `Int` or calling
        // malloc, matching the RAR5 decoder's packed-input policy.
        try Checked.size(compressedSize, limit: limits.maxEntrySize)
        try Checked.size(dictionarySize, limit: limits.maxDictionarySize)
        guard (0x31...0x35).contains(method) else {
            throw KaitoError.unsupportedMethod(
                String(format: "RAR4 method 0x%02x", method)
            )
        }
        guard unpackVersion == 29 else {
            throw KaitoError.unsupportedMethod(
                "RAR4 unpack version \(unpackVersion)"
            )
        }
        guard !isSolid else {
            throw KaitoError.unsupportedMethod("RAR4 solid compression")
        }
        let compressedCount = try Checked.toInt(compressedSize)
        guard compressedCount <= Int.max - Self.sentinelByteCount,
              compressedCount <= Int.max / 8 else {
            throw KaitoError.limitExceeded("RAR4 compressed input size")
        }
        let dictionaryCount = try Checked.toInt(dictionarySize)
        guard dictionaryCount > 0,
              dictionaryCount & (dictionaryCount - 1) == 0 else {
            throw KaitoError.malformed("RAR4 dictionary is not a power of two")
        }

        let inputAllocationCount = compressedCount + Self.sentinelByteCount
        guard let inputRaw = malloc(inputAllocationCount) else {
            throw KaitoError.limitExceeded("unable to allocate RAR4 compressed input")
        }
        guard let windowRaw = malloc(dictionaryCount) else {
            free(inputRaw)
            throw KaitoError.limitExceeded("unable to allocate RAR4 dictionary")
        }

        self.inputCount = compressedCount
        self.expectedSize = uncompressedSize
        self.windowSize = dictionaryCount
        self.windowMask = dictionaryCount - 1
        self.input = inputRaw.bindMemory(to: UInt8.self, capacity: inputAllocationCount)
        self.window = windowRaw.bindMemory(to: UInt8.self, capacity: dictionaryCount)
        self.input.initialize(
            repeating: 0,
            count: inputAllocationCount
        )
        self.window.initialize(repeating: 0, count: dictionaryCount)

        do {
            var filled = 0
            while filled < compressedCount {
                let destination = UnsafeMutableRawBufferPointer(
                    start: input.advanced(by: filled),
                    count: compressedCount - filled
                )
                let count = try source.read(
                    into: destination,
                    at: try Checked.add(offset, UInt64(filled))
                )
                guard count > 0, count <= compressedCount - filled else {
                    throw KaitoError.truncated
                }
                filled += count
            }
        } catch {
            // Stored properties are fully initialized before this read loop,
            // so Swift invokes `deinit` when the initializer throws.  Cleanup
            // here as well would release both raw buffers twice.
            throw error
        }
    }

    deinit {
        input.deinitialize(count: inputCount + Self.sentinelByteCount)
        free(UnsafeMutableRawPointer(input))
        window.deinitialize(count: windowSize)
        free(UnsafeMutableRawPointer(window))
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty else { return 0 }
        if let terminalFailure {
            throw error(for: terminalFailure)
        }
        guard !finished else { return 0 }
        guard let destination = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            return 0
        }

        var bits = RAR29RawBitCursor(
            bytes: UnsafePointer(input),
            byteCount: inputCount,
            bitOffset: bitOffset
        )
        if needsInitialTables {
            do {
                try readTables(bits: &bits)
                needsInitialTables = false
            } catch let kaito as KaitoError {
                bitOffset = bits.bitOffset
                terminalFailure = decodeFailure(from: kaito)
                throw kaito
            } catch {
                bitOffset = bits.bitOffset
                let failure = DecodeFailure.malformed("RAR4 table build failed")
                terminalFailure = failure
                throw self.error(for: failure)
            }
        }

        // All frequently touched decoder state is local for the symbol loop.
        var outputCount = 0
        var outputPosition = produced
        var repeat0 = oldOffset0
        var repeat1 = oldOffset1
        var repeat2 = oldOffset2
        var repeat3 = oldOffset3
        var recentOffset = lastOffset
        var recentLength = lastLength
        var lowOffset = lastLowOffset
        var lowRepeats = lowOffsetRepeatCount
        var matchDistance = pendingDistance
        var matchRemaining = pendingLength
        var reachedEnd = false
        var failure: DecodeFailure?

        while outputCount < buffer.count, !reachedEnd, failure == nil {
            if matchRemaining > 0 {
                copyMatchChunk(
                    distance: matchDistance,
                    remaining: &matchRemaining,
                    output: destination,
                    outputCount: &outputCount,
                    outputCapacity: buffer.count,
                    outputPosition: &outputPosition
                )
                continue
            }

            let symbol = mainTable.decode(bits: &bits)
            if symbol < 0 {
                failure = .malformed("invalid RAR4 main Huffman code")
                break
            }
            if symbol < 256 {
                guard outputPosition < expectedSize else {
                    failure = .malformed("RAR4 output exceeds its declared size")
                    break
                }
                let ringOffset = Int(outputPosition) & windowMask
                let byte = UInt8(truncatingIfNeeded: symbol)
                window[ringOffset] = byte
                destination[outputCount] = byte
                outputCount += 1
                outputPosition += 1
                continue
            }

            var distance = 0
            var length = 0
            switch symbol {
            case 256:
                if bits.read(1) == 0 {
                    _ = bits.read(1) // next-file table policy, for solid state
                    reachedEnd = true
                } else {
                    do {
                        try readTables(bits: &bits)
                    } catch let kaito as KaitoError {
                        failure = decodeFailure(from: kaito)
                    } catch {
                        failure = .malformed("RAR4 table rebuild failed")
                    }
                }
                continue

            case 257:
                // The descriptor/program grammar is not connected yet, so we
                // cannot honestly classify this token as a stock program or a
                // custom VM program. `requireRAR3Program` uses the narrower
                // custom-VM error once a program has actually been parsed.
                failure = .unsupported("RAR3 filter block decoding")
                continue

            case 258:
                guard recentLength > 0 else { continue }
                distance = recentOffset
                length = recentLength

            case 259...262:
                let selected = symbol - 259
                switch selected {
                case 0:
                    distance = repeat0
                case 1:
                    distance = repeat1
                    (repeat0, repeat1) = (repeat1, repeat0)
                case 2:
                    distance = repeat2
                    (repeat0, repeat1, repeat2) = (repeat2, repeat0, repeat1)
                default:
                    distance = repeat3
                    (repeat0, repeat1, repeat2, repeat3) = (
                        repeat3, repeat0, repeat1, repeat2
                    )
                }
                let lengthSlot = lengthTable.decode(bits: &bits)
                guard Self.lengthBases.indices.contains(lengthSlot) else {
                    failure = .malformed("invalid RAR4 repeat length slot")
                    continue
                }
                length = Self.lengthBases[lengthSlot] + 2
                length += Int(bits.read(Self.lengthBits[lengthSlot]))

            case 263...270:
                let shortSlot = symbol - 263
                distance = Self.shortBases[shortSlot] + 1
                distance += Int(bits.read(Self.shortBits[shortSlot]))
                length = 2
                repeat3 = repeat2
                repeat2 = repeat1
                repeat1 = repeat0
                repeat0 = distance

            default:
                let lengthSlot = symbol - 271
                guard Self.lengthBases.indices.contains(lengthSlot) else {
                    failure = .malformed("invalid RAR4 match length slot")
                    continue
                }
                length = Self.lengthBases[lengthSlot] + 3
                length += Int(bits.read(Self.lengthBits[lengthSlot]))

                let distanceSlot = distanceTable.decode(bits: &bits)
                guard Self.distanceBases.indices.contains(distanceSlot) else {
                    failure = .malformed("invalid RAR4 distance slot")
                    continue
                }
                distance = Self.distanceBases[distanceSlot] + 1
                let extraBits = Self.distanceBits[distanceSlot]
                if extraBits > 0 {
                    if distanceSlot > 9 {
                        distance += Int(bits.read(extraBits - 4)) << 4
                        if lowRepeats > 0 {
                            lowRepeats -= 1
                            distance += lowOffset
                        } else {
                            let lowSymbol = lowDistanceTable.decode(bits: &bits)
                            guard (0...16).contains(lowSymbol) else {
                                failure = .malformed("invalid RAR4 low-distance slot")
                                continue
                            }
                            if lowSymbol == 16 {
                                lowRepeats = 15
                                distance += lowOffset
                            } else {
                                lowOffset = lowSymbol
                                distance += lowSymbol
                            }
                        }
                    } else {
                        distance += Int(bits.read(extraBits))
                    }
                }
                if distance >= 0x2_000 { length += 1 }
                if distance >= 0x4_0000 { length += 1 }
                repeat3 = repeat2
                repeat2 = repeat1
                repeat1 = repeat0
                repeat0 = distance
            }

            guard failure == nil else { continue }
            guard distance > 0,
                  distance <= windowSize,
                  UInt64(distance) <= min(outputPosition, UInt64(windowSize)) else {
                failure = .malformed("RAR4 match distance is outside the window")
                continue
            }
            guard length > 0,
                  outputPosition <= expectedSize,
                  UInt64(length) <= expectedSize - outputPosition else {
                failure = .malformed("RAR4 match exceeds the declared output size")
                continue
            }
            recentOffset = distance
            recentLength = length
            matchDistance = distance
            matchRemaining = length
        }

        bitOffset = bits.bitOffset
        produced = outputPosition
        oldOffset0 = repeat0
        oldOffset1 = repeat1
        oldOffset2 = repeat2
        oldOffset3 = repeat3
        lastOffset = recentOffset
        lastLength = recentLength
        lastLowOffset = lowOffset
        lowOffsetRepeatCount = lowRepeats
        pendingDistance = matchDistance
        pendingLength = matchRemaining

        if bits.overrun, failure == nil {
            failure = .truncated
        }
        if reachedEnd {
            guard outputPosition == expectedSize, matchRemaining == 0 else {
                failure = .truncated
                terminalFailure = failure
                throw KaitoError.truncated
            }
            finished = true
        }
        if let failure {
            terminalFailure = failure
            throw error(for: failure)
        }
        return outputCount
    }

    private func readTables(bits: inout RAR29RawBitCursor) throws {
        bits.alignToByte()
        guard bits.read(1) == 0 else {
            throw KaitoError.unsupportedMethod("RAR4 PPMd block")
        }
        lastLowOffset = 0
        lowOffsetRepeatCount = 0
        let keepPrevious = bits.read(1) != 0
        if !keepPrevious {
            _ = previousLengths.withUnsafeMutableBytes { raw in
                raw.initializeMemory(as: UInt8.self, repeating: 0)
            }
        }

        var levelLengths = [UInt8](repeating: 0, count: 20)
        var levelIndex = 0
        while levelIndex < levelLengths.count {
            let value = UInt8(truncatingIfNeeded: bits.read(4))
            if value == 15 {
                let zeroCount = Int(bits.read(4))
                if zeroCount != 0 {
                    let run = zeroCount + 2
                    guard run <= levelLengths.count - levelIndex else {
                        throw KaitoError.malformed(
                            "RAR4 level-table run exceeds its bounds"
                        )
                    }
                    levelIndex += run
                    continue
                }
            }
            levelLengths[levelIndex] = value
            levelIndex += 1
        }
        guard !bits.overrun else { throw KaitoError.truncated }

        try levelTable.build(levelLengths[...])
        var index = 0
        while index < previousLengths.count {
            let symbol = levelTable.decode(bits: &bits)
            guard symbol >= 0 else {
                throw bits.overrun
                    ? KaitoError.truncated
                    : KaitoError.malformed("invalid RAR4 level Huffman code")
            }
            switch symbol {
            case 0...15:
                previousLengths[index] = UInt8(
                    (Int(previousLengths[index]) + symbol) & 0x0f
                )
                index += 1
            case 16, 17:
                guard index > 0 else {
                    throw KaitoError.malformed(
                        "RAR4 length repeat appears before the first value"
                    )
                }
                let run = symbol == 16
                    ? Int(bits.read(3)) + 3
                    : Int(bits.read(7)) + 11
                guard run <= previousLengths.count - index else {
                    throw KaitoError.malformed(
                        "RAR4 length repeat exceeds the table"
                    )
                }
                let repeated = previousLengths[index - 1]
                for destination in index..<(index + run) {
                    previousLengths[destination] = repeated
                }
                index += run
            case 18, 19:
                let run = symbol == 18
                    ? Int(bits.read(3)) + 3
                    : Int(bits.read(7)) + 11
                guard run <= previousLengths.count - index else {
                    throw KaitoError.malformed(
                        "RAR4 zero run exceeds the length table"
                    )
                }
                previousLengths.withUnsafeMutableBufferPointer { lengths in
                    lengths.baseAddress?.advanced(by: index).update(
                        repeating: 0,
                        count: run
                    )
                }
                index += run
            default:
                throw KaitoError.malformed("invalid RAR4 level symbol")
            }
        }
        guard !bits.overrun else { throw KaitoError.truncated }

        let mainEnd = Self.mainSymbolCount
        let distanceEnd = mainEnd + Self.distanceSymbolCount
        let lowEnd = distanceEnd + Self.lowDistanceSymbolCount
        try mainTable.build(previousLengths[0..<mainEnd])
        try distanceTable.build(previousLengths[mainEnd..<distanceEnd])
        try lowDistanceTable.build(previousLengths[distanceEnd..<lowEnd])
        try lengthTable.build(previousLengths[lowEnd..<Self.combinedLengthCount])
    }

    private func copyMatchChunk(
        distance: Int,
        remaining: inout Int,
        output: UnsafeMutablePointer<UInt8>,
        outputCount: inout Int,
        outputCapacity: Int,
        outputPosition: inout UInt64
    ) {
        var count = min(remaining, outputCapacity - outputCount)
        guard count > 0 else { return }

        // A chunk no longer than its distance has no intra-chunk dependency.
        // If its source is contiguous in the ring, stage it directly through
        // the caller buffer and then mirror that plaintext into the window.
        let destinationRing = Int(outputPosition) & windowMask
        let sourceRing = (destinationRing - distance) & windowMask
        count = min(count, distance)
        if sourceRing + count <= windowSize {
            output.advanced(by: outputCount).update(
                from: window.advanced(by: sourceRing),
                count: count
            )
            let firstWindowPart = min(count, windowSize - destinationRing)
            window.advanced(by: destinationRing).update(
                from: output.advanced(by: outputCount),
                count: firstWindowPart
            )
            if firstWindowPart < count {
                window.update(
                    from: output.advanced(by: outputCount + firstWindowPart),
                    count: count - firstWindowPart
                )
            }
            outputCount += count
            outputPosition += UInt64(count)
            remaining -= count
            return
        }

        // Wrapped sources and true LZ overlap are copied in production order.
        for _ in 0..<count {
            let destinationOffset = Int(outputPosition) & windowMask
            let sourceOffset = (destinationOffset - distance) & windowMask
            let byte = window[sourceOffset]
            window[destinationOffset] = byte
            output[outputCount] = byte
            outputCount += 1
            outputPosition += 1
            remaining -= 1
        }
    }

    private func decodeFailure(from error: KaitoError) -> DecodeFailure {
        switch error {
        case .truncated:
            .truncated
        case let .unsupportedMethod(reason):
            .unsupported(reason)
        case let .malformed(reason):
            .malformed(reason)
        default:
            .malformed("RAR4 table rebuild failed")
        }
    }

    private func error(for failure: DecodeFailure) -> KaitoError {
        switch failure {
        case .truncated:
            .truncated
        case let .malformed(reason):
            .malformed(reason)
        case let .unsupported(reason):
            .unsupportedMethod(reason)
        }
    }
}

/// Sentinel-backed, MSB-first cursor. `peek` never marks a logical overread,
/// because a short Huffman code can be valid even when fewer than 15 real bits
/// remain; only consuming beyond the physical bit count sets `overrun`.
private struct RAR29RawBitCursor {
    let bytes: UnsafePointer<UInt8>
    let byteCount: Int
    var bitOffset: Int
    var overrun = false

    mutating func alignToByte() {
        let remainder = bitOffset & 7
        if remainder != 0 {
            consume(8 - remainder)
        }
    }

    func peek(_ count: Int) -> UInt32 {
        guard count > 0 else { return 0 }
        let boundedOffset = min(max(bitOffset, 0), byteCount * 8)
        let byteOffset = boundedOffset >> 3
        let intraByte = boundedOffset & 7
        let word = UInt64(bytes[byteOffset]) << 32
            | UInt64(bytes[byteOffset + 1]) << 24
            | UInt64(bytes[byteOffset + 2]) << 16
            | UInt64(bytes[byteOffset + 3]) << 8
            | UInt64(bytes[byteOffset + 4])
        let shift = 40 - intraByte - count
        let mask = count == 32 ? UInt64(UInt32.max) : (UInt64(1) << count) - 1
        return UInt32(truncatingIfNeeded: word >> shift & mask)
    }

    mutating func read(_ count: Int) -> UInt32 {
        let value = peek(count)
        consume(count)
        return value
    }

    mutating func consume(_ count: Int) {
        guard count >= 0,
              bitOffset <= Int.max - count else {
            overrun = true
            bitOffset = Int.max
            return
        }
        bitOffset += count
        if bitOffset > byteCount * 8 {
            overrun = true
        }
    }
}

/// Full 15-bit canonical lookup. A record stores `(bitCount, symbol + 1)`;
/// zero therefore remains an invalid-prefix sentinel for incomplete trees.
private final class RAR29HuffmanTable {
    private static let maximumBits = 15
    private static let lookupCount = 1 << maximumBits
    private let lookup: UnsafeMutablePointer<UInt32>

    init() {
        lookup = .allocate(capacity: Self.lookupCount)
        lookup.initialize(repeating: 0, count: Self.lookupCount)
    }

    deinit {
        lookup.deinitialize(count: Self.lookupCount)
        lookup.deallocate()
    }

    func build(_ lengths: ArraySlice<UInt8>) throws {
        lookup.update(repeating: 0, count: Self.lookupCount)
        var counts = [Int](repeating: 0, count: Self.maximumBits + 1)
        var symbolCount = 0
        for length in lengths {
            guard Int(length) <= Self.maximumBits else {
                throw KaitoError.malformed("RAR4 Huffman length exceeds 15")
            }
            if length != 0 {
                counts[Int(length)] += 1
                symbolCount += 1
            }
        }
        guard symbolCount > 0 else {
            throw KaitoError.malformed("RAR4 Huffman table is empty")
        }

        var available = 1
        for bitCount in 1...Self.maximumBits {
            available = available * 2 - counts[bitCount]
            guard available >= 0 else {
                throw KaitoError.malformed("oversubscribed RAR4 Huffman table")
            }
        }

        var nextCode = [Int](repeating: 0, count: Self.maximumBits + 1)
        var code = 0
        for bitCount in 1...Self.maximumBits {
            code = (code + counts[bitCount - 1]) << 1
            nextCode[bitCount] = code
        }

        for (relativeSymbol, rawLength) in lengths.enumerated() {
            let bitCount = Int(rawLength)
            guard bitCount > 0 else { continue }
            let canonicalCode = nextCode[bitCount]
            nextCode[bitCount] += 1
            guard canonicalCode < 1 << bitCount else {
                throw KaitoError.malformed("invalid RAR4 canonical Huffman code")
            }
            let first = canonicalCode << (Self.maximumBits - bitCount)
            let repetitions = 1 << (Self.maximumBits - bitCount)
            let record = UInt32(bitCount) << 16 | UInt32(relativeSymbol + 1)
            lookup.advanced(by: first).update(repeating: record, count: repetitions)
        }
    }

    func decode(bits: inout RAR29RawBitCursor) -> Int {
        let record = lookup[Int(bits.peek(Self.maximumBits))]
        guard record != 0 else { return -1 }
        let bitCount = Int(record >> 16)
        bits.consume(bitCount)
        return Int(record & 0xffff) - 1
    }
}
