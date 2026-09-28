import CryptoKit
import Foundation
import KaitoKit

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

func runSHA(_ arguments: [String]) throws {
    var path: String?
    var password: String?
    var allForks = false
    var cursor = ArgumentCursor(arguments)
    while let argument = cursor.next() {
        // --forks は重複しても受け付ける。
        if argument == "--forks" {
            allForks = true
        } else if argument == "-p" {
            password = try cursor.value(unlessSet: password)
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
    var rows = 0
    let stuffItFamily = [.stuffIt, .stuffItX].contains(reader.format)
    let dataForkPaths = Set(reader.entries.compactMap { entry in
        stuffItFamily && entry.formatSpecific["fork"] == "data" ? entry.pathComponents : nil
    })
    for entry in reader.entries {
        do {
            let resourceView = stuffItFamily && !allForks && entry.formatSpecific["fork"] == "resource"
            let result = resourceView ? (byteCount: UInt64(0), digest: SHA256.hash(data: Data()))
                : try entrySHA256(entry, reader: reader, buffer: &buffer)
            var name = entry.name
            if stuffItFamily {
                name = entry.pathComponents.joined(separator: "/")
                if resourceView {
                    // オラクル互換の既定表示・検証は data fork。--forks では resource も検証する。
                    let components = Array(entry.pathComponents.dropLast(2))
                    if dataForkPaths.contains(components) { continue }
                    name = components.joined(separator: "/")
                }
            }
            let digestText = hexadecimal(result.digest)
            total.update(data: Data(digestText.utf8))
            print("\(stuffItFamily ? rows : entry.index)\t\(result.byteCount)\t\(digestText)\t\(oneLine(name))")
            rows += 1
        } catch {
            failures += 1
            if !stuffItFamily {
                print("\(entry.index)\tERROR\tfailed entry \(entry.index): \(entryFailureReason(error))\t\(oneLine(entry.name))")
            }
            reportEntryFailure(error, entry: entry)
        }
    }

    // 欠落した member がある場合、完全な archive digest と誤認させない。
    let totalText = hexadecimal(total.finalize())
    if failures > 0 {
        print("partial\t\(rows)\t\(totalText)\t")
        throw EntryFailures(count: failures)
    }
    print("total\t\(rows)\t\(totalText)\t")
}
