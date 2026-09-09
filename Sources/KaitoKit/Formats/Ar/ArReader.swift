import Foundation

// ar(5)、System V ABI、SDK ar.h / mach-o/ranlib.h、Solaris ar.h(3HEAD)、
// GNU binutils の manual、deb(5) に基づく利用者提供 byte 表・prose だけを
// 形式入力としたクリーンルーム実装。XADMaster / The Unarchiver / libarchive /
// GNU binutils / LLVM / ELF Tool Chain の実装 source は参照しない。
final class ArReader: FormatReader {
    enum ArMagic { case normal, thin }
    static let maximumNameSize: UInt64 = 65_536
    private struct Record {
        let header: ArHeader
        let headerOffset, offset, size: UInt64
        let incomplete: Bool
    }
    private struct Pending {
        let name: [UInt8]
        let nameForm: String
        let record: Record
    }
    let format: ArchiveFormat = .ar
    let entries: [ArchiveEntry]
    let nameEncoding: String.Encoding?
    private let source: any ByteSource
    private let records: [Record]

    static func magic(_ prefix: [UInt8]) -> ArMagic? {
        if prefix.starts(with: Array("!<arch>\n".utf8)) { return .normal }
        if prefix.starts(with: Array("!<thin>\n".utf8)) { return .thin }
        return nil
    }

    static func isPlausibleArchive(_ prefix: [UInt8], sourceLength: UInt64) -> Bool {
        guard magic(prefix) != nil else { return false }
        if sourceLength == 8 { return true }
        guard sourceLength >= 68, prefix.count >= 68 else { return false }
        return prefix[66] == 0x60 && prefix[67] == 0x0A
    }

