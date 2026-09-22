import Foundation

// POSIX ustar/pax と GNU tar 拡張の公開仕様だけを参照したクリーンルーム実装。
final class TarReader: FormatReader {
    private static let retainedPAXKeys: Set<String> = [
        "path", "linkpath", "size", "mtime", "uid", "gid", "hdrcharset",
        // GNU sparse 0.0 / 0.1 / 1.0（tar(5) "GNU tar pax archives"）。0.0 の offset/numbytes 対は
        // parsePAX が順序を保って GNU.sparse.map.0.0 にまとめる。
        "GNU.sparse.numblocks", "GNU.sparse.size", "GNU.sparse.map", "GNU.sparse.map.0.0",
        "GNU.sparse.major", "GNU.sparse.minor", "GNU.sparse.name", "GNU.sparse.realsize",
    ]

    private struct Record: Sendable {
        let dataOffset: UInt64
        let size: UInt64
        var sparse: TarSparseMap? = nil
    }

    private struct PendingText {
        let bytes: [UInt8]
        let declaredEncoding: String.Encoding?
    }

    private struct PendingEntry {
        let name: PendingText
        let link: PendingText?
        let kind: EntryKind
        let size: UInt64
        let isIncomplete: Bool
        let modificationDate: Date?
        let permissions: UInt16
        let formatSpecific: [String: String]
        var storedSize: UInt64? = nil
    }

    let format: ArchiveFormat = .tar
    let entries: [ArchiveEntry]
    let nameEncoding: String.Encoding?
    private let records: [Record]
    private let source: any ByteSource

    init(source: any ByteSource, options: ReaderOptions) throws {
        self.source = source
        let parsed = try Self.parse(
            source: source,
            policy: options.encodingPolicy,
            limits: options.limits,
            recoverDamagedArchives: options.recoverDamagedArchives
        )
        entries = parsed.entries
        nameEncoding = parsed.nameEncoding
        records = parsed.records
    }

    private init(source: any ByteSource, entries: [ArchiveEntry],
                 nameEncoding: String.Encoding?, records: [Record]) {
        self.source = source
        self.entries = entries
        self.nameEncoding = nameEncoding
        self.records = records
    }

    func reopened(options: ReaderOptions) -> sending TarReader {
        TarReader(source: source, entries: entries, nameEncoding: nameEncoding, records: records)
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        guard entry.index >= 0, entry.index < records.count,
              entries[entry.index] == entry else {
            throw KaitoError.notFound("tar entry index \(entry.index)")
        }
        let record = records[entry.index]
        if let sparse = record.sparse {
            return try EntryStream(
                decompressor: TarSparseDecompressor(source: source, dataOffset: record.dataOffset, map: sparse),
                length: sparse.realSize, expectedCRC32: nil, entryIndex: entry.index, limits: limits
            )
        }
        return try EntryStream(
            source: source,
            offset: record.dataOffset,
            length: record.size,
            limits: limits
        )
    }

