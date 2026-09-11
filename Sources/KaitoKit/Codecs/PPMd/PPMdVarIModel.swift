import Foundation

// Dmitry Shkarin の公開ドメイン Model.cpp（var.I rev.1、2002-04-28）の復号側。
// 原典の 12 バイト context と 6 バイト state を、検証付き arena offset で表す。
final class PPMdVarIModel {
    typealias Offset = PPMdVarISuballocator.Offset
    private struct State {
        var symbol: UInt8
        var frequency: Int
        var successor: Offset
    }
    private struct SEE {
        var sum: UInt16
        var shift: UInt8
        var count: UInt8
        init(_ value: Int) {
            sum = UInt16(truncatingIfNeeded: value << 3)
            shift = 3
            count = 7
        }
        init(signature: UInt32) {
            sum = UInt16(truncatingIfNeeded: signature)
            shift = UInt8(truncatingIfNeeded: signature >> 16)
            count = UInt8(truncatingIfNeeded: signature >> 24)
        }
        mutating func mean() -> Int {
            let result = sum >> shift
            sum &-= result
            return Int(result) + (result == 0 ? 1 : 0)
        }
        mutating func update() {
            if shift < 7 {
                count &-= 1
                if count == 0 {
                    sum &+= sum
                    count = UInt8(truncatingIfNeeded: 3 << Int(shift))
                    shift += 1
                }
            }
        }
    }

    private static let qTable: [Int] = {
        var result = [Int](repeating: 0, count: 260)
        for i in 0..<5 { result[i] = i }
        var m = 5, k = 1, step = 1
        for i in 5..<260 {
            result[i] = m
            k -= 1
            if k == 0 { step += 1; k = step; m += 1 }
        }
        return result
    }()
    private static let nsToBS = (0..<256).map { $0 < 2 ? 2 * $0 : ($0 < 11 ? 4 : 6) }
    private static let expEscape = [25, 14, 9, 7, 5, 5, 4, 4, 4, 3, 3, 3, 2, 2, 2, 2]
    private let arena: PPMdVarISuballocator
    private let maximumOrder: Int
    private var restoreMethod: Int
    private var maximumContext: Offset = 0
    private var foundState: Offset = 0
    private var orderFall = 0
    private var runLength: Int32 = 0
    private var initialRunLength: Int32 = 0
    private var initialEscape = 0
    private var previousSuccess = 0
    private var numberMasked = 0
    private var escapeCount: UInt8 = 1
    private var charMask = [UInt8](repeating: 0, count: 256)
    private var binSumm = [UInt16](repeating: 0, count: 25 * 64)
    private var see = [SEE](repeating: SEE(0), count: 24 * 32)
    private var dummySEE = SEE(signature: 0x84ACAF8F)
    private var unmasked = [Offset](repeating: 0, count: 256)
    private var needsNormalization = false

    internal private(set) var restartCount = 0
    internal private(set) var cutOffCount = 0
    internal private(set) var freezeCount = 0
    var isArenaReleased: Bool { arena.isReleased }

    init(maximumOrder: Int, memorySize: UInt64, restoreMethod: Int) throws {
        guard (2...16).contains(maximumOrder), (0...2).contains(restoreMethod) else {
            throw KaitoError.malformed("PPMd var.I: invalid model parameters")
        }
        self.maximumOrder = maximumOrder
        self.restoreMethod = restoreMethod
        arena = try PPMdVarISuballocator(memorySize: memorySize)
        try startModelRare()
    }

    func releaseArena() { arena.release() }

    func decodeByte(using decoder: PPMdVarIRangeDecoder) throws -> UInt8 {
        // 前の symbol の正規化を次の要求まで遅延し、既知サイズの末尾で入力を要求しない。
        if needsNormalization { try decoder.normalize() }
        var minimum = maximumContext
        if try numStats(minimum) != 0 { try decodeSymbol1(minimum, decoder) }
        else { try decodeBinSymbol(minimum, decoder) }
        var depth = 0
        while foundState == 0 {
            try decoder.normalize()
            repeat {
                try step(&depth)
                orderFall += 1
                minimum = try suffix(minimum)
                if minimum == 0 { throw KaitoError.truncated }
            } while try numStats(minimum) == numberMasked
            try decodeSymbol2(minimum, decoder)
        }
        let selected = try state(foundState)
        if orderFall == 0, selected.successor >= arena.unitsStart {
            maximumContext = selected.successor
        } else {
            try updateModel(minimum)
            if escapeCount == 0 { clearMask() }
        }
        needsNormalization = true
        return selected.symbol
    }

