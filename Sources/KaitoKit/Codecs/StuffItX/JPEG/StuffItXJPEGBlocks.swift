// mode-2 の係数 block: plane 配置と近傍を保持する JPEGBlockStore、一 block を復号する StuffItXJPEGBlocks。
// 出典: stuffitx_jpeg_models.py の Blocks を移植。
import Foundation

// baseline は二行、progressive は量子化係数のみ全 plane を保持する。
// 行タグにより、再利用領域の古い値を存在する近傍と取り違えない。
struct JPEGPlaneLayout {
    var width = 0
    var height = 0
    var offset = 0
    var ring = 0
}
final class JPEGBlockStore {
    let layout = JPEGStorage<JPEGPlaneLayout>(3, JPEGPlaneLayout())
    let coefficients: JPEGStorage<Int32>
    let dequantized: JPEGStorage<Int16>
    let extents: JPEGStorage<Int>
    let tags: JPEGStorage<Int>
    let present: JPEGStorage<UInt8>
    let keepAll: Bool
    let componentCount: Int
    let blockCount: Int
    var decoded = 0
    init(_ geometry: JPEGGeometry, keepAll: Bool, limits: ReadLimits) throws {
        self.keepAll = keepAll; componentCount = geometry.components.count; blockCount = geometry.blocks
        guard blockCount <= limits.maxJPEGBlocks else { throw KaitoError.limitExceeded("StuffIt X JPEG coefficient blocks") }
        var full = 0, ring = 0
        for c in 0..<componentCount {
            let properties = geometry.components[c], width = geometry.width * properties.horizontal, height = geometry.height * properties.vertical
            layout.p[c] = JPEGPlaneLayout(width: width,height: height,offset: full,ring: ring)
            full += width*height; ring += width*2
        }
        coefficients = JPEGStorage<Int32>((keepAll ? full : ring)*64,0)
        dequantized = JPEGStorage<Int16>(ring*64,0)
        extents = JPEGStorage<Int>(keepAll ? full : ring,0); tags = JPEGStorage<Int>(ring,-1)
        present = JPEGStorage<UInt8>(keepAll ? full : 0,0)
    }
    @inline(__always) func index(_ c: Int, _ row: Int, _ col: Int) -> Int? {
        guard c >= 0, c < componentCount else { return nil }
        let l = layout.p[c]
        guard row >= 0, row < l.height, col >= 0, col < l.width else { return nil }
        let i = l.ring + (row & 1)*l.width + col
        return tags.p[i] == row ? i : nil
    }
    @inline(__always) func co(_ c: Int, _ row: Int, _ col: Int) -> UnsafePointer<Int32>? {
        if keepAll {
            guard let i = fullIndex(c,row,col), present.p[i] != 0 else { return nil }
            return UnsafePointer(coefficients.p+i*64)
        }
        return index(c,row,col).map { UnsafePointer(coefficients.p+$0*64) }
    }
    @inline(__always) func dq(_ c: Int, _ row: Int, _ col: Int) -> UnsafePointer<Int16>? {
        index(c,row,col).map { UnsafePointer(dequantized.p.advanced(by:$0*64)) }
    }
    @inline(__always) func extent(_ c: Int, _ row: Int, _ col: Int) -> Int {
        if keepAll {
            guard let i = fullIndex(c,row,col), present.p[i] != 0 else { return 0 }
            return extents.p[i]
        }
        return index(c,row,col).map { extents.p[$0] } ?? 0
    }
    @inline(__always) func fullIndex(_ c: Int, _ row: Int, _ col: Int) -> Int? {
        guard c >= 0, c < componentCount else { return nil }
        let l = layout.p[c]
        guard row >= 0, row < l.height, col >= 0, col < l.width else { return nil }
        return l.offset+row*l.width+col
    }
    func commit(_ c: Int, _ row: Int, _ col: Int, _ ring: Int, _ extent: Int) {
        tags.p[ring] = row
        let i = keepAll ? layout.p[c].offset+row*layout.p[c].width+col : ring
        extents.p[i] = extent
        if keepAll { present.p[i] = 1 }; decoded += 1
    }
    func prepare(_ c: Int, _ row: Int, _ col: Int) throws -> (UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int16>, Int) {
        guard c >= 0, c < componentCount, decoded < blockCount else { throw jpegMalformed("coefficient coordinates") }
        let l = layout.p[c]
        guard row >= 0, row < l.height, col >= 0, col < l.width else { throw jpegMalformed("coefficient coordinates") }
        let i = l.ring + (row & 1)*l.width + col
        guard tags.p[i] != row else { throw jpegMalformed("duplicate coefficient block") }
        let co = coefficients.p.advanced(by:(keepAll ? l.offset+row*l.width+col : i)*64), dq = dequantized.p.advanced(by:i*64)
        co.update(repeating:0,count:64); dq.update(repeating:0,count:64)
        return (co,dq,i)
    }
    @inline(__always) func full(_ c: Int, _ row: Int, _ col: Int) -> UnsafePointer<Int32> {
        let l = layout.p[c]
        return UnsafePointer(coefficients.p.advanced(by:(l.offset+row*l.width+col)*64))
    }
}

