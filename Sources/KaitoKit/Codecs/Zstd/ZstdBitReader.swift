import Foundation

// RFC 8878 §4 の逆向きストリーム。終端の 1 と上位のゼロを除き、値のビット順は保つ。
struct ZstdBitReader {
    // 所有側の withUnsafeBytes 内でだけ生成・使用する。
    private let bytes: UnsafeRawBufferPointer
    private let lower: Int
    private var nextByte: Int
    private var reservoir: UInt64
    private var available: Int

    init(_ bytes: UnsafeRawBufferPointer, range: Range<Int>) throws {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count, !range.isEmpty,
              bytes[range.upperBound - 1] != 0 else {
            throw KaitoError.malformed("zstd bitstream end marker")
        }
        self.bytes = bytes
        lower = range.lowerBound
        nextByte = range.upperBound - 2
        let last = bytes[range.upperBound - 1]
        available = 7 - last.leadingZeroBitCount
        reservoir = UInt64(last) & ((1 << available) - 1)
    }

    var remaining: Int { available + (nextByte - lower + 1) * 8 }

    @inline(__always)
    mutating func peekPadded(_ count: Int) -> Int {
        // 呼出幅は 0...31。レジスタを 63 ビット以下に保つ。
        if available < count {
            if nextByte - lower >= 7 {
                // [nextByte - 7, nextByte] は指定領域内。上位側の必要なバイトだけ消費する。
                let word = UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: nextByte - 7, as: UInt64.self))
                let take = (63 - available) >> 3
                let width = take * 8
                reservoir = (reservoir &<< width) | (word &>> (64 - width))
                available += width
                nextByte -= take
            } else {
                while available < count, nextByte >= lower {
                    reservoir = (reservoir << 8) | UInt64(bytes[nextByte])
                    available += 8
                    nextByte -= 1
                }
            }
        }
        // 上記の幅制約により、各シフト量は 0...63。
        if available < count { return Int((reservoir & ((1 &<< available) - 1)) &<< (count - available)) }
        return Int((reservoir &>> (available - count)) & ((1 &<< count) - 1))
    }

    @inline(__always)
    mutating func read(_ count: Int) throws -> Int {
        guard (0...31).contains(count), count <= remaining else {
            throw KaitoError.malformed("zstd bitstream underflow")
        }
        return readUnchecked(count)
    }

    @inline(__always)
    mutating func readUnchecked(_ count: Int) -> Int {
        // 呼出側が 0...31 と残量を検査済み。
        let value = peekPadded(count)
        dropUnchecked(count)
        return value
    }

    @inline(__always)
    mutating func dropUnchecked(_ count: Int) {
        // peekPadded 後、count <= available が保証される場合だけ使う。
        available -= count
        // 消費済みの上位ビットは peek のマスクで除く。
    }
}

// D5: 前余白 8 バイトを持つブロック上の逆向き reader。所有フレームの寿命内だけ使用する。
struct ZstdPaddedBitReader {
    private let base: UnsafeRawPointer
    private let lower: Int
    private var p: Int
    private var container: UInt64
    private(set) var consumed: Int

    init(_ bytes: UnsafeRawBufferPointer, range: Range<Int>) throws {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count, !range.isEmpty,
              bytes[range.upperBound - 1] != 0 else {
            throw KaitoError.malformed("zstd bitstream end marker")
        }
        base = bytes.baseAddress!
        lower = range.lowerBound
        p = range.upperBound - 1
        consumed = bytes[p].leadingZeroBitCount + 1
        // [s,e) の s >= allocation + F >= allocation + 8。初回も [p-7,p] は確保内。
        container = UInt64(littleEndian: base.loadUnaligned(fromByteOffset: p - 7, as: UInt64.self))
    }

    var remaining: Int { (p + 1 - lower) * 8 - consumed }

    @inline(__always)
    mutating func refill() throws {
        let next = p - (consumed >> 3)
        // D5 境界証明: 正常時 p >= s-1、従って [p-7,p] ⊂ [s-8,e) ⊂ allocation。
        // 不正な前方への超過は cold helper で拒否し、確保外の load は実行しない。
        if next < lower - 1 { try Self.underflow() }
        p = next
        consumed &= 7
        container = UInt64(littleEndian: base.loadUnaligned(fromByteOffset: p - 7, as: UInt64.self))
    }

