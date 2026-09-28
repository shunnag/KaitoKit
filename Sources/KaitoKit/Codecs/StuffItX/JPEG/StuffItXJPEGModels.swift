// mode-2 の係数 model: 整数演算の補助関数、文脈から分布を作る StuffItXJPEGModel、DC と方向の予測。
// 出典: stuffitx_jpeg_models.py の整数演算・分布・予測を同じ更新順序で移植。
import Foundation

@inline(__always) func jpegI16(_ n: Int) -> Int { Int(Int16(truncatingIfNeeded: n)) }
@inline(__always) func jpegBitLength(_ n: Int) -> Int { n == 0 ? 0 : Int.bitWidth - n.leadingZeroBitCount }
@inline(__always) func jpegCat4(_ n: Int) -> Int {
    let a = abs(n); return a < 2 ? 0 : a < 6 ? 1 : a <= 16 ? 2 : 3
}
@inline(__always) func jpegCategory(_ n: Int) -> Int {
    let a = min(abs(jpegI16(n)), 16383); return a < 6 ? a : min(15, 5 + jpegBitLength(a - 5))
}
@inline(__always) func jpegActivity(_ n: Int) -> Int {
    n == 0 ? 0 : n < 7 ? 1 : n < 13 ? 2 : n < 49 ? 3 : n <= 160 ? 4 : 5
}

struct JPEGModelKeys {
    var a: Int; var b: Int; var c: Int; var d: Int
    var width: Int
    var sign: Bool = false
}

final class StuffItXJPEGModel {
    typealias T = StuffItXJPEGTables
    let statistics = JPEGStorage<UInt8>(0x39d30, 0)
    let signStatistics = JPEGStorage<UInt8>(0x2aa2, 0)
    let frequencies = JPEGStorage<Int>(16, 0)
    var rescales = 0

