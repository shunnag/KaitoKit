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
    fileprivate static let probabilityInitialValue: UInt16 = 1 << 10
    private static let stateCount = 12
    fileprivate static let maximumPositionStates = 1 << 4

    private var rangeDecoder: LZMARangeDecoder?
    private var expectedSize: UInt64?
    private var literalContextBits: Int
    private var literalPositionBits: Int
    private var positionStateMask: UInt64

    // 各確率配列の添字は仕様で定義された有限範囲だけを使う。
    private var isMatch: [UInt16]
    private var isRep: [UInt16]
    private var isRepG0: [UInt16]
    private var isRepG1: [UInt16]
    private var isRepG2: [UInt16]
    private var isRep0Long: [UInt16]
    private var positionSlot: [UInt16]
    private var positionModels: [UInt16]
    private var alignment: [UInt16]
    private var literals: [UInt16]
    private var matchLength = LZMALengthDecoder()
    private var repeatedLength = LZMALengthDecoder()

    private var dictionary: [UInt8]
    private var dictionaryPosition = 0
    private var dictionaryBytesAvailable: UInt64 = 0
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

        try self.init(
            configuration: configuration,
            retainedDictionarySize: retainedDictionarySize,
            expectedSize: expectedSize
        )

        // 既知サイズ 0 でも range-coder 初期値を読み、空または切れた入力を受理しない。
        if expectedSize == 0 {
            rangeDecoder = try LZMARangeDecoder(
                source: source,
                offset: offset,
                endOffset: compressedEnd
            )
            finished = true
        } else {
            rangeDecoder = try LZMARangeDecoder(
                source: source,
                offset: offset,
                endOffset: compressedEnd
            )
        }
    }

    private init(
        configuration: LZMAProperties,
        retainedDictionarySize: UInt64,
        expectedSize: UInt64?
    ) throws {
        let dictionaryCount = try Checked.toInt(retainedDictionarySize)
        guard dictionaryCount > 0 else {
            throw KaitoError.malformed("LZMA dictionary must not be empty")
        }
        let literalCount = try configuration.literalProbabilityCount()

        self.rangeDecoder = nil
        self.expectedSize = expectedSize
        self.literalContextBits = configuration.literalContextBits
        self.literalPositionBits = configuration.literalPositionBits
        self.positionStateMask = configuration.positionStateMask
        self.dictionary = [UInt8](repeating: 0, count: dictionaryCount)

        self.isMatch = Self.initialProbabilities(Self.stateCount * Self.maximumPositionStates)
        self.isRep = Self.initialProbabilities(Self.stateCount)
        self.isRepG0 = Self.initialProbabilities(Self.stateCount)
        self.isRepG1 = Self.initialProbabilities(Self.stateCount)
        self.isRepG2 = Self.initialProbabilities(Self.stateCount)
        self.isRep0Long = Self.initialProbabilities(Self.stateCount * Self.maximumPositionStates)
        self.positionSlot = Self.initialProbabilities(4 * 64)
        self.positionModels = Self.initialProbabilities((1 << 7) - 14)
        self.alignment = Self.initialProbabilities(1 << 4)
        self.literals = Self.initialProbabilities(literalCount)
    }

    // LZMA2 の外側が保持する辞書を一度だけ確保し、各 chunk の range coder を
    // beginLZMA2Chunk で差し替える。expectedSize は辞書保持量の縮小だけに使う。
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
            expectedSize: nil
        )
        finished = true
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
        guard buffer.baseAddress != nil else {
            throw KaitoError.malformed("LZMA output buffer has no storage")
        }

        let capacity = min(buffer.count, Self.outputChunkSize)
        var output: [UInt8] = []
        output.reserveCapacity(capacity)

        while output.count < capacity, !finished {
            if pendingMatchLength > 0 {
                try copyPendingMatch(into: &output, capacity: capacity)
                continue
            }

            let before = outputPosition
            try decodeSymbol(into: &output, capacity: capacity)
            if !finished, pendingMatchLength == 0, outputPosition == before {
                throw KaitoError.malformed("LZMA stream made no progress")
            }
        }

        if !output.isEmpty {
            buffer.copyBytes(from: output)
        }
        return output.count
    }

    private static func initialProbabilities(_ count: Int) -> [UInt16] {
        [UInt16](repeating: probabilityInitialValue, count: count)
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
            endOffset: compressedEnd
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
        guard !bytes.isEmpty else { return }

        // raw chunk は最大 64 KiB だが、byte ごとの checked arithmetic は
        // 非圧縮主体の巨大書庫で支配的になる。ring に残る末尾だけを 2 区間で写し、
        // 位置と履歴量は chunk 単位で一度だけ更新する。
        let amount = bytes.count
        let dictionaryCount = dictionary.count
        let amountModuloDictionary = amount % dictionaryCount
        let newPosition = (dictionaryPosition + amountModuloDictionary) % dictionaryCount
        let retainedCount = min(amount, dictionaryCount)
        let retained = bytes.suffix(retainedCount)
        let writeStart = amount >= dictionaryCount ? newPosition : dictionaryPosition
        let firstCount = min(retainedCount, dictionaryCount - writeStart)
        let secondCount = retainedCount - firstCount
        try dictionary.withUnsafeMutableBytes { destination in
            try retained.withUnsafeBytes { source in
                guard let destinationBase = destination.baseAddress,
                      let sourceBase = source.baseAddress else {
                    throw KaitoError.malformed("LZMA2 raw dictionary storage is unavailable")
                }
                // 不変条件: retainedCount <= dictionaryCount、firstCount と
                // secondCount の和は retainedCount なので、両 copy は source と
                // dictionary の検証済み範囲内にあり、領域も相互に alias しない。
                if firstCount > 0 {
                    destinationBase.advanced(by: writeStart).copyMemory(
                        from: sourceBase,
                        byteCount: firstCount
                    )
                }
                if secondCount > 0 {
                    destinationBase.copyMemory(
                        from: sourceBase.advanced(by: firstCount),
                        byteCount: secondCount
                    )
                }
            }
        }
        dictionaryPosition = newPosition
        dictionaryBytesAvailable = min(
            UInt64(dictionaryCount),
            try Checked.add(dictionaryBytesAvailable, UInt64(amount))
        )
        previousByte = bytes.last!
        processedPosition = try Checked.add(processedPosition, UInt64(amount))
        outputPosition = try Checked.add(outputPosition, UInt64(amount))
    }

    private func apply(_ configuration: LZMAProperties) throws {
        literalContextBits = configuration.literalContextBits
        literalPositionBits = configuration.literalPositionBits
        positionStateMask = configuration.positionStateMask
        literals = Self.initialProbabilities(try configuration.literalProbabilityCount())
    }

    private func resetCodingState() {
        isMatch = Self.initialProbabilities(Self.stateCount * Self.maximumPositionStates)
        isRep = Self.initialProbabilities(Self.stateCount)
        isRepG0 = Self.initialProbabilities(Self.stateCount)
        isRepG1 = Self.initialProbabilities(Self.stateCount)
        isRepG2 = Self.initialProbabilities(Self.stateCount)
        isRep0Long = Self.initialProbabilities(Self.stateCount * Self.maximumPositionStates)
        positionSlot = Self.initialProbabilities(4 * 64)
        positionModels = Self.initialProbabilities((1 << 7) - 14)
        alignment = Self.initialProbabilities(1 << 4)
        literals = Self.initialProbabilities(literals.count)
        matchLength = LZMALengthDecoder()
        repeatedLength = LZMALengthDecoder()
        state = 0
        rep0 = 0
        rep1 = 0
        rep2 = 0
        rep3 = 0
        pendingMatchLength = 0
    }

    private func decodeSymbol(into output: inout [UInt8], capacity: Int) throws {
        guard var decoder = rangeDecoder else {
            throw KaitoError.malformed("LZMA range decoder is unavailable")
        }

        let positionState = Int(processedPosition & positionStateMask)
        let statePositionIndex = state * Self.maximumPositionStates + positionState

        if try decoder.decodeBit(&isMatch[statePositionIndex]) == 0 {
            let byte = try decodeLiteral(using: &decoder)
            updateStateAfterLiteral()
            try emit(byte, into: &output)
            rangeDecoder = decoder
            return
        }

        if try decoder.decodeBit(&isRep[state]) != 0 {
            if try decoder.decodeBit(&isRepG0[state]) == 0 {
                if try decoder.decodeBit(&isRep0Long[statePositionIndex]) == 0 {
                    updateStateAfterShortRepetition()
                    try validateDistance(rep0)
                    pendingMatchLength = 1
                    rangeDecoder = decoder
                    try copyPendingMatch(into: &output, capacity: capacity)
                    return
                }
            } else {
                let distance: UInt32
                if try decoder.decodeBit(&isRepG1[state]) == 0 {
                    distance = rep1
                } else {
                    if try decoder.decodeBit(&isRepG2[state]) == 0 {
                        distance = rep2
                    } else {
                        distance = rep3
                        rep3 = rep2
                    }
                    rep2 = rep1
                }
                rep1 = rep0
                rep0 = distance
            }

            let lengthSymbol = try repeatedLength.decode(
                positionState: positionState,
                rangeDecoder: &decoder
            )
            let length = try checkedMatchLength(lengthSymbol)
            updateStateAfterRepetition()
            try beginMatch(length: length, distance: rep0)
            rangeDecoder = decoder
            try copyPendingMatch(into: &output, capacity: capacity)
            return
        }

        rep3 = rep2
        rep2 = rep1
        rep1 = rep0

        let lengthSymbol = try matchLength.decode(
            positionState: positionState,
            rangeDecoder: &decoder
        )
        let length = try checkedMatchLength(lengthSymbol)
        updateStateAfterMatch()

        let lengthToPositionState = min(length - 2, 3)
        let slotBase = lengthToPositionState * 64
        let slot = try decodeBitTree(
            probabilities: &positionSlot,
            base: slotBase,
            bitCount: 6,
            rangeDecoder: &decoder
        )
        let distance = try decodeDistance(slot: slot, rangeDecoder: &decoder)

        if distance == UInt32.max {
            guard expectedSize == nil else {
                throw KaitoError.malformed("LZMA end marker precedes the expected size")
            }
            finished = true
            rangeDecoder = decoder
            return
        }

        rep0 = distance
        try beginMatch(length: length, distance: distance)
        rangeDecoder = decoder
        try copyPendingMatch(into: &output, capacity: capacity)
    }

    private func decodeLiteral(using decoder: inout LZMARangeDecoder) throws -> UInt8 {
        let positionPart: UInt64
        if literalPositionBits == 0 {
            positionPart = 0
        } else {
            let mask = (UInt64(1) << UInt64(literalPositionBits)) - 1
            positionPart = processedPosition & mask
        }
        let previousPart: UInt64
        if literalContextBits == 0 {
            previousPart = 0
        } else {
            previousPart = UInt64(previousByte >> UInt8(8 - literalContextBits))
        }
        let context = (positionPart << UInt64(literalContextBits)) | previousPart
        let base = try Checked.toInt(try Checked.mul(context, 0x300))

        var symbol = 1
        if state >= 7 {
            try validateDistance(rep0)
            var matchByte = dictionaryByte(distance: rep0)
            while symbol < 0x100 {
                let matchBit = Int((matchByte >> 7) & 1)
                matchByte <<= 1
                let index = base + ((1 + matchBit) << 8) + symbol
                let bit = Int(try decoder.decodeBit(&literals[index]))
                symbol = (symbol << 1) | bit
                if matchBit != bit {
                    while symbol < 0x100 {
                        let plainBit = Int(try decoder.decodeBit(&literals[base + symbol]))
                        symbol = (symbol << 1) | plainBit
                    }
                    break
                }
            }
        } else {
            while symbol < 0x100 {
                let bit = Int(try decoder.decodeBit(&literals[base + symbol]))
                symbol = (symbol << 1) | bit
            }
        }
        return UInt8(symbol - 0x100)
    }

    private func decodeDistance(
        slot: Int,
        rangeDecoder decoder: inout LZMARangeDecoder
    ) throws -> UInt32 {
        guard slot >= 0, slot < 64 else {
            throw KaitoError.malformed("invalid LZMA position slot")
        }
        if slot < 4 {
            return UInt32(slot)
        }

        let directBitCount = (slot >> 1) - 1
        let prefix = UInt64(2 | (slot & 1)) << UInt64(directBitCount)
        var distance = prefix

        if slot < 14 {
            // base は slot 4 のとき -1 だが、木の最初の添字 1 と相殺される。
            let modelBase = Int(prefix) - slot - 1
            let suffix = try decodeReverseBitTree(
                probabilities: &positionModels,
                base: modelBase,
                bitCount: directBitCount,
                rangeDecoder: &decoder
            )
            distance = try Checked.add(distance, UInt64(suffix))
        } else {
            let direct = try decoder.decodeDirectBits(directBitCount - 4)
            let shiftedDirect = try Checked.shiftLeft(UInt64(direct), by: 4)
            distance = try Checked.add(distance, shiftedDirect)
            let suffix = try decodeReverseBitTree(
                probabilities: &alignment,
                base: 0,
                bitCount: 4,
                rangeDecoder: &decoder
            )
            distance = try Checked.add(distance, UInt64(suffix))
        }

        guard distance <= UInt64(UInt32.max) else {
            throw KaitoError.malformed("LZMA distance overflow")
        }
        return UInt32(distance)
    }

    private func beginMatch(length: Int, distance: UInt32) throws {
        try validateDistance(distance)
        if let expectedSize {
            let matchEnd = try Checked.add(outputPosition, UInt64(length))
            guard matchEnd <= expectedSize else {
                throw KaitoError.malformed("LZMA output exceeds the expected size")
            }
        }
        pendingMatchLength = length
    }

    private func checkedMatchLength(_ symbol: Int) throws -> Int {
        guard symbol >= 0, symbol <= 271 else {
            throw KaitoError.malformed("invalid LZMA match length")
        }
        return symbol + 2
    }

    private func validateDistance(_ distance: UInt32) throws {
        let byteDistance = try Checked.add(UInt64(distance), 1)
        guard byteDistance <= dictionaryBytesAvailable else {
            throw KaitoError.malformed("LZMA match refers before the output start")
        }
        guard byteDistance <= UInt64(dictionary.count) else {
            throw KaitoError.malformed("LZMA match exceeds the declared dictionary")
        }
    }

    private func copyPendingMatch(into output: inout [UInt8], capacity: Int) throws {
        while pendingMatchLength > 0, output.count < capacity {
            let byte = dictionaryByte(distance: rep0)
            try emit(byte, into: &output)
            pendingMatchLength -= 1
        }
    }

    private func dictionaryByte(distance: UInt32) -> UInt8 {
        // 呼び出し前の validateDistance により Int 変換とリング範囲が保証される。
        let byteDistance = Int(distance) + 1
        let index: Int
        if dictionaryPosition >= byteDistance {
            index = dictionaryPosition - byteDistance
        } else {
            index = dictionary.count - (byteDistance - dictionaryPosition)
        }
        return dictionary[index]
    }

    private func emit(_ byte: UInt8, into output: inout [UInt8]) throws {
        if let expectedSize, outputPosition >= expectedSize {
            throw KaitoError.malformed("LZMA output exceeds the expected size")
        }

        try storeInDictionary(byte)
        output.append(byte)

        if let expectedSize, outputPosition == expectedSize {
            finished = true
        }
    }

    private func storeInDictionary(_ byte: UInt8) throws {
        dictionary[dictionaryPosition] = byte
        dictionaryPosition += 1
        if dictionaryPosition == dictionary.count {
            dictionaryPosition = 0
        }
        if dictionaryBytesAvailable < UInt64(dictionary.count) {
            dictionaryBytesAvailable += 1
        }
        previousByte = byte
        processedPosition = try Checked.add(processedPosition, 1)
        outputPosition = try Checked.add(outputPosition, 1)
    }

    private func updateStateAfterLiteral() {
        if state < 4 {
            state = 0
        } else if state < 10 {
            state -= 3
        } else {
            state -= 6
        }
    }

    private func updateStateAfterMatch() {
        state = state < 7 ? 7 : 10
    }

    private func updateStateAfterRepetition() {
        state = state < 7 ? 8 : 11
    }

    private func updateStateAfterShortRepetition() {
        state = state < 7 ? 9 : 11
    }
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

