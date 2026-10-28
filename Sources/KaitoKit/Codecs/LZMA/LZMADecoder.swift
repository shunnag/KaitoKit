import Darwin
import Foundation

// 参照仕様: LZMA SDK の lzma-specification.txt。
// 確率モデルとレンジ復号器はストリームごとに保持し、出力全体は保持しない。

/// A streaming decoder for raw LZMA1 data.
///
/// The five property bytes contain `lc`, `lp`, `pb`, and the little-endian
/// dictionary size. The compressed range starts with the standard five-byte
/// LZMA range-coder initialization sequence.
///
/// Failures are not latched. A throwing `read(into:)` does not commit the
/// scalar coder state, but the dictionary and probability models may already
/// hold partial updates, so the instance must be discarded.
public final class LZMADecoder: Decompressor {
    private static let outputChunkSize = 256 * 1_024
    private static let inputBufferSize = 256 * 1_024
    fileprivate static let maximumBytesPerSymbol = 64
    // 一つの frame で連続して復号する new match の上限。誤り検出の順序（下記
    // decodeLZMANewMatchRun）がこの区切りに依存するので、値を変えると壊れた入力への
    // 報告が変わる。
    fileprivate static let matchRunCapacity = 256
    // 復号済み match を dictionary へ写すまでに溜める個数の上限。辞書が cache に収まら
    // ないとき（64 MiB など）、match の source 読みは毎回 DRAM まで行く。写すのを溜めて
    // まとめて行うと、その miss が互いに重なって（memory-level parallelism）待ちが
    // 個数分に割れる。復号直後に一つずつ写すと miss は復号 1〜2 個分としか重ならない。
    // 逆に辞書が cache に収まるときは、一つずつ写すほうが copy が bit 復号の隙間に
    // 収まって速い（M4 Max 実測: 8 MiB 辞書で 1 個が最速、64 MiB で 32 個が最速）。
    fileprivate static let matchGroupCapacity = 32
    // この辞書長を超える ring では match を matchGroupCapacity 個ずつ写す。
    private static let groupedCopyDictionaryThreshold = 8 * 1_024 * 1_024
    fileprivate static let probabilityInitialValue: UInt16 = 1 << 10
    fileprivate static let maximumPositionStates = 1 << 4
    // LZMA2 は lc + lp <= 4 なので literal coder は最大 16 個。
    private static let maximumLZMA2LiteralProbabilities = LZMAProperties.literalCoderSize << 4

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
    private let matchGroupStorage: UnsafeMutableBufferPointer<UInt64>
    private let matchGroupLimit: Int
    private var dictionaryPosition = 0
    private var dictionaryBytesAvailable = 0
    // literal context の直前 byte は保持せず、必要なときに ring の直前位置から読む
    // （履歴が空なら 0）。literal/position context は dictionary reset からの連続出力
    // 位置を使う。LZMA2 の coding-state reset だけではこの位置を巻き戻さない。
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
    ///   - outputSizeHint: For a stream terminated by an end marker, the output
    ///     size that the container declares separately. It only bounds the
    ///     dictionary allocation and never decides where the stream ends. Output
    ///     beyond the declaration is left to the container's own check, and a
    ///     reference past the retained dictionary fails as an invalid distance.
    public convenience init(
        source: any ByteSource,
        offset: UInt64,
        compressedSize: UInt64,
        properties: [UInt8],
        expectedSize: UInt64?,
        dictionarySizeLimit: UInt64,
        outputSizeHint: UInt64? = nil
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
        if let bound = expectedSize ?? outputSizeHint {
            retainedDictionarySize = min(
                effectiveDictionarySize,
                max(UInt64(1), bound)
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
            literalProbabilityCapacity: literalCount,
            inputBufferCapacity: Int(min(UInt64(Self.inputBufferSize), max(1, compressedSize))),
            initializeProbabilities: true
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
        literalProbabilityCapacity: Int,
        inputBufferCapacity: Int,
        initializeProbabilities: Bool
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
        let inputAllocationSize = inputBufferCapacity &+ Self.maximumBytesPerSymbol
        guard let inputRaw = malloc(inputAllocationSize) else {
            free(probabilityRaw)
            free(dictionaryRaw)
            throw KaitoError.limitExceeded("unable to allocate LZMA input buffer")
        }
        let matchGroupBytes = Self.matchGroupCapacity
            &* MemoryLayout<UInt64>.stride
        guard let matchGroupRaw = malloc(matchGroupBytes) else {
            free(inputRaw)
            free(probabilityRaw)
            free(dictionaryRaw)
            throw KaitoError.limitExceeded("unable to allocate LZMA match group")
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
        let matchGroupPointer = matchGroupRaw.bindMemory(
            to: UInt64.self,
            capacity: Self.matchGroupCapacity
        )
        // History references are checked against dictionaryBytesAvailable;
        // range input is written and its 64-byte sentinel cleared by refill;
        // match-group entries are written before the count exposes them.
        // These trivial raw buffers do not need eager initialization.
        if initializeProbabilities {
            probabilityPointer.initialize(
                repeating: Self.probabilityInitialValue,
                count: probabilityCount
            )
        }

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
        self.matchGroupStorage = UnsafeMutableBufferPointer(
            start: matchGroupPointer,
            count: Self.matchGroupCapacity
        )
        self.matchGroupLimit = dictionaryCount > Self.groupedCopyDictionaryThreshold
            ? Self.matchGroupCapacity
            : 1
    }

    // LZMA2 の外側が保持する辞書・入力 buffer・確率表を一度だけ確保し、
    // 各 chunk では range coder の scalar state と入力内容だけを差し替える。
    convenience init(
        lzma2DictionarySize: UInt64,
        expectedSize: UInt64?,
        dictionarySizeLimit: UInt64,
        compressedSizeHint: UInt64? = nil
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
            literalProbabilityCapacity: Self.maximumLZMA2LiteralProbabilities,
            inputBufferCapacity: Int(min(
                LZMA2ChunkHeader.maximumPackedChunkSize,
                max(1, compressedSizeHint ?? LZMA2ChunkHeader.maximumPackedChunkSize)
            )),
            // The first compressed LZMA2 chunk must reset coding state. Raw
            // chunks do not consult probabilities, so initialize only on reset.
            initializeProbabilities: false
        )
        finished = true
    }

    deinit {
        if let base = probabilities.baseAddress {
            free(UnsafeMutableRawPointer(base))
        }
        if let base = dictionary.baseAddress {
            free(UnsafeMutableRawPointer(base))
        }
        if let base = inputStorage.baseAddress {
            free(UnsafeMutableRawPointer(base))
        }
        if let base = matchGroupStorage.baseAddress {
            free(UnsafeMutableRawPointer(base))
        }
    }

    /// Indicates whether the known output size or LZMA end marker was reached.
    public var isFinished: Bool {
        finished
    }

    /// end marker に到達し、与えた圧縮範囲を byte 単位で使い切ったかどうか。
    var consumedEntireInput: Bool {
        finished && (rangeDecoder?.consumedAllInput ?? false)
    }

    /// Decodes at most one 256 KiB output chunk into `buffer`.
    public func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !finished else {
            return 0
        }
        guard let destinationRaw = buffer.baseAddress,
              let dictionaryBase = dictionary.baseAddress,
              let probabilityBase = probabilities.baseAddress,
              let matchGroupBase = matchGroupStorage.baseAddress else {
            throw KaitoError.malformed("LZMA decoder storage is unavailable")
        }
        guard var decoder = rangeDecoder else {
            throw KaitoError.malformed("LZMA range decoder is unavailable")
        }

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

        // class property はここで一度だけ cursor へ移し、hot loop 終了時に一度だけ戻す。
        // 各 frame は cursor を value で受け取り、frame の出入りでだけ読み書きする。
        var window = LZMAWindowCursor(
            dictionaryPosition: self.dictionaryPosition,
            dictionaryBytesAvailable: self.dictionaryBytesAvailable,
            processedPosition: self.processedPosition,
            outputPosition: self.outputPosition,
            produced: 0,
            flushed: 0,
            flushStart: self.dictionaryPosition,
            pendingMatchLength: self.pendingMatchLength,
            finished: self.finished
        )
        var coder = LZMACoderCursor(
            decoder: decoder.hotState,
            state: self.state,
            rep0: self.rep0,
            rep1: self.rep1,
            rep2: self.rep2,
            rep3: self.rep3
        )
        var failure: LZMAHotFailure?
        var matchHeadPending = false

        decodeLoop: while window.produced < capacity, !window.finished {
            if window.pendingMatchLength > 0 {
                copyPendingLZMAMatch(
                    dictionary: dictionaryBase,
                    dictionaryCount: dictionaryCount,
                    destination: destination,
                    capacity: capacity,
                    distance: coder.rep0,
                    window: &window
                )
                if let expectedSize, window.outputPosition == expectedSize {
                    window.finished = true
                }
                continue
            }

            // 一シンボルの最大 48 input bytes より余裕を持たせた境界でだけ refill する。
            // decodeBit 自体は非 throwing で、物理 EOF は sentinel flag として後で変換する。
            if coder.decoder.remainingInput < Self.maximumBytesPerSymbol,
               decoder.hasUnreadSource {
                decoder.commit(coder.decoder)
                try decoder.refillInput()
                coder.decoder = decoder.hotState
            }

            var outputBudget = capacity &- window.produced
            if let expectedSize, window.outputPosition <= expectedSize {
                let remainingExpected = expectedSize &- window.outputPosition
                if remainingExpected < UInt64(outputBudget) {
                    outputBudget = Int(remainingExpected)
                }
            }
            if outputBudget == 0 {
                window.finished = true
                continue
            }
            let refillLimit = decoder.hasUnreadSource
                ? coder.decoder.inputCount &- Self.maximumBytesPerSymbol
                : Int.max
            let matchRun = decodeLZMANewMatchRun(
                probabilities: probabilityBase,
                positionStateMask: positionStateMask,
                dictionary: dictionaryBase,
                dictionaryCount: dictionaryCount,
                destination: destination,
                capacity: capacity,
                outputLimit: expectedSize ?? UInt64.max,
                outputBudget: outputBudget,
                refillLimit: refillLimit,
                firstMatchPending: matchHeadPending,
                group: matchGroupBase,
                groupLimit: matchGroupLimit,
                window: &window,
                coder: &coder
            )
            matchHeadPending = false
            if let expectedSize, window.outputPosition == expectedSize {
                window.finished = true
            }
            // 読み越しは run 内の検証失敗より優先する（decodeLZMANewMatchRun の注記）。
            if coder.decoder.overrun {
                failure = .truncatedInput
                break decodeLoop
            }
            if let runFailure = matchRun.failure {
                failure = runFailure
                break decodeLoop
            }
            if window.pendingMatchLength > 0
                || window.produced == capacity
                || window.finished {
                continue
            }

            let runStop = matchRun.stop
            if runStop == LZMABatchStop.full
                || runStop == LZMABatchStop.refill {
                continue
            }
            if runStop == LZMABatchStop.endMarker {
                guard expectedSize == nil else {
                    failure = .earlyEndMarker
                    break decodeLoop
                }
                window.finished = true
                continue
            }
            guard runStop != LZMABatchStop.truncated else {
                failure = .truncatedInput
                break decodeLoop
            }

            if runStop == LZMABatchStop.literal {
                var literalMaximum = min(
                    capacity &- window.produced,
                    dictionaryCount &- window.dictionaryPosition
                )
                if let expectedSize {
                    guard window.outputPosition <= expectedSize else {
                        failure = .outputOverflow
                        break decodeLoop
                    }
                    let remainingExpected = expectedSize &- window.outputPosition
                    if remainingExpected < UInt64(literalMaximum) {
                        literalMaximum = Int(remainingExpected)
                    }
                }
                guard literalMaximum > 0 else {
                    failure = .outputOverflow
                    break decodeLoop
                }
                let literalResult = decodeLZMALiteralRun(
                    probabilities: probabilityBase,
                    dictionary: dictionaryBase,
                    dictionaryCount: dictionaryCount,
                    literalContextShift: literalContextShift,
                    literalPreviousShift: literalPreviousShift,
                    literalPositionMask: literalPositionMask,
                    positionStateMask: positionStateMask,
                    maximumCount: literalMaximum,
                    refillLimit: refillLimit,
                    window: &window,
                    coder: &coder
                )
                let literalCount = Int(UInt32(truncatingIfNeeded: literalResult))
                window.produced &+= literalCount
                if window.dictionaryPosition == 0 {
                    flushLZMAWindow(
                        dictionary: dictionaryBase,
                        destination: destination,
                        window: &window
                    )
                }
                if let expectedSize, window.outputPosition == expectedSize {
                    window.finished = true
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

            guard runStop == LZMABatchStop.repeated else {
                failure = .truncatedInput
                break decodeLoop
            }
            let positionState = Int(window.processedPosition & positionStateMask)
            let statePositionIndex = coder.state &* Self.maximumPositionStates &+ positionState
            let matchLength = decodeLZMARepeatedMatchSymbol(
                probabilities: probabilityBase,
                positionState: positionState,
                statePositionIndex: statePositionIndex,
                coder: &coder
            )
            if coder.decoder.overrun {
                failure = .truncatedInput
                break decodeLoop
            }
            let byteDistance = Int(coder.rep0) &+ 1
            guard byteDistance <= window.dictionaryBytesAvailable,
                  byteDistance <= dictionaryCount else {
                failure = .invalidDistance
                break decodeLoop
            }
            if let expectedSize {
                guard window.outputPosition <= expectedSize,
                      UInt64(matchLength) <= expectedSize &- window.outputPosition else {
                    failure = .outputOverflow
                    break decodeLoop
                }
            }
            emitLZMAMatch(
                length: matchLength,
                distance: coder.rep0,
                dictionary: dictionaryBase,
                dictionaryCount: dictionaryCount,
                destination: destination,
                capacity: capacity,
                window: &window
            )
            if let expectedSize, window.outputPosition == expectedSize {
                window.finished = true
            }
        }

        if coder.decoder.overrun, failure == nil {
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
        guard window.produced > 0 || window.finished else {
            throw KaitoError.malformed("LZMA stream made no progress")
        }

        if window.produced > window.flushed {
            flushLZMAWindow(
                dictionary: dictionaryBase,
                destination: destination,
                window: &window
            )
        }
        guard window.flushed == window.produced else {
            throw KaitoError.malformed("LZMA output window accounting mismatch")
        }

        decoder.commit(coder.decoder)
        rangeDecoder = decoder
        self.dictionaryPosition = window.dictionaryPosition
        self.dictionaryBytesAvailable = window.dictionaryBytesAvailable
        self.processedPosition = window.processedPosition
        self.outputPosition = window.outputPosition
        self.state = coder.state
        self.rep0 = coder.rep0
        self.rep1 = coder.rep1
        self.rep2 = coder.rep2
        self.rep3 = coder.rep3
        self.pendingMatchLength = window.pendingMatchLength
        self.finished = window.finished
        return window.produced
    }

    // LZMA2 chunk は range coder だけを毎回初期化し、reset flag に応じて
    // 確率状態を初期化する。dictionary は別 flag のときだけ捨てる。
    func beginLZMA2Chunk(
        reader: inout ByteReader,
        compressedSize: UInt64,
        unpackedSize: UInt64,
        resetState: Bool,
        properties: UInt8?
    ) throws {
        guard unpackedSize > 0, unpackedSize <= LZMA2ChunkHeader.maximumUnpackedChunkSize else {
            throw KaitoError.malformed("invalid LZMA2 unpacked chunk size")
        }
        guard compressedSize > 0, compressedSize <= LZMA2ChunkHeader.maximumPackedChunkSize else {
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

        guard compressedSize <= reader.remaining else { throw KaitoError.truncated }
        expectedSize = try Checked.add(outputPosition, unpackedSize)
        rangeDecoder = try LZMARangeDecoder(
            reader: &reader, compressedSize: compressedSize, storage: inputStorage
        )
        pendingMatchLength = 0
        finished = false
    }

    func resetLZMA2Dictionary() {
        dictionaryPosition = 0
        dictionaryBytesAvailable = 0
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
        // 直前 byte は ring の newPosition - 1 に残るので別に保持しない。
        dictionaryPosition = newPosition
        if amount >= dictionaryCount - dictionaryBytesAvailable {
            dictionaryBytesAvailable = dictionaryCount
        } else {
            dictionaryBytesAvailable += amount
        }
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
        if let base = probabilities.baseAddress {
            // Properties can change only with a coding-state reset. Initialize
            // every model active under the new properties, including newly
            // activated contexts, without touching the unused literal tail.
            let count = LZMAProbabilityOffset.literals
                + (LZMAProperties.literalCoderSize << (literalContextBits + literalPositionBits))
            // 1,024 (0x0400) の UInt16 を並べる。count は確保済み要素数以下で、
            // 8 byte pattern の fill は要素単位の store より速い。
            var pattern: (UInt16, UInt16, UInt16, UInt16) = (
                Self.probabilityInitialValue, Self.probabilityInitialValue,
                Self.probabilityInitialValue, Self.probabilityInitialValue
            )
            withUnsafeBytes(of: &pattern) { patternBytes in
                memset_pattern8(
                    UnsafeMutableRawPointer(base),
                    patternBytes.baseAddress!,
                    count &* MemoryLayout<UInt16>.stride
                )
            }
        }
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

// LZMA の二値 range coder の入力と range/code。hot loop は LZMAHotRangeState に写して使い、
// 入力末尾の読み越しは zero sentinel で遅延検出する。同じ coder を BCJ2Decompressor が
// inline で持つ（一覧: Core/BitReader.swift の先頭）。
private struct LZMARangeDecoder {
    private let source: (any ByteSource)?
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
        try initializeCode()
    }

    // LZMA2 の payload は外側の 256 KiB 窓から既存 storage へ写す。source を
    // 持たず、valid 末尾の 64 byte sentinel と consumedAllInput の条件は共通にする。
    init(
        reader: inout ByteReader, compressedSize: UInt64,
        storage: UnsafeMutableBufferPointer<UInt8>
    ) throws {
        let count = try Checked.toInt(compressedSize)
        guard storage.count > LZMADecoder.maximumBytesPerSymbol,
              count <= storage.count - LZMADecoder.maximumBytesPerSymbol,
              let base = storage.baseAddress else { throw KaitoError.truncated }
        self.source = nil
        self.endOffset = compressedSize
        self.storageBase = base
        self.storageCount = storage.count - LZMADecoder.maximumBytesPerSymbol
        self.nextSourceOffset = compressedSize
        try reader.read(into: UnsafeMutableRawBufferPointer(start: base, count: count))
        inputCount = count
        Darwin.memset(base.advanced(by: count), 0, LZMADecoder.maximumBytesPerSymbol)
        try initializeCode()
    }

    private mutating func initializeCode() throws {
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
            guard let source else { throw KaitoError.truncated }
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
    // lzma-specification.txt の kNumBitModelTotalBits、kBitModelTotal、kNumMoveBits、kTopValue。
    static let probabilityBits: UInt32 = 11
    static let probabilityTotal: UInt32 = 1 << 11
    static let probabilityMoveBits: UInt32 = 5
    static let rangeTop: UInt32 = 1 << 24

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
    // code < bound は LLVM が既に csel 化するため手書き branchless は効かない
    // （経緯と測定: design.md §11「LZMA / LZMA2 bit tree 先読み」）。
    @inline(__always)
    mutating func decodeBit(
        probability: UInt32,
        store probabilityPointer: UnsafeMutablePointer<UInt16>
    ) -> UInt32 {
        var probability = probability
        let bound = (range >> Self.probabilityBits) &* probability
        let bit: UInt32
        if code < bound {
            range = bound
            probability &+= (Self.probabilityTotal &- probability) >> Self.probabilityMoveBits
            bit = 0
        } else {
            range &-= bound
            code &-= bound
            probability &-= probability >> Self.probabilityMoveBits
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
        if range < Self.rangeTop {
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

// LZMA の 12 状態（lzma-specification.txt の UpdateState_*）。0...6 は直前の symbol が
// literal、7...11 は直前が match / rep。遷移は次のとおり。
//   literal:   s < 4 → 0、s < 10 → s - 3、それ以外 → s - 6
//   match:     s < 7 → 7、それ以外 → 10
//   rep:       s < 7 → 8、それ以外 → 11
//   short rep: s < 7 → 9、それ以外 → 11
// s >= 7 の literal は rep0 の位置の byte と照合しながら復号する（matched literal）。
private enum LZMAState {
    /// 直前の symbol が literal である state の数（kNumLitStates）。
    static let literalStateCount = 7
    static let matchAfterLiteral = 7
    static let matchAfterMatch = 10
    static let repAfterLiteral = 8
    static let repAfterMatch = 11
    static let shortRepAfterLiteral = 9
    static let shortRepAfterMatch = 11
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

// read(into:) の hot loop が frame 間で受け渡す window と出力の scalar。
private struct LZMAWindowCursor {
    var dictionaryPosition: Int
    var dictionaryBytesAvailable: Int
    var processedPosition: UInt64
    var outputPosition: UInt64
    var produced: Int
    // produced - flushed が ring の flushStart から続く未 flush 分。
    var flushed: Int
    var flushStart: Int
    var pendingMatchLength: Int
    var finished: Bool
}

// range coder の hot state と LZMA の coding state。repN は実距離 - 1。
private struct LZMACoderCursor {
    var decoder: LZMAHotRangeState
    var state: Int
    var rep0: UInt32
    var rep1: UInt32
    var rep2: UInt32
    var rep3: UInt32
}

private struct LZMAMatchRunResult {
    var stop: UInt32
    var failure: LZMAHotFailure?
}

// 連続する new match を最大 matchRunCapacity 個まで一つの frame で復号し、検証した
// match を matchGroupCapacity 個ずつまとめて dictionary へ写す。copy の load/store は
// range coder の依存鎖と独立なので、別の loop で後から写すより CPU が bit 復号と重ねて
// 実行でき、まとめることで辞書外（DRAM）への source 読みの miss が互いに重なる。
//
// この frame は小さく保つ。Optional や struct の field を hot loop に持ち込むと
// inliner の予算を超え、bit tree の helper が inline されず range state も spill して
// 復号全体が 1.5 倍以上遅くなった（実測）。window の struct は group を写すときにだけ
// 触り、検証は frame 入口の値と復号済み長さの和から行う。
//
// 誤り検出の順序は旧来の「run 分を復号してから順に検証・copy する」形と同じに保つ。
// run 内のどこかで入力を読み越していれば呼出元が truncated を優先し、そうでなければ
// 最初の不正 distance / 出力超過を報告する。検証に失敗した後も run の終端まで復号だけを
// 続ける（drain）のはそのためで、hot path には影響しない。失敗した read は何も返さない
// ので、失敗以降は copy も行わない。
@inline(never)
private func decodeLZMANewMatchRun(
    probabilities: UnsafeMutablePointer<UInt16>,
    positionStateMask: UInt64,
    dictionary: UnsafeMutablePointer<UInt8>,
    dictionaryCount: Int,
    destination: UnsafeMutablePointer<UInt8>,
    capacity: Int,
    outputLimit: UInt64,
    outputBudget: Int,
    refillLimit: Int,
    firstMatchPending: Bool,
    group: UnsafeMutablePointer<UInt64>,
    groupLimit: Int,
    window: inout LZMAWindowCursor,
    coder: inout LZMACoderCursor
) -> LZMAMatchRunResult {
    var localDecoder = coder.decoder
    var localState = coder.state
    var rep0 = coder.rep0
    var rep1 = coder.rep1
    var rep2 = coder.rep2
    var rep3 = coder.rep3
    // 検証と position context は、frame 入口の値に復号済み match 長の和 generated を
    // 足して求める。copy の進み方（group 単位、分割、drain）に依存しない。
    let entryAvailable = window.dictionaryBytesAvailable
    let entryOutputPosition = window.outputPosition
    let modelBase = window.processedPosition
    var count = 0
    var generated = 0
    var groupCount = 0
    var stop = LZMABatchStop.full
    var matchPending = firstMatchPending
    var failure: UInt32 = 0

    while count < LZMADecoder.matchRunCapacity, generated < outputBudget {
        let positionState = Int((modelBase &+ UInt64(generated)) & positionStateMask)
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
        let length = Int(UInt32(truncatingIfNeeded: packedMatch))
        // 検証は match を写す前の位置に対して行う。
        let outputPosition = entryOutputPosition &+ UInt64(generated)
        let available = generated >= dictionaryCount &- entryAvailable
            ? dictionaryCount
            : entryAvailable &+ generated
        count &+= 1
        generated &+= length
        localState = localState < LZMAState.literalStateCount
            ? LZMAState.matchAfterLiteral
            : LZMAState.matchAfterMatch
        rep3 = rep2
        rep2 = rep1
        rep1 = rep0
        rep0 = distance
        if failure != 0 {
            continue
        }

        // available <= dictionaryCount なので距離の検証はこれで足りる。
        guard Int(distance) &+ 1 <= available else {
            failure = LZMAMatchRunFailure.invalidDistance
            continue
        }
        guard outputPosition <= outputLimit,
              UInt64(length) <= outputLimit &- outputPosition else {
            failure = LZMAMatchRunFailure.outputOverflow
            continue
        }
        group[groupCount] = packedMatch
        groupCount &+= 1
        if groupCount == groupLimit {
            applyLZMAMatchGroup(
                group,
                count: groupCount,
                dictionary: dictionary,
                dictionaryCount: dictionaryCount,
                destination: destination,
                capacity: capacity,
                window: &window
            )
            groupCount = 0
        }
    }
    if groupCount > 0, failure == 0 {
        applyLZMAMatchGroup(
            group,
            count: groupCount,
            dictionary: dictionary,
            dictionaryCount: dictionaryCount,
            destination: destination,
            capacity: capacity,
            window: &window
        )
    }

    coder.decoder = localDecoder
    coder.state = localState
    coder.rep0 = rep0
    coder.rep1 = rep1
    coder.rep2 = rep2
    coder.rep3 = rep3
    return LZMAMatchRunResult(
        stop: stop,
        failure: failure == LZMAMatchRunFailure.invalidDistance
            ? .invalidDistance
            : (failure == LZMAMatchRunFailure.outputOverflow ? .outputOverflow : nil)
    )
}

// 検証済み match の group を順に window へ写す。順序を保つので、後の match が直前の
// match の出力を参照しても正しい。分割されて残る copy は run の最後の match でしか
// 起きない（そのとき generated は outputBudget に達している）。
@inline(never)
private func applyLZMAMatchGroup(
    _ group: UnsafeMutablePointer<UInt64>,
    count: Int,
    dictionary: UnsafeMutablePointer<UInt8>,
    dictionaryCount: Int,
    destination: UnsafeMutablePointer<UInt8>,
    capacity: Int,
    window: inout LZMAWindowCursor
) {
    var localWindow = window
    var index = 0
    while index < count {
        let packedMatch = group[index]
        index &+= 1
        emitLZMAMatch(
            length: Int(UInt32(truncatingIfNeeded: packedMatch)),
            distance: UInt32(truncatingIfNeeded: packedMatch >> 32),
            dictionary: dictionary,
            dictionaryCount: dictionaryCount,
            destination: destination,
            capacity: capacity,
            window: &localWindow
        )
    }
    window = localWindow
}

private enum LZMAMatchRunFailure {
    static let invalidDistance: UInt32 = 1
    static let outputOverflow: UInt32 = 2
}

// 検証済みの match を window へ写す。両区間が ring を跨がず、距離が chunk 以上か
// 長さ以上なら直接写し、それ以外（ring 終端、出力 buffer の充足、短距離の重複、
// dictionary 長に近い距離）は分割 copy と flush の slow path に回す。
@inline(__always)
private func emitLZMAMatch(
    length: Int,
    distance: UInt32,
    dictionary: UnsafeMutablePointer<UInt8>,
    dictionaryCount: Int,
    destination: UnsafeMutablePointer<UInt8>,
    capacity: Int,
    window: inout LZMAWindowCursor
) {
    let byteDistance = Int(distance) &+ 1
    let dictionaryPosition = window.dictionaryPosition
    let sourcePosition = dictionaryPosition >= byteDistance
        ? dictionaryPosition &- byteDistance
        : dictionaryCount &- (byteDistance &- dictionaryPosition)
    if length < dictionaryCount &- dictionaryPosition,
       length <= capacity &- window.produced,
       length <= dictionaryCount &- sourcePosition,
       byteDistance >= LZMAMatchCopy.chunkSize || byteDistance >= length,
       dictionaryPosition >= byteDistance
           || sourcePosition &- dictionaryPosition >= length {
        copyLZMAMatchDirect(
            destination: dictionary.advanced(by: dictionaryPosition),
            source: dictionary.advanced(by: sourcePosition),
            amount: length
        )
        window.dictionaryPosition = dictionaryPosition &+ length
        if length >= dictionaryCount &- window.dictionaryBytesAvailable {
            window.dictionaryBytesAvailable = dictionaryCount
        } else {
            window.dictionaryBytesAvailable &+= length
        }
        window.produced &+= length
        window.processedPosition &+= UInt64(length)
        window.outputPosition &+= UInt64(length)
        return
    }
    window.pendingMatchLength = length
    copyPendingLZMAMatch(
        dictionary: dictionary,
        dictionaryCount: dictionaryCount,
        destination: destination,
        capacity: capacity,
        distance: distance,
        window: &window
    )
}

// pendingMatchLength を、出力 buffer が満ちるか match が尽きるまで写す。一回の copy は
// ring 終端で止まるので、終端に達するたびに caller buffer へ flush して先頭から続ける。
@inline(never)
private func copyPendingLZMAMatch(
    dictionary: UnsafeMutablePointer<UInt8>,
    dictionaryCount: Int,
    destination: UnsafeMutablePointer<UInt8>,
    capacity: Int,
    distance: UInt32,
    window: inout LZMAWindowCursor
) {
    repeat {
        copyLZMAMatch(
            dictionary: dictionary,
            dictionaryCount: dictionaryCount,
            distance: distance,
            pendingLength: &window.pendingMatchLength,
            produced: &window.produced,
            capacity: capacity,
            dictionaryPosition: &window.dictionaryPosition,
            dictionaryBytesAvailable: &window.dictionaryBytesAvailable,
            processedPosition: &window.processedPosition,
            outputPosition: &window.outputPosition
        )
        if window.dictionaryPosition == 0 {
            flushLZMAWindow(
                dictionary: dictionary,
                destination: destination,
                window: &window
            )
        }
    } while window.pendingMatchLength > 0 && window.produced < capacity
}

// ring の flushStart から未 flush 分を caller buffer へ写す。呼ぶのは ring の先頭に
// 戻った直後か read の終端で、未 flush 区間は常に連続している。
@inline(__always)
private func flushLZMAWindow(
    dictionary: UnsafeMutablePointer<UInt8>,
    destination: UnsafeMutablePointer<UInt8>,
    window: inout LZMAWindowCursor
) {
    UnsafeMutableRawPointer(destination.advanced(by: window.flushed)).copyMemory(
        from: UnsafeRawPointer(dictionary.advanced(by: window.flushStart)),
        byteCount: window.produced &- window.flushed
    )
    window.flushed = window.produced
    window.flushStart = 0
}

// isMatch=0 を一つ消費済みの位置から literal run を復号し、次の match head または
// buffer 境界まで dictionary の一つの連続 span に直接書く。上位 32 bit が stop、
// 下位 32 bit が書いた byte 数。
@inline(never)
private func decodeLZMALiteralRun(
    probabilities: UnsafeMutablePointer<UInt16>,
    dictionary: UnsafeMutablePointer<UInt8>,
    dictionaryCount: Int,
    literalContextShift: UInt64,
    literalPreviousShift: UInt8,
    literalPositionMask: UInt64,
    positionStateMask: UInt64,
    maximumCount: Int,
    refillLimit: Int,
    window: inout LZMAWindowCursor,
    coder: inout LZMACoderCursor
) -> UInt64 {
    var localDecoder = coder.decoder
    let rep0 = coder.rep0
    var localDictionaryPosition = window.dictionaryPosition
    var localDictionaryBytesAvailable = window.dictionaryBytesAvailable
    var localProcessedPosition = window.processedPosition
    var localOutputPosition = window.outputPosition
    var localState = coder.state
    var produced = 0
    var stop = LZMALiteralStop.full
    // 直前 byte は ring の直前位置にある。dictionary reset 直後（履歴なし）は 0。
    var localPreviousByte: UInt8 = 0
    if localDictionaryBytesAvailable > 0 {
        localPreviousByte = dictionary[
            localDictionaryPosition == 0
                ? dictionaryCount &- 1
                : localDictionaryPosition &- 1
        ]
    }

    while produced < maximumCount {
        let positionPart = localProcessedPosition & literalPositionMask
        let previousPart = UInt64(localPreviousByte >> literalPreviousShift)
        let context = (positionPart << literalContextShift) | previousPart
        let literalBase = LZMAProbabilityOffset.literals
            &+ Int(truncatingIfNeeded: context) &* LZMAProperties.literalCoderSize

        var symbol = 1
        if localState >= LZMAState.literalStateCount {
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
        // literal 後の遷移（LZMAState の表）。
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
    window.dictionaryPosition = localDictionaryPosition
    window.dictionaryBytesAvailable = localDictionaryBytesAvailable
    window.processedPosition = localProcessedPosition
    window.outputPosition = localOutputPosition
    coder.state = localState
    coder.decoder = localDecoder
    return (UInt64(stop) << 32)
        | UInt64(UInt32(truncatingIfNeeded: produced))
}

// new match は rep state を受け渡さずに復号する。上位 32 bit が distance、
// 下位 32 bit が length。@_transparent は必須。@inline(__always) だけでは、copy を
// 併せ持つ decodeLZMANewMatchRun に対して performance inliner がこの本体を inline せず
// （呼出先として残り、range state が inout で memory を往復する）、復号が 1.5 倍遅く
// なった（実測、design.md §11 の bit tree と同じ機構）。
@_transparent
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
    coder: inout LZMACoderCursor
) -> Int {
    var localDecoder = coder.decoder
    var localState = coder.state
    var localRep0 = coder.rep0
    var localRep1 = coder.rep1
    var localRep2 = coder.rep2
    var localRep3 = coder.rep3
    let matchLength: Int

    if localDecoder.decodeBit(
        probabilities.advanced(by: LZMAProbabilityOffset.isRepG0 &+ localState)
    ) == 0 {
        if localDecoder.decodeBit(
            probabilities.advanced(
                by: LZMAProbabilityOffset.isRep0Long &+ statePositionIndex
            )
        ) == 0 {
            localState = localState < LZMAState.literalStateCount
                ? LZMAState.shortRepAfterLiteral
                : LZMAState.shortRepAfterMatch
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
            localState = localState < LZMAState.literalStateCount
                ? LZMAState.repAfterLiteral
                : LZMAState.repAfterMatch
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
        localState = localState < LZMAState.literalStateCount
            ? LZMAState.repAfterLiteral
            : LZMAState.repAfterMatch
    }

    coder.decoder = localDecoder
    coder.state = localState
    coder.rep0 = localRep0
    coder.rep1 = localRep1
    coder.rep2 = localRep2
    coder.rep3 = localRep3
    return matchLength
}

// literal 木も深さ 8 の bit tree なので同じ先読みを使う。8 段を手展開しないこと。
// 手展開すると本体が大きくなり、book-solid.7z が実測で退行する
// (@inline(__always) のみで +31%、@_transparent を足しても +18%。
// 測定: design.md §11「LZMA / LZMA2 bit tree 先読み」)。
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
    processedPosition: inout UInt64,
    outputPosition: inout UInt64
) {
    // 一回の生成を dictionary 終端で止めるため、caller への flush 範囲は常に連続する。
    let amount = min(
        pendingLength,
        min(capacity &- produced, dictionaryCount &- dictionaryPosition)
    )
    guard amount > 0 else { return }
    let byteDistance = Int(distance) &+ 1
    let sourcePosition = dictionaryPosition >= byteDistance
        ? dictionaryPosition &- byteDistance
        : dictionaryCount &- (byteDistance &- dictionaryPosition)

    if byteDistance >= amount || byteDistance >= LZMAMatchCopy.chunkSize,
       amount <= dictionaryCount &- sourcePosition {
        // source が非 wrap で、非重複か chunk 以上の距離。destination は amount の
        // 算出時に ring 終端で切ってある。
        if sourcePosition < dictionaryPosition
            || sourcePosition &- dictionaryPosition >= amount {
            copyLZMAMatchDirect(
                destination: dictionary.advanced(by: dictionaryPosition),
                source: dictionary.advanced(by: sourcePosition),
                amount: amount
            )
        } else {
            // 距離が dictionary 長に近く、source が ring 末尾、destination が先頭にある。
            // 論理的には非重複でも memory 上は後方から重なるので memmove に任せる。
            UnsafeMutableRawPointer(dictionary.advanced(by: dictionaryPosition)).copyMemory(
                from: UnsafeRawPointer(dictionary.advanced(by: sourcePosition)),
                byteCount: amount
            )
        }
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

    if amount >= dictionaryCount &- dictionaryBytesAvailable {
        dictionaryBytesAvailable = dictionaryCount
    } else {
        dictionaryBytesAvailable &+= amount
    }
    pendingLength &-= amount
    produced &+= amount
    processedPosition &+= UInt64(amount)
    outputPosition &+= UInt64(amount)
}

private enum LZMAMatchCopy {
    /// chunk copy の単位。距離がこれ以上なら、各 chunk は書き込み済みの byte だけを読む。
    static let chunkSize = 16
}

// 長さ amount（1 以上）の match を、ring を跨がない source から destination へ写す。
// 前提は byteDistance >= amount（非重複）または byteDistance >= chunkSize で、かつ
// memory 上で source が destination より前にあるか、両区間が重ならないこと（ring 末尾の
// source と先頭の destination が後方から重なる場合は末尾揃えの chunk が壊れる）。
// 末尾は終端に揃えた chunk を重ねて書き、長さ分を超えて書かない。超えて書くと、
// ring 一周前の最古の履歴（距離 dictionaryCount 付近の正当な参照先）を壊す。
// chunk 未満の長さは frame を太らせないよう別関数に置く。LZMAMatchCopyTests が
// byte loop と総当たりで比較するため internal。
@inline(__always)
func copyLZMAMatchDirect(
    destination: UnsafeMutablePointer<UInt8>,
    source: UnsafeMutablePointer<UInt8>,
    amount: Int
) {
    guard amount >= LZMAMatchCopy.chunkSize else {
        copyLZMAShortMatch(destination: destination, source: source, amount: amount)
        return
    }
    let destinationRaw = UnsafeMutableRawPointer(destination)
    let sourceRaw = UnsafeRawPointer(source)
    // 16 byte chunk を前から順に書き、最後の chunk を終端に揃える。重複 match
    // （距離 >= 16）でも各 chunk は 16 byte 以上前に書いた byte だけを読む。
    var offset = 0
    let last = amount &- LZMAMatchCopy.chunkSize
    while offset < last {
        let low = sourceRaw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
        let high = sourceRaw.loadUnaligned(fromByteOffset: offset &+ 8, as: UInt64.self)
        destinationRaw.storeBytes(of: low, toByteOffset: offset, as: UInt64.self)
        destinationRaw.storeBytes(of: high, toByteOffset: offset &+ 8, as: UInt64.self)
        offset &+= LZMAMatchCopy.chunkSize
    }
    let low = sourceRaw.loadUnaligned(fromByteOffset: last, as: UInt64.self)
    let high = sourceRaw.loadUnaligned(fromByteOffset: last &+ 8, as: UInt64.self)
    destinationRaw.storeBytes(of: low, toByteOffset: last, as: UInt64.self)
    destinationRaw.storeBytes(of: high, toByteOffset: last &+ 8, as: UInt64.self)
}

// chunk 未満（1...15 byte）の match を、先頭と終端に揃えた二枚の load/store で写す。
// 前提は copyLZMAMatchDirect と同じ。長さ 1（short rep や分割後の残り）は 1 byte。
@inline(never)
func copyLZMAShortMatch(
    destination: UnsafeMutablePointer<UInt8>,
    source: UnsafeMutablePointer<UInt8>,
    amount: Int
) {
    let destinationRaw = UnsafeMutableRawPointer(destination)
    let sourceRaw = UnsafeRawPointer(source)
    if amount >= 8 {
        let head = sourceRaw.loadUnaligned(as: UInt64.self)
        let tail = sourceRaw.loadUnaligned(fromByteOffset: amount &- 8, as: UInt64.self)
        destinationRaw.storeBytes(of: head, as: UInt64.self)
        destinationRaw.storeBytes(of: tail, toByteOffset: amount &- 8, as: UInt64.self)
    } else if amount >= 4 {
        let head = sourceRaw.loadUnaligned(as: UInt32.self)
        let tail = sourceRaw.loadUnaligned(fromByteOffset: amount &- 4, as: UInt32.self)
        destinationRaw.storeBytes(of: head, as: UInt32.self)
        destinationRaw.storeBytes(of: tail, toByteOffset: amount &- 4, as: UInt32.self)
    } else if amount >= 2 {
        let head = sourceRaw.loadUnaligned(as: UInt16.self)
        let tail = sourceRaw.loadUnaligned(fromByteOffset: amount &- 2, as: UInt16.self)
        destinationRaw.storeBytes(of: head, as: UInt16.self)
        destinationRaw.storeBytes(of: tail, toByteOffset: amount &- 2, as: UInt16.self)
    } else {
        destination.pointee = source.pointee
    }
}
