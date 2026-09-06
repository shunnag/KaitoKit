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
  kaito list <archive> [--raw]
  kaito extract <archive> -o <directory> [-p <password>]
  kaito sha <archive>
  kaito bench <archive> [reps]
"""

private func formatName(_ format: ArchiveFormat) -> String {
    switch format {
    case .zip: return "zip"
    case .rar: return "rar"
    case .sevenZip: return "7z"
    case .lha: return "lha"
    case .tar: return "tar"
    case .gzip: return "gzip"
    case .bzip2: return "bzip2"
    case .xz: return "xz"
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
    // Reader 未実装の形式も signature 検出だけは報告できる。
    let source = try FileByteSource(url: URL(fileURLWithPath: path))
    print(formatName(try FormatDetector.detect(source: source)))
}

private func runList(_ arguments: [String]) throws {
    var path: String?
    var printRaw = false
    for argument in arguments {
        if argument == "--raw" {
            guard !printRaw else { throw CLIError.usage(usage) }
            printRaw = true
        } else if path == nil {
            path = argument
        } else {
            throw CLIError.usage(usage)
        }
    }
    guard let path else { throw CLIError.usage(usage) }

    let reader = try openArchive(path)
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

private func runExtract(_ arguments: [String]) throws {
    let parsed = try parseExtract(arguments)
    let reader = try openArchive(parsed.archive, password: parsed.password)
    let directory = URL(fileURLWithPath: parsed.output, isDirectory: true)
    for entry in reader.entries where entry.kind != .directory {
        _ = try reader.extract(entry, to: directory)
    }
    // 子を作り終えてから深い順に処理し、ディレクトリの最終 mode/mtime を保つ。
    let directories = reader.entries
        .filter { $0.kind == .directory }
        .sorted {
            if $0.pathComponents.count != $1.pathComponents.count {
                return $0.pathComponents.count > $1.pathComponents.count
            }
            return $0.index < $1.index
        }
    for entry in directories {
        _ = try reader.extract(entry, to: directory)
    }
}

private func entryData(_ entry: ArchiveEntry, reader: ArchiveReader) throws -> Data {
    if entry.kind == .directory {
        return Data()
    }
    return try reader.read(entry)
}

private func runSHA(_ arguments: [String]) throws {
    guard arguments.count == 1, let path = arguments.first else {
        throw CLIError.usage(usage)
    }
    let reader = try openArchive(path)
    var total = SHA256()

    for entry in reader.entries {
        let data = try entryData(entry, reader: reader)
        let digest = SHA256.hash(data: data)
        let digestText = hexadecimal(digest)
        // 既存の差分 oracle と同様、各 digest の 16 進表現を連結して総合 hash にする。
        total.update(data: Data(digestText.utf8))
        print("\(entry.index)\t\(data.count)\t\(digestText)\t\(oneLine(entry.name))")
    }

    let totalText = hexadecimal(total.finalize())
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

private func runBench(_ arguments: [String]) throws {
    guard (1...2).contains(arguments.count), let path = arguments.first else {
        throw CLIError.usage(usage)
    }
    let repetitions: Int
    if arguments.count == 2 {
        guard let parsed = Int(arguments[1]), (1...10_000).contains(parsed) else {
            throw CLIError.usage("reps must be between 1 and 10000\n\(usage)")
        }
        repetitions = parsed
    } else {
        repetitions = 5
    }

    var openTimes: [Double] = []
    var extractTimes: [Double] = []
    openTimes.reserveCapacity(repetitions)
    extractTimes.reserveCapacity(repetitions)
    var lastByteCount = 0

    for _ in 0..<repetitions {
        let openStart = DispatchTime.now().uptimeNanoseconds
        let reader = try openArchive(path)
        let openEnd = DispatchTime.now().uptimeNanoseconds
        openTimes.append(elapsedMilliseconds(since: openStart, until: openEnd))

        var extracted: [Data] = []
        extracted.reserveCapacity(reader.entries.count)
        var byteCount = 0
        let extractStart = DispatchTime.now().uptimeNanoseconds
        for entry in reader.entries {
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

    print("reps\t\(repetitions)")
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
