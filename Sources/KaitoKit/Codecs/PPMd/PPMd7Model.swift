// 公式のパブリックドメイン LZMA SDK（Ppmd7.c、Ppmd7.h、Ppmd7Dec.c）と
// Dmitry Shkarin のパブリックドメイン PPMd var.H を参照し、境界検証付きの
// オフセット表現で Swift らしく再実装している。永続的なコンテキストと状態は
// PPMd7Suballocator に格納し、Swift 側には一時スナップショットと UInt32 の
// アリーナオフセットだけを保持する。

private final class PPMd7ArenaSEEContext {
    var summary: Int
    var shift: Int
    var count: Int

    init(initialValue: Int) {
        shift = 3
        summary = initialValue << shift
        count = 4
    }

    func mean() -> Int {
        let value = (summary & 0xffff) >> shift
        summary = (summary - value) & 0xffff
        return max(value, 1)
    }

    func update() {
        guard shift < 7 else { return }
        count -= 1
        guard count == 0 else { return }
        summary = (summary << 1) & 0xffff
        count = 3 << shift
        shift += 1
    }
}

private enum PPMd7ArenaAllocationError: Error {
    case exhausted
}

// PPMd7 model のパック済みアリーナ格納と更新処理。
//
// context 配置（12 byte）:
// - +0: UInt16 NumStats（実際の state 数 1...256）
// - multi-state: +2 UInt16 SummFreq、+4 UInt32 Stats
// - binary: +2 に STATE をインライン格納
// - +8: UInt32 suffix
//
// STATE 配置（6 byte）: symbol、frequency、UInt32 successor。
final class PPMd7Model {
    typealias Offset = PPMd7Suballocator.Offset

    // SDK model の定数と successor frequency の計算式。
    private enum SDK {
        static let maximumFrequency = 124
        static let binaryScale = 1 << 14
        static let binaryInterval = 1 << 7
        static let exponentialEscape = [25, 14, 9, 7, 5, 5, 4, 4, 4, 3, 3, 3, 2, 2, 2, 2]
        static let initialBinaryEscapes = [
            0x3CDD, 0x1F3F, 0x59BF, 0x48F3,
            0x64A1, 0x5ABC, 0x6632, 0x6051,
        ]

        static func inheritedSuccessorFrequency(
            stateFrequency: Int,
            summaryFrequency: Int,
            numberOfStats: Int
        ) throws -> Int {
            let cf = stateFrequency - 1
            let s0 = summaryFrequency - (numberOfStats + 1) - cf
            guard s0 > 0 else {
                throw KaitoError.malformed("PPMd7 successor residual is invalid")
            }
            return 1 + (2 * cf <= s0
                ? (5 * cf > s0 ? 1 : 0)
                : (2 * cf + s0 - 1) / (2 * s0) + 1)
        }
    }

    private enum SuccessorKind {
        case none
        case text(Offset)
        case context(Offset)
    }

    // 6 byte state の一時値。model の永続 state としては保持しない。
    private struct StateValue {
        var symbol: UInt8
        var frequency: UInt8
        var successor: Offset
    }

    private static let contextSize = 12
    private static let stateSize = 6
    private static let null = PPMd7Suballocator.nullOffset

    private let maximumOrder: Int
    private let allocator: PPMd7Suballocator
    private let nsToBinaryIndex: [Int]
    private let nsToSEEIndex: [Int]

    private var binarySummaries = [[Int]]()
    private var seeContexts = [[PPMd7ArenaSEEContext]]()
    private var characterMask = [UInt8](repeating: 0, count: 256)
    private var escapeCount: UInt8 = 1
    private var numberMasked = 0
    private var previousSuccess = 0
    private var runLength = 0
    private var initialRunLength = 0
    private var orderFall = 0
    private var initialEscape = 0
    private var previousFoundSymbol: UInt8 = 0
    private var highBitsFlag = 0

    private var maximumContext: Offset = PPMd7Suballocator.nullOffset
    private var foundState: Offset = PPMd7Suballocator.nullOffset

    init(maximumOrder: Int, memorySize: UInt64) throws {
        self.maximumOrder = maximumOrder
        self.allocator = try PPMd7Suballocator(memorySize: memorySize)
        self.nsToBinaryIndex = Self.makeNS2BSIndex()
        self.nsToSEEIndex = Self.makeNS2SEEIndex()
        try restartModel()
    }

    func decodeByte(using decoder: any PPMd7RangeDecoding) throws -> UInt8 {
        var minimumContext = maximumContext
        try requireContext(minimumContext)

        if try numberOfStats(in: minimumContext) != 0 {
            try decodeSymbol1(in: minimumContext, using: decoder)
        } else {
            try decodeBinarySymbol(in: minimumContext, using: decoder)
        }

        var escapedContexts = 0
        while foundState == Self.null {
            // Range normalization belongs between an escape interval update
            // and the next suffix context.  Keeping it here also preserves the
            // 7z decoder's former one-normalize-per-subrange behavior.
            try decoder.normalize()
            orderFall += 1
            var suffix = try suffix(of: minimumContext)
            guard suffix != Self.null else {
                throw KaitoError.malformed("PPMd7 end marker precedes the declared size")
            }
            escapedContexts += 1
            guard escapedContexts <= maximumOrder + 1 else {
                throw KaitoError.malformed("PPMd7 suffix chain is cyclic")
            }
            while try numberOfStats(in: suffix) == numberMasked {
                orderFall += 1
                let next = try self.suffix(of: suffix)
                guard next != Self.null else {
                    throw KaitoError.malformed("PPMd7 escaped beyond the root context")
                }
                suffix = next
                escapedContexts += 1
                guard escapedContexts <= maximumOrder + 1 else {
                    throw KaitoError.malformed("PPMd7 suffix chain is cyclic")
                }
            }
            minimumContext = suffix
            try decodeSymbol2(in: minimumContext, using: decoder)
        }

        // A selected symbol commits the final interval before model updates
        // change the probabilities used for the next symbol.
        try decoder.normalize()

        let selected = foundState
        guard selected != Self.null else {
            throw KaitoError.malformed("PPMd7 selected no symbol")
        }
        let symbol = try stateSymbol(at: selected)

        if orderFall == 0,
           case let .context(successor) = try successorKind(ofState: selected) {
            maximumContext = successor
        } else {
            do {
                try updateModel(minimumContext: minimumContext)
            } catch PPMd7ArenaAllocationError.exhausted {
                // 割り当て失敗時はアリーナが部分更新済みの可能性があるため、
                // アロケータとモデルをまとめて再初期化する。
                try restartModel()
            }
        }

        if escapeCount == 0 {
            characterMask = [UInt8](repeating: 0, count: 256)
            escapeCount = 1
        }
        previousFoundSymbol = symbol
        foundState = Self.null
        return symbol
    }

