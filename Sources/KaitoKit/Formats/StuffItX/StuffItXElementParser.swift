// 指定資料 Ch.03 の要素文法と二列の framing に基づく。
import Foundation

struct StuffItXAlgorithm: Equatable {
    let key: UInt64
    let value: UInt64
    let keyLength: UInt64?
}

struct StuffItXElement {
    let offset: UInt64
    let flag: Bool
    let type: UInt64
    let attributes: [UInt64: UInt64]
    let algorithms: [StuffItXAlgorithm]
    let extra: UInt64?
    let data: [Range<UInt64>]
    let checksums: [Range<UInt64>]
    let framedSize: UInt64
    var compression: UInt64? { algorithms.first { $0.key == 1 }?.value }
}

struct StuffItXElementParser {
    let source: any ByteSource
    let limits: ReadLimits

    func parse() throws -> [StuffItXElement] {
        guard try readByteRange(source: source, offset: 0, count: 8) == Array("StuffIt!".utf8) else {
            throw KaitoError.unsupportedFormat
        }
        let input = try StuffItXBitReader(source: source, offset: 8)
        var elements: [StuffItXElement] = []
        var metadata: UInt64 = 0
        func charge(_ n: UInt64) throws {
            metadata = try Checked.add(metadata, n)
            try Checked.size(metadata, limit: limits.maxTotalMetadataSize)
        }
        func frames() throws -> [Range<UInt64>] {
            var ranges: [Range<UInt64>] = []
            while true {
                let count = try input.p2(); input.align()
                if count == 0 { return ranges }
                guard ranges.count < limits.maxMetadataRecordCount else { throw KaitoError.limitExceeded("StuffIt X frame count") }
                let end = try Checked.add(input.offset, count)
                guard end <= source.length else { throw KaitoError.truncated }
                try charge(32)
                ranges.append(input.offset..<end); try input.seek(to: end)
            }
        }
        while true {
            guard elements.count < limits.maxMetadataRecordCount else { throw KaitoError.limitExceeded("StuffIt X element count") }
            let start = input.offset, flag = try input.bits(1) != 0, type = try input.p2()
            var attributes: [UInt64: UInt64] = [:], algorithms: [StuffItXAlgorithm] = []
            var pairs = 0
            while true {
                let key = try input.p2()
                if key == 0 { break }
                pairs += 1
                guard pairs <= limits.maxMetadataRecordCount else { throw KaitoError.limitExceeded("StuffIt X attributes") }
                attributes[key] = try input.p2(); try charge(32)
            }
            while true {
                let key = try input.p2()
                if key == 0 { break }
                guard algorithms.count < limits.maxMetadataRecordCount else { throw KaitoError.limitExceeded("StuffIt X algorithms") }
                let value = try input.p2(), keyLength = key == 4 ? try input.p2() : nil
                algorithms.append(StuffItXAlgorithm(key: key, value: value, keyLength: keyLength)); try charge(32)
            }
            let extra = type == 3 || type == 7 ? try input.p2() : nil
            input.align()
            let bodyStart = input.offset
            var data: [Range<UInt64>] = [], checksums: [Range<UInt64>] = []
            switch type {
            case 1, 5, 11...UInt64.max: data = try frames(); checksums = try frames()
            case 6:
                guard let count = attributes[5] else { throw KaitoError.malformed("StuffIt X clue length") }
                try input.seek(to: Checked.add(input.offset, count))
            case 7:
                guard algorithms.isEmpty else {
                    let detail = algorithms.map { "\($0.key):\($0.value)" }.joined(separator: ",")
                    throw KaitoError.unsupportedMethod("StuffIt X Root algorithms \(detail)")
                }
            case 10: throw KaitoError.unsupportedMethod("StuffIt X Receipt")
            default: break
            }
            try charge(128)
            elements.append(StuffItXElement(offset: start, flag: flag, type: type, attributes: attributes,
                algorithms: algorithms, extra: extra, data: data, checksums: checksums, framedSize: input.offset - bodyStart))
            if type == 0 { return elements }
        }
    }
}

// framing を索引だけで連結し、codec の状態を block 境界で切らない。
final class StuffItXFramedInput: ByteSource {
    private let source: any ByteSource
    private let ranges: [Range<UInt64>]
    private let starts: [UInt64]
    let length: UInt64

    init(source: any ByteSource, ranges: [Range<UInt64>]) throws {
        var sum: UInt64 = 0, starts: [UInt64] = []
        for range in ranges {
            guard range.upperBound <= source.length else { throw KaitoError.truncated }
            starts.append(sum); sum = try Checked.add(sum, range.upperBound - range.lowerBound)
        }
        self.source = source; self.ranges = ranges; self.starts = starts; length = sum
    }
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        if buffer.isEmpty || offset >= length { return 0 }
        var low = 0, high = starts.count
        while low + 1 < high {
            let middle = (low + high) / 2
            if starts[middle] <= offset { low = middle } else { high = middle }
        }
        let physical = ranges[low].lowerBound + offset - starts[low]
        let count = Int(min(UInt64(buffer.count), ranges[low].upperBound - physical))
        let actual = try source.read(into: UnsafeMutableRawBufferPointer(rebasing: buffer[..<count]), at: physical)
        guard actual > 0, actual <= count else { throw KaitoError.truncated }
        return actual
    }
}