    private func startModelRare() throws {
        charMask = [UInt8](repeating: 0, count: 256)
        escapeCount = 1
        orderFall = maximumOrder
        arena.initialize()
        initialRunLength = Int32(-min(maximumOrder, 12) - 1)
        runLength = initialRunLength
        maximumContext = try arena.allocateContext()
        let states = try arena.allocateUnits(128)
        guard maximumContext != 0, states != 0 else { throw malformed("root allocation failed") }
        try setNumStats(maximumContext, 255)
        try setFlags(maximumContext, 0)
        try setSum(maximumContext, 257)
        try setStats(maximumContext, states)
        try setSuffix(maximumContext, 0)
        for i in 0..<256 {
            try writeState(at(states, i), State(symbol: UInt8(i), frequency: 1, successor: 0))
        }
        previousSuccess = 0
        let initialBinEscape = [0x3CDD, 0x1F3F, 0x59BF, 0x48F3, 0x64A1, 0x5ABC, 0x6632, 0x6051]
        var i = 0
        for m in 0..<25 {
            while i < Self.qTable.count, Self.qTable[i] == m { i += 1 }
            for k in 0..<64 {
                binSumm[m * 64 + k] = UInt16((1 << 14) - initialBinEscape[k & 7] / (i + 1))
            }
        }
        i = 0
        for m in 0..<24 {
            while i + 3 < Self.qTable.count, Self.qTable[i + 3] == m + 3 { i += 1 }
            for k in 0..<32 { see[m * 32 + k] = SEE(2 * i + 5) }
        }
    }

    private func decodeBinSymbol(_ c: Offset, _ decoder: PPMdVarIRangeDecoder) throws {
        let p = try oneState(c)
        var s = try state(p)
        guard (1...196).contains(s.frequency) else { throw malformed("invalid binary frequency") }
        let suffixCount = try numStats(suffix(c))
        let row = Self.qTable[s.frequency - 1]
        let column = try Self.nsToBS[suffixCount] + previousSuccess + flags(c) + Int((runLength >> 26) & 0x20)
        guard row < 25, (0..<64).contains(column) else { throw malformed("invalid binary index") }
        let index = row * 64 + column
        let probability = Int(binSumm[index])
        if try decoder.shiftThreshold() < probability {
            try decoder.remove(low: 0, high: probability)
            foundState = p
            s.frequency += s.frequency < 196 ? 1 : 0
            try writeState(p, s)
            binSumm[index] &+= UInt16(128 - ((probability + 32) >> 7))
            previousSuccess = 1
            runLength &+= 1
        } else {
            try decoder.remove(low: probability, high: 1 << 14)
            binSumm[index] &-= UInt16((probability + 32) >> 7)
            initialEscape = Self.expEscape[Int(binSumm[index] >> 10)]
            charMask[Int(s.symbol)] = escapeCount
            numberMasked = 0
            previousSuccess = 0
            foundState = 0
        }
    }

    private func decodeSymbol1(_ c: Offset, _ decoder: PPMdVarIRangeDecoder) throws {
        let base = try stats(c), n = try numStats(c), total = try sum(c)
        let count = try decoder.threshold(total: total)
        let first = try state(base)
        var high = first.frequency
        if count < high {
            try decoder.remove(low: 0, high: high)
            previousSuccess = 2 * high >= total ? 1 : 0
            foundState = base
            try setFrequency(base, high + 4)
            try setSum(c, total + 4)
            runLength &+= Int32(previousSuccess)
            if high + 4 > 124 { try rescale(c) }
            return
        }
        previousSuccess = 0
        for i in 1...n {
            let p = try at(base, i), f = try frequency(p)
            high += f
            if count < high {
                try decoder.remove(low: high - f, high: high)
                try update1(c, p)
                return
            }
        }
        try decoder.remove(low: high, high: total)
        for i in 0...n { charMask[Int(try symbol(at(base, i)))] = escapeCount }
        numberMasked = n
        foundState = 0
    }

