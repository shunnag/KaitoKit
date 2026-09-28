// 復元した係数を JPEG の entropy 符号へ戻す共通部品: block 配置 JPEGGeometry、Huffman 符号表 JPEGHuffman、
// DQT・DHT・DRI の表 JPEGTableSet、baseline の bit writer JPEGEntropyWriter。baseline・mode-1・progressive が共有する。
// 出典: stuffitx_jpeg_baseline.py の component 配置・表・Huffman 出力を移植。
import Foundation

struct JPEGGeometry {
    let components: [JPEGComponent]
    let width: Int
    let height: Int
    let blocks: Int
    static func componentsByID(_ frame: JPEGFrame) throws -> [JPEGComponent] {
        let ids = frame.components.map(\.id).sorted()
        guard ids == [0] || ids == [1] || ids == [0,1,2] || ids == [1,2,3] else { throw jpegUnsupported("unsupported component arrangement") }
        var origin = 1, slots = [JPEGComponent](repeating:JPEGComponent(id:0),count:ids.count)
        for component in frame.components {
            origin = min(origin,component.id); slots[component.id-origin] = component
        }
        for i in slots.indices { slots[i].id = origin+i }
        return slots
    }
    init(_ frame: JPEGFrame, limits: ReadLimits) throws {
        components = try Self.componentsByID(frame)
        let h = components[0].horizontal, v = components[0].vertical
        guard (1...2).contains(h), (1...2).contains(v), components.dropFirst().allSatisfy({$0.horizontal == 1 && $0.vertical == 1}),
              components.count != 1 || (h == 1 && v == 1) else { throw jpegUnsupported("unsupported sampling arrangement") }
        width = (frame.width+8*h-1)/(8*h); height = (frame.height+8*v-1)/(8*v)
        blocks = width*height*(h*v+components.count-1)
        guard blocks <= limits.maxJPEGBlocks else { throw KaitoError.limitExceeded("StuffIt X JPEG coefficient blocks") }
    }
}

final class JPEGHuffman {
    let codes = JPEGStorage<Int>(512,0)
    init(_ counts: [Int], _ values: [Int]) throws {
        guard counts.count == 16, counts.reduce(0,+) == values.count, Set(values).count == values.count else { throw jpegMalformed("ambiguous Huffman table") }
        var code = 0, cursor = 0
        for length in 1...16 {
            for _ in 0..<counts[length-1] {
                guard code < (1 << length)-1 else { throw jpegMalformed("invalid JPEG Huffman code space") }
                let value = values[cursor]
                guard (0...255).contains(value) else { throw jpegMalformed("Huffman symbol range") }
                codes.p[value] = code; codes.p[256+value] = length; cursor += 1; code += 1
            }
            code <<= 1
        }
    }
    @inline(__always) func write(_ bits: JPEGEntropyWriter, _ symbol: Int) throws {
        guard symbol >= 0, symbol < 256, codes.p[256+symbol] != 0 else { throw jpegMalformed("missing Huffman symbol") }
        try bits.put(codes.p[symbol],codes.p[256+symbol])
    }
}

