import Foundation

// Provenance: RAR 1.5-4.x format notes §16-17 and RAR 2.50 black-box archives.
// No 7-Zip Rar20, unrar source, XADMaster, or The Unarchiver source was used.
final class RAR20Decoder: Decompressor {
    static let windowSize = 1 << 20
    private static let windowMask = windowSize - 1
    private static let mainSymbolCount = 298
    private static let distanceSymbolCount = 48
    private static let lengthSymbolCount = 28
    private static let levelSymbolCount = 19
    private static let combinedLengthCount = mainSymbolCount + distanceSymbolCount + lengthSymbolCount
    private static let audioSymbolCount = 257
    private static let maximumTableLength = 1_028

    enum BlockMode {
        case lz
        case audio(channels: Int)
    }

    struct AudioChannelState {
        var k = [Int](repeating: 0, count: 5)
        var d1 = 0, d2 = 0, d3 = 0, d4 = 0
        var lastDelta = 0
        var lastChar = 0
        var byteCount = 0
        var dif = [Int](repeating: 0, count: 11)
    }

    private static let lengthBases = [0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20,
        24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224]
    private static let lengthBits = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2,
        2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5]
    private static let distanceBases = [0, 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48,
        64, 96, 128, 192, 256, 384, 512, 768, 1_024, 1_536, 2_048, 3_072,
        4_096, 6_144, 8_192, 12_288, 16_384, 24_576, 32_768, 49_152, 65_536,
        98_304, 131_072, 196_608, 262_144, 327_680, 393_216, 458_752, 524_288,
        589_824, 655_360, 720_896, 786_432, 851_968, 917_504, 983_040]
    private static let distanceBits = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4,
        5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14,
        15, 15, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16]
    private static let shortBases = [0, 4, 8, 16, 32, 64, 128, 192]
    private static let shortBits = [2, 2, 3, 4, 5, 6, 6, 6]

    final class SolidState {
        var window = [UInt8](repeating: 0, count: RAR20Decoder.windowSize)
        var windowPosition = 0
        var historySize = 0
        var oldDistances = [0, 0, 0, 0]
        var oldDistancePointer = 0
        var lastDistance = 0
        var lastLength = 0
        var previousLengths = [UInt8](repeating: 0, count: RAR20Decoder.maximumTableLength)
        let mainTable = RAR20HuffmanTable()
        let distanceTable = RAR20HuffmanTable()
        let lengthTable = RAR20HuffmanTable()
        let audioTables = (0..<4).map { _ in RAR20HuffmanTable() }
        var audioChannels = [RAR20Decoder.AudioChannelState](repeating: .init(), count: 4)
        var channelDelta = 0
        var currentChannel = 0
        var tablesWereRead = false
        var mode: RAR20Decoder.BlockMode = .lz

        init(dictionarySize: UInt64) throws {}
    }

    private let state: SolidState
    private let expectedSize: UInt64
    private var bits: MSBFirstBitReader
    private var produced: UInt64 = 0
    private var pendingDistance = 0
    private var pendingLength = 0
    private var finished = false
    private var terminalError: (any Error)?

    var isFinished: Bool { finished && terminalError == nil }

    init(
        source: any ByteSource,
        offset: UInt64,
        compressedSize: UInt64,
        expectedSize: UInt64,
        unpackVersion: UInt8,
        method: UInt8,
        dictionarySize: UInt64,
        isSolid: Bool,
        limits: ReadLimits,
        solidState suppliedSolidState: SolidState? = nil
    ) throws {
        guard unpackVersion == 20 || unpackVersion == 26 else {
            throw KaitoError.unsupportedMethod("RAR4 unpack version \(unpackVersion)")
        }
        guard (0x31...0x35).contains(method) else {
            throw KaitoError.unsupportedMethod(String(format: "RAR4 method 0x%02x", method))
        }
        guard !isSolid || suppliedSolidState != nil else {
            throw KaitoError.unsupportedMethod("RAR4 solid continuation requires shared state")
        }
        let end = try Checked.add(offset, compressedSize)
        guard end <= source.length else { throw KaitoError.truncated }
        try Checked.size(expectedSize, limit: limits.maxEntrySize)
        try Checked.size(compressedSize, limit: limits.maxEntrySize)
        try Checked.size(UInt64(Self.windowSize), limit: limits.maxDictionarySize)
        _ = dictionarySize
        let count = try Checked.toInt(compressedSize)
        var input = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let read = try input.withUnsafeMutableBytes { destination in
                try source.read(into: destination, at: try Checked.add(offset, UInt64(filled)))
            }
            guard read > 0, read <= count - filled else { throw KaitoError.truncated }
            filled += read
        }
        bits = MSBFirstBitReader(bytes: input)
        state = try suppliedSolidState ?? SolidState(dictionarySize: dictionarySize)
        self.expectedSize = expectedSize
        if expectedSize > 0, !isSolid || !state.tablesWereRead { try readTables() }
        finished = expectedSize == 0
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if let terminalError { throw terminalError }
        guard !finished, !buffer.isEmpty else { return 0 }
        do {
            var count = 0
            while count < buffer.count, produced < expectedSize {
                if pendingLength > 0 {
                    count += try copyMatch(into: buffer, offset: count)
                    continue
                }
                if case .audio(let channels) = state.mode {
                    let number = try state.audioTables[state.currentChannel].decode(&bits)
                    guard !bits.overrun else { throw KaitoError.truncated }
                    if number == 256 {
                        try readTables()
                        continue
                    }
                    let byte = decodeAudio(number)
                    buffer[count] = byte
                    try writeByte(byte)
                    count += 1
                    state.currentChannel = (state.currentChannel + 1) % channels
                    continue
                }
                let number = try state.mainTable.decode(&bits)
                guard !bits.overrun else { throw KaitoError.truncated }
                switch number {
                case 0...255:
                    buffer[count] = UInt8(number)
                    try writeByte(UInt8(number))
                    count += 1
                case 256:
                    guard state.lastDistance > 0, state.lastLength > 0 else {
                        throw KaitoError.malformed("RAR4 repeat match has no previous match")
                    }
                    try appendMatch(distance: state.lastDistance, length: state.lastLength)
                case 257...260:
                    let distance = state.oldDistances[(state.oldDistancePointer - (number - 256)) & 3]
                    let lengthNumber = try state.lengthTable.decode(&bits)
                    var length = Self.lengthBases[lengthNumber] + 2
                    length += try readBits(Self.lengthBits[lengthNumber])
                    if distance >= 0x101 { length += 1 }
                    if distance >= 0x2000 { length += 1 }
                    if distance >= 0x40000 { length += 1 }
                    try appendMatch(distance: distance, length: length)
                case 261...268:
                    let index = number - 261
                    var distance = Self.shortBases[index] + 1
                    distance += try readBits(Self.shortBits[index])
                    try appendMatch(distance: distance, length: 2)
                case 269:
                    try readTables()
                case 270...297:
                    let index = number - 270
                    var length = Self.lengthBases[index] + 3
                    length += try readBits(Self.lengthBits[index])
                    let distanceNumber = try state.distanceTable.decode(&bits)
                    var distance = Self.distanceBases[distanceNumber] + 1
                    distance += try readBits(Self.distanceBits[distanceNumber])
                    if distance >= 0x2000 { length += 1 }
                    if distance >= 0x40000 { length += 1 }
                    try appendMatch(distance: distance, length: length)
                default:
                    throw KaitoError.malformed("RAR4 main symbol \(number)")
                }
                if pendingLength > 0 { count += try copyMatch(into: buffer, offset: count) }
            }
            if produced == expectedSize { finished = true }
            return count
        } catch {
            terminalError = error
            throw error
        }
    }

    private func readBits(_ count: Int) throws -> Int {
        let value = try bits.read(count)
        guard !bits.overrun else { throw KaitoError.truncated }
        return Int(value)
    }

    private func readTables() throws {
        let field = try bits.peek(16)
        guard !bits.overrun else { throw KaitoError.truncated }
        _ = try readBits(2)
        let keepPrevious = field & 0x4000 != 0
        let isAudio = field & 0x8000 != 0
        let channels = isAudio ? Int((field >> 12) & 3) + 1 : 1
        let tableSize = isAudio ? channels * Self.audioSymbolCount : Self.combinedLengthCount
        if isAudio {
            _ = try readBits(2)
            if state.currentChannel >= channels { state.currentChannel = 0 }
        }
        state.mode = isAudio ? .audio(channels: channels) : .lz
        if !keepPrevious {
            state.previousLengths = [UInt8](repeating: 0, count: Self.maximumTableLength)
        }
        var levelLengths = [UInt8](repeating: 0, count: Self.levelSymbolCount)
        for index in levelLengths.indices {
            levelLengths[index] = UInt8(try readBits(4))
        }
        let levelTable = RAR20HuffmanTable()
        try levelTable.build(levelLengths)
        var index = 0
        while index < tableSize {
            let symbol = try levelTable.decode(&bits)
            switch symbol {
            case 0...15:
                state.previousLengths[index] = UInt8((Int(state.previousLengths[index]) + symbol) & 0x0f)
                index += 1
            case 16:
                guard index > 0 else { throw KaitoError.malformed("RAR4 length repeat has no predecessor") }
                let run = try readBits(2) + 3
                guard run <= tableSize - index else {
                    throw KaitoError.malformed("RAR4 length repeat exceeds the table")
                }
                let repeated = state.previousLengths[index - 1]
                for destination in index..<(index + run) { state.previousLengths[destination] = repeated }
                index += run
            case 17:
                let run = try readBits(3) + 3
                guard run <= tableSize - index else {
                    throw KaitoError.malformed("RAR4 zero run exceeds the table")
                }
                for destination in index..<(index + run) { state.previousLengths[destination] = 0 }
                index += run
            case 18:
                let run = try readBits(7) + 11
                guard run <= tableSize - index else {
                    throw KaitoError.malformed("RAR4 zero run exceeds the table")
                }
                for destination in index..<(index + run) { state.previousLengths[destination] = 0 }
                index += run
            default:
                throw KaitoError.malformed("RAR4 level symbol \(symbol)")
            }
        }
        if isAudio {
            for channel in 0..<channels {
                let start = channel * Self.audioSymbolCount
                try state.audioTables[channel].build(state.previousLengths[start..<(start + Self.audioSymbolCount)])
            }
        } else {
            let mainEnd = Self.mainSymbolCount
            let distanceEnd = mainEnd + Self.distanceSymbolCount
            try state.mainTable.build(state.previousLengths[0..<mainEnd])
            try state.distanceTable.build(state.previousLengths[mainEnd..<distanceEnd], requireSymbol: false)
            try state.lengthTable.build(state.previousLengths[distanceEnd..<Self.combinedLengthCount], requireSymbol: false)
        }
        state.tablesWereRead = true
    }

    private func decodeAudio(_ delta: Int) -> UInt8 {
        let channel = state.currentChannel
        var value = state.audioChannels[channel]
        value.byteCount += 1
        value.d4 = value.d3
        value.d3 = value.d2
        value.d2 = value.lastDelta - value.d1
        value.d1 = value.lastDelta
        let prediction = 8 * value.lastChar
            + value.k[0] * value.d1
            + value.k[1] * value.d2
            + value.k[2] * value.d3
            + value.k[3] * value.d4
            + value.k[4] * state.channelDelta
        let predicted = (prediction >> 3) & 0xff
        let decoded = (predicted - delta) & 0xff
        let error = Int(Int8(bitPattern: UInt8(delta))) << 3
        let differences = [error,
            error - value.d1, error + value.d1,
            error - value.d2, error + value.d2,
            error - value.d3, error + value.d3,
            error - value.d4, error + value.d4,
            error - state.channelDelta, error + state.channelDelta]
        for index in 0..<11 { value.dif[index] += abs(differences[index]) }
        let nextDelta = Int(Int8(bitPattern: UInt8((decoded - value.lastChar) & 0xff)))
        state.channelDelta = nextDelta
        value.lastDelta = nextDelta
        value.lastChar = decoded
        if value.byteCount & 0x1f == 0 {
            var minimum = value.dif[0], winner = 0
            value.dif[0] = 0
            for index in 1...10 {
                if value.dif[index] < minimum {
                    minimum = value.dif[index]
                    winner = index
                }
                value.dif[index] = 0
            }
            if winner > 0 {
                let index = (winner - 1) / 2
                if winner % 2 == 1 {
                    if value.k[index] >= -16 { value.k[index] -= 1 }
                } else if value.k[index] < 16 { value.k[index] += 1 }
            }
        }
        state.audioChannels[channel] = value
        return UInt8(decoded)
    }

    private func appendMatch(distance: Int, length: Int) throws {
        guard distance > 0, length > 0 else { throw KaitoError.malformed("RAR4 invalid match") }
        state.oldDistances[state.oldDistancePointer] = distance
        state.oldDistancePointer = (state.oldDistancePointer + 1) & 3
        state.lastDistance = distance
        state.lastLength = length
        pendingDistance = distance
        pendingLength = length
    }

    private func copyMatch(into buffer: UnsafeMutableRawBufferPointer, offset: Int) throws -> Int {
        guard pendingDistance > 0, pendingDistance <= state.historySize else {
            throw KaitoError.malformed("RAR4 match distance exceeds history")
        }
        let available = min(pendingLength, buffer.count - offset, Int(expectedSize - produced))
        for index in 0..<available {
            let sourceIndex = (state.windowPosition - pendingDistance) & Self.windowMask
            let byte = state.window[sourceIndex]
            buffer[offset + index] = byte
            try writeByte(byte)
        }
        pendingLength -= available
        if pendingLength == 0 { pendingDistance = 0 }
        return available
    }

    private func writeByte(_ byte: UInt8) throws {
        guard produced < expectedSize else { throw KaitoError.malformed("RAR4 output exceeds declared size") }
        state.window[state.windowPosition] = byte
        state.windowPosition = (state.windowPosition + 1) & Self.windowMask
        state.historySize = min(state.historySize + 1, Self.windowSize)
        produced += 1
    }
}

