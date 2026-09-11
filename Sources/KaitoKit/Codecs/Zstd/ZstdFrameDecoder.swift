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
    private var window: [UInt8] = []
    private var windowPosition = 0
    private var historyCount = 0
    private var produced: UInt64 = 0
    private var checksum = ZstdXXH64()
    private var huffman: ZstdHuffman?
    private var literalTable: ZstdFSE?
    private var offsetTable: ZstdFSE?
    private var matchTable: ZstdFSE?
    private var repeats = (1, 4, 8)
    private(set) var finished = false
    var allocatedWindowBytes: Int { window.count }

    init(header: ZstdFrameHeader) {
        self.header = header
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
            let retained = header.retainedWindowSize
            // 既知サイズでは上の produced <= contentSize 検査、不明なら
            // maximumBlockSize <= windowSize == retained により output.count <= retained。
            var rest = output[...]
            if window.count < retained {
                // 満杯になる前は windowPosition == window.count == historyCount で折り返さない。
                let take = min(retained - window.count, rest.count)
                window.append(contentsOf: rest.prefix(take))
                rest = rest.dropFirst(take)
                historyCount = window.count
                windowPosition = window.count == retained ? 0 : window.count
            }
            if !rest.isEmpty {
                // 残りは確保済みのリングに最大二つの連続コピーで追記する。
                let first = min(rest.count, window.count - windowPosition)
                window.replaceSubrange(windowPosition..<(windowPosition + first), with: rest.prefix(first))
                if first < rest.count {
                    window.replaceSubrange(0..<(rest.count - first), with: rest.dropFirst(first))
                }
                windowPosition += rest.count
                if windowPosition >= window.count { windowPosition -= window.count }
                historyCount = min(window.count, historyCount + rest.count)
            }
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

    private func table(_ mode: Int, previous: ZstdFSE?, distribution: [Int], log: Int,
                       maximumLog: Int, maximumSymbol: Int, reader: inout ZstdByteReader) throws -> ZstdFSE {
        switch mode {
        case 0: return try ZstdFSE(probabilities: distribution, accuracyLog: log)
        case 1:
            let symbol = try reader.byte()
            guard symbol <= maximumSymbol else { throw KaitoError.malformed("zstd RLE sequence symbol") }
            return ZstdFSE(symbol: symbol)
        case 2: return try ZstdFSE.read(from: &reader, maximumLog: maximumLog, maximumSymbol: maximumSymbol)
        case 3:
            guard let previous else { throw KaitoError.malformed("zstd repeat FSE without table") }
            return previous
        default: throw KaitoError.malformed("zstd sequence mode")
        }
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
            return literalBytes
        }
        // 各 sequence は最低 3 バイトを出力するので、過大な反復を開始前に拒否できる。
        guard sequenceCount <= header.maximumBlockSize / 3 else {
            throw KaitoError.malformed("zstd sequence count exceeds block")
        }
        let modes = try reader.byte()
        guard modes & 3 == 0 else { throw KaitoError.malformed("zstd reserved sequence bits") }
        let ll = try table(modes >> 6, previous: literalTable, distribution: ZstdFSE.literalDistribution,
                           log: 6, maximumLog: 9, maximumSymbol: 35, reader: &reader)
        let of = try table((modes >> 4) & 3, previous: offsetTable, distribution: ZstdFSE.offsetDistribution,
                           log: 5, maximumLog: 8, maximumSymbol: 31, reader: &reader)
        let ml = try table((modes >> 2) & 3, previous: matchTable, distribution: ZstdFSE.matchDistribution,
                           log: 6, maximumLog: 9, maximumSymbol: 52, reader: &reader)
        literalTable = ll
        offsetTable = of
        matchTable = ml
        var bits = try ZstdBitReader(bytes, range: reader.position..<reader.end)
        var llState = try bits.read(ll.accuracyLog)
        var ofState = try bits.read(of.accuracyLog)
        var mlState = try bits.read(ml.accuracyLog)
        var literalPosition = 0
        var output: [UInt8] = []
        output.reserveCapacity(header.maximumBlockSize)
        for index in 0..<sequenceCount {
            let l = try ll.cell(llState)
            let o = try of.cell(ofState)
            let m = try ml.cell(mlState)
            let offsetValue = (1 << o.symbol) + (try bits.read(o.symbol))
            let matchLength = Self.matchBases[m.symbol] + (try bits.read(Self.matchBits[m.symbol]))
            let literalLength = Self.literalBases[l.symbol] + (try bits.read(Self.literalBits[l.symbol]))
            guard literalLength <= literalBytes.count - literalPosition,
                  literalLength + matchLength <= header.maximumBlockSize - output.count else {
                throw KaitoError.malformed("zstd sequence lengths")
            }
            output.append(contentsOf: literalBytes[literalPosition..<(literalPosition + literalLength)])
            literalPosition += literalLength
            let offset = try resolveOffset(offsetValue, literalLength: literalLength)
            // RFC 8878 §3.1.1.1.2 の宣言 window と、現在のブロックを含む到達可能な履歴を検査する。
            // 既知サイズで保持量を減らしても、過去の出力は全て残るので従来と同じ距離を拒否する。
            guard offset > 0, offset <= header.windowSize, offset <= historyCount + output.count else {
                throw KaitoError.malformed("zstd match exceeds history")
            }
            // 重なる match も、直前に書いたバイトを順に参照する。
            for _ in 0..<matchLength {
                let source = output.count - offset
                if source >= 0 { output.append(output[source]) }
                else {
                    // -source <= historyCount <= window.count なので、実保持量で一度折り返せば範囲内。
                    let position = windowPosition + source
                    output.append(window[position < 0 ? position + window.count : position])
                }
            }
            if index + 1 < sequenceCount {
                llState = l.baseline + (try bits.read(l.bits))
                mlState = m.baseline + (try bits.read(m.bits))
                ofState = o.baseline + (try bits.read(o.bits))
            }
        }
        guard bits.remaining == 0, literalBytes.count - literalPosition <= header.maximumBlockSize - output.count else {
            throw KaitoError.malformed("zstd sequence trailing bits or literals")
        }
        output.append(contentsOf: literalBytes[literalPosition...])
        return output
    }

    private func resolveOffset(_ value: Int, literalLength: Int) throws -> Int {
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
}
