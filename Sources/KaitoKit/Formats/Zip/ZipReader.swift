import Foundation

// 参照仕様: PKWARE APPNOTE.TXT 6.3.x。中央ディレクトリを唯一の索引として扱う。
final class ZipReader: FormatReader {
    private static let localHeaderSignature: UInt32 = 0x0403_4b50
    private static let centralHeaderSignature: UInt32 = 0x0201_4b50
    private static let endSignature: UInt32 = 0x0605_4b50
    private static let zip64EndSignature: UInt32 = 0x0606_4b50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4b50
    private static let endMinimumSize = 22
    private static let maximumCommentSize = 65_535

    private enum Encryption {
        case none
        case traditional
        case aes(extra: [UInt8], vendorVersion: UInt16, strength: UInt8)
    }

    private struct Record {
        let localHeaderOffset: UInt64
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let crc32: UInt32?
        let storedCRC32: UInt32
        let flags: UInt16
        let method: UInt16
        let headerMethod: UInt16
        let encryption: Encryption
    }

    private struct LocalRecord {
        let dataOffset: UInt64
        let usesDataDescriptor: Bool
        let dosTime: UInt16
    }

    private struct DirectoryLocation {
        let archiveBase: UInt64
        let offset: UInt64
        let size: UInt64
        let entryCount: Int
    }

    private struct ArchiveNames {
        let encoding: String.Encoding?
        let decoded: [String?]
    }

    private struct EndRecord {
        let offset: UInt64
        let diskNumber: UInt16
        let centralDirectoryDisk: UInt16
        let entriesOnDisk: UInt16
        let totalEntries: UInt16
        let centralDirectorySize: UInt32
        let centralDirectoryOffset: UInt32
    }

    let format: ArchiveFormat = .zip
    private(set) var entries: [ArchiveEntry]
    private(set) var nameEncoding: String.Encoding?

    private let source: any ByteSource
    private let centralDirectoryOffset: UInt64
    private let records: [Record]
    private var localRecords: [LocalRecord?]
    private var password: String?
    private var aesDerivedKeyCache: [WinZipAESKeyCacheKey: WinZipAESDerivedKeys] = [:]

    init(source: any ByteSource, options: ReaderOptions) throws {
        self.source = source
        self.password = options.password

        let directory = try Self.locateCentralDirectory(
            source: source,
            limits: options.limits
        )
        let parsed = try Self.parseCentralDirectory(
            source: source,
            location: directory,
            policy: options.encodingPolicy,
            limits: options.limits
        )
        self.centralDirectoryOffset = directory.offset
        self.entries = parsed.entries
        self.nameEncoding = parsed.nameEncoding
        self.records = parsed.records
        self.localRecords = Array(repeating: nil, count: parsed.records.count)

        if !options.lazyLocalHeaders {
            for index in records.indices {
                _ = try localRecord(at: index, limits: options.limits)
            }
        }
    }

    func setPassword(_ password: String?) {
        self.password = password
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        guard entry.index >= 0,
              entry.index < records.count,
              entries[entry.index] == entry else {
            throw KaitoError.notFound("zip entry index \(entry.index)")
        }

        let record = records[entry.index]
        let local = try localRecord(at: entry.index, limits: limits)
        let payload = try payloadSource(
            record: record,
            local: local,
            limits: limits
        )
        let decompressor = try makeDecompressor(
            method: record.method,
            flags: record.flags,
            source: payload.source,
            offset: payload.offset,
            compressedSize: payload.size,
            uncompressedSize: record.uncompressedSize,
            limits: limits
        )
        return try EntryStream(
            decompressor: decompressor,
            length: record.uncompressedSize,
            expectedCRC32: record.crc32,
            entryIndex: entry.index,
            limits: limits,
            completionCheck: payload.completionCheck
        )
    }

