import CryptoKit
import Darwin
import Dispatch
import Foundation
import KaitoKit

private enum CLIError: Error, CustomStringConvertible {
    case usage(String)

    var description: String {
        switch self {
        case .usage(let message):
            return message
        }
    }
}

private let usage = """
usage:
  kaito detect <archive>
  kaito list <archive> [--raw] [-p <password>]
  kaito extract <archive> -o <directory> [-p <password>]
  kaito sha <archive> [-p <password>]
  kaito bench [--data] [--random] <archive> [reps] [-p <password>]
"""

private func formatName(_ format: ArchiveFormat) -> String {
    switch format {
    case .zip: return "zip"
    case .rar: return "rar"
    case .sevenZip: return "7z"
    case .lha: return "lha"
    case .tar: return "tar"
    case .iso: return "iso"
    case .xar: return "xar"
    case .cab: return "cab"
    case .rpm: return "rpm"
    case .ar: return "ar"
    case .cpio: return "cpio"
    case .gzip: return "gzip"
    case .bzip2: return "bzip2"
    case .xz: return "xz"
    case .lzma: return "lzma"
    case .compress: return "compress"
    }
}

private func kindName(_ kind: EntryKind) -> String {
    switch kind {
    case .file: return "file"
    case .directory: return "directory"
    case .symlink: return "symlink"
    case .hardlink: return "hardlink"
    case .other: return "other"
    }
}

private func hexadecimal<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
}

private func oneLine(_ value: String) -> String {
    var result = ""
    result.reserveCapacity(value.utf8.count)
    for scalar in value.unicodeScalars {
        switch scalar.value {
        case 0x5c:
            result.append("\\\\")
        case 0x09:
            result.append("\\t")
        case 0x0a:
            result.append("\\n")
        case 0x0d:
            result.append("\\r")
        case 0x00...0x1f, 0x7f...0x9f, 0x2028, 0x2029:
            // 制御列と Unicode 改行を可視化し、端末状態や行構造を変更させない。
            result.append(String(format: "\\u{%02x}", scalar.value))
        default:
            result.unicodeScalars.append(scalar)
        }
    }
    return result
}

private func openArchive(_ path: String, password: String? = nil) throws -> ArchiveReader {
    try ArchiveReader.open(
        url: URL(fileURLWithPath: path),
        options: ReaderOptions(password: password)
    )
}

private func runDetect(_ arguments: [String]) throws {
    guard arguments.count == 1, let path = arguments.first else {
        throw CLIError.usage(usage)
    }
    print(formatName(try FormatDetector.detect(url: URL(fileURLWithPath: path))))
}

private func runList(_ arguments: [String]) throws {
    var path: String?
    var printRaw = false
    var password: String?
    var index = arguments.startIndex
    while index != arguments.endIndex {
        let argument = arguments[index]
        arguments.formIndex(after: &index)
        if argument == "--raw" {
            guard !printRaw else { throw CLIError.usage(usage) }
            printRaw = true
        } else if argument == "-p" {
            guard password == nil, index != arguments.endIndex else {
                throw CLIError.usage(usage)
            }
            password = arguments[index]
            arguments.formIndex(after: &index)
        } else if path == nil {
            guard !argument.hasPrefix("-") else { throw CLIError.usage(usage) }
            path = argument
        } else {
            throw CLIError.usage(usage)
        }
    }
    guard let path else { throw CLIError.usage(usage) }

    let reader = try openArchive(path, password: password)
    for entry in reader.entries {
        let size = entry.uncompressedSize.map { String($0) } ?? "-"
        let encryption = entry.formatSpecific["encryption"].flatMap {
            $0 == "none" ? nil : $0
        } ?? (entry.isEncrypted ? "encrypted" : "plain")
        var fields = [
            String(entry.index),
            size,
            kindName(entry.kind),
            oneLine(entry.methodDescription),
            oneLine(encryption),
            oneLine(entry.name),
        ]
        if reader.format == ArchiveFormat.lha,
           let headerLevel = entry.formatSpecific["headerLevel"] {
            fields.append("level=\(headerLevel)")
        }
        if printRaw {
            fields.append(hexadecimal(entry.rawName.bytes))
        }
        print(fields.joined(separator: "\t"))
    }
}

