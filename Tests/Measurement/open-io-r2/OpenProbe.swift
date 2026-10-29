import Foundation
import CryptoKit
import KaitoKit
@_silgen_name("kk_alloc_start") func allocStart()
@_silgen_name("kk_alloc_stop") func allocStop()
@_silgen_name("kk_alloc_count") func allocCount() -> UInt64
@_silgen_name("kk_alloc_bytes") func allocBytes() -> UInt64
final class Source: ByteSource, @unchecked Sendable {
    let data: Data
    var calls = 0, bytes = 0
    let modeled: Bool
    var length: UInt64 { UInt64(data.count) }
    init(_ path: String, modeled: Bool) throws {
        data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        self.modeled = modeled
    }
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        let n = min(buffer.count, max(0, data.count - Int(offset)))
        calls += 1; bytes += n
        if modeled { usleep(useconds_t(500 + Double(n) / 110)) }
        if n > 0 { data.withUnsafeBytes { buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0[Int(offset)..<Int(offset)+n])) } }
        return n
    }
}
let args = CommandLine.arguments
let source = try Source(args[1], modeled: args.contains("model"))
var options = ReaderOptions()
options.inputLatency = args.contains("high") ? .high : .low
if args.contains("fixed") { options.encodingPolicy = .fixed(.shiftJIS) }
if let limit = args.first(where: { $0.hasPrefix("metadata=") }).flatMap({ UInt64($0.dropFirst(9)) }) {
    options.limits.maxMetadataSize = limit
}
let clock = ContinuousClock()
// Warm process-global initialization outside measurement.
_ = try ArchiveReader.open(source: source, options: options)
source.calls = 0; source.bytes = 0
allocStart()
let start = clock.now
let reader = try ArchiveReader.open(source: source, options: options)
let elapsed = start.duration(to: clock.now)
allocStop()
let allocations = allocCount(), allocatedBytes = allocBytes()
var hash = SHA256()
func add(_ s: String) { hash.update(data: Data(s.utf8)); hash.update(data: Data([0])) }
add(String(describing: reader.nameEncoding?.rawValue))
for e in reader.entries {
    add("\(e.index)|\(e.name)|\(e.pathComponents)|\(e.kind)|\(String(describing:e.uncompressedSize))|\(String(describing:e.compressedSize))|\(String(describing:e.modificationDate))|\(String(describing:e.posixPermissions))|\(e.isEncrypted)|\(e.solidGroup)|\(String(describing:e.crc32))|\(e.methodDescription)|\(e.isIncomplete)")
    hash.update(data: Data(e.rawName.bytes))
    add(String(describing: e.rawName.declaredEncoding?.rawValue))
    for k in e.formatSpecific.keys.sorted() { add(k); add(e.formatSpecific[k]!) }
}
let ms = Double(elapsed.components.seconds)*1000 + Double(elapsed.components.attoseconds)/1e15
let row: [String:Any] = ["file":URL(fileURLWithPath:args[1]).lastPathComponent,"ms":ms,"allocations":allocations,"allocatedBytes":allocatedBytes,"reads":source.calls,"readBytes":source.bytes,"entries":reader.entries.count,"nameEncoding":String(describing:reader.nameEncoding),"digest":hash.finalize().map{String(format:"%02x",$0)}.joined()]
print(String(decoding:try JSONSerialization.data(withJSONObject:row,options:.sortedKeys),as:UTF8.self))
