// 指定資料 Ch.09 §7。配置と空きリストの順序も復号結果の一部になる。
import Foundation

final class StuffItXBrimstoneAllocator {
    let bytes: UnsafeMutablePointer<UInt8>
    let capacity: Int
    private let classes: UnsafeMutablePointer<Int>
    private let indices: UnsafeMutablePointer<Int>
    private let heads: UnsafeMutablePointer<Int>
    private(set) var low = 12
    private(set) var high: Int

    init(exponent: Int, limits: ReadLimits) throws {
        guard (0..<31).contains(exponent) else { throw KaitoError.malformed("StuffIt X Brimstone memory exponent") }
        let budget = 1 << exponent
        try Checked.size(UInt64(budget), limit: limits.maxDictionarySize)
        capacity = budget / 12 * 12 + 12; high = capacity
        bytes = .allocate(capacity: capacity); bytes.initialize(repeating: 0, count: capacity)
        classes = .allocate(capacity: 38); indices = .allocate(capacity: 129); heads = .allocate(capacity: 38)
        heads.initialize(repeating: 0, count: 38)
        let sizes = [1,2,3,4,6,8,10,12,15,18,21,24,28,32,36,40,44,48,52,56,60,64,68,72,76,80,84,88,92,96,100,104,108,112,116,120,124,128]
        for i in 0..<38 { classes[i] = sizes[i] }
        var index = 0
        for n in 0...128 {
            while classes[index] < n { index += 1 }
            indices[n] = index
        }
    }
    deinit { bytes.deallocate(); classes.deallocate(); indices.deallocate(); heads.deallocate() }
    func reset() { low = 12; high = capacity; heads.update(repeating: 0, count: 38) }
    @inline(__always) func word(_ offset: Int) -> Int {
        Int(UInt32(littleEndian: UnsafeRawPointer(bytes + offset).loadUnaligned(as: UInt32.self)))
    }
    @inline(__always) func setWord(_ offset: Int, _ value: Int) {
        UnsafeMutableRawPointer(bytes + offset).storeBytes(of: UInt32(value).littleEndian, as: UInt32.self)
    }
    @inline(__always) private func pop(_ index: Int) -> Int {
        let block = heads[index]; heads[index] = word(block); return block
    }
    @inline(__always) private func push(_ block: Int, _ index: Int) {
        setWord(block, heads[index]); heads[index] = block
    }
    private func split(_ block: Int, units: Int) {
        guard units > 0 else { return }
        var index = indices[units]
        if classes[index] != units { index -= 1 }
        push(block, index)
        let rest = units - classes[index]
        if rest > 0 { push(block + classes[index] * 12, indices[rest]) }
    }
    func context() -> Int? {
        if high > low { high -= 12; return high }
        return allocate(units: 1)
    }
    func allocate(units: Int) -> Int? {
        let index = indices[units], count = classes[index]
        if heads[index] != 0 { return pop(index) }
        if high - low >= count * 12 { let block = low; low += count * 12; return block }
        for larger in (index + 1)..<38 where heads[larger] != 0 {
            let block = pop(larger)
            split(block + count * 12, units: classes[larger] - count)
            return block
        }
        return nil
    }
    func free(_ block: Int, units: Int) { push(block, indices[units]) }
    func grow(_ block: Int, units: Int) -> Int? {
        if indices[units] == indices[units + 1] { return block }
        guard let replacement = allocate(units: units + 1) else { return nil }
        (bytes + replacement).update(from: bytes + block, count: units * 12)
        free(block, units: units); return replacement
    }
    func shrink(_ block: Int, from old: Int, to new: Int) -> Int {
        let a = indices[old], b = indices[new]
        if a == b { return block }
        if heads[b] != 0 {
            let replacement = pop(b)
            (bytes + replacement).update(from: bytes + block, count: new * 12)
            free(block, units: old); return replacement
        }
        split(block + classes[b] * 12, units: classes[a] - classes[b]); return block
    }
}
