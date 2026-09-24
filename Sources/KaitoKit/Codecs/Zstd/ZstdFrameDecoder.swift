import Foundation

// RFC 8878 §3.1 のフレーム・ブロックと sequence 実行。
struct ZstdFrameHeader {
    static let magic: UInt64 = 0xfd2fb528
    let windowSize: Int
    let contentSize: UInt64?
    let checksum: Bool
    // 出力全体より古いバイトは参照できないため、既知サイズなら宣言 window を全量保持しない。
    // LZMADecoder の retainedDictionarySize と同じ根拠で保持量を制限する。
    let retainedWindowSize: Int
    var maximumBlockSize: Int { min(128 * 1_024, windowSize) }

    static func isSkippable(_ magic: UInt64) -> Bool {
        (0x184d2a50...0x184d2a5f).contains(magic)
    }

    static func hasMagic(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4 else { return false }
        let magic = UInt64(bytes[0]) | UInt64(bytes[1]) << 8
            | UInt64(bytes[2]) << 16 | UInt64(bytes[3]) << 24
        return magic == Self.magic || isSkippable(magic)
    }

    init(input: ZstdInput, limits: ReadLimits) throws {
        let descriptor = try input.byte()
        guard descriptor & 8 == 0 else { throw KaitoError.malformed("zstd reserved frame bit") }
        // 未使用ビット 4 は RFC §3.1.1.1.1.3 に従い解釈しない。
        let single = descriptor & 32 != 0
        var window: UInt64 = 0
        if !single {
            let value = try input.byte()
            let base: UInt64 = 1 << (10 + Int(value >> 3))
            window = base + (base >> 3) * UInt64(value & 7)
        }
        let dictionary = try input.integer([0, 1, 2, 4][Int(descriptor & 3)])
        guard dictionary == 0 else {
            throw KaitoError.unsupportedMethod("zstd dictionary \(dictionary)")
        }
        let sizeBytes = [single ? 1 : 0, 2, 4, 8][Int(descriptor >> 6)]
        if sizeBytes > 0 {
            let raw = try input.integer(sizeBytes)
            contentSize = sizeBytes == 2 ? raw + 256 : raw
        } else { contentSize = nil }
        if single, let contentSize { window = contentSize }
        try Checked.size(window, limit: limits.maxDictionarySize)
        windowSize = try Checked.toInt(window)
        if let contentSize { try Checked.size(contentSize, limit: limits.maxEntrySize) }
        retainedWindowSize = try Checked.toInt(contentSize.map { min(window, max(1, $0)) } ?? window)
        checksum = descriptor & 4 != 0
    }

    func blockHeader(_ input: ZstdInput) throws -> (last: Bool, type: Int, size: Int) {
        let raw = try input.integer(3)
        let size = Int(raw >> 3)
        let type = Int((raw >> 1) & 3)
        guard type != 3, size <= maximumBlockSize else {
            throw KaitoError.malformed("zstd block type or size")
        }
        return (raw & 1 != 0, type, size)
    }
}

final class ZstdFrameDecoder {
    let header: ZstdFrameHeader
    private var storage = UnsafeMutableRawBufferPointer(start: nil, count: 0)
    private var writePosition = 0
    private var historyCount = 0
    private var produced: UInt64 = 0
    private var checksum = ZstdXXH64()
    private var huffman: ZstdHuffman?
    private var literalTable: SequenceTable?
    private var offsetTable: SequenceTable?
    private var matchTable: SequenceTable?
    private var repeats = (1, 4, 8)
    private(set) var finished = false
    // 予約容量ではなく、検証済みの保持履歴量を返す。
    var allocatedWindowBytes: Int { historyCount }
    var allocatedBufferBytes: Int { storage.count }

    init(header: ZstdFrameHeader) {
        self.header = header
    }

    deinit { storage.baseAddress?.deallocate() }

