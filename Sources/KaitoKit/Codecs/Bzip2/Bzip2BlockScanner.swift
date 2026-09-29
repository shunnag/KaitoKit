import Darwin
import Foundation

/// 元の圧縮 byte を一度だけ読み、stream の範囲と bit 単位の block run を追跡する。
final class Bzip2BlockScanner {
    static let readSize = 1_048_576
    private static let overlap = Bzip2StreamLayout.headerLength - 1
    private static let blockOutputSize = 900_000
    private static let targetBlockCount = 9

    struct StreamEnd {
        let range: Range<UInt64>
        let level: UInt8
        let crc: UInt32
    }
    struct Run {
        let bytes: Data
        let streamStart: UInt64
        let end: StreamEnd?
    }
    enum Result {
        case run(Run)
        case fallback(UInt64)
        case end
    }
    private enum Kind { case block, end, stream }
    private struct Marker {
        let bit: UInt64
        let kind: Kind
    }

    private let source: any ByteSource
    private let compressedLimit: Int
    private let blockLimit: Int
    private let recordsChecksum: Bool
    private let injectedCandidates: [UInt64]
    private let injectedBitCandidates: [UInt64]
    private var bytes: [UInt8] = []
    private var start: UInt64 = 0
    private var sourceOffset: UInt64 = 0
    private var searchedByte: UInt64 = 0
    private var markers: [Marker] = []
    private var markerIndex = 0
    private var pending: Marker?
    private var needsHeader = true
    private var streamStart: UInt64 = 0
    private var level: UInt8 = 0
    private var firstBit: UInt64 = 0
    private var blockStarts: [UInt64] = []
    private var blockCRCs: [UInt32] = []
    private var combined: UInt32 = 0
    private var checksum = CRC32()

    init(source: any ByteSource, compressedLimit: Int, outputLimit: Int, recordsChecksum: Bool,
         injectedCandidates: [UInt64], injectedBitCandidates: [UInt64]) throws {
        self.source = source; self.compressedLimit = compressedLimit
        self.blockLimit = max(1, min(Self.targetBlockCount, outputLimit / Self.blockOutputSize))
        self.recordsChecksum = recordsChecksum
        let bitLength = try Checked.mul(source.length, Bzip2StreamLayout.bitsPerByte)
        self.injectedCandidates = injectedCandidates.filter { $0 > 0 && $0 < source.length }.sorted()
        self.injectedBitCandidates = injectedBitCandidates.filter { $0 > 0 && $0 < bitLength }.sorted()
    }

    func next() throws -> Result {
        if needsHeader {
            streamStart = start
            if start == source.length { return .end }
            guard try ensure(through: Checked.add(start, UInt64(Bzip2StreamLayout.headerLength))),
                  bytes.withUnsafeBytes({ Bzip2StreamLayout.isStreamStart($0, at: 0) }) else { return .fallback(streamStart) }
            level = bytes[Bzip2StreamLayout.streamHeaderLength - 1] - Bzip2StreamLayout.levelDigitBase
            firstBit = try Checked.mul(Checked.add(start, UInt64(Bzip2StreamLayout.streamHeaderLength)), Bzip2StreamLayout.bitsPerByte)
            needsHeader = false
        }
        while true {
            try Task.checkCancellation()
            guard let marker = try nextMarker() else {
                // 窓が満杯なら最後の完全な block 境界までを渡し、残りを次の run に残す。
                if sourceOffset < source.length, blockStarts.count > 1 {
                    let last = blockStarts.removeLast(), crc = blockCRCs.removeLast()
                    let result = try run(endingAt: last)
                    blockStarts = [last]; blockCRCs = [crc]
                    return result
                }
                return .fallback(streamStart)
            }
            if marker.bit < firstBit { continue }
            switch marker.kind {
            case .stream:
                return .fallback(streamStart)
            case .block:
                if !blockCRCs.isEmpty, blockCRCs.count >= blockLimit {
                    pending = marker
                    return try run(endingAt: marker.bit)
                }
                guard (!blockCRCs.isEmpty || marker.bit == firstBit),
                      try ensureMarker(marker.bit) else { return .fallback(streamStart) }
                blockStarts.append(marker.bit)
                blockCRCs.append(try markerCRC(marker.bit))
            case .end:
                guard (!blockCRCs.isEmpty || marker.bit == firstBit),
                      try ensureMarker(marker.bit) else { return .fallback(streamStart) }
                let expected = try markerCRC(marker.bit)
                let actual = blockCRCs.reduce(combined) { Bzip2StreamLayout.combinedCRC($0, blockCRC: $1) }
                guard expected == actual else { return .fallback(streamStart) }
                let end = try byteEnd(Checked.add(marker.bit, Bzip2StreamLayout.trailerBitCount))
                // 末尾の余分な byte は、元の stream を直列で再生して同じエラーにする。
                if end != source.length {
                    guard try ensure(through: Checked.add(end, UInt64(Bzip2StreamLayout.streamHeaderLength))),
                          bytes.withUnsafeBytes({ Bzip2StreamLayout.isStreamHeader($0, at: Int(end - start)) }) else {
                        return .fallback(streamStart)
                    }
                }
                return try run(endingAt: marker.bit, streamEnd: end)
            }
        }
    }