    private func decodeSymbol1(
        in context: Offset,
        using decoder: any PPMd7RangeDecoding
    ) throws {
        try validate(context)
        let scale = try summaryFrequency(of: context)
        let count = try decoder.threshold(total: scale)
        let stateCount = try numberOfStats(in: context) + 1
        var low = 0

        for index in 0..<stateCount {
            let state = try stateRef(in: context, index: index)
            let frequency = Int(try stateFrequency(at: state))
            let high = low + frequency
            if count < high {
                try decoder.remove(start: low, size: frequency)
                foundState = state
                if index == 0 {
                    previousSuccess = 2 * frequency > scale ? 1 : 0
                    runLength += previousSuccess
                    try setStateFrequency(frequency + 4, at: state)
                    try setSummaryFrequency(scale + 4, of: context)
                    if frequency + 4 > SDK.maximumFrequency {
                        try rescale(context)
                    }
                } else {
                    previousSuccess = 0
                    try update1(context: context, stateIndex: index)
                }
                return
            }
            low = high
        }

        guard count < scale else {
            throw KaitoError.malformed("PPMd7 symbol threshold exceeds context scale")
        }
        try decoder.remove(start: low, size: scale - low)
        previousSuccess = 0
        highBitsFlag = Self.highBits3(previousFoundSymbol)
        numberMasked = stateCount - 1
        for index in 0..<stateCount {
            let state = try stateRef(in: context, index: index)
            characterMask[Int(try stateSymbol(at: state))] = escapeCount
        }
        foundState = Self.null
    }

    private func decodeBinarySymbol(
        in context: Offset,
        using decoder: any PPMd7RangeDecoding
    ) throws {
        try validate(context)
        let state = try stateRef(in: context, index: 0)
        let suffix = try self.suffix(of: context)
        guard suffix != Self.null else {
            throw KaitoError.malformed("invalid PPMd7 binary context")
        }
        let frequency = Int(try stateFrequency(at: state))
        guard (1...128).contains(frequency) else {
            throw KaitoError.malformed("PPMd7 binary frequency is out of range")
        }
        let row = frequency - 1
        let runFlag = (runLength >> 26) & 0x20
        let suffixStats = try numberOfStats(in: suffix)
        guard nsToBinaryIndex.indices.contains(suffixStats) else {
            throw KaitoError.malformed("PPMd7 binary suffix count is out of range")
        }
        highBitsFlag = Self.highBits3(previousFoundSymbol)
        let column = nsToBinaryIndex[suffixStats]
            + previousSuccess
            + Self.highBits4(try stateSymbol(at: state))
            + highBitsFlag
            + runFlag
        guard binarySummaries.indices.contains(row),
              binarySummaries[row].indices.contains(column) else {
            throw KaitoError.malformed("PPMd7 binary probability index is out of range")
        }

        let probability = binarySummaries[row][column]
        let escaped = try decoder.decodeBinary(probability: probability)
        var updated = probability - ((probability + 32) >> 7)

        if !escaped {
            updated += SDK.binaryInterval
            binarySummaries[row][column] = updated
            foundState = state
            if frequency < 128 {
                try setStateFrequency(frequency + 1, at: state)
            }
            runLength += 1
            previousSuccess = 1
        } else {
            binarySummaries[row][column] = updated
            characterMask[Int(try stateSymbol(at: state))] = escapeCount
            numberMasked = 0
            previousSuccess = 0
            initialEscape = SDK.exponentialEscape[updated >> 10]
            foundState = Self.null
        }
    }

    private func decodeSymbol2(
        in context: Offset,
        using decoder: any PPMd7RangeDecoding
    ) throws {
        try validate(context)
        let stats = try numberOfStats(in: context)
        let availableCount = stats - numberMasked
        guard availableCount > 0 else {
            throw KaitoError.malformed("PPMd7 context has no unmasked symbols")
        }

        let see = try escapeEstimator(for: context)
        let escapeFrequency = see?.mean() ?? 1
        let stateCount = stats + 1
        var actualAvailable = 0
        var symbolFrequency = 0
        for index in 0..<stateCount {
            let state = try stateRef(in: context, index: index)
            if characterMask[Int(try stateSymbol(at: state))] != escapeCount {
                actualAvailable += 1
                symbolFrequency += Int(try stateFrequency(at: state))
            }
        }
        guard actualAvailable == availableCount else {
            throw KaitoError.malformed("PPMd7 masked-symbol count is inconsistent")
        }

        let scale = symbolFrequency + escapeFrequency
        let count = try decoder.threshold(total: scale)
        if count < symbolFrequency {
            var low = 0
            for index in 0..<stateCount {
                let state = try stateRef(in: context, index: index)
                let symbol = try stateSymbol(at: state)
                guard characterMask[Int(symbol)] != escapeCount else { continue }
                let frequency = Int(try stateFrequency(at: state))
                let high = low + frequency
                if count < high {
                    try decoder.remove(start: low, size: frequency)
                    see?.update()
                    try update2(context: context, state: state)
                    return
                }
                low = high
            }
            throw KaitoError.malformed("PPMd7 failed to select an unmasked state")
        }

        try decoder.remove(start: symbolFrequency, size: escapeFrequency)
        for index in 0..<stateCount {
            let state = try stateRef(in: context, index: index)
            let symbol = try stateSymbol(at: state)
            if characterMask[Int(symbol)] != escapeCount {
                characterMask[Int(symbol)] = escapeCount
            }
        }
        numberMasked = stats
        if let see {
            see.summary = (see.summary + scale) & 0xffff
        }
        foundState = Self.null
    }

