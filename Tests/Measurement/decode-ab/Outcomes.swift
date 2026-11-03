import Foundation
import CryptoKit
import KaitoKit

struct EntryOutcome: Codable {
    let index: Int
    let name: String
    let count: Int
    let digest: String
    let error: String?
}

struct ArchiveOutcome: Codable {
    let archive: String
    let mutation: String
    let threads: String
    let buffer: Int
    let entries: [EntryOutcome]
    let error: String?
}

func loadManifest(_ url: URL) throws -> (root: URL, records: [[String: Any]]) {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    guard let dictionary = object as? [String: Any], let records = dictionary["archives"] as? [[String: Any]] else {
        throw KaitoError.malformed("decode-ab manifest")
    }
    return (url.deletingLastPathComponent(), records)
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    throw KaitoError.malformed("usage: Outcomes MANIFEST OUTPUT [original|mutations] [selection ...]")
}
let manifestURL = URL(fileURLWithPath: arguments[1])
let (root, records) = try loadManifest(manifestURL)
let mode = arguments.count >= 4 ? arguments[3] : "original"
guard mode == "original" || mode == "mutations" else {
    throw KaitoError.malformed("mode must be original or mutations")
}
let selections = arguments.count >= 5 ? Array(arguments.dropFirst(4)) : []
let selected = try records.filter { record in
    guard let path = record["path"] as? String else { throw KaitoError.malformed("archive path") }
    return selections.isEmpty || selections.contains { path.contains($0) }
}
let output = URL(fileURLWithPath: arguments[2])
FileManager.default.createFile(atPath: output.path, contents: nil)
let handle = try FileHandle(forWritingTo: output)
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
var cases = 0

for record in selected {
    guard let relativePath = record["path"] as? String else { continue }
    let archiveURL = root.appendingPathComponent(relativePath)
    let original = try Data(contentsOf: archiveURL)
    var variants: [(String, Data)] = [("original", original)]
    if mode == "mutations" {
        for amount in Set([1, 7, max(1, original.count / 2), max(1, original.count - 32)]).sorted() {
            variants.append(("truncate-\(amount)", Data(original.dropLast(amount))))
        }
        for offset in Set([0, 32, 33, 38, original.count / 4, original.count / 2, original.count - 1]).sorted()
        where offset < original.count {
            for bit: UInt8 in [1, 128] {
                var bytes = original
                bytes[offset] ^= bit
                variants.append(("flip-\(offset)-\(bit)", bytes))
            }
        }
    }
    let threadOptions = mode == "original" ? ["auto", "1", "3", "16"] : ["auto"]
    let bufferOptions = mode == "original" ? [1, 4099, 65536] : [4099]
    for (mutation, bytes) in variants {
        for thread in threadOptions {
            for bufferSize in bufferOptions {
                var entries: [EntryOutcome] = []
                var outerError: String?
                do {
                    var options = ReaderOptions(password: record["password"] as? String,
                                                decodeThreads: thread == "auto" ? nil : Int(thread))
                    options.scanForSFXInData = true
                    let reader = mutation == "original"
                        ? try ArchiveReader.open(url: archiveURL, options: options)
                        : try ArchiveReader.open(data: bytes, options: options)
                    for (index, entry) in reader.entries.enumerated() {
                        var count = 0
                        var digest = SHA256()
                        var failure: String?
                        do {
                            let stream = try reader.stream(entry)
                            var buffer = [UInt8](repeating: 0, count: bufferSize)
                            while true {
                                let amount = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
                                if amount == 0 { break }
                                count += amount
                                digest.update(data: buffer.prefix(amount))
                            }
                        } catch {
                            failure = String(reflecting: error)
                        }
                        entries.append(EntryOutcome(index: index, name: entry.name, count: count,
                            digest: digest.finalize().map { String(format: "%02x", $0) }.joined(), error: failure))
                    }
                } catch {
                    outerError = String(reflecting: error)
                }
                let result = ArchiveOutcome(archive: relativePath, mutation: mutation, threads: thread,
                                            buffer: bufferSize, entries: entries, error: outerError)
                try handle.write(contentsOf: encoder.encode(result))
                try handle.write(contentsOf: Data([10]))
                cases += 1
            }
        }
    }
}
try handle.close()
print("outcomes \(cases)")
