import Foundation

// RAR5 LZ provenance (the complete retained implementation input set):
// - RARLab, "RAR 5.0 archive format", https://www.rarlab.com/technote.htm
//   (accessed 2026-09-06), is the sole external RAR5 format-specific reference
//   source. It specifies the container but intentionally omits compression
//   grammar details.
// - The missing grammar was supplied by the task orchestrator as a clean-room
//   specification, not obtained from a third-party decoder implementation.
// - Archives produced and extracted by /opt/homebrew/bin/rar 7.23 supplied
//   black-box input/output vectors only; its source was not read or used.
// Source code from UnRAR, 7-Zip, XADMaster and The Unarchiver was not read or used.
// During separate filter work, prohibited libarchive RAR5 source was
// accidentally opened once. The affected filter file was deleted and
// independently rewritten; no content from that incident is used here.
// Documentation/design.md §10–§11 records the generic algorithm references
// and the incident/remediation in full.

/// Pull decoder for the version-zero RAR5 LZ stream.
///
/// Performance invariants:
/// - compressed bytes, the ring window and all Huffman lookup tables are raw
///   buffers allocated exactly once during initialization;
/// - the input has sixteen zero sentinel bytes, so a 64-bit unaligned peek is
///   physically safe even at a logical block boundary;
/// - logical bit limits, Huffman runs, distances and output limits are checked
///   at block/symbol boundaries, while literal and match-copy loops do not throw;
/// - matches stage a period in caller output, double it, then mirror the ring;
///   window cursors and output accounting stay local for the entire read.
///
/// A failure is latched: after `read(into:)` throws, every later read throws
/// the same error and `isFinished` stays false.
final class RAR5Decoder: Decompressor {
    private static let sentinelByteCount = 16
    /// Smallest window the version-zero grammar declares (dictionary exponent 0).
    private static let minimumDictionarySize = 128 * 1_024
    /// Initial value of the XOR check over a compressed block header.
    private static let blockHeaderChecksumSeed: UInt8 = 0x5a
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

    /// State carried from one compressed file to the next in a solid group.
    /// A coordinator gives it to only one decoder at a time. Bit readers,
    /// filters and output counters remain file-local; the LZ/Huffman state
    /// defined by the solid grammar lives here.
    final class SolidState {
        let window: UnsafeMutablePointer<UInt8>
        let windowSize: Int
        let windowMask: Int

        fileprivate let mainTable = RAR5HuffmanTable()
        fileprivate let distanceTable = RAR5HuffmanTable()
        fileprivate let lowDistanceTable = RAR5HuffmanTable()
        fileprivate let repeatLengthTable = RAR5HuffmanTable()
        // Table-description work areas. Only one decoder uses a state at a
        // time, and every table is rebuilt before a member decodes symbols.
        fileprivate let bitLengthTable = RAR5HuffmanTable()
        fileprivate let codeLengths: UnsafeMutablePointer<UInt8>
        fileprivate let bitCodeLengths: UnsafeMutablePointer<UInt8>
        // Compressed-input area lent to pooled independent decoders; a solid
        // member keeps its own input because the coordinator may overlap two.
        fileprivate var inputBuffer: UnsafeMutablePointer<UInt8>?
        fileprivate var inputCapacity = 0

        var tablesWereRead = false
        var windowPosition = 0
        var historySize = 0
        var oldDistance0 = 0
        var oldDistance1 = 0
        var oldDistance2 = 0
        var oldDistance3 = 0
        var lastLength = 0

        init(dictionarySize: UInt64) throws {
            let size = try Checked.toInt(dictionarySize)
            guard size >= RAR5Decoder.minimumDictionarySize, size.nonzeroBitCount == 1 else {
                throw KaitoError.unsupportedMethod(
                    "RAR5 decoder requires a power-of-two dictionary"
                )
            }
            guard let raw = malloc(size) else {
                throw KaitoError.limitExceeded("unable to allocate RAR5 dictionary")
            }
            window = raw.bindMemory(to: UInt8.self, capacity: size)
            windowSize = size
            windowMask = size - 1
            codeLengths = .allocate(capacity: RAR5Decoder.combinedTableCount)
            bitCodeLengths = .allocate(capacity: RAR5Decoder.bitLengthSymbolCount)
            // validateMatch requires distance <= historySize. All readable
            // history is written by literals/matches before it is referenced,
            // including in a continuing solid group; no zero fill is observable.
        }

        deinit {
            free(UnsafeMutableRawPointer(window))
            if let inputBuffer { free(UnsafeMutableRawPointer(inputBuffer)) }
            codeLengths.deallocate()
            bitCodeLengths.deallocate()
        }

        /// Returns the state to its fresh-member condition for reuse by an
        /// independent entry. Window contents need no clearing: `historySize`
        /// is zero, so no byte can be referenced before it is written.
        fileprivate func resetForIndependentEntry() {
            tablesWereRead = false
            windowPosition = 0
            historySize = 0
            oldDistance0 = 0
            oldDistance1 = 0
            oldDistance2 = 0
            oldDistance3 = 0
            lastLength = 0
        }

        /// Lends an input area of at least `capacity` bytes, growing it in place.
        fileprivate func lendInputBuffer(capacity: Int) -> UnsafeMutablePointer<UInt8>? {
            if let inputBuffer, inputCapacity >= capacity { return inputBuffer }
            let newCapacity = max(capacity, min(inputCapacity &* 2, ScratchPool.maximumRecycledBytes))
            guard let raw = malloc(newCapacity) else { return nil }
            if let inputBuffer { free(UnsafeMutableRawPointer(inputBuffer)) }
            inputBuffer = raw.bindMemory(to: UInt8.self, capacity: newCapacity)
            inputCapacity = newCapacity
            return inputBuffer
        }
    }

