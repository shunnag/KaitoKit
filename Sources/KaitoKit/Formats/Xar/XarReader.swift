// xar の公開形式説明・xar(1)、RFC 1950/1951、LZMA SDK lzma-specification.txt、
// XZ file-format spec に対応する利用者提供の実測 byte 表に基づくクリーンルーム実装。
// xar / libarchive / 7-Zip / XADMaster / The Unarchiver 等、他の archiver の source は参照していない。
import CryptoKit
import Foundation

final class XarReader: FormatReader {
    let format: ArchiveFormat = .xar
    let entries: [ArchiveEntry]
    let nameEncoding: String.Encoding? = .utf8
    private let source: any ByteSource
    private let heapStart: UInt64
    private let records: [XarData?]

    init(source: any ByteSource, options: ReaderOptions) throws {
        self.source = source
        let limits = options.limits
        let header = try XarHeader(source: source)
        heapStart = header.heapStart
        try Checked.size(header.uncompressedTOCLength, limit: limits.maxMetadataSize)
        let tocBytes = try Self.inflateTOC(source: source, header: header)
        let toc = try XarTOC(bytes: tocBytes, limits: limits)
        if let checksum = toc.checksum, let raw = checksum.style, let style = XarChecksumStyle(rawValue: raw.lowercased()) {
            let hash = Self.hashing(try CopyDecompressor(source: source, offset: header.size,
                compressedSize: header.compressedTOCLength), style: style)
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while !hash.isFinished { _ = try buffer.withUnsafeMutableBytes { try hash.read(into: $0) } }
            let digest = hash.digest
            guard checksum.size == UInt64(digest.count) else { throw KaitoError.malformed("xar toc checksum mismatch") }
            let offset = try Checked.add(heapStart, checksum.offset)
            let expected = try readByteRange(source: source, offset: offset, count: digest.count)
            guard digest == expected else { throw KaitoError.malformed("xar toc checksum mismatch") }
        }
        let heapLength = try Checked.sub(source.length, heapStart)
        var entries: [ArchiveEntry] = []
        var ids: [String: Int] = [:]
        var paths: [String: Int] = [:]
        var metadata = toc.metadataSize
        var dateFormatter: DateFormatter?
        func components(_ path: String) throws -> [String] {
            let parts = path.utf8.split(separator: 47, maxSplits: limits.maxPathComponentCount)
            guard parts.count <= limits.maxPathComponentCount else { throw KaitoError.limitExceeded("xar path component count") }
            return parts.map { String(decoding: $0, as: UTF8.self) }
        }
        for node in toc.files {
            let kind: EntryKind
            switch node.type {
            case "file": kind = .file
            case "directory": kind = .directory
            case "symlink": kind = .symlink
            case "hardlink": kind = node.hardlink == "original" ? .file : .hardlink
            default: kind = .other
            }
            if let data = node.data {
                guard try Checked.add(data.offset, data.length) <= heapLength else { throw KaitoError.truncated }
                if data.encoding == nil || data.encoding?.lowercased() == XarEncoding.stored.rawValue {
                    guard data.length == data.size else { throw KaitoError.malformed("xar stored size") }
                }
            }
            let component = EncodingDetector.resolveUndeclaredName(bytes: node.name, policy: options.encodingPolicy,
                archiveEncoding: .utf8).string
            let parentName = node.parent.map { entries[$0].name + "/" } ?? ""
            let name = parentName + component
            let parts = try components(name)
            var raw = node.parent.map { entries[$0].rawName.bytes + [47] } ?? []
            raw += node.name
            var specific = node.fields.filter { ["fileID", "uid", "gid", "user", "group"].contains($0.key) }
            if let id = specific["fileID"] {
                guard ids[id] == nil else { throw KaitoError.malformed("xar duplicate file id") }
                ids[id] = entries.count
            }
            if let link = kind == .symlink ? node.symlink : (kind == .hardlink ? node.hardlink : nil) {
                _ = try components(link)
                specific["linkPath"] = link
            }
            if let data = node.data {
                specific["encoding"] = data.encoding
                specific["extractedChecksum"] = data.checksum
                specific["extractedChecksumStyle"] = data.checksumStyle
            }
            var cost = try Checked.add(256, UInt64(raw.count))
            cost = try Checked.add(cost, UInt64(name.utf8.count))
            cost = try Checked.add(cost, Checked.mul(UInt64(parts.count), UInt64(MemoryLayout<String>.stride)))
            for part in parts { cost = try Checked.add(cost, UInt64(part.utf8.count)) }
            for (key, value) in specific { cost = try Checked.add(cost, Checked.add(UInt64(key.utf8.count), UInt64(value.utf8.count))) }
            metadata = try Checked.add(metadata, cost)
            try Checked.size(metadata, limit: limits.maxTotalMetadataSize)
            var date: Date?
            if let mtime = node.fields["mtime"] {
                date = Self.parseModificationDate(mtime, formatter: &dateFormatter)
            }
            let mode = node.fields["mode"].flatMap { UInt64($0.trimmingCharacters(in: .whitespacesAndNewlines), radix: 8) }
            let hasOutput = kind == .file || kind == .other
            let encoding = node.data?.encoding ?? XarEncoding.stored.rawValue
            entries.append(ArchiveEntry(index: entries.count,
                rawName: RawName(bytes: raw, declaredEncoding: .utf8, isDirectoryHint: kind == .directory),
                name: name, pathComponents: parts, kind: kind,
                uncompressedSize: hasOutput ? (node.data?.size ?? 0) : 0,
                compressedSize: hasOutput ? (node.data?.length ?? 0) : 0,
                modificationDate: date, posixPermissions: mode.map { UInt16($0 & 0o7777) },
                isEncrypted: false, solidGroup: -1, crc32: nil,
                methodDescription: XarEncoding(rawValue: encoding.lowercased())?.description ?? "xar (\(encoding))", formatSpecific: specific))
            paths[name] = entries.count - 1
        }
        // ID は TOC 全体で解決し、chain は既に解決した実体だけを継承するため cycle を作らない。
        var dependents: [Int: [Int]] = [:]
        for index in entries.indices where entries[index].kind == .hardlink {
            guard let link = toc.files[index].hardlink else { continue }
            let target = ids[link] ?? paths[link]
            if let idTarget = ids[link] {
                var specific = entries[index].formatSpecific
                specific["linkPath"] = entries[idTarget].name
                entries[index] = Self.replacingMetadata(entries[index], with: specific)
                metadata = try Checked.add(metadata, UInt64(entries[idTarget].name.utf8.count))
                try Checked.size(metadata, limit: limits.maxTotalMetadataSize)
            }
            if let target {
                dependents[target, default: []].append(index)
            }
        }
        var queue = entries.indices.filter { entries[$0].kind == .file }
        var cursor = 0
        while cursor < queue.count {
            let target = queue[cursor]
            cursor += 1
            for index in dependents[target] ?? [] {
                var specific = entries[index].formatSpecific
                let resolvedIndex = entries[target].formatSpecific["hardLinkTargetIndex"] ?? String(target)
                // 展開側は index と path の一致を検証するため、両方を最終実体へ揃える。
                specific["hardLinkTargetIndex"] = resolvedIndex
                specific["linkPath"] = entries[target].kind == .file ? entries[target].name : entries[target].formatSpecific["linkPath"]
                entries[index] = Self.replacingMetadata(entries[index], with: specific)
                metadata = try Checked.add(metadata, Checked.add(64, UInt64(specific["linkPath"]?.utf8.count ?? 0)))
                try Checked.size(metadata, limit: limits.maxTotalMetadataSize)
                queue.append(index)
            }
        }
        self.entries = entries
        records = toc.files.map(\.data)
    }