    private func prepareBlock(_ capacity: Int) -> UnsafeMutableBufferPointer<UInt8> {
        // 履歴は [writePosition - historyCount, writePosition)。末尾 16 バイトはコピー用余白。
        if storage.count - writePosition < capacity + 16 {
            let needed = historyCount + capacity + 16
            if storage.count < needed {
                // 宣言 window だけでは確保せず、実出力に応じて倍増する。
                // 利用者が上限を Int.max まで広げても、宣言値の倍増で overflow させない。
                let maximumHistory = (Int.max - header.maximumBlockSize - 16) / 2
                let ceiling = header.retainedWindowSize > maximumHistory ? Int.max
                    : 2 * header.retainedWindowSize + header.maximumBlockSize + 16
                let growth = storage.count > Int.max / 2 ? Int.max : storage.count * 2
                let size = min(ceiling, max(needed, growth))
                let next = UnsafeMutableRawBufferPointer.allocate(byteCount: size, alignment: 16)
                _ = next.bindMemory(to: UInt8.self)
                if historyCount > 0 {
                    next.baseAddress!.copyMemory(
                        from: storage.baseAddress!.advanced(by: writePosition - historyCount), byteCount: historyCount)
                }
                storage.baseAddress?.deallocate()
                storage = next
            } else if historyCount > 0 {
                // 移動元・先とも確保範囲内。重なりを許す memmove で履歴を一括移動する。
                memmove(storage.baseAddress!, storage.baseAddress!.advanced(by: writePosition - historyCount), historyCount)
            }
            writePosition = historyCount
        }
        return UnsafeMutableBufferPointer(start: storage.baseAddress!.advanced(by: writePosition)
            .assumingMemoryBound(to: UInt8.self), count: capacity + 16)
    }

    private func storeBlock(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let target = prepareBlock(bytes.count)
        bytes.withUnsafeBufferPointer {
            // prepareBlock が bytes.count + 16 バイト確保済み。
            target.baseAddress!.initialize(from: $0.baseAddress!, count: bytes.count)
        }
    }

    func nextBlock(_ input: ZstdInput) throws -> [UInt8] {
        let block = try header.blockHeader(input)
        let output: [UInt8]
        switch block.type {
        case 0: output = try input.read(block.size)
        case 1: output = [UInt8](repeating: try input.byte(), count: block.size)
        case 2: output = try compressedBlock(input.read(block.size))
        default: throw KaitoError.malformed("zstd reserved block")
        }
        produced = try Checked.add(produced, UInt64(output.count))
        if let size = header.contentSize, produced > size {
            throw KaitoError.malformed("zstd frame output exceeds content size")
        }
        if header.checksum { checksum.update(output[...]) }
        if block.last {
            if let size = header.contentSize, size != produced {
                throw KaitoError.malformed("zstd frame content size mismatch")
            }
            if header.checksum, try input.integer(4) != UInt64(UInt32(truncatingIfNeeded: checksum.value)) {
                throw KaitoError.checksumMismatch(entry: 0)
            }
            finished = true
        } else if !output.isEmpty {
            if block.type != 2 { storeBlock(output) }
            writePosition += output.count
            historyCount = min(header.retainedWindowSize, historyCount + output.count)
        }
        return output
    }

    private func literals(_ reader: inout ZstdByteReader) throws -> [UInt8] {
        let first = try reader.byte()
        let type = first & 3
        let format = (first >> 2) & 3
        if type <= 1 {
            let size: Int
            if format & 1 == 0 { size = first >> 3 }
            else if format == 1 { size = (first >> 4) | (try reader.byte() << 4) }
            else { size = (first >> 4) | (Int(try reader.integer(2)) << 4) }
            guard size <= header.maximumBlockSize else { throw KaitoError.malformed("zstd literals size") }
            if type == 1 { return [UInt8](repeating: UInt8(try reader.byte()), count: size) }
            return Array(reader.bytes[try reader.take(size)])
        }
        let headerBytes = [3, 3, 4, 5][format]
        let width = [10, 10, 14, 18][format]
        let value = UInt64(first) | (try reader.integer(headerBytes - 1) << 8)
        let size = Int((value >> 4) & ((1 << width) - 1))
        let compressedSize = Int(value >> (4 + width))
        guard size <= header.maximumBlockSize else { throw KaitoError.malformed("zstd literals size") }
        var section = try reader.subreader(compressedSize)
        if type == 2 { huffman = try ZstdHuffman.read(from: &section) }
        guard let huffman else { throw KaitoError.malformed("zstd treeless literals without table") }
        return try huffman.decode(from: &section, count: size, fourStreams: format != 0)
    }