    init(source: any ByteSource, options: ReaderOptions) throws {
        self.source = source
        let prefix = try readByteRange(source: source, offset: 0, count: Checked.toInt(min(8, source.length)))
        switch Self.magic(prefix) {
        case nil: throw KaitoError.unsupportedFormat
        case .thin: throw KaitoError.unsupportedMethod("thin ar archive")
        case .normal: break
        }
        let limits = options.limits
        var offset: UInt64 = 8
        var table: (offset: UInt64, size: UInt64)?
        var tableBytes: [UInt8]?
        var metadata: UInt64 = 0
        var pending: [Pending] = []
        func checkNameSize(_ size: UInt64) throws {
            guard size <= Self.maximumNameSize, size <= limits.maxMetadataSize else {
                throw KaitoError.limitExceeded("ar name size")
            }
        }
        walk: while offset < source.length {
            guard source.length - offset >= 60 else {
                if options.recoverDamagedArchives { break }
                throw KaitoError.truncated
            }
            let header = try ArHeader(readByteRange(source: source, offset: offset, count: 60))
            guard header.size <= limits.maxEntrySize else { throw KaitoError.limitExceeded("ar entry size") }
            let layout = try header.layout(at: offset)
            var dataOffset = layout.data
            var name: [UInt8] = []
            var nameForm = "plain"
            var hidden = false
            switch try header.nameForm() {
            case .extended(let length):
                try checkNameSize(length)
                guard length > 0, length <= header.size else { throw KaitoError.malformed("ar extended name length") }
                dataOffset = try Checked.add(dataOffset, length)
                guard dataOffset <= source.length else {
                    if options.recoverDamagedArchives { break walk }
                    throw KaitoError.truncated
                }
                name = try readByteRange(source: source, offset: layout.data, count: Checked.toInt(length))
                while name.last == 0 { name.removeLast() }
                nameForm = "bsd-extended"
            case .stringTable:
                guard table == nil else { throw KaitoError.malformed("duplicate ar string table") }
                guard header.size <= limits.maxMetadataSize else { throw KaitoError.limitExceeded("ar string table size") }
                // 名前を決める metadata の欠損は recovery でも受理しない。
                guard layout.end <= source.length else { throw KaitoError.truncated }
                metadata = try Checked.add(metadata, header.size)
                try Checked.size(metadata, limit: limits.maxTotalMetadataSize)
                table = (layout.data, header.size)
                hidden = true
            case .symbolTable:
                // 独立した member の byte 列を保持する。特殊名の末尾 slash も落とさない。
                name = header.nameField
            case .reference(let reference):
                guard let table else { throw KaitoError.malformed("ar string table missing") }
                guard reference < table.size else { throw KaitoError.malformed("ar string table offset") }
                if tableBytes == nil {
                    tableBytes = try readByteRange(source: source, offset: table.offset, count: Checked.toInt(table.size))
                }
                let bytes = tableBytes ?? []
                var end = try Checked.toInt(reference)
                let start = end
                // 内部の '/' はパス区切り。LF / NUL / 表の終端まで走査し、末尾 '/' だけ除く。
                while end < bytes.count, bytes[end] != 10, bytes[end] != 0 {
                    guard UInt64(end - start) <= Self.maximumNameSize else { throw KaitoError.limitExceeded("ar name size") }
                    end += 1
                }
                if end > start, bytes[end - 1] == 47 { end -= 1 }
                try checkNameSize(UInt64(end - start))
                name = Array(bytes[start..<end])
                nameForm = "string-table"
            case .plain(let bytes):
                name = bytes
            }
            if !hidden {
                try checkNameSize(UInt64(name.count))
                guard !name.isEmpty else { throw KaitoError.malformed("ar empty member name") }
                guard !name.contains(0) else { throw KaitoError.malformed("ar member name contains NUL") }
                // BSD symbol table も、上で #1/LEN を解決した通常の member として公開する。
            }
            let incomplete = layout.end > source.length
            guard !incomplete || options.recoverDamagedArchives else { throw KaitoError.truncated }
            if !hidden {
                guard pending.count < limits.maxEntryCount else { throw KaitoError.limitExceeded("ar entry count") }
                metadata = try Checked.add(metadata, UInt64(256 + name.count))
                try Checked.size(metadata, limit: limits.maxTotalMetadataSize)
                let size = try Checked.sub(min(layout.end, source.length), dataOffset)
                pending.append(Pending(name: name, nameForm: nameForm,
                    record: Record(header: header, headerOffset: offset, offset: dataOffset, size: size, incomplete: incomplete)))
            }
            guard layout.next > offset else { throw KaitoError.malformed("ar member does not advance") }
            // 奇数サイズの pad は ar_size の外。最後の pad だけ欠ける場合は許容する。
            offset = min(layout.next, source.length)
            if incomplete { break }
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
                    guard count < limits.maxPathComponentCount else { throw KaitoError.limitExceeded("ar path component count") }
                    count += 1
                    inComponent = true
                }
            }
            return path.utf8.split(separator: 47).map { String(decoding: $0, as: UTF8.self) }
        }
        var entries: [ArchiveEntry] = []
        // 表と pending を保持したまま復号名・component を追加するため、合算で制限する。
        for item in pending {
            let record = item.record, header = record.header
            let name = resolve(item.name)
            let parts = try components(name)
            var specific = ["nameForm": item.nameForm, "headerOffset": String(record.headerOffset)]
            if let uid = header.uid { specific["uid"] = String(uid) }
            if let gid = header.gid { specific["gid"] = String(gid) }
            var cost = UInt64(name.utf8.count + parts.count * MemoryLayout<String>.stride)
            for part in parts { cost = try Checked.add(cost, UInt64(part.utf8.count)) }
            for (key, value) in specific { cost = try Checked.add(cost, UInt64(key.utf8.count + value.utf8.count)) }
            metadata = try Checked.add(metadata, cost)
            try Checked.size(metadata, limit: limits.maxTotalMetadataSize)
            entries.append(ArchiveEntry(index: entries.count,
                rawName: RawName(bytes: item.name, declaredEncoding: nil, isDirectoryHint: false),
                name: name, pathComponents: parts, kind: .file, uncompressedSize: record.size, compressedSize: record.size,
                modificationDate: header.date.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                posixPermissions: header.mode.map { UInt16($0 & 0o7777) }, isEncrypted: false, solidGroup: -1,
                crc32: nil, methodDescription: "ar (stored)", formatSpecific: specific, isIncomplete: record.incomplete))
        }
        self.entries = entries
        records = pending.map(\.record)
        nameEncoding = encoding
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        guard entries.indices.contains(entry.index), entries[entry.index] == entry else {
            throw KaitoError.notFound("ar entry index \(entry.index)")
        }
        let record = records[entry.index]
        if record.incomplete {
            let copy = try CopyDecompressor(source: source, offset: record.offset, compressedSize: record.size)
            return try EntryStream(decompressor: RecoveryDecompressor(copy, maximumOutputSize: record.size),
                length: nil, expectedCRC32: nil, entryIndex: entry.index, limits: limits)
        }
        return try EntryStream(source: source, offset: record.offset, length: record.size, limits: limits)
    }
}
