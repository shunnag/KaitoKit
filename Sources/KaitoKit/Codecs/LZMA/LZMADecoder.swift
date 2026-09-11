import Darwin
import Foundation

// 参照仕様: LZMA SDK の lzma-specification.txt。
// 確率モデルとレンジ復号器はストリームごとに保持し、出力全体は保持しない。

/// A streaming decoder for raw LZMA1 data.
///
/// The five property bytes contain `lc`, `lp`, `pb`, and the little-endian
/// dictionary size. The compressed range starts with the standard five-byte
/// LZMA range-coder initialization sequence.
public final class LZMADecoder: Decompressor {
    private static let outputChunkSize = 256 * 1_024
    private static let inputBufferSize = 256 * 1_024
    fileprivate static let maximumBytesPerSymbol = 64
    private static let matchBatchCapacity = 256
    fileprivate static let probabilityInitialValue: UInt16 = 1 << 10
    fileprivate static let maximumPositionStates = 1 << 4
    private static let maximumLZMA2LiteralProbabilities = 0x300 << 4

    private var rangeDecoder: LZMARangeDecoder?
    private var expectedSize: UInt64?
    private var literalContextBits: Int
    private var literalPositionBits: Int
    private var positionStateMask: UInt64
    private let literalProbabilityCapacity: Int

    // 全モデルは単一 allocation 内の固定 offset で参照する。構成値から求めた
    // literal model 末尾も allocation 前に検証され、hot loop は境界検査を反復しない。
    private let probabilities: UnsafeMutableBufferPointer<UInt16>

    // 不変条件: dictionaryPosition は常に 0..<dictionary.count。全参照距離は
    // dictionaryBytesAvailable と dictionary.count の両方で先に検証し、各添字は
    // count との明示的な比較で一度だけ ring wrap してから dereference する。
    private let dictionary: UnsafeMutableBufferPointer<UInt8>
    private let inputStorage: UnsafeMutableBufferPointer<UInt8>
    private let matchBatchStorage: UnsafeMutableBufferPointer<UInt64>
    private var dictionaryPosition = 0
    private var dictionaryBytesAvailable = 0
    private var previousByte: UInt8 = 0
    // literal/position context は dictionary reset からの連続出力位置を使う。
    // LZMA2 の coding-state reset だけではこの位置を巻き戻さない。
    private var processedPosition: UInt64 = 0
    private var outputPosition: UInt64 = 0

    private var state = 0
    // repN は実距離 - 1 を保持する。
    private var rep0: UInt32 = 0
    private var rep1: UInt32 = 0
    private var rep2: UInt32 = 0
    private var rep3: UInt32 = 0
    private var pendingMatchLength = 0
    private var finished = false

    /// Creates a raw LZMA1 decoder over a validated byte-source range.
    ///
    /// - Parameters:
    ///   - source: Source containing the compressed range.
    ///   - offset: Absolute offset of the LZMA range-coder bytes.
    ///   - compressedSize: Number of compressed range-coder bytes.
    ///   - properties: Exactly five LZMA1 property bytes.
    ///   - expectedSize: Known output size, or `nil` to require an end marker.
    ///   - dictionarySizeLimit: Maximum accepted dictionary allocation.
    public convenience init(
        source: any ByteSource,
        offset: UInt64,
        compressedSize: UInt64,
        properties: [UInt8],
        expectedSize: UInt64?,
        dictionarySizeLimit: UInt64
    ) throws {
        guard properties.count == 5 else {
            throw KaitoError.malformed("LZMA properties must contain five bytes")
        }
        let configuration = try LZMAProperties(
            packed: properties[0],
            requireLZMA2LiteralLimit: false
        )

        // LZMA1 は 4 KiB 未満の宣言値を最小辞書サイズへ正規化する。
        let declaredDictionarySize = UInt64(properties[1])
            | (UInt64(properties[2]) << 8)
            | (UInt64(properties[3]) << 16)
            | (UInt64(properties[4]) << 24)
        let effectiveDictionarySize = max(UInt64(4_096), declaredDictionarySize)
        try Checked.size(effectiveDictionarySize, limit: dictionarySizeLimit)
        // 既知の出力全体より古い byte を参照することはできないため、その場合は
        // 宣言辞書を全量確保せずに同じ復号結果を得られる。
        let retainedDictionarySize: UInt64
        if let expectedSize {
            retainedDictionarySize = min(
                effectiveDictionarySize,
                max(UInt64(1), expectedSize)
            )
        } else {
            retainedDictionarySize = effectiveDictionarySize
        }
        let compressedEnd = try Checked.add(offset, compressedSize)
        guard compressedEnd <= source.length else {
            throw KaitoError.truncated
        }
        let literalCount = try configuration.literalProbabilityCount()

        try self.init(
            configuration: configuration,
            retainedDictionarySize: retainedDictionarySize,
            expectedSize: expectedSize,
            literalProbabilityCapacity: literalCount
        )

        // 既知サイズ 0 でも range-coder 初期値を読み、空または切れた入力を受理しない。
        rangeDecoder = try LZMARangeDecoder(
            source: source,
            offset: offset,
            endOffset: compressedEnd,
            storage: inputStorage
        )
        if expectedSize == 0 {
            finished = true
        }
    }

    private init(
        configuration: LZMAProperties,
        retainedDictionarySize: UInt64,
        expectedSize: UInt64?,
        literalProbabilityCapacity: Int
    ) throws {
        let dictionaryCount = try Checked.toInt(retainedDictionarySize)
        guard dictionaryCount > 0 else {
            throw KaitoError.malformed("LZMA dictionary must not be empty")
        }
        let activeLiteralCount = try configuration.literalProbabilityCount()
        guard activeLiteralCount <= literalProbabilityCapacity else {
            throw KaitoError.malformed("LZMA literal model exceeds its allocation")
        }
        let probabilityCount = try Checked.toInt(
            try Checked.add(
                UInt64(LZMAProbabilityOffset.literals),
                UInt64(literalProbabilityCapacity)
            )
        )
        let probabilityBytes = try Checked.toInt(
            try Checked.mul(
                UInt64(probabilityCount),
                UInt64(MemoryLayout<UInt16>.stride)
            )
        )

        guard let dictionaryRaw = malloc(dictionaryCount) else {
            throw KaitoError.limitExceeded("unable to allocate LZMA dictionary")
        }
        guard let probabilityRaw = malloc(probabilityBytes) else {
            free(dictionaryRaw)
            throw KaitoError.limitExceeded("unable to allocate LZMA probability models")
        }
        let inputAllocationSize = Self.inputBufferSize &+ Self.maximumBytesPerSymbol
        guard let inputRaw = malloc(inputAllocationSize) else {
            free(probabilityRaw)
            free(dictionaryRaw)
            throw KaitoError.limitExceeded("unable to allocate LZMA input buffer")
        }
        let matchBatchBytes = Self.matchBatchCapacity
            &* MemoryLayout<UInt64>.stride
        guard let matchBatchRaw = malloc(matchBatchBytes) else {
            free(inputRaw)
            free(probabilityRaw)
            free(dictionaryRaw)
            throw KaitoError.limitExceeded("unable to allocate LZMA match batch")
        }

        let dictionaryPointer = dictionaryRaw.bindMemory(
            to: UInt8.self,
            capacity: dictionaryCount
        )
        let probabilityPointer = probabilityRaw.bindMemory(
            to: UInt16.self,
            capacity: probabilityCount
        )
        let inputPointer = inputRaw.bindMemory(
            to: UInt8.self,
            capacity: inputAllocationSize
        )
        let matchBatchPointer = matchBatchRaw.bindMemory(
            to: UInt64.self,
            capacity: Self.matchBatchCapacity
        )
        dictionaryPointer.initialize(repeating: 0, count: dictionaryCount)
        probabilityPointer.initialize(
            repeating: Self.probabilityInitialValue,
            count: probabilityCount
        )
        inputPointer.initialize(repeating: 0, count: inputAllocationSize)
        matchBatchPointer.initialize(repeating: 0, count: Self.matchBatchCapacity)

        self.rangeDecoder = nil
        self.expectedSize = expectedSize
        self.literalContextBits = configuration.literalContextBits
        self.literalPositionBits = configuration.literalPositionBits
        self.positionStateMask = configuration.positionStateMask
        self.literalProbabilityCapacity = literalProbabilityCapacity
        self.probabilities = UnsafeMutableBufferPointer(
            start: probabilityPointer,
            count: probabilityCount
        )
        self.dictionary = UnsafeMutableBufferPointer(
            start: dictionaryPointer,
            count: dictionaryCount
        )
        self.inputStorage = UnsafeMutableBufferPointer(
            start: inputPointer,
            count: inputAllocationSize
        )
        self.matchBatchStorage = UnsafeMutableBufferPointer(
            start: matchBatchPointer,
            count: Self.matchBatchCapacity
        )
    }