private struct LZMALengthDecoder {
    private var choice = [UInt16](
        repeating: LZMADecoder.probabilityInitialValue,
        count: 2
    )
    private var low = [UInt16](
        repeating: LZMADecoder.probabilityInitialValue,
        count: LZMADecoder.maximumPositionStates * 8
    )
    private var middle = [UInt16](
        repeating: LZMADecoder.probabilityInitialValue,
        count: LZMADecoder.maximumPositionStates * 8
    )
    private var high = [UInt16](
        repeating: LZMADecoder.probabilityInitialValue,
        count: 256
    )

    mutating func decode(
        positionState: Int,
        rangeDecoder: inout LZMARangeDecoder
    ) throws -> Int {
        guard positionState >= 0, positionState < LZMADecoder.maximumPositionStates else {
            throw KaitoError.malformed("invalid LZMA position state")
        }
        if try rangeDecoder.decodeBit(&choice[0]) == 0 {
            return try decodeBitTree(
                probabilities: &low,
                base: positionState * 8,
                bitCount: 3,
                rangeDecoder: &rangeDecoder
            )
        }
        if try rangeDecoder.decodeBit(&choice[1]) == 0 {
            let value = try decodeBitTree(
                probabilities: &middle,
                base: positionState * 8,
                bitCount: 3,
                rangeDecoder: &rangeDecoder
            )
            return 8 + value
        }
        let value = try decodeBitTree(
            probabilities: &high,
            base: 0,
            bitCount: 8,
            rangeDecoder: &rangeDecoder
        )
        return 16 + value
    }
}

