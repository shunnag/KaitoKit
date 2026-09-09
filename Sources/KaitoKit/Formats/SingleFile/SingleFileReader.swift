import Foundation

// gzip / bzip2 / XZ / UNIX compress / LZMA_Alone を単一 entry として公開する。
final class SingleFileReader: FormatReader {
    let format: ArchiveFormat
    let entries: [ArchiveEntry]
    let nameEncoding: String.Encoding?

    private let source: any ByteSource

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
        self.format = format

        let storedName: StoredName
        let modificationDate: Date?
        var uncompressedSize: UInt64?
        switch format {
        case .gzip:
            let header = try GzipHeaderParser.parseFirstHeader(
                source: source,
                limits: options.limits
            )
            if let originalName = header.originalName {
                storedName = StoredName(bytes: originalName, declaredEncoding: nil)
            } else {
                storedName = Self.fallbackName(
                    fallbackFileName,
                    format: format
                )
            }
            modificationDate = header.modificationDate

        case .bzip2:
            try Self.validateBzip2Header(source: source)
            storedName = Self.fallbackName(fallbackFileName, format: format)
            modificationDate = nil

        case .xz:
            try Self.validateXZHeader(source: source)
            storedName = Self.fallbackName(fallbackFileName, format: format)
            modificationDate = nil

        case .compress:
            // LZW の確保と shift の前に maxbits を検証する。
            _ = try LZWDecoder(source: source)
            storedName = Self.fallbackName(fallbackFileName, format: format)
            modificationDate = nil

        case .lzma:
            let header = try LZMAAloneHeader.read(source: source, limits: options.limits)
            uncompressedSize = header.uncompressedSize
            storedName = Self.fallbackName(fallbackFileName, format: format)
            modificationDate = nil

        default:
            throw KaitoError.unsupportedFormat
        }

        let resolved = try Self.resolveName(storedName, policy: options.encodingPolicy)
        nameEncoding = resolved.archiveEncoding
        let components = resolved.string
            .utf8.split(separator: 0x2F, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        guard components.count <= options.limits.maxPathComponentCount else {
            throw KaitoError.limitExceeded("single-file path component count")
        }
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
            decompressor: Self.makeDecompressor(format: format, source: source, limits: limits),
            length: entry.uncompressedSize,
            expectedCRC32: nil,
            entryIndex: 0,
            limits: limits
        )
    }

    static func makeDecompressor(
        format: ArchiveFormat,
        source: any ByteSource,
        limits: ReadLimits
    ) throws -> any Decompressor {
        switch format {
        case .gzip:
            return try GzipDecompressor(source: source)
        case .bzip2:
            return try Bzip2Decompressor(
                source: source,
                offset: 0,
                compressedSize: source.length,
                concatenatedStreams: true
            )
        case .xz:
            return try XZDecompressor(source: source)
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
        default:
            throw KaitoError.unsupportedFormat
        }
    }

    static let supportedFormats: Set<ArchiveFormat> = [
        .gzip, .bzip2, .xz, .compress, .lzma
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
        let suffixes: [String]
        switch format {
        case .gzip:
            suffixes = [".tar.gz", ".tgz", ".gz"]
        case .bzip2:
            suffixes = [".tar.bz2", ".tbz2", ".tbz", ".bz2", ".bz"]
        case .xz:
            suffixes = [".tar.xz", ".txz", ".xz"]
        case .compress:
            suffixes = [".tar.z", ".tz", ".z"]
        case .lzma:
            suffixes = [".lzma"]
        default:
            suffixes = []
        }

        var resolved = supplied
        if let suffix = suffixes.first(where: { lowered.hasSuffix($0) }) {
            resolved.removeLast(suffix.count)
            if !resolved.isEmpty,
               suffix.hasPrefix(".tar.") || suffix == ".tgz" ||
                suffix == ".tbz2" || suffix == ".tbz" ||
                suffix == ".txz" || suffix == ".tz" {
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
        case .compress: "LZW (compress)"
        case .lzma: "LZMA (Alone)"
        default: format.rawValue
        }
    }
}

// 参照仕様: Igor Pavlov, LZMA SDK lzma-specification.txt (2015-06-14)、
// 「lzma file format」と「Range Decoder」。既存 raw LZMA decoder を再利用する。
struct LZMAAloneHeader {
    let properties: [UInt8]
    let dictionarySize: UInt64
    let uncompressedSize: UInt64?

    init(bytes: [UInt8], limits: ReadLimits) throws {
        // 13-byte header と range coder の初期値 5 bytes が必要。
        guard bytes.count >= 18 else { throw KaitoError.truncated }
        guard bytes[0] < 9 * 5 * 5, bytes[13] == 0 else {
            throw KaitoError.malformed("invalid LZMA_Alone properties or range prefix")
        }
        properties = Array(bytes[..<5])
        dictionarySize = UInt64(bytes[1])
            | (UInt64(bytes[2]) << 8)
            | (UInt64(bytes[3]) << 16)
            | (UInt64(bytes[4]) << 24)
        try Checked.size(max(4_096, dictionarySize), limit: limits.maxDictionarySize)
        var size: UInt64 = 0
        for index in 0..<8 {
            size |= UInt64(bytes[5 + index]) << (index * 8)
        }
        if size == UInt64.max {
            uncompressedSize = nil
        } else {
            try Checked.size(size, limit: limits.maxEntrySize)
            try Checked.size(size, limit: limits.maxTotalUncompressedSize)
            uncompressedSize = size
        }
    }

    static func read(source: any ByteSource, limits: ReadLimits) throws -> Self {
        try Self(bytes: readByteRange(source: source, offset: 0, count: 18), limits: limits)
    }

    static func isPlausible(_ bytes: [UInt8], limits: ReadLimits) -> Bool {
        guard let header = try? Self(bytes: bytes, limits: limits) else { return false }
        let lc = Int(bytes[0]) % 9
        let lp = Int(bytes[0]) / 9 % 5
        let pb = Int(bytes[0]) / 45
        // magic が無いため検出は保守的に行う。通常の 2^n / 3*2^n 辞書だけを
        // 候補とし、ゼロ埋めを拒否する。raw decoder 自体の受理範囲は狭めない。
        let dictionary = header.dictionarySize
        let isPowerOfTwo = dictionary > 0 && dictionary & (dictionary - 1) == 0
        let third = dictionary / 3
        let isThreeTimesPowerOfTwo = dictionary.isMultiple(of: 3)
            && third > 0 && third & (third - 1) == 0
        return lc + lp <= 4 && pb <= 4 && dictionary >= 4_096
            && (isPowerOfTwo || isThreeTimesPowerOfTwo)
    }
}
