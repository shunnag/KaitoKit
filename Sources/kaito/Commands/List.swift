import Foundation
import KaitoKit

func runList(_ arguments: [String]) throws {
    var path: String?
    var printRaw = false
    var password: String?
    var cursor = ArgumentCursor(arguments)
    while let argument = cursor.next() {
        if argument == "--raw" {
            guard !printRaw else { throw CLIError.usage(usage) }
            printRaw = true
        } else if argument == "-p" {
            password = try cursor.value(unlessSet: password)
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
            entry.kind.rawValue,
            oneLine(entry.methodDescription),
            oneLine(encryption),
            oneLine(entry.name),
        ]
        if reader.format == ArchiveFormat.lha,
           let headerLevel = entry.formatSpecific["headerLevel"] {
            fields.append("level=\(headerLevel)")
        }
        // StuffIt 系と MacBinary / AppleSingle / BinHex は data / resource の両 fork、UDF と AppleDouble 統合は
        // resource fork にだけ付く。
        if let fork = entry.formatSpecific["fork"] {
            fields.append("fork=\(fork)")
        }
        if reader.format == .stuffItX { fields.append("solid=\(entry.solidGroup)") }
        if printRaw {
            fields.append(hexadecimal(entry.rawName.bytes))
        }
        print(fields.joined(separator: "\t"))
    }
}