    /// Recycles decoder states (window, tables, input area) across the
    /// independent members of one archive, so a 50,000-file archive does not
    /// allocate and clear seventeen buffers per member. States larger than
    /// `maximumRecycledBytes` in either area are freed instead of kept.
    final class ScratchPool: @unchecked Sendable {
        static let maximumRecycledBytes = 4 * 1_024 * 1_024
        private let lock = NSLock()
        private let capacity: Int
        private var free: [SolidState] = []

        init(capacity: Int) {
            self.capacity = max(1, capacity)
        }

        /// A reset state whose window is at least `windowSize` bytes, or nil.
        func take(windowSize: Int) -> SolidState? {
            let state: SolidState? = lock.withLock {
                var best: Int?
                for index in free.indices where free[index].windowSize >= windowSize {
                    if let current = best, free[current].windowSize <= free[index].windowSize { continue }
                    best = index
                }
                guard let best else { return nil }
                return free.remove(at: best)
            }
            state?.resetForIndependentEntry()
            return state
        }

        func recycle(_ state: SolidState) {
            guard state.windowSize <= Self.maximumRecycledBytes,
                  state.inputCapacity <= Self.maximumRecycledBytes else { return }
            lock.withLock {
                if free.count < capacity { free.append(state) }
            }
        }

        var freeCount: Int { lock.withLock { free.count } }
    }

    private let input: UnsafeMutablePointer<UInt8>
    private let inputCount: Int
    private let ownsInput: Bool
    private let solidState: SolidState
    private let scratchPool: ScratchPool?
    // Largest match distance this member may reference: the window it would
    // own by itself (solid group window, or the independent member's retained
    // window). A recycled ring can be larger; history must not reach past this.
    private let matchDistanceLimit: Int
    // Preserve diagnostics for the logical dictionary when storage is smaller.
    private let describedWindowSize: Int
    private let expectedSize: UInt64?
    private let maximumFilterCount: Int
    // Most compressed entries do not use a standard filter. Allocate these
    // large work areas once, on the first filter, instead of touching 8 MiB for
    // every entry in JPEG-heavy archives.
    private var filterInput: UnsafeMutablePointer<UInt8>?
    private var filterOutput: UnsafeMutablePointer<UInt8>?

    private var bitLengthTable: RAR5HuffmanTable { solidState.bitLengthTable }
    private var codeLengths: UnsafeMutablePointer<UInt8> { solidState.codeLengths }
    private var bitCodeLengths: UnsafeMutablePointer<UInt8> { solidState.bitCodeLengths }

    private var nextBlockOffset = 0
    private var bits: RAR5RawBitReader?
    private var currentBlockIsLast = false
    private var rawFinished = false
    private var finished = false
    // Only this small tag is inspected by the symbol loop. Strings and caught
    // boundary errors are materialized/stored exclusively on failure paths.
    private enum DecodeFailure {
        case truncated
        case boundary
        case invalidMatch
        case unsupportedFilter
        case filterBehindOutput
        case positionsDiverged
        case filterPrefillStalled
        case filterBeyondOutput
        case filterInputStalled
        case standardFilterFailed
        case missingFilterInput
        case missingFilterOutput
        case unflushedOutput
        case decoderStalled
        case filterBoundaryPassed
        case missingBlock
        case blockTransitionFailed
        case mainCodeOverrun
        case outputSizeExceeded
        case filterDataOverrun
        case invalidLastMatch
        case repeatLengthOverrun
        case invalidRepeatMatch
        case matchOverrun
        case invalidMainSymbol
        case filterCountExceeded
        case invalidFilterParameters
        case filterRangeOverflow
        case filterRangeExceeded
        case filterRangeOverlap
        case filterInputAllocation
        case filterOutputAllocation
    }

    private var failure: DecodeFailure?

