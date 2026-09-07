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
/// This implementation accepts `UNP_VER == 29` streams. LZ and PPMd-H blocks,
/// their in-stream transitions, native standard RARVM filters, PPMd's embedded
/// LZ matches, and reader-coordinated solid continuation are supported. Custom
/// VM programs are rejected at the exact feature that introduces them, so
/// unsupported data can never be confused with successfully decoded output.
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
        case limitExceeded(String)
    }

    private enum BlockMode {
        case lz
        case ppmd
    }

    private enum PPMdToken {
        case literal(UInt8)
        case match(distance: Int, length: Int)
        case filter(ScheduledFilter)
        case endBlock
        case endFile
    }

    fileprivate struct StoredFilterProgram {
        let kind: RARStandardFilterKind
        var previousLength: Int
        var usageCount: UInt32
    }

    private struct ScheduledFilter {
        let start: UInt64
        let length: Int
        let kind: RARStandardFilterKind
        let registers: [UInt32]

        var end: UInt64 { start + UInt64(length) }
    }

    /// Compression state carried between members of one RAR3 solid group.
    /// Packed bytes, range/bit cursors, output counters, pending matches and
    /// scheduled filter ranges remain owned by each file decoder.  A reader
    /// coordinator hands this object to only one live decoder at a time.
    final class SolidState {
        let window: UnsafeMutablePointer<UInt8>
        let windowSize: Int
        let windowMask: Int

        fileprivate let mainTable = RAR29HuffmanTable()
        fileprivate let distanceTable = RAR29HuffmanTable()
        fileprivate let lowDistanceTable = RAR29HuffmanTable()
        fileprivate let lengthTable = RAR29HuffmanTable()
        fileprivate var previousLengths = [UInt8](
            repeating: 0,
            count: RAR29Decoder.combinedLengthCount
        )

        fileprivate var windowPosition = 0
        fileprivate var historySize = 0
        fileprivate var oldOffset0 = 0
        fileprivate var oldOffset1 = 0
        fileprivate var oldOffset2 = 0
        fileprivate var oldOffset3 = 0
        fileprivate var lastOffset = 0
        fileprivate var lastLength = 0
        fileprivate var lastLowOffset = 0
        fileprivate var lowOffsetRepeatCount = 0
        fileprivate var filterPrograms: [StoredFilterProgram] = []
        fileprivate var lastFilterProgram = 0
        fileprivate var ppmdModel: PPMd7Model?
        fileprivate var ppmdEscape: UInt8 = 2
        fileprivate var tablesWereRead = false
        fileprivate var nextFileRequiresTables = true
        fileprivate var continuationReady = false

        init(dictionarySize: UInt64) throws {
            let size = try Checked.toInt(dictionarySize)
            guard size > 0, size.nonzeroBitCount == 1 else {
                throw KaitoError.malformed("RAR4 dictionary is not a power of two")
            }
            guard let raw = malloc(size) else {
                throw KaitoError.limitExceeded("unable to allocate RAR4 dictionary")
            }
            window = raw.bindMemory(to: UInt8.self, capacity: size)
            windowSize = size
            windowMask = size - 1
            window.initialize(repeating: 0, count: size)
        }

        deinit {
            window.deinitialize(count: windowSize)
            free(UnsafeMutableRawPointer(window))
        }

        fileprivate func advanceWindow() {
            windowPosition = (windowPosition + 1) & windowMask
            if historySize < windowSize { historySize += 1 }
        }

        fileprivate func appendHistory(_ count: Int) {
            historySize = count >= windowSize - historySize
                ? windowSize
                : historySize + count
        }
    }

    private let input: UnsafeMutablePointer<UInt8>
    private let inputCount: Int
    private let solidState: SolidState
    private let expectedSize: UInt64
    private let maximumFilterCount: Int
    private let maximumPPMdMemorySize: UInt64

    private let levelTable = RAR29HuffmanTable()

    private var bitOffset = 0
    private var produced: UInt64 = 0
    private var emitted: UInt64 = 0
    private var pendingDistance = 0
    private var pendingLength = 0
    private var scheduledFilters: [ScheduledFilter] = []
    private var nextFilterIndex = 0
    private var filterCapture: [UInt8] = []
    private var filterCaptureStart: UInt64?
    private var filteredOutput: [UInt8] = []
    private var filteredOutputIndex = 0
    private var blockMode: BlockMode = .lz
    private var ppmdRangeDecoder: RARPPMdRangeDecoder?
    private var needsInitialTables: Bool
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
        limits: ReadLimits,
        solidState suppliedSolidState: SolidState? = nil
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

        let state: SolidState
        do {
            if let suppliedSolidState {
                guard suppliedSolidState.windowSize == dictionaryCount else {
                    throw KaitoError.malformed(
                        "RAR4 solid dictionary size changes within a group"
                    )
                }
                if isSolid {
                    guard suppliedSolidState.continuationReady else {
                        throw KaitoError.malformed(
                            "RAR4 solid continuation has no completed predecessor"
                        )
                    }
                }
                state = suppliedSolidState
            } else {
                guard !isSolid else {
                    throw KaitoError.unsupportedMethod(
                        "RAR4 solid continuation requires shared state"
                    )
                }
                state = try SolidState(dictionarySize: dictionarySize)
            }
        } catch {
            free(inputRaw)
            throw error
        }

        self.inputCount = compressedCount
        self.expectedSize = uncompressedSize
        self.solidState = state
        self.maximumFilterCount = limits.maxMetadataRecordCount
        self.maximumPPMdMemorySize = limits.maxDictionarySize
        self.input = inputRaw.bindMemory(to: UInt8.self, capacity: inputAllocationCount)
        self.needsInitialTables = !isSolid || state.nextFileRequiresTables
        if isSolid { state.continuationReady = false }
        self.input.initialize(
            repeating: 0,
            count: inputAllocationCount
        )

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
            // here as well would release the packed buffer twice.
            throw error
        }
    }

    deinit {
        input.deinitialize(count: inputCount + Self.sentinelByteCount)
        free(UnsafeMutableRawPointer(input))
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
        } else if blockMode == .lz && !solidState.tablesWereRead {
            let failure = DecodeFailure.malformed(
                "RAR4 solid continuation has no reusable Huffman tables"
            )
            terminalFailure = failure
            throw error(for: failure)
        }

        // All frequently touched decoder state is local for the symbol loop.
        var outputCount = 0
        var outputPosition = produced
        var repeat0 = solidState.oldOffset0
        var repeat1 = solidState.oldOffset1
        var repeat2 = solidState.oldOffset2
        var repeat3 = solidState.oldOffset3
        var recentOffset = solidState.lastOffset
        var recentLength = solidState.lastLength
        var lowOffset = solidState.lastLowOffset
        var lowRepeats = solidState.lowOffsetRepeatCount
        var matchDistance = pendingDistance
        var matchRemaining = pendingLength
        var reachedEnd = false
        var nextFileRequiresTables = true
        var failure: DecodeFailure?

        while outputCount < buffer.count, !reachedEnd, failure == nil {
            if filteredOutputIndex < filteredOutput.count {
                let count = min(
                    filteredOutput.count - filteredOutputIndex,
                    buffer.count - outputCount
                )
                filteredOutput.withUnsafeBytes { source in
                    UnsafeMutableRawPointer(destination.advanced(by: outputCount)).copyMemory(
                        from: source.baseAddress!.advanced(by: filteredOutputIndex),
                        byteCount: count
                    )
                }
                filteredOutputIndex += count
                outputCount += count
                emitted += UInt64(count)
                if filteredOutputIndex == filteredOutput.count {
                    filteredOutput.removeAll(keepingCapacity: true)
                    filteredOutputIndex = 0
                }
                continue
            }

            if let captureStart = filterCaptureStart,
               nextFilterIndex < scheduledFilters.count {
                let filter = scheduledFilters[nextFilterIndex]
                guard filter.start == captureStart,
                      filterCapture.count <= filter.length else {
                    failure = .malformed("RAR3 filter capture state is inconsistent")
                    break
                }
                if filterCapture.count == filter.length {
                    do {
                        try prepareCapturedFilters(start: captureStart)
                    } catch let kaito as KaitoError {
                        failure = decodeFailure(from: kaito)
                    } catch {
                        failure = .malformed("RAR3 standard filter failed")
                    }
                    continue
                }
            }

            if filterCaptureStart == nil,
               nextFilterIndex < scheduledFilters.count {
                let filter = scheduledFilters[nextFilterIndex]
                guard outputPosition <= filter.start else {
                    failure = .malformed("RAR3 filter starts behind raw output")
                    break
                }
                if outputPosition == filter.start {
                    guard emitted == filter.start else {
                        failure = .malformed("RAR3 raw and emitted positions diverged")
                        break
                    }
                    filterCaptureStart = filter.start
                    filterCapture.removeAll(keepingCapacity: true)
                    filterCapture.reserveCapacity(filter.length)
                    continue
                }
            }

            if matchRemaining > 0 {
                if let captureStart = filterCaptureStart {
                    let filter = scheduledFilters[nextFilterIndex]
                    guard filter.start == captureStart else {
                        failure = .malformed("RAR3 filter capture lost its descriptor")
                        break
                    }
                    copyMatchToFilter(
                        distance: matchDistance,
                        remaining: &matchRemaining,
                        maximumCount: filter.length - filterCapture.count,
                        outputPosition: &outputPosition
                    )
                } else {
                    var outputCapacity = buffer.count
                    if nextFilterIndex < scheduledFilters.count {
                        let filterStart = scheduledFilters[nextFilterIndex].start
                        let distanceToFilter = filterStart - outputPosition
                        outputCapacity = min(
                            outputCapacity,
                            outputCount + Int(min(distanceToFilter, UInt64(Int.max)))
                        )
                    }
                    let previousCount = outputCount
                    copyMatchChunk(
                        distance: matchDistance,
                        remaining: &matchRemaining,
                        output: destination,
                        outputCount: &outputCount,
                        outputCapacity: outputCapacity,
                        outputPosition: &outputPosition
                    )
                    emitted += UInt64(outputCount - previousCount)
                }
                continue
            }

            if blockMode == .ppmd {
                do {
                    switch try nextPPMdToken(outputPosition: outputPosition) {
                    case let .literal(byte):
                        guard outputPosition < expectedSize else {
                            failure = .malformed("RAR4 PPMd output exceeds its declared size")
                            continue
                        }
                        solidState.window[solidState.windowPosition] = byte
                        solidState.advanceWindow()
                        if filterCaptureStart != nil {
                            filterCapture.append(byte)
                        } else {
                            destination[outputCount] = byte
                            outputCount += 1
                            emitted += 1
                        }
                        outputPosition += 1

                    case let .match(distance, length):
                        guard distance > 0,
                              distance <= solidState.windowSize,
                              distance <= solidState.historySize else {
                            failure = .malformed("RAR4 PPMd match distance is outside the window")
                            continue
                        }
                        guard length > 0,
                              outputPosition <= expectedSize,
                              UInt64(length) <= expectedSize - outputPosition else {
                            failure = .malformed("RAR4 PPMd match exceeds the declared output size")
                            continue
                        }
                        // PPMd escape matches feed the shared LZ window but do
                        // not alter OldDist or the LZ last-match cache.
                        matchDistance = distance
                        matchRemaining = length

                    case let .filter(filter):
                        try schedule(filter: filter)

                    case .endBlock:
                        guard let rangeDecoder = ppmdRangeDecoder else {
                            throw KaitoError.malformed("RAR4 PPMd range state is missing")
                        }
                        bits.bitOffset = try Self.bitOffset(forByteOffset: rangeDecoder.byteOffset)
                        ppmdRangeDecoder = nil
                        try readTables(bits: &bits)
                        lowOffset = 0
                        lowRepeats = 0

                    case .endFile:
                        reachedEnd = true
                    }
                } catch let kaito as KaitoError {
                    failure = decodeFailure(from: kaito)
                } catch {
                    failure = .malformed("RAR4 PPMd token is invalid")
                }
                continue
            }

            let symbol = solidState.mainTable.decode(bits: &bits)
            if symbol < 0 {
                failure = .malformed("invalid RAR4 main Huffman code")
                break
            }
            if symbol < 256 {
                guard outputPosition < expectedSize else {
                    failure = .malformed("RAR4 output exceeds its declared size")
                    break
                }
                let byte = UInt8(truncatingIfNeeded: symbol)
                solidState.window[solidState.windowPosition] = byte
                solidState.advanceWindow()
                if filterCaptureStart != nil {
                    filterCapture.append(byte)
                } else {
                    destination[outputCount] = byte
                    outputCount += 1
                    emitted += 1
                }
                outputPosition += 1
                continue
            }

            var distance = 0
            var length = 0
            switch symbol {
            case 256:
                if bits.read(1) == 0 {
                    nextFileRequiresTables = bits.read(1) != 0
                    reachedEnd = true
                } else {
                    do {
                        try readTables(bits: &bits)
                        // readTables starts a new low-distance code run.  The
                        // hot-loop copies of this state must be reset as well;
                        // otherwise a table switch can reuse a low nibble from
                        // the preceding block.
                        lowOffset = 0
                        lowRepeats = 0
                    } catch let kaito as KaitoError {
                        failure = decodeFailure(from: kaito)
                    } catch {
                        failure = .malformed("RAR4 table rebuild failed")
                    }
                }
                continue

            case 257:
                do {
                    let filter = try readFilter(
                        bits: &bits,
                        outputPosition: outputPosition
                    )
                    try schedule(filter: filter)
                } catch let kaito as KaitoError {
                    failure = decodeFailure(from: kaito)
                } catch {
                    failure = .malformed("RAR3 filter descriptor is invalid")
                }
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
                let lengthSlot = solidState.lengthTable.decode(bits: &bits)
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

                let distanceSlot = solidState.distanceTable.decode(bits: &bits)
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
                            let lowSymbol = solidState.lowDistanceTable.decode(bits: &bits)
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
                  distance <= solidState.windowSize,
                  distance <= solidState.historySize else {
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

        if let rangeDecoder = ppmdRangeDecoder {
            do {
                bits.bitOffset = try Self.bitOffset(forByteOffset: rangeDecoder.byteOffset)
            } catch let kaito as KaitoError {
                failure = decodeFailure(from: kaito)
            } catch {
                failure = .malformed("RAR4 PPMd cursor overflow")
            }
        }
        bitOffset = bits.bitOffset
        produced = outputPosition
        solidState.oldOffset0 = repeat0
        solidState.oldOffset1 = repeat1
        solidState.oldOffset2 = repeat2
        solidState.oldOffset3 = repeat3
        solidState.lastOffset = recentOffset
        solidState.lastLength = recentLength
        solidState.lastLowOffset = lowOffset
        solidState.lowOffsetRepeatCount = lowRepeats
        pendingDistance = matchDistance
        pendingLength = matchRemaining

        if bits.overrun, failure == nil {
            failure = .truncated
        }
        if reachedEnd {
            guard outputPosition == expectedSize,
                  emitted == expectedSize,
                  matchRemaining == 0,
                  filterCaptureStart == nil,
                  filteredOutput.isEmpty,
                  nextFilterIndex == scheduledFilters.count else {
                failure = .truncated
                terminalFailure = failure
                throw KaitoError.truncated
            }
            solidState.nextFileRequiresTables = nextFileRequiresTables
            solidState.continuationReady = true
            finished = true
        }
        if let failure {
            terminalFailure = failure
            throw error(for: failure)
        }
        return outputCount
    }

    private func nextPPMdToken(outputPosition: UInt64) throws -> PPMdToken {
        let byte = try decodePPMdByte()
        guard byte == solidState.ppmdEscape else { return .literal(byte) }

        let action = try decodePPMdByte()
        switch action {
        case 0:
            return .endBlock
        case 1:
            return .literal(solidState.ppmdEscape)
        case 2:
            return .endFile
        case 3:
            return .filter(try readPPMdFilter(outputPosition: outputPosition))
        case 4:
            // RAR stores a big-endian 24-bit value biased by two, followed by
            // a one-byte match length biased by 32.
            var storedDistance = 0
            for _ in 0..<3 {
                storedDistance = (storedDistance << 8) | Int(try decodePPMdByte())
            }
            let length = Int(try decodePPMdByte()) + 32
            return .match(distance: storedDistance + 2, length: length)
        case 5:
            return .match(distance: 1, length: Int(try decodePPMdByte()) + 4)
        default:
            return .literal(solidState.ppmdEscape)
        }
    }

    private func decodePPMdByte() throws -> UInt8 {
        guard let model = solidState.ppmdModel,
              let rangeDecoder = ppmdRangeDecoder else {
            throw KaitoError.malformed("RAR4 PPMd model state is missing")
        }
        return try model.decodeByte(using: rangeDecoder)
    }

    private func readPPMdFilter(outputPosition: UInt64) throws -> ScheduledFilter {
        guard scheduledFilters.count < maximumFilterCount else {
            throw KaitoError.limitExceeded("RAR3 filter count")
        }

        let flags = try decodePPMdByte()
        var payloadLength = Int(flags & 0x07) + 1
        if payloadLength == 7 {
            payloadLength = Int(try decodePPMdByte()) + 7
        } else if payloadLength == 8 {
            payloadLength = Int(try decodePPMdByte()) << 8
            payloadLength |= Int(try decodePPMdByte())
        }
        guard payloadLength > 0 else {
            throw KaitoError.malformed("RAR3 PPMd filter payload is empty")
        }

        var payload = [UInt8]()
        payload.reserveCapacity(payloadLength)
        for _ in 0..<payloadLength {
            payload.append(try decodePPMdByte())
        }
        return try parseFilterPayload(
            payload,
            flags: flags,
            outputPosition: outputPosition
        )
    }

    private func beginPPMdBlock(bits: inout RAR29RawBitCursor) throws {
        guard bits.bitOffset >= 0, bits.bitOffset.isMultiple(of: 8) else {
            throw KaitoError.malformed("RAR4 PPMd block is not byte aligned")
        }
        var byteOffset = bits.bitOffset >> 3
        let header = try readPackedByte(at: &byteOffset)
        guard header & 0x80 != 0 else {
            throw KaitoError.malformed("RAR4 PPMd block lacks its mode flag")
        }

        let resetsModel = header & 0x20 != 0
        var replacementModel: PPMd7Model?
        if resetsModel {
            let storedMemory = try readPackedByte(at: &byteOffset)
            let memorySize = UInt64(Int(storedMemory) + 1) * 1_024 * 1_024
            try Checked.size(memorySize, limit: maximumPPMdMemorySize)

            let storedOrder = Int(header & 0x1f) + 1
            let order = storedOrder > 16
                ? 16 + (storedOrder - 16) * 3
                : storedOrder
            guard (2...64).contains(order) else {
                throw KaitoError.malformed("RAR4 PPMd order is outside 2...64")
            }
            replacementModel = try PPMd7Model(
                maximumOrder: order,
                memorySize: memorySize
            )
        } else {
            guard solidState.ppmdModel != nil else {
                throw KaitoError.malformed("RAR4 PPMd continuation has no model")
            }
        }

        if header & 0x40 != 0 {
            solidState.ppmdEscape = try readPackedByte(at: &byteOffset)
        }
        guard byteOffset <= inputCount, inputCount - byteOffset >= 4 else {
            throw KaitoError.truncated
        }

        let rangeDecoder = try RARPPMdRangeDecoder(
            bytes: UnsafePointer(input),
            byteCount: inputCount,
            byteOffset: byteOffset
        )
        if let replacementModel {
            solidState.ppmdModel = replacementModel
        }
        ppmdRangeDecoder = rangeDecoder
        blockMode = .ppmd
        bits.bitOffset = try Self.bitOffset(forByteOffset: rangeDecoder.byteOffset)
    }

    private func readPackedByte(at byteOffset: inout Int) throws -> UInt8 {
        guard byteOffset >= 0, byteOffset < inputCount else {
            throw KaitoError.truncated
        }
        let result = input[byteOffset]
        byteOffset += 1
        return result
    }

    private static func bitOffset(forByteOffset byteOffset: Int) throws -> Int {
        guard byteOffset >= 0, byteOffset <= Int.max / 8 else {
            throw KaitoError.limitExceeded("RAR4 PPMd input position")
        }
        return byteOffset * 8
    }

    private func readFilter(
        bits: inout RAR29RawBitCursor,
        outputPosition: UInt64
    ) throws -> ScheduledFilter {
        guard scheduledFilters.count < maximumFilterCount else {
            throw KaitoError.limitExceeded("RAR3 filter count")
        }

        let flags = UInt8(truncatingIfNeeded: bits.read(8))
        guard !bits.overrun else { throw KaitoError.truncated }
        var payloadLength = Int(flags & 0x07) + 1
        if payloadLength == 7 {
            payloadLength = Int(bits.read(8)) + 7
        } else if payloadLength == 8 {
            payloadLength = Int(bits.read(8)) << 8
            payloadLength |= Int(bits.read(8))
        }
        guard !bits.overrun else { throw KaitoError.truncated }
        guard payloadLength > 0 else {
            throw KaitoError.malformed("RAR3 filter payload is empty")
        }

        var payload = [UInt8]()
        payload.reserveCapacity(payloadLength)
        for _ in 0..<payloadLength {
            payload.append(UInt8(truncatingIfNeeded: bits.read(8)))
        }
        guard !bits.overrun else { throw KaitoError.truncated }
        return try parseFilterPayload(
            payload,
            flags: flags,
            outputPosition: outputPosition
        )
    }

    private func parseFilterPayload(
        _ payload: [UInt8],
        flags: UInt8,
        outputPosition: UInt64
    ) throws -> ScheduledFilter {
        var cursor = RAR3MemoryBitCursor(bytes: payload)
        var programIndex = solidState.lastFilterProgram
        if flags & 0x80 != 0 {
            let storedNumber = try cursor.readRARVMNumber()
            if storedNumber == 0 {
                guard filterCaptureStart == nil, filteredOutput.isEmpty else {
                    throw KaitoError.malformed(
                        "RAR3 filter program reset interrupts an active filter"
                    )
                }
                solidState.filterPrograms.removeAll(keepingCapacity: true)
                if nextFilterIndex < scheduledFilters.count {
                    scheduledFilters.removeSubrange(nextFilterIndex...)
                }
                programIndex = 0
            } else {
                guard let exactIndex = Int(exactly: storedNumber - 1) else {
                    throw KaitoError.malformed("RAR3 filter program number is too large")
                }
                programIndex = exactIndex
            }
            guard programIndex <= solidState.filterPrograms.count else {
                throw KaitoError.malformed("RAR3 filter program number is invalid")
            }
            solidState.lastFilterProgram = programIndex
        } else {
            guard programIndex <= solidState.filterPrograms.count else {
                throw KaitoError.malformed("RAR3 previous filter program is unavailable")
            }
        }

        let storedStart = try cursor.readRARVMNumber()
        guard storedStart & 0x8000_0000 == 0 else {
            throw KaitoError.malformed("RAR3 filter start is negative")
        }
        var relativeStart = UInt64(storedStart)
        if flags & 0x40 != 0 {
            relativeStart = try Checked.add(relativeStart, 258)
        }
        let start = try Checked.add(outputPosition, relativeStart)

        let isNewProgram = programIndex == solidState.filterPrograms.count
        let blockLength: Int
        if flags & 0x20 != 0 {
            let storedLength = try cursor.readRARVMNumber()
            guard let exactLength = Int(exactly: storedLength) else {
                throw KaitoError.malformed("RAR3 filter length is too large")
            }
            blockLength = exactLength
        } else {
            guard !isNewProgram else {
                throw KaitoError.malformed("new RAR3 filter omits its block length")
            }
            blockLength = solidState.filterPrograms[programIndex].previousLength
        }
        guard blockLength > 0,
              blockLength <= solidState.windowSize,
              blockLength <= RARStandardFilters.rar3WorkAreaSize else {
            throw KaitoError.malformed("RAR3 filter length is outside its work area")
        }

        let usageCount: UInt32
        if isNewProgram {
            usageCount = 0
        } else {
            let (incremented, overflow) = solidState.filterPrograms[programIndex]
                .usageCount.addingReportingOverflow(1)
            guard !overflow else {
                throw KaitoError.limitExceeded("RAR3 filter usage count")
            }
            usageCount = incremented
        }
        var registers = [UInt32](repeating: 0, count: 8)
        registers[3] = UInt32(RARStandardFilters.rar3WorkAreaSize)
        registers[4] = UInt32(blockLength)
        registers[5] = usageCount
        registers[7] = UInt32(RARStandardFilters.rar3VirtualMemorySize)

        if flags & 0x10 != 0 {
            let mask = try cursor.read(7)
            for register in 0..<7 where mask & UInt32(1 << register) != 0 {
                registers[register] = try cursor.readRARVMNumber()
            }
        }

        let kind: RARStandardFilterKind
        if isNewProgram {
            let storedBytecodeLength = try cursor.readRARVMNumber()
            guard let bytecodeLength = Int(exactly: storedBytecodeLength),
                  (1...65_536).contains(bytecodeLength),
                  bytecodeLength <= cursor.remainingByteCapacity else {
                throw KaitoError.malformed("RAR3 VM bytecode length is invalid")
            }
            var bytecode = [UInt8]()
            bytecode.reserveCapacity(bytecodeLength)
            for _ in 0..<bytecodeLength {
                bytecode.append(UInt8(truncatingIfNeeded: try cursor.read(8)))
            }
            guard let checksum = bytecode.first,
                  bytecode.dropFirst().reduce(UInt8(0), ^) == checksum else {
                throw KaitoError.malformed("RAR3 VM bytecode checksum mismatch")
            }
            kind = try RARStandardFilters.requireRAR3Program(bytecode)
            guard solidState.filterPrograms.count < maximumFilterCount else {
                throw KaitoError.limitExceeded("RAR3 filter program count")
            }
            solidState.filterPrograms.append(StoredFilterProgram(
                kind: kind,
                previousLength: blockLength,
                usageCount: usageCount
            ))
        } else {
            kind = solidState.filterPrograms[programIndex].kind
            solidState.filterPrograms[programIndex].previousLength = blockLength
            solidState.filterPrograms[programIndex].usageCount = usageCount
        }

        if flags & 0x08 != 0 {
            let storedGlobalLength = try cursor.readRARVMNumber()
            guard let globalLength = Int(exactly: storedGlobalLength),
                  globalLength <= 0x1FC0,
                  globalLength <= cursor.remainingByteCapacity else {
                throw KaitoError.malformed("RAR3 filter global data is invalid")
            }
            for _ in 0..<globalLength {
                _ = try cursor.read(8)
            }
        }

        // Native standard filters are size preserving. R3/R4/R5/R6 are VM
        // execution state supplied by the decoder; accepting altered values
        // would silently change a recognized program's semantics.
        guard registers[3] == UInt32(RARStandardFilters.rar3WorkAreaSize),
              registers[4] == UInt32(blockLength),
              registers[5] == usageCount,
              registers[6] == 0 else {
            throw KaitoError.unsupportedMethod("RAR3 custom VM filter registers")
        }

        switch kind {
        case .delta, .rgb, .audio:
            guard blockLength <= RARStandardFilters.rar3WorkAreaSize / 2 else {
                throw KaitoError.malformed("RAR3 filter output exceeds its work area")
            }
        case .e8, .e8e9:
            guard blockLength > 4 else {
                throw KaitoError.malformed("RAR3 x86 filter block is too short")
            }
        case .itanium:
            break
        case .arm:
            throw KaitoError.unsupportedMethod("RAR3 ARM filter")
        }

        let end = try Checked.add(start, UInt64(blockLength))
        guard end <= expectedSize else {
            throw KaitoError.malformed("RAR3 filter range exceeds output")
        }
        return ScheduledFilter(
            start: start,
            length: blockLength,
            kind: kind,
            registers: registers
        )
    }

    private func schedule(filter: ScheduledFilter) throws {
        if let previous = scheduledFilters.last {
            if filter.start == previous.start {
                guard filter.length == previous.length else {
                    throw KaitoError.malformed("stacked RAR3 filters have unequal ranges")
                }
            } else {
                guard filter.start >= previous.end else {
                    throw KaitoError.malformed("RAR3 filter ranges overlap or are out of order")
                }
            }
        }
        scheduledFilters.append(filter)
    }

    private func prepareCapturedFilters(start: UInt64) throws {
        guard filteredOutput.isEmpty,
              filterCaptureStart == start,
              nextFilterIndex < scheduledFilters.count else {
            throw KaitoError.malformed("RAR3 filter output state is inconsistent")
        }
        var bytes = filterCapture
        var index = nextFilterIndex
        repeat {
            let filter = scheduledFilters[index]
            guard filter.start == start, filter.length == bytes.count else {
                throw KaitoError.malformed("RAR3 stacked filter range is inconsistent")
            }
            try RARStandardFilters.apply(
                filter.kind,
                to: &bytes,
                fileOffset: start,
                channels: Int(filter.registers[0]),
                width: Int(filter.registers[0]),
                positionR: Int(filter.registers[1]),
                addressMode: .rar3
            )
            index += 1
        } while index < scheduledFilters.count
            && scheduledFilters[index].start == start

        filteredOutput = bytes
        filteredOutputIndex = 0
        filterCapture.removeAll(keepingCapacity: true)
        filterCaptureStart = nil
        nextFilterIndex = index
    }

    private func copyMatchToFilter(
        distance: Int,
        remaining: inout Int,
        maximumCount: Int,
        outputPosition: inout UInt64
    ) {
        let count = min(remaining, maximumCount)
        guard count > 0 else { return }
        for _ in 0..<count {
            let sourceOffset = (solidState.windowPosition - distance)
                & solidState.windowMask
            let byte = solidState.window[sourceOffset]
            solidState.window[solidState.windowPosition] = byte
            solidState.advanceWindow()
            filterCapture.append(byte)
            outputPosition += 1
            remaining -= 1
        }
    }

    private func readTables(bits: inout RAR29RawBitCursor) throws {
        bits.alignToByte()
        if bits.peek(1) != 0 {
            try beginPPMdBlock(bits: &bits)
            return
        }
        blockMode = .lz
        _ = bits.read(1)
        solidState.lastLowOffset = 0
        solidState.lowOffsetRepeatCount = 0
        let keepPrevious = bits.read(1) != 0
        if !keepPrevious {
            _ = solidState.previousLengths.withUnsafeMutableBytes { raw in
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
        while index < solidState.previousLengths.count {
            let symbol = levelTable.decode(bits: &bits)
            guard symbol >= 0 else {
                throw bits.overrun
                    ? KaitoError.truncated
                    : KaitoError.malformed("invalid RAR4 level Huffman code")
            }
            switch symbol {
            case 0...15:
                solidState.previousLengths[index] = UInt8(
                    (Int(solidState.previousLengths[index]) + symbol) & 0x0f
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
                guard run <= solidState.previousLengths.count - index else {
                    throw KaitoError.malformed(
                        "RAR4 length repeat exceeds the table"
                    )
                }
                let repeated = solidState.previousLengths[index - 1]
                for destination in index..<(index + run) {
                    solidState.previousLengths[destination] = repeated
                }
                index += run
            case 18, 19:
                let run = symbol == 18
                    ? Int(bits.read(3)) + 3
                    : Int(bits.read(7)) + 11
                guard run <= solidState.previousLengths.count - index else {
                    throw KaitoError.malformed(
                        "RAR4 zero run exceeds the length table"
                    )
                }
                solidState.previousLengths.withUnsafeMutableBufferPointer { lengths in
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
        try solidState.mainTable.build(solidState.previousLengths[0..<mainEnd])
        // A block can omit any subordinate alphabet it never references. Keep
        // such a table empty; attempting to decode it still yields an invalid
        // code at the exact token that would require it.
        try solidState.distanceTable.build(
            solidState.previousLengths[mainEnd..<distanceEnd],
            requireSymbol: false
        )
        try solidState.lowDistanceTable.build(
            solidState.previousLengths[distanceEnd..<lowEnd],
            requireSymbol: false
        )
        try solidState.lengthTable.build(
            solidState.previousLengths[lowEnd..<Self.combinedLengthCount],
            requireSymbol: false
        )
        solidState.tablesWereRead = true
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
        let destinationRing = solidState.windowPosition
        let sourceRing = (destinationRing - distance) & solidState.windowMask
        count = min(count, distance)
        if sourceRing + count <= solidState.windowSize {
            output.advanced(by: outputCount).update(
                from: solidState.window.advanced(by: sourceRing),
                count: count
            )
            let firstWindowPart = min(
                count,
                solidState.windowSize - destinationRing
            )
            solidState.window.advanced(by: destinationRing).update(
                from: output.advanced(by: outputCount),
                count: firstWindowPart
            )
            if firstWindowPart < count {
                solidState.window.update(
                    from: output.advanced(by: outputCount + firstWindowPart),
                    count: count - firstWindowPart
                )
            }
            solidState.windowPosition = (destinationRing + count)
                & solidState.windowMask
            solidState.appendHistory(count)
            outputCount += count
            outputPosition += UInt64(count)
            remaining -= count
            return
        }

        // Wrapped sources and true LZ overlap are copied in production order.
        for _ in 0..<count {
            let sourceOffset = (solidState.windowPosition - distance)
                & solidState.windowMask
            let byte = solidState.window[sourceOffset]
            solidState.window[solidState.windowPosition] = byte
            solidState.advanceWindow()
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
        case let .limitExceeded(reason):
            .limitExceeded(reason)
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
        case let .limitExceeded(reason):
            .limitExceeded(reason)
        }
    }
}

/// MSB-first bit cursor for the byte-bounded payload embedded in a RAR3
/// filter token. Unlike the sentinel-backed LZ cursor, every read is checked
/// against the descriptor's declared byte length.
private struct RAR3MemoryBitCursor {
    let bytes: [UInt8]
    private(set) var bitOffset = 0

    var remainingByteCapacity: Int {
        max(0, (bytes.count * 8 - bitOffset) / 8)
    }

    mutating func read(_ count: Int) throws -> UInt32 {
        guard (0...32).contains(count),
              bitOffset <= bytes.count * 8,
              count <= bytes.count * 8 - bitOffset else {
            throw KaitoError.malformed("RAR3 filter payload is truncated")
        }
        var value: UInt32 = 0
        for _ in 0..<count {
            let byte = bytes[bitOffset >> 3]
            let shift = 7 - (bitOffset & 7)
            value = value << 1 | UInt32(byte >> shift & 1)
            bitOffset += 1
        }
        return value
    }

    mutating func readRARVMNumber() throws -> UInt32 {
        switch try read(2) {
        case 0:
            return try read(4)
        case 1:
            let value = try read(8)
            if value >= 16 { return value }
            return 0xFFFF_FF00 | value << 4 | (try read(4))
        case 2:
            return try read(16)
        default:
            return try read(32)
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
final class RAR29HuffmanTable {
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

    func build(
        _ lengths: ArraySlice<UInt8>,
        requireSymbol: Bool = true
    ) throws {
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
        guard symbolCount > 0 || !requireSymbol else {
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

    fileprivate func decode(bits: inout RAR29RawBitCursor) -> Int {
        let record = lookup[Int(bits.peek(Self.maximumBits))]
        guard record != 0 else { return -1 }
        let bitCount = Int(record >> 16)
        bits.consume(bitCount)
        return Int(record & 0xffff) - 1
    }
}