    private func localRecord(at index: Int, limits: ReadLimits) throws -> LocalRecord {
        if let cached = localRecords[index] {
            return cached
        }
        let central = records[index]
        let fixedSize: UInt64 = 30
        let fixedEnd = try Checked.add(central.localHeaderOffset, fixedSize)
        guard fixedEnd <= centralDirectoryOffset else {
            throw KaitoError.malformed("ZIP local header overlaps the central directory")
        }
        let fixed = try Self.readExactly(
            source: source,
            offset: central.localHeaderOffset,
            count: 30
        )
        var cursor = ZipByteCursor(fixed)
        guard try cursor.readUInt32LE() == Self.localHeaderSignature else {
            throw KaitoError.malformed("invalid ZIP local-header signature")
        }
        _ = try cursor.readUInt16LE() // 展開に必要なバージョン
        let localFlags = try cursor.readUInt16LE()
        guard localFlags & 0x0040 == 0 else {
            throw KaitoError.unsupportedMethod("strong ZIP encryption")
        }
        _ = try cursor.readUInt16LE() // 圧縮方式は中央ディレクトリを正とする
        let localDOSTime = try cursor.readUInt16LE()
        _ = try cursor.readUInt16LE() // DOS 日付
        _ = try cursor.readUInt32LE() // descriptor 使用時は 0 の場合がある CRC
        let localCompressed32 = try cursor.readUInt32LE()
        let localUncompressed32 = try cursor.readUInt32LE()
        let nameLength = UInt64(try cursor.readUInt16LE())
        let extraLength = UInt64(try cursor.readUInt16LE())

        // 名前長は中央値と照合せず、ローカルヘッダを飛ばすためだけに使う。
        var dataOffset = try Checked.add(fixedEnd, nameLength)
        let extraOffset = dataOffset
        dataOffset = try Checked.add(dataOffset, extraLength)
        guard dataOffset <= centralDirectoryOffset else {
            throw KaitoError.malformed("ZIP local metadata overlaps the central directory")
        }

        let localEncrypted = localFlags & 0x0001 != 0
        let centralEncrypted = central.flags & 0x0001 != 0
        guard localEncrypted == centralEncrypted else {
            throw KaitoError.malformed("ZIP encryption flag differs between headers")
        }

        if extraLength > 0 {
            try Checked.size(extraLength, limit: limits.maxMetadataSize)
            let extra = try Self.readExactly(
                source: source,
                offset: extraOffset,
                count: try Checked.toInt(extraLength)
            )
            let fields = try Self.parseExtraFields(
                extra,
                recordLimit: limits.maxMetadataRecordCount
            )
            if localCompressed32 == UInt32.max || localUncompressed32 == UInt32.max {
                guard let zip64 = Self.uniqueExtra(0x0001, in: fields) else {
                    throw KaitoError.malformed("ZIP64 local sizes are missing")
                }
                var zip64Cursor = ZipByteCursor(zip64)
                if localUncompressed32 == UInt32.max {
                    _ = try zip64Cursor.readUInt64LE()
                }
                if localCompressed32 == UInt32.max {
                    _ = try zip64Cursor.readUInt64LE()
                }
            }
        } else if localCompressed32 == UInt32.max || localUncompressed32 == UInt32.max {
            throw KaitoError.malformed("ZIP64 local sizes are missing")
        }

        let dataEnd = try Checked.add(dataOffset, central.compressedSize)
        guard dataEnd <= centralDirectoryOffset else {
            throw KaitoError.malformed("ZIP entry data overlaps the central directory")
        }
        let local = LocalRecord(
            dataOffset: dataOffset,
            usesDataDescriptor: localFlags & 0x0008 != 0,
            dosTime: localDOSTime
        )
        localRecords[index] = local
        return local
    }

    private func payloadSource(
        record: Record,
        local: LocalRecord,
        limits: ReadLimits
    ) throws -> (
        source: any ByteSource,
        offset: UInt64,
        size: UInt64,
        completionCheck: (() throws -> Void)?
    ) {
        switch record.encryption {
        case .none:
            return (source, local.dataOffset, record.compressedSize, nil)
        case .traditional:
            guard let password else {
                throw KaitoError.passwordRequired
            }
            let decrypted = try ZipCryptoByteSource(
                source: source,
                offset: local.dataOffset,
                compressedSize: record.compressedSize,
                password: password,
                crc32: record.storedCRC32,
                dosTime: local.dosTime,
                usesDataDescriptor: local.usesDataDescriptor
            )
            return (decrypted, 0, decrypted.length, nil)

        case let .aes(extra, _, _):
            guard let password else {
                throw KaitoError.passwordRequired
            }
            let metadata = try WinZipAESMetadata(extraFieldPayload: Data(extra))
            let result = try WinZipAES.prepareStreamingDecryption(
                source: source,
                offset: local.dataOffset,
                compressedSize: record.compressedSize,
                password: password,
                metadata: metadata,
                cachedKeysFor: { [weak self] key in
                    self?.aesDerivedKeyCache[key]
                }
            )
            let derivedKeys = result.derivedKeys
            let cacheKey = result.cacheKey
            let shouldCacheDerivedKeys = result.shouldCacheDerivedKeys
            let decryptedSource = result.source
            let completionCheck = { [weak self] in
                try decryptedSource.finishAndVerify()
                if shouldCacheDerivedKeys {
                    // HMAC 検証成功後の鍵だけを保持する。
                    self?.aesDerivedKeyCache[cacheKey] = derivedKeys
                }
            }
            return (
                result.source,
                0,
                result.source.length,
                completionCheck
            )
        }
    }

    private func makeDecompressor(
        method: UInt16,
        flags: UInt16,
        source: any ByteSource,
        offset: UInt64,
        compressedSize: UInt64,
        uncompressedSize: UInt64,
        limits: ReadLimits
    ) throws -> any Decompressor {
        switch method {
        case 0:
            return try CopyDecompressor(
                source: source,
                offset: offset,
                compressedSize: compressedSize
            )
        case 8:
            return try DeflateDecompressor(
                source: source,
                offset: offset,
                compressedSize: compressedSize
            )
        case 9:
            return try Deflate64Decompressor(
                source: source,
                offset: offset,
                compressedSize: compressedSize,
                expectedSize: uncompressedSize
            )
        case 12:
            return try Bzip2Decompressor(
                source: source,
                offset: offset,
                compressedSize: compressedSize
            )
        case 14:
            guard compressedSize >= 4 else { throw KaitoError.truncated }
            let prefix = try Self.readExactly(source: source, offset: offset, count: 4)
            var cursor = ZipByteCursor(prefix)
            _ = try cursor.readUInt16LE() // 情報用途だけの LZMA SDK バージョン
            let propertyLength = UInt64(try cursor.readUInt16LE())
            guard propertyLength == 5 else {
                throw KaitoError.malformed("ZIP LZMA properties must contain five bytes")
            }
            let headerSize = try Checked.add(4, propertyLength)
            guard headerSize <= compressedSize else { throw KaitoError.truncated }
            let propertiesOffset = try Checked.add(offset, 4)
            let properties = try Self.readExactly(
                source: source,
                offset: propertiesOffset,
                count: try Checked.toInt(propertyLength)
            )
            let streamOffset = try Checked.add(offset, headerSize)
            let streamSize = try Checked.sub(compressedSize, headerSize)
            return try LZMADecoder(
                source: source,
                offset: streamOffset,
                compressedSize: streamSize,
                properties: properties,
                // APPNOTE: method 14 の bit 1 は EOS marker が保存済みであることを示す。
                // その場合は decoder 自身に marker まで到達させ、EntryStream 側で
                // 中央ディレクトリの宣言長との一致を別に検証する。
                expectedSize: flags & 0x0002 != 0 ? nil : uncompressedSize,
                dictionarySizeLimit: limits.maxDictionarySize
            )
        case 93, 95, 96, 98:
            throw KaitoError.unsupportedMethod(String(method))
        default:
            throw KaitoError.unsupportedMethod(String(method))
        }
    }