    func row(_ kind: Character, _ index: Int) throws -> UnsafeMutablePointer<UInt8> {
        let base: Int, width: Int
        switch kind {
        case "d": (base, width) = (0, 16)
        case "h": (base, width) = (0x2d70, 8)
        case "v": (base, width) = (0x8430, 8)
        case "a": (base, width) = (0x10a30, 16)
        case "s": (base, width) = (0, 2)
        default: throw jpegMalformed("coefficient model context range")
        }
        let data = kind == "s" ? signStatistics : statistics
        guard index >= 0, index <= (data.count - base - width) / width else { throw jpegMalformed("coefficient model context range") }
        return data.p.advanced(by: base + index * width)
    }
    @inline(__always) func combine(_ keys: JPEGModelKeys, _ base: [Int], _ weights: (Int, Int, Int, Int)) throws {
        let data = keys.sign ? signStatistics : statistics
        // 各分布の四つの範囲を一度だけ検査し、symbol ごとの添字検査を外す。
        guard keys.a >= 0, keys.b >= 0, keys.c >= 0, keys.d >= 0,
              max(keys.a, keys.b, keys.c, keys.d) <= data.count - keys.width else { throw jpegMalformed("coefficient model context range") }
        let p = data.p, f = frequencies.p
        for i in 0..<keys.width {
            f[i] = base[i] + weights.0 * Int(p[keys.a+i]) + weights.1 * Int(p[keys.b+i])
                + weights.2 * Int(p[keys.c+i]) + weights.3 * Int(p[keys.d+i])
        }
    }
    @inline(__always) func update(_ keys: JPEGModelKeys, _ symbol: Int, _ inc: Int, _ threshold: Int) {
        let data = keys.sign ? signStatistics.p : statistics.p
        updateRow(data.advanced(by: keys.a), keys.width, symbol, inc, threshold)
        updateRow(data.advanced(by: keys.b), keys.width, symbol, inc, threshold)
        updateRow(data.advanced(by: keys.c), keys.width, symbol, inc, threshold)
        if !keys.sign { updateRow(data.advanced(by: keys.d), keys.width, symbol, inc, threshold) }
    }
    @inline(__always) private func updateRow(_ row: UnsafeMutablePointer<UInt8>, _ width: Int, _ symbol: Int, _ inc: Int, _ threshold: Int) {
        row[symbol] &+= UInt8(inc)
        if row[symbol] >= threshold {
            for i in 0..<width { row[i] >>= 1 }
            rescales += 1
        }
    }
    @inline(__always) func symbol(_ r: StuffItXJPEGRange, _ keys: JPEGModelKeys, _ inc: Int, _ threshold: Int) throws -> Int {
        let s = try r.value(frequencies.p, keys.width); update(keys, s, inc, threshold); return s
    }
    @inline(__always) func magnitude(_ r: StuffItXJPEGRange, _ keys: JPEGModelKeys, _ inc: Int, _ threshold: Int) throws -> Int {
        let s = try symbol(r, keys, inc, threshold)
        if s < 6 { return s }
        if s < 15 { return try 5 + (1 << (s - 6)) + r.bits(s - 6) }
        return try 5 + r.bits(15)
    }
    func dcDist(_ c: Int, _ l: Int, _ u: Int, _ p: (Int, Int, Int, Int)) throws -> JPEGModelKeys {
        let (a,b,d,e) = p, diff1 = abs(a-b), diff2 = abs(b-d), bs = jpegBitLength(l) + jpegBitLength(u)
        let i0 = 56 * (c == 0 ? 0 : 1) + 8 * bs + jpegBitLength((diff1 / 4 + diff2 / 4 + abs(d-e) / 4 + abs(e-a) / 4) / 128)
        let i1 = bs * 36 + jpegBitLength(diff1 / 512) * 6 + jpegBitLength(diff2 / 512)
        let i2 = jpegBitLength(diff1 / 256) * 49 + jpegBitLength(abs(a-d) / 256) * 7 + jpegBitLength(abs(a-e) / 256)
        let i3 = 10 * (c == 0 ? 0 : 1) + jpegBitLength(diff1 / 32)
        // 112 / 364 / 707 は T.dc_starts[1...3]、重み (8,6,4,2) は T.dc_weights と同じ値を直書きしている。
        let keys = JPEGModelKeys(a: i0*16, b: (i1+112)*16, c: (i2+364)*16, d: (i3+707)*16, width: 16)
        try combine(keys, [4,4,4,4,3,3,3,3,2,2,2,2,1,1,1,1], (8,6,4,2)); return keys
    }
    @inline(__always) func dc(_ r: StuffItXJPEGRange, _ c: Int, _ l: Int, _ u: Int, _ p: (Int,Int,Int,Int)) throws -> Int {
        let keys = try dcDist(c,l,u,p)
        let v = try magnitude(r, keys, 8, 248)
        return try v != 0 && r.bit() == 0 ? -v : v
    }
    func hDist(_ c: Int, _ dc: Int, _ up: UnsafePointer<Int>, _ left: UnsafePointer<Int>, _ l: Int, _ u: Int, _ cb: Int, _ near: (Int,Int,Int,Int)) throws -> JPEGModelKeys {
        let dcbin = max(-8191, min(8191,dc)) / 1024 + 7
        let a = jpegActivity((abs(up[1])*10 + abs(left[0])*23) / 33 / 8)
        let avg = (near.0 + near.1 + near.2 + near.3 + 2) / 4, lh = l & 7, uh = u & 7
        let i0 = (c == 0 ? 0 : 1) << 9 | uh << 6 | lh << 3 | a
        let i1 = (c << 9) + (uh << 6) + (dcbin * 4 & ~7) + avg
        let i2 = c << 3 | (c == 2 ? cb & 7 : a)
        let i3 = (c << 7) + ((c == 2 ? cb & 7 : a) << 4) + dcbin
        // 1024 / 2560 / 2584 は T.horizontal_starts[1...3] と同じ値を直書きしている。
        let k = JPEGModelKeys(a: 0x2d70+i0*8, b: 0x2d70+(i1+1024)*8, c: 0x2d70+(i2+2560)*8, d: 0x2d70+(i3+2584)*8, width: 8)
        try combine(k,T.limit_base,(32,12,1,5))
        if up[0] == 0 { frequencies.p[uh] *= 2 }
        if c == 2 { frequencies.p[cb & 7] += frequencies.p[cb & 7] / 4 }
        return k
    }
    func vDist(_ c: Int, _ up: UnsafePointer<Int>, _ left: UnsafePointer<Int>, _ l: Int, _ u: Int, _ h: Int, _ cb: Int, _ near: (Int,Int,Int,Int)) throws -> JPEGModelKeys {
        let a = jpegActivity((abs(up[0])*23 + abs(left[1])*10) / 33 / 8)
        let avg = (near.0 + near.1 + near.2 + near.3 + 2) / 4, lv = l >> 3, uv = u >> 3, cv = cb >> 3
        let i0 = ((c == 0 ? 0 : 1)*512 + uv*64 + lv*8) | a
        let i1 = c*512 + lv*8 + cv + avg*64
        let i2 = (c*64 | a*8) + (c == 2 ? cv : h)
        let i3 = (c*512 | a*64) + h*8 + (c == 2 ? cv : lv)
        // 1024 / 2560 / 2752 は T.vertical_starts[1...3] と同じ値を直書きしている。
        let k = JPEGModelKeys(a: 0x8430+i0*8, b: 0x8430+(i1+1024)*8, c: 0x8430+(i2+2560)*8, d: 0x8430+(i3+2752)*8, width: 8)
        try combine(k,T.limit_base,c == 2 ? (20,8,12,2) : (20,8,6,24))
        if left[0] == 0 { frequencies.p[lv] *= 2 }
        if c == 2 { frequencies.p[cv] += frequencies.p[cv] / 4 }
        return k
    }
    func acDist(_ pos: Int, _ dq: UnsafePointer<Int16>, _ c: Int, _ cb: UnsafePointer<Int32>?, _ up: UnsafePointer<Int>, _ left: UnsafePointer<Int>, _ q: UnsafePointer<Int>, _ extent: Int, _ nv: Int, _ nh: Int, _ zx: UnsafePointer<Int>, _ zy: UnsafePointer<Int>, _ sizes: UnsafePointer<Int>, _ ln: UnsafePointer<Int32>?, _ un: UnsafePointer<Int32>?, _ urn: UnsafePointer<Int32>?) throws -> JPEGModelKeys {
        let y = pos / 8, x = pos & 7, h = extent & 7, v = extent >> 3
        let w1 = T.predictor_weights[pos], w2 = T.predictor_weights[x*8+y]
        let pn = abs(up[x])*w1 + abs(left[y])*w2, pw = w1+w2
        let direct = pw == 0 ? 0 : pn / (q[pos]*pw)
        var total = 0, weight = 0, sk = 0
        if x+1 < h && y != 0 { total += abs(Int(dq[pos-6])); weight += 1 }
        if x >= 2 && pos >= 11 { total += abs(Int(dq[pos-10])); weight += 1 }
        if x >= 2 && (y != 0 || x >= 3) { total += abs(Int(dq[pos-2]))*2; weight += 2; sk += sizes[pos-2] }
        if (x != 0 && y != 0) || (x > 1 && y == 0) { total += abs(Int(dq[pos-1]))*3; weight += 3; sk += sizes[pos-1] }
        if pos >= 9 { total += abs(Int(dq[pos-8]))*3; weight += 3; sk += sizes[pos-8] }
        if x < h && y != 0 { total += abs(Int(dq[pos-7]))*4; weight += 4; sk += sizes[pos-7] }
        if x != 0 && pos >= 10 { total += abs(Int(dq[pos-9]))*3; weight += 3 }
        if pos >= 17 { total += abs(Int(dq[pos-16]))*2; weight += 2; sk += sizes[pos-16] }
        if let cb { total += abs(Int(cb[pos])*q[pos])*20; weight += 20 }
        if let urn { total += abs(Int(urn[pos])*q[pos])*2; weight += 2 }
        if let un { total += abs(Int(un[pos])*q[pos])*4; weight += 4 }
        if let ln { total += abs(Int(ln[pos])*q[pos])*4; weight += 4 }
        total >>= 3
        if weight != 0 { total += pn >> 3; weight += pw }
        let edge: Int
        if pos == extent { edge = nv != 0 && nh != 0 ? 2 : 1 }
        else if y == v { edge = nv != 0 ? 4 : 3 }
        else if x == h { edge = nh != 0 ? 4 : 3 }
        else { edge = 0 }
        let av = weight != 0 ? jpegCategory((total << 4) / (q[pos]*weight)) : 0
        var fine = weight != 0 ? min(16383, total*24 / (q[pos]*weight)) : 0
        if fine >= 8 { fine = 8 + jpegBitLength(fine-8) }
        let cc = c == 0 ? 0 : 1, group = edge*512 + T.ac_positions[64*cc+pos]*16
        let aux = abs(jpegI16(cb.map { Int($0[pos]) } ?? direct))
        let auxbin = aux < 2 ? 0 : aux < 4 ? 1 : aux < 10 ? 2 : aux < 37 ? 3 : aux <= 144 ? 4 : 5
        let i0 = group+av, i1 = 2560 + 21*(pos+64*cc) + sk + (edge & 1)*2688 + auxbin
        let i2 = 7936 + fine*2 + (edge & 1), i3 = 7984 + group + jpegCategory(direct >> 1)
        let k = JPEGModelKeys(a: 0x10a30+i0*16, b: 0x10a30+i1*16, c: 0x10a30+i2*16, d: 0x10a30+i3*16, width: 16)
        let wi = cc*64+pos
        try combine(k,edge != 0 ? T.ac_edge_base : T.ac_base,(T.ac_weights[wi]&255,T.ac_weights[128+wi]&255,T.ac_weights[256+wi]&255,T.ac_weights[384+wi]&255))
        frequencies.p[0] = frequencies.p[0] * T.zero_weights[zx[x]*8+zy[y]] / 16
        if pos == extent && (nv == 0 || nh == 0) { frequencies.p[0] = 0 }
        return k
    }
    func signDist(_ pos: Int, _ co: UnsafePointer<Int32>, _ c: Int, _ hint: Int, _ up: UnsafePointer<Int>, _ left: UnsafePointer<Int>, _ q: UnsafePointer<Int>, _ ln: UnsafePointer<Int32>?, _ un: UnsafePointer<Int32>?) throws -> JPEGModelKeys {
        let y = pos / 8, x = pos & 7
        func sc(_ n: Int) -> Int { n < 0 ? 0 : n == 0 ? 1 : 2 }
        let vert = pos >= 17 ? sc(Int(co[pos-16])) : un.map { sc(jpegI16(Int($0[pos])-Int($0[pos+8])+Int($0[pos+16])-Int($0[pos+24]))) } ?? 0
        let hor = x >= 2 && pos >= 3 ? sc(Int(co[pos-2])) : ln.map { sc(jpegI16(Int($0[pos])-Int($0[pos+1])+Int($0[pos+2])-Int($0[pos+3]))) } ?? 0
        let chosen = x < y ? left[y] : up[x], pred1 = up[x]/q[pos], pred2 = left[y]/q[pos]
        let chosenQ = x < y ? pred2 : pred1
        let sclass = sc(jpegI16(Int(UInt32(truncatingIfNeeded: chosen) >> 3))), mclass = jpegCat4(Int(co[pos]))
        let combined = mclass*3+sclass, i0 = vert+hor*3, i1 = combined*4 | jpegCat4(jpegI16(chosenQ))
        let i2 = (c == 0 ? 0 : 2700) + min(y,4)*5 + min(x,4) + (vert+hor*3)*25 + combined*225
        // 9 / 57 は T.sign_starts[1...2]、重み (3,2,7) は T.sign_weights と同じ値を直書きしている。
        let k = JPEGModelKeys(a: i0*2, b: (i1+9)*2, c: (i2+57)*2, d: 0, width: 2, sign: true)
        try combine(k,[8,8],(3,2,7,0))
        if x+y <= 11 {
            var e0 = 0, e1 = 0
            func extra(_ pred: Int, _ value: Int) {
                let delta = abs(abs(pred)-abs(Int(co[pos]))), close = delta < 3 ? 3 : delta < 9 ? 2 : delta < 32 ? 1 : 0
                if pred != 0 && close != 0 {
                    let amp = abs(value >> 3), at = amp <= 64 ? T.sign_at2[amp] : 14
                    let add = frequencies.p[pred > 0 ? 1 : 0]*close*at/32
                    if value > 0 { e1 += add } else { e0 += add }
                }
            }
            extra(pred1,up[x]); extra(pred2,left[y]); frequencies.p[0] += e0; frequencies.p[1] += e1
            if hint < 2 {
                let amp = abs(Int(co[pos])), at = amp <= 128 ? T.sign_at0[amp] : 14
                frequencies.p[hint] += frequencies.p[hint]/6*T.sign_factor[pos] + frequencies.p[hint]/2*at
            }
        }
        return k
    }
}