    private var produced: UInt64 = 0
    private var emitted: UInt64 = 0
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
        expectedSize: UInt64?,
        dictionarySize: UInt64,
        limits: ReadLimits,
        solidState suppliedSolidState: SolidState? = nil,
        scratchPool: ScratchPool? = nil,
        independentState: SolidState? = nil
    ) throws {
        if let expectedSize {
            try Checked.size(expectedSize, limit: limits.maxEntrySize)
        }
        try Checked.size(compressedSize, limit: limits.maxEntrySize)
        try Checked.size(dictionarySize, limit: limits.maxDictionarySize)
        let requiredDictionarySize = try Checked.toInt(dictionarySize)
        guard requiredDictionarySize >= Self.minimumDictionarySize,
              requiredDictionarySize.nonzeroBitCount == 1 else {
            throw KaitoError.unsupportedMethod(
                "RAR5 decoder requires a power-of-two dictionary"
            )
        }
        let inputCount = try Checked.toInt(compressedSize)
        let allocationCount = try Checked.toInt(
            try Checked.add(compressedSize, UInt64(Self.sentinelByteCount))
        )
        let state: SolidState
        var pooled = false
        // The ring the member would own on its own: the solid group's window,
        // or an independent member's retained window. A pooled or batch state
        // may be larger than this, so it bounds match distances explicitly.
        let matchDistanceLimit: Int
        do {
            if let suppliedSolidState {
                // A solid member records its minimum required dictionary, not
                // a command to resize the continuing window. The coordinator
                // allocates the group's maximum and later members may declare
                // a smaller minimum while still referring to older history.
                guard suppliedSolidState.windowSize >= requiredDictionarySize else {
                    throw KaitoError.malformed(
                        "RAR5 solid state is smaller than a member requirement"
                    )
                }
                state = suppliedSolidState
                matchDistanceLimit = suppliedSolidState.windowSize
            } else {
                // Only independent entries with a known total output size
                // can retain less than the declared dictionary. The ring still
                // needs a power-of-two mask; solid coordinators supply the full
                // group window and never take this path. Declared-size limits
                // and grammar validation have already run above.
                let retainedSize = Self.retainedWindowSize(
                    expectedSize: expectedSize, dictionarySize: requiredDictionarySize
                )
                matchDistanceLimit = retainedSize
                if let independentState, independentState.windowSize >= retainedSize {
                    // A caller-owned state reused across a run of independent
                    // members (prefetch batches); it is reset, never recycled.
                    independentState.resetForIndependentEntry()
                    state = independentState
                    pooled = true
                } else if let recycled = scratchPool?.take(windowSize: retainedSize) {
                    state = recycled
                    pooled = true
                } else {
                    state = try SolidState(dictionarySize: UInt64(retainedSize))
                    pooled = scratchPool != nil
                }
            }
        }
        let inputRaw: UnsafeMutableRawPointer
        if pooled, let lent = state.lendInputBuffer(capacity: allocationCount) {
            inputRaw = UnsafeMutableRawPointer(lent)
            ownsInput = false
        } else {
            guard let owned = malloc(allocationCount) else {
                scratchPool?.recycle(state)
                throw KaitoError.limitExceeded("unable to allocate RAR5 compressed input")
            }
            inputRaw = owned
            ownsInput = true
        }
        self.input = inputRaw.bindMemory(to: UInt8.self, capacity: allocationCount)
        self.inputCount = inputCount
        self.solidState = state
        self.scratchPool = pooled && state !== independentState ? scratchPool : nil
        self.matchDistanceLimit = matchDistanceLimit
        self.describedWindowSize = suppliedSolidState?.windowSize ?? requiredDictionarySize
        self.expectedSize = expectedSize
        self.maximumFilterCount = limits.maxMetadataRecordCount
        self.filterInput = nil
        self.filterOutput = nil

        // Input and table lengths are fully written before use. Only the
        // speculative bit-reader padding must be zero even on truncated input.
        input.advanced(by: inputCount).initialize(repeating: 0, count: Self.sentinelByteCount)
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
                guard expectedSize == 0 else { throw KaitoError.truncated }
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

    /// Ring retained for an independent member: the declared dictionary, or
    /// for a member whose known size is smaller, the smallest power of two from
    /// 128 KiB that holds the whole output.
    static func retainedWindowSize(expectedSize: UInt64?, dictionarySize: Int) -> Int {
        guard let expectedSize, expectedSize < UInt64(dictionarySize) else { return dictionarySize }
        var retainedSize = Self.minimumDictionarySize
        while UInt64(retainedSize) < expectedSize {
            retainedSize *= 2
        }
        return retainedSize
    }

    deinit {
        if ownsInput { free(UnsafeMutableRawPointer(input)) }
        if let filterInput { free(UnsafeMutableRawPointer(filterInput)) }
        if let filterOutput { free(UnsafeMutableRawPointer(filterOutput)) }
        scratchPool?.recycle(solidState)
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if let failure { throw error(for: failure) }
        guard !buffer.isEmpty, !finished else { return 0 }
        guard let output = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            return 0
        }

        let window = solidState.window
        let windowMask = solidState.windowMask
        var windowPosition = solidState.windowPosition
        var historySize = solidState.historySize
        var produced = self.produced
        defer {
            solidState.windowPosition = windowPosition
            solidState.historySize = historySize
            self.produced = produced
        }

        var written = 0
        while written < buffer.count, !finished {
            if nextFilterIndex < scheduledFilters.count {
                let filter = scheduledFilters[nextFilterIndex]
                let isBeforeFilter = filterEmitCount == 0 && emitted <= filter.start
                let isResumingFilter = filterEmitCount > 0
                    && emitted == filter.start + UInt64(filterEmitCount)
                guard isBeforeFilter || isResumingFilter else {
                    failure = .filterBehindOutput
                    break
                }

                if emitted < filter.start {
                    guard emitted == produced else {
                        failure = .positionsDiverged
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
                        stopAtFilter: true,
                        window: window,
                        windowMask: windowMask,
                        windowPosition: &windowPosition,
                        historySize: &historySize,
                        produced: &produced
                    )
                    emitted += UInt64(count)
                    written += count
                    if failure != nil { break }
                    if emitted < filter.start {
                        if rawFinished {
                            failure = .truncated
                            break
                        }
                        guard count > 0 else {
                            failure = .filterPrefillStalled
                            break
                        }
                    }
                    continue
                }

                if !filterIsReady {
                    guard ensureFilterBuffers(),
                          let filterInput else { break }
                    guard produced >= filter.start else {
                        failure = .filterBeyondOutput
                        break
                    }
                    let needed = filter.length - filterFillCount
                    if needed > 0 {
                        let count = decodeRaw(
                            into: filterInput.advanced(by: filterFillCount),
                            capacity: needed,
                            stopAtFilter: false,
                            window: window,
                            windowMask: windowMask,
                            windowPosition: &windowPosition,
                            historySize: &historySize,
                            produced: &produced
                        )
                        filterFillCount += count
                        if failure != nil { break }
                        if filterFillCount < filter.length {
                            if rawFinished {
                                failure = .truncated
                                break
                            }
                            guard count > 0 else {
                                failure = .filterInputStalled
                                break
                            }
                            continue
                        }
                    }
                    do {
                        try prepare(filter: filter)
                    } catch let error as KaitoError {
                        boundaryError = error
                        failure = .boundary
                        break
                    } catch {
                        failure = .standardFilterFailed
                        break
                    }
                }

                let available = filter.length - filterEmitCount
                let count = min(available, buffer.count - written)
                guard let filterInput else {
                    failure = .missingFilterInput
                    break
                }
                let source: UnsafeMutablePointer<UInt8>
                if filterUsesSecondaryOutput {
                    guard let filterOutput else {
                        failure = .missingFilterOutput
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
                    failure = .unflushedOutput
                    break
                }
                finished = true
                break
            }

            let count = decodeRaw(
                into: output.advanced(by: written),
                capacity: buffer.count - written,
                stopAtFilter: true,
                window: window,
                windowMask: windowMask,
                windowPosition: &windowPosition,
                historySize: &historySize,
                produced: &produced
            )
            emitted += UInt64(count)
            written += count
            if failure != nil { break }
            if count == 0, !rawFinished, nextFilterIndex >= scheduledFilters.count {
                failure = .decoderStalled
                break
            }
        }

        if let failure { throw error(for: failure) }
        return written
    }

    /// Decodes raw LZ bytes into a caller-owned bounded range. When requested,
    /// decoding stops exactly at the first scheduled filter boundary.
    ///
    /// Symbols are written to the ring only and the produced range is copied
    /// to `output` once, so a match touches one destination. One call
    /// therefore produces at most one window of bytes; `read` keeps calling
    /// until the caller buffer is full, and every token-boundary check (output
    /// size, filter boundary, block transition) happens at the same symbol.
    private func decodeRaw(
        into output: UnsafeMutablePointer<UInt8>,
        capacity requestedCapacity: Int,
        stopAtFilter: Bool,
        window: UnsafeMutablePointer<UInt8>,
        windowMask: Int,
        windowPosition: inout Int,
        historySize: inout Int,
        produced: inout UInt64
    ) -> Int {
        guard requestedCapacity > 0, !rawFinished, failure == nil else { return 0 }
        let windowSize = windowMask &+ 1
        let capacity = min(requestedCapacity, windowSize)
        var written = 0
        var failure: DecodeFailure?
        // The block reader is held in a local for the whole loop. `bits` is nil
        // only before the first block, which `init` always reads.
        var hasBlock = self.bits != nil
        var bitReader = self.bits ?? RAR5RawBitReader(pointer: UnsafePointer(input), bitLimit: 0)
        var pendingLength = self.pendingLength
        var pendingDistance = self.pendingDistance
        var rawFinished = self.rawFinished
        var oldDistance0 = solidState.oldDistance0
        var oldDistance1 = solidState.oldDistance1
        var oldDistance2 = solidState.oldDistance2
        var oldDistance3 = solidState.oldDistance3
        var lastLength = solidState.lastLength
        var position = windowPosition
        var history = historySize
        // Bytes the declared size still allows; with no declared size this is
        // the distance to the counter limit, exactly as before.
        var remainingOutput: UInt64 = expectedSize.map { $0 &- min(produced, $0) }
            ?? (UInt64.max &- produced)
        let mainTable = solidState.mainTable
        let distanceTable = solidState.distanceTable
        let lowDistanceTable = solidState.lowDistanceTable
        let repeatLengthTable = solidState.repeatLengthTable
        let distanceLimit = matchDistanceLimit
        var filterStart: UInt64?
        if stopAtFilter, nextFilterIndex < scheduledFilters.count {
            filterStart = scheduledFilters[nextFilterIndex].start
        }

        symbols: while written < capacity, !rawFinished {
            var available = capacity &- written
            if let filterStart {
                guard filterStart >= produced else {
                    failure = .filterBoundaryPassed
                    break
                }
                if filterStart == produced { break }
                available = min(available, Int(min(filterStart &- produced, UInt64(Int.max))))
            }

            if pendingLength > 0 {
                let amount = min(pendingLength, available)
                Self.copyMatch(
                    window: window, windowMask: windowMask, position: &position,
                    historySize: history, distance: pendingDistance, count: amount
                )
                history = min(windowSize, history &+ amount)
                produced &+= UInt64(amount)
                remainingOutput &-= UInt64(amount)
                pendingLength &-= amount
                written &+= amount
                continue
            }

            guard hasBlock else {
                failure = .missingBlock
                break
            }
            if bitReader.isAtEnd {
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
                    if let next = self.bits {
                        bitReader = next
                        hasBlock = true
                    }
                } catch let error as KaitoError {
                    boundaryError = error
                    failure = .boundary
                    break
                } catch {
                    failure = .blockTransitionFailed
                    break
                }
                continue
            }

            guard let symbol = mainTable.decode(from: &bitReader) else {
                failure = .mainCodeOverrun
                break
            }

            if symbol < 256 {
                guard remainingOutput >= 1 else {
                    failure = .outputSizeExceeded
                    break
                }
                window[position] = UInt8(truncatingIfNeeded: symbol)
                position = (position &+ 1) & windowMask
                history = min(windowSize, history &+ 1)
                produced &+= 1
                remainingOutput &-= 1
                written &+= 1
                continue
            }

            let distance: Int
            let length: Int
            switch symbol {
            case 256:
                guard let filter = readFilter(from: &bitReader, produced: produced, failure: &failure) else {
                    if failure == nil {
                        failure = .filterDataOverrun
                    }
                    break symbols
                }
                scheduledFilters.append(filter)
                if stopAtFilter, nextFilterIndex < scheduledFilters.count {
                    filterStart = scheduledFilters[nextFilterIndex].start
                }
                continue

            case 257:
                guard lastLength > 0,
                      Self.isValidMatch(
                        distance: oldDistance0, length: lastLength, distanceLimit: distanceLimit,
                        historySize: history, remainingOutput: remainingOutput
                      ) else {
                    failure = .invalidLastMatch
                    break symbols
                }
                distance = oldDistance0
                length = lastLength

            case 258...261:
                let repeated: Int
                switch symbol &- 258 {
                case 0:
                    repeated = oldDistance0
                case 1:
                    repeated = oldDistance1
                    oldDistance1 = oldDistance0
                case 2:
                    repeated = oldDistance2
                    oldDistance2 = oldDistance1
                    oldDistance1 = oldDistance0
                default:
                    repeated = oldDistance3
                    oldDistance3 = oldDistance2
                    oldDistance2 = oldDistance1
                    oldDistance1 = oldDistance0
                }
                oldDistance0 = repeated
                guard let slot = repeatLengthTable.decode(from: &bitReader),
                      let repeatedLength = Self.decodeLengthSlot(slot, bits: &bitReader) else {
                    failure = .repeatLengthOverrun
                    break symbols
                }
                guard Self.isValidMatch(
                    distance: repeated, length: repeatedLength, distanceLimit: distanceLimit,
                    historySize: history, remainingOutput: remainingOutput
                ) else {
                    failure = .invalidRepeatMatch
                    break symbols
                }
                lastLength = repeatedLength
                distance = repeated
                length = repeatedLength

            case 262..<Self.mainSymbolCount:
                guard var matchLength = Self.decodeLengthSlot(symbol &- 262, bits: &bitReader),
                      let distanceSlot = distanceTable.decode(from: &bitReader),
                      let matchDistance = Self.decodeDistance(
                        slot: distanceSlot, bits: &bitReader, lowDistanceTable: lowDistanceTable
                      ) else {
                    failure = .matchOverrun
                    break symbols
                }
                if matchDistance > 0x100 { matchLength &+= 1 }
                if matchDistance > 0x2_000 { matchLength &+= 1 }
                if matchDistance > 0x4_0000 { matchLength &+= 1 }
                guard Self.isValidMatch(
                    distance: matchDistance, length: matchLength, distanceLimit: distanceLimit,
                    historySize: history, remainingOutput: remainingOutput
                ) else {
                    failedMatch = (produced, matchDistance, matchLength)
                    failure = .invalidMatch
                    break symbols
                }
                oldDistance3 = oldDistance2
                oldDistance2 = oldDistance1
                oldDistance1 = oldDistance0
                oldDistance0 = matchDistance
                lastLength = matchLength
                distance = matchDistance
                length = matchLength

            default:
                failure = .invalidMainSymbol
                break symbols
            }

            // The match was validated against history and the declared size.
            // Only the part that fits this call is copied; the rest resumes on
            // the next iteration or call exactly like a token-boundary clip.
            let amount = min(length, available)
            Self.copyMatch(
                window: window, windowMask: windowMask, position: &position,
                historySize: history, distance: distance, count: amount
            )
            history = min(windowSize, history &+ amount)
            produced &+= UInt64(amount)
            remainingOutput &-= UInt64(amount)
            written &+= amount
            if amount < length {
                pendingLength = length &- amount
                pendingDistance = distance
            }
        }

        self.failure = failure
        self.bits = hasBlock ? bitReader : nil
        self.pendingLength = pendingLength
        self.pendingDistance = pendingDistance
        self.rawFinished = rawFinished
        solidState.oldDistance0 = oldDistance0
        solidState.oldDistance1 = oldDistance1
        solidState.oldDistance2 = oldDistance2
        solidState.oldDistance3 = oldDistance3
        solidState.lastLength = lastLength
        windowPosition = position
        historySize = history

        // `written` <= windowSize, so the produced range is still intact in
        // the ring: copy it out once, in at most two pieces.
        if written > 0 {
            let start = (position &- written) & windowMask
            let first = min(written, windowSize &- start)
            output.update(from: window.advanced(by: start), count: first)
            if first < written {
                output.advanced(by: first).update(from: window, count: written &- first)
            }
        }
        return written
    }

    private func readFilter(
        from bits: inout RAR5RawBitReader,
        produced: UInt64,
        failure: inout DecodeFailure?
    ) -> ScheduledFilter? {
        guard scheduledFilters.count < maximumFilterCount else {
            failure = .filterCountExceeded
            return nil
        }
        guard let relativeStart = readFilterInteger(from: &bits),
              let lengthValue = readFilterInteger(from: &bits),
              lengthValue > 0,
              lengthValue <= RARStandardFilters.rar5MaximumBlockSize,
              let type = bits.read(3),
              let kind = RARStandardFilterKind(rawValue: UInt8(type)) else {
            failure = .invalidFilterParameters
            return nil
        }
        guard kind == .delta || kind == .e8 || kind == .e8e9 || kind == .arm else {
            failedFilterType = type
            failure = .unsupportedFilter
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
            failure = .filterRangeOverflow
            return nil
        }
        if let expectedSize, end > expectedSize {
            failure = .filterRangeExceeded
            return nil
        }
        if let previous = scheduledFilters.last, start < previous.end {
            failure = .filterRangeOverlap
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
            failure = .filterInputAllocation
            return false
        }
        guard let outputRaw = malloc(capacity) else {
            free(inputRaw)
            failure = .filterOutputAllocation
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

        var checksum: UInt8 = Self.blockHeaderChecksumSeed ^ flags
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
            solidState.tablesWereRead = true
        } else if !solidState.tablesWereRead {
            throw KaitoError.malformed("RAR5 first compressed block has no Huffman tables")
        }
        bits = reader
    }

    private func readTables(from bits: inout RAR5RawBitReader) throws {
        // RAR5 table descriptions are self-contained. A block without the
        // table flag reuses the last tables, but a present description does
        // not delta its lengths against the preceding block.
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

        try solidState.mainTable.build(
            lengths: UnsafePointer(codeLengths),
            count: Self.mainSymbolCount,
            // RAR emits a table-only final block for a valid method-5 empty
            // member, including when the file header omits unpacked size. Any
            // attempted symbol decode still fails closed in `decodeRaw`.
            requireSymbol: false
        )
        try solidState.distanceTable.build(
            lengths: UnsafePointer(codeLengths.advanced(by: Self.mainSymbolCount)),
            count: Self.distanceSymbolCount,
            requireSymbol: false
        )
        try solidState.lowDistanceTable.build(
            lengths: UnsafePointer(codeLengths.advanced(
                by: Self.mainSymbolCount + Self.distanceSymbolCount
            )),
            count: Self.lowDistanceSymbolCount,
            requireSymbol: false
        )
        try solidState.repeatLengthTable.build(
            lengths: UnsafePointer(codeLengths.advanced(
                by: Self.mainSymbolCount
                    + Self.distanceSymbolCount
                    + Self.lowDistanceSymbolCount
            )),
            count: Self.repeatLengthSymbolCount,
            requireSymbol: false
        )
    }

    /// Length slot decoding by arithmetic instead of the two static tables:
    /// slots 0-7 are literal lengths, later slots carry (slot / 4 - 1) extra
    /// bits above a base of (4 + slot % 4) << extra.
    @inline(__always)
    private static func decodeLengthSlot(
        _ slot: Int,
        bits: inout RAR5RawBitReader
    ) -> Int? {
        guard slot >= 0, slot < Self.repeatLengthSymbolCount else { return nil }
        if slot < 8 {
            return slot &+ 2
        }
        let bitCount = (slot >> 2) &- 1
        guard let extra = bits.read(bitCount) else { return nil }
        return ((4 &+ (slot & 3)) << bitCount) &+ extra &+ 2
    }

    @inline(__always)
    private static func decodeDistance(
        slot: Int,
        bits: inout RAR5RawBitReader,
        lowDistanceTable: RAR5HuffmanTable
    ) -> Int? {
        guard slot >= 0, slot < Self.distanceSymbolCount else { return nil }
        if slot < 4 { return slot &+ 1 }

        let extraBitCount = (slot >> 1) &- 1
        var distance = (2 | (slot & 1)) << extraBitCount
        if extraBitCount >= 4 {
            if extraBitCount > 4 {
                guard let high = bits.read(extraBitCount &- 4) else { return nil }
                distance &+= high << 4
            }
            guard let low = lowDistanceTable.decode(from: &bits) else { return nil }
            distance &+= low
        } else {
            guard let extra = bits.read(extraBitCount) else { return nil }
            distance &+= extra
        }
        let (result, overflow) = distance.addingReportingOverflow(1)
        return overflow ? nil : result
    }

    /// Copies a validated match into the ring. While the ring has never
    /// wrapped (`position == historySize`), every byte at or beyond the write
    /// cursor is unwritten and unreachable, so a run that leaves one spare
    /// word before the ring end may overrun by up to seven bytes and skip the
    /// exact tail handling. Everything else takes the exact ring copy.
    @inline(__always)
    private static func copyMatch(
        window: UnsafeMutablePointer<UInt8>,
        windowMask: Int,
        position: inout Int,
        historySize: Int,
        distance: Int,
        count: Int
    ) {
        if position == historySize, distance >= 8, position &+ count &+ 8 <= windowMask &+ 1 {
            let to = UnsafeMutableRawPointer(window.advanced(by: position))
            let from = UnsafeRawPointer(window.advanced(by: position &- distance))
            var index = 0
            while index < count {
                to.storeBytes(of: from.loadUnaligned(fromByteOffset: index, as: UInt64.self),
                              toByteOffset: index, as: UInt64.self)
                index &+= 8
            }
            position &+= count
        } else {
            copyMatchWithinWindow(
                window: window, windowMask: windowMask, position: &position,
                distance: distance, count: count
            )
        }
    }

    /// Token-boundary validation of a match. `distanceLimit` is the window the
    /// member would own by itself (the ring may be a larger recycled one, in
    /// which `historySize` can grow past that window), `historySize` is the
    /// readable history in the ring, and `remainingOutput` is the declared
    /// size minus the output so far.
    @inline(__always)
    private static func isValidMatch(
        distance: Int, length: Int, distanceLimit: Int, historySize: Int, remainingOutput: UInt64
    ) -> Bool {
        distance > 0 && distance <= distanceLimit && distance <= historySize && length > 0
            && UInt64(length) <= remainingOutput
    }

    // MARK: - Failure reporting

    // Details recorded next to `failure` on the failure path only.
    private var boundaryError: KaitoError?
    private var failedMatch: (produced: UInt64, distance: Int, length: Int)?
    private var failedFilterType = 0

    private func error(for failure: DecodeFailure) -> KaitoError {
        switch failure {
        case .truncated: return .truncated
        case .boundary: return boundaryError ?? .malformed("RAR5 block transition failed")
        case .invalidMatch:
            let match = failedMatch ?? (produced: produced, distance: 0, length: 0)
            let describedExpectedSize = expectedSize.map(String.init) ?? "unknown"
            return .malformed(
                "RAR5 invalid LZ match at output \(match.produced): distance \(match.distance), length \(match.length), window \(describedWindowSize), expected \(describedExpectedSize)"
            )
        case .unsupportedFilter: return .unsupportedMethod("RAR5 filter type \(failedFilterType)")
        case .filterBehindOutput: return .malformed("RAR5 filter starts behind emitted output")
        case .positionsDiverged: return .malformed("RAR5 raw and emitted positions diverged")
        case .filterPrefillStalled: return .malformed("RAR5 filter prefill made no progress")
        case .filterBeyondOutput: return .malformed("RAR5 filter begins beyond raw output")
        case .filterInputStalled: return .malformed("RAR5 filter input made no progress")
        case .standardFilterFailed: return .malformed("RAR5 standard filter failed")
        case .missingFilterInput: return .malformed("RAR5 filter input buffer is unavailable")
        case .missingFilterOutput: return .malformed("RAR5 filter output buffer is unavailable")
        case .unflushedOutput: return .malformed("RAR5 output ended with unflushed raw bytes")
        case .decoderStalled: return .malformed("RAR5 decoder made no progress")
        case .filterBoundaryPassed: return .malformed("RAR5 filter boundary was passed")
        case .missingBlock: return .malformed("RAR5 decoder has no active block")
        case .blockTransitionFailed: return .malformed("RAR5 block transition failed")
        case .mainCodeOverrun: return .malformed("RAR5 main Huffman code runs past its block")
        case .outputSizeExceeded: return .malformed("RAR5 output exceeds its declared size")
        case .filterDataOverrun: return .malformed("RAR5 filter data runs past its block")
        case .invalidLastMatch: return .malformed("RAR5 invalid last-match repetition")
        case .repeatLengthOverrun: return .malformed("RAR5 repeat length runs past its block")
        case .invalidRepeatMatch: return .malformed("RAR5 invalid repeated-distance match")
        case .matchOverrun: return .malformed("RAR5 match runs past its block")
        case .invalidMainSymbol: return .malformed("RAR5 main Huffman symbol is out of range")
        case .filterCountExceeded: return .limitExceeded("RAR5 filter count")
        case .invalidFilterParameters: return .malformed("RAR5 filter parameters are invalid")
        case .filterRangeOverflow: return .malformed("RAR5 filter range overflows")
        case .filterRangeExceeded: return .malformed("RAR5 filter range exceeds output")
        case .filterRangeOverlap: return .malformed("RAR5 filter ranges overlap or are out of order")
        case .filterInputAllocation: return .limitExceeded("unable to allocate RAR5 filter input")
        case .filterOutputAllocation: return .limitExceeded("unable to allocate RAR5 filter output")
        }
    }
}