private struct ExtractArguments {
    let archive: String
    let output: String
    let password: String?
}

private func parseExtract(_ arguments: [String]) throws -> ExtractArguments {
    var archive: String?
    var output: String?
    var password: String?
    var index = arguments.startIndex

    while index != arguments.endIndex {
        let argument = arguments[index]
        arguments.formIndex(after: &index)
        switch argument {
        case "-o":
            guard output == nil, index != arguments.endIndex else {
                throw CLIError.usage(usage)
            }
            output = arguments[index]
            arguments.formIndex(after: &index)
        case "-p":
            guard password == nil, index != arguments.endIndex else {
                throw CLIError.usage(usage)
            }
            password = arguments[index]
            arguments.formIndex(after: &index)
        default:
            guard !argument.hasPrefix("-"), archive == nil else {
                throw CLIError.usage(usage)
            }
            archive = argument
        }
    }

    guard let archive, let output else { throw CLIError.usage(usage) }
    return ExtractArguments(archive: archive, output: output, password: password)
}

private struct EntryFailures: Error, CustomStringConvertible {
    let count: Int
    var description: String { "\(count) archive entries failed" }
}

private func reportEntryFailure(_ error: Error, entry: ArchiveEntry) {
    writeStandardError("error: failed entry \(entry.index) (\(oneLine(entry.name))): \(entryFailureReason(error))\n")
}

private func entryFailureReason(_ error: Error) -> String {
    if case KaitoError.checksumMismatch(let sourceMember) = error {
        return "Checksum mismatch (source member \(sourceMember))"
    }
    return oneLine(String(describing: error))
}

private func runExtract(_ arguments: [String]) throws {
    let parsed = try parseExtract(arguments)
    let reader = try openArchive(parsed.archive, password: parsed.password)
    let directory = URL(fileURLWithPath: parsed.output, isDirectory: true)
    var failures = 0
    func extract(_ entry: ArchiveEntry) {
        do {
            _ = try reader.extract(entry, to: directory)
        } catch {
            failures += 1
            reportEntryFailure(error, entry: entry)
        }
    }
    var deferred: [ArchiveEntry] = []
    for entry in reader.entries where entry.kind != .directory {
        // 前方参照は実体の展開後まで待ち、既存の後方参照の順序を保つ。
        if entry.kind == .hardlink,
           let targetText = entry.formatSpecific["hardLinkTargetIndex"],
           let targetIndex = Int(targetText), targetIndex > entry.index {
            deferred.append(entry)
        } else { extract(entry) }
    }
    for entry in deferred { extract(entry) }
    // 部分的な失敗後も子の作成を終え、ディレクトリの最終 mode/mtime を復元する。
    let directories = reader.entries
        .filter { $0.kind == .directory }
        .sorted {
            if $0.pathComponents.count != $1.pathComponents.count {
                return $0.pathComponents.count > $1.pathComponents.count
            }
            return $0.index < $1.index
        }
    for entry in directories { extract(entry) }
    if failures > 0 { throw EntryFailures(count: failures) }
}

private func entryData(_ entry: ArchiveEntry, reader: ArchiveReader) throws -> Data {
    if entry.kind == .directory {
        return Data()
    }
    return try reader.read(entry)
}

private func entrySHA256(
    _ entry: ArchiveEntry,
    reader: ArchiveReader,
    buffer: inout [UInt8]
) throws -> (byteCount: UInt64, digest: SHA256.Digest) {
    guard entry.kind != .directory else {
        return (0, SHA256.hash(data: Data()))
    }

    let stream = try reader.stream(entry)
    var byteCount: UInt64 = 0
    var digest = SHA256()
    while true {
        let count = try buffer.withUnsafeMutableBytes { storage -> Int in
            let count = try stream.read(into: storage)
            if count > 0 {
                digest.update(
                    bufferPointer: UnsafeRawBufferPointer(rebasing: storage[..<count])
                )
            }
            return count
        }
        guard count > 0 else { break }
        let nextCount = byteCount.addingReportingOverflow(UInt64(count))
        guard !nextCount.overflow else {
            throw KaitoError.limitExceeded("SHA-256 byte count")
        }
        byteCount = nextCount.partialValue
    }
    return (byteCount, digest.finalize())
}