    private func escapeEstimator(for context: Offset) throws -> PPMd7ArenaSEEContext? {
        let stats = try numberOfStats(in: context)
        if stats == 255 { return nil }
        let suffix = try self.suffix(of: context)
        guard suffix != Self.null else {
            throw KaitoError.malformed("PPMd7 non-root context has no suffix")
        }
        let nonMasked = stats - numberMasked
        let rowIndex = nonMasked - 1
        guard nsToSEEIndex.indices.contains(rowIndex) else {
            throw KaitoError.malformed("PPMd7 SEE row source is out of range")
        }
        let row = nsToSEEIndex[rowIndex]
        let summary = try summaryFrequency(of: context)
        let suffixStats = try numberOfStats(in: suffix)
        let column = (nonMasked < suffixStats - stats ? 1 : 0)
            + 2 * (summary < 11 * (stats + 1) ? 1 : 0)
            + 4 * (numberMasked + 1 > nonMasked ? 1 : 0)
            + highBitsFlag
        guard seeContexts.indices.contains(row),
              seeContexts[row].indices.contains(column) else {
            throw KaitoError.malformed("PPMd7 SEE index is out of range")
        }
        return seeContexts[row][column]
    }

    private func update1(context: Offset, stateIndex: Int) throws {
        let stateCount = try numberOfStats(in: context) + 1
        guard stateIndex > 0, stateIndex < stateCount else {
            throw KaitoError.malformed("invalid PPMd7 update index")
        }
        let state = try stateRef(in: context, index: stateIndex)
        let newFrequency = Int(try stateFrequency(at: state)) + 4
        try setStateFrequency(newFrequency, at: state)
        try setSummaryFrequency(try summaryFrequency(of: context) + 4, of: context)
        let previous = try stateRef(in: context, index: stateIndex - 1)
        if newFrequency > Int(try stateFrequency(at: previous)) {
            try swapStates(state, previous)
            foundState = previous
            if newFrequency > SDK.maximumFrequency {
                try rescale(context)
            }
        }
    }

    private func update2(context: Offset, state: Offset) throws {
        foundState = state
        let frequency = Int(try stateFrequency(at: state)) + 4
        try setStateFrequency(frequency, at: state)
        try setSummaryFrequency(try summaryFrequency(of: context) + 4, of: context)
        if frequency > SDK.maximumFrequency {
            try rescale(context)
        }
        escapeCount &+= 1
        runLength = initialRunLength
    }

    private func rescale(_ context: Offset) throws {
        let oldCount = try numberOfStats(in: context) + 1
        guard oldCount > 1, foundState != Self.null else {
            throw KaitoError.malformed("PPMd7 rescale state is missing")
        }
        var selectedIndex: Int?
        for index in 0..<oldCount where try stateRef(in: context, index: index) == foundState {
            selectedIndex = index
            break
        }
        guard let selectedIndex else {
            throw KaitoError.malformed("PPMd7 rescale state is missing")
        }

        if selectedIndex > 0 {
            for index in stride(from: selectedIndex, through: 1, by: -1) {
                try swapStates(
                    stateRef(in: context, index: index),
                    stateRef(in: context, index: index - 1)
                )
            }
        }

        var first = try loadState(at: stateRef(in: context, index: 0))
        let firstOldFrequency = Int(first.frequency)
        let oldSummary = try summaryFrequency(of: context)
        var escapeFrequency = oldSummary - firstOldFrequency
        let adder = orderFall == 0 ? 0 : 1
        first.frequency = try byteFrequency((firstOldFrequency + 4 + adder) >> 1)
        try storeState(first, at: stateRef(in: context, index: 0))
        var newSummary = Int(first.frequency)

        for index in 1..<oldCount {
            var value = try loadState(at: stateRef(in: context, index: index))
            escapeFrequency -= Int(value.frequency)
            value.frequency = try byteFrequency((Int(value.frequency) + adder) >> 1)
            newSummary += Int(value.frequency)
            var insertion = index
            while insertion > 0 {
                let previous = try loadState(at: stateRef(in: context, index: insertion - 1))
                guard value.frequency > previous.frequency else { break }
                try storeState(previous, at: stateRef(in: context, index: insertion))
                insertion -= 1
            }
            try storeState(value, at: stateRef(in: context, index: insertion))
        }

        var newCount = oldCount
        while newCount > 0 {
            let tail = try stateRef(in: context, index: newCount - 1)
            guard try stateFrequency(at: tail) == 0 else { break }
            newCount -= 1
        }
        guard newCount > 0 else {
            throw KaitoError.malformed("PPMd7 rescale removed every state")
        }
        let removed = oldCount - newCount
        if removed > 0 {
            escapeFrequency += removed
            try resizeStateStorage(of: context, oldCount: oldCount, newCount: newCount)
        }

        if newCount == 1 {
            let state = try stateRef(in: context, index: 0)
            guard escapeFrequency > 0 else {
                throw KaitoError.malformed("PPMd7 rescale escape frequency is zero")
            }
            var frequency = Int(try stateFrequency(at: state))
            while escapeFrequency > 1 {
                escapeFrequency >>= 1
                frequency = (frequency + 1) >> 1
            }
            try setStateFrequency(frequency, at: state)
            foundState = state
            return
        }

        // 縮小時に状態領域が移動し得るため、参照は毎回取得し直す。
        newSummary += escapeFrequency - (escapeFrequency >> 1)
        let firstRef = try stateRef(in: context, index: 0)
        try setSummaryFrequency(newSummary, of: context)
        foundState = firstRef
        try validate(context)
    }

