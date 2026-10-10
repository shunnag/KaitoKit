import Foundation

// gzip / bzip2 / XZ / zstd / LZ4 / UNIX compress / LZMA_Alone / lzip / brotli / pbzx を単一 entry として公開する。
final class SingleFileReader: FormatReader {
    let format: ArchiveFormat
    let entries: [ArchiveEntry]
    let nameEncoding: String.Encoding?

    private let source: any ByteSource
    private let decodeThreads: Int
    private var gzipHeaderLength: UInt64?

    var tarSpliceGzipHeaderLength: UInt64? { gzipHeaderLength }

    // fallbackFileName は通常 URL の末尾要素。gzip の FNAME を優先する。
    init(
        source: any ByteSource,
        format: ArchiveFormat,
        options: ReaderOptions,
        fallbackFileName: String?
    ) throws {
        guard Self.supportedFormats.contains(format) else {
            throw KaitoError.unsupportedFormat
        }
        guard options.limits.maxEntryCount >= 1 else {
            throw KaitoError.limitExceeded("archive entry count")
        }
        self.source = source
        self.decodeThreads = options.resolvedDecodeThreads
        self.format = format

        var storedName = Self.fallbackName(fallbackFileName, format: format)
        var modificationDate: Date? = nil
        var uncompressedSize: UInt64?
        switch format {
        case .gzip:
            let header = try GzipHeaderParser.parseFirstHeader(
                source: source,
                limits: options.limits
            )
            gzipHeaderLength = header.length
            if let originalName = header.originalName {
                storedName = StoredName(bytes: originalName, declaredEncoding: nil)
            }
            modificationDate = header.modificationDate

        case .bzip2:
            try Self.validateBzip2Header(source: source)

        case .xz:
            try Self.validateXZHeader(source: source)

        case .compress:
            // LZW の確保と shift の前に maxbits を検証する。
            _ = try LZWDecoder(source: source)

        case .zstd:
            uncompressedSize = try ZstdDecompressor.contentSize(source: source, limits: options.limits)

        case .lz4:
            uncompressedSize = try LZ4FrameDecompressor.contentSize(source: source, limits: options.limits)

        case .lzma:
            let header = try LZMAAloneHeader.read(source: source, limits: options.limits)
            uncompressedSize = header.uncompressedSize

        case .lzip:
            // 末尾の member size を辿る索引で全 member の構造と合計サイズを open 時に確定する。
            uncompressedSize = try LzipMemberIndex(source: source, limits: options.limits).totalDataSize

        case .brotli:
            // header の window を辞書上限と照合する。サイズと checksum は形式に無い。
            _ = try BrotliDecompressor.validateHeader(source: source, limits: options.limits)

        case .pbzx:
            // chunk 表を歩いて展開後サイズを確定する（chunk 数と合計は上限で制限）。
            uncompressedSize = try PbzxDecompressor.contentSize(source: source, limits: options.limits)

        default:
            throw KaitoError.unsupportedFormat
        }

        let resolved = try Self.resolveName(storedName, policy: options.encodingPolicy)
        nameEncoding = resolved.archiveEncoding
        let components = try ArchivePath.components(
            of: resolved.string,
            limit: options.limits.maxPathComponentCount,
            label: "single-file path component count"
        )
        guard !components.isEmpty else {
            throw KaitoError.malformed("single-file entry name is empty")
        }

        let metadataSize = try Checked.add(
            UInt64(storedName.bytes.count),
            UInt64(resolved.string.utf8.count)
        )
        try Checked.size(metadataSize, limit: options.limits.maxTotalMetadataSize)
        let rawName = RawName(
            bytes: storedName.bytes,
            declaredEncoding: storedName.declaredEncoding
        )
        entries = [ArchiveEntry(
            index: 0,
            rawName: rawName,
            name: resolved.string,
            pathComponents: components,
            kind: .file,
            uncompressedSize: uncompressedSize,
            compressedSize: source.length,
            modificationDate: modificationDate,
            posixPermissions: nil,
            isEncrypted: false,
            solidGroup: -1,
            crc32: nil,
            methodDescription: Self.methodDescription(format),
            formatSpecific: ["singleFileFormat": format.rawValue]
        )]
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        guard entry.index == 0, entries.first == entry else {
            throw KaitoError.notFound("single-file entry index \(entry.index)")
        }
        return try EntryStream(
            decompressor: makeStreamDecompressor(limits: limits),
            length: entry.uncompressedSize,
            expectedCRC32: nil,
            entryIndex: 0,
            limits: limits
        )
    }

    func stagingStream(limits: ReadLimits, recorder: CompressedTarMapRecorder?) throws -> EntryStream {
        if let gzipHeaderLength { recorder?.prepareGzip(headerLength: gzipHeaderLength) }
        return try EntryStream(
            decompressor: makeStreamDecompressor(limits: limits, recorder: recorder),
            length: entries[0].uncompressedSize, expectedCRC32: nil, entryIndex: 0, limits: limits)
    }