    private static func locateCentralDirectory(
        source: any ByteSource,
        limits: ReadLimits
    ) throws -> DirectoryLocation {
        let end = try findEndRecord(source: source)
        let usesZIP64 = end.diskNumber == UInt16.max
            || end.centralDirectoryDisk == UInt16.max
            || end.entriesOnDisk == UInt16.max
            || end.totalEntries == UInt16.max
            || end.centralDirectorySize == UInt32.max
            || end.centralDirectoryOffset == UInt32.max

        if usesZIP64 {
            return try locateZIP64Directory(source: source, end: end, limits: limits)
        }

        guard end.diskNumber == 0,
              end.centralDirectoryDisk == 0,
              end.entriesOnDisk == end.totalEntries else {
            throw KaitoError.unsupportedMethod("spanned")
        }
        let count = Int(end.totalEntries)
        guard count <= limits.maxEntryCount else {
            throw KaitoError.limitExceeded("ZIP entry count")
        }
        let size = UInt64(end.centralDirectorySize)
        try Checked.size(size, limit: limits.maxMetadataSize)
        let relativeOffset = UInt64(end.centralDirectoryOffset)
        let beforeOffset = try Checked.sub(end.offset, size)
        let archiveBase = try Checked.sub(beforeOffset, relativeOffset)
        let absoluteOffset = try Checked.add(archiveBase, relativeOffset)
        let directoryEnd = try Checked.add(absoluteOffset, size)
        guard directoryEnd == end.offset, directoryEnd <= source.length else {
            throw KaitoError.malformed("ZIP central directory lies outside the file")
        }
        return DirectoryLocation(
            archiveBase: archiveBase,
            offset: absoluteOffset,
            size: size,
            entryCount: count
        )
    }

    private static func findEndRecord(source: any ByteSource) throws -> EndRecord {
        guard source.length >= UInt64(endMinimumSize) else {
            throw KaitoError.truncated
        }
        let maximum = endMinimumSize + maximumCommentSize
        let count = try Checked.toInt(min(source.length, UInt64(maximum)))
        let tailOffset = try Checked.sub(source.length, UInt64(count))
        let tail = try readExactly(source: source, offset: tailOffset, count: count)

        for index in stride(from: tail.count - endMinimumSize, through: 0, by: -1) {
            guard littleUInt32(tail, at: index) == endSignature else { continue }
            let commentLength = Int(littleUInt16(tail, at: index + 20))
            guard index + endMinimumSize + commentLength == tail.count else { continue }
            var cursor = ZipByteCursor(Array(tail[index..<(index + endMinimumSize)]))
            _ = try cursor.readUInt32LE()
            return EndRecord(
                offset: try Checked.add(tailOffset, UInt64(index)),
                diskNumber: try cursor.readUInt16LE(),
                centralDirectoryDisk: try cursor.readUInt16LE(),
                entriesOnDisk: try cursor.readUInt16LE(),
                totalEntries: try cursor.readUInt16LE(),
                centralDirectorySize: try cursor.readUInt32LE(),
                centralDirectoryOffset: try cursor.readUInt32LE()
            )
        }
        throw KaitoError.malformed("ZIP end-of-central-directory record was not found")
    }