    private func updateModel(minimumContext: Offset) throws {
        let selected = foundState
        guard selected != Self.null else {
            throw KaitoError.malformed("PPMd7 update has no selected state")
        }
        let symbol = try stateSymbol(at: selected)
        let foundFrequency = Int(try stateFrequency(at: selected))
        let oldSuccessor = try stateSuccessor(at: selected)
        var suffixState = Self.null

        let minimumSuffix = try suffix(of: minimumContext)
        if foundFrequency < SDK.maximumFrequency / 4,
           minimumSuffix != Self.null {
            let suffixStats = try numberOfStats(in: minimumSuffix)
            if suffixStats != 0 {
                guard let foundIndex = try indexOfSymbol(symbol, in: minimumSuffix) else {
                    throw KaitoError.malformed("PPMd7 suffix state is missing")
                }
                var index = foundIndex
                if foundIndex > 0 {
                    let state = try stateRef(in: minimumSuffix, index: foundIndex)
                    let previous = try stateRef(in: minimumSuffix, index: foundIndex - 1)
                    if try stateFrequency(at: state) >= stateFrequency(at: previous) {
                        try swapStates(state, previous)
                        index = foundIndex - 1
                    }
                }
                let state = try stateRef(in: minimumSuffix, index: index)
                let frequency = Int(try stateFrequency(at: state))
                if frequency < SDK.maximumFrequency - 9 {
                    try setStateFrequency(frequency + 2, at: state)
                    try setSummaryFrequency(
                        try summaryFrequency(of: minimumSuffix) + 2,
                        of: minimumSuffix
                    )
                }
                suffixState = state
            } else {
                let state = try stateRef(in: minimumSuffix, index: 0)
                let frequency = Int(try stateFrequency(at: state))
                if frequency < 32 {
                    try setStateFrequency(frequency + 1, at: state)
                }
                suffixState = state
            }
        }

        if orderFall == 0, oldSuccessor != Self.null {
            let successor = try createSuccessors(
                skipFoundState: true,
                suffixState: suffixState,
                minimumContext: minimumContext
            )
            try setStateSuccessor(successor, at: selected)
            maximumContext = successor
            return
        }

        guard let textByte = try allocator.appendText(symbol) else {
            throw PPMd7ArenaAllocationError.exhausted
        }
        let afterTextByte = try Self.add(textByte, 1)
        guard Int(afterTextByte) == allocator.textOffset else {
            throw KaitoError.malformed("PPMd7 text append frontier is inconsistent")
        }
        guard Int(afterTextByte) < allocator.unitsStartOffset else {
            // テキスト末尾の次位置もユニット境界未満に保ち、
            // オフセット種別の判定を一意にする。
            throw PPMd7ArenaAllocationError.exhausted
        }
        var newSuccessor = afterTextByte

        let resolvedSuccessor: Offset
        switch try successorKind(oldSuccessor) {
        case .text:
            resolvedSuccessor = try createSuccessors(
                skipFoundState: false,
                suffixState: suffixState,
                minimumContext: minimumContext
            )
        case let .context(context):
            resolvedSuccessor = context
        case .none:
            resolvedSuccessor = try reduceOrder(
                suffixState: suffixState,
                minimumContext: minimumContext
            )
        }

        guard orderFall > 0 else {
            throw KaitoError.malformed("PPMd7 order fall underflow")
        }
        orderFall -= 1
        if orderFall == 0 {
            newSuccessor = resolvedSuccessor
            if maximumContext != minimumContext {
                try allocator.retractText()
            }
        }

        // バイナリコンテキストでは SDK の共用体と同様に、2...3 バイト目の
        // シンボル／頻度を同じ領域から読み取る。
        let minimumSummary = Int(try allocator.uint16(at: try Self.add(minimumContext, 2)))
        let escapedTotal = minimumSummary
            - (try numberOfStats(in: minimumContext))
            - foundFrequency
        let minimumStats = try numberOfStats(in: minimumContext)
        guard escapedTotal > 0 else {
            throw KaitoError.malformed("PPMd7 context has no escape frequency")
        }

        var context = maximumContext
        var traversed = 0
        while context != minimumContext {
            let nextSuffix = try suffix(of: context)
            let oldStats = try numberOfStats(in: context)
            var workingSummary: Int
            if oldStats != 0 {
                let currentCount = oldStats + 1
                let minimumCount = minimumStats + 1
                let oldSummary = try summaryFrequency(of: context)
                workingSummary = oldSummary
                    + (2 * currentCount < minimumCount ? 1 : 0)
                    + (4 * currentCount <= minimumCount
                        && oldSummary <= 8 * currentCount ? 2 : 0)
            } else {
                let state = try stateRef(in: context, index: 0)
                let oldFrequency = Int(try stateFrequency(at: state))
                let adjusted = oldFrequency < SDK.maximumFrequency / 4 - 1
                    ? 2 * oldFrequency
                    : SDK.maximumFrequency - 4
                try setStateFrequency(adjusted, at: state)
                workingSummary = adjusted
                    + initialEscape
                    + (minimumStats > 2 ? 1 : 0)
            }

            let weighted = 2 * foundFrequency * (workingSummary + 6)
            let scale = escapedTotal + workingSummary
            let newFrequency: Int
            if weighted < 6 * scale {
                newFrequency = 1
                    + (weighted > scale ? 1 : 0)
                    + (weighted >= 4 * scale ? 1 : 0)
                workingSummary += 3
            } else {
                newFrequency = 4
                    + (weighted >= 9 * scale ? 1 : 0)
                    + (weighted >= 12 * scale ? 1 : 0)
                    + (weighted >= 15 * scale ? 1 : 0)
                workingSummary += newFrequency
            }
            _ = try appendState(
                StateValue(
                    symbol: symbol,
                    frequency: try byteFrequency(newFrequency),
                    successor: newSuccessor
                ),
                summaryFrequency: workingSummary,
                to: context
            )
            guard nextSuffix != Self.null else {
                throw KaitoError.malformed("PPMd7 update did not reach the minimum context")
            }
            context = nextSuffix
            traversed += 1
            guard traversed <= maximumOrder + 1 else {
                throw KaitoError.malformed("PPMd7 update suffix chain is cyclic")
            }
        }
        maximumContext = resolvedSuccessor
    }

