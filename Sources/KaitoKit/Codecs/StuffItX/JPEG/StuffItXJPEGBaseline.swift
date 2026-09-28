// mode-2 baseline JPEG の復元: 係数を MCU 行ごとに復号し、baseline の Huffman 符号と restart marker で出力する。
// 出典: stuffitx_jpeg_baseline.py の decode_baseline の走査を移植。
import Foundation

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
        guard frame.marker == JPEGMarker.sof0 else { throw jpegUnsupported("mode-2 baseline JPEG required") }
        guard scan.ss == 0, scan.se == 63, scan.ah == 0, scan.al == 0 else { throw jpegMalformed("unsupported baseline scan") }
        geometry = try JPEGGeometry(frame,limits:limits)
        guard scan.components.map(\.id).sorted() == geometry.components.map(\.id) else { throw jpegUnsupported("single interleaved scan required") }
        let tables = try JPEGTableSet(prefix); restart = tables.restart
        for (c,properties) in geometry.components.enumerated() {
            let selector = scan.components.first { $0.id == properties.id }!.selector
            guard let dc = tables.huffman[JPEGTableSet.dcTableKey(selector)],
                  let ac = tables.huffman[JPEGTableSet.acTableKey(selector)] else { throw jpegMalformed("undefined Huffman table") }
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
                try entropy.finish(); try entropy.output.append(JPEGMarker.prefix)
                try entropy.output.append(JPEGMarker.rst.lowerBound+restarts%8)
                restarts += 1; previousDC.p.update(repeating:0,count:3)
            }
        }
        row += 1
        if done { try entropy.finish { try self.blocks.decoder.bit() } }
    }
}
