// Microsoft [MS-PATCH] v20160613 を CAB 向けに読み替えた実装。出自と十一項目の差分は設計文書に記録。
final class LZXDecoder {
    private let windowSize: Int
    private let expectedSize: UInt64
    private let folderContinues: Bool
    private var window: [UInt8]
    private var windowPosition = 0
    private var historyCount = 0
    private var repeated = [1, 1, 1]
    private var mainLengths: [Int]
    private var lengthLengths = [Int](repeating: 0, count: 249)
    private var mainTable: LZXHuffmanTable?
    private var lengthTable: LZXHuffmanTable?
    private var alignedTable: LZXHuffmanTable?
    private var blockType = 0
    private var blockRemaining = 0
    private var rawPadding = false
    private var headerRead = false
    private var translationSize: Int64 = 0
    private var decodedSize: UInt64 = 0
    private var declaredSize: UInt64 = 0

    private static let slotCounts = [30, 32, 34, 36, 38, 42, 50]
    private static let footerBits = (0..<50).map { max(0, min(17, $0 / 2 - 1)) }
    private static let basePositions: [Int] = {
        var result = [0]
        for width in footerBits.dropLast() { result.append(result[result.count - 1] + (1 << width)) }
        return result
    }()

    init(windowBits: Int, outputSize: UInt64, dictionarySizeLimit: UInt64, folderContinues: Bool = false) throws {
        guard (15...21).contains(windowBits) else { throw KaitoError.malformed("cab LZX window bits") }
        let size = 1 << windowBits
        try Checked.size(UInt64(size), limit: dictionarySizeLimit)
        windowSize = size
        expectedSize = outputSize
        self.folderContinues = folderContinues
        window = [UInt8](repeating: 0, count: size)
        mainLengths = [Int](repeating: 0, count: 256 + 8 * Self.slotCounts[windowBits - 15])
    }

    func decodeFrame(input: [UInt8], outputSize: Int) throws -> [UInt8] {
        guard (1...32768).contains(outputSize), decodedSize <= expectedSize,
              UInt64(outputSize) <= expectedSize - decodedSize else {
            throw KaitoError.malformed("cab LZX frame size")
        }
        let frameSize = folderContinues ? 32768 : min(32768, expectedSize - decodedSize)
        guard UInt64(outputSize) == frameSize else {
            throw KaitoError.malformed("cab LZX short intermediate frame")
        }
        var bits = LZXBitReader(input)
        if !headerRead {
            if try bits.read(1) != 0 {
                let high = try bits.read(16), low = try bits.read(16)
                translationSize = Int64(Int32(bitPattern: UInt32(high << 16 | low)))
            }
            headerRead = true
        }
        var output = [UInt8](repeating: 0, count: outputSize)
        var out = 0, position = windowPosition, history = historyCount
        let mask = windowSize - 1
        try window.withUnsafeMutableBufferPointer { ring in
            while out < outputSize {
                if blockRemaining == 0 {
                    try consumeRawPadding(&bits)
                    try startBlock(&bits)
                }
                if blockType == 3 {
                    let count = min(blockRemaining, outputSize - out)
                    guard bits.remainingRawBytes >= count else { throw KaitoError.truncated }
                    for _ in 0..<count {
                        let byte = try bits.readRawByte()
                        // マスク済みの位置は固定長の窓の範囲内、出力は事前検査した残量内。
                        ring[position] = byte
                        output[out] = byte
                        position = (position + 1) & mask
                        out += 1
                    }
                    history = min(windowSize, history + count)
                    blockRemaining -= count
                } else {
                    guard let mainTable, let lengthTable else { throw KaitoError.malformed("cab LZX missing tree") }
                    let symbol = try mainTable.decode(&bits)
                    if symbol < 256 {
                        let byte = UInt8(symbol)
                        ring[position] = byte
                        output[out] = byte
                        position = (position + 1) & mask
                        out += 1
                        history = min(windowSize, history + 1)
                        blockRemaining -= 1
                    } else {
                        let header = (symbol - 256) & 7, slot = (symbol - 256) >> 3
                        let length = header == 7 ? try lengthTable.decode(&bits) + 9 : header + 2
                        guard length <= blockRemaining, length <= outputSize - out else {
                            throw KaitoError.malformed("cab LZX match exceeds block or frame")
                        }
                        let offset = try matchOffset(slot: slot, bits: &bits)
                        guard offset > 0, offset <= history, offset <= windowSize - 3 else {
                            throw KaitoError.malformed("cab LZX match exceeds history")
                        }
                        var source = (position - offset) & mask
                        for _ in 0..<length {
                            let byte = ring[source]
                            ring[position] = byte
                            output[out] = byte
                            source = (source + 1) & mask
                            position = (position + 1) & mask
                            out += 1
                        }
                        history = min(windowSize, history + length)
                        blockRemaining -= length
                    }
                }
            }
        }
        let nextSize = try Checked.add(decodedSize, UInt64(outputSize))
        if blockRemaining == 0, rawPadding,
           bits.remainingRawBytes > 0 || nextSize == expectedSize {
            try consumeRawPadding(&bits)
        }
        try bits.finishFrame()
        if !folderContinues, nextSize == expectedSize {
            guard blockRemaining == 0, declaredSize == expectedSize else { throw KaitoError.truncated }
        }
        windowPosition = position; historyCount = history
        // 辞書には変換前の値を保持し、呼出元へ渡すフレームだけを後処理する。
        translate(&output)
        decodedSize = nextSize
        return output
    }