    private func update1(_ c: Offset, _ p: Offset) throws {
        foundState = p
        let f = try frequency(p) + 4
        try setFrequency(p, f)
        try setSum(c, sum(c) + 4)
        let previous = try arena.advance(p, -6)
        if f > (try frequency(previous)) {
            try swap(p, previous)
            foundState = previous
            if f > 124 { try rescale(c) }
        }
    }

    private func update2(_ c: Offset, _ p: Offset) throws {
        foundState = p
        let f = try frequency(p) + 4
        try setFrequency(p, f)
        try setSum(c, sum(c) + 4)
        if f > 124 { try rescale(c) }
        escapeCount &+= 1
        runLength = initialRunLength
    }

    private func makeEscFreq2(_ c: Offset) throws -> (index: Int?, scale: Int) {
        let n = try numStats(c)
        if n == 255 { return (nil, 1) }
        let t = try numStats(suffix(c))
        let row = Self.qTable[n + 2] - 3
        let column = try (sum(c) > 11 * (n + 1) ? 1 : 0)
            + 2 * (2 * n < t + numberMasked ? 1 : 0) + flags(c)
        guard (0..<24).contains(row), (0..<32).contains(column) else {
            throw malformed("invalid SEE index")
        }
        let i = row * 32 + column
        return (i, see[i].mean())
    }

    private func decodeSymbol2(_ c: Offset, _ decoder: PPMdVarIRangeDecoder) throws {
        let estimator = try makeEscFreq2(c)
        let n = try numStats(c), base = try stats(c)
        let expected = n - numberMasked
        guard expected > 0 else { throw malformed("no unmasked states") }
        var count = 0, high = 0
        for i in 0...n {
            let p = try at(base, i), s = try state(p)
            if charMask[Int(s.symbol)] != escapeCount {
                unmasked[count] = p
                count += 1
                high += s.frequency
            }
        }
        guard count == expected else { throw malformed("inconsistent symbol mask") }
        let total = high + estimator.scale
        let threshold = try decoder.threshold(total: total)
        if threshold < high {
            high = 0
            for i in 0..<count {
                let p = unmasked[i], f = try frequency(p)
                high += f
                if threshold < high {
                    try decoder.remove(low: high - f, high: high)
                    if let index = estimator.index { see[index].update() }
                    else { dummySEE.update() }
                    try update2(c, p)
                    return
                }
            }
            throw malformed("unmasked symbol is missing")
        }
        try decoder.remove(low: high, high: total)
        numberMasked = n
        for i in 0..<count { charMask[Int(try symbol(unmasked[i]))] = escapeCount }
        if let index = estimator.index { see[index].sum &+= UInt16(truncatingIfNeeded: total) }
        else { dummySEE.sum &+= UInt16(truncatingIfNeeded: total) }
    }

    private func clearMask() {
        escapeCount = 1
        charMask = [UInt8](repeating: 0, count: 256)
    }

    private func rescale(_ c: Offset) throws {
        var base = try stats(c), n = try numStats(c)
        guard foundState >= base, (foundState - base).isMultiple(of: 6),
              Int(foundState - base) / 6 <= n else { throw malformed("missing rescale state") }
        var p = foundState
        while p != base {
            let previous = try arena.advance(p, -6)
            try swap(p, previous)
            p = previous
        }
        let first = try frequency(base) + 4
        var escape = try sum(c) + 4 - first
        let adder = orderFall != 0 || restoreMethod > 2 ? 1 : 0
        try setFrequency(base, (first + adder) >> 1)
        var total = (first + adder) >> 1
        for i in 1...n {
            p = try at(base, i)
            var s = try state(p)
            escape -= s.frequency
            s.frequency = (s.frequency + adder) >> 1
            total += s.frequency
            try writeState(p, s)
            var destination = p
            while destination > base {
                let previous = try arena.advance(destination, -6)
                if s.frequency <= (try frequency(previous)) { break }
                try copyState(previous, destination)
                destination = previous
            }
            try writeState(destination, s)
        }
        if try frequency(at(base, n)) == 0 {
            var removed = 0
            while n - removed >= 0, try frequency(at(base, n - removed)) == 0 { removed += 1 }
            guard removed <= n else { throw malformed("rescale removed every state") }
            escape += removed
            let oldUnits = (n + 2) >> 1
            n -= removed
            try setNumStats(c, n)
            if n == 0 {
                guard escape > 0 else { throw malformed("zero rescale escape frequency") }
                var s = try state(base)
                s.frequency = min((2 * s.frequency + escape - 1) / escape, 124 / 3)
                try arena.freeUnits(base, oldUnits)
                try writeState(oneState(c), s)
                try setFlags(c, (flags(c) & 0x10) + (s.symbol >= 0x40 ? 8 : 0))
                foundState = try oneState(c)
                return
            }
            base = try arena.shrinkUnits(base, oldUnits, (n + 2) >> 1)
            try setStats(c, base)
            var f = try flags(c) & ~8
            for i in 0...n { if try symbol(at(base, i)) >= 0x40 { f |= 8 } }
            try setFlags(c, f)
        }
        total += escape - (escape >> 1)
        guard total > 0 else { throw malformed("invalid rescale sum") }
        try setSum(c, total)
        try setFlags(c, flags(c) | 4)
        foundState = base
    }

