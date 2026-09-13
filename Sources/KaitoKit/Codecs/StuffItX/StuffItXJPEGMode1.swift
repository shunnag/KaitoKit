// stuffitx_jpeg_mode1.py の色 baseline、整数分布、二行キャッシュを移植。
import Foundation

@inline(__always) func jpegCat3(_ n: Int) -> Int { let a = abs(n); return a < 2 ? 0 : a < 6 ? 1 : 2 }
@inline(__always) func jpegCat6(_ n: Int) -> Int { let a = abs(n); return a < 2 ? 0 : a < 4 ? 1 : a < 10 ? 2 : a < 37 ? 3 : a < 145 ? 4 : 5 }
@inline(__always) func jpegSignClass(_ n: Int) -> Int { n < 0 ? 0 : n == 0 ? 1 : 2 }

final class StuffItXJPEGMode1Blocks {
    let decoder: StuffItXJPEGRange
    let dcRows = JPEGStorage<Int>(2*81*19,0)
    let acRows = JPEGStorage<Int>(2*2404*25,0)
    let signRows = JPEGStorage<Int>(2*1377*2,1)
    let frequencies = JPEGStorage<Int>(25,0)
    let layout = JPEGStorage<JPEGPlaneLayout>(3,JPEGPlaneLayout())
    let cache: JPEGStorage<Int32>
    let metrics: JPEGStorage<Int>
    let tags: JPEGStorage<Int>
    let scratch = JPEGStorage<Int32>(64,0)
    let maxBlocks: Int
    var decoded = 0
    var rescales = 0
    var signRescales = 0
    var copyLeft = 0
    var copyUp = 0
    init(_ decoder: StuffItXJPEGRange, _ geometry: JPEGGeometry) {
        self.decoder = decoder; maxBlocks = geometry.blocks
        var ring = 0
        for c in 0..<3 {
            let p = geometry.components[c], width = geometry.width*p.horizontal, height = geometry.height*p.vertical
            layout.p[c] = JPEGPlaneLayout(width:width,height:height,ring:ring); ring += width*2
        }
        cache = JPEGStorage<Int32>(ring*64,0); metrics = JPEGStorage<Int>(ring,0); tags = JPEGStorage<Int>(ring,-1)
        for c in 0..<2 {
            for i in 64...80 { for s in 0..<19 { dcRows.p[(c*81+i)*19+s] = 1 } }
            for i in 2368..<2404 {
                for s in 0..<25 { acRows.p[(c*2404+i)*25+s] = s <= 1 || s >= 19 ? 50 : 20 }
            }
        }
    }
    func dcrow(_ c: Int, _ i: Int) throws -> UnsafeMutablePointer<Int> {
        guard c >= 0, c <= 1, i >= 0, i <= 80 else { throw jpegMalformed("mode-1 DC context range") }
        return dcRows.p+(c*81+i)*19
    }
    func acrow(_ c: Int, _ i: Int) throws -> UnsafeMutablePointer<Int> {
        guard c >= 0, c <= 1, i >= 0, i < 2404 else { throw jpegMalformed("mode-1 AC context range") }
        return acRows.p+(c*2404+i)*25
    }
    @inline(__always) func update(_ row: UnsafeMutablePointer<Int>, _ width: Int, _ s: Int, _ inc: Int, _ threshold: Int) {
        row[s] += inc
        var sum = 0
        for i in 0..<width { sum += row[i] }
        if sum >= threshold {
            for i in 0..<width { row[i] = (row[i]+1)/2 }; rescales += 1
        }
    }
    func dc(_ c: Int, _ context: Int) throws -> Int {
        let a = try dcrow(c,context), b = try dcrow(c,80), f = frequencies.p
        for i in 0..<19 { f[i] = 4*a[i]+b[i] }
        let s = try decoder.value(f,19)
        update(a,19,s,32,4096); update(b,19,s,1024,4096)
        if s == 0 || s >= 17 { return s == 0 ? s : 65536+s }
        let value = try (1 << (s-1)) | decoder.bits(s-1)
        return try decoder.bit() != 0 ? value : -value
    }
    func ac(_ c: Int, _ context: Int, _ pos: Int) throws -> Int {
        let a = try acrow(c,36*pos+context), b = try acrow(c,2304+pos), d = try acrow(c,2368+context), f = frequencies.p
        for i in 0..<25 { f[i] = 16*a[i]+b[i]+d[i] }
        let s = try decoder.value(f,25)
        update(a,25,s,64,8193); update(b,25,s,1024,8193); update(d,25,s,64,8193); return s
    }
    func sign(_ c: Int, _ index: Int) throws -> Int {
        guard c >= 0, c <= 1, index >= 0, index < 1377 else { throw jpegMalformed("mode-1 sign context range") }
        let f = signRows.p+(c*1377+index)*2, s = try decoder.value(f,2)
        f[s] += 1
        if f[s] >= 64 { f[0] = (f[0]+1)/2; f[1] = (f[1]+1)/2; signRescales += 1 }
        return s
    }
    func block(_ c: Int, _ row: Int, _ col: Int, _ upperLeftOverride: Int? = nil) throws -> (UnsafePointer<Int32>,Int) {
        guard c >= 0, c <= 2, decoded < maxBlocks else { throw jpegMalformed("mode-1 coefficient coordinates or block limit") }
        let l = layout.p[c]
        guard row >= 0, row < l.height, col >= 0, col < l.width else { throw jpegMalformed("mode-1 coefficient coordinates or block limit") }
        let index = l.ring+(row & 1)*l.width+col, upper = l.ring+((row-1) & 1)*l.width+col
        guard tags.p[index] != row else { throw jpegMalformed("duplicate mode-1 block") }
        // Python の cache は二行添字であり、上左が同じ走査中に置換される挙動も保持する。
        let left = col > 0 ? UnsafePointer(cache.p+(index-1)*64) : nil
        let up = row > 0 ? UnsafePointer(cache.p+upper*64) : nil
        let ul = row > 0 && col > 0 ? UnsafePointer(cache.p+(upper-1)*64) : nil
        guard col == 0 || tags.p[index-1] >= 0, row == 0 || tags.p[upper] >= 0,
              row == 0 || col == 0 || tags.p[upper-1] >= 0 else { throw jpegMalformed("missing mode-1 coefficient neighbor") }
        func metric(_ i: Int) -> Int { let n = metrics.p[i]; return n < 2 ? n : 1+jpegBitLength(n-1) }
        var context = 8*(col > 0 ? metric(index-1) : 0) + (row > 0 ? metric(upper) : 0)
        let cc = c == 0 ? 0 : 1, dc = try dc(cc,context), oldDC = Int(cache.p[index*64]), co = scratch.p
        co.update(repeating:0,count:64)
        if dc == 65553 {
            guard let left else { throw jpegMalformed("mode-1 left copy without neighbor") }
            co.update(from:left,count:64); copyLeft += 1
        } else if dc == 65554 {
            guard let up else { throw jpegMalformed("mode-1 upper copy without neighbor") }
            co.update(from:up,count:64); copyUp += 1
        } else {
            let pred: Int
            if let left, let up, let ul { pred = (3*(Int(left[0])+Int(up[0]))-2*(upperLeftOverride ?? Int(ul[0]))) >> 2 }
            else if let up { pred = Int(up[0]) }
            else if let left { pred = Int(left[0]) }
            else { pred = 0 }
            co[0] = Int32(jpegI16(dc+pred))
            var pos = 1
            while pos < 64 {
                let y = pos/8, x = pos & 7
                if y == 0 { context = (up.map { jpegCat6(Int($0[pos])) } ?? 0) + 6*jpegCat6(Int(co[pos-1])) }
                else if x == 0 { context = jpegCat3(Int(co[pos-8])) + (left.map {3*jpegCat4(Int($0[pos]))} ?? 0) + 12*jpegCat3(Int(co[pos-7])) }
                else { context = jpegCat3(Int(co[pos-8])) + 3*jpegCat3(Int(co[pos-1])) + (x <= 5 && pos <= 47 ? 9*jpegCat3(Int(co[pos-7])) : 0) }
                let symbol = try ac(cc,context,pos)
                if (19...21).contains(symbol) { co[pos] = Int32(symbol-20); break }
                if (22...24).contains(symbol) { co[pos] = Int32(symbol-23); pos = (pos | 7)+1; continue }
                let magnitude = symbol < 4 ? symbol : try jpegI16(2+((1 << (symbol-3)) | decoder.bits(symbol-3,little:true)))
                if magnitude != 0 {
                    context = (pos >= 16 ? jpegSignClass(Int(co[pos-16])) : 0) + (x >= 2 ? 3*jpegSignClass(Int(co[pos-2])) : 0)
                    if let up, pos < 16 { context += jpegSignClass(Int(up[pos])) }
                    if let left, x <= 1 { context += 3*jpegSignClass(Int(left[pos])) }
                    if let up, y == 1 { context += 9*jpegSignClass(Int(up[pos-8])) }
                    if let left, x == 1 { context += 27*jpegSignClass(Int(left[pos-1])) }
                    context += 81*min(y,3)+324*min(x,3)
                    co[pos] = Int32(try sign(cc,context) != 0 ? magnitude : -magnitude)
                }
                pos += 1
            }
        }
        var metric = 1
        for i in 0..<64 where co[i] != 0 { metric = i+1 }
        if metric >= 2 && abs(co[metric-1]) <= 1 { metric -= 1 }
        cache.p.advanced(by:index*64).update(from:co,count:64); metrics.p[index] = metric; tags.p[index] = row; decoded += 1
        return (UnsafePointer(cache.p+index*64),oldDC)
    }
}