@inline(__always) func jpegEdgePredictor(_ block: UnsafePointer<Int16>, _ stride: Int) -> Int {
    var value = 0
    for i in 1..<8 { value += (i & 1 == 1 ? -1 : 1)*Int(block[i*stride]) }
    if abs(value) <= 2047 { value += value/4 }
    return max(-8191,min(8191,Int(block[0])+value))
}
func jpegDCPrediction(_ left: UnsafePointer<Int16>?, _ up: UnsafePointer<Int16>?, _ dl: UnsafePointer<Int16>?, _ ur: UnsafePointer<Int16>?, _ ul: Int, _ q: Int) -> (Int,(Int,Int,Int,Int)) {
    typealias T = StuffItXJPEGTables
    guard let left else {
        guard let up else { return (0,(0,0,0,0)) }
        let u = jpegEdgePredictor(up,8); return (jpegI16(u/q),(0,u,2048,3072))
    }
    guard let up else { let l = jpegEdgePredictor(left,1); return (jpegI16(l/q),(l,1024,2048,3072)) }
    let l = jpegEdgePredictor(left,1), u = jpegEdgePredictor(up,8)
    var wu = T.dc_wlt[jpegBitLength(abs(Int(left[0])-ul) >> 6)]+1
    var wl = T.dc_wlt[jpegBitLength(abs(Int(up[0])-ul) >> 6)]+1
    let urp = ur.map { jpegEdgePredictor($0,8) } ?? (u + jpegEdgePredictor(up,1)-Int(up[0])+Int(up[9]))
    let dlp = dl.map { jpegEdgePredictor($0,1) } ?? (jpegEdgePredictor(left,8)+l-Int(left[0])+Int(left[9]))
    let urdc = Int((ur ?? up)[0]), dldc = Int((dl ?? left)[0])
    var wur = 4*T.dc_wl1[jpegBitLength(abs(urdc-l)/q)], wdl = 4*T.dc_wl1[jpegBitLength(abs(dldc-u)/q)]
    wu += wdl; wl += wur
    let cross = T.dc_wl2[jpegBitLength(abs(dldc-urdc)/q)]; wdl += cross
    if Int(up[0]) == u { wu *= 2; wl = (wl+1)/2; wur = 0 } else { wur += cross }
    if Int(left[0]) == l { wl *= 2 }
    return (jpegI16((u*wu+l*wl+urp*wur+dlp*wdl) / ((wu+wl+wur+wdl)*q)),(l,u,urp,dlp))
}
@inline(__always) func jpegDirectionalPrediction(_ block: UnsafePointer<Int16>, _ start: Int, _ stride: Int, _ profile: Int) -> Int {
    var value = 0
    for i in 0..<8 { value += (i & 1 == 1 ? -1 : 1) * ((Int(block[start+i*stride])*StuffItXJPEGTables.factors[profile*8+i]) >> 4) }
    return max(-8191,min(8191,value))
}