    private static func locateZIP64Directory(
        source: any ByteSource,
        end: EndRecord,
        limits: ReadLimits
    ) throws -> DirectoryLocation {
        guard (end.diskNumber == 0 || end.diskNumber == UInt16.max),
              (end.centralDirectoryDisk == 0
                  || end.centralDirectoryDisk == UInt16.max) else {
            throw KaitoError.unsupportedMethod("spanned")
        }
        guard end.offset >= 20 else { throw KaitoError.truncated }
        let locatorOffset = try Checked.sub(end.offset, 20)
        let locatorBytes = try readExactly(source: source, offset: locatorOffset, count: 20)
        var locator = ZipByteCursor(locatorBytes)
        guard try locator.readUInt32LE() == zip64LocatorSignature else {
            throw KaitoError.malformed("ZIP64 locator is missing")
        }
        let recordDisk = try locator.readUInt32LE()
        let relativeRecordOffset = try locator.readUInt64LE()
        let diskCount = try locator.readUInt32LE()
        guard recordDisk == 0, diskCount == 1 else {
            throw KaitoError.unsupportedMethod("spanned")
        }

        let recordOffset = try findZIP64RecordOffset(
            source: source,
            locatorOffset: locatorOffset,
            limits: limits
        )
        let fixed = try readExactly(source: source, offset: recordOffset, count: 56)
        var record = ZipByteCursor(fixed)
        guard try record.readUInt32LE() == zip64EndSignature else {
            throw KaitoError.malformed("invalid ZIP64 end record")
        }
        let payloadSize = try record.readUInt64LE()
        guard payloadSize >= 44 else {
            throw KaitoError.malformed("undersized ZIP64 end record")
        }
        let fullRecordSize = try Checked.add(payloadSize, 12)
        try Checked.size(fullRecordSize, limit: limits.maxMetadataSize)
        guard try Checked.add(recordOffset, fullRecordSize) == locatorOffset else {
            throw KaitoError.malformed("ZIP64 end-record length is inconsistent")
        }
        _ = try record.readUInt16LE() // 作成元バージョン
        _ = try record.readUInt16LE() // 展開に必要なバージョン
        let disk = try record.readUInt32LE()
        let centralDisk = try record.readUInt32LE()
        let entriesOnDisk = try record.readUInt64LE()
        let totalEntries = try record.readUInt64LE()
        let directorySize = try record.readUInt64LE()
        let relativeDirectoryOffset = try record.readUInt64LE()
        guard disk == 0, centralDisk == 0, entriesOnDisk == totalEntries else {
            throw KaitoError.unsupportedMethod("spanned")
        }

        if end.entriesOnDisk != UInt16.max,
           UInt64(end.entriesOnDisk) != entriesOnDisk {
            throw KaitoError.malformed("ZIP32 and ZIP64 entry counts disagree")
        }
        if end.totalEntries != UInt16.max,
           UInt64(end.totalEntries) != totalEntries {
            throw KaitoError.malformed("ZIP32 and ZIP64 entry counts disagree")
        }
        if end.centralDirectorySize != UInt32.max,
           UInt64(end.centralDirectorySize) != directorySize {
            throw KaitoError.malformed("ZIP32 and ZIP64 directory sizes disagree")
        }
        if end.centralDirectoryOffset != UInt32.max,
           UInt64(end.centralDirectoryOffset) != relativeDirectoryOffset {
            throw KaitoError.malformed("ZIP32 and ZIP64 directory offsets disagree")
        }

        let count = try Checked.toInt(totalEntries)
        guard count <= limits.maxEntryCount else {
            throw KaitoError.limitExceeded("ZIP entry count")
        }
        try Checked.size(directorySize, limit: limits.maxMetadataSize)
        let archiveBase = try Checked.sub(recordOffset, relativeRecordOffset)
        let absoluteDirectoryOffset = try Checked.add(archiveBase, relativeDirectoryOffset)
        let directoryEnd = try Checked.add(absoluteDirectoryOffset, directorySize)
        guard directoryEnd <= recordOffset, directoryEnd <= source.length else {
            throw KaitoError.malformed("ZIP64 central directory lies outside the file")
        }
        return DirectoryLocation(
            archiveBase: archiveBase,
            offset: absoluteDirectoryOffset,
            size: directorySize,
            entryCount: count
        )
    }

    private static func findZIP64RecordOffset(
        source: any ByteSource,
        locatorOffset: UInt64,
        limits: ReadLimits
    ) throws -> UInt64 {
        guard locatorOffset >= 56 else { throw KaitoError.truncated }
        guard limits.maxMetadataSize >= 56 else {
            throw KaitoError.limitExceeded("ZIP64 end record")
        }
        let searchSize = min(locatorOffset, limits.maxMetadataSize)
        let searchCount = try Checked.toInt(searchSize)
        let searchOffset = try Checked.sub(locatorOffset, searchSize)
        let bytes = try readExactly(source: source, offset: searchOffset, count: searchCount)
        guard bytes.count >= 56 else { throw KaitoError.truncated }

        for index in stride(from: bytes.count - 56, through: 0, by: -1) {
            guard littleUInt32(bytes, at: index) == zip64EndSignature else { continue }
            let payloadSize = littleUInt64(bytes, at: index + 4)
            guard payloadSize >= 44 else { continue }
            let total: UInt64
            do {
                total = try Checked.add(payloadSize, 12)
            } catch {
                continue
            }
            guard total <= limits.maxMetadataSize else { continue }
            let absolute = try Checked.add(searchOffset, UInt64(index))
            guard (try? Checked.add(absolute, total)) == locatorOffset else { continue }
            return absolute
        }
        throw KaitoError.malformed("ZIP64 end record was not found")
    }