    // LZMA2 の外側が保持する辞書・入力 buffer・確率表を一度だけ確保し、
    // 各 chunk では range coder の scalar state と入力内容だけを差し替える。
    convenience init(
        lzma2DictionarySize: UInt64,
        expectedSize: UInt64?,
        dictionarySizeLimit: UInt64
    ) throws {
        try Checked.size(lzma2DictionarySize, limit: dictionarySizeLimit)
        let retainedDictionarySize: UInt64
        if let expectedSize {
            retainedDictionarySize = min(
                lzma2DictionarySize,
                max(UInt64(1), expectedSize)
            )
        } else {
            retainedDictionarySize = lzma2DictionarySize
        }
        let defaultConfiguration = try LZMAProperties(
            packed: 0x5D,
            requireLZMA2LiteralLimit: true
        )
        try self.init(
            configuration: defaultConfiguration,
            retainedDictionarySize: retainedDictionarySize,
            expectedSize: nil,
            literalProbabilityCapacity: Self.maximumLZMA2LiteralProbabilities
        )
        finished = true
    }

    deinit {
        if let base = probabilities.baseAddress {
            base.deinitialize(count: probabilities.count)
            free(UnsafeMutableRawPointer(base))
        }
        if let base = dictionary.baseAddress {
            base.deinitialize(count: dictionary.count)
            free(UnsafeMutableRawPointer(base))
        }
        if let base = inputStorage.baseAddress {
            base.deinitialize(count: inputStorage.count)
            free(UnsafeMutableRawPointer(base))
        }
        if let base = matchBatchStorage.baseAddress {
            base.deinitialize(count: matchBatchStorage.count)
            free(UnsafeMutableRawPointer(base))
        }
    }

    /// Indicates whether the known output size or LZMA end marker was reached.
    public var isFinished: Bool {
        finished
    }

    /// Decodes at most one 256 KiB output chunk into `buffer`.
    public func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !finished else {
            return 0
        }
        guard let destinationRaw = buffer.baseAddress,
              let dictionaryBase = dictionary.baseAddress,
              let probabilityBase = probabilities.baseAddress,
              let matchBatchBase = matchBatchStorage.baseAddress else {
            throw KaitoError.malformed("LZMA decoder storage is unavailable")
        }
        guard var decoder = rangeDecoder else {
            throw KaitoError.malformed("LZMA range decoder is unavailable")
        }
        var hotDecoder = decoder.hotState

        let capacity = min(buffer.count, Self.outputChunkSize)
        guard outputPosition <= UInt64.max - UInt64(capacity),
              processedPosition <= UInt64.max - UInt64(capacity) else {
            throw KaitoError.limitExceeded("LZMA output position overflow")
        }
        let destination = destinationRaw.assumingMemoryBound(to: UInt8.self)
        let dictionaryCount = dictionary.count
        let expectedSize = self.expectedSize
        let literalContextBits = self.literalContextBits
        let literalPositionBits = self.literalPositionBits
        let positionStateMask = self.positionStateMask
        let literalContextShift = UInt64(truncatingIfNeeded: literalContextBits)
        let literalPreviousShift = UInt8(
            truncatingIfNeeded: 8 &- literalContextBits
        )
        let literalPositionMask = literalPositionBits == 0
            ? UInt64(0)
            : (UInt64(1) << UInt64(truncatingIfNeeded: literalPositionBits)) &- 1

        // class property はここで一度だけ local へ移し、hot loop 終了時に一度だけ戻す。
        var dictionaryPosition = self.dictionaryPosition
        var dictionaryBytesAvailable = self.dictionaryBytesAvailable
        var previousByte = self.previousByte
        var processedPosition = self.processedPosition
        var outputPosition = self.outputPosition
        var state = self.state
        var rep0 = self.rep0
        var rep1 = self.rep1
        var rep2 = self.rep2
        var rep3 = self.rep3
        var pendingMatchLength = self.pendingMatchLength
        var finished = self.finished
        var produced = 0
        var flushed = 0
        var flushStart = dictionaryPosition
        var unflushedCount = 0
        var failure: LZMAHotFailure?
        var matchHeadPending = false