/// Raw MSB-first reader. The owner guarantees at least eight sentinel bytes
/// beyond the physical payload, while `bitLimit` is the authoritative boundary.
struct RAR5RawBitReader {
    let pointer: UnsafePointer<UInt8>
    let bitLimit: Int
    var bitPosition = 0

    var isAtEnd: Bool { bitPosition == bitLimit }

    @inline(__always)
    mutating func read(_ count: Int) -> Int? {
        guard (0...32).contains(count), count <= bitLimit - bitPosition else {
            return nil
        }
        guard count > 0 else { return 0 }
        let value = peekPadded(count)
        bitPosition += count
        return value
    }

    @inline(__always)
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

/// Ten-bit quick lookup with canonical decoding for eleven- to fifteen-bit
/// codes. Only the small quick table is expanded; counts, code boundaries and
/// sorted symbols are retained and rebuilt in place.
final class RAR5HuffmanTable {
    private static let primaryBits = 10
    private static let primaryCount = 1 << primaryBits
    private static let lookupBits = 15
    private static let lengthCount = lookupBits + 1
    private let primary: UnsafeMutablePointer<UInt32>
    private let metadata: UnsafeMutablePointer<Int>
    private let counts: UnsafeMutablePointer<Int>
    private let firstCodes: UnsafeMutablePointer<Int>
    private let symbolOffsets: UnsafeMutablePointer<Int>
    private let nextCodes: UnsafeMutablePointer<Int>
    private var symbols: UnsafeMutablePointer<UInt32>
    private var symbolCapacity = 306
    private var maximumLength = 0

