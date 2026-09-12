// 指定資料 Ch.09 のみを仕様とする。context と state は arena 内の明示的な offset で参照する。
import Foundation

final class StuffItXBrimstoneModel {
    private struct State { var byte: UInt8; var frequency: Int; var successor: Int }
    private struct Estimator { var sum: UInt16; var shift: UInt8; var count: UInt8 }
    private enum ModelError: Error { case exhausted, ended }
    let arena: StuffItXBrimstoneAllocator
    private let range: StuffItXRangeDecoder
    private let order: Int
    private let binary: UnsafeMutablePointer<UInt16>
    private let estimators: UnsafeMutablePointer<Estimator>
    private let exclusions: UnsafeMutablePointer<UInt8>
    private let references: UnsafeMutablePointer<Int>
    private var generation: UInt8 = 1
    private var start = 0
    private var current = 0
    private var frontier = 0
    private var deficit = 1
    private var previousSuccess = 0
    private var initEscape = 0
    private(set) var restartCount = 0
    private(set) var rescaleCount = 0
    private(set) var promotionCount = 0
    private(set) var insertionCount = 0
    private(set) var singleConversionCount = 0
    private(set) var suffixHitCount = 0
    private(set) var fastCount = 0

    init(range: StuffItXRangeDecoder, exponent: Int, order: Int, limits: ReadLimits) throws {
        guard (1...255).contains(order) else { throw KaitoError.malformed("StuffIt X Brimstone order") }
        self.range = range; self.order = order
        arena = try StuffItXBrimstoneAllocator(exponent: exponent, limits: limits)
        binary = .allocate(capacity: 128 * 16 + 16); estimators = .allocate(capacity: 43 * 8)
        exclusions = .allocate(capacity: 256); references = .allocate(capacity: 256)
        try reset()
    }
    deinit { binary.deallocate(); estimators.deallocate(); exclusions.deallocate(); references.deallocate() }
    @inline(__always) private func small(_ p: Int) -> Int { Int(arena.bytes[p]) | Int(arena.bytes[p + 1]) << 8 }
    @inline(__always) private func setSmall(_ p: Int, _ n: Int) {
        arena.bytes[p] = UInt8(truncatingIfNeeded: n); arena.bytes[p + 1] = UInt8(truncatingIfNeeded: n >> 8)
    }
    @inline(__always) private func count(_ c: Int) -> Int { small(c) }
    @inline(__always) private func total(_ c: Int) -> Int { small(c + 2) }
    @inline(__always) private func suffix(_ c: Int) -> Int { arena.word(c + 8) }
    @inline(__always) private func states(_ c: Int) -> Int { count(c) <= 1 ? c + 2 : arena.word(c + 4) }
    @inline(__always) private func state(_ p: Int) -> State {
        State(byte: arena.bytes[p], frequency: Int(arena.bytes[p + 1]), successor: arena.word(p + 2))
    }
    @inline(__always) private func setState(_ p: Int, _ s: State) {
        arena.bytes[p] = s.byte; arena.bytes[p + 1] = UInt8(s.frequency); arena.setWord(p + 2, s.successor)
    }
    @inline(__always) private func addFrequency(_ p: Int, _ n: Int) { arena.bytes[p + 1] += UInt8(n) }
    private func newContext(_ state: State, suffix: Int, pending: Bool = false) throws -> Int {
        guard let c = arena.context() else { throw ModelError.exhausted }
        setSmall(c, pending ? 0 : 1); setState(c + 2, state); arena.setWord(c + 8, suffix); return c
    }
    private func reset() throws {
        arena.reset()
        guard let root = arena.context(), let table = arena.allocate(units: 128) else {
            throw KaitoError.malformed("StuffIt X Brimstone initial memory")
        }
        setSmall(root, 256); setSmall(root + 2, 385); arena.setWord(root + 4, table); arena.setWord(root + 8, 0)
        for byte in 0..<256 { setState(table + 6 * byte, State(byte: UInt8(byte), frequency: byte < 128 ? 2 : 1, successor: 0)) }
        var parent = root
        do {
            for level in 1...order {
                let child = try newContext(State(byte: 0, frequency: 1, successor: 0), suffix: parent, pending: level == order)
                arena.setWord(states(parent) + 2, child); parent = child
            }
        } catch { throw KaitoError.malformed("StuffIt X Brimstone initial memory") }
        frontier = parent; start = suffix(parent); current = start
        deficit = 1; previousSuccess = 0; initEscape = 0; generation = 1
        exclusions.update(repeating: 0, count: 256)
        let constants = [0x3cdd,0x1f3f,0x59bf,0x48f3,0x5ffb,0x5545,0x63d1,0x5d9d,0x64a1,0x5abc,0x6632,0x6051,0x68f6,0x549b,0x6bca,0x3ab0]
        for r in 0..<128 { for c in 0..<16 { binary[r * 16 + c] = UInt16(16384 - constants[c] / (r + 2)) } }
        let initialEscapes: [UInt16] = [25,14,9,7,5,5,4,4,4,3,3,3,2,2,2,2]
        for c in 0..<16 { binary[2048 + c] = initialEscapes[c] }
        for r in 0..<43 { for c in 0..<8 { estimators[r * 8 + c] = Estimator(sum: UInt16((4 * r + 10) * 8), shift: 3, count: 3) } }
    }
    @inline(__always) private func locate(_ byte: UInt8, in context: Int) throws -> Int {
        let table = states(context)
        for i in 0..<count(context) where arena.bytes[table + i * 6] == byte { return table + i * 6 }
        throw KaitoError.malformed("StuffIt X Brimstone missing state")
    }
    @inline(__always) private func exchange(_ a: Int, _ b: Int) { let saved = state(a); setState(a, state(b)); setState(b, saved) }
    private func rescale(_ selected: Int) throws -> Int {
        rescaleCount += 1
        let table = states(current), oldCount = count(current)
        addFrequency(selected, 4)
        var escape = total(current) + 4
        for i in 0..<oldCount { escape -= Int(arena.bytes[table + i * 6 + 1]) }
        guard escape >= 0 else { throw KaitoError.malformed("StuffIt X Brimstone rescale total") }
        let rounding = deficit == 0 ? 0 : 1
        var sum = 0
        for i in 0..<oldCount {
            var item = state(table + i * 6); item.frequency = (item.frequency + rounding) / 2; sum += item.frequency
            var j = i
            while j > 0, item.frequency > Int(arena.bytes[table + (j - 1) * 6 + 1]) {
                setState(table + j * 6, state(table + (j - 1) * 6)); j -= 1
            }
            setState(table + j * 6, item)
        }
        var n = oldCount
        while n > 1, arena.bytes[table + (n - 1) * 6 + 1] == 0 { n -= 1; escape += 1 }
        if n == 1 {
            singleConversionCount += 1
            var item = state(table)
            repeat { item.frequency = (item.frequency + 1) / 2; escape /= 2 } while escape > 1
            setSmall(current, 1); setState(current + 2, item); arena.free(table, units: (oldCount + 1) / 2)
            return current + 2
        }
        setSmall(current, n); setSmall(current + 2, sum + (escape + 1) / 2)
        let replacement = arena.shrink(table, from: (oldCount + 1) / 2, to: (n + 1) / 2)
        arena.setWord(current + 4, replacement); return replacement
    }
    private func firstDecision() throws -> Int? {
        let n = count(current), table = states(current)
        guard n > 0 else { throw KaitoError.malformed("StuffIt X Brimstone pending prediction") }
        if n == 1 {
            let f = Int(arena.bytes[table + 1]), parent = suffix(current)
            guard parent != 0, (1...128).contains(f), count(parent) > 0 else { throw KaitoError.malformed("StuffIt X Brimstone binary context") }
            let j = count(parent) - 1, column = (j < 6 ? j * 2 : (j < 50 ? 12 : 14)) + previousSuccess
            let index = (f - 1) * 16 + column, w = Int(binary[index]), delta = (w + 32) / 128
            if try range.count(total: 16384) < w {
                try range.select(start: 0, frequency: UInt32(w)); binary[index] = UInt16(w + 128 - delta)
                previousSuccess = 1; if f < 128 { addFrequency(table, 1) }; return table
            }
            try range.select(start: UInt32(w), frequency: UInt32(16384 - w))
            binary[index] = UInt16(w - delta); previousSuccess = 0
            initEscape = Int(binary[2048 + (w - delta) / 1024])
            exclusions[Int(arena.bytes[table])] = generation; return nil
        }
        let oldTotal = total(current), value = try range.count(total: UInt32(oldTotal))
        var cumulative = 0
        for i in 0..<n {
            var p = table + i * 6
            let f = Int(arena.bytes[p + 1])
            if value < cumulative + f {
                try range.select(start: UInt32(cumulative), frequency: UInt32(f))
                previousSuccess = i == 0 && f * 2 > oldTotal ? 1 : 0
                addFrequency(p, 4); setSmall(current + 2, oldTotal + 4)
                if i > 0, arena.bytes[p + 1] > arena.bytes[p - 5] { exchange(p, p - 6); p -= 6 }
                return try arena.bytes[p + 1] > 124 ? rescale(p) : p
            }
            cumulative += f
        }
        try range.select(start: UInt32(cumulative), frequency: UInt32(oldTotal - cumulative))
        previousSuccess = 0
        for i in 0..<n { exclusions[Int(arena.bytes[table + i * 6])] = generation }
        return nil
    }
    private func suffixDecision(masked: Int) throws -> Int? {
        let n = count(current), usable = n - masked, table = states(current)
        guard usable > 0 else { throw KaitoError.malformed("StuffIt X Brimstone exclusion count") }
        var estimator = -1, escape = 1
        if n != 256 {
            let parent = suffix(current)
            guard parent != 0 else { throw KaitoError.malformed("StuffIt X Brimstone estimator suffix") }
            let j = usable - 1
            let row = j < 4 ? j : (j < 12 ? 4 + (j - 4) / 2 : (j < 44 ? 8 + (j - 12) / 4 : 16 + (j - 44) / 8))
            let column = (usable < count(parent) - n ? 1 : 0) | (total(current) < 11 * n ? 2 : 0) | (masked > usable ? 4 : 0)
            estimator = row * 8 + column
            let v = estimators[estimator].sum >> estimators[estimator].shift
            estimators[estimator].sum &-= v; escape = max(1, Int(v & 1023))
        }
        var decisionTotal = escape, found = 0
        for i in 0..<n where exclusions[Int(arena.bytes[table + i * 6])] != generation {
            decisionTotal += Int(arena.bytes[table + i * 6 + 1]); found += 1
        }
        guard found == usable else { throw KaitoError.malformed("StuffIt X Brimstone exclusion nesting") }
        let value = try range.count(total: UInt32(decisionTotal))
        var cumulative = 0
        for i in 0..<n {
            let p = table + i * 6
            if exclusions[Int(arena.bytes[p])] == generation { continue }
            let f = Int(arena.bytes[p + 1])
            if value < cumulative + f {
                try range.select(start: UInt32(cumulative), frequency: UInt32(f))
                addFrequency(p, 4); setSmall(current + 2, total(current) + 4)
                let selected = try arena.bytes[p + 1] > 124 ? rescale(p) : p
                if estimator >= 0, estimators[estimator].shift < 7 {
                    estimators[estimator].count &-= 1
                    if estimators[estimator].count == 0 {
                        estimators[estimator].sum &*= 2
                        estimators[estimator].count = 3 << estimators[estimator].shift
                        estimators[estimator].shift += 1
                    }
                }
                generation &+= 1
                if generation == 0 { exclusions.update(repeating: 0, count: 256); generation = 1 }
                suffixHitCount += 1; return selected
            }
            cumulative += f
        }
        try range.select(start: UInt32(cumulative), frequency: UInt32(escape))
        if estimator >= 0 { estimators[estimator].sum &+= UInt16(truncatingIfNeeded: decisionTotal) }
        for i in 0..<n { exclusions[Int(arena.bytes[table + i * 6])] = generation }
        return nil
    }
    private func promote(_ selected: Int, skip: Int) throws {
        promotionCount += 1
        let item = state(selected), pending = item.successor
        guard pending != 0, count(pending) == 0 else { throw KaitoError.malformed("StuffIt X Brimstone promotion") }
        let next = state(pending + 2)
        var context = current, used = 0, support = 0
        for _ in 0..<skip {
            context = suffix(context)
            guard context != 0 else { throw KaitoError.malformed("StuffIt X Brimstone promotion suffix") }
        }
        while true {
            let p = try locate(item.byte, in: context), successor = arena.word(p + 2)
            if successor != pending {
                guard successor != 0, count(successor) > 0 else { throw KaitoError.malformed("StuffIt X Brimstone promotion support") }
                support = successor; break
            }
            guard used < 256 else { throw KaitoError.malformed("StuffIt X Brimstone promotion depth") }
            references[used] = p; used += 1
            let parent = suffix(context)
            if parent == 0 { support = context; break }; context = parent
        }
        let frequency: Int
        if count(support) == 1 { frequency = Int(arena.bytes[states(support) + 1]) }
        else {
            let p = try locate(next.byte, in: support), c = Int(arena.bytes[p + 1]) - 1
            let s = total(support) - count(support) - c
            guard s > 0 else { throw KaitoError.malformed("StuffIt X Brimstone promotion frequency") }
            frequency = 2 * c <= s ? (5 * c > s ? 2 : 1) : 1 + (2 * c + 3 * s - 1) / (2 * s)
        }
        guard (1...128).contains(frequency) else { throw KaitoError.malformed("StuffIt X Brimstone promotion frequency") }
        let replacement = State(byte: next.byte, frequency: frequency, successor: next.successor)
        while used > 0 {
            used -= 1; support = try newContext(replacement, suffix: support); arena.setWord(references[used] + 2, support)
        }
        if deficit == 0 { setSmall(pending, 1); setState(pending + 2, replacement); arena.setWord(pending + 8, support) }
    }
    private func incorporate(_ selected: Int) throws {
        let item = state(selected), oldSuccessor = item.successor
        if deficit == 0, oldSuccessor != 0, count(oldSuccessor) > 0 { start = oldSuccessor; fastCount += 1; return }
        let parent = suffix(current)
        if item.frequency < 31, parent != 0 {
            var p = try locate(item.byte, in: parent)
            if count(parent) == 1 { if arena.bytes[p + 1] < 32 { addFrequency(p, 1) } }
            else {
                if p != states(parent), arena.bytes[p + 1] >= arena.bytes[p - 5] { exchange(p, p - 6); p -= 6 }
                if arena.bytes[p + 1] < 108 { addFrequency(p, 2); setSmall(parent + 2, total(parent) + 2) }
            }
        }
        if deficit == 0 {
            guard oldSuccessor != 0 else { throw ModelError.ended }
            try promote(selected, skip: 2); start = oldSuccessor; return
        }
        deficit -= 1
        let next: Int, skip: Int
        if deficit == 0 {
            guard oldSuccessor != 0 else { throw ModelError.ended }
            next = oldSuccessor; skip = 1
        } else { next = try newContext(State(byte: 0, frequency: 0, successor: 0), suffix: 0, pending: true); skip = 0 }
        if count(frontier) == 0 { setState(frontier + 2, State(byte: item.byte, frequency: 0, successor: next)) }
        let n0 = count(current), s0 = total(current) - n0 - (item.frequency - 1)
        var context = start
        while context != current {
            let n = count(context)
            guard (1..<256).contains(n) else { throw KaitoError.malformed("StuffIt X Brimstone insertion context") }
            var table = states(context), t: Int
            if n > 1 {
                if n % 2 == 0 {
                    guard let replacement = arena.grow(table, units: n / 2) else { throw ModelError.exhausted }
                    table = replacement; arena.setWord(context + 4, table)
                }
                t = total(context)
                if 4 * n <= n0, t <= 8 * n { t += 2 }; if 2 * n < n0 { t += 1 }
            } else {
                var old = state(table)
                guard let replacement = arena.allocate(units: 1) else { throw ModelError.exhausted }
                table = replacement; old.frequency = old.frequency < 30 ? old.frequency * 2 : 120
                setState(table, old); arena.setWord(context + 4, table)
                t = old.frequency + initEscape + (n0 > 3 ? 1 : 0)
            }
            let a = 2 * item.frequency * (t + 6), b = s0 + t
            guard b > 0 else { throw KaitoError.malformed("StuffIt X Brimstone insertion frequency") }
            let f = a <= b ? 1 : (a < 4 * b ? 2 : (a < 6 * b ? 3 : (a < 9 * b ? 4 : (a < 12 * b ? 5 : (a < 15 * b ? 6 : 7)))))
            setState(table + n * 6, State(byte: item.byte, frequency: f, successor: next))
            setSmall(context, n + 1); setSmall(context + 2, t + max(3, f)); insertionCount += 1
            context = suffix(context)
            guard context != 0 else { throw KaitoError.malformed("StuffIt X Brimstone insertion suffix") }
        }
        if oldSuccessor != 0 {
            if count(oldSuccessor) == 0 { try promote(selected, skip: skip) }
            start = arena.word(selected + 2)
        } else { arena.setWord(selected + 2, next); deficit += 1; start = current }
        frontier = next
    }
    func decodeByte() throws -> UInt8? {
        current = start
        var selected = try firstDecision()
        while selected == nil {
            let masked = count(current)
            repeat {
                deficit += 1; current = suffix(current)
                if current == 0 { return nil }
            } while count(current) == masked
            selected = try suffixDecision(masked: masked)
        }
        let p = selected!, byte = arena.bytes[p]
        do { try incorporate(p) }
        catch ModelError.exhausted { restartCount += 1; try reset() }
        catch ModelError.ended { return nil }
        return byte
    }
}
