import Foundation
import CryptoKit
import KaitoKit

// Compare independently linked HEAD/candidate decoders through the public API.
// Sources: KaitoKit fixtures and 7zz-generated archives; no external decoder source.
struct Entry: Codable { let index: Int; let count: Int; let digest: String; let error: String? }
struct Outcome: Codable { let path: String; let mutation: String; let buffer: Int; let entries: [Entry]; let error: String? }
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let fixtures = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/Fixtures")
var paths = [fixtures.appendingPathComponent("sevenzip-edit/ppmd.7z")]
paths += try FileManager.default.contentsOfDirectory(at: fixtures.appendingPathComponent("zip-ppmd"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "b64" }
paths += [fixtures.appendingPathComponent("rar4/r0-ppmd-solid.rar.b64"), fixtures.appendingPathComponent("rar4/ppmd_lorem_rar300.rar.b64")]
let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("corpus/manifest.json"))) as! [String: Any]
paths += (manifest["archives"] as! [[String: Any]]).compactMap {
    let path = $0["path"] as! String
    return path.contains("ppmd") ? root.appendingPathComponent("corpus/" + path) : nil
}
paths += ["text", "color", "jpeg"].flatMap { name in ["7z", "zip"].map { root.appendingPathComponent(name + "." + $0) } }
paths.sort { $0.path < $1.path }
FileManager.default.createFile(atPath: output.path, contents: nil)
let handle = try FileHandle(forWritingTo: output)
let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
var cases = 0
for path in paths {
    let stored = try Data(contentsOf: path)
    let original = path.pathExtension == "b64" ? Data(base64Encoded: stored, options: .ignoreUnknownCharacters)! : stored
    var variants: [(String, Data)] = [("original", original)]
    // Small frozen fixtures cover container errors and mutations in packed data.
    // Generated corpus streams also exercise recovery after long model updates.
    if path.path.contains("/Fixtures/") || path.lastPathComponent.contains("ppmd") {
        for amount in Set([1, 7, max(1, original.count / 2), max(1, original.count - 32)]).sorted() {
            variants.append(("truncate-\(amount)", Data(original.dropLast(amount))))
        }
        for offset in Set([32, 33, 38, original.count / 4, original.count / 2, original.count - 1]).sorted() where offset < original.count {
            for bit: UInt8 in [1, 128] {
                var bytes = original; bytes[offset] ^= bit; variants.append(("flip-\(offset)-\(bit)", bytes))
            }
        }
    }
    for (mutation, bytes) in variants {
        for size in (mutation == "original" ? [4099] : [1, 4099, 262144]) {
            var entries: [Entry] = []; var outer: String?
            do {
                let reader = try ArchiveReader.open(data: bytes, options: ReaderOptions(decodeThreads: 1))
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
            try handle.write(contentsOf: encoder.encode(Outcome(path: path.lastPathComponent, mutation: mutation, buffer: size, entries: entries, error: outer)))
            try handle.write(contentsOf: Data([10])); cases += 1
        }
    }
}
try handle.close()
print("outcomes \(cases)")
