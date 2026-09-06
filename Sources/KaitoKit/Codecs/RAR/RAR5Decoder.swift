import Foundation

// Container reference: RARLab, "RAR 5.0 archive format",
// https://www.rarlab.com/technote.htm (accessed 2026-09-06).
// RARLab intentionally does not publish the compression grammar in that note.
// The compression grammar here follows the clean-room milestone requirements
// supplied by the repository owner and was verified with archives emitted by
// /opt/homebrew/bin/rar 7.23 as a black-box oracle. RARLab/UnRAR, 7-Zip,
// XADMaster, and The Unarchiver source code were not read or used.

/// Pull decoder for the version-zero RAR5 LZ stream.
///
/// Performance invariants:
/// - compressed bytes, the ring window and all Huffman lookup tables are raw
///   buffers allocated exactly once during initialization;
/// - the input has sixteen zero sentinel bytes, so a 64-bit unaligned peek is
///   physically safe even at a logical block boundary;
/// - logical bit limits, Huffman runs, distances and output limits are checked
///   at block/symbol boundaries, while literal and match-copy loops do not throw;
/// - non-wrapping, non-overlapping window copies use memcpy through copyMemory.
final class RAR5Decoder: Decompressor {
    private static let sentinelByteCount = 16
    private static let mainSymbolCount = 306
    private static let distanceSymbolCount = 64
    private static let lowDistanceSymbolCount = 16
    private static let repeatLengthSymbolCount = 44
    private static let bitLengthSymbolCount = 20
    private static let combinedTableCount = mainSymbolCount
        + distanceSymbolCount
        + lowDistanceSymbolCount
        + repeatLengthSymbolCount

    private static let lengthBase: [Int] = [
        0, 1, 2, 3, 4, 5, 6, 7,
        8, 10, 12, 14, 16, 20, 24, 28,
        32, 40, 48, 56, 64, 80, 96, 112,
        128, 160, 192, 224, 256, 320, 384, 448,
        512, 640, 768, 896, 1_024, 1_280, 1_536, 1_792,
        2_048, 2_560, 3_072, 3_584,
    ]
    private static let lengthBits: [Int] = [
        0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4,
        5, 5, 5, 5, 6, 6, 6, 6,
        7, 7, 7, 7, 8, 8, 8, 8,
        9, 9, 9, 9,
    ]

    private struct ScheduledFilter {
        let start: UInt64
        let length: Int
        let kind: RARStandardFilterKind
        let channels: Int

        var end: UInt64 { start + UInt64(length) }
    }

    private let input: UnsafeMutablePointer<UInt8>
    private let inputCount: Int
    private let window: UnsafeMutablePointer<UInt8>
    private let windowSize: Int
    private let windowMask: Int
    private let expectedSize: UInt64?
    private let maximumFilterCount: Int
    // Most compressed entries do not use a standard filter. Allocate these
    // large work areas once, on the first filter, instead of touching 8 MiB for
    // every entry in JPEG-heavy archives.
    private var filterInput: UnsafeMutablePointer<UInt8>?
    private var filterOutput: UnsafeMutablePointer<UInt8>?

    private let bitLengthTable = RAR5HuffmanTable()
    private let mainTable = RAR5HuffmanTable()
    private let distanceTable = RAR5HuffmanTable()
    private let lowDistanceTable = RAR5HuffmanTable()
    private let repeatLengthTable = RAR5HuffmanTable()
    private let oldCodeLengths: UnsafeMutablePointer<UInt8>
    private let codeLengths: UnsafeMutablePointer<UInt8>
    private let bitCodeLengths: UnsafeMutablePointer<UInt8>

    private var nextBlockOffset = 0
    private var bits: RAR5RawBitReader?
    private var currentBlockIsLast = false
    private var tablesWereRead = false
    private var rawFinished = false
    private var finished = false
    private var failure: KaitoError?

    private var produced: UInt64 = 0
    private var emitted: UInt64 = 0
    private var windowPosition = 0
    private var oldDistance0 = 0
    private var oldDistance1 = 0
    private var oldDistance2 = 0
    private var oldDistance3 = 0
    private var lastLength = 0
    private var pendingLength = 0
    private var pendingDistance = 0
    private var scheduledFilters: [ScheduledFilter] = []
    private var nextFilterIndex = 0
    private var filterFillCount = 0
    private var filterEmitCount = 0
    private var filterIsReady = false
    private var filterUsesSecondaryOutput = false