    private func createSuccessors(
        skipFoundState: Bool,
        suffixState: Offset,
        minimumContext: Offset
    ) throws -> Offset {
        let selected = foundState
        guard selected != Self.null else {
            throw KaitoError.malformed("PPMd7 successor branch is invalid")
        }
        let selectedSuccessor = try stateSuccessor(at: selected)
        let upBranch: Offset
        switch try successorKind(selectedSuccessor) {
        case let .text(text):
            upBranch = text
        case let .context(context):
            return context
        case .none:
            throw KaitoError.malformed("PPMd7 successor branch is invalid")
        }

        let symbol = try stateSymbol(at: selected)
        var pendingStates = [Offset]()
        pendingStates.reserveCapacity(maximumOrder + 2)
        if !skipFoundState {
            pendingStates.append(selected)
            if try suffix(of: minimumContext) == Self.null {
                return try materializeSuccessors(
                    pendingStates,
                    baseContext: minimumContext,
                    upBranch: upBranch,
                    symbol: symbol
                )
            }
        }

        var context = minimumContext
        var state = suffixState
        if state != Self.null {
            let lower = try suffix(of: context)
            guard lower != Self.null else {
                throw KaitoError.malformed("PPMd7 successor suffix is missing")
            }
            context = lower
        }

        var traversed = 0
        while true {
            if state == Self.null {
                let lower = try suffix(of: context)
                guard lower != Self.null else { break }
                context = lower
                guard let matchingIndex = try indexOfSymbol(symbol, in: context) else {
                    throw KaitoError.malformed("PPMd7 successor symbol is missing")
                }
                let matching = try stateRef(in: context, index: matchingIndex)
                state = matching
            }

            let current = state
            guard current != Self.null else {
                throw KaitoError.malformed("PPMd7 successor state is unavailable")
            }
            let currentSuccessor = try stateSuccessor(at: current)
            if currentSuccessor != upBranch {
                guard case let .context(base) = try successorKind(currentSuccessor) else {
                    throw KaitoError.malformed("PPMd7 successor points to unresolved text")
                }
                context = base
                break
            }
            pendingStates.append(current)
            let lower = try suffix(of: context)
            guard lower != Self.null else { break }
            state = Self.null
            traversed += 1
            guard traversed <= maximumOrder + 1 else {
                throw KaitoError.malformed("PPMd7 successor chain is cyclic")
            }
        }

        if pendingStates.isEmpty { return context }
        return try materializeSuccessors(
            pendingStates,
            baseContext: context,
            upBranch: upBranch,
            symbol: symbol
        )
    }

    private func materializeSuccessors(
        _ pendingStates: [Offset],
        baseContext: Offset,
        upBranch: Offset,
        symbol: UInt8
    ) throws -> Offset {
        guard Int(upBranch) <= allocator.textOffset else {
            throw KaitoError.malformed("PPMd7 text successor is out of range")
        }
        let nextSymbol = try allocator.byte(at: upBranch)
        let frequency: Int
        let baseStats = try numberOfStats(in: baseContext)
        if baseStats != 0 {
            guard let matchingIndex = try indexOfSymbol(nextSymbol, in: baseContext) else {
                throw KaitoError.malformed("PPMd7 base successor symbol is missing")
            }
            let state = try stateRef(in: baseContext, index: matchingIndex)
            frequency = try SDK.inheritedSuccessorFrequency(
                stateFrequency: Int(try stateFrequency(at: state)),
                summaryFrequency: try summaryFrequency(of: baseContext),
                numberOfStats: baseStats
            )
        } else {
            frequency = Int(try stateFrequency(at: stateRef(in: baseContext, index: 0)))
        }
        let nextText = try Self.add(upBranch, 1)
        guard Int(nextText) <= allocator.textOffset else {
            throw KaitoError.malformed("PPMd7 text successor advance is out of range")
        }
        var contextSuffix = baseContext
        for pending in pendingStates.reversed() {
            guard let context = try allocator.allocateContext() else {
                throw PPMd7ArenaAllocationError.exhausted
            }
            try initializeBinaryContext(
                context,
                state: StateValue(
                    symbol: nextSymbol,
                    frequency: try byteFrequency(frequency),
                    successor: nextText
                ),
                suffix: contextSuffix
            )
            try setStateSuccessor(context, at: pending)
            contextSuffix = context
        }
        return contextSuffix
    }

