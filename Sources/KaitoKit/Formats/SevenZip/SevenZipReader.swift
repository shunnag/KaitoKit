import Foundation

// 参照仕様: LZMA SDK DOC/7zFormat.txt (18.06)。
// container 実装には XADMaster / 7-Zip C++ archive decoder のコードを取り込まず、
// 7zz は差分 oracle のみに使う。
final class SevenZipReader: FormatReader {
    private static let signature: [UInt8] = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]
    private static let signatureHeaderSize: UInt64 = 32

    private struct Record: Sendable, Equatable {
        let substream: SevenZipSubstream?
        let isEncrypted: Bool
    }

    private struct NextHeader {
        let bytes: [UInt8]
        let absoluteOffset: UInt64
    }

    private struct DecodedHeader {
        let bytes: [UInt8]
        let isEncrypted: Bool
    }

    let format: ArchiveFormat = .sevenZip
    private(set) var entries: [ArchiveEntry]
    let nameEncoding: String.Encoding? = nil

    private let source: any ByteSource
    private let limits: ReadLimits
    private let maximumAESCyclesPower: UInt8
    private let streams: SevenZipStreamsInfo?
    private let packedRanges: [[Int: SevenZipPackRange]]
    private let records: [Record]
    private let keyCache: SevenZipAESKeyCache
    private let packedStreamVerifier: SevenZipPackedStreamVerifier
    private var coordinators: [Int: SevenZipFolderCoordinator] = [:]
    private var password: String?

    var resolvedPassword: String? { password }

    init(source: any ByteSource, options: ReaderOptions) throws {
        self.source = source
        self.limits = options.limits
        self.maximumAESCyclesPower = options.maxSevenZipAESCyclesPower

        let keyCache = SevenZipAESKeyCache()
        let packedStreamVerifier = SevenZipPackedStreamVerifier(source: source)
        let metadataBudget = SevenZipMetadataBudget(
            limit: options.limits.maxTotalMetadataSize
        )
        var resolvedPassword = options.password
        let nextHeader = try Self.readNextHeader(source: source, limits: options.limits)
        let decodedHeader = try Self.decodeNextHeader(
            nextHeader.bytes,
            source: source,
            packedDataEnd: nextHeader.absoluteOffset,
            limits: options.limits,
            maximumAESCyclesPower: options.maxSevenZipAESCyclesPower,
            keyCache: keyCache,
            packedStreamVerifier: packedStreamVerifier,
            metadataBudget: metadataBudget,
            password: &resolvedPassword,
            passwordProvider: options.passwordProvider
        )
        let header: SevenZipParsedHeader
        do {
            header = try Self.parseHeader(
                decodedHeader.bytes,
                source: source,
                packedDataEnd: nextHeader.absoluteOffset,
                limits: options.limits,
                maximumAESCyclesPower: options.maxSevenZipAESCyclesPower,
                keyCache: keyCache,
                packedStreamVerifier: packedStreamVerifier,
                metadataBudget: metadataBudget,
                password: &resolvedPassword,
                passwordProvider: options.passwordProvider
            )
        } catch let error as KaitoError {
            guard decodedHeader.isEncrypted else { throw error }
            switch error {
            case .malformed, .truncated, .checksumMismatch:
                throw KaitoError.wrongPassword
            case .passwordRequired, .wrongPassword, .limitExceeded, .unsupportedMethod:
                throw error
            default:
                throw error
            }
        }
        let ranges: [[Int: SevenZipPackRange]]
        if let streams = header.streams {
            ranges = try SevenZipFolderLayout.ranges(
                for: streams,
                sourceLength: source.length,
                packedDataEnd: nextHeader.absoluteOffset
            )
        } else {
            ranges = []
        }

        let built = try Self.makeEntries(
            files: header.files,
            streams: header.streams,
            packedRanges: ranges,
            limits: options.limits,
            metadataBudget: metadataBudget
        )
        self.streams = header.streams
        self.packedRanges = ranges
        self.entries = built.entries
        self.records = built.records
        self.keyCache = keyCache
        self.packedStreamVerifier = packedStreamVerifier
        self.password = resolvedPassword
    }

    func setPassword(_ password: String?) {
        guard self.password != password else { return }
        self.password = password
        keyCache.removeAll()
        coordinators.removeAll(keepingCapacity: false)
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        guard entry.index >= 0, entry.index < records.count,
              entries[entry.index] == entry else {
            throw KaitoError.notFound("7z entry index \(entry.index)")
        }
        let record = records[entry.index]
        guard let substream = record.substream else {
            let empty = DataByteSource(data: Data())
            let decoder = try CopyDecompressor(source: empty, offset: 0, compressedSize: 0)
            return try EntryStream(
                decompressor: decoder,
                length: 0,
                expectedCRC32: entry.crc32,
                entryIndex: entry.index,
                limits: limits,
                checksumMismatchIsWrongPassword: false
            )
        }
        guard let streams,
              substream.folderIndex >= 0,
              substream.folderIndex < streams.folders.count else {
            throw KaitoError.malformed("7z entry references an invalid folder")
        }

        let folder = streams.folders[substream.folderIndex]
        if substream.offset == 0,
           substream.size == folder.unpackSizes[folder.finalOutputIndex],
           folder.coders.count == 1,
           folder.coders.first.map({ SevenZipMethod.kind(for: $0.methodID) == .copy }) == true {
            let factory = try SevenZipFolderDecoderFactory(
                source: source,
                folder: folder,
                packedRanges: packedRanges[substream.folderIndex],
                limits: self.limits,
                password: password,
                keyCache: keyCache,
                maximumAESCyclesPower: maximumAESCyclesPower,
                packedStreamVerifier: packedStreamVerifier
            )
            return try EntryStream(
                decompressor: factory.makeDecoder(),
                length: substream.size,
                expectedCRC32: substream.digest.value,
                entryIndex: entry.index,
                limits: limits
            )
        }

        let coordinator: SevenZipFolderCoordinator
        let folderHasMultipleSubstreams = entry.solidGroup >= 0
        if folderHasMultipleSubstreams,
           let cached = coordinators[substream.folderIndex] {
            coordinator = cached
        } else {
            let factory = try SevenZipFolderDecoderFactory(
                source: source,
                folder: folder,
                packedRanges: packedRanges[substream.folderIndex],
                limits: self.limits,
                password: password,
                keyCache: keyCache,
                maximumAESCyclesPower: maximumAESCyclesPower,
                packedStreamVerifier: packedStreamVerifier
            )
            coordinator = SevenZipFolderCoordinator(factory: factory)
            if folderHasMultipleSubstreams {
                coordinators[substream.folderIndex] = coordinator
            }
        }
        let decompressor = try coordinator.stream(
            offset: substream.offset,
            length: substream.size
        )
        return try EntryStream(
            decompressor: decompressor,
            length: substream.size,
            expectedCRC32: substream.digest.value,
            entryIndex: entry.index,
            limits: limits,
            checksumMismatchIsWrongPassword: record.isEncrypted
        )
    }

    private static func readNextHeader(
        source: any ByteSource,
        limits: ReadLimits
    ) throws -> NextHeader {
        guard source.length >= signatureHeaderSize else { throw KaitoError.truncated }
        let fixed = try readByteRange(source: source, offset: 0, count: 32)
        guard Array(fixed[0..<6]) == signature else {
            throw KaitoError.unsupportedFormat
        }
        guard fixed[6] == 0, fixed[7] <= 4 else {
            throw KaitoError.unsupportedMethod("7z version \(fixed[6]).\(fixed[7])")
        }
        let recordedStartCRC = littleUInt32(fixed, at: 8)
        let startBytes = Array(fixed[12..<32])
        guard CRC32.checksum(startBytes) == recordedStartCRC else {
            throw KaitoError.malformed("7z start-header CRC mismatch")
        }

        let nextOffset = littleUInt64(fixed, at: 12)
        let nextSize = littleUInt64(fixed, at: 20)
        let nextCRC = littleUInt32(fixed, at: 28)
        try Checked.size(nextSize, limit: limits.maxMetadataSize)
        let absoluteOffset = try Checked.add(signatureHeaderSize, nextOffset)
        let end = try Checked.add(absoluteOffset, nextSize)
        guard end <= source.length else {
            throw KaitoError.truncated
        }
        let bytes = try readByteRange(
            source: source,
            offset: absoluteOffset,
            count: try Checked.toInt(nextSize)
        )
        guard CRC32.checksum(bytes) == nextCRC else {
            throw KaitoError.malformed("7z next-header CRC mismatch")
        }
        return NextHeader(bytes: bytes, absoluteOffset: absoluteOffset)
    }

    private static func decodeNextHeader(
        _ bytes: [UInt8],
        source: any ByteSource,
        packedDataEnd: UInt64,
        limits: ReadLimits,
        maximumAESCyclesPower: UInt8,
        keyCache: SevenZipAESKeyCache,
        packedStreamVerifier: SevenZipPackedStreamVerifier,
        metadataBudget: SevenZipMetadataBudget,
        password: inout String?,
        passwordProvider: (any PasswordProvider)?
    ) throws -> DecodedHeader {
        guard let first = bytes.first else {
            throw KaitoError.malformed("empty 7z next header")
        }
        if first == SevenZipNID.header.rawValue {
            return DecodedHeader(bytes: bytes, isEncrypted: false)
        }
        guard first == SevenZipNID.encodedHeader.rawValue else {
            throw KaitoError.malformed("unknown 7z next-header kind")
        }

        var cursor = SevenZipHeaderCursor(Array(bytes.dropFirst()))
        let streams = try SevenZipStreamsParser.parse(
            cursor: &cursor,
            limits: limits,
            budget: metadataBudget
        )
        guard cursor.isAtEnd else {
            throw KaitoError.malformed("7z encoded header has trailing bytes")
        }
        let decoded = try decodeStreamsResolvingPassword(
            streams,
            source: source,
            packedDataEnd: packedDataEnd,
            limit: limits.maxMetadataSize,
            limits: limits,
            maximumAESCyclesPower: maximumAESCyclesPower,
            keyCache: keyCache,
            packedStreamVerifier: packedStreamVerifier,
            password: &password,
            passwordProvider: passwordProvider
        )
        guard decoded.count == 1 else {
            throw KaitoError.malformed("7z encoded header must contain one substream")
        }
        let stream = streams.substreams[0]
        guard streams.folders.indices.contains(stream.folderIndex) else {
            throw KaitoError.malformed("7z encoded header references an invalid folder")
        }
        let isEncrypted = streams.folders[stream.folderIndex].coders.contains {
            SevenZipMethod.kind(for: $0.methodID) == .aes
        }
        return DecodedHeader(bytes: [UInt8](decoded[0]), isEncrypted: isEncrypted)
    }

    private static func parseHeader(
        _ bytes: [UInt8],
        source: any ByteSource,
        packedDataEnd: UInt64,
        limits: ReadLimits,
        maximumAESCyclesPower: UInt8,
        keyCache: SevenZipAESKeyCache,
        packedStreamVerifier: SevenZipPackedStreamVerifier,
        metadataBudget: SevenZipMetadataBudget,
        password: inout String?,
        passwordProvider: (any PasswordProvider)?
    ) throws -> SevenZipParsedHeader {
        try SevenZipHeaderParser.parse(
            bytes: bytes,
            limits: limits,
            budget: metadataBudget
        ) { streams, limit in
            try decodeStreamsResolvingPassword(
                streams,
                source: source,
                packedDataEnd: packedDataEnd,
                limit: limit,
                limits: limits,
                maximumAESCyclesPower: maximumAESCyclesPower,
                keyCache: keyCache,
                packedStreamVerifier: packedStreamVerifier,
                password: &password,
                passwordProvider: passwordProvider
            )
        }
    }

    private static func decodeStreamsResolvingPassword(
        _ streams: SevenZipStreamsInfo,
        source: any ByteSource,
        packedDataEnd: UInt64,
        limit: UInt64,
        limits: ReadLimits,
        maximumAESCyclesPower: UInt8,
        keyCache: SevenZipAESKeyCache,
        packedStreamVerifier: SevenZipPackedStreamVerifier,
        password: inout String?,
        passwordProvider: (any PasswordProvider)?
    ) throws -> [Data] {
        do {
            return try decodeStreams(
                streams,
                source: source,
                packedDataEnd: packedDataEnd,
                limit: limit,
                limits: limits,
                maximumAESCyclesPower: maximumAESCyclesPower,
                keyCache: keyCache,
                packedStreamVerifier: packedStreamVerifier,
                password: password
            )
        } catch KaitoError.passwordRequired {
            guard password == nil, let passwordProvider,
                  let supplied = try passwordProvider.password(for: .sevenZip) else {
                throw KaitoError.passwordRequired
            }
            password = supplied
            return try decodeStreams(
                streams,
                source: source,
                packedDataEnd: packedDataEnd,
                limit: limit,
                limits: limits,
                maximumAESCyclesPower: maximumAESCyclesPower,
                keyCache: keyCache,
                packedStreamVerifier: packedStreamVerifier,
                password: supplied
            )
        }
    }

    private static func decodeStreams(
        _ streams: SevenZipStreamsInfo,
        source: any ByteSource,
        packedDataEnd: UInt64,
        limit: UInt64,
        limits: ReadLimits,
        maximumAESCyclesPower: UInt8,
        keyCache: SevenZipAESKeyCache,
        packedStreamVerifier: SevenZipPackedStreamVerifier,
        password: String?
    ) throws -> [Data] {
        let ranges = try SevenZipFolderLayout.ranges(
            for: streams,
            sourceLength: source.length,
            packedDataEnd: packedDataEnd
        )
        var folderData: [Data] = []
        folderData.reserveCapacity(streams.folders.count)
        var aggregate: UInt64 = 0
        for index in streams.folders.indices {
            let factory = try SevenZipFolderDecoderFactory(
                source: source,
                folder: streams.folders[index],
                packedRanges: ranges[index],
                limits: limits,
                password: password,
                keyCache: keyCache,
                maximumAESCyclesPower: maximumAESCyclesPower,
                packedStreamVerifier: packedStreamVerifier
            )
            aggregate = try Checked.add(aggregate, factory.finalSize)
            try Checked.size(aggregate, limit: limit)
            folderData.append(try factory.decodeAll(limit: limit))
        }

        var result: [Data] = []
        result.reserveCapacity(streams.substreams.count)
        for stream in streams.substreams {
            guard stream.folderIndex >= 0, stream.folderIndex < folderData.count else {
                throw KaitoError.malformed("7z substream references an invalid folder")
            }
            let data = folderData[stream.folderIndex]
            let start = try Checked.toInt(stream.offset)
            let size = try Checked.toInt(stream.size)
            guard start <= data.count, size <= data.count - start else {
                throw KaitoError.malformed("7z substream exceeds decoded folder data")
            }
            let slice: Data
            if start == 0, size == data.count {
                // 典型的な encoded header は folder 全体が 1 substream なので CoW 共有する。
                slice = data
            } else {
                slice = Data(data[start..<(start + size)])
            }
            if let expected = stream.digest.value,
               CRC32.checksum(slice) != expected {
                let encrypted = streams.folders[stream.folderIndex].coders.contains {
                    SevenZipMethod.kind(for: $0.methodID) == .aes
                }
                if encrypted { throw KaitoError.wrongPassword }
                throw KaitoError.checksumMismatch(entry: -1)
            }
            result.append(slice)
        }
        return result
    }

    private static func makeEntries(
        files: [SevenZipFileMetadata],
        streams: SevenZipStreamsInfo?,
        packedRanges: [[Int: SevenZipPackRange]],
        limits: ReadLimits,
        metadataBudget: SevenZipMetadataBudget
    ) throws -> (entries: [ArchiveEntry], records: [Record]) {
        let substreams = streams?.substreams ?? []
        let streamedFileCount = files.lazy.filter(\.hasStream).count
        guard streamedFileCount == substreams.count else {
            throw KaitoError.malformed("7z file and substream counts differ")
        }

        var folderSubstreamCounts: [Int: Int] = [:]
        for stream in substreams { folderSubstreamCounts[stream.folderIndex, default: 0] += 1 }
        var folderPackedSizes: [UInt64] = []
        if let streams {
            folderPackedSizes.reserveCapacity(streams.folders.count)
            for index in streams.folders.indices {
                var total: UInt64 = 0
                for range in packedRanges[index].values {
                    total = try Checked.add(total, range.size)
                }
                folderPackedSizes.append(total)
            }
        }

        var entries: [ArchiveEntry] = []
        var records: [Record] = []
        // ArchiveEntry/Record の backing storage を確保する前に、FilesInfo と
        // 同時保持される固定費を共有予算から先に確保する。
        try metadataBudget.reserve(
            count: files.count,
            bytesPerRecord: 256,
            description: "7z published entry metadata"
        )
        entries.reserveCapacity(files.count)
        records.reserveCapacity(files.count)
        var streamIndex = 0

        for (index, file) in files.enumerated() {
            let substream: SevenZipSubstream?
            let folder: SevenZipFolder?
            if file.hasStream {
                guard streamIndex < substreams.count, let streams else {
                    throw KaitoError.malformed("missing 7z file substream")
                }
                substream = substreams[streamIndex]
                folder = streams.folders[substreams[streamIndex].folderIndex]
                streamIndex += 1
            } else {
                substream = nil
                folder = nil
            }
            let size = substream?.size ?? 0
            try Checked.size(size, limit: limits.maxEntrySize)

            let unixMode: UInt16? = file.windowsAttributes.flatMap { attributes in
                guard attributes & 0x8000 != 0 else { return nil }
                return UInt16(truncatingIfNeeded: attributes >> 16)
            }
            let unixType = unixMode.map { $0 & 0o170000 }
            let dosDirectory = file.windowsAttributes.map { $0 & 0x10 != 0 } ?? false
            let kind: EntryKind
            if unixType == 0o120000 {
                kind = .symlink
            } else if unixType == 0o040000 || dosDirectory
                        || (!file.hasStream && !file.isEmptyFile && !file.isAnti) {
                kind = .directory
            } else {
                kind = .file
            }
            let components = file.name
                .utf8.split(separator: 0x2F, omittingEmptySubsequences: true)
                .map { String(decoding: $0, as: UTF8.self) }
            guard !components.isEmpty else {
                throw KaitoError.malformed("7z entry has an empty path")
            }
            guard components.count <= limits.maxPathComponentCount else {
                throw KaitoError.limitExceeded("7z path component count")
            }

            let encrypted = folder?.coders.contains {
                SevenZipMethod.kind(for: $0.methodID) == .aes
            } ?? false
            let methods = folder?.coders.map(SevenZipMethod.description(for:)) ?? ["Copy"]
            var specific: [String: String] = [
                "encryption": encrypted ? "7zAES-256" : "none",
                "anti": file.isAnti ? "true" : "false",
                "emptyFile": file.isEmptyFile ? "true" : "false",
                "emptyStream": file.hasStream ? "false" : "true"
            ]
            if let attributes = file.windowsAttributes {
                specific["windowsAttributes"] = String(format: "0x%08x", attributes)
            }
            if let startPosition = file.startPosition {
                specific["startPosition"] = String(startPosition)
            }
            if let creationTime = file.creationTime {
                specific["creationTime"] = String(creationTime.timeIntervalSince1970)
            }
            if let accessTime = file.accessTime {
                specific["accessTime"] = String(accessTime.timeIntervalSince1970)
            }
            if kind == .symlink { specific["linkTargetStoredAsData"] = "true" }

            var entryMetadata = try Checked.add(
                UInt64(file.rawName.count),
                UInt64(file.name.utf8.count)
            )
            entryMetadata = try Checked.add(
                entryMetadata,
                try Checked.mul(UInt64(components.count), UInt64(MemoryLayout<String>.stride))
            )
            for component in components {
                entryMetadata = try Checked.add(entryMetadata, UInt64(component.utf8.count))
            }
            try metadataBudget.reserve(
                entryMetadata,
                description: "7z published entry metadata"
            )

            let compressedSize = substream.map { folderPackedSizes[$0.folderIndex] }
            let solidGroup: Int
            if let substream,
               folderSubstreamCounts[substream.folderIndex, default: 0] > 1 {
                solidGroup = substream.folderIndex
            } else {
                solidGroup = -1
            }
            entries.append(ArchiveEntry(
                index: index,
                rawName: RawName(
                    bytes: file.rawName,
                    declaredEncoding: .utf16LittleEndian,
                    isDirectoryHint: kind == .directory
                ),
                name: file.name,
                pathComponents: components,
                kind: kind,
                uncompressedSize: size,
                compressedSize: compressedSize,
                modificationDate: file.modificationTime,
                posixPermissions: unixMode.map { $0 & 0o7777 },
                isEncrypted: encrypted,
                solidGroup: solidGroup,
                crc32: substream?.digest.value,
                methodDescription: methods.joined(separator: "+"),
                formatSpecific: specific
            ))
            records.append(Record(substream: substream, isEncrypted: encrypted))
        }
        guard streamIndex == substreams.count else {
            throw KaitoError.malformed("unused 7z substreams")
        }
        return (entries, records)
    }

    private static func littleUInt32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(bytes[index])
            | UInt32(bytes[index + 1]) << 8
            | UInt32(bytes[index + 2]) << 16
            | UInt32(bytes[index + 3]) << 24
    }

    private static func littleUInt64(_ bytes: [UInt8], at index: Int) -> UInt64 {
        UInt64(littleUInt32(bytes, at: index))
            | UInt64(littleUInt32(bytes, at: index + 4)) << 32
    }
}