    var isFinished: Bool { finished && failure == nil }

    init(
        source: any ByteSource,
        offset: UInt64,
        compressedSize: UInt64,
        unpackedSize: UInt64?,
        dictionarySize: UInt64,
        limits: ReadLimits
    ) throws {
        if let unpackedSize {
            try Checked.size(unpackedSize, limit: limits.maxEntrySize)
        }
        try Checked.size(compressedSize, limit: limits.maxEntrySize)
        try Checked.size(dictionarySize, limit: limits.maxDictionarySize)
        guard dictionarySize >= 128 * 1_024,
              dictionarySize.nonzeroBitCount == 1 else {
            throw KaitoError.unsupportedMethod(
                "RAR5 decoder requires a power-of-two dictionary"
            )
        }

        let inputCount = try Checked.toInt(compressedSize)
        let allocationCount = try Checked.toInt(
            try Checked.add(compressedSize, UInt64(Self.sentinelByteCount))
        )
        let windowSize = try Checked.toInt(dictionarySize)
        guard let inputRaw = malloc(allocationCount) else {
            throw KaitoError.limitExceeded("unable to allocate RAR5 compressed input")
        }
        guard let windowRaw = malloc(windowSize) else {
            free(inputRaw)
            throw KaitoError.limitExceeded("unable to allocate RAR5 dictionary")
        }
        self.input = inputRaw.bindMemory(to: UInt8.self, capacity: allocationCount)
        self.inputCount = inputCount
        self.window = windowRaw.bindMemory(to: UInt8.self, capacity: windowSize)
        self.windowSize = windowSize
        self.windowMask = windowSize - 1
        self.expectedSize = unpackedSize
        self.maximumFilterCount = limits.maxMetadataRecordCount
        self.filterInput = nil
        self.filterOutput = nil
        self.oldCodeLengths = .allocate(capacity: Self.combinedTableCount)
        self.codeLengths = .allocate(capacity: Self.combinedTableCount)
        self.bitCodeLengths = .allocate(capacity: Self.bitLengthSymbolCount)

        input.initialize(repeating: 0, count: allocationCount)
        window.initialize(repeating: 0, count: windowSize)
        oldCodeLengths.initialize(repeating: 0, count: Self.combinedTableCount)
        codeLengths.initialize(repeating: 0, count: Self.combinedTableCount)
        bitCodeLengths.initialize(repeating: 0, count: Self.bitLengthSymbolCount)
        do {
            var filled = 0
            while filled < inputCount {
                let destination = UnsafeMutableRawBufferPointer(
                    start: input.advanced(by: filled),
                    count: inputCount - filled
                )
                let actual = try source.read(
                    into: destination,
                    at: try Checked.add(offset, UInt64(filled))
                )
                guard actual > 0, actual <= inputCount - filled else {
                    throw KaitoError.truncated
                }
                filled += actual
            }
            if inputCount == 0 {
                guard unpackedSize == 0 else { throw KaitoError.truncated }
                rawFinished = true
                finished = true
            } else {
                try readNextBlock()
            }
        } catch {
            // All stored properties have been initialized at this point, so a
            // throwing class initializer runs `deinit`.  Releasing these raw
            // buffers here as well would double-free them on malformed input.
            throw error
        }
    }

    deinit {
        input.deinitialize(count: inputCount + Self.sentinelByteCount)
        free(UnsafeMutableRawPointer(input))
        window.deinitialize(count: windowSize)
        free(UnsafeMutableRawPointer(window))
        if let filterInput { free(UnsafeMutableRawPointer(filterInput)) }
        if let filterOutput { free(UnsafeMutableRawPointer(filterOutput)) }
        oldCodeLengths.deallocate()
        codeLengths.deallocate()
        bitCodeLengths.deallocate()
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if let failure { throw failure }
        guard !buffer.isEmpty, !finished else { return 0 }
        guard let output = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            return 0
        }

