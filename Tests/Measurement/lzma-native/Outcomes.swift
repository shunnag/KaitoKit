// 同一 executable の Swift/native を別 process で照合する。外部 oracle は不要。
import Foundation
import CryptoKit
import KaitoKit

struct Entry: Codable { let index: Int; let count: Int; let digest: String; let error: String? }
struct Outcome: Codable { let path: String; let buffer: Int; let entries: [Entry]; let error: String? }
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let roots = CommandLine.arguments.dropFirst(2).map { URL(fileURLWithPath: $0) }
let paths = try roots.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }.sorted { $0.path < $1.path }
FileManager.default.createFile(atPath: output.path, contents: nil)
let handle = try FileHandle(forWritingTo: output)
let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
let limits = ReadLimits(maxEntrySize: 16 * 1024 * 1024, maxTotalUncompressedSize: 32 * 1024 * 1024,
    maxDictionarySize: 64 * 1024 * 1024)
var cases = 0
for path in paths {
    let bytes = try Data(contentsOf: path)
    for size in [1, 4099, 65536] {
        var entries: [Entry] = []; var outer: String?
        do {
            let reader = try ArchiveReader.open(data: bytes, options: ReaderOptions(limits: limits, decodeThreads: 1))
            for (index, entry) in reader.entries.enumerated() {
                var count = 0; var digest = SHA256(); var failure: String?
                do {
                    let stream = try reader.stream(entry)
                    var buffer = [UInt8](repeating: 0, count: size)
                    while true {
                        let n = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
                        if n == 0 { break }
                        count += n; digest.update(data: buffer.prefix(n))
                    }
                } catch { failure = String(reflecting: error) }
                entries.append(Entry(index: index, count: count, digest: digest.finalize().map { String(format: "%02x", $0) }.joined(), error: failure))
            }
        } catch { outer = String(reflecting: error) }
        let result = Outcome(path: path.lastPathComponent, buffer: size, entries: entries, error: outer)
        try handle.write(contentsOf: encoder.encode(result)); try handle.write(contentsOf: Data([10])); cases += 1
    }
}
try handle.close()
print("outcomes \(cases)")
