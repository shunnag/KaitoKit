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
    static let outputSlack = 32
    let header: ZstdFrameHeader
    private let tuning: ZstdTuning
    private let blockBuffer = ZstdScratchBuffer()
    private let literalBuffer = ZstdScratchBuffer()
    private var probabilities = UnsafeMutableBufferPointer<Int>(start: nil, count: 0)
    private var storage = UnsafeMutableRawBufferPointer(start: nil, count: 0)
    private var writePosition = 0
    private var historyCount = 0
    private var produced: UInt64 = 0
    private var checksum = ZstdXXH64()
    private var huffman: ZstdHuffman?
    private let literalTable = ZstdSequenceTable(maximumLog: 9)
    private let offsetTable = ZstdSequenceTable(maximumLog: 8)
    private let matchTable = ZstdSequenceTable(maximumLog: 9)
    private var repeats = (1, 4, 8)
    private(set) var finished = false
    // 予約容量ではなく、検証済みの保持履歴量を返す。
    var allocatedWindowBytes: Int { historyCount }
    var allocatedBufferBytes: Int { storage.count }

    var allocatedScratchBytes: Int {
        blockBuffer.allocatedBytes + literalBuffer.allocatedBytes + probabilities.count * MemoryLayout<Int>.stride
            + literalTable.allocatedBytes + offsetTable.allocatedBytes + matchTable.allocatedBytes
            + (huffman?.allocatedTableBytes ?? 0)
    }

    init(header: ZstdFrameHeader, tuning: ZstdTuning = .default) {
        self.header = header
        self.tuning = tuning
    }

    deinit {
        storage.baseAddress?.deallocate()
        probabilities.baseAddress?.deallocate()
    }

    private func prepareBlock(_ capacity: Int) -> UnsafeMutableBufferPointer<UInt8> {
        // 履歴は [writePosition - historyCount, writePosition)。末尾 outputSlack バイトは書込み専用余白（D3）。
        if storage.count - writePosition < capacity + Self.outputSlack {
            let needed = historyCount + capacity + Self.outputSlack
            if storage.count < needed {
                // 宣言 window だけでは確保せず、実出力に応じて倍増する。
                // 利用者が上限を Int.max まで広げても、宣言値の倍増で overflow させない。
                let maximumHistory = (Int.max - header.maximumBlockSize - Self.outputSlack) / 2
                let ceiling = header.retainedWindowSize > maximumHistory ? Int.max
                    : 2 * header.retainedWindowSize + header.maximumBlockSize + Self.outputSlack
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
            .assumingMemoryBound(to: UInt8.self), count: capacity + Self.outputSlack)
    }

    private func checkedProduced(_ count: Int) throws -> UInt64 {
        let total = try Checked.add(produced, UInt64(count))
        if let size = header.contentSize, total > size {
            throw KaitoError.malformed("zstd frame output exceeds content size")
        }
        return total
    }

    // D11: view は次の nextBlock または frame 解放まで有効。返却前に最終サイズ・checksum も検証する。
    func nextBlock(_ input: ZstdInput) throws -> UnsafeRawBufferPointer {
        let block = try header.blockHeader(input)
        let output: UnsafeRawBufferPointer
        let total: UInt64
        switch block.type {
        case 0, 1:
            // D11: 既知の再生長は確保前に検査。空 block は prepareBlock せず、RLE の byte は必ず消費する。
            total = try checkedProduced(block.size)
            let repeated = block.type == 1 ? UInt8(try input.byte()) : 0
            if block.size == 0 {
                output = UnsafeRawBufferPointer(start: nil, count: 0)
            } else {
                let target = prepareBlock(block.size)
                // prepareBlock が実長 + outputSlack を確保済み。raw/RLE は実長だけ書き、余白を読まない。
                if block.type == 0 {
                    try input.read(block.size, into: UnsafeMutableRawPointer(target.baseAddress!))
                } else {
                    target.baseAddress!.initialize(repeating: repeated, count: block.size)
                }
                output = UnsafeRawBufferPointer(start: target.baseAddress, count: block.size)
            }
        case 2:
            blockBuffer.reserve(block.size, maximum: header.maximumBlockSize)
            try input.read(block.size, into: blockBuffer.base)
            blockBuffer.pad(after: block.size)
            output = try compressedBlock(UnsafeRawBufferPointer(start: blockBuffer.base, count: block.size))
            total = try checkedProduced(output.count)
        default: throw KaitoError.malformed("zstd reserved block")
        }
        produced = total
        if header.checksum { checksum.update(output) }
        if block.last {
            if let size = header.contentSize, size != produced {
                throw KaitoError.malformed("zstd frame content size mismatch")
            }
            if header.checksum, try input.integer(4) != UInt64(UInt32(truncatingIfNeeded: checksum.value)) {
                throw KaitoError.checksumMismatch(entry: 0)
            }
            finished = true
        } else if !output.isEmpty {
            writePosition += output.count
            historyCount = min(header.retainedWindowSize, historyCount + output.count)
        }
        return output
    }

    private func literals(_ reader: inout ZstdByteReader) throws -> UnsafeRawBufferPointer {
        let first = try reader.byte()
        let type = first & 3
        let format = (first >> 2) & 3
        if type <= 1 {
            let size: Int
            if format & 1 == 0 { size = first >> 3 }
            else if format == 1 { size = (first >> 4) | (try reader.byte() << 4) }
            else { size = (first >> 4) | (Int(try reader.integer(2)) << 4) }
            guard size <= header.maximumBlockSize else { throw KaitoError.malformed("zstd literals size") }
            if type == 1 {
                let byte = UInt8(try reader.byte())
                literalBuffer.reserve(size, maximum: header.maximumBlockSize)
                // D2: 有効 size バイトと直後の 32 バイトだけを同じ値で初期化する。
                literalBuffer.base.initializeMemory(as: UInt8.self, repeating: byte,
                                                     count: size + ZstdScratchBuffer.backPad)
                return UnsafeRawBufferPointer(start: literalBuffer.base, count: size)
            }
            // D1/D2: raw literals は block 内の view。後続 block データまたは後余白が 32 バイト以上ある。
            return UnsafeRawBufferPointer(rebasing: reader.bytes[try reader.take(size)])
        }
        let headerBytes = [3, 3, 4, 5][format]
        let width = [10, 10, 14, 18][format]
        let value = UInt64(first) | (try reader.integer(headerBytes - 1) << 8)
        let size = Int((value >> 4) & ((1 << width) - 1))
        let compressedSize = Int(value >> (4 + width))
        guard size <= header.maximumBlockSize else { throw KaitoError.malformed("zstd literals size") }
        var section = try reader.subreader(compressedSize)
        if type == 2 {
            // D8/D9: 新しい表でも frame 所有の storage は再利用し、pair の有効性と使用量だけをリセットする。
            if huffman == nil { huffman = ZstdHuffman() }
            try huffman!.readTable(from: &section)
        }
        guard let huffman else { throw KaitoError.malformed("zstd treeless literals without table") }
        literalBuffer.reserve(size, maximum: header.maximumBlockSize)
        let target = literalBuffer.base.bindMemory(to: UInt8.self, capacity: size + ZstdScratchBuffer.backPad)
        try huffman.decode(from: &section, count: size, fourStreams: format != 0, tuning: tuning,
                           into: UnsafeMutableBufferPointer(start: target, count: size + ZstdScratchBuffer.backPad))
        return UnsafeRawBufferPointer(start: literalBuffer.base, count: size)
    }

    private func table(_ mode: Int, target: ZstdSequenceTable, predefined: [ZstdSequenceCell],
                       predefinedLog: Int, maximumLog: Int, bases: [Int], bits: [Int],
                       reader: inout ZstdByteReader) throws {
        switch mode {
        case 0: target.predefined(predefined, log: predefinedLog)
        case 1: try target.rle(symbol: reader.byte(), bases: bases, bits: bits)
        case 2:
            if probabilities.isEmpty { probabilities = .allocate(capacity: 53) }
            let description = try ZstdFSE.readDistribution(from: &reader, maximumLog: maximumLog,
                                                          maximumSymbol: bases.count - 1, into: probabilities)
            try target.build(probabilities: probabilities, count: description.count,
                             log: description.accuracyLog, bases: bases, bits: bits)
        case 3:
            guard target.accuracyLog != nil else { throw KaitoError.malformed("zstd repeat FSE without table") }
        default: throw KaitoError.malformed("zstd sequence mode")
        }
    }

    private func compressedBlock(_ bytes: UnsafeRawBufferPointer) throws -> UnsafeRawBufferPointer {
        // D7: input / literals / tables はフレーム所有。以下の全 view はこの呼出中に無効化されない。
        var reader = ZstdByteReader(bytes)
        let literalBytes = try literals(&reader)
        let first = try reader.byte()
        let sequenceCount: Int
        if first < 128 { sequenceCount = first }
        else if first == 255 { sequenceCount = Int(try reader.integer(2)) + 0x7f00 }
        else { sequenceCount = ((first - 128) << 8) + (try reader.byte()) }
        if sequenceCount == 0 {
            guard reader.remaining == 0 else { throw KaitoError.malformed("zstd trailing sequence data") }
            if literalBytes.isEmpty { return UnsafeRawBufferPointer(start: nil, count: 0) }
            let output = prepareBlock(literalBytes.count)
            // 検査済み literal 領域から、確保済み storage へ実データだけをコピーする。
            UnsafeMutableRawPointer(output.baseAddress!).copyMemory(
                from: literalBytes.baseAddress!, byteCount: literalBytes.count)
            return UnsafeRawBufferPointer(start: output.baseAddress, count: literalBytes.count)
        }
        // 各 sequence は最低 3 バイトを出力するので、過大な反復を開始前に拒否できる。
        guard sequenceCount <= header.maximumBlockSize / 3 else {
            throw KaitoError.malformed("zstd sequence count exceeds block")
        }
        let modes = try reader.byte()
        guard modes & 3 == 0 else { throw KaitoError.malformed("zstd reserved sequence bits") }
        try table(modes >> 6, target: literalTable, predefined: Self.predefinedLiterals,
                  predefinedLog: 6, maximumLog: 9, bases: Self.literalBases, bits: Self.literalBits, reader: &reader)
        try table((modes >> 4) & 3, target: offsetTable, predefined: Self.predefinedOffsets,
                  predefinedLog: 5, maximumLog: 8, bases: Self.offsetBases, bits: Self.offsetBits, reader: &reader)
        try table((modes >> 2) & 3, target: matchTable, predefined: Self.predefinedMatches,
                  predefinedLog: 6, maximumLog: 9, bases: Self.matchBases, bits: Self.matchBits, reader: &reader)
        var repeats = self.repeats
        let output = prepareBlock(header.maximumBlockSize)
        var bits = try ZstdPaddedBitReader(bytes, range: reader.position..<reader.end)
        let count = try Self.executeSequences(
            bits: &bits, logs: (literalTable.accuracyLog!, offsetTable.accuracyLog!, matchTable.accuracyLog!),
            llCells: UnsafePointer(literalTable.cells!), ofCells: UnsafePointer(offsetTable.cells!),
            mlCells: UnsafePointer(matchTable.cells!), literals: literalBytes,
            output: UnsafeMutableRawPointer(output.baseAddress!), sequenceCount: sequenceCount,
            repeats: &repeats, windowSize: header.windowSize, historyCount: historyCount,
            maximumBlockSize: header.maximumBlockSize, matchPath: tuning.matchPath)
        self.repeats = repeats
        // D11: 検証済みの実長だけを借用する。outputSlack は返却・checksum・履歴に含めない。
        return UnsafeRawBufferPointer(start: output.baseAddress, count: count)
    }

    private static func executeSequences(bits: inout ZstdPaddedBitReader, logs: (Int, Int, Int),
                                         llCells: UnsafePointer<ZstdSequenceCell>,
                                         ofCells: UnsafePointer<ZstdSequenceCell>,
                                         mlCells: UnsafePointer<ZstdSequenceCell>,
                                         literals: UnsafeRawBufferPointer, output: UnsafeMutableRawPointer,
                                         sequenceCount: Int, repeats: inout (Int, Int, Int),
                                         windowSize: Int, historyCount: Int, maximumBlockSize: Int,
                                         matchPath: ZstdTuning.MatchPath) throws -> Int {
        // D6: 全て値またはローカル変数。ループ内に class property / stored inout は無い。
        // 初期幅 <= 9+8+9、consumed <= 8+26。短い stream は refill または厳密終端で拒否する。
        var llState = bits.readUnchecked(logs.0)
        var ofState = bits.readUnchecked(logs.1)
        var mlState = bits.readUnchecked(logs.2)
        let literalBase = literals.baseAddress!
        let literalCount = literals.count
        var literalPosition = 0
        var outputCount = 0
        for index in 0..<sequenceCount {
            // 初期状態は log ビット。全遷移先も構築時に検査済みで、常に各表内。
            let l = llCells[llState]
            let o = ofCells[ofState]
            let m = mlCells[mlState]
            try bits.refill()
            let ofBits = Int(o.extraBits)
            let offsetValue = Int(o.base) &+ bits.readUnchecked(ofBits)
            // refill 後は >= 57 ビット。OF > 24 の時だけ補充し ML+LL <= 32 を確保する。
            if ofBits > 24 { try bits.refill() }
            let matchLength = Int(m.base) &+ bits.readUnchecked(Int(m.extraBits))
            let literalLength = Int(l.base) &+ bits.readUnchecked(Int(l.extraBits))
            let offset = resolveOffset(offsetValue, literalLength: literalLength, repeats: &repeats)
            // 長さ <= 131074、offset < 2^32。64-bit Int への拡張後の加算は overflow しない。
            if literalLength > literalCount - literalPosition
                || literalLength + matchLength > maximumBlockSize - outputCount
                || offset <= 0 || offset > windowSize || offset > historyCount + outputCount + literalLength {
                try invalidSequence(literalLength: literalLength, matchLength: matchLength, offset: offset,
                                    literalsRemaining: literalCount - literalPosition,
                                    outputRemaining: maximumBlockSize - outputCount,
                                    windowSize: windowSize, availableHistory: historyCount + outputCount + literalLength)
            }
            // D2/D3: source に 32 初期化済みバイト、target に outputSlack。LL == 0 でも 16 バイトを写す。
            copyLiterals(from: literalBase.advanced(by: literalPosition),
                         to: output.advanced(by: outputCount), length: literalLength)
            outputCount &+= literalLength
            literalPosition &+= literalLength
            copyMatch(output: output.advanced(by: outputCount), length: matchLength, offset: offset, path: matchPath)
            outputCount &+= matchLength
            if index + 1 < sequenceCount {
                try bits.refill()
                // 状態幅 <= 9+9+8 <= 57、順序は LL, ML, OF。最後の sequence は遷移しない。
                llState = Int(l.nextBaseline) &+ bits.readUnchecked(Int(l.stateBits))
                mlState = Int(m.nextBaseline) &+ bits.readUnchecked(Int(m.stateBits))
                ofState = Int(o.nextBaseline) &+ bits.readUnchecked(Int(o.stateBits))
            }
        }
        guard bits.remaining == 0, literalCount - literalPosition <= maximumBlockSize - outputCount else {
            throw KaitoError.malformed("zstd sequence trailing bits or literals")
        }
        let tail = literalCount - literalPosition
        if tail > 0 {
            // 終端 guard で長さを検査済み。末尾 literal は実長だけを写す。
            output.advanced(by: outputCount).copyMemory(from: literalBase.advanced(by: literalPosition), byteCount: tail)
        }
        return outputCount + tail
    }

    @inline(never)
    private static func invalidSequence(literalLength: Int, matchLength: Int, offset: Int,
                                        literalsRemaining: Int, outputRemaining: Int,
                                        windowSize: Int, availableHistory: Int) throws -> Never {
        // D6: 従来と同じ優先順でエラーを選び、いずれもコピー前に返す。
        if literalLength > literalsRemaining || literalLength + matchLength > outputRemaining {
            throw KaitoError.malformed("zstd sequence lengths")
        }
        if offset <= 0 || offset > windowSize || offset > availableHistory {
            throw KaitoError.malformed("zstd match exceeds history")
        }
        preconditionFailure("validated sequence reached cold error helper")
    }

    @inline(__always)
    private static func copy16(from source: UnsafeRawPointer, to target: UnsafeMutableRawPointer) {
        // 呼出側が source の初期化済み 16 バイトと target の確保済み 16 バイトを保証する。
        target.storeBytes(of: source.loadUnaligned(as: UInt64.self), as: UInt64.self)
        target.storeBytes(of: source.loadUnaligned(fromByteOffset: 8, as: UInt64.self),
                          toByteOffset: 8, as: UInt64.self)
    }

    @inline(__always)
    private static func copyLiterals(from source: UnsafeRawPointer, to target: UnsafeMutableRawPointer, length: Int) {
        var position = 0
        repeat {
            // 最終 chunk の超過は 15 バイト以下（LL == 0 は 16）。両側の 32 バイト余白内。
            copy16(from: source.advanced(by: position), to: target.advanced(by: position))
            position &+= 16
        } while position < length
    }

    @inline(__always)
    private static func copyMatch(output: UnsafeMutableRawPointer, length: Int, offset: Int,
                                  path: ZstdTuning.MatchPath) {
        // D3/D6: 履歴距離・出力長は検査済み。各 chunk の読取り終端 <= その書込み開始位置。
        // 従って storage の余白は読まず、literal は D1/D2 から読む。storage 全体のゼロ初期化は不要。
        if offset >= 16, path == .automatic {
            var position = 0
            repeat {
                // offset >= 16: [o-off+16k, +16) は現在位置 o+16k 以下の初期化済み履歴。
                copy16(from: output.advanced(by: position - offset), to: output.advanced(by: position))
                position &+= 16
            } while position < length
            return
        }
        var position = 0
        var distance = offset
        if offset < 8 || path == .byteThenPeriod {
            // 短い match は実長で止めるので、バイト経路も出力余白を読み戻さない。
            let prefix = min(8, length)
            while position < prefix {
                output.storeBytes(of: output.load(fromByteOffset: position - offset, as: UInt8.self),
                                  toByteOffset: position, as: UInt8.self)
                position &+= 1
            }
            distance = offset < 8 ? offset * ((8 + offset - 1) / offset) : offset
        }
        while position < length {
            // distance >= 8（小 offset は周期の倍数 8...14）。各入力 8 バイトは現在位置より前。
            output.storeBytes(of: output.loadUnaligned(fromByteOffset: position - distance, as: UInt64.self),
                              toByteOffset: position, as: UInt64.self)
            position &+= 8
        }
    }

    @inline(__always)
    private static func resolveOffset(_ value: Int, literalLength: Int, repeats: inout (Int, Int, Int)) -> Int {
        if value > 3 {
            let offset = value - 3
            repeats = (offset, repeats.0, repeats.1)
            return offset
        }
        let selected = value + (literalLength == 0 ? 1 : 0)
        switch selected {
        case 1: return repeats.0
        case 2: repeats = (repeats.1, repeats.0, repeats.2)
        case 3: repeats = (repeats.2, repeats.0, repeats.1)
        default:
            // OF の基底 >= 1、従って残るのは case 4 のみ。offset 0 は履歴 guard が拒否する。
            repeats = (repeats.0 - 1, repeats.0, repeats.1)
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
    private static let predefinedLiterals = ZstdSequenceTable.predefinedCells(
        try! ZstdFSE(probabilities: ZstdFSE.literalDistribution, accuracyLog: 6), bases: literalBases, bits: literalBits)
    private static let predefinedOffsets = ZstdSequenceTable.predefinedCells(
        try! ZstdFSE(probabilities: ZstdFSE.offsetDistribution, accuracyLog: 5), bases: offsetBases, bits: offsetBits)
    private static let predefinedMatches = ZstdSequenceTable.predefinedCells(
        try! ZstdFSE(probabilities: ZstdFSE.matchDistribution, accuracyLog: 6), bases: matchBases, bits: matchBits)
}