    private static func parseCentralDirectory(
        source: any ByteSource,
        location: DirectoryLocation,
        policy: EncodingPolicy,
        limits: ReadLimits
    ) throws -> (
        entries: [ArchiveEntry],
        records: [Record],
        nameEncoding: String.Encoding?
    ) {
        let bytes = try readExactly(
            source: source,
            offset: location.offset,
            count: try Checked.toInt(location.size)
        )
        // 固定部だけでも一件 46 バイト必要。偽の巨大 count で reserveCapacity を
        // 先に膨らませず、中央ディレクトリとの整合性を確保してから配列を予約する。
        guard location.entryCount <= bytes.count / 46 else {
            throw KaitoError.malformed(
                "ZIP central-directory entry count exceeds its data"
            )
        }
        let minimumRetainedMetadata = try Checked.mul(
            UInt64(location.entryCount),
            256
        )
        try Checked.size(
            minimumRetainedMetadata,
            limit: limits.maxTotalMetadataSize
        )
        let archiveNames = try archiveNames(
            in: bytes,
            entryCount: location.entryCount,
            policy: policy,
            recordLimit: limits.maxMetadataRecordCount
        )
        var cursor = ZipByteCursor(bytes)
        var entries: [ArchiveEntry] = []
        var records: [Record] = []
        entries.reserveCapacity(location.entryCount)
        records.reserveCapacity(location.entryCount)
        var retainedMetadataSize: UInt64 = 0
        var archiveNameIndex = 0

        for index in 0..<location.entryCount {
            guard cursor.remaining >= 46 else {
                throw KaitoError.malformed("ZIP central-directory entry count exceeds its data")
            }
            guard try cursor.readUInt32LE() == centralHeaderSignature else {
                throw KaitoError.malformed("invalid ZIP central-header signature")
            }
            let versionMadeBy = try cursor.readUInt16LE()
            _ = try cursor.readUInt16LE() // 展開に必要なバージョン
            let flags = try cursor.readUInt16LE()
            let headerMethod = try cursor.readUInt16LE()
            let dosTime = try cursor.readUInt16LE()
            let dosDate = try cursor.readUInt16LE()
            let storedCRC = try cursor.readUInt32LE()
            let compressed32 = try cursor.readUInt32LE()
            let uncompressed32 = try cursor.readUInt32LE()
            let nameLength = Int(try cursor.readUInt16LE())
            let extraLength = Int(try cursor.readUInt16LE())
            let commentLength = Int(try cursor.readUInt16LE())
            let diskStart16 = try cursor.readUInt16LE()
            _ = try cursor.readUInt16LE() // 内部属性
            let externalAttributes = try cursor.readUInt32LE()
            let localOffset32 = try cursor.readUInt32LE()

            guard nameLength > 0 else {
                throw KaitoError.malformed("ZIP entry has an empty name")
            }
            let variableLength = try Checked.add(UInt64(nameLength), UInt64(extraLength))
            let fullVariableLength = try Checked.add(variableLength, UInt64(commentLength))
            guard fullVariableLength <= UInt64(cursor.remaining) else {
                throw KaitoError.malformed("ZIP central variable fields overrun the directory")
            }
            let rawName = try cursor.readBytes(nameLength)
            let extra = try cursor.readBytes(extraLength)
            try cursor.skip(commentLength)
            guard !rawName.contains(0) else {
                throw KaitoError.malformed("ZIP entry name contains NUL")
            }

            let extraFields = try parseExtraFields(
                extra,
                recordLimit: limits.maxMetadataRecordCount
            )
            let zip64 = try resolveZIP64Values(
                compressed32: compressed32,
                uncompressed32: uncompressed32,
                localOffset32: localOffset32,
                diskStart16: diskStart16,
                fields: extraFields
            )
            guard zip64.diskStart == 0 else {
                throw KaitoError.unsupportedMethod("spanned")
            }
            try Checked.size(zip64.compressedSize, limit: limits.maxEntrySize)
            try Checked.size(zip64.uncompressedSize, limit: limits.maxEntrySize)

            let absoluteLocalOffset = try Checked.add(
                location.archiveBase,
                zip64.localHeaderOffset
            )
            guard absoluteLocalOffset < location.offset else {
                throw KaitoError.malformed("ZIP local header overlaps the central directory")
            }

            let aes = try parseAESExtra(fields: extraFields, headerMethod: headerMethod)
            let encryption: Encryption
            let method: UInt16
            let expectedCRC: UInt32?
            guard flags & 0x0040 == 0 else {
                throw KaitoError.unsupportedMethod("strong ZIP encryption")
            }
            if let aes {
                guard flags & 0x0001 != 0 else {
                    throw KaitoError.malformed("WinZip AES entry lacks the encryption flag")
                }
                if aes.vendorVersion == 2, storedCRC != 0 {
                    throw KaitoError.malformed("WinZip AE-2 entry has a nonzero CRC")
                }
                encryption = .aes(
                    extra: aes.data,
                    vendorVersion: aes.vendorVersion,
                    strength: aes.strength
                )
                method = aes.actualMethod
                expectedCRC = aes.vendorVersion == 2 ? nil : storedCRC
            } else if flags & 0x0001 != 0 {
                encryption = .traditional
                method = headerMethod
                expectedCRC = storedCRC
            } else {
                encryption = .none
                method = headerMethod
                expectedCRC = storedCRC
            }

            let hostOS = UInt8(truncatingIfNeeded: versionMadeBy >> 8)
            let unicodeName = unicodePath(from: extraFields, rawName: rawName)
            let declaredEncoding: String.Encoding? = flags & 0x0800 != 0 ? .utf8 : nil
            let name: String
            if let declaredEncoding {
                guard let decoded = EncodingDetector.decode(bytes: rawName, as: declaredEncoding) else {
                    throw KaitoError.malformed("ZIP UTF-8 name is invalid")
                }
                name = decoded
            } else if let unicodeName {
                name = unicodeName
            } else {
                let archiveDecodedName: String?
                if participatesInArchiveDetection(rawName, policy: policy) {
                    guard archiveNameIndex < archiveNames.decoded.count else {
                        throw KaitoError.malformed("ZIP archive-name index is inconsistent")
                    }
                    archiveDecodedName = archiveNames.decoded[archiveNameIndex]
                    archiveNameIndex += 1
                } else {
                    archiveDecodedName = nil
                }
                name = archiveDecodedName ??
                    EncodingDetector.resolveUndeclaredName(
                        bytes: rawName,
                        policy: policy,
                        archiveEncoding: archiveNames.encoding,
                        fromWindows: hostOS == 0
                    ).string
            }
            guard !name.isEmpty, !name.utf8.contains(0) else {
                throw KaitoError.malformed("ZIP entry name cannot be decoded safely")
            }
            let pathComponents = name
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard pathComponents.count <= limits.maxPathComponentCount else {
                throw KaitoError.limitExceeded("ZIP path component count")
            }

            let unixMode = UInt16(truncatingIfNeeded: externalAttributes >> 16)
            let isSymbolicLink = unixMode & 0o170000 == 0o120000
            let dosDirectory = externalAttributes & 0x10 != 0 && zip64.uncompressedSize == 0
            let kind: EntryKind
            if isSymbolicLink {
                kind = .symlink
            } else if name.hasSuffix("/") || dosDirectory {
                kind = .directory
            } else {
                kind = .file
            }
            let permissions: UInt16? = unixMode == 0 ? nil : unixMode & 0o7777
            let modificationDate = try modificationDate(
                fields: extraFields,
                dosDate: dosDate,
                dosTime: dosTime
            )
            let encryptionDescription: String
            switch encryption {
            case .none: encryptionDescription = "none"
            case .traditional: encryptionDescription = "ZipCrypto"
            case let .aes(_, _, strength):
                encryptionDescription = "AES-\(aesBitCount(strength))"
            }
            let methodName = methodDescription(method)
            var specific: [String: String] = [
                "method": String(method),
                "versionMadeBy": String(versionMadeBy),
                "flags": String(format: "0x%04x", flags),
                "hostOS": String(hostOS),
                "encryption": encryptionDescription,
            ]
            if isSymbolicLink {
                specific["linkTargetStoredAsData"] = "true"
            }

            let metadataCost = try retainedMetadataCost(
                rawName: rawName,
                name: name,
                components: pathComponents,
                specific: specific
            )
            retainedMetadataSize = try Checked.add(retainedMetadataSize, metadataCost)
            try Checked.size(retainedMetadataSize, limit: limits.maxTotalMetadataSize)

            let entry = ArchiveEntry(
                index: index,
                rawName: RawName(
                    bytes: rawName,
                    declaredEncoding: declaredEncoding,
                    isDirectoryHint: kind == .directory
                ),
                name: name,
                pathComponents: pathComponents,
                kind: kind,
                uncompressedSize: zip64.uncompressedSize,
                compressedSize: zip64.compressedSize,
                modificationDate: modificationDate,
                posixPermissions: permissions,
                isEncrypted: flags & 0x0001 != 0,
                solidGroup: -1,
                crc32: expectedCRC,
                methodDescription: methodName,
                formatSpecific: specific
            )
            entries.append(entry)
            records.append(Record(
                localHeaderOffset: absoluteLocalOffset,
                compressedSize: zip64.compressedSize,
                uncompressedSize: zip64.uncompressedSize,
                crc32: expectedCRC,
                storedCRC32: storedCRC,
                flags: flags,
                method: method,
                headerMethod: headerMethod,
                encryption: encryption
            ))
        }

        guard cursor.remaining == 0 else {
            throw KaitoError.malformed("ZIP central-directory count does not match its data")
        }
        guard archiveNameIndex == archiveNames.decoded.count else {
            throw KaitoError.malformed("ZIP archive-name count is inconsistent")
        }
        return (entries, records, archiveNames.encoding)
    }

