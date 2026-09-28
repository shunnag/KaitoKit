// JPEG header の構文（component・frame・scan・segment）と、最初の scan までの marker を読む StuffItXJPEGEnvelope。
// 出典: stuffitx_jpeg.py の wire_token・_first_scan・Prefix を関数単位で移植。
import Foundation

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
        guard try get() == JPEGMarker.prefix, try get() == JPEGMarker.soi else { throw jpegMalformed("JPEG SOI required") }
        result.segments.append(JPEGSegment(marker: JPEGMarker.soi, offset: 0, end: 2))
        var tokens: UInt64 = 0
        while tokens < (wire ? limit : 4096) {
            tokens += 1
            let start = result.header.count
            if try get() != JPEGMarker.prefix {
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
            if wire && allowComplete && (marker == JPEGMarker.soi || marker == JPEGMarker.eoi) {
                result.header[result.header.count - 1] = UInt8(JPEGMarker.eoi)
                result.segments.append(JPEGSegment(marker: JPEGMarker.eoi, offset: start, end: result.header.count))
                return result
            }
            guard ![JPEGMarker.stuffedZero, JPEGMarker.tem, JPEGMarker.soi, JPEGMarker.eoi].contains(marker),
                  !JPEGMarker.rst.contains(marker) else {
                throw jpegUnsupported("unsupported marker before first scan")
            }
            let length = try get() * 256 + get()
            guard length >= 2 else { throw jpegMalformed("JPEG segment length") }
            var body: [Int] = []; body.reserveCapacity(length - 2)
            for _ in 0..<(length - 2) { body.append(try get()) }
            guard result.segments.count < 4096 else { throw jpegMalformed("JPEG segment count") }
            result.segments.append(JPEGSegment(marker: marker, offset: start, end: result.header.count, length: length))
            if marker == JPEGMarker.sof0 || marker == JPEGMarker.sof2 {
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
            } else if marker == JPEGMarker.sos {
                guard let frame = result.frame else {
                    // 未対応の SOF がある場合と、SOF 自体が欠けた破損を区別する。
                    if result.segments.contains(where: {
                        JPEGMarker.sofRange.contains($0.marker) && ![JPEGMarker.dht, JPEGMarker.jpg, JPEGMarker.dac].contains($0.marker)
                    }) {
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