    private func run(endingAt endBit: UInt64, streamEnd: UInt64? = nil) throws -> Result {
        let bitCount = try Checked.sub(endBit, firstBit)
        let size = try Checked.add(byteEnd(bitCount), UInt64(Bzip2StreamLayout.framingByteCount))
        guard size <= UInt64(compressedLimit) else { return .fallback(streamStart) }
        let relative = try Checked.sub(firstBit, Checked.mul(start, Bzip2StreamLayout.bitsPerByte))
        let framed = bytes.withUnsafeBytes {
            Bzip2StreamLayout.reframe(stream: level, bits: $0, firstBit: relative, bitCount: bitCount, blockCRCs: blockCRCs)
        }
        combined = blockCRCs.reduce(combined) { Bzip2StreamLayout.combinedCRC($0, blockCRC: $1) }
        let consumedEnd = streamEnd ?? endBit / Bzip2StreamLayout.bitsPerByte
        let consumed = try Checked.toInt(Checked.sub(consumedEnd, start))
        if recordsChecksum {
            bytes.withUnsafeBytes { checksum.update(UnsafeRawBufferPointer(rebasing: $0[..<consumed])) }
        }
        let end = streamEnd.map { StreamEnd(range: streamStart..<$0, level: level, crc: checksum.value) }
        let result = Result.run(Run(bytes: Data(framed), streamStart: streamStart, end: end))
        bytes = Array(bytes.dropFirst(consumed)); start = consumedEnd; firstBit = endBit
        blockStarts = []; blockCRCs = []
        if streamEnd != nil { needsHeader = true; combined = 0; checksum = CRC32() }
        return result
    }

    private func markerCRC(_ bit: UInt64) throws -> UInt32 {
        let relative = try Checked.sub(Checked.add(bit, Bzip2StreamLayout.magicBitCount),
                                       Checked.mul(start, Bzip2StreamLayout.bitsPerByte))
        return bytes.withUnsafeBytes { Bzip2StreamLayout.crc(in: $0, atBit: relative) }
    }

    private func ensureMarker(_ bit: UInt64) throws -> Bool {
        try ensure(through: byteEnd(Checked.add(bit, Bzip2StreamLayout.trailerBitCount)))
    }

    private func byteEnd(_ bit: UInt64) throws -> UInt64 {
        try Checked.add(bit / Bzip2StreamLayout.bitsPerByte, bit % Bzip2StreamLayout.bitsPerByte == 0 ? 0 : 1)
    }

    private func ensure(through end: UInt64) throws -> Bool {
        guard end <= source.length else { return false }
        while sourceOffset < end {
            guard try refill() else { return false }
        }
        return true
    }

    private func nextMarker() throws -> Marker? {
        if let pending { self.pending = nil; return pending }
        while true {
            if markerIndex < markers.count {
                defer { markerIndex += 1 }
                return markers[markerIndex]
            }
            markers = []; markerIndex = 0
            let safeEnd = sourceOffset == source.length ? sourceOffset : max(start, sourceOffset > UInt64(Self.overlap) ? sourceOffset - UInt64(Self.overlap) : 0)
            if searchedByte < safeEnd {
                let lower = max(start, searchedByte)
                let baseBit = try Checked.mul(lower, Bzip2StreamLayout.bitsPerByte)
                let endBit = try Checked.mul(safeEnd, Bzip2StreamLayout.bitsPerByte)
                bytes.withUnsafeBytes { storage in
                    let window = UnsafeRawBufferPointer(rebasing: storage[Int(lower - start)...])
                    markers = Bzip2StreamLayout.blockMagicPositions(in: window, baseBit: baseBit)
                        .filter { $0 < endBit }.map { Marker(bit: $0, kind: .block) }
                    markers += Bzip2StreamLayout.endMagicPositions(in: window, baseBit: baseBit)
                        .filter { $0 < endBit }.map { Marker(bit: $0, kind: .end) }
                    var cursor = 0
                    let last = window.count - Bzip2StreamLayout.headerLength
                    while cursor <= last, let base = window.baseAddress,
                          let found = memchr(base.advanced(by: cursor), Int32(Bzip2StreamLayout.signature[0]), last - cursor + 1) {
                        let offset = base.distance(to: found)
                        let bit = baseBit + UInt64(offset) * Bzip2StreamLayout.bitsPerByte
                        if bit < endBit, Bzip2StreamLayout.isStreamStart(window, at: offset) {
                            markers.append(Marker(bit: bit, kind: .stream))
                        }
                        cursor = offset + 1
                    }
                }
                markers += injectedCandidates.filter { $0 >= lower && $0 < safeEnd }
                    .map { Marker(bit: $0 * Bzip2StreamLayout.bitsPerByte, kind: .stream) }
                markers += injectedBitCandidates.filter { $0 >= baseBit && $0 < endBit }
                    .map { Marker(bit: $0, kind: .block) }
                markers.sort { $0.bit < $1.bit }
                searchedByte = safeEnd
                continue
            }
            guard try refill() else { return nil }
        }
    }

    private func refill() throws -> Bool {
        try Task.checkCancellation()
        let requested = min(Self.readSize, compressedLimit + Bzip2StreamLayout.headerLength - bytes.count,
                            Int(min(UInt64(Int.max), source.length - sourceOffset)))
        guard requested > 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: requested)
        let count = try buffer.withUnsafeMutableBytes { try source.read(into: $0, at: sourceOffset) }
        guard count >= 0, count <= requested else { throw KaitoError.malformed("ByteSource returned an invalid byte count") }
        guard count > 0 else { throw KaitoError.truncated }
        bytes.append(contentsOf: buffer.prefix(count))
        sourceOffset = try Checked.add(sourceOffset, UInt64(count))
        return true
    }
}