    private struct SequenceTable: Sendable {
        struct Cell: Sendable {
            let value: Int
            let extraBits: Int
            let baseline: Int
            let bits: Int
        }
        let accuracyLog: Int
        let cells: [Cell]

        init(_ fse: ZstdFSE, bases: [Int], bits: [Int]) {
            accuracyLog = fse.accuracyLog
            cells = fse.cells.map {
                Cell(value: bases[$0.symbol], extraBits: bits[$0.symbol], baseline: $0.baseline, bits: $0.bits)
            }
        }
    }

    private func table(_ mode: Int, previous: SequenceTable?, predefined: SequenceTable,
                       maximumLog: Int, bases: [Int], bits: [Int], reader: inout ZstdByteReader) throws -> SequenceTable {
        let fse: ZstdFSE
        switch mode {
        case 0: return predefined
        case 1:
            let symbol = try reader.byte()
            guard symbol < bases.count else { throw KaitoError.malformed("zstd RLE sequence symbol") }
            fse = ZstdFSE(symbol: symbol)
        case 2: fse = try ZstdFSE.read(from: &reader, maximumLog: maximumLog, maximumSymbol: bases.count - 1)
        case 3:
            guard let previous else { throw KaitoError.malformed("zstd repeat FSE without table") }
            return previous
        default: throw KaitoError.malformed("zstd sequence mode")
        }
        return SequenceTable(fse, bases: bases, bits: bits)
    }

    private func compressedBlock(_ bytes: [UInt8]) throws -> [UInt8] {
        var reader = ZstdByteReader(bytes)
        let literalBytes = try literals(&reader)
        let first = try reader.byte()
        let sequenceCount: Int
        if first < 128 { sequenceCount = first }
        else if first == 255 { sequenceCount = Int(try reader.integer(2)) + 0x7f00 }
        else { sequenceCount = ((first - 128) << 8) + (try reader.byte()) }
        if sequenceCount == 0 {
            guard reader.remaining == 0 else { throw KaitoError.malformed("zstd trailing sequence data") }
            storeBlock(literalBytes)
            return literalBytes
        }
        // 各 sequence は最低 3 バイトを出力するので、過大な反復を開始前に拒否できる。
        guard sequenceCount <= header.maximumBlockSize / 3 else {
            throw KaitoError.malformed("zstd sequence count exceeds block")
        }
        let modes = try reader.byte()
        guard modes & 3 == 0 else { throw KaitoError.malformed("zstd reserved sequence bits") }
        let ll = try table(modes >> 6, previous: literalTable, predefined: Self.predefinedLiterals,
                           maximumLog: 9, bases: Self.literalBases, bits: Self.literalBits, reader: &reader)
        let of = try table((modes >> 4) & 3, previous: offsetTable, predefined: Self.predefinedOffsets,
                           maximumLog: 8, bases: Self.offsetBases, bits: Self.offsetBits, reader: &reader)
        let ml = try table((modes >> 2) & 3, previous: matchTable, predefined: Self.predefinedMatches,
                           maximumLog: 9, bases: Self.matchBases, bits: Self.matchBits, reader: &reader)
        literalTable = ll
        offsetTable = of
        matchTable = ml
        var repeats = self.repeats
        defer { self.repeats = repeats }
        let output = prepareBlock(header.maximumBlockSize)
        let count = try literalBytes.withUnsafeBufferPointer { literals in
            try bytes.withUnsafeBytes { input in
                try ll.cells.withUnsafeBufferPointer { llCells in
                    try of.cells.withUnsafeBufferPointer { ofCells in
                        try ml.cells.withUnsafeBufferPointer { mlCells in
                            var bits = try ZstdBitReader(input, range: reader.position..<reader.end)
                            return try executeSequences(
                                bits: &bits, logs: (ll.accuracyLog, of.accuracyLog, ml.accuracyLog),
                                llCells: llCells, ofCells: ofCells, mlCells: mlCells,
                                literals: literals, output: output,
                                sequenceCount: sequenceCount, repeats: &repeats)
                        }
                    }
                }
            }
        }
        return Array(UnsafeBufferPointer(start: output.baseAddress, count: count))
    }