    private static func archiveNames(
        in bytes: [UInt8],
        entryCount: Int,
        policy: EncodingPolicy,
        recordLimit: Int
    ) throws -> ArchiveNames {
        var cursor = ZipByteCursor(bytes)
        var undecoratedNames: [[UInt8]] = []
        undecoratedNames.reserveCapacity(entryCount)
        var windowsNameCount = 0

        for _ in 0..<entryCount {
            guard cursor.remaining >= 46,
                  try cursor.readUInt32LE() == centralHeaderSignature else {
                throw KaitoError.malformed("invalid ZIP central-header signature")
            }
            let versionMadeBy = try cursor.readUInt16LE()
            try cursor.skip(2) // 展開に必要なバージョン
            let flags = try cursor.readUInt16LE()
            try cursor.skip(18) // method から uncompressed size まで
            let nameLength = Int(try cursor.readUInt16LE())
            let extraLength = Int(try cursor.readUInt16LE())
            let commentLength = Int(try cursor.readUInt16LE())
            try cursor.skip(12) // disk number から local-header offset まで

            guard nameLength > 0 else {
                throw KaitoError.malformed("ZIP entry has an empty name")
            }
            let variableLength = try Checked.add(UInt64(nameLength), UInt64(extraLength))
            let fullVariableLength = try Checked.add(variableLength, UInt64(commentLength))
            guard fullVariableLength <= UInt64(cursor.remaining) else {
                throw KaitoError.malformed("ZIP central variable fields overrun the directory")
            }
            let rawName = try cursor.readBytes(nameLength)
            let extra = try cursor.readBytes(extraLength)
            try cursor.skip(commentLength)
            guard !rawName.contains(0) else {
                throw KaitoError.malformed("ZIP entry name contains NUL")
            }

            guard flags & 0x0800 == 0 else { continue }
            let extraFields = try parseExtraFields(extra, recordLimit: recordLimit)
            guard unicodePath(from: extraFields, rawName: rawName) == nil else { continue }
            guard participatesInArchiveDetection(rawName, policy: policy) else { continue }
            undecoratedNames.append(rawName)
            if UInt8(truncatingIfNeeded: versionMadeBy >> 8) == 0 {
                windowsNameCount += 1
            }
        }

        guard cursor.remaining == 0 else {
            throw KaitoError.malformed("ZIP central-directory count does not match its data")
        }
        let fromWindows = windowsNameCount >= undecoratedNames.count - windowsNameCount
        let encoding = EncodingDetector.detectArchiveEncoding(
            names: undecoratedNames,
            policy: policy,
            fromWindows: fromWindows
        )
        guard let encoding else {
            return ArchiveNames(encoding: nil, decoded: [])
        }
        let decodedNames = EncodingDetector.decodeArchiveNames(
            undecoratedNames,
            as: encoding
        )
        return ArchiveNames(encoding: encoding, decoded: decodedNames)
    }