    private func refresh(_ c: Offset, _ oldUnits: Int, scale: Bool) throws {
        let n = try numStats(c), shift = scale ? 1 : 0
        guard n > 0 else { throw malformed("refresh requires multiple states") }
        let base = try arena.shrinkUnits(stats(c), oldUnits, (n + 2) >> 1)
        try setStats(c, base)
        var f = try flags(c) & (0x10 + 4 * shift)
        var escape = try sum(c), total = 0
        for i in 0...n {
            let p = try at(base, i), old = try frequency(p)
            escape -= old
            let frequency = (old + shift) >> shift
            try setFrequency(p, frequency)
            total += frequency
            if try symbol(p) >= 0x40 { f |= 8 }
        }
        guard escape >= 0 else { throw malformed("invalid refresh escape frequency") }
        total += (escape + shift) >> shift
        try setFlags(c, f)
        try setSum(c, total)
    }

    private func createSuccessors(skip: Bool, hint: Offset, context: Offset) throws -> Offset {
        let selected = try state(foundState)
        let upBranch = selected.successor
        var pc = context, p = hint
        var pending = [Offset]()
        pending.reserveCapacity(16)
        if !skip { pending.append(foundState) }
        var depth = 0
        if try skip || suffix(pc) != 0 {
            while true {
                try step(&depth)
                pc = try suffix(pc)
                guard pc != 0 else { throw malformed("successor suffix is missing") }
                if p == 0 {
                    p = try findState(pc, selected.symbol)
                    let f = try frequency(p)
                    if try numStats(pc) != 0 {
                        let delta = f < 124 - 9 ? 1 : 0
                        try setFrequency(p, f + delta)
                        try setSum(pc, sum(pc) + delta)
                    } else {
                        let delta = try numStats(suffix(pc)) == 0 && f < 24 ? 1 : 0
                        try setFrequency(p, f + delta)
                    }
                }
                let successor = try self.successor(p)
                if successor != upBranch { pc = successor; break }
                guard pending.count < 16 else { throw malformed("successor stack overflow") }
                pending.append(p)
                if try suffix(pc) == 0 { break }
                p = 0
            }
        }
        if pending.isEmpty { return pc }
        guard upBranch >= PPMdVarISuballocator.heapStart, upBranch < arena.text else {
            throw malformed("successor text is unresolved")
        }
        let newSymbol = try arena.get8(upBranch)
        let newSuccessor = try arena.advance(upBranch, 1)
        let newFlags = (selected.symbol >= 0x40 ? 0x10 : 0) + (newSymbol >= 0x40 ? 8 : 0)
        let newFrequency: Int
        if try numStats(pc) != 0 {
            p = try findState(pc, newSymbol)
            let cf = try frequency(p) - 1
            let s0 = try sum(pc) - numStats(pc) - cf
            guard cf >= 0, s0 > 0 else { throw malformed("invalid successor frequency") }
            newFrequency = 1 + (2 * cf <= s0 ? (5 * cf > s0 ? 1 : 0) : (cf + 2 * s0 - 3) / s0)
        } else { newFrequency = try frequency(oneState(pc)) }
        for owner in pending.reversed() {
            let next = try arena.allocateContext()
            if next == 0 { return 0 }
            try setNumStats(next, 0)
            try setFlags(next, newFlags)
            try writeState(oneState(next), State(symbol: newSymbol, frequency: newFrequency, successor: newSuccessor))
            try setSuffix(next, pc)
            pc = next
            try setSuccessor(owner, pc)
        }
        return pc
    }