final class StuffItXJPEGBlocks {
    let decoder: StuffItXJPEGRange
    let model = StuffItXJPEGModel()
    let store: JPEGBlockStore
    let scratch = JPEGStorage<Int>(8*4+64,0)
    init(_ decoder: StuffItXJPEGRange, geometry: JPEGGeometry, keepAll: Bool, limits: ReadLimits) throws {
        self.decoder = decoder; store = try JPEGBlockStore(geometry,keepAll:keepAll,limits:limits)
    }
    func block(_ c: Int, _ row: Int, _ col: Int, _ q: UnsafePointer<Int>, _ hint: Int, _ profile: Int) throws -> UnsafePointer<Int32> {
        let left = store.dq(c,row,col-1), up = store.dq(c,row-1,col)
        let ur = hint != 3 ? store.dq(c,row-1,col+1) : nil, dl = hint == 0 ? store.dq(c,row+1,col-1) : nil
        guard !(col > 0 && left == nil), !(row > 0 && up == nil) else { throw jpegMalformed("missing coefficient neighbor") }
        let ul = row > 0 && col > 0 && hint != 0 ? Int(store.dq(c,row-1,col-1)?[0] ?? 0) : 0
        let (pred,contexts) = jpegDCPrediction(left,up,dl,ur,ul,q[0])
        let le = store.extent(c,row,col-1), ue = store.extent(c,row-1,col)
        let cb = c == 2 ? store.co(c-1,row,col) : nil, ce = c == 2 ? store.extent(c-1,row,col) : 0
        let ln = store.co(c,row,col-1), un = store.co(c,row-1,col), urn = hint != 3 ? store.co(c,row-1,col+1) : nil
        let near = (le,ue,store.extent(c,row,col-2),hint != 3 ? store.extent(c,row-1,col+1) : 0)
        let (co,dq,index) = try store.prepare(c,row,col)
        let upPred = scratch.p, leftPred = upPred+8, zx = leftPred+8, zy = zx+8, sizes = zy+8
        scratch.p.update(repeating:0,count:scratch.count)
        co[0] = Int32(try jpegI16(pred + model.dc(decoder,c,max(le&7,le>>3),max(ue&7,ue>>3),contexts)))
        dq[0] = Int16(truncatingIfNeeded:Int(co[0])*q[0])
        if let up {
            for i in 0..<8 { upPred[i] = jpegDirectionalPrediction(up,i,8,profile) }
            upPred[0] -= Int(dq[0])
        }
        if let left {
            for i in 0..<8 { leftPred[i] = jpegDirectionalPrediction(left,i*8,1,profile) }
            leftPred[0] -= Int(dq[0])
        }
        let hk = try model.hDist(c,Int(dq[0]),upPred,leftPred,le,ue,ce,(near.0&7,near.1&7,near.2&7,near.3&7))
        let h = try model.symbol(decoder,hk,2,64)
        let vk = try model.vDist(c,upPred,leftPred,le,ue,h,ce,(near.0>>3,near.1>>3,near.2>>3,near.3>>3))
        let v = try model.symbol(decoder,vk,2,64), extent = h+8*v
        sizes[0] = jpegCat4(Int(co[0]))
        var nv = 0, nh = 0
        for y in 0...v {
            for x in 0...h {
                let pos = y*8+x
                if pos == 0 { continue }
                let ak = try model.acDist(pos,dq,c,cb,upPred,leftPred,q,extent,nv,nh,zx,zy,sizes,ln,un,urn)
                // magnitude の escape は 32772 まで。符号判定前は Int で保持する。
                let magnitude = try model.magnitude(decoder,ak,2,160)
                co[pos] = Int32(magnitude)
                if magnitude != 0 {
                    zx[x] = 0; zy[y] = 0; nv += y == v ? 1 : 0; nh += x == h ? 1 : 0
                    let selected = y > x ? upPred[x] : leftPred[y]
                    let signHint = left != nil && up != nil && abs(selected) >= 43 ? (selected > 0 ? 1 : 0) : 2
                    let sk = try model.signDist(pos,co,c,signHint,upPred,leftPred,q,ln,un)
                    if try model.symbol(decoder,sk,6,129) == 0 { co[pos] = -co[pos] }
                    sizes[pos] = jpegCat4(Int(co[pos])); dq[pos] = Int16(truncatingIfNeeded:Int(co[pos])*q[pos])
                    if up != nil { upPred[x] -= (Int(dq[pos])*StuffItXJPEGTables.factors[profile*8+y]) >> 4 }
                    if left != nil { leftPred[y] -= (Int(dq[pos])*StuffItXJPEGTables.factors[profile*8+x]) >> 4 }
                } else { zx[x] += 1; zy[y] += 1 }
            }
        }
        store.commit(c,row,col,index,extent)
        return UnsafePointer(co)
    }
}