    private func consumeRawPadding(_ bits: inout LZXBitReader) throws {
        if rawPadding {
            guard try bits.readRawByte() == 0 else { throw KaitoError.malformed("cab LZX uncompressed padding") }
            rawPadding = false
        }
    }

    private func startBlock(_ bits: inout LZXBitReader) throws {
        blockType = try bits.read(3)
        guard (1...3).contains(blockType) else { throw KaitoError.malformed("cab LZX block type") }
        blockRemaining = try bits.read(24)
        // 継続フォルダーでは、この cabinet 内の展開量を block 全体の上限にはできない。
        guard blockRemaining > 0, folderContinues || (declaredSize <= expectedSize
              && UInt64(blockRemaining) <= expectedSize - declaredSize) else {
            throw KaitoError.malformed("cab LZX block size")
        }
        declaredSize = try Checked.add(declaredSize, UInt64(blockRemaining))
        if blockType == 3 {
            try bits.beginRaw()
            for index in 0..<3 {
                let offset = try bits.readRawOffset()
                guard offset > 0, offset <= windowSize - 3 else { throw KaitoError.malformed("cab LZX repeated offset") }
                repeated[index] = offset
            }
            rawPadding = blockRemaining & 1 != 0
        } else {
            if blockType == 2 {
                var lengths = [Int]()
                for _ in 0..<8 { lengths.append(try bits.read(3)) }
                alignedTable = try LZXHuffmanTable(lengths: lengths)
            }
            try Self.readLengths(&mainLengths, range: 0..<256, bits: &bits)
            try Self.readLengths(&mainLengths, range: 256..<mainLengths.count, bits: &bits)
            mainTable = try LZXHuffmanTable(lengths: mainLengths)
            try Self.readLengths(&lengthLengths, range: 0..<249, bits: &bits)
            lengthTable = try LZXHuffmanTable(lengths: lengthLengths, allowEmpty: true)
        }
    }

    private static func readLengths(_ lengths: inout [Int], range: Range<Int>, bits: inout LZXBitReader) throws {
        var preLengths = [Int]()
        for _ in 0..<20 { preLengths.append(try bits.read(4)) }
        let pretree = try LZXHuffmanTable(lengths: preLengths)
        var index = range.lowerBound
        while index < range.upperBound {
            let symbol = try pretree.decode(&bits)
            let count: Int, value: Int
            switch symbol {
            case 0...16:
                count = 1
                value = (lengths[index] - symbol + 17) % 17
            case 17:
                count = try bits.read(4) + 4
                value = 0
            case 18:
                count = try bits.read(5) + 20
                value = 0
            case 19:
                count = try bits.read(1) + 4
                let delta = try pretree.decode(&bits)
                guard delta <= 16 else { throw KaitoError.malformed("cab LZX pretree repeat delta") }
                value = (lengths[index] - delta + 17) % 17
            default:
                throw KaitoError.malformed("cab LZX pretree symbol")
            }
            guard count <= range.upperBound - index else { throw KaitoError.malformed("cab LZX pretree run") }
            for offset in index..<(index + count) { lengths[offset] = value }
            index += count
        }
    }

    private func matchOffset(slot: Int, bits: inout LZXBitReader) throws -> Int {
        guard Self.footerBits.indices.contains(slot) else { throw KaitoError.malformed("cab LZX position slot") }
        if slot < 3 {
            let offset = repeated[slot]
            repeated[slot] = repeated[0]
            repeated[0] = offset
            return offset
        }
        let width = Self.footerBits[slot]
        let footer: Int
        if blockType == 2, width >= 3 {
            guard let alignedTable else { throw KaitoError.malformed("cab LZX missing aligned tree") }
            let high = try bits.read(width - 3)
            footer = try (high << 3) | alignedTable.decode(&bits)
        } else {
            footer = try bits.read(width)
        }
        let offset = Self.basePositions[slot] + footer - 2
        repeated[2] = repeated[1]; repeated[1] = repeated[0]; repeated[0] = offset
        return offset
    }

    private func translate(_ bytes: inout [UInt8]) {
        guard translationSize != 0, decodedSize < 0x40000000, bytes.count > 10 else { return }
        var index = 0
        while index < bytes.count - 10 {
            if bytes[index] != 0xe8 { index += 1; continue }
            let pointer = Int64(decodedSize) + Int64(index)
            let word = UInt32(bytes[index + 1]) | UInt32(bytes[index + 2]) << 8
                | UInt32(bytes[index + 3]) << 16 | UInt32(bytes[index + 4]) << 24
            let value = Int64(Int32(bitPattern: word))
            if value >= -pointer, value < translationSize {
                let displacement = value >= 0 ? value - pointer : value + translationSize
                let converted = UInt32(truncatingIfNeeded: displacement)
                for byte in 0..<4 { bytes[index + 1 + byte] = UInt8(truncatingIfNeeded: converted >> (byte * 8)) }
            }
            index += 5
        }
    }
}
