// Clean-room format inputs: 指定レポート Ch.04 の Arsenic arithmetic と model 表に基づく。
// XADMaster / The Unarchiver / stuffit-go 等の実装ソースは参照していない。
import Foundation

final class StuffItArsenicArithmetic {
    private struct Model {
        let offset: Int
        let count: Int
        let first: Int
        let increment: UInt64
        let limit: UInt64
        var total: UInt64
    }
    private let input: StuffItPackedInput
    private var range: UInt64 = 1 << 25
    private var code: UInt64
    private let frequencies: UnsafeMutablePointer<UInt64>
    private let models: UnsafeMutablePointer<Model>

    init(input: StuffItPackedInput) throws {
        self.input = input
        code = UInt64(try input.bits(26, lsb: false))
        frequencies = .allocate(capacity: 267)
        models = .allocate(capacity: 9)
        models.initialize(to: Model(offset: 0, count: 2, first: 0, increment: 1, limit: 256, total: 2))
        (models + 1).initialize(to: Model(offset: 2, count: 11, first: 0, increment: 8, limit: 1024, total: 88))
        var offset = 13
        for group in 3...9 {
            let count = 1 << (group - 2)
            let increment: UInt64 = group == 3 ? 8 : group <= 6 ? 4 : group <= 8 ? 2 : 1
            (models + group - 1).initialize(to: Model(offset: offset, count: count, first: count,
                                                     increment: increment, limit: 1024, total: UInt64(count) * increment))
            offset += count
        }
        for index in 0..<9 {
            let m = models[index]
            (frequencies + m.offset).initialize(repeating: m.increment, count: m.count)
        }
    }
    deinit { frequencies.deallocate(); models.deallocate() }
    func resetBlockModels() {
        for index in 1..<9 {
            var m = models[index]
            (frequencies + m.offset).update(repeating: m.increment, count: m.count)
            m.total = UInt64(m.count) * m.increment; models[index] = m
        }
    }
    // index は固定 control/selector または検証済み selector 3...9 から求める。
    @inline(__always) func symbol(_ index: Int) throws -> Int {
        var model = models[index]
        let table = frequencies + model.offset
        let q = range / model.total
        let selection = code / q
        var low: UInt64 = 0, symbol = 0
        while symbol < model.count - 1 && selection >= low + table[symbol] {
            low += table[symbol]; symbol += 1
        }
        let removed = q * low
        code -= removed
        range = symbol == model.count - 1 ? range - removed : q * table[symbol]
        while range <= 1 << 24 {
            range <<= 1
            guard code <= UInt64.max >> 1 else { throw KaitoError.malformed("StuffIt Arsenic arithmetic overflow") }
            code = (code << 1) | UInt64(try input.bits(1, lsb: false))
        }
        table[symbol] += model.increment; model.total += model.increment
        if model.total > model.limit {
            model.total = 0
            for i in 0..<model.count { table[i] = (table[i] + 1) >> 1; model.total += table[i] }
        }
        models[index] = model
        return symbol + model.first
    }
    func integer(_ bits: Int) throws -> Int {
        var value = 0
        for bit in 0..<bits { value |= (try symbol(0)) << bit }
        return value
    }
}