    private func reduceOrder(hint: Offset, context: Offset) throws -> Offset {
        let selectedSymbol = try symbol(foundState), upBranch = arena.text
        var pending = [foundState]
        pending.reserveCapacity(16)
        var pc = context, p = hint, depth = 0
        try setSuccessor(foundState, upBranch)
        orderFall += 1
        while true {
            try step(&depth)
            if p == 0 {
                if try suffix(pc) == 0 {
                    if restoreMethod > 2 {
                        for owner in pending.reversed() { try setSuccessor(owner, pc) }
                        arena.resetText(plusOne: true)
                        orderFall = 1
                    }
                    return pc
                }
                pc = try suffix(pc)
                p = try findState(pc, selectedSymbol)
                let f = try frequency(p)
                if try numStats(pc) != 0 {
                    let delta = f < 124 - 9 ? 2 : 0
                    try setFrequency(p, f + delta)
                    try setSum(pc, sum(pc) + delta)
                } else { try setFrequency(p, f + (f < 32 ? 1 : 0)) }
            } else { pc = try suffix(pc) }
            if try successor(p) != 0 { break }
            guard pending.count < 16 else { throw malformed("reduce-order stack overflow") }
            pending.append(p)
            try setSuccessor(p, upBranch)
            orderFall += 1
            p = 0
        }
        if restoreMethod > 2 {
            pc = try successor(p)
            for owner in pending.reversed() { try setSuccessor(owner, pc) }
            arena.resetText(plusOne: true)
            orderFall = 1
            return pc
        }
        if try successor(p) <= upBranch {
            let saved = foundState
            foundState = p
            let result = try createSuccessors(skip: false, hint: 0, context: pc)
            try setSuccessor(p, result)
            foundState = saved
        }
        let result = try successor(p)
        if orderFall == 1, context == maximumContext {
            try setSuccessor(foundState, result)
            try arena.retractText()
        }
        return result
    }

