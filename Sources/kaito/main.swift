import Darwin
import Foundation
@_spi(SevenZipEditLayout) @_spi(TarEditLayout) import KaitoKit

enum CLIError: Error, CustomStringConvertible {
    case usage(String)

    var description: String {
        switch self {
        case .usage(let message):
            return message
        }
    }
}

let usage = """
usage:
  kaito detect <archive>
  kaito \(detectEncodingUsage)
  kaito list <archive> [--raw] [-p <password>] [--threads <N|auto>]
  kaito extract <archive> -o <directory> [-p <password>] [--threads <N|auto>]
  kaito sha <archive> [--sink] [--forks] [-p <password>] [--threads <N|auto>]
  kaito bench [--data] [--random] <archive> [reps] [-p <password>] [--threads <N|auto>]
"""

func hexadecimal<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
}

// entry 名・method・error 文を一行の表示にする。list / sha / extract の stdout と stderr が使う。
// detect-encoding の nameDetectionEscape とは書式が異なる（こちらは制御文字を 2 桁以上の `\u{%02x}` にし、
// `|` を素通しする）。両者の出力は CLISmokeTests がそれぞれ固定しているため、一つにしない。
func oneLine(_ value: String) -> String {
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

func openArchive(_ path: String, password: String? = nil, decodeThreads: Int? = nil) throws -> ArchiveReader {
    var options = ReaderOptions(password: password, decodeThreads: decodeThreads)
    options.recordsSevenZipEditLayout = environmentFlag("KAITOKIT_BENCH_7Z_EDIT_LAYOUT")
    options.recordsTarEditLayout = environmentFlag("KAITOKIT_BENCH_TAR_EDIT_LAYOUT")
    return try ArchiveReader.open(
        url: URL(fileURLWithPath: path),
        options: options
    )
}

// 値が厳密に "1" のときだけ有効。未設定・空・その他の値は無効。
private func environmentFlag(_ name: String) -> Bool {
    getenv(name).map { String(cString: $0) == "1" } ?? false
}

struct EntryFailures: Error, CustomStringConvertible {
    let count: Int
    var description: String { "\(count) archive entries failed" }
}

func reportEntryFailure(_ error: Error, entry: ArchiveEntry) {
    writeStandardError("error: failed entry \(entry.index) (\(oneLine(entry.name))): \(entryFailureReason(error))\n")
}

func entryFailureReason(_ error: Error) -> String {
    if case KaitoError.checksumMismatch(let sourceMember) = error {
        return "Checksum mismatch (source member \(sourceMember))"
    }
    return oneLine(String(describing: error))
}

private func run(_ arguments: [String]) throws {
    guard let command = arguments.first else { throw CLIError.usage(usage) }
    let tail = Array(arguments.dropFirst())
    switch command {
    case "detect": try runDetect(tail)
    case "detect-encoding": try runDetectEncoding(tail)
    case "list": try runList(tail)
    case "extract": try runExtract(tail)
    case "sha": try runSHA(tail)
    case "bench": try runBench(tail)
    default: throw CLIError.usage(usage)
    }
}

func writeStandardError(_ message: String) {
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