        decodeLoop: while produced < capacity, !finished {
            if pendingMatchLength > 0 {
                let copied = copyLZMAMatch(
                    dictionary: dictionaryBase,
                    dictionaryCount: dictionaryCount,
                    distance: rep0,
                    pendingLength: &pendingMatchLength,
                    produced: &produced,
                    capacity: capacity,
                    dictionaryPosition: &dictionaryPosition,
                    dictionaryBytesAvailable: &dictionaryBytesAvailable,
                    previousByte: &previousByte,
                    processedPosition: &processedPosition,
                    outputPosition: &outputPosition
                )
                unflushedCount &+= copied
                if dictionaryPosition == 0 {
                    UnsafeMutableRawPointer(destination.advanced(by: flushed)).copyMemory(
                        from: UnsafeRawPointer(dictionaryBase.advanced(by: flushStart)),
                        byteCount: unflushedCount
                    )
                    flushed &+= unflushedCount
                    flushStart = 0
                    unflushedCount = 0
                }
                if let expectedSize, outputPosition == expectedSize {
                    finished = true
                }
                continue
            }

            // 一シンボルの最大 48 input bytes より余裕を持たせた境界でだけ refill する。
            // decodeBit 自体は非 throwing で、物理 EOF は sentinel flag として後で変換する。
            if hotDecoder.remainingInput < Self.maximumBytesPerSymbol,
               decoder.hasUnreadSource {
                decoder.commit(hotDecoder)
                try decoder.refillInput()
                hotDecoder = decoder.hotState
            }

            var outputBudget = capacity &- produced
            if let expectedSize, outputPosition <= expectedSize {
                let remainingExpected = expectedSize &- outputPosition
                if remainingExpected < UInt64(outputBudget) {
                    outputBudget = Int(remainingExpected)
                }
            }
            if outputBudget == 0 {
                finished = true
                continue
            }
            let refillLimit = decoder.hasUnreadSource
                ? hotDecoder.inputCount &- Self.maximumBytesPerSymbol
                : Int.max
            let matchBatch = decodeLZMANewMatchBatch(
                probabilities: probabilityBase,
                positionStateMask: positionStateMask,
                processedPosition: processedPosition,
                state: state,
                decoder: hotDecoder,
                output: matchBatchBase,
                outputCapacity: matchBatchStorage.count,
                outputBudget: outputBudget,
                refillLimit: refillLimit,
                firstMatchPending: matchHeadPending
            )
            hotDecoder = matchBatch.decoder
            state = matchBatch.state
            let batchResult = matchBatch.packedResult
            matchHeadPending = false
            if hotDecoder.overrun {
                failure = .truncatedInput
                break decodeLoop
            }

            let batchCount = Int(UInt32(truncatingIfNeeded: batchResult))
            var batchIndex = 0
            while batchIndex < batchCount {
                let packedMatch = matchBatchBase[batchIndex]
                let matchLength = Int(UInt32(truncatingIfNeeded: packedMatch))
                let distance = UInt32(truncatingIfNeeded: packedMatch >> 32)
                rep3 = rep2
                rep2 = rep1
                rep1 = rep0
                rep0 = distance

                let byteDistance = Int(distance) &+ 1
                guard byteDistance <= dictionaryBytesAvailable,
                      byteDistance <= dictionaryCount else {
                    failure = .invalidDistance
                    break decodeLoop
                }
                if let expectedSize {
                    guard outputPosition <= expectedSize,
                          UInt64(matchLength) <= expectedSize &- outputPosition else {
                        failure = .outputOverflow
                        break decodeLoop
                    }
                }
                pendingMatchLength = matchLength
                repeat {
                    let copied = copyLZMAMatch(
                        dictionary: dictionaryBase,
                        dictionaryCount: dictionaryCount,
                        distance: rep0,
                        pendingLength: &pendingMatchLength,
                        produced: &produced,
                        capacity: capacity,
                        dictionaryPosition: &dictionaryPosition,
                        dictionaryBytesAvailable: &dictionaryBytesAvailable,
                        previousByte: &previousByte,
                        processedPosition: &processedPosition,
                        outputPosition: &outputPosition
                    )
                    unflushedCount &+= copied
                    if dictionaryPosition == 0 {
                        UnsafeMutableRawPointer(destination.advanced(by: flushed)).copyMemory(
                            from: UnsafeRawPointer(dictionaryBase.advanced(by: flushStart)),
                            byteCount: unflushedCount
                        )
                        flushed &+= unflushedCount
                        flushStart = 0
                        unflushedCount = 0
                    }
                } while pendingMatchLength > 0 && produced < capacity
                batchIndex &+= 1
                if let expectedSize, outputPosition == expectedSize {
                    finished = true
                }
                if pendingMatchLength > 0 || produced == capacity || finished {
                    break
                }
            }
            if failure != nil {
                break decodeLoop
            }
            if pendingMatchLength > 0 || produced == capacity || finished {
                continue
            }

            let batchStop = UInt32(truncatingIfNeeded: batchResult >> 32)
            if batchStop == LZMABatchStop.full
                || batchStop == LZMABatchStop.refill {
                continue
            }
            if batchStop == LZMABatchStop.endMarker {
                guard expectedSize == nil else {
                    failure = .earlyEndMarker
                    break decodeLoop
                }
                finished = true
                continue
            }
            guard batchStop != LZMABatchStop.truncated else {
                failure = .truncatedInput
                break decodeLoop
            }

            if batchStop == LZMABatchStop.literal {
                var literalMaximum = min(
                    capacity &- produced,
                    dictionaryCount &- dictionaryPosition
                )
                if let expectedSize {
                    guard outputPosition <= expectedSize else {
                        failure = .outputOverflow
                        break decodeLoop
                    }
                    let remainingExpected = expectedSize &- outputPosition
                    if remainingExpected < UInt64(literalMaximum) {
                        literalMaximum = Int(remainingExpected)
                    }
                }
                guard literalMaximum > 0 else {
                    failure = .outputOverflow
                    break decodeLoop
                }
                let literalRun = decodeLZMALiteralRun(
                    probabilities: probabilityBase,
                    dictionary: dictionaryBase,
                    dictionaryCount: dictionaryCount,
                    literalContextShift: literalContextShift,
                    literalPreviousShift: literalPreviousShift,
                    literalPositionMask: literalPositionMask,
                    positionStateMask: positionStateMask,
                    rep0: rep0,
                    dictionaryPosition: &dictionaryPosition,
                    dictionaryBytesAvailable: &dictionaryBytesAvailable,
                    previousByte: &previousByte,
                    processedPosition: &processedPosition,
                    outputPosition: &outputPosition,
                    state: &state,
                    decoder: hotDecoder,
                    maximumCount: literalMaximum,
                    refillLimit: refillLimit
                )
                hotDecoder = literalRun.decoder
                let literalResult = literalRun.packedResult
                let literalCount = Int(UInt32(truncatingIfNeeded: literalResult))
                produced &+= literalCount
                unflushedCount &+= literalCount
                if dictionaryPosition == dictionaryCount {
                    dictionaryPosition = 0
                }
                if dictionaryPosition == 0 {
                    UnsafeMutableRawPointer(destination.advanced(by: flushed)).copyMemory(
                        from: UnsafeRawPointer(dictionaryBase.advanced(by: flushStart)),
                        byteCount: unflushedCount
                    )
                    flushed &+= unflushedCount
                    flushStart = 0
                    unflushedCount = 0
                }
                if let expectedSize, outputPosition == expectedSize {
                    finished = true
                }
                let literalStop = UInt32(truncatingIfNeeded: literalResult >> 32)
                if literalStop == LZMALiteralStop.truncated {
                    failure = .truncatedInput
                    break decodeLoop
                }
                if literalStop == LZMALiteralStop.invalidDistance {
                    failure = .invalidDistance
                    break decodeLoop
                }
                if literalStop == LZMALiteralStop.match {
                    matchHeadPending = true
                }
                continue
            }

            guard batchStop == LZMABatchStop.repeated else {
                failure = .truncatedInput
                break decodeLoop
            }
            let positionState = Int(processedPosition & positionStateMask)
            let statePositionIndex = state &* Self.maximumPositionStates &+ positionState
            let repeatedMatch = decodeLZMARepeatedMatchSymbol(
                probabilities: probabilityBase,
                positionState: positionState,
                statePositionIndex: statePositionIndex,
                state: state,
                rep0: rep0,
                rep1: rep1,
                rep2: rep2,
                rep3: rep3,
                decoder: hotDecoder
            )
            hotDecoder = repeatedMatch.decoder
            state = repeatedMatch.state
            rep0 = repeatedMatch.rep0
            rep1 = repeatedMatch.rep1
            rep2 = repeatedMatch.rep2
            rep3 = repeatedMatch.rep3
            if hotDecoder.overrun {
                failure = .truncatedInput
                break decodeLoop
            }
            let matchLength = repeatedMatch.length
            let byteDistance = Int(rep0) &+ 1
            guard byteDistance <= dictionaryBytesAvailable,
                  byteDistance <= dictionaryCount else {
                failure = .invalidDistance
                break decodeLoop
            }
            if let expectedSize {
                guard outputPosition <= expectedSize,
                      UInt64(matchLength) <= expectedSize &- outputPosition else {
                    failure = .outputOverflow
                    break decodeLoop
                }
            }
            pendingMatchLength = matchLength
            let copied = copyLZMAMatch(
                dictionary: dictionaryBase,
                dictionaryCount: dictionaryCount,
                distance: rep0,
                pendingLength: &pendingMatchLength,
                produced: &produced,
                capacity: capacity,
                dictionaryPosition: &dictionaryPosition,
                dictionaryBytesAvailable: &dictionaryBytesAvailable,
                previousByte: &previousByte,
                processedPosition: &processedPosition,
                outputPosition: &outputPosition
            )
            unflushedCount &+= copied
            if dictionaryPosition == 0 {
                UnsafeMutableRawPointer(destination.advanced(by: flushed)).copyMemory(
                    from: UnsafeRawPointer(dictionaryBase.advanced(by: flushStart)),
                    byteCount: unflushedCount
                )
                flushed &+= unflushedCount
                flushStart = 0
                unflushedCount = 0
            }
            if let expectedSize, outputPosition == expectedSize {
                finished = true
            }
        }

