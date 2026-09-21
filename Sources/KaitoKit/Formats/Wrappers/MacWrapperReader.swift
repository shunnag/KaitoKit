import Foundation

/// MacBinary / AppleSingle / BinHex 4 の wrapper を、payload が StuffIt でないときに 1 file の書庫として
/// 公開する reader。data fork が entry 0、resource fork があれば `name/..namedfork/rsrc` が entry 1。
final class MacWrapperReader: FormatReader {
    let format: ArchiveFormat
    let entries: [ArchiveEntry]
    let nameEncoding: String.Encoding?
    private let envelope: StuffItEnvelope

    init(envelope: StuffItEnvelope, format: ArchiveFormat, options: ReaderOptions, fallbackFileName: String?) throws {
        guard let info = envelope.wrapper else { throw KaitoError.unsupportedFormat }
        self.envelope = envelope
        self.format = format
        try Checked.size(envelope.data.length, limit: options.limits.maxEntrySize)
        if let resource = envelope.resource { try Checked.size(resource.length, limit: options.limits.maxEntrySize) }

        // 名前は wrapper の生 byte（Mac OS Roman / Shift_JIS など）を書庫名の判定に掛ける。無ければ file 名から
        // wrapper の拡張子を 1 つ外す。
        var rawName = info.name ?? []
        var resolved: String
        var encoding: String.Encoding?
        if !rawName.isEmpty {
            encoding = EncodingDetector.detectArchiveEncoding(names: [rawName], policy: options.encodingPolicy,
                                                              maximumBatchByteCount: Int(clamping: options.limits.maxMetadataSize))
            let detection = EncodingDetector.resolveUndeclaredName(bytes: rawName, policy: options.encodingPolicy, archiveEncoding: encoding)
            resolved = detection.string
            if encoding == .shiftJIS, detection.encoding != .shiftJIS, detection.encoding != .utf8,
               let macJapanese = EncodingDetector.decodeMacJapanese(bytes: rawName) {
                resolved = macJapanese
            }
        } else {
            resolved = Self.fallbackName(fallbackFileName, kind: info.kind)
            rawName = Array(resolved.utf8)
            encoding = .utf8
        }
        // Mac の名前は `/` を含みうる（HFS の区切りは `:`）。path として安全な形に写す。
        resolved = resolved.replacingOccurrences(of: "/", with: ":")
        guard !resolved.isEmpty, resolved != ".", resolved != "..", !resolved.utf8.contains(0) else {
            throw KaitoError.malformed("\(format.rawValue) file name")
        }
        nameEncoding = encoding

        var specific: [String: String] = ["wrapper": info.kind.rawValue, "fork": "data"]
        if let type = info.type, type != 0 { specific["macType"] = Self.fourCC(type) }
        if let creator = info.creator, creator != 0 { specific["macCreator"] = Self.fourCC(creator) }
        if let flags = info.finderFlags { specific["finderFlags"] = "0x" + String(flags, radix: 16) }
        if let created = info.created { specific["created"] = ISO8601DateFormatter().string(from: created) }
        if let comment = info.comment, !comment.isEmpty {
            specific["comment"] = EncodingDetector.resolveUndeclaredName(bytes: comment, policy: options.encodingPolicy, archiveEncoding: encoding).string
        }
        let method: String
        switch info.kind {
        case .macBinary: method = "MacBinary (stored)"
        case .appleSingle: method = "AppleSingle (stored)"
        case .binHex: method = "BinHex 4.0 (RLE90)"
        }
        var result = [ArchiveEntry(index: 0, rawName: RawName(bytes: rawName, declaredEncoding: encoding == .utf8 ? .utf8 : nil),
                                   name: resolved, pathComponents: [resolved], kind: .file,
                                   uncompressedSize: envelope.data.length, compressedSize: envelope.data.length,
                                   modificationDate: info.modified, posixPermissions: nil, isEncrypted: false, solidGroup: -1,
                                   crc32: nil, methodDescription: method, formatSpecific: specific)]
        if let resource = envelope.resource, resource.length > 0 {
            var forkSpecific = specific
            forkSpecific["fork"] = "resource"
            let components = [resolved, "..namedfork", "rsrc"]
            result.append(ArchiveEntry(index: 1, rawName: RawName(bytes: Array(components.joined(separator: "/").utf8), declaredEncoding: .utf8),
                                       name: components.joined(separator: "/"), pathComponents: components, kind: .file,
                                       uncompressedSize: resource.length, compressedSize: resource.length,
                                       modificationDate: info.modified, posixPermissions: nil, isEncrypted: false, solidGroup: -1,
                                       crc32: nil, methodDescription: method, formatSpecific: forkSpecific))
        }
        entries = result
    }

    private static func fallbackName(_ fileName: String?, kind: MacWrapperInfo.Kind) -> String {
        guard let fileName, !fileName.isEmpty else { return "data" }
        let url = URL(fileURLWithPath: fileName)
        let suffixes: [String]
        switch kind {
        case .macBinary: suffixes = ["bin", "macbin", "mb"]
        case .appleSingle: suffixes = ["as", "applesingle"]
        case .binHex: suffixes = ["hqx"]
        }
        if suffixes.contains(url.pathExtension.lowercased()), !url.deletingPathExtension().lastPathComponent.isEmpty {
            return url.deletingPathExtension().lastPathComponent
        }
        return fileName
    }

    private static func fourCC(_ value: UInt32) -> String {
        let bytes = [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        if bytes.allSatisfy({ (0x20...0x7E).contains($0) }) { return String(decoding: bytes, as: UTF8.self) }
        return "0x" + String(value, radix: 16)
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        guard entries.indices.contains(entry.index), entries[entry.index] == entry else {
            throw KaitoError.notFound("\(format.rawValue) entry index \(entry.index)")
        }
        let source: any ByteSource = entry.index == 0 ? envelope.data : envelope.resource!
        return try EntryStream(source: source, offset: 0, length: source.length, limits: limits)
    }
}
