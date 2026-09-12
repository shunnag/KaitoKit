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
    private let capacity = 16_384

    init(source: any ByteSource, offset: UInt64, size: UInt64) throws {
        end = try Checked.add(offset, size)
        guard end <= source.length else { throw KaitoError.truncated }
        self.source = source; position = offset
        storage = .allocate(capacity: capacity)
    }
    deinit { storage.deallocate() }
    var isAtEnd: Bool { cursor == available && position == end }

    // tree / block の境界では、既に読んだ octet の残りだけを捨てる。
    func alignToByte() { reservoir = 0; bitCount = 0 }

    @inline(__always) func byte() throws -> UInt8 {
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
        while bitCount < count {
            let next = UInt64(try byte())
            if lsb { reservoir |= next << bitCount } else { reservoir = (reservoir << 8) | next }
            bitCount += 8
        }
        let mask = (UInt64(1) << count) - 1
        bitCount -= count
        if lsb {
            let result = reservoir & mask
            reservoir >>= count
            return Int(result)
        }
        let result = (reservoir >> bitCount) & mask
        reservoir &= (UInt64(1) << bitCount) - 1
        return Int(result)
    }
}