        if hotDecoder.overrun, failure == nil {
            failure = .truncatedInput
        }
        if let failure {
            switch failure {
            case .truncatedInput:
                throw KaitoError.truncated
            case .invalidDistance:
                throw KaitoError.malformed("LZMA match refers outside the available dictionary")
            case .outputOverflow:
                throw KaitoError.malformed("LZMA output exceeds the expected size")
            case .earlyEndMarker:
                throw KaitoError.malformed("LZMA end marker precedes the expected size")
            }
        }
        guard produced > 0 || finished else {
            throw KaitoError.malformed("LZMA stream made no progress")
        }

        if unflushedCount > 0 {
            UnsafeMutableRawPointer(destination.advanced(by: flushed)).copyMemory(
                from: UnsafeRawPointer(dictionaryBase.advanced(by: flushStart)),
                byteCount: unflushedCount
            )
            flushed &+= unflushedCount
        }
        guard flushed == produced else {
            throw KaitoError.malformed("LZMA output window accounting mismatch")
        }

        decoder.commit(hotDecoder)
        rangeDecoder = decoder
        self.dictionaryPosition = dictionaryPosition
        self.dictionaryBytesAvailable = dictionaryBytesAvailable
        self.previousByte = previousByte
        self.processedPosition = processedPosition
        self.outputPosition = outputPosition
        self.state = state
        self.rep0 = rep0
        self.rep1 = rep1
        self.rep2 = rep2
        self.rep3 = rep3
        self.pendingMatchLength = pendingMatchLength
        self.finished = finished
        return produced
    }

    // LZMA2 chunk は range coder だけを毎回初期化し、reset flag に応じて
    // 確率状態を初期化する。dictionary は別 flag のときだけ捨てる。
    func beginLZMA2Chunk(
        source: any ByteSource,
        offset: UInt64,
        compressedSize: UInt64,
        unpackedSize: UInt64,
        resetState: Bool,
        properties: UInt8?
    ) throws {
        guard unpackedSize > 0, unpackedSize <= 2 * 1_024 * 1_024 else {
            throw KaitoError.malformed("invalid LZMA2 unpacked chunk size")
        }
        guard compressedSize > 0, compressedSize <= 64 * 1_024 else {
            throw KaitoError.malformed("invalid LZMA2 packed chunk size")
        }
        guard properties == nil || resetState else {
            throw KaitoError.malformed("LZMA2 properties require a state reset")
        }

        if let properties {
            let configuration = try LZMAProperties(
                packed: properties,
                requireLZMA2LiteralLimit: true
            )
            try apply(configuration)
        }
        if resetState {
            resetCodingState()
        }

        let compressedEnd = try Checked.add(offset, compressedSize)
        guard compressedEnd <= source.length else {
            throw KaitoError.truncated
        }
        expectedSize = try Checked.add(outputPosition, unpackedSize)
        rangeDecoder = try LZMARangeDecoder(
            source: source,
            offset: offset,
            endOffset: compressedEnd,
            storage: inputStorage
        )
        pendingMatchLength = 0
        finished = false
    }

    func resetLZMA2Dictionary() {
        dictionaryPosition = 0
        dictionaryBytesAvailable = 0
        previousByte = 0
        processedPosition = 0
    }

    func preloadLZMA2Properties(_ properties: UInt8) throws {
        let configuration = try LZMAProperties(
            packed: properties,
            requireLZMA2LiteralLimit: true
        )
        try apply(configuration)
        resetCodingState()
    }

    func finishLZMA2Chunk() throws {
        guard finished, pendingMatchLength == 0,
              let rangeDecoder else {
            throw KaitoError.malformed("LZMA2 chunk ended before its declared output size")
        }
        guard rangeDecoder.isFinishedOK else {
            throw KaitoError.malformed("LZMA2 range coder has a nonzero terminal code")
        }
        guard rangeDecoder.consumedAllInput else {
            throw KaitoError.malformed("LZMA2 packed chunk has unused bytes")
        }
    }

    func appendLZMA2Uncompressed(_ bytes: ArraySlice<UInt8>) throws {
        // 直前の compressed chunk の終端値は raw chunk には適用しない。
        expectedSize = nil
        rangeDecoder = nil
        pendingMatchLength = 0
        finished = true
        guard !bytes.isEmpty, let dictionaryBase = dictionary.baseAddress else { return }

        // raw chunk は最大 64 KiB。ring に残る末尾だけを二区間で写し、
        // 位置と履歴量は chunk 単位で一度だけ更新する。
        let amount = bytes.count
        let dictionaryCount = dictionary.count
        let amountModuloDictionary = amount % dictionaryCount
        let room = dictionaryCount - dictionaryPosition
        let newPosition = amountModuloDictionary >= room
            ? amountModuloDictionary - room
            : dictionaryPosition + amountModuloDictionary
        let retainedCount = min(amount, dictionaryCount)
        let retained = bytes.suffix(retainedCount)
        let writeStart = amount >= dictionaryCount ? newPosition : dictionaryPosition
        let firstCount = min(retainedCount, dictionaryCount - writeStart)
        let secondCount = retainedCount - firstCount
        retained.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else { return }
            // retainedCount <= dictionaryCount かつ二区間の和は retainedCount。
            // source と dictionary は非 alias で、両 copy は検証済み範囲内にある。
            if firstCount > 0 {
                UnsafeMutableRawPointer(dictionaryBase.advanced(by: writeStart)).copyMemory(
                    from: sourceBase,
                    byteCount: firstCount
                )
            }
            if secondCount > 0 {
                UnsafeMutableRawPointer(dictionaryBase).copyMemory(
                    from: sourceBase.advanced(by: firstCount),
                    byteCount: secondCount
                )
            }
        }
        dictionaryPosition = newPosition
        if amount >= dictionaryCount - dictionaryBytesAvailable {
            dictionaryBytesAvailable = dictionaryCount
        } else {
            dictionaryBytesAvailable += amount
        }
        previousByte = bytes.last!
        processedPosition = try Checked.add(processedPosition, UInt64(amount))
        outputPosition = try Checked.add(outputPosition, UInt64(amount))
    }

    private func apply(_ configuration: LZMAProperties) throws {
        let count = try configuration.literalProbabilityCount()
        guard count <= literalProbabilityCapacity else {
            throw KaitoError.malformed("LZMA2 literal model exceeds its allocation")
        }
        literalContextBits = configuration.literalContextBits
        literalPositionBits = configuration.literalPositionBits
        positionStateMask = configuration.positionStateMask
    }

    private func resetCodingState() {
        probabilities.baseAddress?.update(
            repeating: Self.probabilityInitialValue,
            count: probabilities.count
        )
        state = 0
        rep0 = 0
        rep1 = 0
        rep2 = 0
        rep3 = 0
        pendingMatchLength = 0
    }
}

private enum LZMAHotFailure {
    case truncatedInput
    case invalidDistance
    case outputOverflow
    case earlyEndMarker
}

private enum LZMAProbabilityOffset {
    static let isMatch = 0
    static let isRep = isMatch + 12 * 16
    static let isRepG0 = isRep + 12
    static let isRepG1 = isRepG0 + 12
    static let isRepG2 = isRepG1 + 12
    static let isRep0Long = isRepG2 + 12
    static let positionSlot = isRep0Long + 12 * 16
    static let positionModels = positionSlot + 4 * 64
    static let alignment = positionModels + ((1 << 7) - 14)