    private func reduceOrder(
        suffixState: Offset,
        minimumContext: Offset
    ) throws -> Offset {
        let selected = foundState
        guard selected != Self.null else {
            throw KaitoError.malformed("PPMd7 reduce-order state is missing")
        }
        guard allocator.textOffset <= Int(UInt32.max) else {
            throw KaitoError.malformed("PPMd7 text frontier is out of range")
        }
        let upBranch = Offset(allocator.textOffset)
        try setStateSuccessor(upBranch, at: selected)
        orderFall += 1
        let symbol = try stateSymbol(at: selected)
        let originalMaximum = maximumContext
        var context = minimumContext
        var state = suffixState

        if state != Self.null {
            let lower = try suffix(of: context)
            guard lower != Self.null else {
                throw KaitoError.malformed("PPMd7 reduce-order suffix is missing")
            }
            context = lower
        }

        var traversed = 0
        while true {
            if state == Self.null {
                let lower = try suffix(of: context)
                guard lower != Self.null else { return context }
                context = lower
                guard let matchingIndex = try indexOfSymbol(symbol, in: context) else {
                    throw KaitoError.malformed("PPMd7 reduce-order symbol is missing")
                }
                let matching = try stateRef(in: context, index: matchingIndex)
                state = matching
                let frequency = Int(try stateFrequency(at: matching))
                if try numberOfStats(in: context) != 0 {
                    if frequency < SDK.maximumFrequency - 3 {
                        try setStateFrequency(frequency + 2, at: matching)
                        try setSummaryFrequency(
                            try summaryFrequency(of: context) + 2,
                            of: context
                        )
                    }
                } else if frequency < 11 {
                    try setStateFrequency(frequency + 1, at: matching)
                }
            }

            let current = state
            guard current != Self.null else {
                throw KaitoError.malformed("PPMd7 reduce-order state is unavailable")
            }
            let currentSuccessor = try stateSuccessor(at: current)
            if currentSuccessor != Self.null {
                if case let .text(index) = try successorKind(currentSuccessor),
                   index <= upBranch {
                    let saved = foundState
                    foundState = current
                    let successor = try createSuccessors(
                        skipFoundState: false,
                        suffixState: Self.null,
                        minimumContext: context
                    )
                    try setStateSuccessor(successor, at: current)
                    foundState = saved
                }
                guard case let .context(successor) = try successorKind(
                    try stateSuccessor(at: current)
                ) else {
                    throw KaitoError.malformed("PPMd7 reduce-order successor is unresolved")
                }
                if orderFall == 1, originalMaximum == minimumContext {
                    try setStateSuccessor(successor, at: selected)
                    try allocator.retractText()
                }
                return successor
            }

            try setStateSuccessor(upBranch, at: current)
            orderFall += 1
            state = Self.null
            traversed += 1
            guard traversed <= maximumOrder + 1 else {
                throw KaitoError.malformed("PPMd7 reduce-order chain is cyclic")
            }
        }
    }

    private func restartModel() throws {
        allocator.restart()
        characterMask = [UInt8](repeating: 0, count: 256)
        escapeCount = 1
        numberMasked = 0
        previousSuccess = 0
        orderFall = maximumOrder
        initialRunLength = -min(maximumOrder, 12) - 1
        runLength = initialRunLength
        initialEscape = 0
        previousFoundSymbol = 0
        highBitsFlag = 0
        foundState = Self.null

        guard let root = try allocator.allocateContext(),
              let states = try allocator.allocateUnits(128) else {
            throw PPMd7ArenaAllocationError.exhausted
        }
        for index in 0..<256 {
            let state = try Self.add(states, index * Self.stateSize)
            try storeState(
                StateValue(
                    symbol: UInt8(index),
                    frequency: 1,
                    successor: Self.null
                ),
                at: state
            )
        }
        try initializeMultiContext(
            root,
            numberOfStats: 255,
            summaryFrequency: 257,
            states: states,
            suffix: Self.null
        )
        maximumContext = root

        binarySummaries = Array(
            repeating: Array(repeating: 0, count: 64),
            count: 128
        )
        for column in 0..<64 {
            for row in 0..<128 {
                binarySummaries[row][column] = SDK.binaryScale
                    - SDK.initialBinaryEscapes[column & 7] / (row + 2)
            }
        }

        seeContexts = (0..<25).map { row in
            (0..<16).map { _ in PPMd7ArenaSEEContext(initialValue: 5 * row + 10) }
        }
        try validate(root)
    }

    // MARK: - パック済みアリーナへのアクセス

    private func requireContext(_ context: Offset) throws {
        guard context != Self.null else {
            throw KaitoError.malformed("PPMd7 context reference is null")
        }
        let value = Int(context)
        guard value >= allocator.unitsStartOffset,
              value <= allocator.arenaEndOffset - Self.contextSize,
              (value - allocator.unitsStartOffset).isMultiple(of: PPMd7Suballocator.unitSize) else {
            throw KaitoError.malformed("PPMd7 context reference is outside the unit arena")
        }
    }

    private func numberOfStats(in context: Offset) throws -> Int {
        try requireContext(context)
        let count = Int(try allocator.uint16(at: context))
        guard (1...256).contains(count) else {
            throw KaitoError.malformed("PPMd7 context state count is out of range")
        }
        return count - 1
    }

    private func setNumberOfStats(_ value: Int, in context: Offset) throws {
        try requireContext(context)
        guard (0...255).contains(value) else {
            throw KaitoError.malformed("PPMd7 context state count is out of range")
        }
        try allocator.storeUInt16(UInt16(value + 1), at: context)
    }

    private func suffix(of context: Offset) throws -> Offset {
        try requireContext(context)
        return try allocator.uint32(at: try Self.add(context, 8))
    }

    private func setSuffix(_ suffix: Offset, of context: Offset) throws {
        try requireContext(context)
        if suffix != Self.null { try requireContext(suffix) }
        try allocator.storeUInt32(suffix, at: try Self.add(context, 8))
    }

    private func summaryFrequency(of context: Offset) throws -> Int {
        guard try numberOfStats(in: context) != 0 else {
            throw KaitoError.malformed("PPMd7 binary context has no summary frequency")
        }
        return Int(try allocator.uint16(at: try Self.add(context, 2)))
    }

    private func setSummaryFrequency(_ value: Int, of context: Offset) throws {
        guard try numberOfStats(in: context) != 0,
              value > 0, value <= Int(UInt16.max) else {
            throw KaitoError.malformed("PPMd7 summary frequency is out of range")
        }
        try allocator.storeUInt16(UInt16(value), at: try Self.add(context, 2))
    }

    private func statsRef(of context: Offset) throws -> Offset {
        let stats = try numberOfStats(in: context)
        guard stats != 0 else {
            throw KaitoError.malformed("PPMd7 binary context has no state array")
        }
        let result = try allocator.uint32(at: try Self.add(context, 4))
        try requireStateBlock(result, stateCount: stats + 1)
        return result
    }

