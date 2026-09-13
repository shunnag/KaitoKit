// Clean-room format inputs: 指定レポート Ch.04 の共通 bit 規則と Ch.06 の transport 規則に基づく。
// XADMaster / The Unarchiver / stuffit-go 等の実装ソースは参照していない。
import Foundation

final class StuffItPackedInput {
    private let source: any ByteSource
    private let end: UInt64
    private var position: UInt64
    private let storage: UnsafeMutablePointer<UInt8>
    private var cursor = 0
    private var available = 0
    private var reservoir: UInt64 = 0
    private var bitCount = 0
    private var lowBitFirst = true
    private var deferredError: (any Error)?
    private let capacity = 16_384

    init(source: any ByteSource, offset: UInt64, size: UInt64) throws {
        end = try Checked.add(offset, size)
        guard end <= source.length else { throw KaitoError.truncated }
        self.source = source; position = offset
        storage = .allocate(capacity: capacity)
    }
    deinit { storage.deallocate() }
    var isAtEnd: Bool { bitCount < 8 && cursor == available && position == end }

    // tree / block の境界では、既に読んだ octet の残りだけを捨てる。
    func alignToByte() { _ = consume(bitCount & 7) }

    @inline(__always) func byte() throws -> UInt8 {
        // 先読みした完全な octet を先に返し、従来 byte() が触れなかった端数 bit は残す。
        if bitCount >= 8 {
            let partial = bitCount & 7
            let result: UInt8
            if lowBitFirst {
                result = UInt8((reservoir >> partial) & 255)
                reservoir = ((reservoir >> (partial + 8)) << partial) | (reservoir & ((1 << partial) - 1))
            } else {
                let tail = bitCount - partial - 8
                result = UInt8((reservoir >> tail) & 255)
                reservoir = ((reservoir >> (tail + 8)) << tail) | (reservoir & ((1 << tail) - 1))
            }
            bitCount -= 8
            return result
        }
        if let deferredError { throw deferredError }
        if cursor == available { try refill() }
        let result = storage[cursor]
        cursor += 1
        return result
    }
    private func refill() throws {
        guard position < end else { throw KaitoError.truncated }
        let requested = Int(min(UInt64(capacity), end - position))
        let count = try source.read(into: UnsafeMutableRawBufferPointer(start: storage, count: requested), at: position)
        guard count > 0, count <= requested else { throw KaitoError.truncated }
        position += UInt64(count); cursor = 0; available = count
    }
    @inline(__always) func bits(_ count: Int, lsb: Bool) throws -> Int {
        if count == 0 { return 0 }
        if lowBitFirst != lsb { changeOrder(lsb) }
        // 表引きをしない算術復号では、既存の残量だけで足りるときに補充判定を増やさない。
        if bitCount < count {
            fill(minimum: count)
            guard bitCount >= count else { throw exhaustionError }
        }
        bitCount -= count
        let mask = (UInt64(1) << count) - 1
        if lsb {
            let result = reservoir & mask
            reservoir >>= count
            return Int(result)
        }
        let result = (reservoir >> bitCount) & mask
        reservoir &= (UInt64(1) << bitCount) - 1
        return Int(result)
    }

    // 一次表を読む前に 32 bit 以上を補充する。末尾のゼロ詰めは実在 bit 数に含めない。
    @inline(__always) func peek(_ count: Int, lsb: Bool) -> Int {
        if lowBitFirst != lsb { changeOrder(lsb) }
        if bitCount < max(32, count) { fill(minimum: max(32, count)) }
        let mask = (UInt64(1) << count) - 1
        if lsb { return Int(reservoir & mask) }
        if bitCount >= count { return Int((reservoir >> (bitCount - count)) & mask) }
        return Int((reservoir << (count - bitCount)) & mask)
    }

    // エラーを確定するのは実消費時だけ。呼出側の throwing 境界で元のエラーを返す。
    @inline(__always) func consume(_ count: Int) -> Bool {
        guard count <= bitCount else { return false }
        bitCount -= count
        if lowBitFirst { reservoir >>= count }
        else { reservoir &= (UInt64(1) << bitCount) - 1 }
        return true
    }
    var exhaustionError: any Error { deferredError ?? KaitoError.truncated }

    @inline(__always) private func fill(minimum: Int) {
        if available - cursor >= 4, bitCount <= 31 {
            let word = UnsafeRawPointer(storage + cursor).loadUnaligned(as: UInt32.self)
            if lowBitFirst { reservoir |= UInt64(UInt32(littleEndian: word)) << bitCount }
            else { reservoir = (reservoir << 32) | UInt64(UInt32(bigEndian: word)) }
            cursor += 4; bitCount += 32
            if bitCount >= minimum { return }
        }
        fillTail(minimum: minimum)
    }
    private func fillTail(minimum: Int) {
        while bitCount < minimum {
            if cursor == available {
                if deferredError != nil || position == end { return }
                do { try refill() } catch { deferredError = error; return }
            }
            let byte = UInt64(storage[cursor]); cursor += 1
            if lowBitFirst { reservoir |= byte << bitCount }
            else { reservoir = (reservoir << 8) | byte }
            bitCount += 8
        }
    }
    private func changeOrder(_ lsb: Bool) {
        // 端数の値は従来どおり保ち、未消費の完全な octet だけを新しい順に並べ直す。
        let partial = bitCount & 7, whole = bitCount - partial
        let mask = (UInt64(1) << partial) - 1
        var result = lowBitFirst ? reservoir & mask : reservoir >> whole
        for offset in stride(from: 0, to: whole, by: 8) {
            let byte = (reservoir >> (lowBitFirst ? partial + offset : whole - offset - 8)) & 255
            if lsb { result |= byte << (partial + offset) }
            else { result = (result << 8) | byte }
        }
        reservoir = result; lowBitFirst = lsb
    }
}