    static let matchChoice = alignment + (1 << 4)
    static let matchLow = matchChoice + 2
    static let matchMiddle = matchLow + 16 * 8
    static let matchHigh = matchMiddle + 16 * 8

    static let repeatedChoice = matchHigh + 256
    static let repeatedLow = repeatedChoice + 2
    static let repeatedMiddle = repeatedLow + 16 * 8
    static let repeatedHigh = repeatedMiddle + 16 * 8
    static let literals = repeatedHigh + 256
}

private struct LZMAProperties {
    let literalContextBits: Int
    let literalPositionBits: Int
    let positionBits: Int

    var positionStateMask: UInt64 {
        (UInt64(1) << UInt64(positionBits)) - 1
    }

    init(packed: UInt8, requireLZMA2LiteralLimit: Bool) throws {
        let value = Int(packed)
        guard value < 9 * 5 * 5 else {
            throw KaitoError.malformed("invalid LZMA lc/lp/pb properties")
        }
        literalContextBits = value % 9
        let remainder = value / 9
        literalPositionBits = remainder % 5
        positionBits = remainder / 5
        if requireLZMA2LiteralLimit,
           literalContextBits + literalPositionBits > 4 {
            throw KaitoError.malformed("invalid LZMA2 literal properties")
        }
    }

    func literalProbabilityCount() throws -> Int {
        let shift = try Checked.add(
            UInt64(literalContextBits),
            UInt64(literalPositionBits)
        )
        let contextCount = try Checked.shiftLeft(1, by: shift)
        let probabilityCount = try Checked.mul(0x300, contextCount)
        return try Checked.toInt(probabilityCount)
    }
}

private struct LZMARangeDecoder {
    private let source: any ByteSource
    private let endOffset: UInt64
    private let storageBase: UnsafeMutablePointer<UInt8>
    private let storageCount: Int
    private var nextSourceOffset: UInt64
    private var inputCount = 0
    private var inputPosition = 0
    private(set) var range: UInt32 = UInt32.max
    private(set) var code: UInt32 = 0
    private(set) var overrun = false

    var isFinishedOK: Bool { code == 0 && !overrun }
    var consumedAllInput: Bool {
        nextSourceOffset == endOffset && inputPosition == inputCount && !overrun
    }

    init(
        source: any ByteSource,
        offset: UInt64,
        endOffset: UInt64,
        storage: UnsafeMutableBufferPointer<UInt8>
    ) throws {
        guard offset <= endOffset, endOffset <= source.length,
              storage.count > LZMADecoder.maximumBytesPerSymbol,
              storage.baseAddress != nil else {
            throw KaitoError.truncated
        }
        self.source = source
        self.endOffset = endOffset
        self.storageBase = storage.baseAddress!
        self.storageCount = storage.count &- LZMADecoder.maximumBytesPerSymbol
        self.nextSourceOffset = offset
        try refillInput()
        guard inputCount >= 5 else {
            throw KaitoError.truncated
        }
        let first = storageBase[inputPosition]
        inputPosition += 1
        guard first == 0 else {
            throw KaitoError.malformed("invalid LZMA range-coder initialization")
        }
        for _ in 0..<4 {
            code = (code << 8) | UInt32(storageBase[inputPosition])
            inputPosition += 1
        }
    }

    var hasUnreadSource: Bool { nextSourceOffset < endOffset }

    var hotState: LZMAHotRangeState {
        LZMAHotRangeState(
            inputBase: storageBase,
            inputCount: inputCount,
            inputPosition: inputPosition,
            range: range,
            code: code
        )
    }

    mutating func commit(_ hotState: LZMAHotRangeState) {
        inputPosition = hotState.inputPosition
        range = hotState.range
        code = hotState.code
        overrun = hotState.overrun
    }

    mutating func refillInput() throws {
        let base = storageBase
        let retained = inputCount &- inputPosition
        if retained > 0, inputPosition > 0 {
            // source/destination は同一 buffer 内で重なり得るため memmove を使う。
            Darwin.memmove(base, base.advanced(by: inputPosition), retained)
        }
        inputPosition = 0
        inputCount = retained

        while inputCount < storageCount, nextSourceOffset < endOffset {
            let remaining = endOffset &- nextSourceOffset
            let available = storageCount &- inputCount
            let requested = remaining < UInt64(available)
                ? Int(remaining)
                : available
            let destination = UnsafeMutableRawBufferPointer(
                start: base.advanced(by: inputCount),
                count: requested
            )
            let actual = try source.read(into: destination, at: nextSourceOffset)
            guard actual > 0, actual <= requested else {
                throw KaitoError.truncated
            }
            inputCount &+= actual
            nextSourceOffset &+= UInt64(actual)
        }
        // hot range reader は最大一シンボル分だけ無条件 load できる。valid 末尾の
        // zero sentinel は結果を受理するためではなく、chunk 境界で overrun を
        // 遅延検出して物理 buffer 外を読まないためのもの。
        Darwin.memset(
            base.advanced(by: inputCount),
            0,
            LZMADecoder.maximumBytesPerSymbol
        )
    }

}

private struct LZMAHotRangeState {
    let inputBase: UnsafeMutablePointer<UInt8>
    let inputCount: Int
    var inputPosition: Int
    var range: UInt32
    var code: UInt32

    @inline(__always)
    var remainingInput: Int { inputCount &- inputPosition }

    @inline(__always)
    var overrun: Bool { inputPosition > inputCount }

    // この本体を三項演算子や mask 形へ書き換えず、bit tree の最終段も先読みしない。
    // code < bound は LLVM が既に csel 化するため手書き branchless は効かない。
    // 設計検討の micro benchmark では 5〜6% 遅かった（2026-09-12、cooViewer-r897）。
    // この値は採用形の A/B では再測していない。
    @inline(__always)
    mutating func decodeBit(
        probability: UInt32,
        store probabilityPointer: UnsafeMutablePointer<UInt16>
    ) -> UInt32 {
        var probability = probability
        let bound = (range >> 11) &* probability
        let bit: UInt32
        if code < bound {
            range = bound
            probability &+= (2_048 &- probability) >> 5
            bit = 0
        } else {
            range &-= bound
            code &-= bound
            probability &-= probability >> 5
            bit = 1
        }
        probabilityPointer.pointee = UInt16(truncatingIfNeeded: probability)
        normalize()
        return bit
    }

    @inline(__always)
    mutating func decodeBit(_ probabilityPointer: UnsafeMutablePointer<UInt16>) -> UInt32 {
        decodeBit(probability: UInt32(probabilityPointer.pointee), store: probabilityPointer)
    }

    @inline(__always)
    mutating func decodeDirectBits(_ count: Int) -> UInt32 {
        var result: UInt32 = 0
        for _ in 0..<count {
            range >>= 1
            result <<= 1
            if code >= range {
                code &-= range
                result |= 1
            }
            normalize()
        }
        return result
    }

    @inline(__always)
    private mutating func normalize() {
        if range < 0x0100_0000 {
            range <<= 8
            code = (code << 8) | UInt32(nextByte())
        }
    }

    @inline(__always)
    private mutating func nextByte() -> UInt8 {
        let byte = inputBase[inputPosition]
        inputPosition &+= 1
        return byte
    }
}

private enum LZMABatchStop {
    static let full: UInt32 = 0
    static let literal: UInt32 = 1
    static let repeated: UInt32 = 2
    static let endMarker: UInt32 = 3
    static let refill: UInt32 = 4
    static let truncated: UInt32 = 5
}

private enum LZMALiteralStop {
    static let full: UInt32 = 0
    static let match: UInt32 = 1
    static let refill: UInt32 = 2
    static let truncated: UInt32 = 3
    static let invalidDistance: UInt32 = 4
}

