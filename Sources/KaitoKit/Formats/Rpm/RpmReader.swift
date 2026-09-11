// Linux Standard Base「Package File Format」、rpm(8)、rpm.org の prose、
// RFC 1950/1951/1952 を許可資料とする利用者提供の実測 byte 表に基づくクリーンルーム実装。
// rpm / libarchive / 7-Zip / XADMaster / The Unarchiver / dpkg 等、他の実装 source は参照していない。
import Foundation

final class RpmReader: FormatReader {
    let format: ArchiveFormat = .rpm
    let entries: [ArchiveEntry]
    var nameEncoding: String.Encoding? { cpio?.nameEncoding }
    private let payload: any ByteSource
    private let cpio: CpioReader?

    init(source: any ByteSource, options: ReaderOptions) throws {
        let limits = options.limits
        let header = try RpmHeader(source: source, limits: limits)
        payload = try RebasedByteSource(source: source, baseOffset: header.payloadStart)
        let declaredCompressor = header.values[.payloadCompressor]
        let prefix = try readByteRange(source: payload, offset: 0, count: Checked.toInt(min(6, payload.length)))
        // 古い package の tag 欠落や誤った宣言でも、実体の magic が示す codec を優先する。
        let detectedCompressor: String?
        if prefix.starts(with: [0x30, 0x37, 0x30, 0x37]) { detectedCompressor = "none" }
        else if prefix.starts(with: [0x1f, 0x8b]) { detectedCompressor = "gzip" }
        else if prefix.starts(with: [0x42, 0x5a, 0x68]) { detectedCompressor = "bzip2" }
        else if prefix.starts(with: [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00]) { detectedCompressor = "xz" }
        else if ZstdFrameHeader.hasMagic(prefix) { detectedCompressor = "zstd" }
        else { detectedCompressor = nil }
        let compressor = detectedCompressor ?? declaredCompressor
        var metadata = header.metadata
        if let detectedCompressor, detectedCompressor != declaredCompressor {
            // 宣言値は診断用に保存し、相違がある場合だけ実体の判定を併記する。
            metadata["rpmPayloadCompressorDetected"] = detectedCompressor
        }
        let codecs: [String: ArchiveFormat] = ["gzip": .gzip, "bzip2": .bzip2, "xz": .xz, "lzma": .lzma, "zstd": .zstd]
        let extensions = ["gzip": ".gz", "bzip2": ".bz2", "xz": ".xz", "lzma": ".lzma", "zstd": ".zst"]
        var inner: CpioReader?
        if header.values[.payloadFormat] == nil || header.values[.payloadFormat] == "cpio",
           compressor == "none" || codecs[compressor ?? ""] != nil {
            let stream: EntryStream
            if let compressor, let codec = codecs[compressor] {
                let single = try SingleFileReader(source: payload, format: codec, options: options,
                    fallbackFileName: nil)
                stream = try single.stream(for: single.entries[0], limits: limits)
            } else {
                stream = try EntryStream(source: payload, offset: 0, length: payload.length, limits: limits)
            }
            // tar.gz と同じ上限で staging し、復号エラーを blob fallback で隠さない。
            let expanded = try SingleFileMaterializer.materialize(stream, limits: limits)
            let magic = try readByteRange(source: expanded, offset: 0, count: Checked.toInt(min(6, expanded.length)))
            if CpioHeader.variant(magic) != nil {
                inner = try CpioReader(source: expanded, options: options)
            }
        }
        cpio = inner
        var metadataSize = header.metadataSize
        func account(_ entry: ArchiveEntry, specific: [String: String]) throws {
            var cost = try Checked.add(256, UInt64(entry.rawName.bytes.count))
            cost = try Checked.add(cost, UInt64(entry.name.utf8.count))
            cost = try Checked.add(cost, Checked.mul(UInt64(entry.pathComponents.count), UInt64(MemoryLayout<String>.stride)))
            for part in entry.pathComponents { cost = try Checked.add(cost, UInt64(part.utf8.count)) }
            for (key, value) in specific {
                cost = try Checked.add(cost, Checked.add(UInt64(key.utf8.count), UInt64(value.utf8.count)))
            }
            metadataSize = try Checked.add(metadataSize, cost)
            try Checked.size(metadataSize, limit: limits.maxTotalMetadataSize)
        }
        if let inner {
            entries = try inner.entries.map { entry in
                let specific = entry.formatSpecific.merging(metadata) { original, _ in original }
                try account(entry, specific: specific)
                return ArchiveEntry(index: entry.index, rawName: entry.rawName, name: entry.name,
                    pathComponents: entry.pathComponents, kind: entry.kind,
                    uncompressedSize: entry.uncompressedSize, compressedSize: entry.compressedSize,
                    modificationDate: entry.modificationDate, posixPermissions: entry.posixPermissions,
                    isEncrypted: entry.isEncrypted, solidGroup: entry.solidGroup, crc32: entry.crc32,
                    methodDescription: entry.methodDescription, formatSpecific: specific, isIncomplete: entry.isIncomplete)
            }
        } else {
            guard limits.maxEntryCount >= 1 else { throw KaitoError.limitExceeded("rpm entry count") }
            try Checked.size(payload.length, limit: limits.maxEntrySize)
            let name = (header.values[.name] ?? "payload") + ".cpio" + (extensions[compressor ?? ""] ?? "")
            let parts = name.utf8.split(separator: 47, maxSplits: limits.maxPathComponentCount)
            guard parts.count <= limits.maxPathComponentCount else { throw KaitoError.limitExceeded("rpm path component count") }
            let entry = ArchiveEntry(index: 0, rawName: RawName(bytes: Array(name.utf8), declaredEncoding: .utf8),
                name: name, pathComponents: parts.map { String(decoding: $0, as: UTF8.self) }, kind: .file,
                uncompressedSize: payload.length, compressedSize: payload.length,
                modificationDate: nil, posixPermissions: nil, isEncrypted: false, solidGroup: -1, crc32: nil,
                methodDescription: "rpm payload (\(compressor == "none" ? "stored" : compressor ?? "stored"))",
                formatSpecific: metadata)
            try account(entry, specific: entry.formatSpecific)
            entries = [entry]
        }
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        guard entries.indices.contains(entry.index), entries[entry.index] == entry else {
            throw KaitoError.notFound("rpm entry index \(entry.index)")
        }
        if let cpio {
            // cpio 側の同一性検査には RPM metadata を足す前の entry を渡す。
            return try cpio.stream(for: cpio.entries[entry.index], limits: limits)
        }
        return try EntryStream(source: payload, offset: 0, length: payload.length, limits: limits)
    }
}