    private func updateModel(_ minimum: Offset) throws {
        let selected = try state(foundState)
        let fFrequency = selected.frequency, fSymbol = selected.symbol
        var fSuccessor = selected.successor
        var pc = try suffix(minimum), pc1 = maximumContext, p: Offset = 0
        if fFrequency < 124 / 4, pc != 0 {
            p = try findState(pc, fSymbol)
            if try numStats(pc) != 0 {
                let base = try stats(pc)
                if p != base {
                    let previous = try arena.advance(p, -6)
                    if try frequency(p) >= frequency(previous) { try swap(p, previous); p = previous }
                }
                let f = try frequency(p), delta = f < 124 - 9 ? 2 : 0
                try setFrequency(p, f + delta)
                try setSum(pc, sum(pc) + delta)
            } else {
                let f = try frequency(p)
                try setFrequency(p, f + (f < 32 ? 1 : 0))
            }
        }
        if orderFall == 0, fSuccessor != 0 {
            let result = try createSuccessors(skip: true, hint: p, context: minimum)
            try setSuccessor(foundState, result)
            if result == 0 { try restartModelRare(pc1, minimum, fSuccessor) }
            else { maximumContext = result }
            return
        }
        var next = try arena.appendText(fSymbol)
        if arena.text >= arena.unitsStart {
            try restartModelRare(pc1, minimum, fSuccessor)
            return
        }
        if fSuccessor != 0 {
            if fSuccessor < arena.unitsStart {
                fSuccessor = try createSuccessors(skip: false, hint: p, context: minimum)
            }
        } else { fSuccessor = try reduceOrder(hint: p, context: minimum) }
        if fSuccessor == 0 { try restartModelRare(pc1, minimum, fSuccessor); return }
        guard orderFall > 0 else { throw malformed("order fall underflow") }
        orderFall -= 1
        if orderFall == 0 {
            next = fSuccessor
            if maximumContext != minimum { try arena.retractText() }
        } else if restoreMethod > 2 {
            next = fSuccessor
            arena.resetText()
            orderFall = 0
        }
        let ns = try numStats(minimum)
        // 単一 state では SummFreq は Symbol/Freq と同じ二バイトを指す。
        let s0 = UInt32(try sum(minimum)) &- UInt32(ns) &- UInt32(fFrequency)
        let flag = fSymbol >= 0x40 ? 8 : 0
        var depth = 0
        while pc1 != minimum {
            try step(&depth)
            let ns1 = try numStats(pc1)
            guard ns1 < 255 else { throw malformed("too many context states") }
            if ns1 != 0 {
                if ns1 & 1 != 0 {
                    p = try arena.expandUnits(stats(pc1), (ns1 + 1) >> 1)
                    if p == 0 { try restartModelRare(pc1, minimum, fSuccessor); return }
                    try setStats(pc1, p)
                }
                try setSum(pc1, sum(pc1) + (3 * ns1 + 1 < ns ? 1 : 0))
            } else {
                p = try arena.allocateUnits(1)
                if p == 0 { try restartModelRare(pc1, minimum, fSuccessor); return }
                var s = try state(oneState(pc1))
                s.frequency = s.frequency < 124 / 4 - 1 ? 2 * s.frequency : 124 - 4
                try writeState(p, s)
                try setStats(pc1, p)
                try setSum(pc1, s.frequency + initialEscape + (ns > 2 ? 1 : 0))
            }
            let sum = try self.sum(pc1)
            let cf = UInt32(2 * fFrequency * (sum + 6)), sf = s0 &+ UInt32(sum)
            let frequency: Int
            if cf < 6 &* sf {
                frequency = 1 + (cf > sf ? 1 : 0) + (cf >= 4 &* sf ? 1 : 0)
                try setSum(pc1, sum + 4)
            } else {
                frequency = 4 + (cf > 9 &* sf ? 1 : 0) + (cf > 12 &* sf ? 1 : 0) + (cf > 15 &* sf ? 1 : 0)
                try setSum(pc1, sum + frequency)
            }
            try setNumStats(pc1, ns1 + 1)
            p = try at(stats(pc1), ns1 + 1)
            try writeState(p, State(symbol: fSymbol, frequency: frequency, successor: next))
            try setFlags(pc1, flags(pc1) | flag)
            pc = try suffix(pc1)
            pc1 = pc
        }
        maximumContext = fSuccessor
    }

    // 原典の RestoreModelRare に対応する。復元中に増えた state を先に戻す。
    private func restartModelRare(_ stopped: Offset, _ minimum: Offset, _ fSuccessor: Offset) throws {
        arena.resetText()
        var pc = maximumContext, depth = 0
        while pc != stopped {
            try step(&depth)
            let old = try numStats(pc), base = try stats(pc)
            guard old > 0 else { throw malformed("invalid restore context") }
            try setNumStats(pc, old - 1)
            if old == 1 {
                var s = try state(base)
                try setFlags(pc, (flags(pc) & 0x10) + (s.symbol >= 0x40 ? 8 : 0))
                try writeState(oneState(pc), s)
                try arena.specialFreeUnit(base)
                s.frequency = (s.frequency + 11) >> 3
                try writeState(oneState(pc), s)
            } else { try refresh(pc, (old + 2) >> 1, scale: false) }
            pc = try suffix(pc)
        }
        while pc != minimum {
            try step(&depth)
            let n = try numStats(pc)
            if n == 0 {
                let p = try oneState(pc), f = try frequency(p)
                try setFrequency(p, f - (f >> 1))
            } else {
                let total = try sum(pc) + 4
                try setSum(pc, total)
                if total > 128 + 4 * n { try refresh(pc, (n + 2) >> 1, scale: true) }
            }
            pc = try suffix(pc)
        }
        if restoreMethod > 2 {
            maximumContext = fSuccessor
            arena.glueCount &+= arena.secondListStamp & 1 == 0 ? 1 : 0
        } else if restoreMethod == 2 {
            freezeCount += 1
            maximumContext = try root(maximumContext)
            var budget = arena.size / 6
            _ = try removeBinConts(maximumContext, order: 0, budget: &budget)
            restoreMethod = 3
            arena.glueCount = 0
            orderFall = maximumOrder
        } else if try restoreMethod == 0 || arena.usedMemory() < arena.size >> 1 {
            restartCount += 1
            try startModelRare()
            escapeCount = 0
        } else {
            cutOffCount += 1
            maximumContext = try root(maximumContext)
            // 各 pass は枝を短縮する。最大次数より多い無進行の繰返しは破損とする。
            var passes = 0
            repeat {
                guard passes <= maximumOrder + 1 else { throw malformed("cut-off did not converge") }
                passes += 1
                var budget = arena.size / 6
                _ = try cutOff(maximumContext, order: 0, budget: &budget)
                try arena.expandTextArea()
            } while try arena.usedMemory() > 3 * (arena.size >> 2)
            arena.glueCount = 0
            orderFall = maximumOrder
        }
    }

