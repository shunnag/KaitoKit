import Foundation

// Dmitry Shkarin の公開ドメイン原典 SubAlloc.hpp（var.I rev.1）の移植。
// 参照はすべて Base からの offset。先頭の予約領域で null と HeapStart を区別する。
final class PPMdVarISuballocator {
    typealias Offset = UInt32
    static let unitSize = 12
    static let heapStart: Offset = 12
    static let indexToUnits: [Int] = {
        var result = [Int]()
        var units = 0
        for i in 0..<38 {
            units += i >= 12 ? 4 : (i >> 2) + 1
            result.append(units)
        }
        return result
    }()
    static let unitsToIndex: [Int] = (1...128).map { units in
        indexToUnits.firstIndex { $0 >= units }!
    }

    private struct List {
        var stamp: UInt32 = 0
        var next: Offset = 0
    }
    private var lists = [List](repeating: List(), count: 38)
    private var storage: UnsafeMutableRawPointer?
    let size: Int
    var end: Int { Int(Self.heapStart) + size }
    private(set) var text: Offset = 12
    private(set) var unitsStart: Offset = 0
    private var lowUnit: Offset = 0
    private var highUnit: Offset = 0
    var glueCount: UInt32 = 0
    var secondListStamp: UInt32 { lists[1].stamp }
    var isReleased: Bool { storage == nil }

    init(memorySize: UInt64) throws {
        guard (1 << 20...256 << 20).contains(memorySize) else {
            throw KaitoError.malformed("invalid PPMd var.I arena size")
        }
        size = try Checked.toInt(memorySize)
        guard let pointer = calloc(size + Int(Self.heapStart), 1) else {
            throw KaitoError.limitExceeded("unable to allocate PPMd var.I arena")
        }
        storage = pointer
        initialize()
    }

    deinit { free(storage) }

    func release() {
        free(storage)
        storage = nil
    }

    func initialize() {
        lists = [List](repeating: List(), count: 38)
        text = Self.heapStart
        highUnit = Offset(end)
        unitsStart = highUnit - Offset(12 * (size / 8 / 12 * 7))
        lowUnit = unitsStart
        glueCount = 0
    }

    func usedMemory() throws -> Int {
        var result = size - (Int(highUnit) - Int(lowUnit)) - (Int(unitsStart) - Int(text))
        for i in lists.indices {
            result -= 12 * Self.indexToUnits[i] * Int(lists[i].stamp)
        }
        guard (0...size).contains(result) else {
            throw KaitoError.malformed("invalid PPMd var.I memory accounting")
        }
        return result
    }

    func allocateUnits(_ units: Int) throws -> Offset {
        let i = try index(units)
        if lists[i].next != 0 { return try remove(i) }
        let bytes = Offset(12 * Self.indexToUnits[i])
        if highUnit >= lowUnit, highUnit - lowUnit >= bytes {
            let result = lowUnit
            lowUnit += bytes
            try requireUnit(result, count: Int(bytes))
            return result
        }
        return try allocateUnitsRare(i)
    }

    func allocateContext() throws -> Offset {
        guard highUnit >= lowUnit else { throw invalid() }
        if highUnit != lowUnit {
            guard highUnit - lowUnit >= 12 else { throw invalid() }
            highUnit -= 12
            try requireUnit(highUnit)
            return highUnit
        }
        if lists[0].next != 0 { return try remove(0) }
        return try allocateUnitsRare(0)
    }

    func expandUnits(_ old: Offset, _ oldUnits: Int) throws -> Offset {
        let i0 = try index(oldUnits), i1 = try index(oldUnits + 1)
        try requireUnit(old, count: 12 * Self.indexToUnits[i0])
        if i0 == i1 { return old }
        let result = try allocateUnits(oldUnits + 1)
        if result != 0 {
            try copy(from: old, to: result, count: oldUnits * 12)
            try insert(old, i0, units: oldUnits)
        }
        return result
    }

    func shrinkUnits(_ old: Offset, _ oldUnits: Int, _ newUnits: Int) throws -> Offset {
        guard newUnits <= oldUnits else { throw invalid() }
        let i0 = try index(oldUnits), i1 = try index(newUnits)
        try requireUnit(old, count: 12 * Self.indexToUnits[i0])
        if i0 == i1 { return old }
        if lists[i1].next != 0 {
            let result = try remove(i1)
            try copy(from: old, to: result, count: 12 * newUnits)
            try insert(old, i0, units: Self.indexToUnits[i0])
            return result
        }
        try split(old, i0, i1)
        return old
    }

    func freeUnits(_ offset: Offset, _ units: Int) throws {
        let i = try index(units)
        try insert(offset, i, units: Self.indexToUnits[i])
    }

    func specialFreeUnit(_ offset: Offset) throws {
        if offset != unitsStart {
            try insert(offset, 0, units: 1)
        } else {
            try put32(UInt32.max, offset)
            unitsStart = try advance(unitsStart, 12)
        }
    }

