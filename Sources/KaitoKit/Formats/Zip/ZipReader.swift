import Darwin
import Foundation

// 参照仕様: PKWARE APPNOTE.TXT 6.3.x。通常は中央ディレクトリを索引として扱う。
final class ZipReader: FormatReader {
    private static let maximumEndRecordCandidateAttempts = 8_192

    // ZipCrypto の 1 byte 検査値を誤通過した password は、復号後の破損と区別できない。
    // そのため展開中の構造的な失敗（malformed・truncated・checksumMismatch）を wrongPassword として返す。
    private final class ZipPasswordAmbiguousDecompressor: Decompressor {
        private let base: any Decompressor
        private var remaining: UInt64?

        init(_ base: any Decompressor, expectedSize: UInt64?) {
            self.base = base
            self.remaining = expectedSize
        }

        var isFinished: Bool { base.isFinished }

        func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
            do {
                let count = try base.read(into: buffer)
                guard count >= 0, count <= buffer.count else {
                    throw KaitoError.malformed("decompressor returned an invalid byte count")
                }
                // EntryStream の宣言長検証より先に、短すぎる／長すぎる出力も正規化する。
                if let remaining {
                    guard UInt64(count) <= remaining else {
                        throw KaitoError.malformed("entry output exceeds its declared size")
                    }
                    self.remaining = remaining - UInt64(count)
                }
                guard buffer.isEmpty || count > 0
                    || (base.isFinished && (remaining ?? 0) == 0) else {
                    throw KaitoError.truncated
                }
                return count
            } catch {
                throw Self.asWrongPassword(error)
            }
        }