    init() {
        primary = .allocate(capacity: Self.primaryCount)
        metadata = .allocate(capacity: Self.lengthCount * 4)
        counts = metadata
        firstCodes = metadata.advanced(by: Self.lengthCount)
        symbolOffsets = metadata.advanced(by: Self.lengthCount * 2)
        nextCodes = metadata.advanced(by: Self.lengthCount * 3)
        symbols = .allocate(capacity: symbolCapacity)
        // A table may be queried before its first build (an absent optional
        // alphabet). decode must still return nil in that case.
        primary.initialize(repeating: 0, count: Self.primaryCount)
    }

    deinit {
        primary.deallocate()
        metadata.deallocate()
        symbols.deallocate()
    }

    func build(
        lengths: UnsafePointer<UInt8>,
        count: Int,
        requireSymbol: Bool
    ) throws {
        metadata.update(repeating: 0, count: Self.lengthCount * 4)
        maximumLength = 0
        var symbolCount = 0
        var longest = 0
        for index in 0..<count {
            let length = Int(lengths[index])
            guard length <= Self.lookupBits else {
                throw KaitoError.malformed("RAR5 Huffman length exceeds 15")
            }
            if length > 0 {
                counts[length] += 1
                symbolCount += 1
                longest = max(longest, length)
            }
        }
        if requireSymbol, symbolCount == 0 {
            throw KaitoError.malformed("RAR5 Huffman table is empty")
        }
        guard symbolCount > 0 else {
            primary.update(repeating: 0, count: Self.primaryCount)
            return
        }

        var code = 0
        var offset = 0
        for length in 1...Self.lookupBits {
            let (sum, overflow) = code.addingReportingOverflow(counts[length - 1])
            guard !overflow else { throw KaitoError.malformed("RAR5 Huffman count overflow") }
            let (shifted, shiftOverflow) = sum.multipliedReportingOverflow(by: 2)
            guard !shiftOverflow, shifted <= 1 << length else {
                throw KaitoError.malformed("RAR5 Huffman table is oversubscribed")
            }
            code = shifted
            firstCodes[length] = code
            nextCodes[length] = code
            symbolOffsets[length] = offset
            offset += counts[length]
        }
        if symbolCount > symbolCapacity {
            symbols.deallocate()
            symbolCapacity = symbolCount
            symbols = .allocate(capacity: symbolCapacity)
        }

        // Canonical codes occupy a contiguous prefix of the quick table, so
        // only the slots past the last short code must be cleared.
        var primaryFilled = 0
        for symbol in 0..<count {
            let length = Int(lengths[symbol])
            guard length > 0 else { continue }
            let prefix = nextCodes[length]
            nextCodes[length] += 1
            guard nextCodes[length] <= 1 << length else {
                throw KaitoError.malformed("RAR5 Huffman code is oversubscribed")
            }
            let repetitions = 1 << (Self.lookupBits - length)
            let start = prefix << (Self.lookupBits - length)
            guard start >= 0, repetitions <= (1 << Self.lookupBits) - start else {
                throw KaitoError.malformed("RAR5 Huffman lookup range is invalid")
            }
            let entry = UInt32(length << 16 | symbol)
            symbols[symbolOffsets[length] + prefix - firstCodes[length]] = entry
            if length <= Self.primaryBits {
                let primaryStart = prefix << (Self.primaryBits - length)
                let primaryRepetitions = 1 << (Self.primaryBits - length)
                primary.advanced(by: primaryStart).update(
                    repeating: entry, count: primaryRepetitions
                )
                primaryFilled = max(primaryFilled, primaryStart + primaryRepetitions)
            }
        }
        if primaryFilled < Self.primaryCount {
            primary.advanced(by: primaryFilled).update(
                repeating: 0, count: Self.primaryCount - primaryFilled
            )
        }
        maximumLength = longest
    }