    private static func participatesInArchiveDetection(
        _ rawName: [UInt8],
        policy: EncodingPolicy
    ) -> Bool {
        switch policy {
        case .fixed:
            return true
        case .automatic, .utf8Only:
            return !EncodingDetector.isStrictUTF8(rawName)
        }
    }

    private struct ZIP64Values {
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
        let diskStart: UInt32
    }

    private static func resolveZIP64Values(
        compressed32: UInt32,
        uncompressed32: UInt32,
        localOffset32: UInt32,
        diskStart16: UInt16,
        fields: [ZipExtraField]
    ) throws -> ZIP64Values {
        let needsZIP64 = compressed32 == UInt32.max
            || uncompressed32 == UInt32.max
            || localOffset32 == UInt32.max
            || diskStart16 == UInt16.max
        guard needsZIP64 else {
            return ZIP64Values(
                compressedSize: UInt64(compressed32),
                uncompressedSize: UInt64(uncompressed32),
                localHeaderOffset: UInt64(localOffset32),
                diskStart: UInt32(diskStart16)
            )
        }
        guard let data = uniqueExtra(0x0001, in: fields) else {
            throw KaitoError.malformed("ZIP64 central values are missing")
        }
        var cursor = ZipByteCursor(data)
        let uncompressed = uncompressed32 == UInt32.max
            ? try cursor.readUInt64LE() : UInt64(uncompressed32)
        let compressed = compressed32 == UInt32.max
            ? try cursor.readUInt64LE() : UInt64(compressed32)
        let local = localOffset32 == UInt32.max
            ? try cursor.readUInt64LE() : UInt64(localOffset32)
        let disk = diskStart16 == UInt16.max
            ? try cursor.readUInt32LE() : UInt32(diskStart16)
        return ZIP64Values(
            compressedSize: compressed,
            uncompressedSize: uncompressed,
            localHeaderOffset: local,
            diskStart: disk
        )
    }

    private struct AESExtra {
        let data: [UInt8]
        let vendorVersion: UInt16
        let strength: UInt8
        let actualMethod: UInt16
    }

    private static func parseAESExtra(
        fields: [ZipExtraField],
        headerMethod: UInt16
    ) throws -> AESExtra? {
        let matching = fields.filter { $0.identifier == 0x9901 }
        guard !matching.isEmpty else {
            if headerMethod == 99 {
                throw KaitoError.malformed("WinZip AES extra field is missing")
            }
            return nil
        }
        guard matching.count == 1, headerMethod == 99 else {
            throw KaitoError.malformed("ambiguous WinZip AES metadata")
        }
        let data = matching[0].data
        guard data.count == 7 else {
            throw KaitoError.malformed("invalid WinZip AES extra-field length")
        }
        var cursor = ZipByteCursor(data)
        let version = try cursor.readUInt16LE()
        let vendor0 = try cursor.readUInt8()
        let vendor1 = try cursor.readUInt8()
        let strength = try cursor.readUInt8()
        let method = try cursor.readUInt16LE()
        guard (version == 1 || version == 2),
              vendor0 == 0x41, vendor1 == 0x45,
              (1...3).contains(strength),
              method != 99 else {
            throw KaitoError.malformed("invalid WinZip AES metadata")
        }
        return AESExtra(
            data: data,
            vendorVersion: version,
            strength: strength,
            actualMethod: method
        )
    }

    private static func unicodePath(
        from fields: [ZipExtraField],
        rawName: [UInt8]
    ) -> String? {
        for field in fields where field.identifier == 0x7075 {
            guard field.data.count >= 5, field.data[0] == 1 else { continue }
            let expected = littleUInt32(field.data, at: 1)
            guard CRC32.checksum(rawName) == expected else { continue }
            let nameBytes = Array(field.data.dropFirst(5))
            guard let decoded = EncodingDetector.decode(bytes: nameBytes, as: .utf8),
                  !decoded.isEmpty else { continue }
            return decoded
        }
        return nil
    }

    private static func modificationDate(
        fields: [ZipExtraField],
        dosDate: UInt16,
        dosTime: UInt16
    ) throws -> Date? {
        var unixDate: Date?
        if let timestamp = fields.first(where: { $0.identifier == 0x5455 })?.data,
           timestamp.count >= 5,
           timestamp[0] & 0x01 != 0 {
            let seconds = Int32(bitPattern: littleUInt32(timestamp, at: 1))
            unixDate = Date(timeIntervalSince1970: TimeInterval(seconds))
        }

        var ntfsDate: Date?
        if let ntfs = fields.first(where: { $0.identifier == 0x000a })?.data,
           ntfs.count >= 4 {
            var cursor = ZipByteCursor(Array(ntfs.dropFirst(4)))
            while cursor.remaining > 0 {
                guard cursor.remaining >= 4 else {
                    throw KaitoError.malformed("truncated ZIP NTFS extra field")
                }
                let tag = try cursor.readUInt16LE()
                let length = Int(try cursor.readUInt16LE())
                guard length <= cursor.remaining else {
                    throw KaitoError.malformed("ZIP NTFS attribute overruns its extra field")
                }
                let value = try cursor.readBytes(length)
                if tag == 1, value.count >= 8 {
                    let ticks = littleUInt64(value, at: 0)
                    let interval = Double(ticks) / 10_000_000.0 - 11_644_473_600.0
                    guard interval.isFinite else {
                        throw KaitoError.malformed("ZIP NTFS timestamp is out of range")
                    }
                    ntfsDate = Date(timeIntervalSince1970: interval)
                    break
                }
            }
        }
        if let ntfsDate { return ntfsDate }
        if let unixDate { return unixDate }
        return try dosModificationDate(date: dosDate, time: dosTime)
    }