    static func parseModificationDate(_ mtime: String, formatter: inout DateFormatter?) -> Date? {
        let text = mtime.trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = text.hasSuffix("Z") ? String(text.dropLast()) : text
        // 5,110 項目の open 標本の 68% を占めた ICU 解析を、暦が一致する定型日時だけで省く。
        // 1582 年以前の混合暦と 5 桁以上の年は、従来の formatter にそのまま委ねる。
        if plain.utf8.count == 19 {
            let bytes = Array(plain.utf8)
            if bytes[4] == 45, bytes[7] == 45, bytes[10] == 84, bytes[13] == 58, bytes[16] == 58,
               [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18].allSatisfy({ (48...57).contains(bytes[$0]) }) {
                func pair(_ index: Int) -> Int { Int(bytes[index] - 48) * 10 + Int(bytes[index + 1] - 48) }
                let year = pair(0) * 100 + pair(2)
                if year >= 1583 {
                    let month = pair(5), day = pair(8)
                    let hour = pair(11), minute = pair(14), second = pair(17)
                    guard (1...12).contains(month), (0...23).contains(hour),
                          (0...59).contains(minute), (0...59).contains(second) else { return nil }
                    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
                    let monthLengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
                    guard (1...monthLengths[month - 1]).contains(day) else { return nil }
                    // 前年までの日数と月初までの平年日数を足し、1970-01-01 までの 719162 日を引く。
                    // 年は 1583...9999 に限定済みなので、秒への乗算も Int の範囲内に収まる。
                    let previousYear = year - 1
                    let monthStarts = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
                    let days = previousYear * 365 + previousYear / 4 - previousYear / 100 + previousYear / 400
                        + monthStarts[month - 1] + (leap && month > 2 ? 1 : 0) + day - 1 - 719162
                    let seconds = days * 86400 + hour * 3600 + minute * 60 + second
                    return Date(timeIntervalSince1970: TimeInterval(seconds))
                }
            }
        }
        // 通常の書庫では作成せず、例外日時が複数あっても書庫内で同じ設定を再利用する。
        let fallback: DateFormatter
        if let formatter {
            fallback = formatter
        } else {
            fallback = DateFormatter()
            fallback.locale = Locale(identifier: "en_US_POSIX")
            fallback.calendar = Calendar(identifier: .gregorian)
            fallback.timeZone = TimeZone(secondsFromGMT: 0)
            fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            fallback.isLenient = false
            formatter = fallback
        }
        if let parsed = fallback.date(from: plain), fallback.string(from: parsed) == plain { return parsed }
        return nil
    }