private struct LZMALiteralRunResult {
    var decoder: LZMAHotRangeState
    var packedResult: UInt64
}

private struct LZMAMatchBatchResult {
    var decoder: LZMAHotRangeState
    var state: Int
    var packedResult: UInt64
}

private struct LZMARepeatedMatchResult {
    var decoder: LZMAHotRangeState
    var state: Int
    var rep0: UInt32
    var rep1: UInt32
    var rep2: UInt32
    var rep3: UInt32
    var length: Int
}

// 連続する new match を最大 256 個まで一つの frame で復号する。range state は
// value で受け渡し、各 bit ではなく batch 終端で一度だけ書き戻す。
@inline(never)
private func decodeLZMANewMatchBatch(
    probabilities: UnsafeMutablePointer<UInt16>,
    positionStateMask: UInt64,
    processedPosition: UInt64,
    state inputState: Int,
    decoder inputDecoder: LZMAHotRangeState,
    output: UnsafeMutablePointer<UInt64>,
    outputCapacity: Int,
    outputBudget: Int,
    refillLimit: Int,
    firstMatchPending: Bool
) -> LZMAMatchBatchResult {
    var localDecoder = inputDecoder
    var localState = inputState
    var modelPosition = processedPosition
    var count = 0
    var generated = 0
    var stop = LZMABatchStop.full
    var matchPending = firstMatchPending

    while count < outputCapacity, generated < outputBudget {
        let positionState = Int(modelPosition & positionStateMask)
        let statePositionIndex = localState
            &* LZMADecoder.maximumPositionStates
            &+ positionState
        if !matchPending {
            if localDecoder.inputPosition > refillLimit {
                stop = LZMABatchStop.refill
                break
            }
            if localDecoder.decodeBit(
                probabilities.advanced(
                    by: LZMAProbabilityOffset.isMatch &+ statePositionIndex
                )
            ) == 0 {
                stop = LZMABatchStop.literal
                break
            }
        }
        matchPending = false
        if localDecoder.decodeBit(
            probabilities.advanced(by: LZMAProbabilityOffset.isRep &+ localState)
        ) != 0 {
            stop = LZMABatchStop.repeated
            break
        }

        let packedMatch = decodeLZMANewMatchCore(
            probabilities: probabilities,
            positionState: positionState,
            decoder: &localDecoder
        )
        if localDecoder.overrun {
            stop = LZMABatchStop.truncated
            break
        }
        let distance = UInt32(truncatingIfNeeded: packedMatch >> 32)
        if distance == UInt32.max {
            stop = LZMABatchStop.endMarker
            break
        }
        output[count] = packedMatch
        count &+= 1
        let length = Int(UInt32(truncatingIfNeeded: packedMatch))
        generated &+= length
        modelPosition &+= UInt64(length)
        localState = localState < 7 ? 7 : 10
    }

    return LZMAMatchBatchResult(
        decoder: localDecoder,
        state: localState,
        packedResult: (UInt64(stop) << 32)
            | UInt64(UInt32(truncatingIfNeeded: count))
    )
}

// isMatch=0 を一つ消費済みの位置から literal run を復号し、次の match head または
// buffer 境界まで dictionary の一つの連続 span に直接書く。
@inline(never)
private func decodeLZMALiteralRun(
    probabilities: UnsafeMutablePointer<UInt16>,
    dictionary: UnsafeMutablePointer<UInt8>,
    dictionaryCount: Int,
    literalContextShift: UInt64,
    literalPreviousShift: UInt8,
    literalPositionMask: UInt64,
    positionStateMask: UInt64,
    rep0: UInt32,
    dictionaryPosition: inout Int,
    dictionaryBytesAvailable: inout Int,
    previousByte: inout UInt8,
    processedPosition: inout UInt64,
    outputPosition: inout UInt64,
    state: inout Int,
    decoder inputDecoder: LZMAHotRangeState,
    maximumCount: Int,
    refillLimit: Int
) -> LZMALiteralRunResult {
    var localDecoder = inputDecoder
    var localDictionaryPosition = dictionaryPosition
    var localDictionaryBytesAvailable = dictionaryBytesAvailable
    var localPreviousByte = previousByte
    var localProcessedPosition = processedPosition
    var localOutputPosition = outputPosition
    var localState = state
    var produced = 0
    var stop = LZMALiteralStop.full

    while produced < maximumCount {
        let positionPart = localProcessedPosition & literalPositionMask
        let previousPart = UInt64(localPreviousByte >> literalPreviousShift)
        let context = (positionPart << literalContextShift) | previousPart
        let literalBase = LZMAProbabilityOffset.literals
            &+ Int(truncatingIfNeeded: context) &* 0x300

        var symbol = 1
        if localState >= 7 {
            let byteDistance = Int(rep0) &+ 1
            guard byteDistance <= localDictionaryBytesAvailable,
                  byteDistance <= dictionaryCount else {
                stop = LZMALiteralStop.invalidDistance
                break
            }
            let sourcePosition = localDictionaryPosition >= byteDistance
                ? localDictionaryPosition &- byteDistance
                : dictionaryCount &- (byteDistance &- localDictionaryPosition)
            var matchByte = dictionary[sourcePosition]
            while symbol < 0x100 {
                let matchBit = Int((matchByte >> 7) & 1)
                matchByte <<= 1
                let index = literalBase
                    &+ ((1 &+ matchBit) << 8)
                    &+ symbol
                let bit = Int(
                    localDecoder.decodeBit(probabilities.advanced(by: index))
                )
                symbol = (symbol << 1) | bit
                if matchBit != bit {
                    while symbol < 0x100 {
                        let plainBit = Int(
                            localDecoder.decodeBit(
                                probabilities.advanced(by: literalBase &+ symbol)
                            )
                        )
                        symbol = (symbol << 1) | plainBit
                    }
                    break
                }
            }
        } else {
            symbol = decodeLZMAPlainLiteral(
                probabilities: probabilities,
                base: literalBase,
                decoder: &localDecoder
            )
        }
        if localDecoder.overrun {
            stop = LZMALiteralStop.truncated
            break
        }

        let byte = UInt8(truncatingIfNeeded: symbol &- 0x100)
        dictionary[localDictionaryPosition] = byte
        localDictionaryPosition &+= 1
        produced &+= 1
        if localDictionaryBytesAvailable < dictionaryCount {
            localDictionaryBytesAvailable &+= 1
        }
        localPreviousByte = byte
        localProcessedPosition &+= 1
        localOutputPosition &+= 1
        if localState < 4 {
            localState = 0
        } else if localState < 10 {
            localState &-= 3
        } else {
            localState &-= 6
        }

        if produced == maximumCount {
            break
        }
        if localDecoder.inputPosition > refillLimit {
            stop = LZMALiteralStop.refill
            break
        }
        let positionState = Int(localProcessedPosition & positionStateMask)
        let statePositionIndex = localState
            &* LZMADecoder.maximumPositionStates
            &+ positionState
        if localDecoder.decodeBit(
            probabilities.advanced(
                by: LZMAProbabilityOffset.isMatch &+ statePositionIndex
            )
        ) != 0 {
            stop = localDecoder.overrun
                ? LZMALiteralStop.truncated
                : LZMALiteralStop.match
            break
        }
        if localDecoder.overrun {
            stop = LZMALiteralStop.truncated
            break
        }
    }

    if localDictionaryPosition == dictionaryCount {
        localDictionaryPosition = 0
    }
    dictionaryPosition = localDictionaryPosition
    dictionaryBytesAvailable = localDictionaryBytesAvailable
    previousByte = localPreviousByte
    processedPosition = localProcessedPosition
    outputPosition = localOutputPosition
    state = localState
    return LZMALiteralRunResult(
        decoder: localDecoder,
        packedResult: (UInt64(stop) << 32)
            | UInt64(UInt32(truncatingIfNeeded: produced))
    )
}