    private static func parse(
        source: any ByteSource,
        policy: EncodingPolicy,
        limits: ReadLimits,
        recoverDamagedArchives: Bool
    ) throws -> (
        entries: [ArchiveEntry],
        records: [Record],
        nameEncoding: String.Encoding?
    ) {
        var pendingEntries: [PendingEntry] = []
        var records: [Record] = []
        var offset: UInt64 = 0
        var globalPAX: [String: [UInt8]] = [:]
        var localPAX: [String: [UInt8]] = [:]
        var hasLocalPAX = false
        var longName: [UInt8]?
        var longLink: [UInt8]?
        var pendingMetadataFloor: UInt64 = 0
        var foundTerminator = false
        // Headers are separated by member bodies, which listing must not
        // prefetch. Extension payloads use their own bounded ranged reads.
        var byteReader = try ByteReader(source: source, bufferCapacity: 4 * 1_024)

        while offset < source.length {
            let remaining = try Checked.sub(source.length, offset)
            guard remaining >= 512 else {
                if recoverDamagedArchives { break }
                throw KaitoError.truncated
            }

            try byteReader.seek(to: offset)
            let header = Array(try byteReader.readBytes(512))
            guard header.count == 512 else { throw KaitoError.truncated }
            if header.allSatisfy({ $0 == 0 }) {
                foundTerminator = true
                break
            }

            try validateChecksum(header)
            let typeByte = header[156]
            let headerSize = try parseUnsigned(
                Array(header[124..<136]),
                fieldName: "size"
            )
            let dataOffset = try Checked.add(offset, 512)

            if typeByte == ascii("x") || typeByte == ascii("X") ||
                typeByte == ascii("g") ||
                typeByte == ascii("L") || typeByte == ascii("K") {
                try Checked.size(headerSize, limit: limits.maxMetadataSize)
                if recoverDamagedArchives, headerSize > source.length - dataOffset { break }
                let payload = try readPayload(
                    source: source,
                    offset: dataOffset,
                    size: headerSize
                )
                switch typeByte {
                case ascii("x"), ascii("X"):
                    guard !hasLocalPAX else {
                        throw KaitoError.malformed("consecutive local pax headers")
                    }
                    let values = try parsePAX(
                        payload,
                        recordLimit: limits.maxMetadataRecordCount
                    )
                    try rejectForeignSparse(values)
                    localPAX = retainedPAXValues(values)
                    hasLocalPAX = true
                case ascii("g"):
                    let values = try parsePAX(
                        payload,
                        recordLimit: limits.maxMetadataRecordCount
                    )
                    try rejectSparse(values)
                    let retained = retainedPAXValues(values)
                    try validatePAXMerge(existing: globalPAX, new: retained, limits: limits)
                    applyPAX(retained, to: &globalPAX)
                case ascii("L"):
                    guard longName == nil else {
                        throw KaitoError.malformed("duplicate GNU tar long-name header")
                    }
                    longName = try parseGNULongValue(payload, fieldName: "name")
                case ascii("K"):
                    guard longLink == nil else {
                        throw KaitoError.malformed("duplicate GNU tar long-link header")
                    }
                    longLink = try parseGNULongValue(payload, fieldName: "link")
                default:
                    break
                }
                offset = try nextHeaderOffset(
                    dataOffset: dataOffset, size: headerSize, source: source,
                    recoverDamagedArchives: recoverDamagedArchives
                )
                continue
            }

            guard typeByte != ascii("S") else {
                throw KaitoError.unsupportedMethod("GNU tar sparse entries")
            }

            var pax = globalPAX
            try validatePAXMerge(existing: pax, new: localPAX, limits: limits)
            applyPAX(localPAX, to: &pax)
            try rejectForeignSparse(pax)

            let effectiveSize: UInt64
            if let paxSize = pax["size"] {
                effectiveSize = try parsePAXUnsigned(paxSize, fieldName: "size")
            } else {
                effectiveSize = headerSize
            }
            let storedSize = try storedBodySize(
                typeByte: typeByte,
                declaredSize: effectiveSize,
                hasAuthoritativePAXSize: pax["size"] != nil,
                dataOffset: dataOffset,
                source: source,
                reader: &byteReader,
                recoverDamagedArchives: recoverDamagedArchives
            )
            try Checked.size(storedSize, limit: limits.maxEntrySize)
            let nextOffset = try nextHeaderOffset(
                dataOffset: dataOffset,
                size: storedSize,
                source: source,
                recoverDamagedArchives: recoverDamagedArchives
            )

            guard pendingEntries.count < limits.maxEntryCount else {
                throw KaitoError.limitExceeded("archive entry count")
            }

            // GNU sparse（pax 0.0 / 0.1 / 1.0）。1.0 は本文先頭の map block を読み、実データの開始を
            // その後ろへずらす。実サイズは realsize / size、本文は fragment の連結。
            var sparse: TarSparseMap?
            var sparseDataOffset = dataOffset
            var sparseVersion: String?
            var sparseName: [UInt8]?
            if entryKind(for: typeByte) == .file, hasGNUSparse(pax) {
                let parsed = try parseGNUSparse(
                    pax, dataOffset: dataOffset, storedSize: storedSize, source: source, limits: limits
                )
                sparse = parsed.map
                sparseDataOffset = parsed.dataOffset
                sparseVersion = parsed.version
                sparseName = parsed.name
            }

            let ustarName = headerPath(header)
            let selectedName: [UInt8]
            let nameIsPAX: Bool
            if let sparseName {
                // 1.0 の header 名は GNUSparseFile.N/… の作業名なので、GNU.sparse.name を採る。
                selectedName = sparseName
                nameIsPAX = true
            } else if let paxPath = pax["path"] {
                guard longName == nil else {
                    throw KaitoError.malformed("conflicting pax and GNU tar names")
                }
                selectedName = paxPath
                nameIsPAX = true
            } else if let longName {
                selectedName = longName
                nameIsPAX = false
            } else {
                selectedName = ustarName
                nameIsPAX = false
            }
            guard !selectedName.isEmpty, !selectedName.contains(0) else {
                throw KaitoError.malformed("tar entry has an empty or NUL-containing name")
            }

            let declaredEncoding: String.Encoding? = nameIsPAX && !isBinaryHeaderCharset(pax)
                ? .utf8
                : nil
            if let declaredEncoding {
                guard EncodingDetector.decode(bytes: selectedName, as: declaredEncoding) != nil else {
                    throw KaitoError.malformed("pax path is not valid UTF-8")
                }
            }

            let kind = entryKind(for: typeByte)
            let mode = try parseUnsigned(Array(header[100..<108]), fieldName: "mode")
            let uid = try paxUnsignedOrHeader(
                pax["uid"],
                header: Array(header[108..<116]),
                fieldName: "uid"
            )
            let gid = try paxUnsignedOrHeader(
                pax["gid"],
                header: Array(header[116..<124]),
                fieldName: "gid"
            )
            let modificationDate = try parseModificationDate(
                pax: pax["mtime"],
                header: Array(header[136..<148])
            )

            let headerLink = nulTerminated(Array(header[157..<257]))
            let selectedLink: [UInt8]?
            let linkIsPAX: Bool
            if let paxLink = pax["linkpath"] {
                guard longLink == nil else {
                    throw KaitoError.malformed("conflicting pax and GNU tar links")
                }
                selectedLink = paxLink
                linkIsPAX = true
            } else if let longLink {
                selectedLink = longLink
                linkIsPAX = false
            } else if !headerLink.isEmpty {
                selectedLink = headerLink
                linkIsPAX = false
            } else {
                selectedLink = nil
                linkIsPAX = false
            }

            var specific: [String: String] = [
                "typeFlag": typeDescription(typeByte),
                "uid": String(uid),
                "gid": String(gid)
            ]
            if let sparseVersion, let sparse {
                specific["sparse"] = sparseVersion
                specific["sparseFragmentCount"] = String(sparse.fragments.count)
            }
            if let charset = pax["hdrcharset"],
               let value = String(bytes: charset, encoding: .utf8) {
                specific["hdrcharset"] = value
            }
            let pendingLink: PendingText?
            if let selectedLink {
                guard !selectedLink.contains(0) else {
                    throw KaitoError.malformed("tar link contains NUL")
                }
                let linkEncoding: String.Encoding? = linkIsPAX && !isBinaryHeaderCharset(pax)
                    ? .utf8
                    : nil
                if let linkEncoding {
                    guard EncodingDetector.decode(
                        bytes: selectedLink,
                        as: linkEncoding
                    ) != nil else {
                        throw KaitoError.malformed("pax linkpath is not valid UTF-8")
                    }
                }
                pendingLink = PendingText(
                    bytes: selectedLink,
                    declaredEncoding: linkEncoding
                )
            } else {
                pendingLink = nil
            }

            var metadataFloor = try Checked.add(256, UInt64(selectedName.count))
            if let selectedLink {
                metadataFloor = try Checked.add(metadataFloor, UInt64(selectedLink.count))
            }
            for (key, value) in specific {
                metadataFloor = try Checked.add(metadataFloor, UInt64(key.utf8.count))
                metadataFloor = try Checked.add(metadataFloor, UInt64(value.utf8.count))
            }
            pendingMetadataFloor = try Checked.add(
                pendingMetadataFloor,
                metadataFloor
            )
            try Checked.size(
                pendingMetadataFloor,
                limit: limits.maxTotalMetadataSize
            )
            pendingEntries.append(PendingEntry(
                name: PendingText(
                    bytes: selectedName,
                    declaredEncoding: declaredEncoding
                ),
                link: pendingLink,
                kind: kind,
                size: sparse?.realSize ?? storedSize,
                isIncomplete: recoverDamagedArchives
                    && storedSize > source.length - dataOffset,
                modificationDate: modificationDate,
                permissions: UInt16(mode & 0o7777),
                formatSpecific: specific,
                storedSize: sparse != nil ? storedSize : nil
            ))
            records.append(Record(
                dataOffset: sparseDataOffset,
                size: recoverDamagedArchives
                    ? min(storedSize, source.length - dataOffset)
                    : storedSize,
                sparse: sparse
            ))

            localPAX.removeAll(keepingCapacity: true)
            hasLocalPAX = false
            longName = nil
            longLink = nil
            offset = nextOffset
        }

        guard foundTerminator || recoverDamagedArchives else { throw KaitoError.truncated }
        guard (!hasLocalPAX && longName == nil && longLink == nil)
            || (recoverDamagedArchives && !foundTerminator) else {
            throw KaitoError.malformed("tar ends after an extension header")
        }
        var undecoratedNames: [[UInt8]] = []
        undecoratedNames.reserveCapacity(pendingEntries.count)
        for pending in pendingEntries {
            if pending.name.declaredEncoding == nil {
                switch policy {
                case .fixed:
                    undecoratedNames.append(pending.name.bytes)
                case .automatic, .utf8Only:
                    if !EncodingDetector.isStrictUTF8(pending.name.bytes) {
                        undecoratedNames.append(pending.name.bytes)
                    }
                }
            }
        }
        let archiveEncoding = EncodingDetector.detectArchiveEncoding(
            names: undecoratedNames,
            policy: policy,
            maximumBatchByteCount: Int(clamping: limits.maxMetadataSize)
        )
        var archiveDecodedNames: [[UInt8]: String] = [:]
        if let archiveEncoding {
            let decodedNames = EncodingDetector.decodeArchiveNames(
                undecoratedNames,
                as: archiveEncoding,
                maximumBatchByteCount: Int(clamping: limits.maxMetadataSize)
            )
            archiveDecodedNames.reserveCapacity(undecoratedNames.count)
            for (bytes, string) in zip(undecoratedNames, decodedNames) {
                if let string { archiveDecodedNames[bytes] = string }
            }
        }
        let entries = try finalizeEntries(
            pendingEntries,
            policy: policy,
            archiveEncoding: archiveEncoding,
            archiveDecodedNames: archiveDecodedNames,
            limits: limits
        )
        return (entries, records, archiveEncoding)
    }

