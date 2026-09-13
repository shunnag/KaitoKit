// stuffitx_jpeg_baseline.py の component 配置・表・Huffman 出力・走査を移植。
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
    func read(_ bit: () throws -> Int) throws -> Int {
        var code = 0
        for length in 1...16 {
            code = try code*2+bit()
            for symbol in 0..<256 where codes.p[256+symbol] == length && codes.p[symbol] == code { return symbol }
        }
        throw jpegMalformed("unknown Huffman code")
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
            if (s.marker == 192 || s.marker == 194), let frame = prefix.frame {
                frameProfiles = try JPEGGeometry.componentsByID(frame).map {
                    let value = quantization[$0.quantization] == nil ? 0 : try scaled($0.quantization)[2]
                    return value < 12 ? 0 : value < 48 ? 1 : 5
                }
            }
        }
    }
    mutating func segment(_ marker: Int, _ body: [UInt8]) throws {
        var position = 0
        func byte() throws -> Int {
            guard position < body.count else { throw KaitoError.truncated }
            defer { position += 1 }; return Int(body[position])
        }
        if marker == 219 {
            while position < body.count {
                let key = try byte()
                guard key & 15 <= 3, key >> 4 <= 1 else { throw jpegMalformed("quantization table selector") }
                guard key >> 4 == 0 else { throw jpegUnsupported("only eight-bit quantization tables supported") }
                var table = [Int](repeating:0,count:64)
                for p in StuffItXJPEGTables.zigzag { table[p] = try byte() }
                guard table.allSatisfy({$0 > 0}) else { throw jpegMalformed("zero quantization value") }
                quantization[key] = table
            }
        } else if marker == 196 {
            while position < body.count {
                let key = try byte()
                guard [0,1,2,3,16,17,18,19].contains(key) else { throw jpegMalformed("Huffman table selector") }
                var counts: [Int] = [], values: [Int] = []
                for _ in 0..<16 { counts.append(try byte()) }
                for _ in 0..<counts.reduce(0,+) { values.append(try byte()) }
                huffman[key] = try JPEGHuffman(counts,values)
            }
        } else if marker == 221 {
            guard body.count == 2 else { throw jpegMalformed("restart interval length") }
            restart = Int(body[0])*256+Int(body[1])
        }
    }
    func scaled(_ key: Int) throws -> [Int] {
        guard let q = quantization[key] else { throw jpegMalformed("undefined quantization table") }
        // Python の演算の括弧と Double の十進定数を保ち、積和演算へ縮約しない。
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

final class StuffItXJPEGBaseline {
    let geometry: JPEGGeometry
    let configuration = JPEGStorage<JPEGBaselineComponent>(3,JPEGBaselineComponent())
    let quantization = JPEGStorage<Int>(3*64,0)
    let previousDC = JPEGStorage<Int>(3,0)
    let blocks: StuffItXJPEGBlocks
    let entropy: JPEGEntropyWriter
    let restart: Int
    var row = 0
    var restarts = 0
    var done: Bool { row == geometry.height }
    init(_ prefix: JPEGPrefix, _ decoder: StuffItXJPEGRange, _ output: JPEGOutput, _ limits: ReadLimits) throws {
        guard let frame = prefix.frame, let scan = prefix.scan else { throw jpegMalformed("mode-2 baseline JPEG required") }
        guard frame.marker == 192 else { throw jpegUnsupported("mode-2 baseline JPEG required") }
        guard scan.ss == 0, scan.se == 63, scan.ah == 0, scan.al == 0 else { throw jpegMalformed("unsupported baseline scan") }
        geometry = try JPEGGeometry(frame,limits:limits)
        guard scan.components.map(\.id).sorted() == geometry.components.map(\.id) else { throw jpegUnsupported("single interleaved scan required") }
        let tables = try JPEGTableSet(prefix); restart = tables.restart
        for (c,properties) in geometry.components.enumerated() {
            let selector = scan.components.first { $0.id == properties.id }!.selector
            guard let dc = tables.huffman[selector >> 4], let ac = tables.huffman[16+(selector & 15)] else { throw jpegMalformed("undefined Huffman table") }
            configuration.p[c] = JPEGBaselineComponent(hs:properties.horizontal,vs:properties.vertical,profile:tables.frameProfiles[c],dc:dc,ac:ac)
            let q = try tables.scaled(properties.quantization)
            guard q.allSatisfy({$0 > 0 && $0 <= 32767}) else { throw jpegMalformed("scaled quantization table") }
            for i in 0..<64 { quantization.p[c*64+i] = q[i] }
        }
        blocks = try StuffItXJPEGBlocks(decoder,geometry:geometry,keepAll:false,limits:limits)
        entropy = JPEGEntropyWriter(output)
    }
    func step() throws {
        guard !done else { return }
        for column in 0..<geometry.width {
            for c in 0..<geometry.components.count {
                let p = configuration.p[c], q = UnsafePointer(quantization.p+c*64)
                for dy in 0..<p.vs {
                    for dx in 0..<p.hs {
                        let hint = p.vs == 1 ? 1 : p.hs == 2 ? dy*p.hs+dx : 3*dy
                        let co = try blocks.block(c,row*p.vs+dy,column*p.hs+dx,q,hint,p.profile)
                        try entropy.block(co,previousDC.p[c],p.dc!,p.ac!); previousDC.p[c] = Int(co[0])
                    }
                }
            }
            let unit = row*geometry.width+column+1
            if restart != 0 && unit < geometry.width*geometry.height && unit%restart == 0 {
                try entropy.finish(); try entropy.output.append(255); try entropy.output.append(208+restarts%8)
                restarts += 1; previousDC.p.update(repeating:0,count:3)
            }
        }
        row += 1
        if done { try entropy.finish { try self.blocks.decoder.bit() } }
    }
}

// stuffitx_jpeg_restore.py の DelayedBits。最後の完全な一バイトも保留する。
final class JPEGDelayedBits {
    let output: JPEGOutput
    var value = 0
    var count = 0
    var total = 0
    var missing = 0
    init(_ output: JPEGOutput) { self.output = output }
    @inline(__always) func flush() throws {
        try output.append(value)
        if value == 255 { try output.append(0) }
        value = 0; count = 0
    }
    @inline(__always) func put(_ v: Int, _ n: Int) throws {
        guard n >= 0, n <= 16, v >= 0, v < 1 << n else { throw jpegMalformed("progressive entropy bit value") }
        total += n
        var remaining = n
        while remaining > 0 {
            if count == 8 { try flush() }
            let take = min(8-count,remaining); remaining -= take
            value |= ((v >> remaining) & ((1 << take)-1)) << (8-count-take); count += take
        }
    }
    @inline(__always) func symbol(_ table: JPEGHuffman, _ symbol: Int) throws {
        guard symbol >= 0, symbol < 256 else { throw jpegMalformed("progressive Huffman symbol range") }
        if table.codes.p[256+symbol] == 0 { missing += 1 }
        try put(table.codes.p[symbol],table.codes.p[256+symbol])
    }
    @inline(__always) func signed(_ v: Int) throws {
        let n = jpegBitLength(abs(v)); try put(v >= 0 ? v : v+(1 << n)-1,n)
    }
    @discardableResult func finish(_ savedByte: Int) throws -> Int {
        let before = count; value = savedByte; try flush(); return before
    }
    func restart(_ index: Int) throws {
        if count < 8 { let n = 8-count; try put((1 << n)-1,n) }
        try flush(); try output.append(255); try output.append(208+index%8)
    }
}

final class JPEGScanEncoder {
    let scan: JPEGScan
    let tables: JPEGTableSet
    let bits: JPEGDelayedBits
    let lastDC = JPEGStorage<Int>(3,0)
    let correction = JPEGStorage<UInt8>(1024,0)
    let scratch = JPEGStorage<Int>(128,0)
    var correctionCount = 0
    var eob = 0
    var eobRuns = 0
    var zrls = 0
    var newRefinements = 0
    var correctionBits = 0
    var correctionFlushes = 0
    var restarts = 0
    init(_ scan: JPEGScan, _ tables: JPEGTableSet, _ output: JPEGOutput) {
        self.scan = scan; self.tables = tables; bits = JPEGDelayedBits(output)
    }
    func flushEOB(_ table: JPEGHuffman) throws {
        if eob == 0 { return }
        let size = jpegBitLength(eob)-1
        try bits.symbol(table,size << 4); try bits.put(eob-(1 << size),size)
        for i in 0..<correctionCount { try bits.put(Int(correction.p[i]),1) }
        eobRuns += 1; correctionBits += correctionCount; eob = 0; correctionCount = 0
    }
    func corrections(_ source: UnsafePointer<Int>, _ count: Int) throws {
        for i in 0..<count { try bits.put(source[i],1) }; correctionBits += count
    }
    func block(_ co: UnsafePointer<Int32>, _ component: Int, _ selector: Int) throws {
        let key = scan.ss != 0 ? 16+(selector & 15) : selector >> 4
        guard let table = tables.huffman[key] else { throw jpegMalformed("undefined progressive Huffman table") }
        if scan.ss == 0 {
            if scan.ah == 0 {
                let value = Int(co[0]) >> scan.al, difference = value-lastDC.p[component], size = jpegBitLength(abs(difference))
                guard size <= 11 else { throw jpegMalformed("progressive DC difference range") }
                try bits.symbol(table,size); try bits.signed(difference); lastDC.p[component] = value
            } else { try bits.put(Int(co[0]) >> scan.al & 1,1) }
            return
        }
        for i in scan.ss...scan.se {
            guard abs(Int(co[StuffItXJPEGTables.zigzag[i]])) <= 1023 else { throw jpegMalformed("progressive AC range") }
        }
        if scan.ah == 0 { try acFirst(co,table,scan.ss,scan.se,scan.al) }
        else { try acRefine(co,table,scan.ss,scan.se,scan.al) }
    }
    func acFirst(_ co: UnsafePointer<Int32>, _ table: JPEGHuffman, _ start: Int, _ end: Int, _ low: Int) throws {
        var run = 0
        for pos in start...end {
            let v = Int(co[StuffItXJPEGTables.zigzag[pos]]), magnitude = abs(v) >> low
            if magnitude == 0 { run += 1; continue }
            try flushEOB(table)
            while run >= 16 { try bits.symbol(table,240); run -= 16; zrls += 1 }
            try bits.symbol(table,16*run+jpegBitLength(magnitude)); try bits.signed(v > 0 ? magnitude : -magnitude); run = 0
        }
        if run != 0 { eob += 1; if eob == 32767 { try flushEOB(table) } }
    }
    func acRefine(_ co: UnsafePointer<Int32>, _ table: JPEGHuffman, _ start: Int, _ end: Int, _ low: Int) throws {
        let values = scratch.p, local = values+64
        for i in 0..<64 { values[i] = abs(Int(co[StuffItXJPEGTables.zigzag[i]])) >> low }
        var lastNew = 0, localCount = 0, run = 0
        for i in start...end where values[i] == 1 { lastNew = i }
        for pos in start...end {
            let magnitude = values[pos]
            if magnitude == 0 { run += 1; continue }
            while run >= 16 && pos <= lastNew {
                try flushEOB(table); try bits.symbol(table,240); zrls += 1
                try corrections(local,localCount); localCount = 0; run -= 16
            }
            if magnitude > 1 { local[localCount] = magnitude & 1; localCount += 1; continue }
            try flushEOB(table); try bits.symbol(table,16*run+1)
            try bits.put(co[StuffItXJPEGTables.zigzag[pos]] > 0 ? 1 : 0,1)
            try corrections(local,localCount); newRefinements += 1; run = 0; localCount = 0
        }
        if run != 0 || localCount != 0 {
            eob += 1
            // 前回は 938 未満で、今回追加できるのは最大 63 個。
            for i in 0..<localCount { correction.p[correctionCount+i] = UInt8(local[i]) }
            correctionCount += localCount
            if eob == 32767 || correctionCount >= 938 {
                correctionFlushes += correctionCount >= 938 ? 1 : 0; try flushEOB(table)
            }
        }
    }
    func finish(_ savedByte: Int) throws {
        if scan.ss != 0 {
            guard let selector = scan.components.last?.selector, let table = tables.huffman[16+(selector & 15)] else { throw jpegMalformed("undefined progressive Huffman table") }
            try flushEOB(table)
        }
        try bits.finish(savedByte)
    }
}

struct JPEGScanItem {
    var header: [UInt8]
    var scan: JPEGScan
    var savedByte: Int
    var tables: JPEGTableSet
}

final class StuffItXJPEGProgressive {
    let frame: JPEGFrame
    let geometry: JPEGGeometry
    let output: JPEGOutput
    let decoder: StuffItXJPEGRange
    let model: StuffItXJPEGHeaderModel
    let scans = JPEGStorage<JPEGScanItem?>(31,nil)
    let blocks: StuffItXJPEGBlocks
    var tables: JPEGTableSet
    var scanCount = 0
    var nextScan = 0
    var reconstructed = false
    var done: Bool { reconstructed && nextScan == scanCount }
    static func parseScan(_ body: [UInt8], _ ids: [Int]) throws -> JPEGScan {
        guard !body.isEmpty, (1...3).contains(body[0]), body.count == 2*Int(body[0])+4 else { throw jpegMalformed("progressive scan length") }
        var components: [(id:Int,selector:Int)] = []
        for i in stride(from:1,to:1+2*Int(body[0]),by:2) { components.append((Int(body[i]),Int(body[i+1]))) }
        let members = components.map(\.id)
        guard Set(members).count == members.count, Set(members).isSubset(of:Set(ids)) else { throw jpegMalformed("progressive component references") }
        guard components.allSatisfy({$0.selector >> 4 <= 3 && $0.selector & 15 <= 3}) else { throw jpegMalformed("progressive Huffman selector") }
        let ss = Int(body[body.count-3]), se = Int(body[body.count-2]), ah = Int(body.last! >> 4), al = Int(body.last! & 15)
        guard ss <= se, se <= 63, ss != 0 || se == 0, ss == 0 || members.count == 1 else { throw jpegMalformed("progressive spectral selection") }
        guard ah <= 13, al <= 13, ah == 0 || ah == al+1 else { throw jpegMalformed("progressive successive approximation") }
        if ss == 0 && members.count != 1 {
            guard members.sorted() == ids else { throw jpegMalformed("progressive DC scan arrangement") }
            components.sort { $0.id < $1.id }
        }
        return JPEGScan(components:components,ss:ss,se:se,ah:ah,al:al)
    }
    init(_ prefix: JPEGPrefix, _ decoder: StuffItXJPEGRange, _ model: StuffItXJPEGHeaderModel, _ output: JPEGOutput, _ limits: ReadLimits) throws {
        guard let frame = prefix.frame else { throw jpegMalformed("mode-2 progressive JPEG required") }
        guard frame.marker == 194 else { throw jpegUnsupported("mode-2 progressive JPEG required") }
        self.frame = frame; self.decoder = decoder; self.model = model; self.output = output
        geometry = try JPEGGeometry(frame,limits:limits); tables = try JPEGTableSet(prefix)
        blocks = try StuffItXJPEGBlocks(decoder,geometry:geometry,keepAll:true,limits:limits)
        try headers(prefix,limits)
    }
    private func headers(_ prefix: JPEGPrefix, _ limits: ReadLimits) throws {
        let ids = geometry.components.map(\.id), last = prefix.segments.last!
        var body: [UInt8]? = prefix.scan == nil ? nil : Array(prefix.header[(last.end-last.length+2)..<last.end])
        try output.append(Array(prefix.header[..<last.offset]))
        var before = prefix.scan == nil ? [] : Array(prefix.header[last.offset...])
        var totalHeader = UInt64(prefix.header.count), literalBytes = prefix.literals, markers = 0
        let progression = JPEGStorage<Int>(3*64,-1)
        func get() throws -> Int { try model.byte(decoder) }
        while let current = body {
            guard scanCount < 31 else { throw jpegMalformed("progressive scan count limit") }
            let scan = try Self.parseScan(current,ids)
            for member in scan.components {
                let c = ids.firstIndex(of:member.id)!
                for p in scan.ss...scan.se {
                    let prior = progression.p[c*64+p]
                    if literalBytes == 0 && ((scan.ah == 0 && prior != -1) || (scan.ah != 0 && prior != scan.ah)) { throw jpegMalformed("inconsistent progressive approximation sequence") }
                    progression.p[c*64+p] = scan.al
                }
            }
            scans.p[scanCount] = JPEGScanItem(header:before,scan:scan,savedByte:try get(),tables:tables); scanCount += 1
            before = []; var tokens: UInt64 = 0
            while true {
                tokens += 1
                guard tokens <= limits.maxEntrySize else { throw KaitoError.limitExceeded("StuffIt X JPEG header tokens") }
                let (marker,token) = try StuffItXJPEGEnvelope.wireToken(get)
                guard let marker else {
                    try output.append(token); literalBytes += token.count; totalHeader += UInt64(token.count)
                    try Checked.size(totalHeader,limit:limits.maxEntrySize); continue
                }
                markers += 1
                guard markers <= 4096 else { throw jpegMalformed("progressive marker count limit") }
                if marker == 216 || marker == 217 { body = nil; break }
                guard ![0,1,192,194,255].contains(marker), !(208...215).contains(marker) else { throw jpegUnsupported("unsupported progressive inter-scan marker") }
                let high = try get(), low = try get(), length = high*256+low
                guard length >= 2 else { throw jpegMalformed("progressive header length limit") }
                totalHeader += UInt64(length+2); try Checked.size(totalHeader,limit:limits.maxEntrySize)
                var data: [UInt8] = []; data.reserveCapacity(length-2)
                for _ in 0..<(length-2) { data.append(UInt8(try get())) }
                let bytes = [255,UInt8(marker),UInt8(high),UInt8(low)]+data
                if marker == 196 { before = bytes }
                else if marker == 218 { before += bytes }
                else { try output.append(bytes) }
                if marker == 218 { body = data; break }
                try tables.segment(marker,data)
            }
        }
        if literalBytes == 0 {
            for c in ids.indices where progression.p[c*64] == -1 { throw jpegMalformed("missing progressive DC scan") }
        }
    }
    func reconstruct() throws {
        for (c,component) in geometry.components.enumerated() {
            let q = try tables.scaled(component.quantization)
            guard q.allSatisfy({$0 > 0 && $0 <= 32767}) else { throw jpegMalformed("scaled quantization table") }
            try q.withUnsafeBufferPointer { q in
                for row in 0..<(geometry.height*component.vertical) {
                    for col in 0..<(geometry.width*component.horizontal) {
                        _ = try blocks.block(c,row,col,q.baseAddress!,1,tables.frameProfiles[c])
                    }
                }
            }
        }
        reconstructed = true
    }
    func step() throws {
        if !reconstructed { try reconstruct() }
        guard nextScan < scanCount else { return }
        let item = scans.p[nextScan]!, scan = item.scan
        let encoder = JPEGScanEncoder(scan,item.tables,output)
        try output.append(item.header)
        let ids = geometry.components.map(\.id)
        var ordinal = 0
        func endUnit() throws {
            ordinal += 1
            // Python と同じく base MCU 数で制限し、EOB は restart をまたいで残す。
            if tables.restart != 0 && ordinal < geometry.width*geometry.height && ordinal%tables.restart == 0 {
                try encoder.bits.restart(encoder.restarts); encoder.restarts += 1
                encoder.lastDC.p.update(repeating:0,count:3)
            }
        }
        if scan.components.count > 1 || scan.ss == 0 {
            for row in 0..<geometry.height {
                for col in 0..<geometry.width {
                    for member in scan.components {
                        let c = ids.firstIndex(of:member.id)!, properties = geometry.components[c]
                        for dy in 0..<properties.vertical {
                            for dx in 0..<properties.horizontal {
                                try encoder.block(blocks.store.full(c,row*properties.vertical+dy,col*properties.horizontal+dx),c,member.selector)
                            }
                        }
                    }
                    try endUnit()
                }
            }
        } else {
            let member = scan.components[0], c = ids.firstIndex(of:member.id)!, p = geometry.components[c], first = geometry.components[0]
            let width = (frame.width*p.horizontal+8*first.horizontal-1)/(8*first.horizontal)
            let height = (frame.height*p.vertical+8*first.vertical-1)/(8*first.vertical), padded = geometry.width*p.horizontal
            for flat in 0..<(width*height) {
                try encoder.block(blocks.store.full(c,flat/padded,flat%padded),c,member.selector); try endUnit()
            }
        }
        try encoder.finish(item.savedByte); scans.p[nextScan] = nil; nextScan += 1
    }
}