struct JPEGTableSet {
    var quantization: [Int:[Int]] = [:]
    var huffman: [Int:JPEGHuffman] = [:]
    var restart = 0
    var frameProfiles: [Int] = []
    init(_ prefix: JPEGPrefix) throws {
        for s in prefix.segments where s.length > 0 {
            let body = Array(prefix.header[(s.end-s.length+2)..<s.end])
            try segment(s.marker,body)
            if (s.marker == JPEGMarker.sof0 || s.marker == JPEGMarker.sof2), let frame = prefix.frame {
                frameProfiles = try JPEGGeometry.componentsByID(frame).map {
                    let value = quantization[$0.quantization] == nil ? 0 : try scaled($0.quantization)[2]
                    return value < 12 ? 0 : value < 48 ? 1 : 5
                }
            }
        }
    }
    /// DHT の表番号（class << 4 | id）。scan の selector は上位 4 bit が DC、下位 4 bit が AC の表 id。
    @inline(__always) static func dcTableKey(_ selector: Int) -> Int { selector >> 4 }
    @inline(__always) static func acTableKey(_ selector: Int) -> Int { 16 + (selector & 15) }
    mutating func segment(_ marker: Int, _ body: [UInt8]) throws {
        var position = 0
        func byte() throws -> Int {
            guard position < body.count else { throw KaitoError.truncated }
            defer { position += 1 }; return Int(body[position])
        }
        if marker == JPEGMarker.dqt {
            while position < body.count {
                let key = try byte()
                guard key & 15 <= 3, key >> 4 <= 1 else { throw jpegMalformed("quantization table selector") }
                guard key >> 4 == 0 else { throw jpegUnsupported("only eight-bit quantization tables supported") }
                var table = [Int](repeating:0,count:64)
                for p in StuffItXJPEGTables.zigzag { table[p] = try byte() }
                guard table.allSatisfy({$0 > 0}) else { throw jpegMalformed("zero quantization value") }
                quantization[key] = table
            }
        } else if marker == JPEGMarker.dht {
            while position < body.count {
                let key = try byte()
                guard [0,1,2,3,16,17,18,19].contains(key) else { throw jpegMalformed("Huffman table selector") }
                var counts: [Int] = [], values: [Int] = []
                for _ in 0..<16 { counts.append(try byte()) }
                for _ in 0..<counts.reduce(0,+) { values.append(try byte()) }
                huffman[key] = try JPEGHuffman(counts,values)
            }
        } else if marker == JPEGMarker.dri {
            guard body.count == 2 else { throw jpegMalformed("restart interval length") }
            restart = Int(body[0])*256+Int(body[1])
        }
    }
    func scaled(_ key: Int) throws -> [Int] {
        guard let q = quantization[key] else { throw jpegMalformed("undefined quantization table") }
        // 丸めは (値 × (scale[x] × scale[y])) × 8.0 + 0.5 をこの括弧と順序の Double で計算し、積和へ縮約しない。
        // 順序や縮約で丸めが変わると、量子化表が参照実装と一致しなくなる。
        return q.enumerated().map { i,value in Int(Double(value)*(StuffItXJPEGTables.scale[i%8]*StuffItXJPEGTables.scale[i/8])*8.0+0.5) }
    }
}

final class JPEGEntropyWriter {
    let output: JPEGOutput
    var value = 0
    var count = 0
    var totalBits = 0
    init(_ output: JPEGOutput) { self.output = output }
    @inline(__always) func put(_ v: Int, _ n: Int) throws {
        guard n >= 0, n <= 16, v >= 0, v < 1 << n else { throw jpegMalformed("entropy bit value") }
        totalBits += n; value = (value << n) | v; count += n
        while count >= 8 {
            count -= 8
            let byte = value >> count & 255
            try output.append(byte)
            if byte == 255 { try output.append(0) }
        }
        value &= (1 << count)-1
    }
    @discardableResult func finish(_ padding: (() throws -> Int)? = nil) throws -> Int {
        let n = (8-count)%8
        for _ in 0..<n { try put(padding?() ?? 1,1) }
        return n
    }
    func block(_ co: UnsafePointer<Int32>, _ previousDC: Int, _ dc: JPEGHuffman, _ ac: JPEGHuffman) throws {
        let difference = Int(co[0])-previousDC, size = jpegBitLength(abs(difference))
        guard size <= 11 else { throw jpegMalformed("baseline DC range") }
        try dc.write(self,size)
        if size != 0 { try put(difference > 0 ? difference : difference+(1 << size)-1,size) }
        var run = 0
        for i in 1..<64 {
            let v = Int(co[StuffItXJPEGTables.zigzag[i]])
            if v == 0 { run += 1; continue }
            while run >= 16 { try ac.write(self,240); run -= 16 }
            let size = jpegBitLength(abs(v))
            guard size <= 10 else { throw jpegMalformed("baseline AC range") }
            try ac.write(self,run*16+size)
            try put(v > 0 ? v : v+(1 << size)-1,size); run = 0
        }
        if run != 0 { try ac.write(self,0) }
    }
}

struct JPEGBaselineComponent {
    var hs = 1
    var vs = 1
    var profile = 0
    var dc: JPEGHuffman?
    var ac: JPEGHuffman?
}
