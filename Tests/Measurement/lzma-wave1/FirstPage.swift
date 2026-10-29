// 同じ書庫の先頭 file を 7 回読み、open から最初の entry 完了までの中央値を出す。
// 引数: archive path、decode threads。返却 byte の digest も記録する。
import Foundation
import CryptoKit
import KaitoKit
let path = URL(fileURLWithPath: CommandLine.arguments[1])
let threads = Int(CommandLine.arguments[2])!
var times: [Double] = []
var digest = "", count = 0
for _ in 0..<7 {
    Thread.sleep(forTimeInterval: 0.1)
    try autoreleasepool {
        let start = DispatchTime.now().uptimeNanoseconds
        let reader = try ArchiveReader.open(url: path, options: ReaderOptions(decodeThreads: threads))
        let entry = reader.entries.first { $0.kind == .file }!
        let bytes = try reader.read(entry)
        times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        count = bytes.count
    }
}
print("\(path.lastPathComponent) threads=\(threads) first-page-ms=\(times.sorted()[times.count/2]) bytes=\(count) sha256=\(digest) samples=\(times)")