        static func asWrongPassword(_ error: Error) -> Error {
            guard let kaito = error as? KaitoError else { return error }
            switch kaito {
            case .malformed, .truncated, .checksumMismatch:
                return KaitoError.wrongPassword
            default:
                return error
            }
        }
    }

    private struct LocalRecord {
        let dataOffset: UInt64
        let usesDataDescriptor: Bool
        let dosTime: UInt16
        let usesZIP64: Bool
        var rawRecordEnd: UInt64? = nil
    }

    private typealias EndRecord = ZipEndRecords.EndRecord

    struct EndRecordParseBudget {
        var remainingAttempts: Int
        var remainingMetadataBytes: UInt64
        private var exemptsFirstAttempt: Bool
        private var attemptCount = 0

        init(limits: ReadLimits, exemptsFirstAttempt: Bool = false) {
            self.exemptsFirstAttempt = exemptsFirstAttempt
            remainingAttempts = ZipReader.maximumEndRecordCandidateAttempts
            let doubled = limits.maxMetadataSize.multipliedReportingOverflow(by: 2)
            remainingMetadataBytes = doubled.overflow ? UInt64.max : doubled.partialValue
        }

        mutating func chargeAttempt() throws {
            guard remainingAttempts > 0 else {
                throw KaitoError.limitExceeded("ZIP end-record candidate attempts")
            }
            remainingAttempts -= 1
            attemptCount += 1
        }

        mutating func endFirstAttemptExemption() {
            exemptsFirstAttempt = false
        }

        mutating func chargeMetadataBytes(_ count: UInt64) throws {
            // 初回の通常解析だけを免除し、エラー後の整合性検査にも累積予算を適用する。
            if exemptsFirstAttempt, attemptCount == 1 { return }
            guard count <= remainingMetadataBytes else {
                throw KaitoError.limitExceeded("ZIP end-record candidate metadata work")
            }
            remainingMetadataBytes -= count
        }
    }

    let format: ArchiveFormat = .zip
    let entries: [ArchiveEntry]
    let nameEncoding: String.Encoding?

    private let source: any ByteSource
    private let centralDirectoryOffset: UInt64
    private let records: [ZipEntryRecord]
    private let localHeaderOrder: [Int]
    private let localHeaderOrderPositions: [Int]
    private var localRecords: [LocalRecord?] = []
    private var validatedLocalRangePosition = -1
    // 通常の読取は従来どおり payload まで。descriptor を含む検証の進捗は分離する。
    private var validatedRawRangePosition = -1
    private var password: String?
    private var aesDerivedKeyCache: [WinZipAESKeyCacheKey: WinZipAESDerivedKeys] = [:]
    private var localReadAhead: ZipLocalReadAhead

    init(source: any ByteSource, options: ReaderOptions, diskLayout: ZipDiskLayout? = nil,
         readAhead: ZipLocalReadAheadPolicy = .standard) throws {
        self.source = source
        self.password = options.password
        self.localReadAhead = ZipLocalReadAhead(policy: readAhead)

        let parsedDirectory: ZipParsedDirectory
        // 巻の欠落を部分成功で隠さず、先頭の spanning 署名を descriptor と誤認しない。
        if diskLayout == nil, options.recoverDamagedArchives,
           try source.length < UInt64(ZipEndRecords.endMinimumSize)
                || (ZipEndRecords.findEndRecords(
                    source: source,
                    maximumSearchSize: ZipEndRecords.endMinimumSize + ZipEndRecords.maximumCommentSize
                        + ZipEndRecords.maximumTrailingDataSize
                )).isEmpty {
            parsedDirectory = try ZipLocalHeaderRecovery.recover(
                source: source, policy: options.encodingPolicy, limits: options.limits
            )
        } else {
            parsedDirectory = try Self.locateAndParseCentralDirectory(
                source: source,
                diskLayout: diskLayout,
                policy: options.encodingPolicy,
                limits: options.limits
            )
        }
        self.centralDirectoryOffset = parsedDirectory.location.offset
        self.entries = parsedDirectory.entries
        self.nameEncoding = parsedDirectory.nameEncoding
        self.records = parsedDirectory.records
        var comparisonCount = 0
        let localHeaderOrder = try parsedDirectory.records.indices.sorted { lhs, rhs in
            try checkCancellation(every: comparisonCount)
            comparisonCount &+= 1
            let lhsOffset = parsedDirectory.records[lhs].localHeaderOffset
            let rhsOffset = parsedDirectory.records[rhs].localHeaderOffset
            return lhsOffset == rhsOffset ? lhs < rhs : lhsOffset < rhsOffset
        }
        var localHeaderOrderPositions = Array(
            repeating: 0,
            count: parsedDirectory.records.count
        )
        for (position, index) in localHeaderOrder.enumerated() {
            try checkCancellation(every: position)
            localHeaderOrderPositions[index] = position
        }
        self.localHeaderOrder = localHeaderOrder
        self.localHeaderOrderPositions = localHeaderOrderPositions
        if !options.lazyLocalHeaders || options.recoverDamagedArchives {
            for index in records.indices {
                try checkCancellation(every: index)
                _ = try localRecord(at: index, limits: options.limits)
            }
        }
    }

    private init(source: any ByteSource, options: ReaderOptions,
                 centralDirectoryOffset: UInt64, records: [ZipEntryRecord],
                 localHeaderOrder: [Int], localHeaderOrderPositions: [Int],
                 entries: [ArchiveEntry], nameEncoding: String.Encoding?,
                 readAhead: ZipLocalReadAheadPolicy = .standard) {
        self.source = source
        self.centralDirectoryOffset = centralDirectoryOffset
        self.records = records
        self.localHeaderOrder = localHeaderOrder
        self.localHeaderOrderPositions = localHeaderOrderPositions
        self.entries = entries
        self.nameEncoding = nameEncoding
        self.password = options.password
        self.localReadAhead = ZipLocalReadAhead(policy: readAhead)
    }

    func reopened(options: ReaderOptions) -> sending (any FormatReader)? {
        // Parsed arrays are immutable COW values. Local validation progress,
        // cached headers and derived AES keys start empty in each reader.
        ZipReader(source: source, options: options, centralDirectoryOffset: centralDirectoryOffset,
                  records: records, localHeaderOrder: localHeaderOrder,
                  localHeaderOrderPositions: localHeaderOrderPositions,
                  entries: entries, nameEncoding: nameEncoding, readAhead: localReadAhead.policy)
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
        return try makeStream(record: record, entry: entry, local: local, limits: limits,
                              aesKey: nil, storedOnly: false)
    }

    func zipStream(at index: Int, limits: ReadLimits, aesKey: ZipAESKeyMaterial?, storedOnly: Bool) throws -> EntryStream? {
        guard records.indices.contains(index) else {
            throw KaitoError.notFound("zip entry index \(index)")
        }
        guard !entries[index].isIncomplete else { return nil }
        let local = try localRecord(at: index, limits: limits)
        return try makeStream(record: records[index], entry: entries[index], local: local, limits: limits,
                              aesKey: aesKey, storedOnly: storedOnly)
    }

    private func makeStream(record: ZipEntryRecord, entry: ArchiveEntry, local: LocalRecord, limits: ReadLimits,
                            aesKey: ZipAESKeyMaterial?, storedOnly: Bool) throws -> EntryStream {
        if aesKey != nil {
            guard case .aes = record.encryption else {
                throw KaitoError.malformed("AES key material requires an AES entry")
            }
        }
        var zipCryptoErrorsAreWrongPassword = false
        if case .traditional = record.encryption {
            zipCryptoErrorsAreWrongPassword = !entry.isIncomplete
        }
        let payload = try payloadSource(
            record: record,
            local: local,
            limits: limits,
            isIncomplete: entry.isIncomplete,
            aesKey: aesKey,
            stagesXZ: !storedOnly
        )
        if storedOnly {
            return try EntryStream(
                decompressor: CopyDecompressor(source: payload.source, offset: payload.offset,
                                               compressedSize: payload.size),
                length: payload.size, expectedCRC32: nil, entryIndex: entry.index, limits: limits,
                completionCheck: payload.completionCheck
            )
        }
        var decompressor: any Decompressor
        do {
            decompressor = try makeDecompressor(
                method: record.method,
                flags: record.flags,
                source: payload.source,
                offset: payload.offset,
                compressedSize: payload.size,
                uncompressedSize: entry.uncompressedSize,
                limits: limits
            )
        } catch KaitoError.truncated where entry.isIncomplete {
            decompressor = try CopyDecompressor(
                source: source, offset: local.dataOffset, compressedSize: 0
            )
        } catch {
            throw zipCryptoErrorsAreWrongPassword ? ZipPasswordAmbiguousDecompressor.asWrongPassword(error) : error
        }
        if zipCryptoErrorsAreWrongPassword {
            decompressor = ZipPasswordAmbiguousDecompressor(decompressor, expectedSize: entry.uncompressedSize)
        }
        // Recovery bounds unencrypted stored payload.size to available source bytes,
        // so CopyDecompressor can preserve bulk reads without recovery wrapping.
        return try EntryStream(
            decompressor: entry.isIncomplete && !(record.method == ZipMethod.stored && !entry.isEncrypted)
                ? RecoveryDecompressor(decompressor, maximumOutputSize: entry.uncompressedSize)
                : decompressor,
            length: entry.isIncomplete ? nil : entry.uncompressedSize,
            expectedCRC32: entry.isIncomplete ? nil : record.crc32,
            entryIndex: entry.index,
            limits: limits,
            completionCheck: payload.completionCheck,
            checksumMismatchIsWrongPassword: zipCryptoErrorsAreWrongPassword
        )
    }

    func rawRecord(for entry: ArchiveEntry, limits: ReadLimits) throws -> RawEntryRecord? {
        guard entry.index >= 0,
              entry.index < records.count,
              entries[entry.index] == entry else {
            throw KaitoError.notFound("zip entry index \(entry.index)")
        }
        guard !entry.isIncomplete else { return nil }
        let (record, local, end) = try validatedRawRecord(at: entry.index, limits: limits)
        var specific = entry.formatSpecific
        specific["crc32"] = Self.crc32Description(record.storedCRC32)
        specific["headerMethod"] = String(record.headerMethod)
        specific["hasDataDescriptor"] = String(local.usesDataDescriptor)
        specific["isZIP64"] = String(record.usesZIP64 || local.usesZIP64)
        return RawEntryRecord(
            recordRange: record.localHeaderOffset..<end,
            payloadRange: local.dataOffset..<(try Checked.add(local.dataOffset, record.compressedSize)),
            formatSpecific: specific
        )
    }

    func zipRawRecordLayout(at index: Int, limits: ReadLimits) throws -> ZipRawRecordLayout? {
        guard records.indices.contains(index) else {
            throw KaitoError.notFound("zip entry index \(index)")
        }
        guard !entries[index].isIncomplete else { return nil }
        let (record, local, end) = try validatedRawRecord(at: index, limits: limits)
        let encryption: ZipRawEncryption
        switch record.encryption {
        case .none: encryption = .none
        case .traditional: encryption = .zipCrypto
        case let .aes(metadata):
            encryption = .winZipAES(
                strength: metadata.strength.rawValue, vendorVersion: metadata.vendorVersion.rawValue
            )
        }
        return ZipRawRecordLayout(
            recordRange: record.localHeaderOffset..<end,
            payloadRange: local.dataOffset..<(try Checked.add(local.dataOffset, record.compressedSize)),
            hasDataDescriptor: local.usesDataDescriptor,
            centralHasZIP64Extra: record.usesZIP64,
            localHasZIP64Extra: local.usesZIP64,
            encryption: encryption,
            storedCRC32: record.storedCRC32,
            compressionMethod: record.method
        )
    }

    private func validatedRawRecord(at index: Int, limits: ReadLimits) throws -> (ZipEntryRecord, LocalRecord, end: UInt64) {
        try validateEntryRanges(
            through: localHeaderOrderPositions[index],
            limits: limits,
            includingDataDescriptors: true
        )
        let record = records[index]
        let local = try resolveLocalRecord(at: index, limits: limits)
        guard let end = local.rawRecordEnd else {
            throw KaitoError.malformed("ZIP raw record range was not validated")
        }
        return (record, local, end)
    }

    private func localRecord(at index: Int, limits: ReadLimits) throws -> LocalRecord {
        let local = try resolveLocalRecord(at: index, limits: limits,
            sequential: localHeaderOrderPositions[index] == validatedLocalRangePosition + 1)
        try validateEntryRanges(
            through: localHeaderOrderPositions[index],
            limits: limits
        )
        return local
    }

    private func resolveLocalRecord(at index: Int, limits: ReadLimits, sequential: Bool = false) throws -> LocalRecord {
        // Keep reopen independent of entry count; allocate this mutable cache
        // only when the new reader first needs a local header.
        if localRecords.isEmpty { localRecords = Array(repeating: nil, count: records.count) }
        if let cached = localRecords[index] { return cached }
        let central = records[index]
        let fixedSize = UInt64(ZipRecordSize.localHeader)
        let fixedEnd = try Checked.add(central.localHeaderOffset, fixedSize)
        guard fixedEnd <= centralDirectoryOffset else {
            throw KaitoError.malformed("ZIP local header overlaps the central directory")
        }
        let fixed = try readLocal(
            offset: central.localHeaderOffset,
            count: ZipRecordSize.localHeader, position: localHeaderOrderPositions[index], sequential: sequential,
            limits: limits
        )
        var cursor = ZipByteCursor(fixed)
        guard try cursor.readUInt32LE() == ZipSignature.localHeader else {
            throw KaitoError.malformed("invalid ZIP local-header signature")
        }
        _ = try cursor.readUInt16LE() // 展開に必要なバージョン
        let localFlags = try cursor.readUInt16LE()
        guard localFlags & ZipGeneralPurposeFlag.strongEncryption == 0 else {
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

        let localEncrypted = localFlags & ZipGeneralPurposeFlag.encrypted != 0
        let centralEncrypted = central.flags & ZipGeneralPurposeFlag.encrypted != 0
        guard localEncrypted == centralEncrypted else {
            throw KaitoError.malformed("ZIP encryption flag differs between headers")
        }

        var usesZIP64 = false
        if extraLength > 0 {
            try Checked.size(extraLength, limit: limits.maxMetadataSize)
            let extra = try readLocal(
                offset: extraOffset,
                count: try Checked.toInt(extraLength), position: localHeaderOrderPositions[index],
                sequential: false, limits: limits
            )
            let fields = try ZipExtraFields.parse(
                extra,
                recordLimit: limits.maxMetadataRecordCount,
                tailPolicy: .zeroPadding
            )
            usesZIP64 = fields.contains { $0.identifier == ZipExtraFieldID.zip64 }
            if localCompressed32 == UInt32.max || localUncompressed32 == UInt32.max {
                guard let zip64 = ZipExtraFields.unique(ZipExtraFieldID.zip64, in: fields) else {
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

        let dataEnd = try Checked.add(dataOffset, central.availableCompressedSize ?? central.compressedSize)
        guard dataEnd <= centralDirectoryOffset else {
            throw KaitoError.malformed("ZIP entry data overlaps the central directory")
        }
        let local = LocalRecord(
            dataOffset: dataOffset,
            usesDataDescriptor: localFlags & ZipGeneralPurposeFlag.dataDescriptor != 0,
            dosTime: localDOSTime,
            usesZIP64: usesZIP64
        )
        localRecords[index] = local
        return local
    }

    private func validateEntryRanges(
        through requestedPosition: Int,
        limits: ReadLimits,
        includingDataDescriptors: Bool = false
    ) throws {
        var validatedPosition = includingDataDescriptors
            ? validatedRawRangePosition : validatedLocalRangePosition
        while validatedPosition < requestedPosition {
            let position = validatedPosition + 1
            let index = localHeaderOrder[position]
            let start = records[index].localHeaderOffset
            if position > 0 {
                let previousIndex = localHeaderOrder[position - 1]
                if records[previousIndex].localHeaderOffset == start {
                    throw KaitoError.malformed("ZIP entry ranges overlap")
                }
            }

            var local = try resolveLocalRecord(at: index, limits: limits, sequential: true)
            let end = try Checked.add(
                local.dataOffset,
                records[index].availableCompressedSize ?? records[index].compressedSize
            )
            var upperBound = min(centralDirectoryOffset, source.length)
            if position + 1 < localHeaderOrder.count {
                let nextIndex = localHeaderOrder[position + 1]
                if records[nextIndex].localHeaderOffset < end {
                    throw KaitoError.malformed("ZIP entry ranges overlap")
                }
                upperBound = min(upperBound, records[nextIndex].localHeaderOffset)
            }
            if includingDataDescriptors {
                guard !entries[index].isIncomplete else {
                    throw KaitoError.malformed("ZIP preceding entry has an unverified extent")
                }
                guard local.usesDataDescriptor
                    == (records[index].flags & ZipGeneralPurposeFlag.dataDescriptor != 0) else {
                    throw KaitoError.malformed("ZIP data-descriptor flag differs between headers")
                }
                // 前の entry の descriptor も調べ、呼出順にかかわらず重なりを拒否する。
                local.rawRecordEnd = try rawRecordEnd(
                    record: records[index], local: local, payloadEnd: end, upperBound: upperBound,
                    position: position, limits: limits
                )
                localRecords[index] = local
                validatedRawRangePosition = position
            } else {
                validatedLocalRangePosition = position
            }
            validatedPosition = position
            localReadAhead.finish(position: position, recordCount: records.count)
        }
    }

    private func rawRecordEnd(
        record: ZipEntryRecord,
        local: LocalRecord,
        payloadEnd: UInt64,
        upperBound: UInt64,
        position: Int,
        limits: ReadLimits
    ) throws -> UInt64 {
        guard payloadEnd <= upperBound else {
            throw KaitoError.malformed("ZIP raw record lies outside its entry bounds")
        }
        guard local.usesDataDescriptor else { return payloadEnd }

        // APPNOTE 4.3.9: entry の ZIP64 extra がサイズ幅を決める。
        // 書庫全体の ZIP64 EOCD や展開バージョンだけでは判定しない。
        let wide = record.usesZIP64 || local.usesZIP64
        let unsignedSize = wide ? 20 : 12
        let available = upperBound - payloadEnd
        guard available >= UInt64(unsignedSize) else {
            throw KaitoError.malformed("ZIP data descriptor overlaps the next record or central directory")
        }
        let bytes = try readLocal(
            offset: payloadEnd,
            count: Int(min(available, UInt64(unsignedSize + 4))),
            position: position, sequential: false, limits: limits
        )
        var matchedEnd: UInt64?
        // CRC 自体が署名と同値の場合があるため、署名の有無は全フィールドで照合する。
        for base in [0, 4] {
            if base == 4, LittleEndian.uint32(bytes, at: 0) != ZipSignature.dataDescriptor {
                continue
            }
            guard bytes.count >= base + unsignedSize else { continue }
            let crc = LittleEndian.uint32(bytes, at: base)
            let compressed = wide ? LittleEndian.uint64(bytes, at: base + 4)
                : UInt64(LittleEndian.uint32(bytes, at: base + 4))
            let uncompressed = wide ? LittleEndian.uint64(bytes, at: base + 12)
                : UInt64(LittleEndian.uint32(bytes, at: base + 8))
            guard crc == record.storedCRC32,
                  compressed == record.compressedSize,
                  uncompressed == record.uncompressedSize else { continue }
            guard matchedEnd == nil else {
                throw KaitoError.malformed("ambiguous ZIP data descriptor")
            }
            matchedEnd = try Checked.add(payloadEnd, UInt64(base + unsignedSize))
        }
        guard let matchedEnd else {
            throw KaitoError.malformed("ZIP data descriptor disagrees with the central directory")
        }
        return matchedEnd
    }

    private func readLocal(offset: UInt64, count: Int, position: Int,
                           sequential: Bool, limits: ReadLimits) throws -> [UInt8] {
        guard count >= 0 else { throw KaitoError.malformed("negative ZIP read size") }
        let end = try Checked.add(offset, UInt64(count))
        guard end <= source.length else { throw KaitoError.truncated }
        guard count > 0 else { return [] }
        if let bytes = localReadAhead.read(
            source: source, offset: offset, count: count,
            position: position, recordCount: records.count, sequential: sequential,
            limits: limits, bound: min(centralDirectoryOffset, source.length),
            headerOffset: { records[localHeaderOrder[$0]].localHeaderOffset }
        ) { return bytes }
        return try readByteRange(source: source, offset: offset, count: count)
    }

    private func payloadSource(
        record: ZipEntryRecord,
        local: LocalRecord,
        limits: ReadLimits,
        isIncomplete: Bool,
        aesKey: ZipAESKeyMaterial?,
        stagesXZ: Bool
    ) throws -> (
        source: any ByteSource,
        offset: UInt64,
        size: UInt64,
        completionCheck: (() throws -> Void)?
    ) {
        let availableSize = record.availableCompressedSize ?? record.compressedSize
        switch record.encryption {
        case .none:
            return (source, local.dataOffset, availableSize, nil)
        case .traditional:
            guard let password else {
                throw KaitoError.passwordRequired
            }
            if isIncomplete, availableSize < UInt64(ZipCrypto.headerSize) {
                return (source, local.dataOffset, 0, nil)
            }
            do {
                let decrypted = try ZipCryptoByteSource(
                    source: source,
                    offset: local.dataOffset,
                    compressedSize: availableSize,
                    password: password,
                    crc32: record.storedCRC32,
                    dosTime: local.dosTime,
                    usesDataDescriptor: local.usesDataDescriptor
                )
                return (decrypted, 0, decrypted.length, nil)
            } catch {
                throw isIncomplete ? error : ZipPasswordAmbiguousDecompressor.asWrongPassword(error)
            }

        case let .aes(metadata):
            guard let decryptionPassword = aesKey == nil ? password : "" else {
                throw KaitoError.passwordRequired
            }
            if isIncomplete, availableSize < UInt64(metadata.strength.saltLength + 2) {
                return (source, local.dataOffset, 0, nil)
            }
            let result = try WinZipAES.prepareStreamingDecryption(
                source: source,
                offset: local.dataOffset,
                compressedSize: record.compressedSize,
                password: decryptionPassword,
                metadata: metadata,
                cachedKeysFor: { [weak self] key in
                    if let aesKey {
                        guard aesKey.salt == key.salt, aesKey.strength == metadata.strength.rawValue else {
                            throw KaitoError.malformed("AES key material does not match the stored salt")
                        }
                        return try WinZipAESDerivedKeys(salt: key.salt, strength: key.strength, material: aesKey.bytes)
                    }
                    return self?.aesDerivedKeyCache[key]
                },
                availableCompressedSize: isIncomplete ? availableSize : nil,
                hasKnownCompressedSize: record.hasKnownCompressedSize
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
            if stagesXZ, record.method == ZipMethod.xz {
                // XZ checks every block's dictionary before native decoding, then
                // rereads the stream. AES random access authenticates the entire
                // ciphertext each time. Snapshot one sequential authenticated pass
                // to keep this linear, without weakening mutable-source checks.
                var stagingLimits = limits
                stagingLimits.maxEntrySize = decryptedSource.length
                stagingLimits.inMemorySingleFileLimit = min(limits.inMemorySingleFileLimit, 4 * 1_024 * 1_024)
                let compressedStream = try EntryStream(
                    decompressor: CopyDecompressor(source: decryptedSource, offset: 0,
                                                   compressedSize: decryptedSource.length),
                    length: decryptedSource.length, expectedCRC32: nil, entryIndex: -1,
                    limits: stagingLimits, completionCheck: completionCheck)
                let staged = try SingleFileMaterializer.materialize(compressedStream, limits: stagingLimits)
                return (staged, 0, staged.length, nil)
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
        uncompressedSize: UInt64?,
        limits: ReadLimits
    ) throws -> any Decompressor {
        switch method {
        case ZipMethod.stored:
            return try CopyDecompressor(
                source: source,
                offset: offset,
                compressedSize: compressedSize
            )
        case ZipMethod.shrink...ZipMethod.implode:
            // APPNOTE §5.1〜5.3 の旧 method（PKZIP 1.x）。stream に終端が無く、宣言サイズで止める。
            guard let uncompressedSize else {
                throw KaitoError.malformed("ZIP method \(method) requires a known uncompressed size")
            }
            switch method {
            case ZipMethod.shrink:
                return try ShrinkDecompressor(source: source, offset: offset, compressedSize: compressedSize,
                                              expectedSize: uncompressedSize)
            case ZipMethod.implode:
                return try ImplodeDecompressor(source: source, offset: offset, compressedSize: compressedSize,
                                               expectedSize: uncompressedSize, flags: flags)
            default:
                return try ReduceDecompressor(source: source, offset: offset, compressedSize: compressedSize,
                                              expectedSize: uncompressedSize, factor: Int(method) - 1)
            }
        case ZipMethod.deflate:
            return try DeflateDecompressor(
                source: source,
                offset: offset,
                compressedSize: compressedSize
            )
        case ZipMethod.deflate64:
            return try Deflate64Decompressor(
                source: source,
                offset: offset,
                compressedSize: compressedSize,
                expectedSize: uncompressedSize
            )
        case ZipMethod.bzip2:
            return try Bzip2Decompressor(
                source: source,
                offset: offset,
                compressedSize: compressedSize
            )
        case ZipMethod.lzma:
            guard compressedSize >= 4 else { throw KaitoError.truncated }
            let prefix = try readByteRange(source: source, offset: offset, count: 4)
            var cursor = ZipByteCursor(prefix)
            _ = try cursor.readUInt16LE() // 情報用途だけの LZMA SDK バージョン
            let propertyLength = UInt64(try cursor.readUInt16LE())
            guard propertyLength == 5 else {
                throw KaitoError.malformed("ZIP LZMA properties must contain five bytes")
            }
            let headerSize = try Checked.add(4, propertyLength)
            guard headerSize <= compressedSize else { throw KaitoError.truncated }
            let propertiesOffset = try Checked.add(offset, 4)
            let properties = try readByteRange(
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
                expectedSize: flags & ZipGeneralPurposeFlag.lzmaEOSMarker != 0 ? nil : uncompressedSize,
                dictionarySizeLimit: limits.maxDictionarySize
            )
        case ZipMethod.ppmd:
            guard compressedSize >= 2 else { throw KaitoError.truncated }
            guard let uncompressedSize else {
                throw KaitoError.malformed("ZIP PPMd requires a known uncompressed size")
            }
            let prefix = try readByteRange(source: source, offset: offset, count: 2)
            var cursor = ZipByteCursor(prefix)
            let parameterWord = try cursor.readUInt16LE()
            return try PPMdVarIDecoder(
                source: source,
                offset: Checked.add(offset, 2),
                compressedSize: compressedSize - 2,
                parameterWord: parameterWord,
                expectedSize: uncompressedSize,
                memorySizeLimit: limits.maxDictionarySize
            )
        case ZipMethod.zstdDeprecated, ZipMethod.zstd:
            // APPNOTE: 20 is the deprecated Zstandard identifier; decode both IDs.
            return try ZstdDecompressor(source: source, offset: offset, compressedSize: compressedSize,
                                        expectedSize: uncompressedSize, limits: limits)
        case ZipMethod.xz:
            return try XZDecompressor(source: source, offset: offset,
                                      compressedSize: compressedSize, limits: limits)
        default:
            throw KaitoError.unsupportedMethod(String(method))
        }
    }

    private static func locateAndParseCentralDirectory(
        source: any ByteSource,
        diskLayout: ZipDiskLayout? = nil,
        policy: EncodingPolicy,
        limits: ReadLimits
    ) throws -> ZipParsedDirectory {
        // 二つの探索窓と包含候補の再試行で共有する。兄弟探索の予算は免除しない。
        var budget = EndRecordParseBudget(limits: limits, exemptsFirstAttempt: true)
        var attemptedEndRecordOffsets: Set<UInt64> = []
        let standardSearchSize = ZipEndRecords.endMinimumSize + ZipEndRecords.maximumCommentSize
        let initialCandidates = try ZipEndRecords.findEndRecords(
            source: source,
            maximumSearchSize: standardSearchSize
        )
        let initial = try parseDirectoryCandidates(
            initialCandidates,
            source: source,
            diskLayout: diskLayout,
            policy: policy,
            limits: limits,
            budget: &budget,
            attemptedOffsets: &attemptedEndRecordOffsets
        )

        if let directory = initial.directory,
           !directory.entries.isEmpty
               || initial.end?.recordEnd == source.length
               || source.length <= UInt64(standardSearchSize) {
            return directory
        }

        let expandedSearchSize = standardSearchSize + ZipEndRecords.maximumTrailingDataSize
        if source.length > UInt64(standardSearchSize) {
            let expandedCandidates = try ZipEndRecords.findEndRecords(
                source: source,
                maximumSearchSize: expandedSearchSize
            )
            let expanded = try parseDirectoryCandidates(
                expandedCandidates,
                source: source,
                diskLayout: diskLayout,
                policy: policy,
                limits: limits,
                budget: &budget,
                attemptedOffsets: &attemptedEndRecordOffsets
            )
            if let directory = expanded.directory {
                return directory
            }
            if let directory = initial.directory {
                return directory
            }
            throw initial.error
                ?? expanded.error
                ?? KaitoError.malformed(
                    "ZIP end-of-central-directory record was not found"
                )
        }

        if let directory = initial.directory {
            return directory
        }
        throw initial.error
            ?? KaitoError.malformed("ZIP end-of-central-directory record was not found")
    }

    private static func parseDirectoryCandidates(
        _ candidates: [EndRecord],
        source: any ByteSource,
        diskLayout: ZipDiskLayout? = nil,
        policy: EncodingPolicy,
        limits: ReadLimits,
        budget: inout EndRecordParseBudget,
        attemptedOffsets: inout Set<UInt64>
    ) throws -> (directory: ZipParsedDirectory?, end: EndRecord?, error: Error?) {
        var candidateError: Error?

        for (candidateIndex, end) in candidates.enumerated() {
            guard attemptedOffsets.insert(end.offset).inserted else { continue }
            do {
                let parsed = try parseDirectoryCandidate(
                    source: source,
                    diskLayout: diskLayout,
                    end: end,
                    policy: policy,
                    limits: limits,
                    budget: &budget
                )

                // An empty EOCD-shaped sequence is structurally self-consistent
                // wherever it appears. Before accepting one, prefer a coherent
                // non-empty EOCD whose declared comment wholly contains it.
                // This preserves real comments containing PK\x05\x06 without
                // allowing an arbitrary SFX prefix to discard a later archive.
                if parsed.entries.isEmpty,
                   candidateIndex + 1 < candidates.count {
                    for enclosing in candidates[(candidateIndex + 1)...]
                        where enclosing.totalEntries != 0
                            || enclosing.centralDirectorySize != 0
                    {
                        let commentStart = enclosing.offset + UInt64(ZipEndRecords.endMinimumSize)
                        guard end.offset >= commentStart,
                              end.recordEnd <= enclosing.recordEnd else { continue }
                        guard attemptedOffsets.insert(enclosing.offset).inserted else {
                            continue
                        }
                        do {
                            let enclosingParsed = try parseDirectoryCandidate(
                                source: source,
                                diskLayout: diskLayout,
                                end: enclosing,
                                policy: policy,
                                limits: limits,
                                budget: &budget
                            )
                            if !enclosingParsed.entries.isEmpty {
                                return (enclosingParsed, enclosing, nil)
                            }
                        } catch {
                            guard try shouldRetryEndRecordCandidateError(
                                error,
                                source: source,
                                diskLayout: diskLayout,
                                end: enclosing,
                                limits: limits,
                                budget: &budget
                            ) else {
                                throw error
                            }
                        }
                    }
                }
                return (parsed, end, nil)
            } catch {
                // Trailing data can contain an EOCD-shaped byte sequence. It
                // is not a usable candidate unless its complete central
                // directory is coherent, so continue toward the preceding
                // bounded candidate before reporting the newest failure.
                guard try shouldRetryEndRecordCandidateError(
                    error,
                    source: source,
                    diskLayout: diskLayout,
                    end: end,
                    limits: limits,
                    budget: &budget
                ) else {
                    throw error
                }
                candidateError = candidateError ?? error
            }
        }
        return (nil, nil, candidateError)
    }

    private static func shouldRetryEndRecordCandidateError(
        _ error: Error,
        source: any ByteSource,
        diskLayout: ZipDiskLayout? = nil,
        end: EndRecord,
        limits: ReadLimits,
        budget: inout EndRecordParseBudget
    ) throws -> Bool {
        if isRetryableEndRecordError(error) { return true }
        guard let kaitoError = error as? KaitoError else { return false }
        switch kaitoError {
        case let .limitExceeded(reason):
            // Exhausting either candidate budget is itself the hard stop that
            // bounds adversarial retries; it must never become retryable.
            guard reason != "ZIP end-record candidate attempts",
                  reason != "ZIP end-record candidate metadata work" else {
                return false
            }
        case .unsupportedMethod:
            break
        default:
            return false
        }

        // Disk and configured-limit fields are checked before the directory is
        // read. Preserve those policy errors for a genuinely coherent newer
        // concatenated archive, but do not let an EOCD-shaped trailing sequence
        // with no matching directory hide an older archive.
        // Claim checks intentionally relax policy limits, so they must charge
        // the shared work budget even after the first parsing attempt.
        budget.endFirstAttemptExemption()
        do {
            return try !hasCoherentDirectoryClaim(
                source: source,
                diskLayout: diskLayout,
                end: end,
                limits: limits,
                budget: &budget
            )
        } catch {
            // Only a completed, bounded check can justify an older candidate.
            // If the work budget runs out, stop with the original policy error.
            if case let KaitoError.limitExceeded(reason) = error,
               reason == "ZIP end-record candidate metadata work" {
                return false
            }
            if isRetryableEndRecordError(error) { return true }
            throw error
        }
    }

    private static func hasCoherentDirectoryClaim(
        source: any ByteSource,
        diskLayout: ZipDiskLayout? = nil,
        end: EndRecord,
        limits: ReadLimits,
        budget: inout EndRecordParseBudget
    ) throws -> Bool {
        if let diskLayout {
            var claimLimits = limits
            claimLimits.maxEntryCount = Int.max
            claimLimits.maxMetadataSize = UInt64.max
            claimLimits.maxTotalMetadataSize = UInt64.max
            let location: ZipDirectoryLocation
            if try end.diskNumber == UInt16.max || end.centralDirectoryDisk == UInt16.max
                || end.entriesOnDisk == UInt16.max || end.totalEntries == UInt16.max
                || end.centralDirectorySize == UInt32.max || end.centralDirectoryOffset == UInt32.max
                || hasZIP64Locator(source: source, end: end) {
                location = try locateZIP64Directory(source: source, diskLayout: diskLayout,
                    end: end, limits: claimLimits, budget: &budget)
            } else {
                location = try locateZIP32Directory(source: source, diskLayout: diskLayout,
                    end: end, limits: claimLimits)
            }
            return try hasCoherentCentralDirectoryClaim(source: source, diskLayout: diskLayout,
                archiveBase: 0, directoryStart: location.offset, directorySize: location.size,
                entryCount: location.entryCount, upperBound: end.offset, budget: &budget)
        }
        let usesZIP64 = end.diskNumber == UInt16.max
            || end.centralDirectoryDisk == UInt16.max
            || end.entriesOnDisk == UInt16.max
            || end.totalEntries == UInt16.max
            || end.centralDirectorySize == UInt32.max
            || end.centralDirectoryOffset == UInt32.max
        if usesZIP64 {
            do {
                return try hasCoherentZIP64DirectoryClaim(
                    source: source,
                    diskLayout: diskLayout,
                    end: end,
                    limits: limits,
                    budget: &budget
                )
            } catch {
                if isRetryableEndRecordError(error) { return false }
                throw error
            }
        }

        // Some producers emit a ZIP64 record and locator without ZIP32
        // sentinels. Try that evidenced interpretation before the ZIP32 claim.
        if try hasZIP64Locator(source: source, end: end) {
            do {
                if try hasCoherentZIP64DirectoryClaim(
                    source: source,
                    diskLayout: diskLayout,
                    end: end,
                    limits: limits,
                    budget: &budget
                ) {
                    return true
                }
            } catch {
                guard isRetryableEndRecordError(error) else { throw error }
            }
        }
        return try hasCoherentZIP32DirectoryClaim(
            source: source,
            diskLayout: diskLayout,
            end: end,
            budget: &budget
        )
    }

    /// 兄弟探索の段階でも、末尾ゴミにある単巻 EOCD の候補を区別する。
    static func hasCoherentZIP32End(source: any ByteSource, end: ZipEndRecords.EndRecord,
                                   budget: inout EndRecordParseBudget) throws -> Bool {
        return try hasCoherentZIP32DirectoryClaim(source: source, end: end, budget: &budget)
    }

    private static func hasCoherentZIP32DirectoryClaim(
        source: any ByteSource,
        diskLayout: ZipDiskLayout? = nil,
        end: EndRecord,
        budget: inout EndRecordParseBudget
    ) throws -> Bool {
        let entryCount = Int(end.totalEntries)
        let size = UInt64(end.centralDirectorySize)

        // An empty EOCD carries no central-directory evidence with which to
        // distinguish a real archive from an EOCD-shaped trailing sequence.
        // Let candidate ordering continue toward an older evidenced archive.
        guard entryCount != 0, size != 0 else { return false }

        let directoryStart: UInt64
        let archiveBase: UInt64
        do {
            directoryStart = try Checked.sub(end.offset, size)
            archiveBase = try Checked.sub(
                directoryStart,
                UInt64(end.centralDirectoryOffset)
            )
        } catch {
            return false
        }
        guard (try? Checked.add(directoryStart, size)) == end.offset else {
            return false
        }
        return try hasCoherentCentralDirectoryClaim(
            source: source,
            diskLayout: diskLayout,
            archiveBase: archiveBase,
            directoryStart: directoryStart,
            directorySize: size,
            entryCount: entryCount,
            upperBound: end.offset,
            budget: &budget
        )
    }

    private static func hasCoherentZIP64DirectoryClaim(
        source: any ByteSource,
        diskLayout: ZipDiskLayout? = nil,
        end: EndRecord,
        limits: ReadLimits,
        budget: inout EndRecordParseBudget
    ) throws -> Bool {
        guard end.offset >= UInt64(ZipRecordSize.zip64Locator) else { return false }
        let locatorOffset = try Checked.sub(end.offset, UInt64(ZipRecordSize.zip64Locator))
        let locatorBytes = try readByteRange(
            source: source,
            offset: locatorOffset,
            count: ZipRecordSize.zip64Locator
        )
        var locator = ZipByteCursor(locatorBytes)
        guard try locator.readUInt32LE() == ZipSignature.zip64Locator else {
            return false
        }
        _ = try locator.readUInt32LE() // locator disk is a policy field
        let relativeRecordOffset = try locator.readUInt64LE()
        _ = try locator.readUInt32LE() // disk count is a policy field

        // The bounded backwards lookup proves that a ZIP64 record actually ends
        // at this locator. A bare locator-shaped trailer is not enough evidence.
        guard limits.maxMetadataSize >= UInt64(ZipRecordSize.zip64EndFixed) else { return false }
        try budget.chargeMetadataBytes(min(locatorOffset, limits.maxMetadataSize))
        let recordOffset = try findZIP64RecordOffset(
            source: source,
            locatorOffset: locatorOffset,
            limits: limits
        )
        let fixed = try readByteRange(source: source, offset: recordOffset, count: ZipRecordSize.zip64EndFixed)
        var record = ZipByteCursor(fixed)
        guard try record.readUInt32LE() == ZipSignature.zip64End else { return false }
        let payloadSize = try record.readUInt64LE()
        guard payloadSize >= UInt64(ZipRecordSize.zip64EndMinimumPayload) else { return false }
        let fullRecordSize: UInt64
        do {
            fullRecordSize = try Checked.add(payloadSize, UInt64(ZipRecordSize.zip64EndLeadingFields))
        } catch {
            return false
        }
        guard fullRecordSize <= limits.maxMetadataSize,
              (try? Checked.add(recordOffset, fullRecordSize)) == locatorOffset else {
            return false
        }

        _ = try record.readUInt16LE()
        _ = try record.readUInt16LE()
        _ = try record.readUInt32LE() // record disk is a policy field
        _ = try record.readUInt32LE() // central disk is a policy field
        _ = try record.readUInt64LE() // per-disk count is a policy field
        let totalEntries = try record.readUInt64LE()
        let directorySize = try record.readUInt64LE()
        let relativeDirectoryOffset = try record.readUInt64LE()

        if end.totalEntries != UInt16.max,
           UInt64(end.totalEntries) != totalEntries {
            return false
        }
        if end.centralDirectorySize != UInt32.max,
           UInt64(end.centralDirectorySize) != directorySize {
            return false
        }
        if end.centralDirectoryOffset != UInt32.max,
           UInt64(end.centralDirectoryOffset) != relativeDirectoryOffset {
            return false
        }

        let archiveBase: UInt64
        let directoryStart: UInt64
        let directoryEnd: UInt64
        do {
            archiveBase = try Checked.sub(recordOffset, relativeRecordOffset)
            directoryStart = try Checked.add(archiveBase, relativeDirectoryOffset)
            directoryEnd = try Checked.add(directoryStart, directorySize)
        } catch {
            return false
        }
        guard directoryEnd <= recordOffset,
              directoryEnd <= source.length else { return false }
        // Even a minimal central entry needs 46 bytes, so a count that cannot
        // fit Int cannot be represented by any in-memory ByteSource envelope.
        guard totalEntries <= UInt64(Int.max) else { return false }
        return try hasCoherentCentralDirectoryClaim(
            source: source,
            diskLayout: diskLayout,
            archiveBase: archiveBase,
            directoryStart: directoryStart,
            directorySize: directorySize,
            entryCount: Int(totalEntries),
            upperBound: recordOffset,
            budget: &budget
        )
    }

    private static func hasCoherentCentralDirectoryClaim(
        source: any ByteSource,
        diskLayout: ZipDiskLayout? = nil,
        archiveBase: UInt64,
        directoryStart: UInt64,
        directorySize: UInt64,
        entryCount: Int,
        upperBound: UInt64,
        budget: inout EndRecordParseBudget
    ) throws -> Bool {
        guard entryCount >= 0 else { return false }
        if entryCount == 0 { return directorySize == 0 }
        guard directorySize != 0 else { return false }
        let directoryEnd: UInt64
        let minimumSize: UInt64
        do {
            directoryEnd = try Checked.add(directoryStart, directorySize)
            minimumSize = try Checked.mul(UInt64(entryCount), UInt64(ZipRecordSize.centralHeader))
        } catch {
            return false
        }
        guard directoryEnd <= upperBound,
              directoryEnd <= source.length,
              minimumSize <= directorySize else { return false }
        var cursor = directoryStart

        // Only fixed headers are read; variable fields are bounded and skipped
        // from their declared lengths. Every read is charged to the shared work
        // budget before it occurs, including claims after the first attempt.
        for index in 0..<entryCount {
            try checkCancellation(every: index)
            guard cursor <= directoryEnd,
                  directoryEnd - cursor >= UInt64(ZipRecordSize.centralHeader) else { return false }
            try budget.chargeMetadataBytes(UInt64(ZipRecordSize.centralHeader))
            let fixed = try readByteRange(
                source: source,
                offset: cursor,
                count: ZipRecordSize.centralHeader
            )
            guard LittleEndian.uint32(fixed, at: 0) == ZipSignature.centralHeader else {
                return false
            }

            let nameLength = UInt64(LittleEndian.uint16(fixed, at: 28))
            let extraLength = UInt64(LittleEndian.uint16(fixed, at: 30))
            let commentLength = UInt64(LittleEndian.uint16(fixed, at: 32))
            guard nameLength > 0 else { return false }
            let recordSize: UInt64
            let next: UInt64
            do {
                let nameAndExtra = try Checked.add(nameLength, extraLength)
                let variableLength = try Checked.add(nameAndExtra, commentLength)
                recordSize = try Checked.add(UInt64(ZipRecordSize.centralHeader), variableLength)
                next = try Checked.add(cursor, recordSize)
            } catch {
                return false
            }
            guard next <= directoryEnd else { return false }

            let localOffset32 = LittleEndian.uint32(fixed, at: 42)
            let localOffset: UInt64
            var diskStart = UInt32(LittleEndian.uint16(fixed, at: 34))
            if localOffset32 == UInt32.max || (diskLayout != nil && diskStart == UInt16.max) {
                let extraOffset: UInt64
                do {
                    extraOffset = try Checked.add(
                        try Checked.add(cursor, UInt64(ZipRecordSize.centralHeader)),
                        nameLength
                    )
                } catch {
                    return false
                }
                try budget.chargeMetadataBytes(extraLength)
                let extra = try readByteRange(
                    source: source,
                    offset: extraOffset,
                    count: Int(extraLength)
                )
                let fields: [ZipExtraField]
                do {
                    fields = try ZipExtraFields.parse(
                        extra,
                        recordLimit: extra.count / 4 + 1,
                        tailPolicy: .ignoreUnparsableTail
                    )
                    let values = try ZipExtraFields.resolveZIP64Values(
                        compressed32: LittleEndian.uint32(fixed, at: 20),
                        uncompressed32: LittleEndian.uint32(fixed, at: 24),
                        localOffset32: localOffset32,
                        diskStart16: LittleEndian.uint16(fixed, at: 34),
                        fields: fields
                    )
                    localOffset = values.localHeaderOffset
                    diskStart = values.diskStart
                } catch {
                    return false
                }
            } else {
                localOffset = UInt64(localOffset32)
            }

            let absoluteLocalOffset: UInt64
            do {
                absoluteLocalOffset = try diskLayout?.absoluteOffset(disk: UInt64(diskStart), relative: localOffset)
                    ?? Checked.add(archiveBase, localOffset)
            } catch {
                return false
            }
            guard absoluteLocalOffset < directoryStart else { return false }
            cursor = next
        }
        return cursor == directoryEnd
    }

    private static func isRetryableEndRecordError(_ error: Error) -> Bool {
        guard let kaitoError = error as? KaitoError else { return false }
        switch kaitoError {
        case .malformed, .truncated:
            return true
        default:
            return false
        }
    }

    private static func parseDirectoryCandidate(
        source: any ByteSource,
        diskLayout: ZipDiskLayout? = nil,
        end: EndRecord,
        policy: EncodingPolicy,
        limits: ReadLimits,
        budget: inout EndRecordParseBudget
    ) throws -> ZipParsedDirectory {
        try budget.chargeAttempt()
        let usesZIP64 = end.diskNumber == UInt16.max
            || end.centralDirectoryDisk == UInt16.max
            || end.entriesOnDisk == UInt16.max
            || end.totalEntries == UInt16.max
            || end.centralDirectorySize == UInt32.max
            || end.centralDirectoryOffset == UInt32.max
        if usesZIP64 {
            let location = try locateZIP64Directory(
                source: source,
                diskLayout: diskLayout,
                end: end,
                limits: limits,
                budget: &budget
            )
            return try parseDirectory(
                source: source,
                location: location,
                policy: policy,
                limits: limits,
                budget: &budget
            )
        }

        let hasZIP64Locator = try hasZIP64Locator(source: source, end: end)
        if hasZIP64Locator {
            do {
                let location = try locateZIP64Directory(
                    source: source,
                    diskLayout: diskLayout,
                    end: end,
                    limits: limits,
                    budget: &budget
                )
                return try parseDirectory(
                    source: source,
                    location: location,
                    policy: policy,
                    limits: limits,
                    budget: &budget
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let zip64Error = error
                // A four-byte locator signature can legally occur at the start
                // of a ZIP32 central-entry comment. Only use that interpretation
                // when its complete central directory parses coherently.
                do {
                    let location = try locateZIP32Directory(
                        source: source,
                        diskLayout: diskLayout,
                        end: end,
                        limits: limits
                    )
                    return try parseDirectory(
                        source: source,
                        location: location,
                        policy: policy,
                        limits: limits,
                        budget: &budget
                    )
                } catch {
                    if !isRetryableEndRecordError(zip64Error) { throw zip64Error }
                    if !isRetryableEndRecordError(error) { throw error }
                    throw zip64Error
                }
            }
        }

        let location = try locateZIP32Directory(
            source: source,
            diskLayout: diskLayout,
            end: end,
            limits: limits
        )
        return try parseDirectory(
            source: source,
            location: location,
            policy: policy,
            limits: limits,
            budget: &budget
        )
    }

    private static func parseDirectory(
        source: any ByteSource,
        location: ZipDirectoryLocation,
        policy: EncodingPolicy,
        limits: ReadLimits,
        budget: inout EndRecordParseBudget
    ) throws -> ZipParsedDirectory {
        try budget.chargeMetadataBytes(location.size)
        return try ZipCentralDirectoryParser.parse(
            source: source,
            location: location,
            policy: policy,
            limits: limits
        )
    }

    private static func hasZIP64Locator(
        source: any ByteSource,
        end: EndRecord
    ) throws -> Bool {
        guard end.offset >= UInt64(ZipRecordSize.zip64Locator) else { return false }
        let locatorSignature = try readByteRange(
            source: source,
            offset: try Checked.sub(end.offset, UInt64(ZipRecordSize.zip64Locator)),
            count: 4
        )
        return LittleEndian.uint32(locatorSignature, at: 0) == ZipSignature.zip64Locator
    }

    private static func locateZIP32Directory(
        source: any ByteSource,
        diskLayout: ZipDiskLayout? = nil,
        end: EndRecord,
        limits: ReadLimits
    ) throws -> ZipDirectoryLocation {
        if let diskLayout {
            try diskLayout.validate(end: end)
            guard end.entriesOnDisk <= end.totalEntries else {
                throw KaitoError.malformed("ZIP per-disk entry count exceeds total")
            }
        } else {
            guard end.diskNumber == 0,
                  end.centralDirectoryDisk == 0,
                  end.entriesOnDisk == end.totalEntries else {
                throw KaitoError.unsupportedMethod("spanned")
            }
        }
        let count = Int(end.totalEntries)
        guard count <= limits.maxEntryCount else {
            throw KaitoError.limitExceeded("ZIP entry count")
        }
        let size = UInt64(end.centralDirectorySize)
        // 中央ディレクトリは件数に比例し、単一確保の 16 MiB 上限では 100 万件と両立しない。
        // 既存の総 metadata 上限（既定 256 MiB）を使い、メモリ上限自体は引き上げない。
        try Checked.size(size, limit: limits.maxTotalMetadataSize)
        let relativeOffset = UInt64(end.centralDirectoryOffset)
        let beforeOffset = try Checked.sub(end.offset, size)
        let archiveBase = try diskLayout == nil ? Checked.sub(beforeOffset, relativeOffset) : 0
        let absoluteOffset = try diskLayout?.absoluteOffset(
            disk: UInt64(end.centralDirectoryDisk), relative: relativeOffset, allowEnd: size == 0
        ) ?? Checked.add(archiveBase, relativeOffset)
        let directoryEnd = try Checked.add(absoluteOffset, size)
        guard directoryEnd == end.offset, directoryEnd <= source.length else {
            throw KaitoError.malformed("ZIP central directory lies outside the file")
        }
        return ZipDirectoryLocation(
            archiveBase: archiveBase,
            offset: absoluteOffset,
            size: size,
            entryCount: count,
            diskLayout: diskLayout
        )
    }

    private static func locateZIP64Directory(
        source: any ByteSource,
        diskLayout: ZipDiskLayout? = nil,
        end: EndRecord,
        limits: ReadLimits,
        budget: inout EndRecordParseBudget
    ) throws -> ZipDirectoryLocation {
        if let diskLayout {
            try diskLayout.validate(end: end)
        } else {
            guard (end.diskNumber == 0 || end.diskNumber == UInt16.max),
                  (end.centralDirectoryDisk == 0 || end.centralDirectoryDisk == UInt16.max) else {
                throw KaitoError.unsupportedMethod("spanned")
            }
        }
        guard end.offset >= UInt64(ZipRecordSize.zip64Locator) else { throw KaitoError.truncated }
        let locatorOffset = try Checked.sub(end.offset, UInt64(ZipRecordSize.zip64Locator))
        guard let locator = try ZipEndRecords.locator(source: source, end: end) else {
            throw KaitoError.malformed("ZIP64 locator is missing")
        }
        let relativeRecordOffset = locator.relativeRecordOffset
        let recordOffset: UInt64
        if let diskLayout {
            guard UInt64(locator.diskCount) == UInt64(diskLayout.disks.count),
                  locatorOffset >= diskLayout.disks[diskLayout.disks.count - 1].start else {
                throw KaitoError.malformed("ZIP64 locator disagrees with the volume set")
            }
            recordOffset = try diskLayout.absoluteOffset(
                disk: UInt64(locator.recordDisk), relative: relativeRecordOffset)
            try budget.chargeMetadataBytes(UInt64(ZipRecordSize.zip64EndFixed))
        } else {
            guard locator.recordDisk == 0, locator.diskCount == 1 else {
                throw KaitoError.unsupportedMethod("spanned")
            }
            try budget.chargeMetadataBytes(min(locatorOffset, limits.maxMetadataSize))
            recordOffset = try findZIP64RecordOffset(
                source: source, locatorOffset: locatorOffset, limits: limits)
        }
        let fixed = try readByteRange(source: source, offset: recordOffset, count: ZipRecordSize.zip64EndFixed)
        var record = ZipByteCursor(fixed)
        guard try record.readUInt32LE() == ZipSignature.zip64End else {
            throw KaitoError.malformed("invalid ZIP64 end record")
        }
        let payloadSize = try record.readUInt64LE()
        guard payloadSize >= UInt64(ZipRecordSize.zip64EndMinimumPayload) else {
            throw KaitoError.malformed("undersized ZIP64 end record")
        }
        let fullRecordSize = try Checked.add(payloadSize, UInt64(ZipRecordSize.zip64EndLeadingFields))
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
        if let diskLayout {
            guard UInt64(disk) == diskLayout.lastDiskIndex,
                  UInt64(centralDisk) <= diskLayout.lastDiskIndex,
                  entriesOnDisk <= totalEntries,
                  end.diskNumber == UInt16.max || UInt32(end.diskNumber) == disk,
                  end.centralDirectoryDisk == UInt16.max || UInt32(end.centralDirectoryDisk) == centralDisk else {
                throw KaitoError.malformed("ZIP32 and ZIP64 disk fields disagree with the volume set")
            }
        } else {
            guard disk == 0, centralDisk == 0, entriesOnDisk == totalEntries else {
                throw KaitoError.unsupportedMethod("spanned")
            }
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
        // ZIP32 と同じく件数に比例する中央ディレクトリは、既存の総 metadata 上限で制限する。
        try Checked.size(directorySize, limit: limits.maxTotalMetadataSize)
        let archiveBase = try diskLayout == nil ? Checked.sub(recordOffset, relativeRecordOffset) : 0
        let absoluteDirectoryOffset = try diskLayout?.absoluteOffset(
            disk: UInt64(centralDisk), relative: relativeDirectoryOffset, allowEnd: directorySize == 0
        ) ?? Checked.add(archiveBase, relativeDirectoryOffset)
        let directoryEnd = try Checked.add(absoluteDirectoryOffset, directorySize)
        guard directoryEnd <= recordOffset, directoryEnd <= source.length else {
            throw KaitoError.malformed("ZIP64 central directory lies outside the file")
        }
        return ZipDirectoryLocation(
            archiveBase: archiveBase,
            offset: absoluteDirectoryOffset,
            size: directorySize,
            entryCount: count,
            diskLayout: diskLayout
        )
    }

    private static func findZIP64RecordOffset(
        source: any ByteSource,
        locatorOffset: UInt64,
        limits: ReadLimits
    ) throws -> UInt64 {
        guard locatorOffset >= UInt64(ZipRecordSize.zip64EndFixed) else { throw KaitoError.truncated }
        guard limits.maxMetadataSize >= UInt64(ZipRecordSize.zip64EndFixed) else {
            throw KaitoError.limitExceeded("ZIP64 end record")
        }
        let searchSize = min(locatorOffset, limits.maxMetadataSize)
        let searchCount = try Checked.toInt(searchSize)
        let searchOffset = try Checked.sub(locatorOffset, searchSize)
        let bytes = try readByteRange(source: source, offset: searchOffset, count: searchCount)
        guard bytes.count >= ZipRecordSize.zip64EndFixed else { throw KaitoError.truncated }

        for index in stride(from: bytes.count - ZipRecordSize.zip64EndFixed, through: 0, by: -1) {
            try checkCancellation(every: index)
            guard LittleEndian.uint32(bytes, at: index) == ZipSignature.zip64End else { continue }
            let payloadSize = LittleEndian.uint64(bytes, at: index + 4)
            guard payloadSize >= UInt64(ZipRecordSize.zip64EndMinimumPayload) else { continue }
            let total: UInt64
            do {
                total = try Checked.add(payloadSize, UInt64(ZipRecordSize.zip64EndLeadingFields))
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

    /// formatSpecific の "flags" の表記（`0x` と小文字 4 桁）。
    static func flagsDescription(_ flags: UInt16) -> String {
        ZipCentralDirectoryParser.flagsDescription(flags)
    }

    /// formatSpecific の "crc32" の表記（`0x` と小文字 8 桁）。
    static func crc32Description(_ crc: UInt32) -> String {
        ZipCentralDirectoryParser.crc32Description(crc)
    }
}
