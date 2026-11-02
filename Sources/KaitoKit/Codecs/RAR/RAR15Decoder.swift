import Foundation

// Provenance: RAR 1.3/1.5 format notes §6 and RAR 1.54 black-box archives.
// No 7-Zip Rar15, unrar source, XADMaster, or The Unarchiver source was used.
final class RAR15Decoder: Decompressor {
    static let windowSize = 1 << 16
    private static let windowMask = windowSize - 1
    private static let decL1 = [0x8000, 0xa000, 0xc000, 0xd000, 0xe000, 0xea00,
        0xee00, 0xf000, 0xf200, 0xf200, 0xffff]
    private static let posL1 = [0, 0, 0, 2, 3, 5, 7, 11, 16, 20, 24, 32, 32]
    private static let decL2 = [0xa000, 0xc000, 0xd000, 0xe000, 0xea00, 0xee00,
        0xf000, 0xf200, 0xf240, 0xffff]
    private static let posL2 = [0, 0, 0, 0, 5, 7, 9, 13, 18, 22, 26, 34, 36]
    private static let decHf0 = [0x8000, 0xc000, 0xe000, 0xf200, 0xf200, 0xf200,
        0xf200, 0xf200, 0xffff]
    private static let posHf0 = [0, 0, 0, 0, 0, 8, 16, 24, 33, 33, 33, 33, 33]
    private static let decHf1 = [0x2000, 0xc000, 0xe000, 0xf000, 0xf200, 0xf200,
        0xf7e0, 0xffff]
    private static let posHf1 = [0, 0, 0, 0, 0, 0, 4, 44, 60, 76, 80, 80, 127]
    private static let decHf2 = [0x1000, 0x2400, 0x8000, 0xc000, 0xfa00, 0xffff,
        0xffff, 0xffff]
    private static let posHf2 = [0, 0, 0, 0, 0, 0, 2, 7, 53, 117, 233, 0, 0]
    private static let decHf3 = [0x0800, 0x2400, 0xee00, 0xfe80, 0xffff, 0xffff, 0xffff]
    private static let posHf3 = [0, 0, 0, 0, 0, 0, 0, 2, 16, 218, 251, 0, 0]
    private static let decHf4 = [0xff00, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff]
    private static let posHf4 = [0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 0, 0, 0]
    private static let shortLen1 = [1, 3, 4, 4, 5, 6, 7, 8, 8, 4, 4, 5, 6, 6, 4, 0]
    private static let shortXor1 = [0x00, 0xa0, 0xd0, 0xe0, 0xf0, 0xf8, 0xfc, 0xfe,
        0xff, 0xc0, 0x80, 0x90, 0x98, 0x9c, 0xb0]
    private static let shortLen2 = [2, 3, 3, 3, 4, 4, 5, 6, 6, 4, 4, 5, 6, 6, 4, 0]
    private static let shortXor2 = [0x00, 0x40, 0x60, 0xa0, 0xd0, 0xe0, 0xf0, 0xf8,
        0xfc, 0xc0, 0x80, 0x90, 0x98, 0x9c, 0xb0]

    final class SolidState {
        var chSet = (0..<256).map { $0 << 8 }
        var chSetA = Array(0..<256)
        var chSetB = (0..<256).map { $0 << 8 }
        var chSetC = (0..<256).map { ((256 - $0) & 0xff) << 8 }
        var nToPl = [Int](repeating: 0, count: 256)
        var nToPlB = [Int](repeating: 0, count: 256)
        var nToPlC = [Int](repeating: 0, count: 256)
        var window = [UInt8](repeating: 0, count: RAR15Decoder.windowSize)
        var unpPtr = 0
        var firstWinDone = false
        var avrPlc = 0x3500
        var avrPlcB = 0
        var avrLn1 = 0
        var avrLn2 = 0
        var avrLn3 = 0
        var maxDist3 = 0x2001
        var nhfb = 0x80
        var nlzb = 0x80
        var numHuf = 0
        var buf60 = 0
        var stMode = 0
        var lCount = 0
        var flagBuf = 0
        var flagsCnt = 0
        var oldDistances = [-1, -1, -1, -1]
        var oldDistancePointer = 0
        var lastDistance = -1
        var lastLength = 0

        init(dictionarySize: UInt64) throws {
            RAR15Decoder.corrHuff(&chSetB, &nToPlB)
        }
    }

