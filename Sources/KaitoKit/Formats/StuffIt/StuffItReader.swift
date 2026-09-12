// Clean-room format inputs: 指定レポート Ch.00・01・02・04・06 の散文に基づく。
// XADMaster / The Unarchiver / stuffit-go 等の実装ソースは参照していない。
import Foundation

final class StuffItReader: FormatReader {
    let format: ArchiveFormat = .stuffIt
    let entries: [ArchiveEntry]
    let nameEncoding: String.Encoding?
    private let source: any ByteSource
    // 書庫自身の resource fork を保持する。MKey / SitC の解釈は slice 2 で追加する。
    let archiveResourceFork: (any ByteSource)?
    private let records: [StuffItRecord]

    init(source: any ByteSource, resourceFork: (any ByteSource)? = nil, options: ReaderOptions) throws {
        self.source = source
        self.archiveResourceFork = resourceFork
        let prefix = try readByteRange(source: source, offset: 0, count: Int(min(source.length, 100)))
        guard let container = StuffItHeader.signature(prefix) else { throw KaitoError.unsupportedFormat }
        var parser = StuffItParser(source: source, limits: options.limits)
        if container == "classic" { try parser.classic() } else { try parser.stuffIt5() }
        records = parser.records
        let names = records.map(\.rawName)
        var encoding = EncodingDetector.detectArchiveEncoding(names: names, policy: options.encodingPolicy,
                                                              maximumBatchByteCount: try Checked.toInt(options.limits.maxMetadataSize))
        // 日本語の推定を維持し、それ以外の未宣言の旧 Mac 名は MacRoman を既定候補とする。
        if case .automatic = options.encodingPolicy, encoding != nil,
           encoding != .shiftJIS, encoding != .japaneseEUC, encoding != .utf8 {
            encoding = .macOSRoman
        }
        nameEncoding = encoding
        var result: [ArchiveEntry] = []
        var pathBytes: UInt64 = 0
        for record in records {
            let resolved = EncodingDetector.resolveUndeclaredName(bytes: record.rawName, policy: options.encodingPolicy,
                                                                  archiveEncoding: encoding).string
            let suffix = record.resource ? [resolved, "..namedfork", "rsrc"] : [resolved]
            let parent = record.parent.map { result[$0].pathComponents } ?? []
            guard parent.count + suffix.count <= options.limits.maxPathComponentCount else { throw KaitoError.limitExceeded("StuffIt path components") }
            let path = parent + suffix
            for component in path { pathBytes = try Checked.add(pathBytes, UInt64(component.utf8.count + 16)) }
            try Checked.size(Checked.add(pathBytes, parser.metadataSize), limit: options.limits.maxTotalMetadataSize)
            var metadata = record.metadata
            if !record.directory { metadata["fork"] = record.resource ? "resource" : "data" }
            result.append(ArchiveEntry(index: result.count, rawName: RawName(bytes: record.rawName, isDirectoryHint: record.directory),
                name: suffix.joined(separator: "/"), pathComponents: path, kind: record.directory ? .directory : .file,
                uncompressedSize: record.size, compressedSize: record.stored,
                modificationDate: Date(timeIntervalSince1970: Double(record.modified) - 2_082_844_800),
                posixPermissions: nil, isEncrypted: record.encrypted, solidGroup: -1, crc32: nil,
                methodDescription: record.directory ? "Directory" : Self.methodName(record.method), formatSpecific: metadata))
        }
        entries = result
    }

    static func methodName(_ method: Int) -> String {
        let names = [0: "Stored", 1: "RLE90", 2: "LZW", 3: "Huffman", 5: "LZAH", 6: "Fixed Huffman",
                     8: "MW", 13: "LZ+Huffman", 14: "Installer", 15: "Arsenic"]
        return "StuffIt method \(method) (\(names[method] ?? "Unknown"))"
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        guard records.indices.contains(entry.index), entries[entry.index] == entry else { throw KaitoError.notFound("StuffIt entry") }
        let r = records[entry.index]
        if r.encrypted && !r.directory { throw KaitoError.unsupportedMethod("StuffIt encryption") }
        let decoder: any Decompressor
        if r.directory {
            decoder = try CopyDecompressor(source: source, offset: 0, compressedSize: 0)
        } else {
            decoder = try StuffItCodec.make(method: r.method, source: source, offset: r.offset,
                                            stored: r.stored, size: r.size, limits: limits)
        }
        return try EntryStream(decompressor: decoder, length: r.size, expectedCRC32: nil,
                               expectedCRC16: r.directory || r.method == 15 ? nil : r.crc,
                               entryIndex: entry.index, limits: limits)
    }
}