private struct LZMARangeDecoder {
    private var reader: ByteReader
    private let endOffset: UInt64
    private var range: UInt32 = UInt32.max
    private var code: UInt32 = 0

    var isFinishedOK: Bool { code == 0 }
    var consumedAllInput: Bool { reader.offset == endOffset }

    init(source: any ByteSource, offset: UInt64, endOffset: UInt64) throws {
        guard offset <= endOffset, endOffset <= source.length else {
            throw KaitoError.truncated
        }
        // ByteReader は最大 256 KiB を補充するため、元 source を上限付きで包む。
        // これにより物理的な read 要求も検証済み圧縮範囲を越えて後続 ZIP record を読まない。
        self.reader = try ByteReader(
            source: LZMABoundedByteSource(source: source, endOffset: endOffset),
            offset: offset
        )
        self.endOffset = endOffset

        let first = try readByte()
        guard first == 0 else {
            throw KaitoError.malformed("invalid LZMA range-coder initialization")
        }
        for _ in 0..<4 {
            code = (code << 8) | UInt32(try readByte())
        }
    }

    mutating func decodeBit(_ probability: inout UInt16) throws -> UInt32 {
        guard probability > 0, probability < 2_048 else {
            throw KaitoError.malformed("invalid LZMA probability state")
        }

        let bound = (range >> 11) * UInt32(probability)
        let bit: UInt32
        if code < bound {
            range = bound
            probability += UInt16((2_048 - UInt32(probability)) >> 5)
            bit = 0
        } else {
            range -= bound
            code -= bound
            probability -= probability >> 5
            bit = 1
        }
        try normalize()
        return bit
    }

