import Foundation

// POSIX / IEEE Std 1003.1 (SUSv2 pax cpio interchange format)、cpio(5)、
// GNU cpio manual、Heirloom cpio(1)、Linux initramfs buffer format、HP-UX cpio(4) の
// 公開仕様・prose に基づく利用者提供 byte 表だけを参照したクリーンルーム実装。
// XADMaster / The Unarchiver / libarchive / GNU cpio / bsdcpio / 7-Zip の source は参照しない。
final class CpioReader: FormatReader {
    static let maximumNameSize: UInt64 = 65_536
    static let maximumLinkTargetSize: UInt64 = 65_536
    static let maximumNULRun: UInt64 = 1 << 20
    private struct Record {
        let header: CpioHeader
        let offset, size: UInt64
        let incomplete: Bool
        let kind: EntryKind
    }
    private struct Pending {
        let name: [UInt8]
        let link: [UInt8]?
        let archiveIndex: Int
        let record: Record
    }
    let format: ArchiveFormat = .cpio
    let entries: [ArchiveEntry]
    let nameEncoding: String.Encoding?
    private let source: any ByteSource
    private let records: [Record]

    init(source: any ByteSource, options: ReaderOptions) throws {
        self.source = source
        let prefix = try readByteRange(source: source, offset: 0, count: Checked.toInt(min(6, source.length)))
        guard CpioHeader.variant(prefix) != nil else { throw KaitoError.unsupportedFormat }
        let limits = options.limits
        var offset: UInt64 = 0
        var archiveIndex = 0
        var afterTrailer = false
        var metadata: UInt64 = 0
        var pending: [Pending] = []
        while offset < source.length {
            do {
                guard let start = try Self.skipNULRun(source: source, from: offset), start < source.length else { break }
                offset = start
                if afterTrailer {
                    let magic = try readByteRange(source: source, offset: offset, count: Checked.toInt(min(6, source.length - offset)))
                    // POSIX は trailer 後を未定義とする。認識できる連結書庫だけを続ける。
                    guard CpioHeader.variant(magic) != nil else { break }
                }
                let header = try CpioHeader.read(source: source, at: offset)
                let layout = try header.layout(at: offset)
                let name = try header.readName(source: source, at: layout.name, limit: limits.maxMetadataSize)
                guard layout.data <= source.length else { throw KaitoError.truncated }
                if name == Array("TRAILER!!!".utf8) {
                    offset = min(layout.next, source.length)
                    archiveIndex += 1
                    afterTrailer = true
                    continue
                }
                afterTrailer = false
                guard pending.count < limits.maxEntryCount else { throw KaitoError.limitExceeded("cpio entry count") }
                guard header.fileSize <= limits.maxEntrySize else { throw KaitoError.limitExceeded("cpio entry size") }
                let incomplete = layout.next > source.length
                guard !incomplete || options.recoverDamagedArchives else { throw KaitoError.truncated }
                let storedSize = min(header.fileSize, source.length - layout.data)
                let kind: EntryKind
                switch header.mode & 0o170000 {
                case 0o100000: kind = .file
                case 0o040000: kind = .directory
                case 0o120000: kind = .symlink
                default: kind = .other
                }
                var link: [UInt8]?
                if kind == .symlink {
                    guard header.fileSize <= Self.maximumLinkTargetSize else { throw KaitoError.limitExceeded("cpio symlink target size") }
                    try Checked.size(storedSize, limit: limits.maxMetadataSize)
                    if storedSize == 0 {
                        // hard-link placeholder の宣言値は補正しない。target の無い symlink は抽出側が拒否する。
                        guard header.nlink > 1 || incomplete else { throw KaitoError.malformed("cpio symlink without target") }
                    } else {
                        let target = try readByteRange(source: source, offset: layout.data, count: Checked.toInt(storedSize))
                        guard !target.contains(0) else { throw KaitoError.malformed("cpio symlink target contains NUL") }
                        link = target
                    }
                }
                metadata = try Checked.add(metadata, UInt64(256 + name.count + (link?.count ?? 0)))
                try Checked.size(metadata, limit: limits.maxTotalMetadataSize)
                let size = kind == .file || kind == .symlink ? storedSize : 0
                pending.append(Pending(name: name, link: link, archiveIndex: archiveIndex,
                    record: Record(header: header, offset: layout.data, size: size, incomplete: incomplete, kind: kind)))
                guard layout.next > offset else { throw KaitoError.malformed("cpio record does not advance") }
                offset = min(layout.next, source.length)
                if incomplete { break }
            } catch KaitoError.truncated {
                if options.recoverDamagedArchives { break }
                throw KaitoError.truncated
            } catch KaitoError.malformed(let reason) {
                if options.recoverDamagedArchives { break }
                throw KaitoError.malformed(reason)
            }
        }
        let names = pending.map(\.name).filter {
            if case .fixed = options.encodingPolicy { return true }
            return !EncodingDetector.isStrictUTF8($0)
        }
        let encoding = EncodingDetector.detectArchiveEncoding(names: names, policy: options.encodingPolicy,
            maximumBatchByteCount: Int(clamping: limits.maxMetadataSize))
        var decoded: [[UInt8]: String] = [:]
        if let encoding {
            let strings = EncodingDetector.decodeArchiveNames(names, as: encoding,
                maximumBatchByteCount: Int(clamping: limits.maxMetadataSize))
            for (bytes, string) in zip(names, strings) { if let string { decoded[bytes] = string } }
        }
        func resolve(_ bytes: [UInt8]) -> String {
            decoded[bytes] ?? EncodingDetector.resolveUndeclaredName(bytes: bytes, policy: options.encodingPolicy,
                archiveEncoding: encoding).string
        }
        func components(_ path: String) throws -> [String] {
            var count = 0
            var inComponent = false
            for byte in path.utf8 {
                if byte == 47 { inComponent = false }
                else if !inComponent {
                    guard count < limits.maxPathComponentCount else { throw KaitoError.limitExceeded("cpio path component count") }
                    count += 1
                    inComponent = true
                }
            }
            return path.utf8.split(separator: 47).map { String(decoding: $0, as: UTF8.self) }
        }
        var entries: [ArchiveEntry] = []
        metadata = 0
        let concatenated = pending.contains { $0.archiveIndex > 0 }
        for item in pending {
            let record = item.record, header = record.header
            let name = resolve(item.name)
            let parts = try components(name)
            var specific = ["variant": header.variant.rawValue, "uid": String(header.uid), "gid": String(header.gid),
                "nlink": String(header.nlink), "ino": String(header.ino), "dev": String(header.dev)]
            if header.variant == .crc { specific["check"] = String(format: "%08x", header.check) }
            if concatenated { specific["archiveIndex"] = String(item.archiveIndex) }
            if header.nlink > 1, record.kind == .file || record.kind == .symlink {
                specific["hardLinkGroup"] = "\(item.archiveIndex):\(header.dev):\(header.ino)"
            }
            if record.kind == .other {
                // HP-UX sentinel は解釈せず、元 field bytes の hex 表示だけを保持する。
                specific["rdev"] = header.rawRdev.map { String(format: "%02x", $0) }.joined()
            }
            if let link = item.link {
                let target = resolve(link)
                _ = try components(target)
                specific["linkPath"] = target
            }
            var cost = UInt64(256 + item.name.count + name.utf8.count + parts.count * MemoryLayout<String>.stride)
            for part in parts { cost = try Checked.add(cost, UInt64(part.utf8.count)) }
            for (key, value) in specific { cost = try Checked.add(cost, UInt64(key.utf8.count + value.utf8.count)) }
            metadata = try Checked.add(metadata, cost)
            try Checked.size(metadata, limit: limits.maxTotalMetadataSize)
            entries.append(ArchiveEntry(index: entries.count,
                rawName: RawName(bytes: item.name, declaredEncoding: nil, isDirectoryHint: record.kind == .directory),
                name: name, pathComponents: parts, kind: record.kind, uncompressedSize: record.size, compressedSize: record.size,
                modificationDate: Date(timeIntervalSince1970: TimeInterval(header.mtime)),
                posixPermissions: UInt16(header.mode & 0o7777), isEncrypted: false, solidGroup: -1,
                crc32: nil, methodDescription: "cpio (stored)", formatSpecific: specific, isIncomplete: record.incomplete))
        }
        self.entries = entries
        records = pending.map(\.record)
        nameEncoding = encoding
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        guard entries.indices.contains(entry.index), entries[entry.index] == entry else {
            throw KaitoError.notFound("cpio entry index \(entry.index)")
        }
        let record = records[entry.index]
        if record.incomplete {
            let copy = try CopyDecompressor(source: source, offset: record.offset, compressedSize: record.size)
            return try EntryStream(
                decompressor: RecoveryDecompressor(copy, maximumOutputSize: record.size),
                length: nil, expectedCRC32: nil, entryIndex: entry.index, limits: limits)
        }
        // pax は symlink の check=0 を出力するため通常 file の完全な実体だけを検証する。
        if record.header.variant == .crc, record.kind == .file, record.size > 0, !record.incomplete {
            let sum = try CpioSumDecompressor(source: source, offset: record.offset, length: record.size)
            return try EntryStream(decompressor: sum, length: record.size, expectedCRC32: nil,
                entryIndex: entry.index, limits: limits, completionCheck: {
                    guard sum.value == record.header.check else { throw KaitoError.malformed("cpio checksum mismatch") }
                })
        }
        return try EntryStream(source: source, offset: record.offset, length: record.size, limits: limits)
    }

    // nil は走査上限。probe では EOF の証明にならないため失敗、reader では読み止めとする。
    static func skipNULRun(source: any ByteSource, from start: UInt64) throws -> UInt64? {
        var offset = start
        while offset < source.length {
            let scanned = try Checked.sub(offset, start)
            if scanned == maximumNULRun {
                // 上限ぴったりの run の後に header が来る場合は受理する。
                let next = try readByteRange(source: source, offset: offset, count: 1)[0]
                return next == 0 ? nil : offset
            }
            let count = min(4096, min(source.length - offset, maximumNULRun - scanned))
            let bytes = try readByteRange(source: source, offset: offset, count: Checked.toInt(count))
            if let index = bytes.firstIndex(where: { $0 != 0 }) { return try Checked.add(offset, UInt64(index)) }
            offset = try Checked.add(offset, count)
        }
        return offset
    }
}