    @inline(__always)
    func decode(from bits: inout RAR5RawBitReader) -> Int? {
        guard bits.bitPosition < bits.bitLimit else { return nil }
        let prefix = bits.peekPadded(Self.lookupBits)
        var entry = primary[prefix >> (Self.lookupBits - Self.primaryBits)]
        if entry == 0 {
            guard maximumLength > Self.primaryBits else { return nil }
            for length in (Self.primaryBits + 1)...maximumLength {
                let index = (prefix >> (Self.lookupBits - length)) - firstCodes[length]
                if index >= 0, index < counts[length] {
                    entry = symbols[symbolOffsets[length] + index]
                    break
                }
            }
        }
        let length = Int(entry >> 16)
        guard length > 0, length <= bits.bitLimit - bits.bitPosition else { return nil }
        bits.bitPosition += length
        return Int(entry & 0xffff)
    }
}


/// Copies a validated LZ match inside the power-of-two ring: `count` bytes
/// from `distance` behind `position`, with both ends wrapping independently.
///
/// A source that wrapped to the ring end lies ahead of the destination and
/// never overlaps it within one run, so a plain copy is exact. Otherwise the
/// source is behind the destination: distances of eight or more move whole
/// words whose reads all precede the word being written, keeping forward LZ
/// semantics for repeating matches, and shorter distances expand the period
/// bytewise until a word-sized multiple of it exists, then continue with words.
@inline(__always)
func copyMatchWithinWindow(
    window: UnsafeMutablePointer<UInt8>,
    windowMask: Int,
    position: inout Int,
    distance: Int,
    count: Int
) {
    let windowCount = windowMask &+ 1
    var destination = position
    var remaining = count
    while remaining > 0 {
        let source = (destination &- distance) & windowMask
        let run = min(remaining, windowCount &- max(destination, source))
        let to = window.advanced(by: destination)
        let from = window.advanced(by: source)
        if source >= destination {
            // Wrapped (or distance == window) source: non-overlapping within
            // this run, and distance == window copies a byte onto itself.
            to.update(from: from, count: run)
        } else if distance >= 8 {
            copyForwardWords(to: to, from: from, count: run)
        } else {
            let stride = distance &* ((8 &+ distance &- 1) / distance)
            let prefix = min(run, stride)
            for index in 0..<prefix {
                to[index] = to[index &- distance]
            }
            if prefix < run {
                copyForwardWords(
                    to: to.advanced(by: prefix),
                    from: to.advanced(by: prefix &- stride),
                    count: run &- prefix
                )
            }
        }
        destination = (destination &+ run) & windowMask
        remaining &-= run
    }
    position = destination
}

/// Word-granular forward copy where `from` is at least eight bytes before
/// `to`. The tail is copied as one word ending at `count`; its source bytes
/// precede the tail store, so re-reading bytes this copy already wrote keeps
/// the forward semantics.
@inline(__always)
private func copyForwardWords(
    to: UnsafeMutablePointer<UInt8>,
    from: UnsafeMutablePointer<UInt8>,
    count: Int
) {
    var index = 0
    while index &+ 8 <= count {
        UnsafeMutableRawPointer(to.advanced(by: index)).storeBytes(
            of: UnsafeRawPointer(from.advanced(by: index)).loadUnaligned(as: UInt64.self),
            as: UInt64.self
        )
        index &+= 8
    }
    if index < count {
        if count >= 8 {
            let tail = count &- 8
            UnsafeMutableRawPointer(to.advanced(by: tail)).storeBytes(
                of: UnsafeRawPointer(from.advanced(by: tail)).loadUnaligned(as: UInt64.self),
                as: UInt64.self
            )
        } else {
            while index < count {
                to[index] = from[index]
                index &+= 1
            }
        }
    }
}