    mutating func decodeDirectBits(_ count: Int) throws -> UInt32 {
        guard count >= 0, count <= 26 else {
            throw KaitoError.malformed("invalid LZMA direct-bit count")
        }
        var result: UInt32 = 0
        for _ in 0..<count {
            range >>= 1
            result <<= 1
            if code >= range {
                code -= range
                result |= 1
            }
            try normalize()
        }
        return result
    }

    private mutating func normalize() throws {
        guard range != 0 else {
            throw KaitoError.malformed("LZMA range coder reached a zero range")
        }
        if range < 0x0100_0000 {
            range <<= 8
            code = (code << 8) | UInt32(try readByte())
        }
    }

    private mutating func readByte() throws -> UInt8 {
        guard reader.offset < endOffset else {
            throw KaitoError.truncated
        }
        return try reader.readUInt8()
    }
}

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

private func decodeBitTree(
    probabilities: inout [UInt16],
    base: Int,
    bitCount: Int,
    rangeDecoder: inout LZMARangeDecoder
) throws -> Int {
    guard base >= 0, bitCount >= 0, bitCount <= 8 else {
        throw KaitoError.malformed("invalid LZMA bit tree")
    }
    let treeSize = 1 << bitCount
    guard base <= probabilities.count, treeSize <= probabilities.count - base else {
        throw KaitoError.malformed("LZMA bit tree exceeds its probability table")
    }

    var symbol = 1
    for _ in 0..<bitCount {
        let bit = Int(try rangeDecoder.decodeBit(&probabilities[base + symbol]))
        symbol = (symbol << 1) | bit
    }
    return symbol - treeSize
}

private func decodeReverseBitTree(
    probabilities: inout [UInt16],
    base: Int,
    bitCount: Int,
    rangeDecoder: inout LZMARangeDecoder
) throws -> Int {
    guard bitCount >= 0, bitCount <= 8 else {
        throw KaitoError.malformed("invalid LZMA reverse bit tree")
    }

    var symbol = 1
    var result = 0
    for bitIndex in 0..<bitCount {
        let index = base + symbol
        guard index >= 0, index < probabilities.count else {
            throw KaitoError.malformed("LZMA reverse bit tree exceeds its probability table")
        }
        let bit = Int(try rangeDecoder.decodeBit(&probabilities[index]))
        symbol = (symbol << 1) | bit
        result |= bit << bitIndex
    }
    return result
}