    private let state: SolidState
    private let expectedSize: UInt64
    private let packedBitCount: UInt64
    private var bits: MSBFirstBitReader
    private var consumedBits: UInt64 = 0
    private var produced: UInt64 = 0
    private var pendingDistance = 0
    private var pendingLength = 0
    private var pendingZeroFill = false
    private var finished = false
    private var terminalError: (any Error)?

    var isFinished: Bool { finished && terminalError == nil }

    init(
        source: any ByteSource,
        offset: UInt64,
        compressedSize: UInt64,
        expectedSize: UInt64,
        unpackVersion: UInt8,
        method: UInt8,
        dictionarySize: UInt64,
        isSolid: Bool,
        limits: ReadLimits,
        solidState suppliedSolidState: SolidState? = nil
    ) throws {
        guard unpackVersion == 15 || unpackVersion == 13 else {
            throw KaitoError.unsupportedMethod("RAR4 unpack version \(unpackVersion)")
        }
        guard (0x31...0x35).contains(method) else {
            throw KaitoError.unsupportedMethod(String(format: "RAR4 method 0x%02x", method))
        }
        guard !isSolid || suppliedSolidState != nil else {
            throw KaitoError.unsupportedMethod("RAR4 solid continuation requires shared state")
        }
        let end = try Checked.add(offset, compressedSize)
        guard end <= source.length else { throw KaitoError.truncated }
        try Checked.size(expectedSize, limit: limits.maxEntrySize)
        try Checked.size(compressedSize, limit: limits.maxEntrySize)
        try Checked.size(UInt64(Self.windowSize), limit: limits.maxDictionarySize)
        _ = dictionarySize
        let count = try Checked.toInt(compressedSize)
        var input = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let read = try input.withUnsafeMutableBytes { destination in
                try source.read(into: destination, at: try Checked.add(offset, UInt64(filled)))
            }
            guard read > 0, read <= count - filled else { throw KaitoError.truncated }
            filled += read
        }
        bits = MSBFirstBitReader(bytes: input)
        packedBitCount = try Checked.mul(compressedSize, 8)
        state = try suppliedSolidState ?? SolidState(dictionarySize: dictionarySize)
        self.expectedSize = expectedSize
        state.flagBuf = 0
        state.flagsCnt = 0
        state.stMode = 0
        state.lCount = 0
        if expectedSize > 0 {
            try getFlagsBuf()
            state.flagsCnt = 8
        }
        finished = expectedSize == 0
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if let terminalError { throw terminalError }
        guard !finished, !buffer.isEmpty else { return 0 }
        do {
            var count = 0
            while count < buffer.count, produced < expectedSize {
                if pendingLength > 0 {
                    count += try copyMatch(into: buffer, offset: count)
                    continue
                }
                if state.stMode != 0 {
                    try huffDecode(into: buffer, offset: &count)
                    continue
                }
                state.flagsCnt -= 1
                if state.flagsCnt < 0 {
                    try getFlagsBuf()
                    state.flagsCnt = 7
                }
                if state.flagBuf & 0x80 != 0 {
                    state.flagBuf <<= 1
                    if state.nlzb > state.nhfb {
                        try longLZ(into: buffer, offset: &count)
                    } else {
                        try huffDecode(into: buffer, offset: &count)
                    }
                } else {
                    state.flagBuf <<= 1
                    state.flagsCnt -= 1
                    if state.flagsCnt < 0 {
                        try getFlagsBuf()
                        state.flagsCnt = 7
                    }
                    if state.flagBuf & 0x80 != 0 {
                        state.flagBuf <<= 1
                        if state.nlzb > state.nhfb {
                            try huffDecode(into: buffer, offset: &count)
                        } else {
                            try longLZ(into: buffer, offset: &count)
                        }
                    } else {
                        state.flagBuf <<= 1
                        try shortLZ(into: buffer, offset: &count)
                    }
                }
            }
            if produced == expectedSize { finished = true }
            return count
        } catch {
            terminalError = error
            throw error
        }
    }

    private func getBits() throws -> Int {
        Int(try bits.peek(16))
    }

    private func addBits(_ count: Int) throws {
        guard (0...32).contains(count) else { throw KaitoError.malformed("RAR4 invalid bit count") }
        consumedBits = try Checked.add(consumedBits, UInt64(count))
        guard consumedBits <= packedBitCount else { throw KaitoError.truncated }
        _ = try bits.read(count)
    }

    private func decodeNum(_ start: Int, _ dec: [Int], _ pos: [Int]) throws -> Int {
        let num = try getBits() & 0xfff0
        var start = start, index = 0
        while dec[index] <= num {
            start += 1
            index += 1
            guard index < dec.count else { throw KaitoError.malformed("RAR4 decode table overrun") }
        }
        guard start <= 16 else { throw KaitoError.malformed("RAR4 decode bit count") }
        try addBits(start)
        let base = index > 0 ? dec[index - 1] : 0
        guard start < pos.count else { throw KaitoError.malformed("RAR4 decode position overrun") }
        return ((num - base) >> (16 - start)) + pos[start]
    }

    private func getFlagsBuf() throws {
        let place = try decodeNum(5, Self.decHf2, Self.posHf2)
        guard state.chSetC.indices.contains(place) else {
            throw KaitoError.malformed("RAR4 flag position place=\(place)")
        }
        var flags = 0
        var newPlace = 0
        while true {
            flags = state.chSetC[place]
            newPlace = state.nToPlC[flags & 0xff]
            guard state.chSetC.indices.contains(newPlace) else {
                throw KaitoError.malformed("RAR4 flag position place=\(place) newPlace=\(newPlace)")
            }
            state.nToPlC[flags & 0xff] += 1
            flags += 1
            guard flags & 0xff != 0 else {
                Self.corrHuff(&state.chSetC, &state.nToPlC)
                continue
            }
            break
        }
        state.flagBuf = state.chSetC[place] >> 8
        state.chSetC[place] = state.chSetC[newPlace]
        state.chSetC[newPlace] = flags
    }

    private func huffDecode(into buffer: UnsafeMutableRawBufferPointer, offset: inout Int) throws {
        let field = try getBits()
        var place: Int
        if state.avrPlc > 0x75ff {
            place = try decodeNum(8, Self.decHf4, Self.posHf4)
        } else if state.avrPlc > 0x5dff {
            place = try decodeNum(6, Self.decHf3, Self.posHf3)
        } else if state.avrPlc > 0x35ff {
            place = try decodeNum(5, Self.decHf2, Self.posHf2)
        } else if state.avrPlc > 0x0dff {
            place = try decodeNum(5, Self.decHf1, Self.posHf1)
        } else {
            place = try decodeNum(4, Self.decHf0, Self.posHf0)
        }
        place &= 0xff
        if state.stMode != 0 {
            if place == 0, field > 0x0fff { place = 0x100 }
            place -= 1
            if place == -1 {
                let control = try getBits()
                try addBits(1)
                if control & 0x8000 != 0 {
                    state.numHuf = 0
                    state.stMode = 0
                    return
                }
                let length = control & 0x4000 != 0 ? 4 : 3
                try addBits(1)
                var distance = try decodeNum(5, Self.decHf2, Self.posHf2)
                distance = (distance << 5) | (try getBits() >> 11)
                try addBits(5)
                try appendMatch(distance: distance, length: length, record: false)
                offset += try copyMatch(into: buffer, offset: offset)
                return
            }
        } else if state.numHuf >= 16, state.flagsCnt == 0 {
            state.stMode = 1
        }
        state.avrPlc += place
        state.avrPlc -= state.avrPlc >> 8
        state.nhfb += 16
        if state.nhfb > 0xff {
            state.nhfb = 0x90
            state.nlzb >>= 1
        }
        guard state.chSet.indices.contains(place) else {
            throw KaitoError.malformed("RAR4 literal position place=\(place)")
        }
        let literal = state.chSet[place] >> 8
        guard (0...255).contains(literal) else {
            throw KaitoError.malformed("RAR4 literal state place=\(place) entry=\(state.chSet[place])")
        }
        buffer[offset] = UInt8(literal)
        try writeByte(UInt8(literal))
        offset += 1
        state.numHuf += 1
        var current = 0
        var newPlace = 0
        while true {
            current = state.chSet[place]
            newPlace = state.nToPl[current & 0xff]
            guard state.chSet.indices.contains(newPlace) else {
                throw KaitoError.malformed(
                    "RAR4 literal position place=\(place) newPlace=\(newPlace) entry=\(current)"
                )
            }
            state.nToPl[current & 0xff] += 1
            current += 1
            guard current & 0xff > 0xa1 else { break }
            Self.corrHuff(&state.chSet, &state.nToPl)
        }
        state.chSet[place] = state.chSet[newPlace]
        state.chSet[newPlace] = current
    }

    private func shortLZ(into buffer: UnsafeMutableRawBufferPointer, offset: inout Int) throws {
        state.numHuf = 0
        var field = try getBits()
        if state.lCount == 2 {
            try addBits(1)
            if field >= 0x8000 {
                try appendMatch(distance: state.lastDistance, length: state.lastLength, record: false)
                offset += try copyMatch(into: buffer, offset: offset)
                return
            }
            field <<= 1
            state.lCount = 0
        }
        field >>= 8
        var length = 0
        if state.avrLn1 < 37 {
            while length < Self.shortXor1.count {
                let bits = length == 1 ? state.buf60 + 3 : Self.shortLen1[length]
                let mask = ~(0xff >> bits)
                if (field ^ Self.shortXor1[length]) & mask == 0 { break }
                length += 1
            }
            guard length < Self.shortXor1.count else { throw KaitoError.malformed("RAR4 short match code") }
            try addBits(length == 1 ? state.buf60 + 3 : Self.shortLen1[length])
        } else {
            while length < Self.shortXor2.count {
                let bits = length == 3 ? state.buf60 + 3 : Self.shortLen2[length]
                let mask = ~(0xff >> bits)
                if (field ^ Self.shortXor2[length]) & mask == 0 { break }
                length += 1
            }
            guard length < Self.shortXor2.count else { throw KaitoError.malformed("RAR4 short match code") }
            try addBits(length == 3 ? state.buf60 + 3 : Self.shortLen2[length])
        }
        if length == 9 {
            state.lCount += 1
            try appendMatch(distance: state.lastDistance, length: state.lastLength, record: false)
            offset += try copyMatch(into: buffer, offset: offset)
            return
        }
        if length == 14 {
            state.lCount = 0
            let matchLength = try decodeNum(3, Self.decL2, Self.posL2) + 5
            let distance = (try getBits() >> 1) | 0x8000
            try addBits(15)
            state.lastDistance = distance
            state.lastLength = matchLength
            try appendMatch(distance: distance, length: matchLength, record: false)
            offset += try copyMatch(into: buffer, offset: offset)
            return
        }
        if length >= 10 {
            state.lCount = 0
            let savedLength = length
            let distance = state.oldDistances[(state.oldDistancePointer - (length - 9)) & 3]
            var matchLength = try decodeNum(2, Self.decL1, Self.posL1) + 2
            if matchLength == 0x101, savedLength == 10 {
                state.buf60 ^= 1
                return
            }
            if distance > 256 { matchLength += 1 }
            if distance >= state.maxDist3 { matchLength += 1 }
            try appendMatch(distance: distance, length: matchLength, record: true)
            offset += try copyMatch(into: buffer, offset: offset)
            return
        }
        state.lCount = 0
        state.avrLn1 += length
        state.avrLn1 -= state.avrLn1 >> 4
        let place = try decodeNum(5, Self.decHf2, Self.posHf2) & 0xff
        let distance = state.chSetA[place]
        if place > 0 {
            let previous = state.chSetA[place - 1]
            state.chSetA[place] = previous
            state.chSetA[place - 1] = distance
        }
        try appendMatch(distance: distance + 1, length: length + 2, record: true)
        offset += try copyMatch(into: buffer, offset: offset)
    }

    private func longLZ(into buffer: UnsafeMutableRawBufferPointer, offset: inout Int) throws {
        state.numHuf = 0
        state.nlzb += 16
        if state.nlzb > 0xff {
            state.nlzb = 0x90
            state.nhfb >>= 1
        }
        let oldAvr2 = state.avrLn2
        var length: Int
        let field = try getBits()
        if state.avrLn2 >= 122 {
            length = try decodeNum(3, Self.decL2, Self.posL2)
        } else if state.avrLn2 >= 64 {
            length = try decodeNum(2, Self.decL1, Self.posL1)
        } else if field < 0x100 {
            length = field
            try addBits(16)
        } else {
            length = 0
            while (field << length) & 0x8000 == 0 {
                length += 1
                guard length <= 15 else { throw KaitoError.malformed("RAR4 long match length") }
            }
            try addBits(length + 1)
        }
        state.avrLn2 += length
        state.avrLn2 -= state.avrLn2 >> 5
        let distancePlace: Int
        if state.avrPlcB > 0x28ff {
            distancePlace = try decodeNum(5, Self.decHf2, Self.posHf2)
        } else if state.avrPlcB > 0x6ff {
            distancePlace = try decodeNum(5, Self.decHf1, Self.posHf1)
        } else {
            distancePlace = try decodeNum(4, Self.decHf0, Self.posHf0)
        }
        state.avrPlcB += distancePlace
        state.avrPlcB -= state.avrPlcB >> 8
        let place = distancePlace & 0xff
        var packed = 0
        var newPlace = 0
        while true {
            packed = state.chSetB[place]
            newPlace = state.nToPlB[packed & 0xff]
            guard state.chSetB.indices.contains(newPlace) else {
                throw KaitoError.malformed(
                    "RAR4 distance position place=\(place) newPlace=\(newPlace) entry=\(packed)"
                )
            }
            state.nToPlB[packed & 0xff] += 1
            packed += 1
            guard packed & 0xff == 0 else { break }
            Self.corrHuff(&state.chSetB, &state.nToPlB)
        }
        state.chSetB[place] = state.chSetB[newPlace]
        state.chSetB[newPlace] = packed
        let distance = ((packed & 0xff00) | (try getBits() >> 8)) >> 1
        try addBits(7)
        let oldAvr3 = state.avrLn3
        if length != 1 && length != 4 {
            if length == 0, distance <= state.maxDist3 {
                state.avrLn3 += 1
                state.avrLn3 -= state.avrLn3 >> 8
            } else if state.avrLn3 > 0 {
                state.avrLn3 -= 1
            }
        }
        length += 3
        if distance >= state.maxDist3 { length += 1 }
        if distance <= 256 { length += 8 }
        if oldAvr3 > 0xb0 || (state.avrPlc >= 0x2a00 && oldAvr2 < 0x40) {
            state.maxDist3 = 0x7f00
        } else {
            state.maxDist3 = 0x2001
        }
        try appendMatch(distance: distance, length: length, record: true)
        offset += try copyMatch(into: buffer, offset: offset)
    }

    private func appendMatch(distance: Int, length: Int, record: Bool) throws {
        if record {
            state.oldDistances[state.oldDistancePointer] = distance
            state.oldDistancePointer = (state.oldDistancePointer + 1) & 3
            state.lastDistance = distance
            state.lastLength = length
        }
        pendingDistance = distance
        pendingLength = length
        pendingZeroFill = distance < 0 || distance == 0 || distance > Self.windowSize ||
            (!state.firstWinDone && distance > state.unpPtr)
    }

    private func copyMatch(into buffer: UnsafeMutableRawBufferPointer, offset: Int) throws -> Int {
        let available = min(pendingLength, min(buffer.count - offset, Int(expectedSize - produced)))
        for index in 0..<available {
            let byte: UInt8
            if pendingZeroFill {
                byte = 0
            } else {
                let sourceIndex = (state.unpPtr - pendingDistance) & Self.windowMask
                byte = state.window[sourceIndex]
            }
            buffer[offset + index] = byte
            try writeByte(byte)
        }
        pendingLength -= available
        if pendingLength == 0 { pendingDistance = 0 }
        return available
    }

    private func writeByte(_ byte: UInt8) throws {
        guard produced < expectedSize else { throw KaitoError.malformed("RAR4 output exceeds declared size") }
        state.window[state.unpPtr] = byte
        state.unpPtr = (state.unpPtr + 1) & Self.windowMask
        if state.unpPtr == 0 { state.firstWinDone = true }
        produced += 1
    }

    private static func corrHuff(_ chars: inout [Int], _ places: inout [Int]) {
        var index = 0
        for rank in stride(from: 7, through: 0, by: -1) {
            for _ in 0..<32 {
                chars[index] = (chars[index] & 0xff00) | rank
                index += 1
            }
        }
        places = [Int](repeating: 0, count: 256)
        for rank in stride(from: 6, through: 0, by: -1) {
            places[rank] = (7 - rank) * 32
        }
    }
}