final class StuffItXJPEGMode1 {
    let geometry: JPEGGeometry
    let configuration = JPEGStorage<JPEGBaselineComponent>(3,JPEGBaselineComponent())
    let previousDC = JPEGStorage<Int>(3,0)
    let blocks: StuffItXJPEGMode1Blocks
    let entropy: JPEGEntropyWriter
    let restart: Int
    var row = 0
    var restarts = 0
    var savedUpperLeft = 0
    var done: Bool { row == geometry.height }
    init(_ prefix: JPEGPrefix, _ decoder: StuffItXJPEGRange, _ output: JPEGOutput, _ limits: ReadLimits) throws {
        guard let frame = prefix.frame, let scan = prefix.scan else { throw jpegMalformed("mode-1 baseline JPEG required") }
        guard frame.marker == 192 else { throw jpegUnsupported("mode-1 baseline JPEG required") }
        let components = try JPEGGeometry.componentsByID(frame), ids = components.map(\.id)
        guard (ids == [0,1,2] || ids == [1,2,3]), scan.components.map(\.id).sorted() == ids else { throw jpegUnsupported("mode-1 measured three-component interleaved profile required") }
        guard scan.ss == 0, scan.se == 63, scan.ah == 0, scan.al == 0 else { throw jpegMalformed("unsupported mode-1 scan") }
        geometry = try JPEGGeometry(frame,limits:limits)
        let tables = try JPEGTableSet(prefix); restart = tables.restart
        for (c,p) in components.enumerated() {
            let selector = scan.components.first {$0.id == p.id}!.selector
            guard let dc = tables.huffman[selector >> 4], let ac = tables.huffman[16+(selector & 15)] else { throw jpegMalformed("undefined mode-1 Huffman table") }
            configuration.p[c] = JPEGBaselineComponent(hs:p.horizontal,vs:p.vertical,dc:dc,ac:ac)
        }
        blocks = StuffItXJPEGMode1Blocks(decoder,geometry); entropy = JPEGEntropyWriter(output)
    }
    func step() throws {
        guard !done else { return }
        for column in 0..<geometry.width {
            for c in 0..<3 {
                let p = configuration.p[c]
                for dy in 0..<p.vs {
                    for dx in 0..<p.hs {
                        let save = c == 0 && p.hs == 2 && p.vs == 2
                        let override = save && dx == 0 && dy == 0 ? savedUpperLeft : nil
                        let (co,replaced) = try blocks.block(c,row*p.vs+dy,column*p.hs+dx,override)
                        if save && dx == 1 && dy == 1 { savedUpperLeft = replaced }
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