        var written = 0
        while written < buffer.count, !finished {
            if nextFilterIndex < scheduledFilters.count {
                let filter = scheduledFilters[nextFilterIndex]
                guard emitted <= filter.start else {
                    failure = .malformed("RAR5 filter starts behind emitted output")
                    break
                }

                if emitted < filter.start {
                    guard emitted == produced else {
                        failure = .malformed("RAR5 raw and emitted positions diverged")
                        break
                    }
                    let distanceToFilter = filter.start - emitted
                    let capacity = min(
                        buffer.count - written,
                        Int(min(distanceToFilter, UInt64(Int.max)))
                    )
                    let count = decodeRaw(
                        into: output.advanced(by: written),
                        capacity: capacity,
                        stopAtFilter: true
                    )
                    emitted += UInt64(count)
                    written += count
                    if failure != nil { break }
                    continue
                }

                if !filterIsReady {
                    guard ensureFilterBuffers(),
                          let filterInput else { break }
                    guard produced >= filter.start else {
                        failure = .malformed("RAR5 filter begins beyond raw output")
                        break
                    }
                    let needed = filter.length - filterFillCount
                    if needed > 0 {
                        let count = decodeRaw(
                            into: filterInput.advanced(by: filterFillCount),
                            capacity: needed,
                            stopAtFilter: false
                        )
                        filterFillCount += count
                        if failure != nil { break }
                        if filterFillCount < filter.length {
                            if rawFinished {
                                failure = .truncated
                                break
                            }
                            guard count > 0 else {
                                failure = .malformed("RAR5 filter input made no progress")
                                break
                            }
                            continue
                        }
                    }
                    do {
                        try prepare(filter: filter)
                    } catch let error as KaitoError {
                        failure = error
                        break
                    } catch {
                        failure = .malformed("RAR5 standard filter failed")
                        break
                    }
                }

                let available = filter.length - filterEmitCount
                let count = min(available, buffer.count - written)
                guard let filterInput else {
                    failure = .malformed("RAR5 filter input buffer is unavailable")
                    break
                }
                let source: UnsafeMutablePointer<UInt8>
                if filterUsesSecondaryOutput {
                    guard let filterOutput else {
                        failure = .malformed("RAR5 filter output buffer is unavailable")
                        break
                    }
                    source = filterOutput
                } else {
                    source = filterInput
                }
                UnsafeMutableRawPointer(output.advanced(by: written)).copyMemory(
                    from: UnsafeRawPointer(source.advanced(by: filterEmitCount)),
                    byteCount: count
                )
                filterEmitCount += count
                emitted += UInt64(count)
                written += count
                if filterEmitCount == filter.length {
                    nextFilterIndex += 1
                    filterFillCount = 0
                    filterEmitCount = 0
                    filterIsReady = false
                    filterUsesSecondaryOutput = false
                }
                continue
            }

            if rawFinished {
                guard emitted == produced else {
                    failure = .malformed("RAR5 output ended with unflushed raw bytes")
                    break
                }
                finished = true
                break
            }

            let count = decodeRaw(
                into: output.advanced(by: written),
                capacity: buffer.count - written,
                stopAtFilter: true
            )
            emitted += UInt64(count)
            written += count
            if failure != nil { break }
            if count == 0, !rawFinished, nextFilterIndex >= scheduledFilters.count {
                failure = .malformed("RAR5 decoder made no progress")
                break
            }
        }