    private func executeSequences(bits: inout ZstdBitReader, logs: (Int, Int, Int),
                                  llCells: UnsafeBufferPointer<SequenceTable.Cell>,
                                  ofCells: UnsafeBufferPointer<SequenceTable.Cell>,
                                  mlCells: UnsafeBufferPointer<SequenceTable.Cell>,
                                  literals: UnsafeBufferPointer<UInt8>, output: UnsafeMutableBufferPointer<UInt8>,
                                  sequenceCount: Int,
                                  repeats: inout (Int, Int, Int)) throws -> Int {
        var llState = try bits.read(logs.0)
        var ofState = try bits.read(logs.1)
        var mlState = try bits.read(logs.2)
        var literalPosition = 0
        var outputCount = 0
        for index in 0..<sequenceCount {
            // 初期状態は accuracyLog ビット。FSE 構築時に全遷移先も表内と検査済み。
            let l = llCells[llState]
            let o = ofCells[ofState]
            let m = mlCells[mlState]
            let extraBits = o.extraBits + m.extraBits + l.extraBits
            guard extraBits <= bits.remaining else {
                throw KaitoError.malformed("zstd bitstream underflow")
            }
            let offsetValue: Int
            let matchLength: Int
            let literalLength: Int
            if extraBits <= 31 {
                let extra = bits.readUnchecked(extraBits)
                offsetValue = o.value + (extra >> (m.extraBits + l.extraBits))
                matchLength = m.value + ((extra >> l.extraBits) & ((1 << m.extraBits) - 1))
                literalLength = l.value + (extra & ((1 << l.extraBits) - 1))
            } else {
                offsetValue = o.value + bits.readUnchecked(o.extraBits)
                matchLength = m.value + bits.readUnchecked(m.extraBits)
                literalLength = l.value + bits.readUnchecked(l.extraBits)
            }
            guard literalLength <= literals.count - literalPosition,
                  literalLength + matchLength <= header.maximumBlockSize - outputCount else {
                throw KaitoError.malformed("zstd sequence lengths")
            }
            // 上の長さ検査により、入力と未初期化の出力領域はともに範囲内。
            if literalLength > 0, literalLength <= 16, literals.count - literalPosition >= 16 {
                // 入力には 16 バイト残り、出力には上記の余白がある。
                let source = UnsafeRawPointer(literals.baseAddress!.advanced(by: literalPosition))
                let target = UnsafeMutableRawPointer(output.baseAddress!.advanced(by: outputCount))
                target.storeBytes(of: source.loadUnaligned(as: UInt64.self), as: UInt64.self)
                target.storeBytes(of: source.loadUnaligned(fromByteOffset: 8, as: UInt64.self),
                                  toByteOffset: 8, as: UInt64.self)
            } else if literalLength > 0 {
                output.baseAddress!.advanced(by: outputCount).initialize(
                    from: literals.baseAddress!.advanced(by: literalPosition), count: literalLength)
            }
            outputCount += literalLength
            literalPosition += literalLength
            let offset = try Self.resolveOffset(offsetValue, literalLength: literalLength, repeats: &repeats)
            // RFC 8878 §3.1.1.1.2 の宣言 window と、現在のブロックを含む到達可能な履歴を検査する。
            // 既知サイズで保持量を減らしても、過去の出力は全て残るので従来と同じ距離を拒否する。
            guard offset > 0, offset <= header.windowSize, offset <= historyCount + outputCount else {
                throw KaitoError.malformed("zstd match exceeds history")
            }
            Self.copyMatch(output: output.baseAddress!, count: &outputCount, length: matchLength,
                           offset: offset)
            if index + 1 < sequenceCount {
                let stateBits = l.bits + m.bits + o.bits
                guard stateBits <= bits.remaining else {
                    throw KaitoError.malformed("zstd bitstream underflow")
                }
                // accuracyLog の上限から stateBits <= 9 + 9 + 8。
                let states = bits.readUnchecked(stateBits)
                llState = l.baseline + (states >> (m.bits + o.bits))
                mlState = m.baseline + ((states >> o.bits) & ((1 << m.bits) - 1))
                ofState = o.baseline + (states & ((1 << o.bits) - 1))
            }
        }
        guard bits.remaining == 0, literals.count - literalPosition <= header.maximumBlockSize - outputCount else {
            throw KaitoError.malformed("zstd sequence trailing bits or literals")
        }
        let tail = literals.count - literalPosition
        if tail > 0 {
            // tail の上限は直前の guard で検査済み。
            output.baseAddress!.advanced(by: outputCount).initialize(
                from: literals.baseAddress!.advanced(by: literalPosition), count: tail)
        }
        return outputCount + tail
    }