    func moveUnitsUp(_ old: Offset, _ units: Int) throws -> Offset {
        let i = try index(units)
        if Int(old) > Int(unitsStart) + 16 * 1024 || old > lists[i].next { return old }
        let result = try remove(i)
        try copy(from: old, to: result, count: units * 12)
        let actual = Self.indexToUnits[i]
        if old != unitsStart { try insert(old, i, units: actual) }
        else { unitsStart = try advance(unitsStart, actual * 12) }
        return result
    }

    func expandTextArea() throws {
        var counts = [Int](repeating: 0, count: 38)
        var budget = size / 12 * 2
        while Int(unitsStart) <= end - 12, try get32(unitsStart) == UInt32.max {
            try consume(&budget)
            let node = unitsStart
            let units = Int(try get32(advance(node, 8)))
            let i = try index(units)
            unitsStart = try advance(node, units * 12)
            counts[i] += 1
            try put32(0, node)
        }
        for i in lists.indices where counts[i] != 0 {
            var previous: Offset = 0
            var node = lists[i].next
            while counts[i] != 0 {
                try consume(&budget)
                guard node != 0 else { throw invalid() }
                let next = try get32(advance(node, 4))
                if try get32(node) == 0 {
                    if previous == 0 { lists[i].next = next }
                    else { try put32(next, advance(previous, 4)) }
                    guard lists[i].stamp > 0 else { throw invalid() }
                    lists[i].stamp -= 1
                    counts[i] -= 1
                } else { previous = node }
                node = next
            }
        }
    }

    // 原典の書き込み後の衝突判定を呼出元で行う。
    func appendText(_ symbol: UInt8) throws -> Offset {
        guard text < unitsStart else { throw invalid() }
        try put8(symbol, text)
        text = try advance(text, 1)
        return text
    }

    func resetText(plusOne: Bool = false) { text = Self.heapStart + (plusOne ? 1 : 0) }
    func retractText() throws {
        guard text > Self.heapStart else { throw invalid() }
        text -= 1
    }

    private func allocateUnitsRare(_ i: Int) throws -> Offset {
        if glueCount == 0 {
            try glueFreeBlocks()
            if lists[i].next != 0 { return try remove(i) }
        }
        for j in (i + 1)..<38 where lists[j].next != 0 {
            let result = try remove(j)
            try split(result, j, i)
            return result
        }
        glueCount &-= 1
        let bytes = Offset(12 * Self.indexToUnits[i])
        guard unitsStart >= text else { throw invalid() }
        guard unitsStart - text > bytes else { return 0 }
        unitsStart -= bytes
        try requireUnit(unitsStart, count: Int(bytes))
        return unitsStart
    }

    private func split(_ block: Offset, _ oldIndex: Int, _ newIndex: Int) throws {
        guard oldIndex > newIndex else { throw invalid() }
        var difference = Self.indexToUnits[oldIndex] - Self.indexToUnits[newIndex]
        var p = try advance(block, 12 * Self.indexToUnits[newIndex])
        var i = try index(difference)
        if Self.indexToUnits[i] != difference {
            i -= 1
            let k = Self.indexToUnits[i]
            try insert(p, i, units: k)
            p = try advance(p, 12 * k)
            difference -= k
        }
        try insert(p, index(difference), units: difference)
    }

    private func glueFreeBlocks() throws {
        if lowUnit != highUnit { try put8(0, lowUnit) }
        var head: Offset = 0, tail: Offset = 0
        var budget = size / 12 * 3
        for i in lists.indices {
            while lists[i].next != 0 {
                try consume(&budget)
                let p = try remove(i)
                var units = Int(try get32(advance(p, 8)))
                if units == 0 { continue }
                while true {
                    let adjacent = try advance(p, units * 12)
                    if Int(adjacent) > end - 12 { break }
                    if try get32(adjacent) != UInt32.max { break }
                    try consume(&budget)
                    let extra = Int(try get32(advance(adjacent, 8)))
                    guard extra > 0, extra <= size / 12 - units else { throw invalid() }
                    units += extra
                    try put32(UInt32(units), advance(p, 8))
                    try put32(0, advance(adjacent, 8))
                }
                try put32(0, advance(p, 4))
                if tail == 0 { head = p }
                else { try put32(p, advance(tail, 4)) }
                tail = p
            }
        }
        while head != 0 {
            try consume(&budget)
            var p = head
            head = try get32(advance(p, 4))
            var units = Int(try get32(advance(p, 8)))
            if units == 0 { continue }
            while units > 128 {
                try insert(p, 37, units: 128)
                units -= 128
                p = try advance(p, 12 * 128)
            }
            var i = try index(units)
            if Self.indexToUnits[i] != units {
                i -= 1
                let k = units - Self.indexToUnits[i]
                try insert(advance(p, 12 * (units - k)), k - 1, units: k)
            }
            try insert(p, i, units: Self.indexToUnits[i])
        }
        glueCount = 1 << 13
    }