    private static func finalizeEntries(
        _ pendingEntries: [PendingEntry],
        policy: EncodingPolicy,
        archiveEncoding: String.Encoding?,
        archiveDecodedNames: [[UInt8]: String],
        limits: ReadLimits
    ) throws -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        entries.reserveCapacity(pendingEntries.count)
        var retainedMetadataSize: UInt64 = 0
        var lastEntryByNormalizedPath: [String: Int] = [:]

        for pending in pendingEntries {
            let resolvedName = try resolve(
                pending.name,
                policy: policy,
                archiveEncoding: archiveEncoding,
                archiveDecodedNames: archiveDecodedNames,
                invalidDeclaredMessage: "pax path is not valid UTF-8"
            )
            guard !resolvedName.isEmpty else {
                throw KaitoError.malformed("tar entry name cannot be decoded")
            }
            try validatePathComponentCount(
                in: resolvedName,
                limit: limits.maxPathComponentCount,
                fieldName: "entry path"
            )
            let pathComponents = resolvedName
                .utf8.split(separator: 0x2F, omittingEmptySubsequences: true)
                .map { String(decoding: $0, as: UTF8.self) }

            var specific = pending.formatSpecific
            if let pendingLink = pending.link {
                let link = try resolve(
                    pendingLink,
                    policy: policy,
                    archiveEncoding: archiveEncoding,
                    archiveDecodedNames: archiveDecodedNames,
                    invalidDeclaredMessage: "pax linkpath is not valid UTF-8"
                )
                try validatePathComponentCount(
                    in: link,
                    limit: limits.maxPathComponentCount,
                    fieldName: "link"
                )
                specific["linkPath"] = link
                if pending.kind == .hardlink,
                   let normalizedTarget = normalizedExtractionPath(link),
                   let targetIndex = lastEntryByNormalizedPath[normalizedTarget],
                   entries.indices.contains(targetIndex) {
                    let target = entries[targetIndex]
                    if target.kind == .file ||
                        (target.kind == .hardlink &&
                            target.formatSpecific["hardLinkTargetIndex"] != nil) {
                        specific["hardLinkTargetIndex"] = String(targetIndex)
                    }
                }
            }

            let rawName = RawName(
                bytes: pending.name.bytes,
                declaredEncoding: pending.name.declaredEncoding,
                isDirectoryHint: pending.kind == .directory || resolvedName.hasSuffix("/")
            )
            let entryMetadataSize = try retainedMetadataCost(
                rawName: pending.name.bytes,
                resolvedName: resolvedName,
                pathComponents: pathComponents,
                formatSpecific: specific
            )
            retainedMetadataSize = try Checked.add(retainedMetadataSize, entryMetadataSize)
            try Checked.size(retainedMetadataSize, limit: limits.maxTotalMetadataSize)

            let entry = ArchiveEntry(
                index: entries.count,
                rawName: rawName,
                name: resolvedName,
                pathComponents: pathComponents,
                kind: pending.kind,
                uncompressedSize: pending.size,
                compressedSize: pending.storedSize ?? pending.size,
                modificationDate: pending.modificationDate,
                posixPermissions: pending.permissions,
                isEncrypted: false,
                solidGroup: -1,
                crc32: nil,
                methodDescription: pending.storedSize != nil ? "tar (sparse)" : "tar (stored)",
                formatSpecific: specific,
                isIncomplete: pending.isIncomplete
            )
            entries.append(entry)
            if let normalizedName = normalizedExtractionPath(resolvedName) {
                // hard link の解決後に挿入し、参照先を必ず過去の member に限定する。
                lastEntryByNormalizedPath[normalizedName] = entry.index
            }
        }
        return entries
    }

    private static func resolve(
        _ text: PendingText,
        policy: EncodingPolicy,
        archiveEncoding: String.Encoding?,
        archiveDecodedNames: [[UInt8]: String],
        invalidDeclaredMessage: String
    ) throws -> String {
        if let declaredEncoding = text.declaredEncoding {
            guard let decoded = EncodingDetector.decode(
                bytes: text.bytes,
                as: declaredEncoding
            ) else {
                throw KaitoError.malformed(invalidDeclaredMessage)
            }
            return decoded
        }
        if let decoded = archiveDecodedNames[text.bytes] {
            return decoded
        }
        return EncodingDetector.resolveUndeclaredName(
            bytes: text.bytes,
            policy: policy,
            archiveEncoding: archiveEncoding
        ).string
    }

    private static func readPayload(
        source: any ByteSource,
        offset: UInt64,
        size: UInt64
    ) throws -> [UInt8] {
        try readByteRange(source: source, offset: offset, count: Checked.toInt(size))
    }

    private static func nextHeaderOffset(
        dataOffset: UInt64,
        size: UInt64,
        source: any ByteSource,
        recoverDamagedArchives: Bool = false
    ) throws -> UInt64 {
        let rounded = try Checked.add(size, 511)
        let blocks = rounded / 512
        let padded = try Checked.mul(blocks, 512)
        let next = try Checked.add(dataOffset, padded)
        guard next <= source.length || recoverDamagedArchives else { throw KaitoError.truncated }
        return next
    }

    // 本文や拡張の解釈前に、検出に必要な member header の構造だけを検証する。
    // 数値フィールドの妥当性は parser の責務で、そこで malformed として報告する。
    // 検出側で弾くと、壊れた tar が「未対応形式」に化けて診断を失う。
    static func isPlausibleMemberHeader(_ header: [UInt8]) -> Bool {
        guard header.count == 512, !headerPath(header).isEmpty else { return false }
        do {
            try validateChecksum(header)
            return true
        } catch {
            return false
        }
    }

    private static func validateChecksum(_ header: [UInt8]) throws {
        let expected = try parseUnsigned(Array(header[148..<156]), fieldName: "checksum")
        var unsignedSum: UInt64 = 0
        var signedSum: Int64 = 0
        for index in header.indices {
            let byte: UInt8 = (148..<156).contains(index) ? 0x20 : header[index]
            unsignedSum = try Checked.add(unsignedSum, UInt64(byte))
            signedSum += Int64(Int8(bitPattern: byte))
        }
        let signedMatches = signedSum >= 0 && UInt64(signedSum) == expected
        guard unsignedSum == expected || signedMatches else {
            throw KaitoError.malformed("invalid tar header checksum")
        }
    }

    private static func parseUnsigned(
        _ field: [UInt8],
        fieldName: String
    ) throws -> UInt64 {
        guard !field.isEmpty else {
            throw KaitoError.malformed("empty tar \(fieldName) field")
        }
        if field[0] & 0x80 != 0 {
            guard field[0] & 0x40 == 0 else {
                throw KaitoError.malformed("negative tar \(fieldName) field")
            }
            var value: UInt64 = 0
            for index in field.indices {
                let byte = index == field.startIndex ? field[index] & 0x7f : field[index]
                value = try Checked.mul(value, 256)
                value = try Checked.add(value, UInt64(byte))
            }
            return value
        }

        var value: UInt64 = 0
        var sawDigit = false
        var sawTrailingPadding = false
        var sawNULTerminator = false
        for byte in field {
            if byte == 0 {
                sawNULTerminator = true
                continue
            }
            if byte == 0x20 {
                if sawDigit { sawTrailingPadding = true }
                continue
            }
            guard !sawNULTerminator,
                  !sawTrailingPadding,
                  byte >= ascii("0"), byte <= ascii("7") else {
                throw KaitoError.malformed("invalid octal tar \(fieldName) field")
            }
            sawDigit = true
            value = try Checked.mul(value, 8)
            value = try Checked.add(value, UInt64(byte - ascii("0")))
        }
        return value
    }

    private static func storedBodySize(
        typeByte: UInt8,
        declaredSize: UInt64,
        hasAuthoritativePAXSize: Bool,
        dataOffset: UInt64,
        source: any ByteSource,
        reader: inout ByteReader,
        recoverDamagedArchives: Bool
    ) throws -> UInt64 {
        // ustar の hard link は歴史的に size がヒントでも本文を持たない。
        // pax size または後続 header の構造で裏付けた場合だけ linkdata として扱う。
        switch typeByte {
        case ascii("1"):
            guard declaredSize > 0 else { return 0 }
            if hasAuthoritativePAXSize { return declaredSize }
            // pax の x/g header は省略可能なので、曖昧時は次の有効 header 位置で判定する。
            // 両方が成立する場合は古い ustar writer の size ヒントを優先して無視する。
            if try isHeaderOrTerminator(
                at: dataOffset,
                source: source,
                reader: &reader
            ) {
                return 0
            }
            let bodyEnd = try nextHeaderOffset(
                dataOffset: dataOffset,
                size: declaredSize,
                source: source,
                recoverDamagedArchives: recoverDamagedArchives
            )
            if recoverDamagedArchives, bodyEnd >= source.length { return declaredSize }
            guard try isHeaderOrTerminator(
                at: bodyEnd,
                source: source,
                reader: &reader
            ) else {
                throw KaitoError.malformed("ambiguous tar hard-link body")
            }
            return declaredSize
        case ascii("2"), ascii("3"), ascii("4"), ascii("5"), ascii("6"):
            // pax の size は物理本文長として権威がある。ustar header の同じ欄は無視する。
            return hasAuthoritativePAXSize ? declaredSize : 0
        default:
            return declaredSize
        }
    }

    private static func isHeaderOrTerminator(
        at offset: UInt64,
        source: any ByteSource,
        reader: inout ByteReader
    ) throws -> Bool {
        let remaining = try Checked.sub(source.length, offset)
        guard remaining >= 512 else { return false }
        try reader.seek(to: offset)
        let block = Array(try reader.readBytes(512))
        if block.allSatisfy({ $0 == 0 }) { return true }
        do {
            try validateChecksum(block)
            return true
        } catch KaitoError.malformed {
            return false
        }
    }

    private static func parsePAX(
        _ payload: [UInt8],
        recordLimit: Int
    ) throws -> [String: [UInt8]] {
        guard let countLimit = UInt64(exactly: recordLimit) else {
            throw KaitoError.limitExceeded("pax metadata record count")
        }
        var result: [String: [UInt8]] = [:]
        let payloadLength = UInt64(payload.count)
        var cursor: UInt64 = 0
        var recordCount: UInt64 = 0
        while cursor < payloadLength {
            guard recordCount < countLimit else {
                throw KaitoError.limitExceeded("pax metadata record count")
            }
            recordCount = try Checked.add(recordCount, 1)
            var length: UInt64 = 0
            var digitCount = 0
            var space: Int?
            var position = try Checked.toInt(cursor)
            while position < payload.count {
                let byte = payload[position]
                if byte == 0x20 {
                    space = position
                    break
                }
                guard byte >= ascii("0"), byte <= ascii("9") else {
                    throw KaitoError.malformed("invalid pax record length")
                }
                guard digitCount < 20 else {
                    throw KaitoError.malformed("oversized pax record length")
                }
                digitCount += 1
                length = try Checked.mul(length, 10)
                length = try Checked.add(length, UInt64(byte - ascii("0")))
                position += 1
            }
            guard let space, digitCount > 0 else {
                throw KaitoError.malformed("unterminated pax record length")
            }
            let recordRemaining = try Checked.sub(payloadLength, cursor)
            guard length > 0, length <= recordRemaining else {
                throw KaitoError.truncated
            }
            let endOffset = try Checked.add(cursor, length)
            let bodyStartOffset = try Checked.add(UInt64(space), 1)
            let bodyEndOffset = try Checked.sub(endOffset, 1)
            guard bodyEndOffset >= bodyStartOffset else {
                throw KaitoError.malformed("invalid pax record length")
            }
            let bodyStart = try Checked.toInt(bodyStartOffset)
            let bodyEnd = try Checked.toInt(bodyEndOffset)
            guard payload[bodyEnd] == 0x0a else {
                throw KaitoError.malformed("invalid pax record terminator")
            }
            let body = payload[bodyStart..<bodyEnd]
            guard let equals = body.firstIndex(of: ascii("=")), equals != body.startIndex else {
                throw KaitoError.malformed("invalid pax key/value record")
            }
            let keyBytes = body[..<equals]
            guard keyBytes.count <= 1_024,
                  !keyBytes.contains(0),
                  !keyBytes.contains(0x0a),
                  let key = String(bytes: keyBytes, encoding: .utf8) else {
                throw KaitoError.malformed("invalid UTF-8 pax key")
            }
            let value = Array(body[body.index(after: equals)...])
            if key == "GNU.sparse.offset" || key == "GNU.sparse.numbytes" {
                // 0.0 形式は同じ key を繰り返す。辞書では順序が失われるため、出現順のまま
                // comma 区切りで一つの値にまとめる（0.1 の GNU.sparse.map と同じ表現）。
                var joined = result["GNU.sparse.map.0.0"] ?? []
                if !joined.isEmpty { joined.append(ascii(",")) }
                joined += value
                result["GNU.sparse.map.0.0"] = joined
            } else {
                result[key] = value
            }
            cursor = endOffset
        }
        return result
    }

    private static func validatePAXMerge(
        existing: [String: [UInt8]],
        new: [String: [UInt8]],
        limits: ReadLimits
    ) throws {
        var size: UInt64 = 0
        for (key, value) in existing {
            size = try Checked.add(size, UInt64(key.utf8.count))
            size = try Checked.add(size, UInt64(value.count))
        }
        var count = UInt64(existing.count)
        guard let countLimit = UInt64(exactly: limits.maxMetadataRecordCount) else {
            throw KaitoError.limitExceeded("pax metadata record count")
        }
        for (key, value) in new {
            if value.isEmpty {
                if let previous = existing[key] {
                    size = try Checked.sub(size, UInt64(key.utf8.count))
                    size = try Checked.sub(size, UInt64(previous.count))
                    count = try Checked.sub(count, 1)
                }
            } else if let previous = existing[key] {
                size = try Checked.sub(size, UInt64(previous.count))
                size = try Checked.add(size, UInt64(value.count))
            } else {
                guard count < countLimit else {
                    throw KaitoError.limitExceeded("pax metadata record count")
                }
                count = try Checked.add(count, 1)
                size = try Checked.add(size, UInt64(key.utf8.count))
                size = try Checked.add(size, UInt64(value.count))
            }
        }
        try Checked.size(size, limit: limits.maxMetadataSize)
    }

    private static func applyPAX(
        _ changes: [String: [UInt8]],
        to values: inout [String: [UInt8]]
    ) {
        for (key, value) in changes {
            if value.isEmpty {
                values.removeValue(forKey: key)
            } else {
                values[key] = value
            }
        }
    }

    private static func retainedPAXValues(
        _ values: [String: [UInt8]]
    ) -> [String: [UInt8]] {
        values.filter { retainedPAXKeys.contains($0.key) }
    }

    private static func validatePathComponentCount(
        in path: String,
        limit: Int,
        fieldName: String
    ) throws {
        guard let unsignedLimit = UInt64(exactly: limit) else {
            throw KaitoError.limitExceeded("tar \(fieldName) component count")
        }
        var count: UInt64 = 0
        var insideComponent = false
        for byte in path.utf8 {
            if byte == ascii("/") {
                insideComponent = false
            } else if !insideComponent {
                count = try Checked.add(count, 1)
                guard count <= unsignedLimit else {
                    throw KaitoError.limitExceeded("tar \(fieldName) component count")
                }
                insideComponent = true
            }
        }
    }

    private static func retainedMetadataCost(
        rawName: [UInt8],
        resolvedName: String,
        pathComponents: [String],
        formatSpecific: [String: String]
    ) throws -> UInt64 {
        // 固定値は ArchiveEntry と配列・辞書の管理領域を保守的に見積もる。
        var size: UInt64 = 256
        size = try Checked.add(size, UInt64(rawName.count))
        size = try Checked.add(size, UInt64(resolvedName.utf8.count))
        for component in pathComponents {
            size = try Checked.add(size, UInt64(component.utf8.count))
        }
        let componentSlots = try Checked.mul(
            UInt64(pathComponents.count),
            UInt64(MemoryLayout<String>.stride)
        )
        size = try Checked.add(size, componentSlots)
        for (key, value) in formatSpecific {
            size = try Checked.add(size, UInt64(key.utf8.count))
            size = try Checked.add(size, UInt64(value.utf8.count))
        }
        return size
    }

    private static func normalizedExtractionPath(_ path: String) -> String? {
        guard !path.isEmpty, path.utf8.first != 0x2F, !path.utf8.contains(0) else {
            return nil
        }
        let rawComponents = path
            .utf8.split(separator: 0x2F, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        guard !rawComponents.contains("..") else { return nil }
        let components = rawComponents.filter { $0 != "." }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "/")
    }

    private static func parsePAXUnsigned(
        _ bytes: [UInt8],
        fieldName: String
    ) throws -> UInt64 {
        guard !bytes.isEmpty, bytes.count <= 20 else {
            throw KaitoError.malformed("invalid pax \(fieldName)")
        }
        var value: UInt64 = 0
        for byte in bytes {
            guard byte >= ascii("0"), byte <= ascii("9") else {
                throw KaitoError.malformed("invalid pax \(fieldName)")
            }
            value = try Checked.mul(value, 10)
            value = try Checked.add(value, UInt64(byte - ascii("0")))
        }
        return value
    }

    private static func parseModificationDate(
        pax: [UInt8]?,
        header: [UInt8]
    ) throws -> Date? {
        if let pax {
            return Date(timeIntervalSince1970: try parsePAXTime(pax))
        }
        return Date(timeIntervalSince1970: try parseHeaderTime(header))
    }

    private static func parsePAXTime(_ bytes: [UInt8]) throws -> TimeInterval {
        guard !bytes.isEmpty, bytes.count <= 128 else {
            throw KaitoError.malformed("invalid pax mtime")
        }
        var cursor = 0
        var negative = false
        if bytes[cursor] == ascii("-") || bytes[cursor] == ascii("+") {
            negative = bytes[cursor] == ascii("-")
            cursor += 1
        }
        guard cursor < bytes.count else { throw KaitoError.malformed("invalid pax mtime") }

        var integral: UInt64 = 0
        var integralDigits = 0
        while cursor < bytes.count, bytes[cursor] != ascii(".") {
            let byte = bytes[cursor]
            guard byte >= ascii("0"), byte <= ascii("9") else {
                throw KaitoError.malformed("invalid pax mtime")
            }
            integral = try Checked.mul(integral, 10)
            integral = try Checked.add(integral, UInt64(byte - ascii("0")))
            integralDigits += 1
            cursor += 1
        }
        guard integralDigits > 0 else { throw KaitoError.malformed("invalid pax mtime") }

        var fraction = 0.0
        if cursor < bytes.count {
            cursor += 1
            guard cursor < bytes.count else { throw KaitoError.malformed("invalid pax mtime") }
            var scale = 0.1
            while cursor < bytes.count {
                let byte = bytes[cursor]
                guard byte >= ascii("0"), byte <= ascii("9") else {
                    throw KaitoError.malformed("invalid pax mtime")
                }
                fraction += Double(byte - ascii("0")) * scale
                scale *= 0.1
                cursor += 1
            }
        }
        let value = Double(integral) + fraction
        guard value.isFinite else { throw KaitoError.malformed("pax mtime is out of range") }
        return negative ? -value : value
    }

    private static func parseHeaderTime(_ field: [UInt8]) throws -> TimeInterval {
        guard !field.isEmpty else { throw KaitoError.malformed("empty tar mtime") }
        if field[0] & 0x80 != 0 {
            if field[0] & 0x40 == 0 {
                return Double(try parseUnsigned(field, fieldName: "mtime"))
            }
            // 64 bit より上位は全て符号拡張でなければ表現範囲外として拒否する。
            if field.count > 8 {
                let prefix = field.dropLast(8)
                guard let first = prefix.first,
                      first & 0x7f == 0x7f,
                      prefix.dropFirst().allSatisfy({ $0 == 0xff }) else {
                    throw KaitoError.malformed("tar mtime is out of range")
                }
                var low: UInt64 = 0
                for byte in field.suffix(8) {
                    low = try Checked.mul(low, 256)
                    low = try Checked.add(low, UInt64(byte))
                }
                let signed = Int64(bitPattern: low)
                guard signed < 0 else { throw KaitoError.malformed("invalid tar mtime sign") }
                return Double(signed)
            }

            var encoded: UInt64 = 0
            for index in field.indices {
                let byte = index == field.startIndex ? field[index] & 0x7f : field[index]
                encoded = try Checked.mul(encoded, 256)
                encoded = try Checked.add(encoded, UInt64(byte))
            }
            let width = UInt64(field.count * 8 - 1)
            let modulus = try Checked.shiftLeft(1, by: width)
            guard encoded < modulus else { throw KaitoError.malformed("invalid tar mtime") }
            return Double(encoded) - Double(modulus)
        }

        guard let firstNonSpace = field.firstIndex(where: { $0 != 0x20 }) else {
            return 0
        }
        if field[firstNonSpace] == ascii("-") {
            let magnitudeField = Array(field[field.index(after: firstNonSpace)...])
            let magnitude = try parseUnsigned(magnitudeField, fieldName: "mtime")
            guard magnitudeField.contains(where: {
                $0 >= ascii("0") && $0 <= ascii("7")
            }) else {
                throw KaitoError.malformed("invalid tar mtime")
            }
            return -Double(magnitude)
        }
        return Double(try parseUnsigned(field, fieldName: "mtime"))
    }

    private static func paxUnsignedOrHeader(
        _ pax: [UInt8]?,
        header: [UInt8],
        fieldName: String
    ) throws -> UInt64 {
        if let pax { return try parsePAXUnsigned(pax, fieldName: fieldName) }
        return try parseUnsigned(header, fieldName: fieldName)
    }

    private static func parseGNULongValue(
        _ payload: [UInt8],
        fieldName: String
    ) throws -> [UInt8] {
        var value = payload
        while value.last == 0 { value.removeLast() }
        guard !value.isEmpty, !value.contains(0) else {
            throw KaitoError.malformed("invalid GNU tar long \(fieldName)")
        }
        return value
    }

    private static func headerPath(_ header: [UInt8]) -> [UInt8] {
        let name = nulTerminated(Array(header[0..<100]))
        let magic = Array(header[257..<263])
        let version = Array(header[263..<265])
        let prefix = nulTerminated(Array(header[345..<500]))
        // old GNU の同位置は prefix ではないため、POSIX ustar の完全値だけを認める。
        guard magic == Array("ustar\0".utf8),
              version == Array("00".utf8),
              !prefix.isEmpty else { return name }
        return prefix + [ascii("/")] + name
    }

    private static func nulTerminated(_ field: [UInt8]) -> [UInt8] {
        guard let end = field.firstIndex(of: 0) else { return field }
        return Array(field[..<end])
    }

    private static func isBinaryHeaderCharset(_ pax: [String: [UInt8]]) -> Bool {
        guard let bytes = pax["hdrcharset"],
              let string = String(bytes: bytes, encoding: .ascii) else { return false }
        return string.uppercased() == "BINARY"
    }

    /// GNU 以外の sparse 表現（star の SCHILY、Solaris の SUN.holesdata）は従来どおり読まない。
    private static func rejectForeignSparse(_ pax: [String: [UInt8]]) throws {
        if pax.contains(where: { key, value in
            !value.isEmpty && (key == "SCHILY.realsize" || key == "SUN.holesdata")
        }) ||
            pax["SCHILY.filetype"] == Array("sparse".utf8) {
            throw KaitoError.unsupportedMethod("tar sparse entries")
        }
    }

    /// global header の sparse 記録は entry に属さないので拒否する。
    private static func rejectSparse(_ pax: [String: [UInt8]]) throws {
        if pax.contains(where: { key, value in !value.isEmpty && key.hasPrefix("GNU.sparse") }) {
            throw KaitoError.malformed("GNU sparse attributes in a global pax header")
        }
        try rejectForeignSparse(pax)
    }

    private static func hasGNUSparse(_ pax: [String: [UInt8]]) -> Bool {
        pax.contains { key, value in !value.isEmpty && key.hasPrefix("GNU.sparse") }
    }

    /// pax の GNU.sparse.* から fragment map を組む。戻り値の dataOffset は fragment 本文の開始。
    private static func parseGNUSparse(
        _ pax: [String: [UInt8]],
        dataOffset: UInt64,
        storedSize: UInt64,
        source: any ByteSource,
        limits: ReadLimits
    ) throws -> (map: TarSparseMap, dataOffset: UInt64, version: String, name: [UInt8]?) {
        func decimal(_ bytes: ArraySlice<UInt8>, _ field: String) throws -> UInt64 {
            guard !bytes.isEmpty, bytes.count <= 20 else { throw KaitoError.malformed("invalid \(field)") }
            var value: UInt64 = 0
            for byte in bytes {
                guard byte >= ascii("0"), byte <= ascii("9") else { throw KaitoError.malformed("invalid \(field)") }
                value = try Checked.add(Checked.mul(value, 10), UInt64(byte - ascii("0")))
            }
            return value
        }
        func fragments(fromList list: [UInt8], field: String) throws -> [TarSparseFragment] {
            let numbers = try list.split(separator: ascii(","), omittingEmptySubsequences: false)
                .map { try decimal($0, field) }
            guard numbers.count.isMultiple(of: 2) else { throw KaitoError.malformed("odd \(field) length") }
            guard numbers.count / 2 <= limits.maxMetadataRecordCount else {
                throw KaitoError.limitExceeded("tar sparse fragment count")
            }
            return stride(from: 0, to: numbers.count, by: 2).map {
                TarSparseFragment(offset: numbers[$0], size: numbers[$0 + 1])
            }
        }

        if let major = pax["GNU.sparse.major"] {
            // 1.0: map は本文先頭の 512 byte block 列。改行区切りの十進で「fragment 数、offset、size…」。
            let minor = pax["GNU.sparse.minor"] ?? []
            guard try decimal(major[...], "GNU.sparse.major") == 1, try decimal(minor[...], "GNU.sparse.minor") == 0 else {
                throw KaitoError.unsupportedMethod("GNU sparse format \(String(decoding: major, as: UTF8.self)).\(String(decoding: minor, as: UTF8.self))")
            }
            guard let realsizeBytes = pax["GNU.sparse.realsize"] else {
                throw KaitoError.malformed("GNU sparse 1.0 without realsize")
            }
            let realSize = try decimal(realsizeBytes[...], "GNU.sparse.realsize")
            try Checked.size(realSize, limit: limits.maxEntrySize)
            // map を 512 byte ずつ読む。数値の個数が 1 + 2n になるまで、metadata 上限の範囲で続ける。
            var numbers: [UInt64] = []
            var consumedBlocks: UInt64 = 0
            var pending: [UInt8] = []
            var expectedCount: Int?
            while expectedCount.map({ numbers.count < 1 + 2 * $0 }) ?? true {
                let offset = try Checked.add(dataOffset, Checked.mul(consumedBlocks, 512))
                guard try Checked.mul(consumedBlocks + 1, 512) <= storedSize,
                      try Checked.add(offset, 512) <= source.length else {
                    throw KaitoError.malformed("GNU sparse 1.0 map exceeds the entry body")
                }
                try Checked.size(Checked.mul(consumedBlocks + 1, 512), limit: limits.maxMetadataSize)
                let block = try readByteRange(source: source, offset: offset, count: 512)
                consumedBlocks += 1
                for byte in block {
                    if byte == ascii("\n") {
                        numbers.append(try decimal(pending[...], "GNU.sparse map"))
                        pending.removeAll(keepingCapacity: true)
                        if expectedCount == nil {
                            guard let first = numbers.first, first <= UInt64(limits.maxMetadataRecordCount) else {
                                throw KaitoError.limitExceeded("tar sparse fragment count")
                            }
                            expectedCount = Int(first)
                        }
                        if let expectedCount, numbers.count == 1 + 2 * expectedCount { break }
                    } else if byte == 0 {
                        // block の残りは padding。
                        break
                    } else {
                        pending.append(byte)
                        guard pending.count <= 20 else { throw KaitoError.malformed("GNU sparse map number") }
                    }
                }
            }
            let count = expectedCount ?? 0
            let list = stride(from: 0, to: count, by: 1).map {
                TarSparseFragment(offset: numbers[1 + 2 * $0], size: numbers[2 + 2 * $0])
            }
            let map = try TarSparseMap(realSize: realSize, fragments: list, limits: limits)
            let mapBytes = try Checked.mul(consumedBlocks, 512)
            guard try Checked.sub(storedSize, mapBytes) == map.storedSize else {
                throw KaitoError.malformed("GNU sparse 1.0 fragments do not match the stored size")
            }
            return (map, try Checked.add(dataOffset, mapBytes), "GNU.sparse 1.0", pax["GNU.sparse.name"])
        }

        guard let sizeBytes = pax["GNU.sparse.size"] else {
            throw KaitoError.malformed("GNU sparse entry without size")
        }
        let realSize = try decimal(sizeBytes[...], "GNU.sparse.size")
        try Checked.size(realSize, limit: limits.maxEntrySize)
        let list: [TarSparseFragment]
        let version: String
        if let map = pax["GNU.sparse.map"] {
            list = try fragments(fromList: map, field: "GNU.sparse.map")
            version = "GNU.sparse 0.1"
        } else if let pairs = pax["GNU.sparse.map.0.0"] {
            list = try fragments(fromList: pairs, field: "GNU.sparse.offset/numbytes")
            if let declared = pax["GNU.sparse.numblocks"] {
                guard try decimal(declared[...], "GNU.sparse.numblocks") == UInt64(list.count) else {
                    throw KaitoError.malformed("GNU sparse 0.0 numblocks mismatch")
                }
            }
            version = "GNU.sparse 0.0"
        } else {
            throw KaitoError.malformed("GNU sparse entry without a map")
        }
        let map = try TarSparseMap(realSize: realSize, fragments: list, limits: limits)
        guard storedSize == map.storedSize else {
            throw KaitoError.malformed("GNU sparse fragments do not match the stored size")
        }
        return (map, dataOffset, version, pax["GNU.sparse.name"])
    }

    private static func entryKind(for type: UInt8) -> EntryKind {
        switch type {
        case 0, ascii("0"), ascii("7"):
            return .file
        case ascii("5"):
            return .directory
        case ascii("2"):
            return .symlink
        case ascii("1"):
            return .hardlink
        default:
            return .other
        }
    }

    private static func typeDescription(_ type: UInt8) -> String {
        if type == 0 { return "NUL" }
        if type >= 0x20, type <= 0x7e { return String(UnicodeScalar(type)) }
        return String(format: "0x%02x", type)
    }

    private static func ascii(_ character: Character) -> UInt8 {
        // 呼出箇所はソース中の単一 ASCII リテラルだけに限定する。
        character.asciiValue ?? 0
    }
}