    private static func replacingMetadata(_ entry: ArchiveEntry, with specific: [String: String]) -> ArchiveEntry {
        ArchiveEntry(index: entry.index, rawName: entry.rawName, name: entry.name, pathComponents: entry.pathComponents,
            kind: entry.kind, uncompressedSize: entry.uncompressedSize, compressedSize: entry.compressedSize,
            modificationDate: entry.modificationDate, posixPermissions: entry.posixPermissions,
            isEncrypted: false, solidGroup: -1, crc32: nil, methodDescription: entry.methodDescription, formatSpecific: specific)
    }

    private static func inflateTOC(source: any ByteSource, header: XarHeader) throws -> [UInt8] {
        let decoder = try DeflateDecompressor(source: source, offset: header.size,
            compressedSize: header.compressedTOCLength, zlibWrapped: true)
        var result: [UInt8] = []
        let expected = try Checked.toInt(header.uncompressedTOCLength)
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, max(1, expected)))
        do {
            while !decoder.isFinished {
                let remaining = expected - result.count
                let capacity = min(buffer.count, max(1, remaining))
                let count = try buffer.withUnsafeMutableBytes {
                    try decoder.read(into: UnsafeMutableRawBufferPointer(rebasing: $0[..<capacity]))
                }
                guard count <= remaining else { throw KaitoError.malformed("xar toc size") }
                result.append(contentsOf: buffer.prefix(count))
            }
        } catch KaitoError.truncated { throw KaitoError.malformed("xar toc zlib") }
        guard result.count == expected else { throw KaitoError.malformed("xar toc size") }
        return result
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        guard entries.indices.contains(entry.index), entries[entry.index] == entry else { throw KaitoError.notFound("xar entry index \(entry.index)") }
        guard entry.kind != .directory, entry.kind != .symlink, entry.kind != .hardlink, let data = records[entry.index] else {
            return try EntryStream(source: source, offset: heapStart, length: 0, limits: limits)
        }
        let style = data.encoding ?? XarEncoding.stored.rawValue
        guard let encoding = XarEncoding(rawValue: style.lowercased()) else { throw KaitoError.unsupportedMethod("xar encoding \(style)") }
        let window = try BoundedByteSource(source: source, baseOffset: Checked.add(heapStart, data.offset), length: data.length)
        let decoder: any Decompressor
        switch encoding {
        case .stored: decoder = try CopyDecompressor(source: window, offset: 0, compressedSize: data.length)
        case .zlib, .rfc6713Zlib: decoder = try DeflateDecompressor(source: window, offset: 0, compressedSize: data.length, zlibWrapped: true)
        case .bzip2: decoder = try Bzip2Decompressor(source: window, offset: 0, compressedSize: data.length)
        case .xz: decoder = try XZDecompressor(source: window)
        case .lzma:
            let prefix = try readByteRange(source: window, offset: 0, count: Checked.toInt(min(6, window.length)))
            if prefix == [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0] { decoder = try XZDecompressor(source: window) }
            else {
                let header = try LZMAAloneHeader.read(source: window, limits: limits)
                if let size = header.uncompressedSize, size != data.size { throw KaitoError.malformed("xar lzma size") }
                decoder = try LZMADecoder(source: window, offset: 13, compressedSize: Checked.sub(data.length, 13),
                    properties: header.properties, expectedSize: header.uncompressedSize, dictionarySizeLimit: limits.maxDictionarySize)
            }
        }
        if let text = data.checksum, let raw = data.checksumStyle, let style = XarChecksumStyle(rawValue: raw.lowercased()) {
            let hash = Self.hashing(decoder, style: style)
            return try EntryStream(decompressor: hash, length: data.size, expectedCRC32: nil, entryIndex: entry.index,
                limits: limits, completionCheck: {
                    let digest = hash.digest.map { String(format: "%02x", $0) }.joined()
                    guard digest == text.lowercased() else { throw KaitoError.malformed("xar checksum mismatch") }
                })
        }
        return try EntryStream(decompressor: decoder, length: data.size, expectedCRC32: nil, entryIndex: entry.index, limits: limits)
    }

    private static func hashing(_ decoder: any Decompressor, style: XarChecksumStyle) -> any XarDigestDecompressor {
        switch style {
        case .sha1: XarHashDecompressor<Insecure.SHA1>(decoder)
        case .md5: XarHashDecompressor<Insecure.MD5>(decoder)
        case .sha256: XarHashDecompressor<SHA256>(decoder)
        case .sha512: XarHashDecompressor<SHA512>(decoder)
        }
    }
}

private protocol XarDigestDecompressor: Decompressor { var digest: [UInt8] { get } }

// 展開時の同一 pass で digest を更新し、出力全体の保持や圧縮 data の再読込を避ける。
private final class XarHashDecompressor<H: HashFunction>: XarDigestDecompressor {
    private let decoder: any Decompressor
    private var hash = H()
    init(_ decoder: any Decompressor) { self.decoder = decoder }
    var isFinished: Bool { decoder.isFinished }
    var digest: [UInt8] { Array(hash.finalize()) }
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let count = try decoder.read(into: buffer)
        guard count >= 0, count <= buffer.count else { throw KaitoError.malformed("xar decoder byte count") }
        hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[..<count]))
        return count
    }
}