        if let failure { throw failure }
        return written
    }

    /// Decodes raw LZ bytes into a caller-owned bounded range. When requested,
    /// decoding stops exactly at the first scheduled filter boundary.
    private func decodeRaw(
        into output: UnsafeMutablePointer<UInt8>,
        capacity: Int,
        stopAtFilter: Bool
    ) -> Int {
        guard capacity > 0, !rawFinished, failure == nil else { return 0 }
        var written = 0

        while written < capacity, !rawFinished, failure == nil {
            var available = capacity - written
            if stopAtFilter, nextFilterIndex < scheduledFilters.count {
                let start = scheduledFilters[nextFilterIndex].start
                guard start >= produced else {
                    failure = .malformed("RAR5 filter boundary was passed")
                    break
                }
                if start == produced { break }
                available = min(available, Int(min(start - produced, UInt64(Int.max))))
            }

            if pendingLength > 0 {
                let amount = min(pendingLength, available)
                copyMatch(
                    distance: pendingDistance,
                    count: amount,
                    output: output.advanced(by: written)
                )
                pendingLength -= amount
                written += amount
                continue
            }

            guard var bitReader = bits else {
                failure = .malformed("RAR5 decoder has no active block")
                break
            }
            if bitReader.isAtEnd {
                bits = bitReader
                if currentBlockIsLast {
                    if let expectedSize, produced != expectedSize {
                        failure = .truncated
                    } else {
                        rawFinished = true
                    }
                    break
                }
                do {
                    try readNextBlock()
                } catch let error as KaitoError {
                    failure = error
                } catch {
                    failure = .malformed("RAR5 block transition failed")
                }
                continue
            }

            guard let symbol = mainTable.decode(from: &bitReader) else {
                bits = bitReader
                failure = .malformed("RAR5 main Huffman code runs past its block")
                break
            }
            bits = bitReader

            if symbol < 256 {
                guard outputIsAvailable(1) else {
                    failure = .malformed("RAR5 output exceeds its declared size")
                    break
                }
                let byte = UInt8(symbol)
                output[written] = byte
                window[windowPosition] = byte
                windowPosition = (windowPosition + 1) & windowMask
                produced += 1
                written += 1
                continue
            }

            switch symbol {
            case 256:
                guard var localBits = bits,
                      let filter = readFilter(from: &localBits) else {
                    if failure == nil {
                        failure = .malformed("RAR5 filter data runs past its block")
                    }
                    break
                }
                bits = localBits
                scheduledFilters.append(filter)

            case 257:
                guard lastLength > 0,
                      validateMatch(distance: oldDistance0, length: lastLength) else {
                    failure = .malformed("RAR5 invalid last-match repetition")
                    break
                }
                pendingDistance = oldDistance0
                pendingLength = lastLength

            case 258...261:
                let distanceIndex = symbol - 258
                let distance = distance(at: distanceIndex)
                rotateDistanceToFront(distanceIndex)
                guard var localBits = bits,
                      let length = decodeLength(using: repeatLengthTable, bits: &localBits) else {
                    failure = .malformed("RAR5 repeat length runs past its block")
                    break
                }
                bits = localBits
                guard validateMatch(distance: distance, length: length) else {
                    failure = .malformed("RAR5 invalid repeated-distance match")
                    break
                }
                lastLength = length
                pendingDistance = distance
                pendingLength = length

            case 262..<Self.mainSymbolCount:
                guard var localBits = bits,
                      var length = decodeLengthSlot(symbol - 262, bits: &localBits),
                      let distanceSlot = distanceTable.decode(from: &localBits),
                      let distance = decodeDistance(slot: distanceSlot, bits: &localBits) else {
                    failure = .malformed("RAR5 match runs past its block")
                    break
                }
                if distance > 0x100 { length += 1 }
                if distance > 0x2_000 { length += 1 }
                if distance > 0x4_0000 { length += 1 }
                guard validateMatch(distance: distance, length: length) else {
                    let describedExpectedSize = expectedSize.map(String.init) ?? "unknown"
                    failure = .malformed(
                        "RAR5 invalid LZ match at output \(produced): distance \(distance), length \(length), window \(windowSize), expected \(describedExpectedSize)"
                    )
                    break
                }
                bits = localBits
                pushDistance(distance)
                lastLength = length
                pendingDistance = distance
                pendingLength = length

            default:
                failure = .malformed("RAR5 main Huffman symbol is out of range")
            }
            if failure != nil { break }
        }

        return written
    }

    private func readFilter(from bits: inout RAR5RawBitReader) -> ScheduledFilter? {
        guard scheduledFilters.count < maximumFilterCount else {
            failure = .limitExceeded("RAR5 filter count")
            return nil
        }
        guard let relativeStart = readFilterInteger(from: &bits),
              let lengthValue = readFilterInteger(from: &bits),
              lengthValue > 0,
              lengthValue <= RARStandardFilters.rar5MaximumBlockSize,
              let type = bits.read(3),
              let kind = RARStandardFilterKind(rawValue: UInt8(type)) else {
            failure = .malformed("RAR5 filter parameters are invalid")
            return nil
        }
        guard kind == .delta || kind == .e8 || kind == .e8e9 || kind == .arm else {
            failure = .unsupportedMethod("RAR5 filter type \(type)")
            return nil
        }
        let channels: Int
        if kind == .delta {
            guard let storedChannels = bits.read(5) else { return nil }
            channels = storedChannels + 1
        } else {
            channels = 1
        }

        let (start, startOverflow) = produced.addingReportingOverflow(
            UInt64(relativeStart)
        )
        let (end, endOverflow) = start.addingReportingOverflow(UInt64(lengthValue))
        guard !startOverflow, !endOverflow else {
            failure = .malformed("RAR5 filter range overflows")
            return nil
        }
        if let expectedSize, end > expectedSize {
            failure = .malformed("RAR5 filter range exceeds output")
            return nil
        }
        if let previous = scheduledFilters.last, start < previous.end {
            failure = .malformed("RAR5 filter ranges overlap or are out of order")
            return nil
        }
        return ScheduledFilter(
            start: start,
            length: lengthValue,
            kind: kind,
            channels: channels
        )
    }

    private func readFilterInteger(from bits: inout RAR5RawBitReader) -> Int? {
        guard let storedByteCount = bits.read(2) else { return nil }
        let byteCount = storedByteCount + 1
        var value = 0
        for byteIndex in 0..<byteCount {
            guard let byte = bits.read(8) else { return nil }
            value |= byte << (byteIndex * 8)
        }
        return value
    }

    private func prepare(filter: ScheduledFilter) throws {
        guard let filterInput, let filterOutput else {
            throw KaitoError.malformed("RAR5 filter work buffers are unavailable")
        }
        let input = UnsafeMutableRawBufferPointer(
            start: filterInput,
            count: filter.length
        )
        switch filter.kind {
        case .delta:
            try RARStandardFilters.decodeDelta(
                input: UnsafeRawBufferPointer(input),
                output: UnsafeMutableRawBufferPointer(
                    start: filterOutput,
                    count: filter.length
                ),
                channels: filter.channels
            )
            filterUsesSecondaryOutput = true
        case .e8:
            try RARStandardFilters.e8(
                input,
                fileOffset: filter.start,
                includeE9: false,
                addressMode: .rar5
            )
        case .e8e9:
            try RARStandardFilters.e8(
                input,
                fileOffset: filter.start,
                includeE9: true,
                addressMode: .rar5
            )
        case .arm:
            try RARStandardFilters.arm(input, fileOffset: filter.start)
        case .audio, .rgb, .itanium:
            throw KaitoError.unsupportedMethod("RAR5 filter \(filter.kind)")
        }
        filterIsReady = true
    }

    private func ensureFilterBuffers() -> Bool {
        if filterInput != nil, filterOutput != nil { return true }
        let capacity = RARStandardFilters.rar5MaximumBlockSize
        guard let inputRaw = malloc(capacity) else {
            failure = .limitExceeded("unable to allocate RAR5 filter input")
            return false
        }
        guard let outputRaw = malloc(capacity) else {
            free(inputRaw)
            failure = .limitExceeded("unable to allocate RAR5 filter output")
            return false
        }
        // Every byte read from either work area is overwritten first, so no
        // eager zero fill is necessary for this trivial element type.
        filterInput = inputRaw.bindMemory(to: UInt8.self, capacity: capacity)
        filterOutput = outputRaw.bindMemory(to: UInt8.self, capacity: capacity)
        return true
    }

    private func readNextBlock() throws {
        guard nextBlockOffset < inputCount else { throw KaitoError.truncated }
        let start = nextBlockOffset
        guard inputCount - start >= 3 else { throw KaitoError.truncated }
        let flags = input[start]
        let recordedChecksum = input[start + 1]
        let sizeByteCount = Int((flags >> 3) & 0x03) + 1
        guard (1...3).contains(sizeByteCount),
              inputCount - start >= 2 + sizeByteCount else {
            throw KaitoError.malformed("RAR5 compressed block has an invalid size field")
        }

        var checksum: UInt8 = 0x5a ^ flags
        var blockSize = 0
        for index in 0..<sizeByteCount {
            let byte = input[start + 2 + index]
            checksum ^= byte
            blockSize |= Int(byte) << (index * 8)
        }
        guard checksum == recordedChecksum else {
            throw KaitoError.malformed("RAR5 compressed block checksum mismatch")
        }
        guard blockSize > 0 else {
            throw KaitoError.malformed("RAR5 compressed block size is zero")
        }
        let payloadOffset = start + 2 + sizeByteCount
        let (end, overflow) = payloadOffset.addingReportingOverflow(blockSize)
        guard !overflow, end <= inputCount, end > start else { throw KaitoError.truncated }
        // Low three flag bits store valid bits in the final byte minus one.
        let unusedBits = 7 - Int(flags & 0x07)
        let (physicalBits, bitOverflow) = blockSize.multipliedReportingOverflow(by: 8)
        guard !bitOverflow, unusedBits < 8, physicalBits >= unusedBits else {
            throw KaitoError.malformed("RAR5 compressed block has invalid bit padding")
        }

        var reader = RAR5RawBitReader(
            pointer: UnsafePointer(input.advanced(by: payloadOffset)),
            bitLimit: physicalBits - unusedBits
        )
        currentBlockIsLast = flags & 0x40 != 0
        nextBlockOffset = end
        if flags & 0x80 != 0 {
            try readTables(from: &reader)
            tablesWereRead = true
        } else if !tablesWereRead {
            throw KaitoError.malformed("RAR5 first compressed block has no Huffman tables")
        }
        bits = reader
    }

    private func readTables(from bits: inout RAR5RawBitReader) throws {
        bitCodeLengths.update(repeating: 0, count: Self.bitLengthSymbolCount)
        // RAR5 table descriptions are self-contained. A block without the
        // table flag reuses the last tables, but a present description does
        // not delta its lengths against the preceding block.
        oldCodeLengths.update(repeating: 0, count: Self.combinedTableCount)
        var index = 0
        while index < Self.bitLengthSymbolCount {
            guard let length = bits.read(4) else { throw KaitoError.truncated }
            if length != 15 {
                bitCodeLengths[index] = UInt8(length)
                index += 1
                continue
            }
            guard let zeros = bits.read(4) else { throw KaitoError.truncated }
            if zeros == 0 {
                bitCodeLengths[index] = 15
                index += 1
            } else {
                let count = zeros + 2
                guard count <= Self.bitLengthSymbolCount - index else {
                    throw KaitoError.malformed("RAR5 bit-length run exceeds its table")
                }
                bitCodeLengths.advanced(by: index).update(repeating: 0, count: count)
                index += count
            }
        }
        try bitLengthTable.build(
            lengths: UnsafePointer(bitCodeLengths),
            count: Self.bitLengthSymbolCount,
            requireSymbol: true
        )

        index = 0
        while index < Self.combinedTableCount {
            guard let symbol = bitLengthTable.decode(from: &bits) else {
                throw KaitoError.malformed("RAR5 code-length stream is invalid")
            }
            switch symbol {
            case 0...15:
                codeLengths[index] = UInt8(symbol)
                index += 1

            case 16, 17:
                guard index > 0 else {
                    throw KaitoError.malformed("RAR5 repeat precedes a code length")
                }
                let extraBitCount = symbol == 16 ? 3 : 7
                let base = symbol == 16 ? 3 : 11
                guard let extra = bits.read(extraBitCount) else { throw KaitoError.truncated }
                let count = base + extra
                guard count <= Self.combinedTableCount - index else {
                    throw KaitoError.malformed("RAR5 repeated length exceeds its tables")
                }
                codeLengths.advanced(by: index).update(
                    repeating: codeLengths[index - 1],
                    count: count
                )
                index += count

            case 18, 19:
                let extraBitCount = symbol == 18 ? 3 : 7
                let base = symbol == 18 ? 3 : 11
                guard let extra = bits.read(extraBitCount) else { throw KaitoError.truncated }
                let count = base + extra
                guard count <= Self.combinedTableCount - index else {
                    throw KaitoError.malformed("RAR5 zero run exceeds its tables")
                }
                codeLengths.advanced(by: index).update(repeating: 0, count: count)
                index += count

            default:
                throw KaitoError.malformed("RAR5 code-length symbol is out of range")
            }
        }

        try mainTable.build(
            lengths: UnsafePointer(codeLengths),
            count: Self.mainSymbolCount,
            requireSymbol: true
        )
        try distanceTable.build(
            lengths: UnsafePointer(codeLengths.advanced(by: Self.mainSymbolCount)),
            count: Self.distanceSymbolCount,
            requireSymbol: false
        )
        try lowDistanceTable.build(
            lengths: UnsafePointer(codeLengths.advanced(
                by: Self.mainSymbolCount + Self.distanceSymbolCount
            )),
            count: Self.lowDistanceSymbolCount,
            requireSymbol: false
        )
        try repeatLengthTable.build(
            lengths: UnsafePointer(codeLengths.advanced(
                by: Self.mainSymbolCount
                    + Self.distanceSymbolCount
                    + Self.lowDistanceSymbolCount
            )),
            count: Self.repeatLengthSymbolCount,
            requireSymbol: false
        )
        oldCodeLengths.update(
            from: UnsafePointer(codeLengths),
            count: Self.combinedTableCount
        )
    }

    private func decodeLength(
        using table: RAR5HuffmanTable,
        bits: inout RAR5RawBitReader
    ) -> Int? {
        guard let slot = table.decode(from: &bits) else { return nil }
        return decodeLengthSlot(slot, bits: &bits)
    }

    private func decodeLengthSlot(
        _ slot: Int,
        bits: inout RAR5RawBitReader
    ) -> Int? {
        guard Self.lengthBase.indices.contains(slot) else { return nil }
        let bitCount = Self.lengthBits[slot]
        guard let extra = bits.read(bitCount) else { return nil }
        return Self.lengthBase[slot] + extra + 2
    }

    private func decodeDistance(
        slot: Int,
        bits: inout RAR5RawBitReader
    ) -> Int? {
        guard (0..<Self.distanceSymbolCount).contains(slot) else { return nil }
        if slot < 4 { return slot + 1 }

        let extraBitCount = slot / 2 - 1
        var distance = (2 | (slot & 1)) << extraBitCount
        if extraBitCount >= 4 {
            if extraBitCount > 4 {
                guard let high = bits.read(extraBitCount - 4) else { return nil }
                distance += high << 4
            }
            guard let low = lowDistanceTable.decode(from: &bits) else { return nil }
            distance += low
        } else {
            guard let extra = bits.read(extraBitCount) else { return nil }
            distance += extra
        }
        let (result, overflow) = distance.addingReportingOverflow(1)
        return overflow ? nil : result
    }

    private func outputIsAvailable(_ count: Int) -> Bool {
        guard count >= 0 else { return false }
        guard let expectedSize else { return UInt64(count) <= UInt64.max - produced }
        return UInt64(count) <= expectedSize - min(produced, expectedSize)
    }

    private func validateMatch(distance: Int, length: Int) -> Bool {
        guard distance > 0,
              distance <= windowSize,
              UInt64(distance) <= produced,
              length > 0,
              outputIsAvailable(length) else {
            return false
        }
        return true
    }

    private func copyMatch(
        distance: Int,
        count: Int,
        output: UnsafeMutablePointer<UInt8>
    ) {
        var remaining = count
        var outputPosition = 0
        while remaining > 0 {
            let sourceIndex = (windowPosition - distance) & windowMask
            let sourceContiguous = windowSize - sourceIndex
            let destinationContiguous = windowSize - windowPosition
            let amount = min(remaining, sourceContiguous, destinationContiguous)

            let physicalRangesDoNotOverlap = sourceIndex + amount <= windowPosition
                || windowPosition + amount <= sourceIndex
            if distance >= amount, physicalRangesDoNotOverlap {
                // The source and ring destination cannot overlap when the
                // backward distance is at least the contiguous copy size.
                output.advanced(by: outputPosition).update(
                    from: UnsafePointer(window.advanced(by: sourceIndex)),
                    count: amount
                )
                window.advanced(by: windowPosition).update(
                    from: UnsafePointer(window.advanced(by: sourceIndex)),
                    count: amount
                )
                windowPosition = (windowPosition + amount) & windowMask
                produced += UInt64(amount)
                outputPosition += amount
                remaining -= amount
            } else {
                // Overlapping LZ copies intentionally observe bytes written by
                // earlier iterations, so memcpy would be incorrect here.
                for _ in 0..<amount {
                    let byte = window[(windowPosition - distance) & windowMask]
                    output[outputPosition] = byte
                    window[windowPosition] = byte
                    windowPosition = (windowPosition + 1) & windowMask
                    produced += 1
                    outputPosition += 1
                    remaining -= 1
                }
            }
        }
    }

    private func distance(at index: Int) -> Int {
        switch index {
        case 0: oldDistance0
        case 1: oldDistance1
        case 2: oldDistance2
        default: oldDistance3
        }
    }

    private func rotateDistanceToFront(_ index: Int) {
        switch index {
        case 0:
            break
        case 1:
            let selected = oldDistance1
            oldDistance1 = oldDistance0
            oldDistance0 = selected
        case 2:
            let selected = oldDistance2
            oldDistance2 = oldDistance1
            oldDistance1 = oldDistance0
            oldDistance0 = selected
        default:
            let selected = oldDistance3
            oldDistance3 = oldDistance2
            oldDistance2 = oldDistance1
            oldDistance1 = oldDistance0
            oldDistance0 = selected
        }
    }

    private func pushDistance(_ distance: Int) {
        oldDistance3 = oldDistance2
        oldDistance2 = oldDistance1
        oldDistance1 = oldDistance0
        oldDistance0 = distance
    }
}