private func runSHA(_ arguments: [String]) throws {
    var path: String?
    var password: String?
    var index = arguments.startIndex
    while index != arguments.endIndex {
        let argument = arguments[index]
        arguments.formIndex(after: &index)
        if argument == "-p" {
            guard password == nil, index != arguments.endIndex else {
                throw CLIError.usage(usage)
            }
            password = arguments[index]
            arguments.formIndex(after: &index)
        } else {
            guard !argument.hasPrefix("-"), path == nil else {
                throw CLIError.usage(usage)
            }
            path = argument
        }
    }
    guard let path else { throw CLIError.usage(usage) }
    let reader = try openArchive(path, password: password)
    var total = SHA256()
    // Hash incrementally so `sha` does not allocate each complete entry and
    // traverse it again after decompression. Reuse one buffer for the archive.
    var buffer = [UInt8](repeating: 0, count: 4 * 1_024 * 1_024)

    var failures = 0
    for entry in reader.entries {
        do {
            let result = try entrySHA256(entry, reader: reader, buffer: &buffer)
            let digestText = hexadecimal(result.digest)
            total.update(data: Data(digestText.utf8))
            print("\(entry.index)\t\(result.byteCount)\t\(digestText)\t\(oneLine(entry.name))")
        } catch {
            failures += 1
            print("\(entry.index)\tERROR\tfailed entry \(entry.index): \(entryFailureReason(error))\t\(oneLine(entry.name))")
            reportEntryFailure(error, entry: entry)
        }
    }

    // 欠落した member がある場合、完全な archive digest と誤認させない。
    let totalText = hexadecimal(total.finalize())
    if failures > 0 {
        print("partial\t\(reader.entries.count - failures)\t\(totalText)\t")
        throw EntryFailures(count: failures)
    }
    print("total\t\(reader.entries.count)\t\(totalText)\t")
}

private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
}

private func elapsedMilliseconds(since start: UInt64, until end: UInt64) -> Double {
    let nanoseconds = end >= start ? end - start : 0
    return Double(nanoseconds) / 1_000_000
}

private struct BenchArguments {
    let archive: String
    let repetitions: Int
    let useMappedData: Bool
    let useRandomAccess: Bool
    let password: String?
}

private func parseBench(_ arguments: [String]) throws -> BenchArguments {
    var positionals: [String] = []
    var useMappedData = false
    var useRandomAccess = false
    var password: String?
    var index = arguments.startIndex
    while index != arguments.endIndex {
        let argument = arguments[index]
        arguments.formIndex(after: &index)
        if argument == "--data" {
            guard !useMappedData else { throw CLIError.usage(usage) }
            useMappedData = true
        } else if argument == "--random" {
            guard !useRandomAccess else { throw CLIError.usage(usage) }
            useRandomAccess = true
        } else if argument == "-p" {
            guard password == nil, index != arguments.endIndex else {
                throw CLIError.usage(usage)
            }
            password = arguments[index]
            arguments.formIndex(after: &index)
        } else {
            guard !argument.hasPrefix("-") else { throw CLIError.usage(usage) }
            positionals.append(argument)
        }
    }

    guard (1...2).contains(positionals.count) else {
        throw CLIError.usage(usage)
    }
    let repetitions: Int
    if positionals.count == 2 {
        guard let parsed = Int(positionals[1]), (1...10_000).contains(parsed) else {
            throw CLIError.usage("reps must be between 1 and 10000\n\(usage)")
        }
        repetitions = parsed
    } else {
        repetitions = 5
    }
    return BenchArguments(
        archive: positionals[0],
        repetitions: repetitions,
        useMappedData: useMappedData,
        useRandomAccess: useRandomAccess,
        password: password
    )
}