// new match は rep state を受け渡さずに復号する。上位 32 bit が distance、
// 下位 32 bit が length。
@inline(__always)
private func decodeLZMANewMatchCore(
    probabilities: UnsafeMutablePointer<UInt16>,
    positionState: Int,
    decoder: inout LZMAHotRangeState
) -> UInt64 {
    let matchLength = 2 &+ decodeLZMALength(
        probabilities: probabilities,
        choiceOffset: LZMAProbabilityOffset.matchChoice,
        lowOffset: LZMAProbabilityOffset.matchLow,
        middleOffset: LZMAProbabilityOffset.matchMiddle,
        highOffset: LZMAProbabilityOffset.matchHigh,
        positionState: positionState,
        decoder: &decoder
    )
    let lengthToPositionState = min(matchLength &- 2, 3)
    let slot = decodeLZMABitTree(
        probabilities: probabilities,
        base: LZMAProbabilityOffset.positionSlot
            &+ lengthToPositionState &* 64,
        bitCount: 6,
        decoder: &decoder
    )
    let distance = decodeLZMADistance(
        slot: slot,
        probabilities: probabilities,
        decoder: &decoder
    )
    return (UInt64(distance) << 32)
        | UInt64(UInt32(truncatingIfNeeded: matchLength))
}

// rep match は実データでは稀だが、同じ local-scalar invariant を維持する。
@inline(never)
private func decodeLZMARepeatedMatchSymbol(
    probabilities: UnsafeMutablePointer<UInt16>,
    positionState: Int,
    statePositionIndex: Int,
    state: Int,
    rep0: UInt32,
    rep1: UInt32,
    rep2: UInt32,
    rep3: UInt32,
    decoder: LZMAHotRangeState
) -> LZMARepeatedMatchResult {
    var localDecoder = decoder
    var localState = state
    var localRep0 = rep0
    var localRep1 = rep1
    var localRep2 = rep2
    var localRep3 = rep3
    let matchLength: Int

    if localDecoder.decodeBit(
        probabilities.advanced(by: LZMAProbabilityOffset.isRepG0 &+ localState)
    ) == 0 {
        if localDecoder.decodeBit(
            probabilities.advanced(
                by: LZMAProbabilityOffset.isRep0Long &+ statePositionIndex
            )
        ) == 0 {
            localState = localState < 7 ? 9 : 11
            matchLength = 1
        } else {
            matchLength = 2 &+ decodeLZMALength(
                probabilities: probabilities,
                choiceOffset: LZMAProbabilityOffset.repeatedChoice,
                lowOffset: LZMAProbabilityOffset.repeatedLow,
                middleOffset: LZMAProbabilityOffset.repeatedMiddle,
                highOffset: LZMAProbabilityOffset.repeatedHigh,
                positionState: positionState,
                decoder: &localDecoder
            )
            localState = localState < 7 ? 8 : 11
        }
    } else {
        let distance: UInt32
        if localDecoder.decodeBit(
            probabilities.advanced(by: LZMAProbabilityOffset.isRepG1 &+ localState)
        ) == 0 {
            distance = localRep1
        } else {
            if localDecoder.decodeBit(
                probabilities.advanced(by: LZMAProbabilityOffset.isRepG2 &+ localState)
            ) == 0 {
                distance = localRep2
            } else {
                distance = localRep3
                localRep3 = localRep2
            }
            localRep2 = localRep1
        }
        localRep1 = localRep0
        localRep0 = distance
        matchLength = 2 &+ decodeLZMALength(
            probabilities: probabilities,
            choiceOffset: LZMAProbabilityOffset.repeatedChoice,
            lowOffset: LZMAProbabilityOffset.repeatedLow,
            middleOffset: LZMAProbabilityOffset.repeatedMiddle,
            highOffset: LZMAProbabilityOffset.repeatedHigh,
            positionState: positionState,
            decoder: &localDecoder
        )
        localState = localState < 7 ? 8 : 11
    }

    return LZMARepeatedMatchResult(
        decoder: localDecoder,
        state: localState,
        rep0: localRep0,
        rep1: localRep1,
        rep2: localRep2,
        rep3: localRep3,
        length: matchLength
    )
}

// literal 木も深さ 8 の bit tree なので同じ先読みを使う。8 段を手展開しないこと。
// 手展開すると本体が大きくなり、book-solid.7z が実測で退行する
// (@inline(__always) のみで +31%、@_transparent を足しても +18%。2026-09-12、cooViewer-r897)。
@inline(__always)
private func decodeLZMAPlainLiteral(
    probabilities: UnsafeMutablePointer<UInt16>,
    base: Int,
    decoder: inout LZMAHotRangeState
) -> Int {
    // 最終段だけは子を持たないので先読みしない。
    let node = probabilities.advanced(by: base)
    var symbol = 1
    var probability = UInt32(node[1])
    for _ in 0..<7 {
        let childZero = UInt32(node[symbol << 1])
        let childOne = UInt32(node[(symbol << 1) | 1])
        let bit = decoder.decodeBit(
            probability: probability,
            store: node.advanced(by: symbol)
        )
        symbol = (symbol << 1) | Int(bit)
        probability = bit == 0 ? childZero : childOne
    }
    let bit = decoder.decodeBit(
        probability: probability,
        store: node.advanced(by: symbol)
    )
    return (symbol << 1) | Int(bit)
}

@_transparent
@inline(__always)
private func decodeLZMALength(
    probabilities: UnsafeMutablePointer<UInt16>,
    choiceOffset: Int,
    lowOffset: Int,
    middleOffset: Int,
    highOffset: Int,
    positionState: Int,
    decoder: inout LZMAHotRangeState
) -> Int {
    if decoder.decodeBit(probabilities.advanced(by: choiceOffset)) == 0 {
        return decodeLZMABitTree(
            probabilities: probabilities,
            base: lowOffset &+ positionState &* 8,
            bitCount: 3,
            decoder: &decoder
        )
    }
    if decoder.decodeBit(probabilities.advanced(by: choiceOffset &+ 1)) == 0 {
        return 8 &+ decodeLZMABitTree(
            probabilities: probabilities,
            base: middleOffset &+ positionState &* 8,
            bitCount: 3,
            decoder: &decoder
        )
    }
    return 16 &+ decodeLZMABitTree(
        probabilities: probabilities,
        base: highOffset,
        bitCount: 8,
        decoder: &decoder
    )
}

// bit tree の子 node 2s / 2s+1 は bit 確定前に address が判る。両方先読みして
// bit 確定後に選ぶと、probability の load latency が range/code の依存鎖から外れる。
// 最終段は子を持たないので先読みしない。
// 先読み段 k（0 起点）では symbol < 2^(k+1) ≤ 2^(bitCount-1) なので、
// 子の最大 index は 2s+1 ≤ 2^bitCount − 1。元コードが最終段に書き込む
// index 集合と同じ表の範囲に収まり、確率表の拡張は不要。
@_transparent
@inline(__always)
private func decodeLZMABitTree(
    probabilities: UnsafeMutablePointer<UInt16>,
    base: Int,
    bitCount: Int,
    decoder: inout LZMAHotRangeState
) -> Int {
    let node = probabilities.advanced(by: base)
    var symbol = 1
    var probability = UInt32(node[1])
    for _ in 0..<(bitCount &- 1) {
        let childZero = UInt32(node[symbol << 1])
        let childOne = UInt32(node[(symbol << 1) | 1])
        let bit = decoder.decodeBit(
            probability: probability,
            store: node.advanced(by: symbol)
        )
        symbol = (symbol << 1) | Int(bit)
        probability = bit == 0 ? childZero : childOne
    }
    let bit = decoder.decodeBit(
        probability: probability,
        store: node.advanced(by: symbol)
    )
    symbol = (symbol << 1) | Int(bit)
    return symbol &- (1 << bitCount)
}

