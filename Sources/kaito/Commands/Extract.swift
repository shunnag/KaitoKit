import Foundation
import KaitoKit

private struct ExtractArguments {
    let archive: String
    let output: String
    let password: String?
}

private func parseExtract(_ arguments: [String]) throws -> ExtractArguments {
    var archive: String?
    var output: String?
    var password: String?
    var cursor = ArgumentCursor(arguments)

    while let argument = cursor.next() {
        switch argument {
        case "-o":
            output = try cursor.value(unlessSet: output)
        case "-p":
            password = try cursor.value(unlessSet: password)
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

func runExtract(_ arguments: [String]) throws {
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
    func isResourceFork(_ entry: ArchiveEntry) -> Bool {
        entry.kind == .file && entry.pathComponents.suffix(2).elementsEqual(["..namedfork", "rsrc"])
    }
    for entry in reader.entries where entry.kind != .directory {
        // 前方参照は実体の展開後まで待ち、既存の後方参照の順序を保つ。
        if isResourceFork(entry) {
            deferred.append(entry)
        } else if entry.kind == .hardlink,
           let targetText = entry.formatSpecific["hardLinkTargetIndex"],
           let targetIndex = Int(targetText), targetIndex > entry.index {
            deferred.append(entry)
        } else { extract(entry) }
    }
    for entry in deferred where !isResourceFork(entry) { extract(entry) }
    // data fork の renameat は inode を置換するため、全 data/hardlink の後に書く。
    for entry in deferred where isResourceFork(entry) { extract(entry) }
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
