// 指定資料 Ch.03 の packed field と P2 に基づく。
import Foundation

final class StuffItXBitReader {
    let source: any ByteSource
    private let storage: UnsafeMutablePointer<UInt8>
    private var fetched: UInt64
    private var cursor = 0
    private var available = 0
    private var reservoir: UInt64 = 0
    private(set) var bitCount = 0

    init(source: any ByteSource, offset: UInt64 = 0) throws {
        guard offset <= source.length else { throw KaitoError.truncated }
        self.source = source; fetched = offset; storage = .allocate(capacity: 16_384)
    }
    deinit { storage.deallocate() }
    var offset: UInt64 { fetched - UInt64(bitCount / 8) }
    var isAtEnd: Bool { offset == source.length }

    func seek(to offset: UInt64) throws {
        guard offset <= source.length else { throw KaitoError.truncated }
        fetched = offset; cursor = 0; available = 0; reservoir = 0; bitCount = 0
    }
    @inline(__always) private func rawByte() throws -> UInt8 {
        if cursor == available {
            guard fetched < source.length else { throw KaitoError.truncated }
            let n = Int(min(16_384, source.length - fetched))
            available = try source.read(into: UnsafeMutableRawBufferPointer(start: storage, count: n), at: fetched)
            guard available > 0, available <= n else { throw KaitoError.truncated }
            cursor = 0
        }
        let value = storage[cursor]; cursor += 1; fetched += 1
        return value
    }
    @inline(__always) func bits(_ count: Int) throws -> UInt64 {
        precondition((0...32).contains(count))
        while bitCount < count {
            reservoir |= UInt64(try rawByte()) << bitCount; bitCount += 8
        }
        let value = reservoir & ((UInt64(1) << count) - 1)
        reservoir >>= count; bitCount -= count
        return value
    }
    @inline(__always) func byte() throws -> UInt8 {
        if bitCount == 0 { return try rawByte() }
        return UInt8(try bits(8))
    }
    // 最終 octet の未使用 bit だけを捨て、先読み済みの完全な octet は残す。
    func align() {
        let discarded = bitCount % 8
        reservoir >>= discarded; bitCount -= discarded
    }
    func p2() throws -> UInt64 {
        var population = 1
        while try bits(1) != 0 {
            population += 1
            guard population <= 64 else { throw KaitoError.malformed("StuffIt X P2 population") }
        }
        var value: UInt64 = 0
        for shift in 0..<64 {
            if try bits(1) != 0 {
                value |= UInt64(1) << shift; population -= 1
                if population == 0 { return value - 1 }
            }
        }
        throw KaitoError.malformed("StuffIt X P2 width")
    }
    func packedBE(_ octets: Int) throws -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<octets { value = (value << 8) | UInt64(try byte()) }
        return value
    }
    func string(limit: UInt64) throws -> [UInt8] {
        let count = try Checked.toInt(Checked.size(p2(), limit: limit))
        align()
        let bytes = try readByteRange(source: source, offset: offset, count: count)
        try seek(to: Checked.add(offset, UInt64(count)))
        return bytes
    }
    // Huffman 表参照用。入力末尾を仮のゼロで補い、消費時に実 bit 数を検査する。
    func peek(_ count: Int) throws -> Int {
        while bitCount < count, fetched < source.length {
            reservoir |= UInt64(try rawByte()) << bitCount; bitCount += 8
        }
        return Int(reservoir & ((UInt64(1) << count) - 1))
    }
}