@_transparent
@inline(__always)
private func decodeLZMAReverseBitTree(
    probabilities: UnsafeMutablePointer<UInt16>,
    base: Int,
    bitCount: Int,
    decoder: inout LZMAHotRangeState
) -> Int {
    let node = probabilities.advanced(by: base)
    var symbol = 1
    var result = 0
    guard bitCount > 0 else { return 0 }
    var probability = UInt32(node[1])
    for bitIndex in 0..<(bitCount &- 1) {
        let childZero = UInt32(node[symbol << 1])
        let childOne = UInt32(node[(symbol << 1) | 1])
        let bit = Int(decoder.decodeBit(
            probability: probability,
            store: node.advanced(by: symbol)
        ))
        symbol = (symbol << 1) | bit
        result |= bit << bitIndex
        probability = bit == 0 ? childZero : childOne
    }
    let bit = Int(decoder.decodeBit(
        probability: probability,
        store: node.advanced(by: symbol)
    ))
    result |= bit << (bitCount &- 1)
    return result
}

@_transparent
@inline(__always)
private func decodeLZMADistance(
    slot: Int,
    probabilities: UnsafeMutablePointer<UInt16>,
    decoder: inout LZMAHotRangeState
) -> UInt32 {
    if slot < 4 {
        return UInt32(slot)
    }
    let directBitCount = (slot >> 1) &- 1
    let prefix = UInt32(truncatingIfNeeded: 2 | (slot & 1))
        << UInt32(truncatingIfNeeded: directBitCount)
    if slot < 14 {
        // slot 4 では base が -1 だが、木の最初の symbol 1 と相殺される。
        let modelBase = LZMAProbabilityOffset.positionModels
            &+ Int(prefix) &- slot &- 1
        let suffix = decodeLZMAReverseBitTree(
            probabilities: probabilities,
            base: modelBase,
            bitCount: directBitCount,
            decoder: &decoder
        )
        return prefix &+ UInt32(truncatingIfNeeded: suffix)
    }
    let direct = decoder.decodeDirectBits(directBitCount &- 4)
    let suffix = decodeLZMAReverseBitTree(
        probabilities: probabilities,
        base: LZMAProbabilityOffset.alignment,
        bitCount: 4,
        decoder: &decoder
    )
    return prefix &+ (direct << 4) &+ UInt32(truncatingIfNeeded: suffix)
}

@inline(__always)
private func copyLZMAMatch(
    dictionary: UnsafeMutablePointer<UInt8>,
    dictionaryCount: Int,
    distance: UInt32,
    pendingLength: inout Int,
    produced: inout Int,
    capacity: Int,
    dictionaryPosition: inout Int,
    dictionaryBytesAvailable: inout Int,
    previousByte: inout UInt8,
    processedPosition: inout UInt64,
    outputPosition: inout UInt64
) -> Int {
    // 一回の生成を dictionary 終端で止めるため、caller への flush 範囲は常に連続する。
    let amount = min(
        pendingLength,
        min(capacity &- produced, dictionaryCount &- dictionaryPosition)
    )
    guard amount > 0 else { return 0 }
    let byteDistance = Int(distance) &+ 1
    let sourcePosition = dictionaryPosition >= byteDistance
        ? dictionaryPosition &- byteDistance
        : dictionaryCount &- (byteDistance &- dictionaryPosition)

    if byteDistance >= amount,
       amount <= dictionaryCount &- sourcePosition,
       amount <= dictionaryCount &- dictionaryPosition {
        // 両 window 範囲が非 wrap かつ非重複なので、match と caller 出力を一括 copy する。
        UnsafeMutableRawPointer(dictionary.advanced(by: dictionaryPosition)).copyMemory(
            from: UnsafeRawPointer(dictionary.advanced(by: sourcePosition)),
            byteCount: amount
        )
        dictionaryPosition &+= amount
        if dictionaryPosition == dictionaryCount {
            dictionaryPosition = 0
        }
    } else if byteDistance == 1 {
        // distance 1 は直前 byte の反復なので、依存付き loop を memset に畳み込める。
        let previousIndex = dictionaryPosition == 0
            ? dictionaryCount &- 1
            : dictionaryPosition &- 1
        Darwin.memset(
            dictionary.advanced(by: dictionaryPosition),
            Int32(dictionary[previousIndex]),
            amount
        )
        dictionaryPosition &+= amount
        if dictionaryPosition == dictionaryCount {
            dictionaryPosition = 0
        }
    } else if dictionaryPosition >= byteDistance {
        // destination は amount の算出時に ring 終端で切ってある。最初の周期を
        // 非重複 copy した後は、生成済み prefix を倍増 copy して前向き overlap の
        // 意味を保つ。各 copy の source/destination 自体は互いに重ならない。
        let source = dictionary.advanced(by: dictionaryPosition &- byteDistance)
        let destination = dictionary.advanced(by: dictionaryPosition)
        UnsafeMutableRawPointer(destination).copyMemory(
            from: UnsafeRawPointer(source),
            byteCount: byteDistance
        )
        var copied = byteDistance
        while copied < amount {
            let batch = min(copied, amount &- copied)
            UnsafeMutableRawPointer(destination.advanced(by: copied)).copyMemory(
                from: UnsafeRawPointer(destination),
                byteCount: batch
            )
            copied &+= batch
        }
        dictionaryPosition &+= amount
        if dictionaryPosition == dictionaryCount {
            dictionaryPosition = 0
        }
    } else {
        // source だけが ring 終端を跨ぐ場合も位置を一度求め、loop 内の距離計算を除く。
        var sourcePosition = dictionaryCount &- (byteDistance &- dictionaryPosition)
        var destinationPosition = dictionaryPosition
        for _ in 0..<amount {
            dictionary[destinationPosition] = dictionary[sourcePosition]
            destinationPosition &+= 1
            sourcePosition &+= 1
            if sourcePosition == dictionaryCount {
                sourcePosition = 0
            }
        }
        dictionaryPosition = destinationPosition == dictionaryCount
            ? 0
            : destinationPosition
    }

    let previousIndex = dictionaryPosition == 0
        ? dictionaryCount &- 1
        : dictionaryPosition &- 1
    previousByte = dictionary[previousIndex]
    if amount >= dictionaryCount &- dictionaryBytesAvailable {
        dictionaryBytesAvailable = dictionaryCount
    } else {
        dictionaryBytesAvailable &+= amount
    }
    pendingLength &-= amount
    produced &+= amount
    processedPosition &+= UInt64(amount)
    outputPosition &+= UInt64(amount)
    return amount
}

// LZMA2 の外側の ByteReader も folder の検証済み packed 範囲だけを読む。
struct LZMABoundedByteSource: ByteSource {
    let source: any ByteSource
    let length: UInt64

    init(source: any ByteSource, endOffset: UInt64) {
        self.source = source
        self.length = endOffset
    }

    func read(
        into buffer: UnsafeMutableRawBufferPointer,
        at offset: UInt64
    ) throws -> Int {
        guard !buffer.isEmpty, offset < length else { return 0 }
        let remaining = try Checked.sub(length, offset)
        let count = try Checked.toInt(min(UInt64(buffer.count), remaining))
        let destination = UnsafeMutableRawBufferPointer(rebasing: buffer[..<count])
        return try source.read(into: destination, at: offset)
    }
}
