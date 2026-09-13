// stuffitx_jpeg.py の Bytes・RangeDecoder・HeaderModel・ヘッダー処理を関数単位で移植。
import Foundation

@inline(__always) func jpegMalformed(_ reason: String) -> KaitoError {
    .malformed("StuffIt X JPEG \(reason)")
}

@inline(__always) func jpegUnsupported(_ reason: String) -> KaitoError {
    .unsupportedMethod("StuffIt X JPEG \(reason)")
}

// 固定長領域の寿命を所有する。ホットループでは p を直接参照する。
final class JPEGStorage<T> {
    let p: UnsafeMutablePointer<T>
    let count: Int
    init(_ count: Int, _ value: T) {
        self.count = count; p = .allocate(capacity: max(1, count))
        p.initialize(repeating: value, count: count)
    }
    deinit { p.deinitialize(count: count); p.deallocate() }
}

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
    static func writeWZ(_ value: UInt64) -> [UInt8] {
        var value = value, result = [UInt8(value & 127)]
        value >>= 7
        while value != 0 { result.append(128 | UInt8(value & 127)); value >>= 7 }
        return result.reversed()
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
    var decodedBytes = 0
    var rescales = 0
    func byte(_ decoder: StuffItXJPEGRange) throws -> Int {
        let context = one.p.advanced(by: previous * 256), f = frequencies.p
        for i in 0..<256 { f[i] = zero.p[i] + 8 * context[i] }
        let symbol = try decoder.value(f, 256)
        update(context,symbol)
        update(zero.p,symbol)
        previous = symbol; decodedBytes += 1; return symbol
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

struct JPEGComponent: Equatable {
    var id: Int
    var horizontal: Int = 1
    var vertical: Int = 1
    var quantization: Int = 0
}
struct JPEGFrame {
    var marker: Int
    var width: Int
    var height: Int
    var components: [JPEGComponent]
}
struct JPEGScan {
    var components: [(id: Int, selector: Int)]
    var ss: Int
    var se: Int
    var ah: Int
    var al: Int
}
struct JPEGSegment {
    var marker: Int
    var offset: Int
    var end: Int
    var length: Int = 0
}
struct JPEGPrefix {
    var header: [UInt8] = []
    var frame: JPEGFrame?
    var scan: JPEGScan?
    var segments: [JPEGSegment] = []
    var literals = 0
    var discarded = 0
}

enum StuffItXJPEGEnvelope {
    static func wireToken(_ get: () throws -> Int) throws -> (Int?, [UInt8]) {
        let first = try get()
        if first != 255 { return (nil, [UInt8(first)]) }
        let second = try get()
        if second == 0 { return (nil, []) }
        if second == 255 { return (nil, [255, 255]) }
        return (second, [255, UInt8(second)])
    }
    static func firstScan(limit: UInt64, wire: Bool = true, allowComplete: Bool = true,
                          get next: () throws -> Int) throws -> JPEGPrefix {
        var result = JPEGPrefix()
        func get() throws -> Int {
            guard UInt64(result.header.count) < limit else { throw KaitoError.limitExceeded("StuffIt X JPEG header") }
            let value = try next(); result.header.append(UInt8(value)); return value
        }
        guard try get() == 255, try get() == 216 else { throw jpegMalformed("JPEG SOI required") }
        result.segments.append(JPEGSegment(marker: 216, offset: 0, end: 2))
        var tokens: UInt64 = 0
        while tokens < (wire ? limit : 4096) {
            tokens += 1
            let start = result.header.count
            if try get() != 255 {
                if wire { result.literals += 1; continue }
                throw jpegMalformed("JPEG marker prefix required")
            }
            var marker = try get()
            if wire {
                if marker == 255 { result.literals += 2; continue }
                if marker == 0 { result.header.removeLast(2); result.discarded += 1; continue }
            } else {
                while marker == 255 { marker = try get() }
            }
            if wire && allowComplete && (marker == 216 || marker == 217) {
                result.header[result.header.count - 1] = 217
                result.segments.append(JPEGSegment(marker: 217, offset: start, end: result.header.count))
                return result
            }
            guard ![0,1,216,217].contains(marker), !(208...215).contains(marker) else {
                throw jpegUnsupported("unsupported marker before first scan")
            }
            let length = try get() * 256 + get()
            guard length >= 2 else { throw jpegMalformed("JPEG segment length") }
            var body: [Int] = []; body.reserveCapacity(length - 2)
            for _ in 0..<(length - 2) { body.append(try get()) }
            guard result.segments.count < 4096 else { throw jpegMalformed("JPEG segment count") }
            result.segments.append(JPEGSegment(marker: marker, offset: start, end: result.header.count, length: length))
            if marker == 192 || marker == 194 {
                guard result.frame == nil, body.count >= 6, body.count == 6 + 3 * body[5] else { throw jpegMalformed("JPEG frame layout") }
                var components: [JPEGComponent] = []
                for i in stride(from: 6, to: body.count, by: 3) {
                    components.append(JPEGComponent(id: body[i], horizontal: body[i+1] >> 4, vertical: body[i+1] & 15, quantization: body[i+2]))
                }
                guard !components.isEmpty, Set(components.map(\.id)).count == components.count else { throw jpegMalformed("JPEG frame components") }
                guard components.count <= 4 else { throw jpegUnsupported("JPEG frame components") }
                guard components.allSatisfy({ (1...4).contains($0.horizontal) && (1...4).contains($0.vertical) }) else { throw jpegMalformed("JPEG sampling factors") }
                let height = body[1] * 256 + body[2], width = body[3] * 256 + body[4]
                guard width > 0, height > 0 else { throw jpegMalformed("JPEG frame dimensions or precision") }
                guard body[0] == 8 else { throw jpegUnsupported("JPEG frame dimensions or precision") }
                result.frame = JPEGFrame(marker: marker, width: width, height: height, components: components)
            } else if marker == 218 {
                guard let frame = result.frame else {
                    // 未対応の SOF がある場合と、SOF 自体が欠けた破損を区別する。
                    if result.segments.contains(where: { (192...207).contains($0.marker) && ![196,200,204].contains($0.marker) }) {
                        throw jpegUnsupported("unsupported JPEG frame marker")
                    }
                    throw jpegMalformed("JPEG scan layout")
                }
                guard body.count >= 4, body.count == 4 + 2 * body[0], (1...4).contains(body[0]) else { throw jpegMalformed("JPEG scan layout") }
                var components: [(id: Int, selector: Int)] = []
                for i in stride(from: 1, to: 1 + body[0] * 2, by: 2) { components.append((body[i], body[i+1])) }
                let ids = components.map(\.id)
                guard Set(ids).count == ids.count, Set(ids).isSubset(of: Set(frame.components.map(\.id))) else { throw jpegMalformed("JPEG scan component references") }
                result.scan = JPEGScan(components: components, ss: body[body.count-3], se: body[body.count-2], ah: body.last! >> 4, al: body.last! & 15)
                return result
            }
        }
        throw jpegMalformed("JPEG segment count")
    }
}

// read(into:) が消費した行／scan は直ちに再利用する。全画像バイト列は保持しない。
final class JPEGOutput {
    private var storage: UnsafeMutablePointer<UInt8>
    private var capacity = 4096
    var count = 0
    var cursor = 0
    var produced: UInt64 = 0
    let limit: UInt64
    init(limit: UInt64) { self.limit = limit; storage = .allocate(capacity: capacity) }
    deinit { storage.deallocate() }
    @inline(__always) func append(_ byte: Int) throws {
        guard produced < limit else { throw KaitoError.limitExceeded("StuffIt X JPEG output") }
        if count == capacity { grow() }
        storage[count] = UInt8(truncatingIfNeeded: byte); count += 1; produced += 1
    }
    private func grow() {
        let next = capacity * 2, replacement = UnsafeMutablePointer<UInt8>.allocate(capacity: next)
        replacement.initialize(from: storage, count: count); storage.deallocate(); storage = replacement; capacity = next
    }
    func append(_ bytes: [UInt8]) throws { for byte in bytes { try append(Int(byte)) } }
    func read(into buffer: UnsafeMutableRawBufferPointer) -> Int {
        let n = min(buffer.count, count - cursor)
        if n > 0 { buffer.baseAddress!.copyMemory(from: storage.advanced(by: cursor), byteCount: n); cursor += n }
        if cursor == count { count = 0; cursor = 0 }
        return n
    }
    var bytes: [UInt8] { Array(UnsafeBufferPointer(start: storage, count: count)) }
}
