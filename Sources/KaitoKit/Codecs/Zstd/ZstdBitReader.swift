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

// ブロック内の前向き読み取り。部分領域を独立した上限付き reader にできる。
struct ZstdByteReader {
    let bytes: [UInt8]
    private(set) var position: Int
    let end: Int

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        position = 0
        end = bytes.count
    }

    private init(bytes: [UInt8], range: Range<Int>) {
        self.bytes = bytes
        position = range.lowerBound
        end = range.upperBound
    }

    var remaining: Int { end - position }

    mutating func byte() throws -> Int { Int(try integer(1)) }

    mutating func integer(_ count: Int) throws -> UInt64 {
        guard (0...8).contains(count), count <= remaining else { throw KaitoError.truncated }
        var value: UInt64 = 0
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
    let bytes: [UInt8]
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
            result |= ((Int(bytes[position >> 3]) >> shift) & ((1 << width) - 1)) << written
            position += width
            written += width
        }
        return result
    }
}

// ByteSource の指定範囲だけを読む。skip は圧縮データや metadata を確保しない。
final class ZstdInput {
    private let source: any ByteSource
    let end: UInt64
    private(set) var position: UInt64
    private var buffer: [UInt8] = []
    private var bufferOffset = 0

    init(source: any ByteSource, offset: UInt64, size: UInt64) throws {
        end = try Checked.add(offset, size)
        guard end <= source.length else { throw KaitoError.truncated }
        self.source = source
        position = offset
    }

    var remaining: UInt64 { end - position }

    func byte() throws -> UInt8 {
        if bufferOffset == buffer.count {
            guard position < end else { throw KaitoError.truncated }
            let count = Int(min(4 * 1_024, remaining))
            buffer = try readByteRange(source: source, offset: position, count: count)
            bufferOffset = 0
        }
        let value = buffer[bufferOffset]
        bufferOffset += 1
        position += 1
        return value
    }

    func integer(_ count: Int) throws -> UInt64 {
        var result: UInt64 = 0
        for index in 0..<count { result |= UInt64(try byte()) << (index * 8) }
        return result
    }

    func read(_ count: Int) throws -> [UInt8] {
        guard count >= 0, UInt64(count) <= remaining else { throw KaitoError.truncated }
        var result: [UInt8] = []
        result.reserveCapacity(count)
        while result.count < count {
            if bufferOffset == buffer.count {
                let amount = count - result.count
                if amount >= 4 * 1_024 {
                    // 本文の大きな残り要求は先読みを挟まず、一括して取得する。
                    result.append(contentsOf: try readByteRange(source: source, offset: position, count: amount))
                    position += UInt64(amount)
                } else {
                    result.append(try byte())
                }
            } else {
                let amount = min(count - result.count, buffer.count - bufferOffset)
                result.append(contentsOf: buffer[bufferOffset..<(bufferOffset + amount)])
                bufferOffset += amount
                position += UInt64(amount)
            }
        }
        return result
    }

    func skip(_ count: UInt64) throws {
        guard count <= remaining else { throw KaitoError.truncated }
        if count <= UInt64(buffer.count - bufferOffset) {
            bufferOffset += Int(count)
        } else {
            buffer.removeAll(keepingCapacity: true)
            bufferOffset = 0
        }
        position += count
    }
}
