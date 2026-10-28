// 凍結 7z / decode-ab の返却 byte 数・digest・error を、保存した二つの build で照合する。
// 引数: corpus を置いた作業 directory、出力 JSONL。repository root から実行する。
import Foundation
import CryptoKit
import KaitoKit

struct Entry: Codable { let index: Int; let count: Int; let digest: String; let error: String? }
struct Outcome: Codable { let path: String; let mutation: String; let threads: Int; let buffer: Int; let entries: [Entry]; let error: String? }
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let frozen = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/Fixtures/sevenzip-edit")
var paths = try FileManager.default.contentsOfDirectory(at: frozen, includingPropertiesForKeys: nil).filter { $0.pathExtension == "7z" }
paths += try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("corpus/archives"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "7z" }
paths.sort { $0.path < $1.path }
FileManager.default.createFile(atPath: output.path, contents: nil)
let handle = try FileHandle(forWritingTo: output)
let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
var cases = 0
for path in paths {
    let original = try Data(contentsOf: path)
    var variants: [(String, Data)] = [("original", original)]
    if ["g_plain", "m", "s200", "z_default", "z_plainhdr", "z_nonsolid", "bcj", "zero_lzma2"].contains(path.deletingPathExtension().lastPathComponent) {
        for amount in [1, 7, max(1, original.count / 2)] { variants.append(("truncate-\(amount)", original.dropLast(amount))) }
        for offset in Set([32, 33, 38, original.count / 4, original.count / 2, original.count - 1]).sorted() where offset < original.count {
            for bit: UInt8 in [1, 128] {
                var bytes = original; bytes[offset] ^= bit; variants.append(("flip-\(offset)-\(bit)", bytes))
            }
            var bytes = original; bytes.replaceSubrange(offset..<min(offset + 8, bytes.count), with: repeatElement(UInt8(0), count: min(8, bytes.count - offset)))
            variants.append(("zero-\(offset)", bytes))
        }
    }
    for (mutation, bytes) in variants {
        for threads in [1, 16] {
            for size in (mutation == "original" ? [4099] : [1, 4099, 65536]) {
                var entries: [Entry] = []; var outer: String?
                do {
                    let password = path.path.contains("/corpus/") ? "decode-ab-password" : "secret"
                    let reader = try ArchiveReader.open(data: bytes, options: ReaderOptions(password: password, decodeThreads: threads))
                    for (index, entry) in reader.entries.enumerated() {
                        var count = 0; var digest = SHA256(); var failure: String?
                        do {
                            if path.lastPathComponent == "mix.7z" { reader.password = entry.name == "b.bin" ? "secret2" : "secret" }
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
                let result = Outcome(path: path.lastPathComponent, mutation: mutation, threads: threads, buffer: size, entries: entries, error: outer)
                try handle.write(contentsOf: encoder.encode(result)); try handle.write(contentsOf: Data([10])); cases += 1
            }
        }
    }
}
try handle.close()
print("outcomes \(cases)")
