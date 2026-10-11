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

// D5: 前余白（16 byte）を持つブロック上の逆向き reader。word load は余白の先頭 8 byte に収まる。所有フレームの寿命内だけ使用する。
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
    mutating func refill(minimumBits: Int = 64) throws {
        let next = p - (consumed >> 3)
        // D5 境界証明: 正常時 p >= s-1、従って [p-7,p] ⊂ [s-8,e) ⊂ allocation。
        // 不正な前方への超過は cold helper で拒否し、確保外の load は実行しない。
        if next < lower - 1 { try Self.underflow() }
        // 同じ checkpoint で下限を検査し、現在の word に必要量があれば load を省く。
        // consumed を正規化しない場合も remaining と read のビット位置は同一。
        if consumed + minimumBits <= 63 { return }
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

// D5: sequence stream 専用の逆向き reader。現在 word [p-7, p] と、その下の word [p-15, p-8] を保持する。
// refill は下位 word からのシフトで現在 word を補い、新しい下位 word の load は次の refill まで使わない。
// 消費位置に依存する load を状態遷移の経路から外し、分岐も持たない。block scratch の前余白 16 byte が
// 下限 p = s-1 での load [s-16, s-1] を確保内に収める。ZstdPaddedBitReader と同じ検査を同じ checkpoint で行うので、
// 不正 stream に対する error も同一になる。
struct ZstdSequenceBitReader {
    /// 現在 word の最上位 byte の位置（p）。
    private var pointer: UnsafeRawPointer
    /// s-1 の位置。p はこれより前へ進めない。
    private let lowerPointer: UnsafeRawPointer
    private var container: UInt64
    /// 下位 word [p-15, p-8] の上位 56 bit（1 byte 右にずらした値）。refill は byte 単位なので下位 byte は使わない。
    private var nextBytes: UInt64
    private(set) var consumed: Int

    init(_ bytes: UnsafeRawBufferPointer, range: Range<Int>) throws {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count, !range.isEmpty,
              bytes[range.upperBound - 1] != 0 else {
            throw KaitoError.malformed("zstd bitstream end marker")
        }
        let base = bytes.baseAddress!
        lowerPointer = base + (range.lowerBound - 1)
        pointer = base + (range.upperBound - 1)
        consumed = bytes[range.upperBound - 1].leadingZeroBitCount + 1
        // s >= allocation + 16。初回の 2 word [p-15, p] も確保内。
        container = UInt64(littleEndian: pointer.loadUnaligned(fromByteOffset: -7, as: UInt64.self))
        nextBytes = UInt64(littleEndian: pointer.loadUnaligned(fromByteOffset: -15, as: UInt64.self)) &>> 8
    }

    var remaining: Int { (pointer - lowerPointer) * 8 - consumed }

    /// 消費済み byte を捨て、未消費ビットを 57 以上にする。refill 直後は consumed <= 7。
    @inline(__always)
    mutating func refill() throws {
        let target = pointer - (consumed >> 3)
        // D5 境界証明: 正常時 target >= s-1、従って [target-15, target] ⊂ [s-16, e) ⊂ allocation。
        // 不正な前方への超過は cold helper で拒否し、確保外の load は実行しない。
        if target < lowerPointer { try Self.underflow() }
        // shift = consumed & ~7 は 0...56。下位 word の上位 56 bit は 56 - shift = ~consumed & 56 だけ右にずらして繋ぐ。
        // shift == 0 のとき nextBytes >> 56 == 0 で container は変わらない。
        let shift = consumed & ~7
        container = (container &<< shift) | (nextBytes &>> (~consumed & 56))
        consumed &= 7
        pointer = target
        nextBytes = UInt64(littleEndian: target.loadUnaligned(fromByteOffset: -15, as: UInt64.self)) &>> 8
    }

    @inline(__always)
    mutating func read(_ count: Int) -> Int {
        // 呼出幅 0...31、refill schedule により consumed + count <= 63。残量は終端で厳密検査する。
        let value = ((container &<< consumed) &>> 1) &>> (63 &- count)
        consumed &+= count
        return Int(truncatingIfNeeded: value)
    }

    /// 連続する 2 つの field を読む。消費量は和で一度に進め、2 つ目の値は 1 つ目のシフト結果から取る。
    @inline(__always)
    mutating func readPair(_ first: Int, _ second: Int) -> (Int, Int) {
        // first + second <= 32、refill schedule により consumed + first + second <= 63。
        let window = container &<< consumed
        let a = (window &>> 1) &>> (63 &- first)
        let b = ((window &<< first) &>> 1) &>> (63 &- second)
        consumed &+= first &+ second
        return (Int(truncatingIfNeeded: a), Int(truncatingIfNeeded: b))
    }

    /// 状態遷移の 3 field を読み、値 × 16（16 byte cell の offset）で返す。mask は ZstdSequenceCell.stateMask。
    /// シフト量は消費位置から先に求まり、container からは右シフトと mask の 2 命令で値を得る。
    @inline(__always)
    mutating func readScaledStates(_ first: Int, _ firstMask: Int, _ second: Int, _ secondMask: Int,
                                   _ third: Int, _ thirdMask: Int) -> (Int, Int, Int) {
        // 各幅 0...9、合計 <= 26。refill 直後なので position3 <= 33 で、各シフト量 60 - position は 27 以上。
        let position1 = consumed &+ first
        let position2 = position1 &+ second
        let position3 = position2 &+ third
        let a = Int(truncatingIfNeeded: container &>> (60 &- position1)) & firstMask
        let b = Int(truncatingIfNeeded: container &>> (60 &- position2)) & secondMask
        let c = Int(truncatingIfNeeded: container &>> (60 &- position3)) & thirdMask
        consumed = position3
        return (a, b, c)
    }

    @inline(never)
    private static func underflow() throws -> Never {
        throw KaitoError.malformed("zstd bitstream underflow")
    }
}

// ブロック内の前向き view。部分領域を独立した上限付き reader にできる。
struct ZstdByteReader {
    // frame 所有の scratch を借用する。寿命は所有側（D7）が保証する。
    let bytes: UnsafeRawBufferPointer
    private(set) var position: Int
    let end: Int

    init(_ bytes: UnsafeRawBufferPointer) {
        self.bytes = bytes
        position = 0
        end = bytes.count
    }

    private init(bytes: UnsafeRawBufferPointer, range: Range<Int>) {
        self.bytes = bytes
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
        Self(bytes: bytes, range: try take(count))
    }
}

// FSE 分布だけは最下位ビットから前向きに読む。各読取りで境界を確認する。
struct ZstdForwardBits {
    let bytes: UnsafeRawBufferPointer
    let end: Int
    var position: Int

    init(_ reader: ZstdByteReader) {
        bytes = reader.bytes
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
