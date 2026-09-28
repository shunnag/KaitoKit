import Darwin
import Foundation

// 参照仕様: PKWARE APPNOTE.TXT 6.3.x。通常は中央ディレクトリを索引として扱う。
// 索引の位置決めは ZipCentralDirectoryLocator、解析は ZipCentralDirectoryParser、中央ディレクトリを使えない
// 書庫の復旧は ZipLocalHeaderRecovery が行う。この型は local header と entry 範囲の検証、payload の復号、
// entry の stream と raw layout SPI を受け持つ。
final class ZipReader: FormatReader {
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
    // 通常の読取は payload 終端まで検証する。descriptor を含む検証の進捗は分離する。
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
            parsedDirectory = try ZipCentralDirectoryLocator.locate(
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
        // 解析済みの配列は不変の COW 値として共有する。local の検証の進捗、cache した header、
        // 導出済みの AES 鍵は reader ごとに空から始める。
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
        // 復旧は暗号化されていない stored の payload.size を source に実在する byte 数に抑えるので、
        // CopyDecompressor は RecoveryDecompressor で包まずに一括読取を保てる。
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
        // reopen の費用を entry 数に比例させない。この可変 cache は、新しい reader が初めて
        // local header を必要としたときに確保する。
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
                // XZ は native の展開の前に全 block の辞書を検査してから stream を読み直す。AES の任意位置の
                // 読取は毎回暗号文全体を認証する。認証済みの順次読取一回分を写し取り、変わり得る source の
                // 検査を弱めずに費用を線形に保つ。
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
            // APPNOTE: 20 は Zstandard の旧 ID。現行の 93 と同じく展開する。
            return try ZstdDecompressor(source: source, offset: offset, compressedSize: compressedSize,
                                        expectedSize: uncompressedSize, limits: limits)
        case ZipMethod.xz:
            return try XZDecompressor(source: source, offset: offset,
                                      compressedSize: compressedSize, limits: limits)
        default:
            throw KaitoError.unsupportedMethod(String(method))
        }
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