    @inline(__always)
    mutating func readUnchecked(_ count: Int) -> Int {
        // 呼出幅 0...31、refill schedule により consumed + count <= 63。残量は終端で厳密検査する。
        let value = ((container &<< consumed) &>> 1) &>> (63 - count)
        consumed += count
        return Int(value)
    }

    @inline(__always)
    func peekUnchecked(_ count: Int) -> Int {
        // D10: Huffman の幅 <= 12。batch の K または tail の refill が consumed + count <= 63 を保証する。
        Int(((container &<< consumed) &>> 1) &>> (63 - count))
    }

    @inline(__always)
    mutating func dropUnchecked(_ count: Int) {
        // D10: 検証済み cell の幅だけ進む。batch は最大幅で残量を予約し、tail は実幅を検査する。
        consumed += count
    }

    @inline(never)
    private static func underflow() throws -> Never {
        throw KaitoError.malformed("zstd bitstream underflow")
    }
}

// ブロック内の前向き view。部分領域を独立した上限付き reader にできる。
struct ZstdByteReader {
    let bytes: UnsafeRawBufferPointer
    // 配列 API の互換 wrapper のみ所有する。本番はフレームの scratch を借用する。
    fileprivate let owner: ZstdScratchBuffer?
    private(set) var position: Int
    let end: Int

    init(_ bytes: [UInt8]) {
        let owner = ZstdScratchBuffer()
        owner.reserve(bytes.count, maximum: bytes.count)
        bytes.withUnsafeBytes { source in
            if !source.isEmpty { owner.base.copyMemory(from: source.baseAddress!, byteCount: source.count) }
        }
        owner.pad(after: bytes.count)
        self.owner = owner
        self.bytes = UnsafeRawBufferPointer(start: owner.base, count: bytes.count)
        position = 0
        end = bytes.count
    }

    init(_ bytes: UnsafeRawBufferPointer) {
        self.bytes = bytes
        owner = nil
        position = 0
        end = bytes.count
    }

    private init(bytes: UnsafeRawBufferPointer, range: Range<Int>, owner: ZstdScratchBuffer?) {
        self.bytes = bytes
        self.owner = owner
        position = range.lowerBound
        end = range.upperBound
    }

    var remaining: Int { end - position }

    mutating func byte() throws -> Int { Int(try integer(1)) }

    mutating func integer(_ count: Int) throws -> UInt64 {
        guard (0...8).contains(count), count <= remaining else { throw KaitoError.truncated }
        var value: UInt64 = 0
        // 直前の guard が [position, position + count) を view 内に制限する。
        for index in 0..<count { value |= UInt64(bytes[position + index]) << (8 * index) }
        position += count
        return value
    }

    mutating func take(_ count: Int) throws -> Range<Int> {
        guard count >= 0, count <= remaining else { throw KaitoError.truncated }
        let start = position
        position += count
        return start..<position
    }

    mutating func subreader(_ count: Int) throws -> Self {
        Self(bytes: bytes, range: try take(count), owner: owner)
    }
}

// FSE 分布だけは最下位ビットから前向きに読む。各読取りで境界を確認する。
struct ZstdForwardBits {
    let bytes: UnsafeRawBufferPointer
    private let owner: ZstdScratchBuffer?
    let end: Int
    var position: Int

    init(_ reader: ZstdByteReader) {
        bytes = reader.bytes
        owner = reader.owner
        end = reader.end * 8
        position = reader.position * 8
    }

    mutating func read(_ count: Int) throws -> Int {
        guard (0...16).contains(count), count <= end - position else { throw KaitoError.truncated }
        var result = 0
        var written = 0
        while written < count {
            let shift = position & 7
            let width = min(8 - shift, count - written)
            // count <= end - position の検査により、参照バイトは部分 view 内。
            result |= ((Int(bytes[position >> 3]) >> shift) & ((1 << width) - 1)) << written
            position += width
            written += width
        }
        return result
    }
}