private struct BenchmarkRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64 = 0x4B61_6974_6F4B_6974

    mutating func next() -> UInt64 {
        // SplitMix64 の合同算術は擬似乱数生成のため意図的に 64 bit で折り返す。
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private func randomBenchmarkEntries(_ entries: [ArchiveEntry]) -> [ArchiveEntry] {
    let sampleLimit = 20
    var generator = BenchmarkRandomNumberGenerator()
    var sample: [ArchiveEntry] = []
    sample.reserveCapacity(min(sampleLimit, entries.count))
    var eligibleCount = 0

    // 全エントリ配列を複製せず、最大 20 件の一様な reservoir sample を作る。
    for entry in entries where entry.kind != .directory {
        eligibleCount += 1 // `entries.count` 以下なので Int の範囲内。
        if sample.count < sampleLimit {
            sample.append(entry)
        } else {
            let replacement = Int.random(in: 0..<eligibleCount, using: &generator)
            if replacement < sampleLimit {
                sample[replacement] = entry
            }
        }
    }
    sample.shuffle(using: &generator)
    return sample
}

private func runBench(_ arguments: [String]) throws {
    let parsed = try parseBench(arguments)

    var openTimes: [Double] = []
    var extractTimes: [Double] = []
    openTimes.reserveCapacity(parsed.repetitions)
    extractTimes.reserveCapacity(parsed.repetitions)
    var lastByteCount = 0

    for _ in 0..<parsed.repetitions {
        let openStart = DispatchTime.now().uptimeNanoseconds
        let reader: ArchiveReader
        if parsed.useMappedData {
            // cooViewer の初回 open と同じく、map 作成も Data 経路の時間に含める。
            let mappedData = try Data(
                contentsOf: URL(fileURLWithPath: parsed.archive),
                options: .mappedIfSafe
            )
            reader = try ArchiveReader.open(
                data: mappedData,
                options: ReaderOptions(password: parsed.password)
            )
        } else {
            reader = try openArchive(parsed.archive, password: parsed.password)
        }
        let openEnd = DispatchTime.now().uptimeNanoseconds
        openTimes.append(elapsedMilliseconds(since: openStart, until: openEnd))

        let benchmarkEntries = parsed.useRandomAccess
            ? randomBenchmarkEntries(reader.entries)
            : reader.entries
        var extracted: [Data] = []
        extracted.reserveCapacity(benchmarkEntries.count)
        var byteCount = 0
        let extractStart = DispatchTime.now().uptimeNanoseconds
        for entry in benchmarkEntries {
            let data = try entryData(entry, reader: reader)
            let sum = byteCount.addingReportingOverflow(data.count)
            guard !sum.overflow else {
                throw KaitoError.limitExceeded("benchmark byte count")
            }
            byteCount = sum.partialValue
            extracted.append(data)
        }
        let extractEnd = DispatchTime.now().uptimeNanoseconds
        extractTimes.append(elapsedMilliseconds(since: extractStart, until: extractEnd))
        lastByteCount = byteCount
        withExtendedLifetime(extracted) {}
    }

    print("reps\t\(parsed.repetitions)")
    print(String(format: "open-median-ms\t%.3f", median(openTimes)))
    print(String(format: "extract-median-ms\t%.3f", median(extractTimes)))
    print("bytes\t\(lastByteCount)")
}

private func run(_ arguments: [String]) throws {
    guard let command = arguments.first else { throw CLIError.usage(usage) }
    let tail = Array(arguments.dropFirst())
    switch command {
    case "detect": try runDetect(tail)
    case "list": try runList(tail)
    case "extract": try runExtract(tail)
    case "sha": try runSHA(tail)
    case "bench": try runBench(tail)
    default: throw CLIError.usage(usage)
    }
}

private func writeStandardError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch let error as CLIError {
    writeStandardError("\(error.description)\n")
    exit(2)
} catch {
    writeStandardError("error: \(error)\n")
    exit(1)
}