    @inline(__always)
    private static func copyMatch(output: UnsafeMutablePointer<UInt8>, count: inout Int, length: Int, offset: Int) {
        // 呼出側が出力上限と履歴距離を検査済み。負の相対位置も同じ storage 内の初期化済み履歴。
        var remaining = length
        let source = count - offset
        if remaining <= 16, offset >= 8 {
            // 各 8 バイトの入力は既に初期化済み。書込みの超過は確保済みの 16 バイト以内。
            let source = UnsafeRawPointer(output.advanced(by: source))
            let target = UnsafeMutableRawPointer(output.advanced(by: count))
            target.storeBytes(of: source.loadUnaligned(as: UInt64.self), as: UInt64.self)
            if remaining > 8 {
                target.storeBytes(of: source.loadUnaligned(fromByteOffset: 8, as: UInt64.self),
                                  toByteOffset: 8, as: UInt64.self)
            }
            count += remaining
            return
        }
        // 初期化済みの履歴・接頭部だけを読み、各コピーは非重複。
        // 周期全体を倍々に伸ばすので、小さい offset でもバイト単位にはならない。
        while remaining > 0 {
            let amount = min(remaining, count - source)
            output.advanced(by: count).initialize(from: output.advanced(by: source), count: amount)
            count += amount
            remaining -= amount
        }
    }

    @inline(__always)
    private static func resolveOffset(_ value: Int, literalLength: Int, repeats: inout (Int, Int, Int)) throws -> Int {
        if value > 3 {
            let offset = value - 3
            repeats = (offset, repeats.0, repeats.1)
            return offset
        }
        let selected = value + (literalLength == 0 ? 1 : 0)
        switch selected {
        case 1: return repeats.0
        case 2:
            repeats = (repeats.1, repeats.0, repeats.2)
        case 3:
            repeats = (repeats.2, repeats.0, repeats.1)
        case 4:
            guard repeats.0 > 1 else { throw KaitoError.malformed("zstd repeat offset is zero") }
            repeats = (repeats.0 - 1, repeats.0, repeats.1)
        default: throw KaitoError.malformed("zstd repeat offset")
        }
        return repeats.0
    }

    // RFC 8878 表 16・17 の基底値と追加ビット数。
    private static let literalBases = Array(0...15) + [
        16,18,20,22,24,28,32,40,48,64,128,256,512,1024,2048,4096,8192,16384,32768,65536
    ]
    private static let literalBits = [Int](repeating: 0, count: 16) + [
        1,1,1,1,2,2,3,3,4,6,7,8,9,10,11,12,13,14,15,16
    ]
    private static let matchBases = Array(3...34) + [
        35,37,39,41,43,47,51,59,67,83,99,131,259,515,1027,2051,4099,8195,16387,32771,65539
    ]
    private static let matchBits = [Int](repeating: 0, count: 32) + [
        1,1,1,1,2,2,3,3,4,4,5,7,8,9,10,11,12,13,14,15,16
    ]
    private static let offsetBases = (0...31).map { 1 << $0 }
    private static let offsetBits = Array(0...31)

    // 固定分布のみを一度構築する。外部入力は try! に渡らない。
    private static let predefinedLiterals = SequenceTable(
        try! ZstdFSE(probabilities: ZstdFSE.literalDistribution, accuracyLog: 6), bases: literalBases, bits: literalBits)
    private static let predefinedOffsets = SequenceTable(
        try! ZstdFSE(probabilities: ZstdFSE.offsetDistribution, accuracyLog: 5), bases: offsetBases, bits: offsetBits)
    private static let predefinedMatches = SequenceTable(
        try! ZstdFSE(probabilities: ZstdFSE.matchDistribution, accuracyLog: 6), bases: matchBases, bits: matchBits)
}