    private func setStatsRef(_ states: Offset, of context: Offset, stateCount: Int) throws {
        try requireContext(context)
        try requireStateBlock(states, stateCount: stateCount)
        try allocator.storeUInt32(states, at: try Self.add(context, 4))
    }

    private func requireStateBlock(_ states: Offset, stateCount: Int) throws {
        guard states != Self.null, stateCount > 1, stateCount <= 256 else {
            throw KaitoError.malformed("PPMd7 state block description is invalid")
        }
        let start = Int(states)
        let (bytes, overflow) = stateCount.multipliedReportingOverflow(by: Self.stateSize)
        guard !overflow,
              start >= allocator.unitsStartOffset,
              start <= allocator.arenaEndOffset,
              bytes <= allocator.arenaEndOffset - start,
              (start - allocator.unitsStartOffset).isMultiple(of: PPMd7Suballocator.unitSize) else {
            throw KaitoError.malformed("PPMd7 state block is outside the unit arena")
        }
    }

    private func stateRef(in context: Offset, index: Int) throws -> Offset {
        let stats = try numberOfStats(in: context)
        let count = stats + 1
        guard index >= 0, index < count else {
            throw KaitoError.malformed("PPMd7 state index is out of range")
        }
        if stats == 0 {
            return try Self.add(context, 2)
        }
        let base = try statsRef(of: context)
        return try Self.add(base, index * Self.stateSize)
    }

    private func loadState(at state: Offset) throws -> StateValue {
        try requirePackedState(state)
        return StateValue(
            symbol: try allocator.byte(at: state),
            frequency: try allocator.byte(at: try Self.add(state, 1)),
            successor: try allocator.uint32(at: try Self.add(state, 2))
        )
    }

    private func storeState(_ value: StateValue, at state: Offset) throws {
        try requirePackedState(state)
        _ = try successorKind(value.successor)
        try allocator.storeByte(value.symbol, at: state)
        try allocator.storeByte(value.frequency, at: try Self.add(state, 1))
        try allocator.storeUInt32(value.successor, at: try Self.add(state, 2))
    }

    private func stateSymbol(at state: Offset) throws -> UInt8 {
        try requirePackedState(state)
        return try allocator.byte(at: state)
    }

    private func stateFrequency(at state: Offset) throws -> UInt8 {
        try requirePackedState(state)
        return try allocator.byte(at: try Self.add(state, 1))
    }

    private func setStateFrequency(_ frequency: Int, at state: Offset) throws {
        try requirePackedState(state)
        try allocator.storeByte(try byteFrequency(frequency), at: try Self.add(state, 1))
    }

    private func stateSuccessor(at state: Offset) throws -> Offset {
        try requirePackedState(state)
        return try allocator.uint32(at: try Self.add(state, 2))
    }

    private func setStateSuccessor(_ successor: Offset, at state: Offset) throws {
        try requirePackedState(state)
        _ = try successorKind(successor)
        try allocator.storeUInt32(successor, at: try Self.add(state, 2))
    }

    private func requirePackedState(_ state: Offset) throws {
        guard state != Self.null else {
            throw KaitoError.malformed("PPMd7 state reference is null")
        }
        let value = Int(state)
        guard value >= allocator.unitsStartOffset,
              value <= allocator.arenaEndOffset - Self.stateSize else {
            throw KaitoError.malformed("PPMd7 state reference is outside the unit arena")
        }
    }

    private func successorKind(ofState state: Offset) throws -> SuccessorKind {
        try successorKind(stateSuccessor(at: state))
    }

    private func successorKind(_ successor: Offset) throws -> SuccessorKind {
        if successor == Self.null { return .none }
        if Int(successor) < allocator.unitsStartOffset {
            // 巻き戻し後は textOffset より先に未解決ポインタが残り得る。
            // テキストポインタとして扱い、実際に読む時点で範囲検証する。
            return .text(successor)
        }
        try requireContext(successor)
        return .context(successor)
    }

    private func swapStates(_ lhs: Offset, _ rhs: Offset) throws {
        guard lhs != rhs else { return }
        let left = try loadState(at: lhs)
        let right = try loadState(at: rhs)
        try storeState(right, at: lhs)
        try storeState(left, at: rhs)
    }

    private func indexOfSymbol(_ symbol: UInt8, in context: Offset) throws -> Int? {
        let count = try numberOfStats(in: context) + 1
        for index in 0..<count
        where try stateSymbol(at: stateRef(in: context, index: index)) == symbol {
            return index
        }
        return nil
    }

    @discardableResult
    private func appendState(
        _ value: StateValue,
        summaryFrequency: Int,
        to context: Offset
    ) throws -> Offset {
        let oldStats = try numberOfStats(in: context)
        let oldCount = oldStats + 1
        guard oldCount < 256,
              summaryFrequency > 0,
              summaryFrequency <= Int(UInt16.max) else {
            throw KaitoError.malformed("PPMd7 state append is out of range")
        }

        if oldStats == 0 {
            // 2...7 バイト目を SummFreq/Stats に切り替える前にインライン状態を退避する。
            let first = try loadState(at: stateRef(in: context, index: 0))
            guard let states = try allocator.allocateUnits(1) else {
                throw PPMd7ArenaAllocationError.exhausted
            }
            try storeState(first, at: states)
            let appended = try Self.add(states, Self.stateSize)
            try storeState(value, at: appended)
            try setNumberOfStats(1, in: context)
            try allocator.storeUInt16(UInt16(summaryFrequency), at: try Self.add(context, 2))
            try setStatsRef(states, of: context, stateCount: 2)
            return appended
        }

        let oldStates = try statsRef(of: context)
        let oldUnits = Self.units(forStateCount: oldCount)
        let newCount = oldCount + 1
        let newUnits = Self.units(forStateCount: newCount)
        let states: Offset
        if newUnits > oldUnits {
            guard newUnits == oldUnits + 1,
                  let expanded = try allocator.expandUnits(
                    at: oldStates,
                    oldUnits: oldUnits
                  ) else {
                throw PPMd7ArenaAllocationError.exhausted
            }
            states = expanded
        } else {
            states = oldStates
        }
        let appended = try Self.add(states, oldCount * Self.stateSize)
        try storeState(value, at: appended)
        try setNumberOfStats(oldStats + 1, in: context)
        try setStatsRef(states, of: context, stateCount: newCount)
        try allocator.storeUInt16(UInt16(summaryFrequency), at: try Self.add(context, 2))
        return appended
    }

