// 指定資料 Ch.07 §2。算術 state は全て UInt32 の巡回演算。
import Foundation

final class StuffItXRangeDecoder {
    let input: StuffItXBitReader
    private let explicitLower: Bool
    private let floor: UInt32
    private let state: UnsafeMutablePointer<UInt32>

    init(input: StuffItXBitReader, explicitLower: Bool) throws {
        self.input = input; self.explicitLower = explicitLower; floor = explicitLower ? 0x10000 : 0
        let code = UInt32(try input.packedBE(4))
        state = .allocate(capacity: 4)
        state.initialize(repeating: 0, count: 4)
        state[1] = code; state[2] = .max
    }
    deinit { state.deallocate() }
    @inline(__always) func count(total: UInt32) throws -> UInt32 {
        guard total > 0 else { throw KaitoError.malformed("StuffIt X range total") }
        let q = state[2] / total
        guard q > 0 else { throw KaitoError.malformed("StuffIt X range quotient") }
        let count = (state[1] &- state[0]) / q
        guard count < total else { throw KaitoError.malformed("StuffIt X range count") }
        state[3] = q
        return count
    }
    @inline(__always) func select(start: UInt32, frequency: UInt32) throws {
        guard frequency > 0 else { throw KaitoError.malformed("StuffIt X range frequency") }
        let delta = state[3] &* start
        if explicitLower { state[0] &+= delta } else { state[1] &-= delta }
        state[2] = state[3] &* frequency
        try normalize()
    }
    @inline(__always) private func normalize() throws {
        while true {
            let x = state[0] ^ (state[0] &+ state[2])
            if x >= 0x01000000 {
                if state[2] >= floor { return }
                state[2] = (0 &- state[0]) & (floor &- 1)
            }
            state[0] <<= 8; state[1] = (state[1] << 8) | UInt32(try input.byte()); state[2] <<= 8
        }
    }
    @inline(__always) func modeled(_ weight: UnsafeMutablePointer<UInt32>) throws -> Int {
        let t = (state[2] >> 12) * weight.pointee
        let bit: Int
        if state[1] < t {
            state[2] = t; weight.pointee += (4096 - weight.pointee) >> 5; bit = 0
        } else {
            state[1] &-= t; state[2] &-= t; weight.pointee -= weight.pointee >> 5; bit = 1
        }
        try normalize(); return bit
    }
    @inline(__always) func fair(_ width: Int) throws -> Int {
        var value = 0
        for _ in 0..<width {
            let bit = try count(total: 2); try select(start: bit, frequency: 1)
            value = (value << 1) | Int(bit)
        }
        return value
    }
    @inline(__always) func tree(_ weights: UnsafeMutablePointer<UInt32>, width: Int) throws -> Int {
        var node = 1
        for _ in 0..<width { node = (node << 1) | (try modeled(weights.advanced(by: node))) }
        return node - (1 << width)
    }
}