    private func cutOff(_ c: Offset, order: Int, budget: inout Int) throws -> Offset {
        try visit(order, &budget)
        let n = try numStats(c)
        if n == 0 {
            let p = try oneState(c), next = try successor(p)
            if next >= arena.unitsStart {
                let result = order < maximumOrder ? try cutOff(next, order: order + 1, budget: &budget) : 0
                try setSuccessor(p, result)
                if result != 0 || order <= 9 { return c }
            }
            try arena.specialFreeUnit(c)
            return 0
        }
        let units = (n + 2) >> 1
        let base = try arena.moveUnitsUp(stats(c), units)
        try setStats(c, base)
        var i = n
        for j in stride(from: n, through: 0, by: -1) {
            let p = try at(base, j), next = try successor(p)
            if next < arena.unitsStart {
                try setSuccessor(p, 0)
                try swap(p, at(base, i))
                i -= 1
            } else {
                let result = order < maximumOrder ? try cutOff(next, order: order + 1, budget: &budget) : 0
                try setSuccessor(p, result)
            }
        }
        if i != n, order != 0 {
            if i < 0 {
                try arena.freeUnits(base, units)
                try arena.specialFreeUnit(c)
                return 0
            }
            try setNumStats(c, i)
            if i == 0 {
                var s = try state(base)
                try setFlags(c, (flags(c) & 0x10) + (s.symbol >= 0x40 ? 8 : 0))
                try writeState(oneState(c), s)
                try arena.freeUnits(base, units)
                s.frequency = (s.frequency + 11) >> 3
                try writeState(oneState(c), s)
            } else { try refresh(c, units, scale: sum(c) > 16 * i) }
        }
        return c
    }

    private func removeBinConts(_ c: Offset, order: Int, budget: inout Int) throws -> Offset {
        try visit(order, &budget)
        let n = try numStats(c)
        if n == 0 {
            let p = try oneState(c), next = try successor(p)
            let result: Offset
            if next >= arena.unitsStart, order < maximumOrder {
                result = try removeBinConts(next, order: order + 1, budget: &budget)
            } else { result = 0 }
            try setSuccessor(p, result)
            let parent = try suffix(c)
            if result == 0, try numStats(parent) == 0 || flags(parent) == 0xFF {
                try arena.freeUnits(c, 1)
                return 0
            }
        } else {
            let base = try stats(c)
            for i in stride(from: n, through: 0, by: -1) {
                let p = try at(base, i), next = try successor(p)
                let result: Offset
                if next >= arena.unitsStart, order < maximumOrder {
                    result = try removeBinConts(next, order: order + 1, budget: &budget)
                } else { result = 0 }
                try setSuccessor(p, result)
            }
        }
        return c
    }

    private func root(_ context: Offset) throws -> Offset {
        var c = context, depth = 0
        while true {
            let next = try suffix(c)
            if next == 0 { return c }
            try step(&depth)
            c = next
        }
    }

    private func step(_ depth: inout Int) throws {
        guard depth <= maximumOrder else { throw malformed("cyclic context chain") }
        depth += 1
    }
    private func visit(_ order: Int, _ budget: inout Int) throws {
        guard order <= maximumOrder, budget > 0 else { throw malformed("cyclic context tree") }
        budget -= 1
    }