    private func resizeStateStorage(
        of context: Offset,
        oldCount: Int,
        newCount: Int
    ) throws {
        guard oldCount > 1, newCount > 0, newCount < oldCount,
              try numberOfStats(in: context) + 1 == oldCount else {
            throw KaitoError.malformed("PPMd7 state resize is invalid")
        }
        let oldStates = try statsRef(of: context)
        let oldUnits = Self.units(forStateCount: oldCount)

        if newCount == 1 {
            let state = try loadState(at: oldStates)
            // 解放対象ブロックからの読み取りをすべて終えてから表現を切り替える。
            try setNumberOfStats(0, in: context)
            try storeState(state, at: try Self.add(context, 2))
            try allocator.freeUnits(at: oldStates, units: oldUnits)
            return
        }

        let newUnits = Self.units(forStateCount: newCount)
        var states = oldStates
        if newUnits < oldUnits {
            states = try allocator.shrinkUnits(
                at: oldStates,
                oldUnits: oldUnits,
                newUnits: newUnits
            )
        }
        try setNumberOfStats(newCount - 1, in: context)
        try setStatsRef(states, of: context, stateCount: newCount)
    }

    private func initializeBinaryContext(
        _ context: Offset,
        state: StateValue,
        suffix: Offset
    ) throws {
        try requireContext(context)
        try setNumberOfStats(0, in: context)
        try storeState(state, at: try Self.add(context, 2))
        try setSuffix(suffix, of: context)
    }

    private func initializeMultiContext(
        _ context: Offset,
        numberOfStats: Int,
        summaryFrequency: Int,
        states: Offset,
        suffix: Offset
    ) throws {
        try requireContext(context)
        guard numberOfStats > 0, numberOfStats <= 255,
              summaryFrequency > 0, summaryFrequency <= Int(UInt16.max) else {
            throw KaitoError.malformed("PPMd7 multi-state context is out of range")
        }
        try setNumberOfStats(numberOfStats, in: context)
        try allocator.storeUInt16(UInt16(summaryFrequency), at: try Self.add(context, 2))
        try setStatsRef(states, of: context, stateCount: numberOfStats + 1)
        try setSuffix(suffix, of: context)
    }

    private func validate(_ context: Offset) throws {
        try requireContext(context)
        let count = try numberOfStats(in: context) + 1
        guard count > 0, count <= 256 else {
            throw KaitoError.malformed("PPMd7 context state count is invalid")
        }
        var symbols = (UInt64(0), UInt64(0), UInt64(0), UInt64(0))
        var sum = 0
        for index in 0..<count {
            let state = try stateRef(in: context, index: index)
            let frequency = Int(try stateFrequency(at: state))
            let symbol = Int(try stateSymbol(at: state))
            guard frequency > 0 else {
                throw KaitoError.malformed("PPMd7 context state is invalid")
            }
            let bit = UInt64(1) << UInt64(symbol & 63)
            let duplicate: Bool
            switch symbol >> 6 {
            case 0:
                duplicate = symbols.0 & bit != 0
                symbols.0 |= bit
            case 1:
                duplicate = symbols.1 & bit != 0
                symbols.1 |= bit
            case 2:
                duplicate = symbols.2 & bit != 0
                symbols.2 |= bit
            default:
                duplicate = symbols.3 & bit != 0
                symbols.3 |= bit
            }
            guard !duplicate else {
                throw KaitoError.malformed("PPMd7 context state is invalid")
            }
            _ = try successorKind(ofState: state)
            sum += frequency
        }
        if count > 1 {
            let summary = try summaryFrequency(of: context)
            guard summary > sum, summary <= Int(UInt16.max) else {
                throw KaitoError.malformed("PPMd7 context frequency sum is invalid")
            }
        }
        let suffix = try self.suffix(of: context)
        if suffix != Self.null { try requireContext(suffix) }
    }

    private func byteFrequency(_ value: Int) throws -> UInt8 {
        guard value >= 0, value <= Int(UInt8.max) else {
            throw KaitoError.malformed("PPMd7 state frequency is out of range")
        }
        return UInt8(value)
    }

    private static func units(forStateCount count: Int) -> Int {
        (count + 1) >> 1
    }

    private static func add(_ offset: Offset, _ bytes: Int) throws -> Offset {
        let (result, overflow) = Int(offset).addingReportingOverflow(bytes)
        guard bytes >= 0, !overflow, result >= 0,
              result <= Int(UInt32.max) else {
            throw KaitoError.malformed("PPMd7 arena offset overflow")
        }
        return Offset(result)
    }

    private static func makeNS2BSIndex() -> [Int] {
        var result = [Int](repeating: 0, count: 256)
        result[0] = 0
        result[1] = 2
        for index in 2..<11 { result[index] = 4 }
        for index in 11..<256 { result[index] = 6 }
        return result
    }

    private static func makeNS2SEEIndex() -> [Int] {
        var result = [Int](repeating: 0, count: 256)
        for index in 0..<3 { result[index] = index }
        var value = 3
        var remaining = 1
        for index in 3..<256 {
            result[index] = value
            remaining -= 1
            if remaining == 0 {
                value += 1
                remaining = value - 2
            }
        }
        return result
    }

    private static func highBits3(_ symbol: UInt8) -> Int {
        symbol < 0x40 ? 0 : 1 << 3
    }

    private static func highBits4(_ symbol: UInt8) -> Int {
        symbol < 0x40 ? 0 : 1 << 4
    }
}