    private func insert(_ p: Offset, _ i: Int, units: Int) throws {
        guard lists.indices.contains(i), units > 0, units <= 128 else { throw invalid() }
        try requireUnit(p, count: units * 12)
        try put32(lists[i].next, advance(p, 4))
        try put32(UInt32.max, p)
        try put32(UInt32(units), advance(p, 8))
        lists[i].next = p
        lists[i].stamp &+= 1
    }

    private func remove(_ i: Int) throws -> Offset {
        let p = lists[i].next
        guard p != 0, lists[i].stamp > 0 else { throw invalid() }
        try requireUnit(p)
        lists[i].next = try get32(advance(p, 4))
        lists[i].stamp -= 1
        return p
    }

    private func index(_ units: Int) throws -> Int {
        guard (1...128).contains(units) else { throw invalid() }
        return Self.unitsToIndex[units - 1]
    }

    private func consume(_ budget: inout Int) throws {
        guard budget > 0 else { throw KaitoError.malformed("cyclic PPMd var.I free list") }
        budget -= 1
    }

    // 生ポインタ操作が使う連続領域を検証し、解放済みの領域も拒否する。
    @inline(__always)
    func checkedInt(_ offset: Offset, count: Int) throws -> Int {
        let value = Int(offset)
        guard storage != nil, value >= Int(Self.heapStart), value <= end,
              count >= 0, count <= end - value else { throw invalid() }
        return value
    }

    @inline(__always)
    func advance(_ offset: Offset, _ count: Int) throws -> Offset {
        let (value, overflow) = Int(offset).addingReportingOverflow(count)
        guard !overflow, value >= Int(Self.heapStart), value <= end else { throw invalid() }
        return Offset(value)
    }

    @inline(__always)
    func requireUnit(_ offset: Offset, count: Int = 12) throws {
        _ = try checkedInt(offset, count: count)
        guard offset >= unitsStart, (end - Int(offset)).isMultiple(of: 12) else { throw invalid() }
    }

    @inline(__always)
    func get8(_ p: Offset) throws -> UInt8 {
        let i = try checkedInt(p, count: 1)
        return storage!.load(fromByteOffset: i, as: UInt8.self)
    }
    @inline(__always)
    func put8(_ value: UInt8, _ p: Offset) throws {
        let i = try checkedInt(p, count: 1)
        storage!.storeBytes(of: value, toByteOffset: i, as: UInt8.self)
    }
    @inline(__always)
    func get16(_ p: Offset) throws -> UInt16 {
        let i = try checkedInt(p, count: 2)
        return UInt16(littleEndian: storage!.loadUnaligned(fromByteOffset: i, as: UInt16.self))
    }
    @inline(__always)
    func put16(_ value: UInt16, _ p: Offset) throws {
        let i = try checkedInt(p, count: 2)
        var little = value.littleEndian
        memcpy(storage!.advanced(by: i), &little, 2)
    }
    @inline(__always)
    func get32(_ p: Offset) throws -> UInt32 {
        let i = try checkedInt(p, count: 4)
        return UInt32(littleEndian: storage!.loadUnaligned(fromByteOffset: i, as: UInt32.self))
    }
    @inline(__always)
    func put32(_ value: UInt32, _ p: Offset) throws {
        let i = try checkedInt(p, count: 4)
        var little = value.littleEndian
        memcpy(storage!.advanced(by: i), &little, 4)
    }
    // 復号の頻出経路専用。呼出元が checkedInt または requireUnit で全範囲を検証し、
    // その検査から読書きまでの間に領域を解放しないこと。
    @inline(__always)
    internal func uncheckedGet8(_ i: Int) -> UInt8 {
        storage!.load(fromByteOffset: i, as: UInt8.self)
    }
    @inline(__always)
    internal func uncheckedPut8(_ value: UInt8, _ i: Int) {
        storage!.storeBytes(of: value, toByteOffset: i, as: UInt8.self)
    }
    @inline(__always)
    internal func uncheckedGet32(_ i: Int) -> UInt32 {
        UInt32(littleEndian: storage!.loadUnaligned(fromByteOffset: i, as: UInt32.self))
    }
    @inline(__always)
    internal func uncheckedPut32(_ value: UInt32, _ i: Int) {
        var little = value.littleEndian
        memcpy(storage!.advanced(by: i), &little, 4)
    }
    func copy(from source: Offset, to destination: Offset, count: Int) throws {
        let s = try checkedInt(source, count: count), d = try checkedInt(destination, count: count)
        memmove(storage!.advanced(by: d), storage!.advanced(by: s), count)
    }
    private func invalid() -> KaitoError { .malformed("invalid PPMd var.I arena reference") }
}