final class RAR20HuffmanTable {
    private static let primaryBits = 10
    private static let primaryCount = 1 << primaryBits
    private let primary: UnsafeMutablePointer<UInt32>
    private var counts = [Int]()
    private var firstCodes = [Int]()
    private var firstSymbols = [Int]()
    private var symbols = [Int]()

    init() {
        primary = .allocate(capacity: Self.primaryCount)
        primary.initialize(repeating: 0, count: Self.primaryCount)
    }

    deinit {
        primary.deinitialize(count: Self.primaryCount)
        primary.deallocate()
    }

    func build(_ lengths: some Sequence<UInt8>, requireSymbol: Bool = true) throws {
        let lengths = Array(lengths)
        var counts = [Int](repeating: 0, count: 16)
        var populated = 0
        for length in lengths {
            guard length <= 15 else { throw KaitoError.malformed("RAR4 Huffman length exceeds 15") }
            if length > 0 {
                counts[Int(length)] += 1
                populated += 1
            }
        }
        guard populated > 0 || !requireSymbol else { throw KaitoError.malformed("RAR4 Huffman table is empty") }
        var available = 1
        for length in 1...15 {
            available = (available << 1) - counts[length]
            guard available >= 0 else { throw KaitoError.malformed("RAR4 oversubscribed Huffman table") }
        }
        var firstCodes = [Int](repeating: 0, count: 16)
        var firstSymbols = [Int](repeating: 0, count: 16)
        var code = 0, index = 0
        for length in 1...15 {
            code = (code + counts[length - 1]) << 1
            firstCodes[length] = code
            firstSymbols[length] = index
            index += counts[length]
        }
        var nextCodes = firstCodes, nextSymbols = firstSymbols
        var symbols = [Int](repeating: 0, count: populated)
        var primaryFilled = 0
        for (symbol, length) in lengths.enumerated() where length > 0 {
            let count = Int(length)
            let canonicalCode = nextCodes[count]
            guard canonicalCode < 1 << count else { throw KaitoError.malformed("RAR4 canonical Huffman code") }
            symbols[nextSymbols[count]] = symbol
            nextSymbols[count] += 1
            nextCodes[count] += 1
            if count <= Self.primaryBits {
                let first = canonicalCode << (Self.primaryBits - count)
                let repetitions = 1 << (Self.primaryBits - count)
                let record = UInt32(count) << 16 | UInt32(symbol + 1)
                primary.advanced(by: first).update(repeating: record, count: repetitions)
                primaryFilled = max(primaryFilled, first + repetitions)
            }
        }
        if primaryFilled < Self.primaryCount {
            primary.advanced(by: primaryFilled).update(
                repeating: 0, count: Self.primaryCount - primaryFilled
            )
        }
        self.counts = counts
        self.firstCodes = firstCodes
        self.firstSymbols = firstSymbols
        self.symbols = symbols
    }

    @inline(__always)
    func decode(_ bits: inout MSBFirstBitReader) throws -> Int {
        let record = primary[Int(try bits.peekPadded(Self.primaryBits))]
        if record != 0 {
            try bits.consume(Int(record >> 16))
            return Int(record & 0xffff) - 1
        }
        var code = 0
        for length in 1...15 {
            code = (code << 1) | Int(try bits.read(1))
            let relative = code - firstCodes[length]
            if relative >= 0, relative < counts[length] {
                let index = firstSymbols[length] + relative
                guard symbols.indices.contains(index) else { throw KaitoError.malformed("RAR4 Huffman symbol") }
                return symbols[index]
            }
        }
        guard !bits.overrun else { throw KaitoError.truncated }
        throw KaitoError.malformed("RAR4 invalid Huffman code")
    }
}
