import Foundation
import CryptoKit
@_silgen_name("kk_alloc_start") func allocStart()
@_silgen_name("kk_alloc_stop") func allocStop()
@_silgen_name("kk_alloc_count") func allocCount() -> UInt64
@_silgen_name("kk_alloc_bytes") func allocBytes() -> UInt64
@main struct Probe {
 static func main() throws {
  for n in [200,512,10000,100000] {
   let names = (0..<n).map { Array("画像/ページ\($0).jpg".data(using: .shiftJIS)!) }
   for mode in ["score", "decode"] {
    if mode == "score" && n > 512 { continue }
    func run() -> String {
     if mode == "score" { return String(describing: EncodingDetector.detectArchiveEncoding(names:names,policy:.automatic())) }
     let decoded = EncodingDetector.decodeArchiveNames(names,as:.shiftJIS)
     return String(decoded.reduce(0) { $0 + ($1?.utf8.count ?? 0) })
    }
    _ = run()
    for _ in 0..<5 {
     allocStart(); let start=ContinuousClock.now; let result=run(); let dt=start.duration(to:ContinuousClock.now); allocStop()
     print("\(mode)\t\(n)\t\(Double(dt.components.seconds)*1000+Double(dt.components.attoseconds)/1e15)\t\(allocCount())\t\(allocBytes())\t\(result)")
    }
   }
  }
 }
}