/// Raw MSB-first reader. The owner guarantees at least eight sentinel bytes
/// beyond the physical payload, while `bitLimit` is the authoritative boundary.
private struct RAR5RawBitReader {
    let pointer: UnsafePointer<UInt8>
    let bitLimit: Int
    var bitPosition = 0

    var isAtEnd: Bool { bitPosition == bitLimit }

    mutating func read(_ count: Int) -> Int? {
        guard (0...32).contains(count), count <= bitLimit - bitPosition else {
            return nil
        }
        guard count > 0 else { return 0 }
        let value = peekPadded(count)
        bitPosition += count
        return value
    }

    func peekPadded(_ count: Int) -> Int {
        let byteOffset = bitPosition >> 3
        let intraByte = bitPosition & 7
        var word = UInt64(bigEndian: UnsafeRawPointer(
            pointer.advanced(by: byteOffset)
        ).loadUnaligned(as: UInt64.self))
        word <<= UInt64(intraByte)
        return Int(word >> UInt64(64 - count))
    }
}

/// Fifteen-bit direct Huffman lookup. Entry high bits hold code length and low
/// sixteen bits hold the symbol. Tables are allocated once and rebuilt in place.
private final class RAR5HuffmanTable {
    private static let lookupBits = 15
    private static let lookupCount = 1 << lookupBits
    private let lookup: UnsafeMutablePointer<UInt32>