    private static func dosModificationDate(date: UInt16, time: UInt16) throws -> Date? {
        guard date != 0 else { return nil }
        let day = Int(date & 0x001f)
        let month = Int((date >> 5) & 0x000f)
        let year = Int((date >> 9) & 0x007f) + 1980
        let second = Int(time & 0x001f) * 2
        let minute = Int((time >> 5) & 0x003f)
        let hour = Int((time >> 11) & 0x001f)
        guard (1...31).contains(day),
              (1...12).contains(month),
              (0...59).contains(second),
              (0...59).contains(minute),
              (0...23).contains(hour) else {
            throw KaitoError.malformed("invalid ZIP DOS timestamp")
        }
        var calendar = Calendar(identifier: .gregorian)
        // DOS 日時には timezone が無いため、APPNOTE の慣例どおり現在のローカル時刻として解釈する。
        calendar.timeZone = .current
        // Calendar.date(from:) は 2 月 31 日などを翌月へ正規化するため、先に月内の日数を検証する。
        guard let monthStart = calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: 1
        )),
            let validDays = calendar.range(of: .day, in: .month, for: monthStart),
            validDays.contains(day)
        else {
            throw KaitoError.malformed("invalid ZIP DOS timestamp")
        }
        guard let result = calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )) else {
            throw KaitoError.malformed("invalid ZIP DOS timestamp")
        }
        return result
    }

    private static func methodDescription(_ method: UInt16) -> String {
        switch method {
        case 0: "stored"
        case 8: "deflate"
        case 9: "deflate64"
        case 12: "bzip2"
        case 14: "lzma"
        case 93: "zstd"
        case 95: "xz"
        case 96: "jpeg"
        case 98: "ppmd"
        default: "method \(method)"
        }
    }

    private static func aesBitCount(_ strength: UInt8) -> Int {
        switch strength {
        case 1: 128
        case 2: 192
        case 3: 256
        default: 0
        }
    }

    private static func retainedMetadataCost(
        rawName: [UInt8],
        name: String,
        components: [String],
        specific: [String: String]
    ) throws -> UInt64 {
        var size: UInt64 = 256
        size = try Checked.add(size, UInt64(rawName.count))
        size = try Checked.add(size, UInt64(name.utf8.count))
        size = try Checked.add(
            size,
            try Checked.mul(
                UInt64(components.count),
                UInt64(MemoryLayout<String>.stride)
            )
        )
        for component in components {
            size = try Checked.add(size, UInt64(component.utf8.count))
        }
        for (key, value) in specific {
            size = try Checked.add(size, UInt64(key.utf8.count))
            size = try Checked.add(size, UInt64(value.utf8.count))
        }
        return size
    }

    private static func parseExtraFields(
        _ bytes: [UInt8],
        recordLimit: Int
    ) throws -> [ZipExtraField] {
        guard recordLimit >= 0 else {
            throw KaitoError.limitExceeded("ZIP extra-field record count")
        }
        var cursor = ZipByteCursor(bytes)
        var fields: [ZipExtraField] = []
        while cursor.remaining > 0 {
            guard cursor.remaining >= 4 else {
                throw KaitoError.malformed("truncated ZIP extra-field header")
            }
            guard fields.count < recordLimit else {
                throw KaitoError.limitExceeded("ZIP extra-field record count")
            }
            let identifier = try cursor.readUInt16LE()
            let length = Int(try cursor.readUInt16LE())
            guard length <= cursor.remaining else {
                throw KaitoError.malformed("ZIP extra field overruns its containing header")
            }
            fields.append(ZipExtraField(
                identifier: identifier,
                data: try cursor.readBytes(length)
            ))
        }
        return fields
    }

    private static func uniqueExtra(
        _ identifier: UInt16,
        in fields: [ZipExtraField]
    ) -> [UInt8]? {
        let matches = fields.filter { $0.identifier == identifier }
        guard matches.count == 1 else { return nil }
        return matches[0].data
    }

    private static func readExactly(
        source: any ByteSource,
        offset: UInt64,
        count: Int
    ) throws -> [UInt8] {
        guard count >= 0 else {
            throw KaitoError.malformed("negative ZIP read size")
        }
        let end = try Checked.add(offset, UInt64(count))
        guard end <= source.length else { throw KaitoError.truncated }
        guard count > 0 else { return [] }
        return try readByteRange(source: source, offset: offset, count: count)
    }

    private static func littleUInt16(_ bytes: [UInt8], at index: Int) -> UInt16 {
        UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
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

private struct ZipExtraField {
    let identifier: UInt16
    let data: [UInt8]
}

private struct ZipByteCursor {
    private let bytes: [UInt8]
    private(set) var offset: Int = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var remaining: Int {
        bytes.count - offset
    }

    mutating func readUInt8() throws -> UInt8 {
        guard remaining >= 1 else { throw KaitoError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt16LE() throws -> UInt16 {
        let low = UInt16(try readUInt8())
        return low | UInt16(try readUInt8()) << 8
    }

    mutating func readUInt32LE() throws -> UInt32 {
        var result: UInt32 = 0
        for shift in stride(from: 0, to: 32, by: 8) {
            result |= UInt32(try readUInt8()) << shift
        }
        return result
    }

    mutating func readUInt64LE() throws -> UInt64 {
        var result: UInt64 = 0
        for shift in stride(from: 0, to: 64, by: 8) {
            result |= UInt64(try readUInt8()) << shift
        }
        return result
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= remaining else { throw KaitoError.truncated }
        let end = offset + count
        defer { offset = end }
        return Array(bytes[offset..<end])
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, count <= remaining else { throw KaitoError.truncated }
        offset += count
    }
}