    private func makeStreamDecompressor(limits: ReadLimits, recorder: CompressedTarMapRecorder? = nil) throws -> any Decompressor {
        if format == .bzip2 {
            return try ParallelBzip2Decompressor(source: source, limits: limits, recorder: recorder, workers: decodeThreads)
        } else if format == .xz {
            return try ParallelXZDecompressor(source: source, limits: limits, recorder: recorder, workers: decodeThreads)
        } else if format == .zstd {
            return try ZstdDecompressor.parallel(source: source, limits: limits, workers: decodeThreads)
        } else if format == .lzip {
            return try LzipDecompressor.parallel(source: source, limits: limits, workers: decodeThreads)
        } else if format == .pbzx {
            return try PbzxDecompressor.parallel(source: source, limits: limits, workers: decodeThreads)
        } else {
            return try Self.makeDecompressor(format: format, source: source, limits: limits, recorder: recorder)
        }
    }

    static func makeDecompressor(
        format: ArchiveFormat,
        source: any ByteSource,
        limits: ReadLimits,
        recorder: CompressedTarMapRecorder? = nil
    ) throws -> any Decompressor {
        switch format {
        case .gzip:
            return try GzipDecompressor(source: source, recorder: recorder)
        case .bzip2:
            return try Bzip2Decompressor(
                source: source,
                offset: 0,
                compressedSize: source.length,
                concatenatedStreams: true,
                recorder: recorder
            )
        case .xz:
            return try XZDecompressor(source: source, limits: limits, recorder: recorder)
        case .zstd:
            return try ZstdDecompressor(source: source, limits: limits)
        case .lz4:
            return try LZ4FrameDecompressor(source: source, limits: limits)
        case .compress:
            return try LZWDecoder(source: source)
        case .lzma:
            let header = try LZMAAloneHeader.read(source: source, limits: limits)
            return try LZMADecoder(
                source: source,
                offset: 13,
                compressedSize: Checked.sub(source.length, 13),
                properties: header.properties,
                expectedSize: header.uncompressedSize,
                dictionarySizeLimit: limits.maxDictionarySize
            )
        case .lzip:
            return try LzipDecompressor(source: source, limits: limits)
        case .brotli:
            return try BrotliDecompressor(source: source, limits: limits)
        case .pbzx:
            return try PbzxDecompressor(source: source, limits: limits)
        default:
            throw KaitoError.unsupportedFormat
        }
    }

    static let supportedFormats: Set<ArchiveFormat> = [
        .gzip, .bzip2, .xz, .zstd, .lz4, .compress, .lzma, .lzip, .brotli, .pbzx
    ]

    private struct StoredName {
        let bytes: [UInt8]
        let declaredEncoding: String.Encoding?
    }

    private static func resolveName(
        _ stored: StoredName,
        policy: EncodingPolicy
    ) throws -> (string: String, archiveEncoding: String.Encoding?) {
        if let declared = stored.declaredEncoding {
            guard let string = EncodingDetector.decode(bytes: stored.bytes, as: declared) else {
                throw KaitoError.malformed("single-file name does not match its encoding")
            }
            return (string, nil)
        }

        let archiveEncoding = EncodingDetector.detectArchiveEncoding(
            names: [stored.bytes],
            policy: policy
        )
        if let archiveEncoding,
           let decoded = EncodingDetector.decode(bytes: stored.bytes, as: archiveEncoding) {
            return (decoded, archiveEncoding)
        }
        let detected = EncodingDetector.detect(bytes: stored.bytes, policy: policy)
        return (detected.string, archiveEncoding)
    }

    private static func fallbackName(
        _ fileName: String?,
        format: ArchiveFormat
    ) -> StoredName {
        let supplied = fileName.flatMap { $0.isEmpty ? nil : $0 } ?? "data"
        let lowered = supplied.lowercased()
        var resolved = supplied
        if let row = CompressedNaming.stripRows(for: format).first(where: { lowered.hasSuffix($0.suffix) }) {
            resolved.removeLast(row.suffix.count)
            if !resolved.isEmpty, row.impliesTar {
                resolved += ".tar"
            }
        }
        if resolved.isEmpty { resolved = "data" }
        return StoredName(bytes: Array(resolved.utf8), declaredEncoding: .utf8)
    }

    private static func validateBzip2Header(source: any ByteSource) throws {
        guard source.length >= 4 else { throw KaitoError.truncated }
        let header = try readByteRange(source: source, offset: 0, count: 4)
        guard header[0] == 0x42, header[1] == 0x5a, header[2] == 0x68 else {
            throw KaitoError.unsupportedFormat
        }
        guard (0x31...0x39).contains(header[3]) else {
            throw KaitoError.malformed("bzip2 block-size marker is invalid")
        }
    }

    private static func validateXZHeader(source: any ByteSource) throws {
        let signature: [UInt8] = [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00]
        guard source.length >= UInt64(signature.count) else { throw KaitoError.truncated }
        guard try readByteRange(
            source: source,
            offset: 0,
            count: signature.count
        ) == signature else {
            throw KaitoError.unsupportedFormat
        }
    }

    private static func methodDescription(_ format: ArchiveFormat) -> String {
        switch format {
        case .gzip: "DEFLATE (gzip)"
        case .bzip2: "BZip2"
        case .xz: "LZMA (XZ)"
        case .zstd: "Zstandard"
        case .lz4: "LZ4"
        case .compress: "LZW (compress)"
        case .lzma: "LZMA (Alone)"
        case .lzip: "LZMA (lzip)"
        case .brotli: "Brotli"
        case .pbzx: "XZ (pbzx)"
        default: format.rawValue
        }
    }
}
