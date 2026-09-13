// Clean-room format inputs: 指定レポート Ch.00・01・02・04・06 の散文に基づく。
// XADMaster / The Unarchiver / stuffit-go 等の実装ソースは参照していない。
import Foundation

final class StuffItReader: FormatReader {
    let format: ArchiveFormat = .stuffIt
    let entries: [ArchiveEntry]
    let nameEncoding: String.Encoding?
    private let source: any ByteSource
    // メンバーの fork とは区別して書庫自身の resource fork を保持する。
    let archiveResourceFork: (any ByteSource)?
    let archiveComment: String?
    private let records: [StuffItRecord]
    private let archiveHash: [UInt8]?
    private let mkey: [UInt8]?
    private let classic: Bool
    private var password: String?

    init(source: any ByteSource, resourceFork: (any ByteSource)? = nil, options: ReaderOptions) throws {
        self.source = source
        self.archiveResourceFork = resourceFork
        let prefix = try readByteRange(source: source, offset: 0, count: Int(min(source.length, 100)))
        guard let container = StuffItHeader.signature(prefix) else { throw KaitoError.unsupportedFormat }
        classic = container == "classic"
        password = options.password
        var parser = StuffItParser(source: source, limits: options.limits)
        if container == "classic" { try parser.classic() } else { try parser.stuffIt5() }
        records = parser.records
        archiveHash = parser.archiveHash
        let resources = try resourceFork.map { try StuffItResourceMap(source: $0, limits: options.limits) }
        mkey = resources?.mkey
        archiveComment = (parser.archiveCommentBytes ?? resources?.comment).flatMap { String(bytes: $0, encoding: .macOSRoman) }
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
        var pathBytes = UInt64(archiveComment?.utf8.count ?? 0)
        try Checked.size(Checked.add(pathBytes, parser.metadataSize), limit: options.limits.maxTotalMetadataSize)
        for record in records {
            let detection = EncodingDetector.resolveUndeclaredName(bytes: record.rawName, policy: options.encodingPolicy,
                                                                   archiveEncoding: encoding)
            var resolved = detection.string
            // CP932 に成功した名と自動判定の厳密 UTF-8 は維持し、単名 fallback だけ再試行する。
            let decodedAsCP932 = detection.encoding == .shiftJIS && detection.confidence > 0
            let strictUTF8 = detection.encoding == .utf8 && detection.confidence == 1
            if encoding == .shiftJIS, !decodedAsCP932, !strictUTF8,
               let macJapanese = EncodingDetector.decodeMacJapanese(bytes: record.rawName) {
                resolved = macJapanese
            }
            let suffix = record.resource ? [resolved, "..namedfork", "rsrc"] : [resolved]
            let parent = record.parent.map { result[$0].pathComponents } ?? []
            guard parent.count + suffix.count <= options.limits.maxPathComponentCount else { throw KaitoError.limitExceeded("StuffIt path components") }
            let path = parent + suffix
            for component in path { pathBytes = try Checked.add(pathBytes, UInt64(component.utf8.count + 16)) }
            try Checked.size(Checked.add(pathBytes, parser.metadataSize), limit: options.limits.maxTotalMetadataSize)
            var metadata = record.metadata
            if result.isEmpty, let archiveComment { metadata["comment"] = archiveComment }
            if !record.directory { metadata["fork"] = record.resource ? "resource" : "data" }
            result.append(ArchiveEntry(index: result.count, rawName: RawName(bytes: record.rawName, isDirectoryHint: record.directory),
                name: path.joined(separator: "/"), pathComponents: path, kind: record.directory ? .directory : .file,
                uncompressedSize: record.size, compressedSize: record.stored,
                modificationDate: Date(timeIntervalSince1970: Double(record.modified) - 2_082_844_800),
                posixPermissions: nil, isEncrypted: record.encrypted, solidGroup: -1, crc32: nil,
                methodDescription: record.directory ? "Directory" : Self.methodName(record.method), formatSpecific: metadata))
        }
        entries = result
    }

    func setPassword(_ password: String?) { self.password = password }

    func validateEncryptionSupport(for entry: ArchiveEntry) throws {
        guard records.indices.contains(entry.index), entries[entry.index] == entry else { throw KaitoError.notFound("StuffIt entry") }
        let record = records[entry.index]
        guard record.encrypted && !record.directory else { return }
        if classic && mkey == nil {
            throw KaitoError.unsupportedMethod("StuffIt encryption without archive resource fork")
        }
        // go の newde 標本の 0x10 は Ch.05 の 0x80 と区別し、平文 codec に渡さない。
        if classic && record.encryptionFlags & 0x10 != 0 {
            throw KaitoError.unsupportedMethod("StuffIt encryption flag 0x10")
        }
        if !classic && archiveHash == nil {
            throw KaitoError.unsupportedMethod("StuffIt 5 encryption without archive password hash")
        }
    }

    static func methodName(_ method: Int) -> String {
        let names = [0: "Stored", 1: "RLE90", 2: "LZW", 3: "Huffman", 5: "LZAH", 6: "Fixed Huffman",
                     8: "MW", 13: "LZ+Huffman", 14: "Installer", 15: "Arsenic"]
        return "StuffIt method \(method) (\(names[method] ?? "Unknown"))"
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        guard records.indices.contains(entry.index), entries[entry.index] == entry else { throw KaitoError.notFound("StuffIt entry") }
        let r = records[entry.index]
        try validateEncryptionSupport(for: entry)
        let decoder: any Decompressor
        if r.directory {
            decoder = try CopyDecompressor(source: source, offset: 0, compressedSize: 0)
        } else {
            var packed: any ByteSource = source
            var offset = r.offset, stored = r.stored
            if r.encrypted {
                guard let password else { throw KaitoError.passwordRequired }
                let passwordBytes = Array(password.utf8)
                if classic {
                    guard let mkey else { throw KaitoError.unsupportedMethod("StuffIt encryption without archive resource fork") }
                    let archive = try StuffItCrypto.ClassicKeys(password: passwordBytes, mkey: mkey)
                    guard stored >= 16, (stored - 16) % 8 == 0, r.padding <= stored - 16 else {
                        throw KaitoError.malformed("StuffIt encrypted fork extent")
                    }
                    let trailer = try readByteRange(source: source, offset: offset + stored - 16, count: 16)
                    let keys = try archive.fork(trailer: trailer)
                    packed = try StuffItCryptoSource(source: source, offset: offset, stored: stored - 16,
                                                    padding: r.padding, mode: .classic(key: keys.key, iv: keys.iv))
                } else {
                    guard let archiveHash else { throw KaitoError.unsupportedMethod("StuffIt 5 encryption without archive password hash") }
                    let archiveKey = try StuffItCrypto.sit5Key(password: passwordBytes, hash: archiveHash)
                    if stored > 0 {
                        guard r.entryKey.count == 5 else { throw KaitoError.malformed("StuffIt 5 fork key length") }
                        packed = try StuffItCryptoSource(source: source, offset: offset, stored: stored, mode: .rc4(archiveKey + r.entryKey))
                    } else { packed = DataByteSource(data: Data()) }
                }
                offset = 0; stored = packed.length
            }
            decoder = try StuffItCodec.make(method: r.method, source: packed, offset: offset,
                                            stored: stored, size: r.size, limits: limits)
        }
        return try EntryStream(decompressor: decoder, length: r.size, expectedCRC32: nil,
                               expectedCRC16: r.directory || r.method == 15 ? nil : r.crc,
                               entryIndex: entry.index, limits: limits)
    }
}
