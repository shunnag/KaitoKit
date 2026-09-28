// StuffIt X JPEG の入力と算術復号: WZ 整数を読む StuffItXJPEGInput、range decoder StuffItXJPEGRange、
// header byte の適応 model StuffItXJPEGHeaderModel。
// 出典: stuffitx_jpeg.py の Bytes・RangeDecoder・HeaderModel を関数単位で移植。
import Foundation

final class StuffItXJPEGInput {
    let input: StuffItXBitReader
    init(_ source: any ByteSource, limits: ReadLimits) throws {
        try Checked.size(source.length, limit: limits.maxEntrySize)
        input = try StuffItXBitReader(source: source)
    }
    var position: UInt64 { input.offset }
    var length: UInt64 { input.source.length }
    @inline(__always) func byte() throws -> Int { Int(try input.byte()) }
    func wz() throws -> UInt64 {
        var result: UInt64 = 0
        for _ in 0..<10 {
            let value = try byte()
            guard result <= UInt64.max >> 7 else { throw jpegMalformed("WZ integer overflow") }
            result = (result << 7) | UInt64(value & 127)
            if value & 128 == 0 { return result }
        }
        throw jpegMalformed("unterminated WZ integer")
    }
}

final class StuffItXJPEGRange {
    let source: StuffItXJPEGInput
    // 算術状態の排他アクセスを係数ごとの呼び出しへ持ち込まない。
    let state = JPEGStorage<UInt32>(2, 0)
    var code: UInt32 { state.p[0] }
    var range: UInt32 { state.p[1] }
    init(_ source: StuffItXJPEGInput) throws {
        self.source = source; state.p[1] = .max
        for _ in 0..<5 { state.p[0] = (state.p[0] << 8) | UInt32(try source.byte()) }
    }
    @inline(__always) func value(_ f: UnsafePointer<Int>, _ count: Int) throws -> Int {
        var total = 0
        for i in 0..<count { total += f[i] }
        guard total > 0, total <= Int(state.p[1]) else { throw jpegMalformed("invalid frequency total") }
        let unit = state.p[1] / UInt32(total), target = Int(state.p[0] / (state.p[1] / UInt32(total)))
        var cumulative = 0, symbol = 0
        while symbol < count {
            let frequency = f[symbol]
            guard frequency >= 0 else { throw jpegMalformed("negative frequency") }
            if target < cumulative + frequency { break }
            cumulative += frequency; symbol += 1
        }
        guard symbol < count else { throw jpegMalformed("arithmetic code outside distribution") }
        state.p[0] -= UInt32(cumulative) * unit; state.p[1] = UInt32(f[symbol]) * unit
        try normalize()
        return symbol
    }
    @inline(__always) func bit() throws -> Int {
        let unit = state.p[1] >> 1
        let symbol = state.p[0] < unit ? 0 : 1
        guard unit > 0, state.p[0] / unit < 2 else { throw jpegMalformed("arithmetic code outside distribution") }
        state.p[0] -= UInt32(symbol) * unit; state.p[1] = unit
        try normalize(); return symbol
    }
    @inline(__always) func bits(_ count: Int, little: Bool = false) throws -> Int {
        var value = 0
        for i in 0..<count {
            let b = try bit()
            if little { value |= b << i } else { value = value * 2 + b }
        }
        return value
    }
    @inline(__always) private func normalize() throws {
        while state.p[1] < 1 << 24 {
            state.p[0] = (state.p[0] << 8) | UInt32(try source.byte()); state.p[1] <<= 8
        }
    }
}

final class StuffItXJPEGHeaderModel {
    let zero = JPEGStorage<Int>(256, 1)
    let one = JPEGStorage<Int>(256 * 256, 0)
    let frequencies = JPEGStorage<Int>(256, 0)
    var previous = 0
    var rescales = 0
    func byte(_ decoder: StuffItXJPEGRange) throws -> Int {
        let context = one.p.advanced(by: previous * 256), f = frequencies.p
        for i in 0..<256 { f[i] = zero.p[i] + 8 * context[i] }
        let symbol = try decoder.value(f, 256)
        update(context,symbol)
        update(zero.p,symbol)
        previous = symbol; return symbol
    }
    private func update(_ row: UnsafeMutablePointer<Int>, _ symbol: Int) {
        row[symbol] += 8
        var sum = 0
        for i in 0..<256 { sum += row[i] }
        if sum > 500 {
            for i in 0..<256 { row[i] = (row[i]+1)/2 }; rescales += 1
        }
    }
}