    init() {
        lookup = .allocate(capacity: Self.lookupCount)
        lookup.initialize(repeating: 0, count: Self.lookupCount)
    }

    deinit { lookup.deallocate() }

    func build(
        lengths: UnsafePointer<UInt8>,
        count: Int,
        requireSymbol: Bool
    ) throws {
        lookup.update(repeating: 0, count: Self.lookupCount)
        var counts = [Int](repeating: 0, count: Self.lookupBits + 1)
        var symbolCount = 0
        for index in 0..<count {
            let length = Int(lengths[index])
            guard length <= Self.lookupBits else {
                throw KaitoError.malformed("RAR5 Huffman length exceeds 15")
            }
            if length > 0 {
                counts[length] += 1
                symbolCount += 1
            }
        }
        if requireSymbol, symbolCount == 0 {
            throw KaitoError.malformed("RAR5 Huffman table is empty")
        }
        guard symbolCount > 0 else { return }

        var next = [Int](repeating: 0, count: Self.lookupBits + 1)
        var code = 0
        for length in 1...Self.lookupBits {
            let (sum, overflow) = code.addingReportingOverflow(counts[length - 1])
            guard !overflow else { throw KaitoError.malformed("RAR5 Huffman count overflow") }
            let (shifted, shiftOverflow) = sum.multipliedReportingOverflow(by: 2)
            guard !shiftOverflow, shifted <= 1 << length else {
                throw KaitoError.malformed("RAR5 Huffman table is oversubscribed")
            }
            code = shifted
            next[length] = code
        }

        for symbol in 0..<count {
            let length = Int(lengths[symbol])
            guard length > 0 else { continue }
            let prefix = next[length]
            next[length] += 1
            guard next[length] <= 1 << length else {
                throw KaitoError.malformed("RAR5 Huffman code is oversubscribed")
            }
            let repetitions = 1 << (Self.lookupBits - length)
            let start = prefix << (Self.lookupBits - length)
            guard start >= 0, repetitions <= Self.lookupCount - start else {
                throw KaitoError.malformed("RAR5 Huffman lookup range is invalid")
            }
            let entry = UInt32(length << 16 | symbol)
            lookup.advanced(by: start).update(repeating: entry, count: repetitions)
        }
    }

    func decode(from bits: inout RAR5RawBitReader) -> Int? {
        guard bits.bitPosition < bits.bitLimit else { return nil }
        let entry = lookup[bits.peekPadded(Self.lookupBits)]
        let length = Int(entry >> 16)
        guard length > 0, length <= bits.bitLimit - bits.bitPosition else { return nil }
        bits.bitPosition += length
        return Int(entry & 0xffff)
    }
}