    // context: NumStats@0、Flags@1、SummFreq@2、Stats@4、Suffix@8。
    // 単一 state: Symbol@2、Freq@3、Successor@4。
    @inline(__always)
    private func numStats(_ c: Offset) throws -> Int {
        try arena.requireUnit(c)
        return Int(try arena.get8(c))
    }
    @inline(__always)
    private func flags(_ c: Offset) throws -> Int { Int(try arena.get8(arena.advance(c, 1))) }
    @inline(__always)
    private func sum(_ c: Offset) throws -> Int { Int(try arena.get16(arena.advance(c, 2))) }
    @inline(__always)
    private func suffix(_ c: Offset) throws -> Offset {
        try arena.requireUnit(c)
        return try arena.get32(arena.advance(c, 8))
    }
    private func stats(_ c: Offset) throws -> Offset {
        let n = try numStats(c)
        let p = try arena.get32(arena.advance(c, 4))
        try arena.requireUnit(p, count: 6 * (n + 1))
        return p
    }
    @inline(__always)
    private func oneState(_ c: Offset) throws -> Offset {
        try arena.requireUnit(c)
        return try arena.advance(c, 2)
    }
    private func setNumStats(_ c: Offset, _ n: Int) throws {
        guard (0...255).contains(n) else { throw malformed("invalid state count") }
        try arena.put8(UInt8(n), c)
    }
    private func setFlags(_ c: Offset, _ value: Int) throws {
        try arena.put8(UInt8(truncatingIfNeeded: value), arena.advance(c, 1))
    }
    private func setSum(_ c: Offset, _ value: Int) throws {
        guard (0...Int(UInt16.max)).contains(value) else { throw malformed("invalid frequency sum") }
        try arena.put16(UInt16(value), arena.advance(c, 2))
    }
    private func setStats(_ c: Offset, _ p: Offset) throws { try arena.put32(p, arena.advance(c, 4)) }
    private func setSuffix(_ c: Offset, _ p: Offset) throws { try arena.put32(p, arena.advance(c, 8)) }
    @inline(__always)
    private func at(_ base: Offset, _ index: Int) throws -> Offset {
        guard (0...255).contains(index) else { throw malformed("invalid state index") }
        return try arena.advance(base, index * 6)
    }
    @inline(__always)
    private func symbol(_ p: Offset) throws -> UInt8 { try arena.get8(p) }
    @inline(__always)
    private func frequency(_ p: Offset) throws -> Int { Int(try arena.get8(arena.advance(p, 1))) }
    @inline(__always)
    private func successor(_ p: Offset) throws -> Offset { try arena.get32(arena.advance(p, 2)) }
    private func setFrequency(_ p: Offset, _ value: Int) throws {
        guard (0...255).contains(value) else { throw malformed("invalid state frequency") }
        try arena.put8(UInt8(value), arena.advance(p, 1))
    }
    private func setSuccessor(_ p: Offset, _ value: Offset) throws {
        try arena.put32(value, arena.advance(p, 2))
    }
    private func state(_ p: Offset) throws -> State {
        guard p >= arena.unitsStart else { throw malformed("state outside unit area") }
        _ = try arena.checkedInt(p, count: 6)
        return try State(symbol: symbol(p), frequency: frequency(p), successor: successor(p))
    }
    private func writeState(_ p: Offset, _ value: State) throws {
        _ = try arena.checkedInt(p, count: 6)
        try arena.put8(value.symbol, p)
        try setFrequency(p, value.frequency)
        try setSuccessor(p, value.successor)
    }
    private func copyState(_ source: Offset, _ destination: Offset) throws {
        try arena.copy(from: source, to: destination, count: 6)
    }
    private func swap(_ a: Offset, _ b: Offset) throws {
        if a == b { return }
        let saved = try state(a)
        try copyState(b, a)
        try writeState(b, saved)
    }
    private func findState(_ c: Offset, _ symbol: UInt8) throws -> Offset {
        let n = try numStats(c), base = try n == 0 ? oneState(c) : stats(c)
        for i in 0...n {
            let p = try at(base, i)
            if try self.symbol(p) == symbol { return p }
        }
        throw malformed("suffix symbol is missing")
    }
    private func malformed(_ message: String) -> KaitoError { .malformed("PPMd var.I: " + message) }
}
