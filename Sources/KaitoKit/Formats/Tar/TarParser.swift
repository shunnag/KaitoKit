import Foundation

// POSIX ustar/pax と GNU tar 拡張の公開仕様だけを参照したクリーンルーム解析。
// 構造・payload 境界・上限を検証し、名前判定後の公開値生成は TarEntryPublisher に渡す。
enum TarParser {
    static func parse(
        source: any ByteSource,
        policy: EncodingPolicy,
        limits: ReadLimits,
        recoverDamagedArchives: Bool,
        recordsLayout: Bool
    ) throws -> (
        entries: [ArchiveEntry],
        records: [TarEntryRecord],
        nameEncoding: String.Encoding?,
        layout: TarLayoutStorage?
    ) {
        let layout = recordsLayout ? TarLayoutStorage.Builder(recovery: recoverDamagedArchives) : nil
        var pendingEntries: [TarPendingEntry] = []
        var records: [TarEntryRecord] = []
        var offset: UInt64 = 0
        var globalPAX = TarPAXRecords()
        var localPAX = TarPAXRecords()
        var hasLocalPAX = false
        var longName: [UInt8]?
        var longLink: [UInt8]?
        var pendingMetadataFloor: UInt64 = 0
        var foundTerminator = false
        // header の間には member の本文があり、一覧の走査はそれを先読みしない。
        // 拡張 header の payload は、範囲を限った読み出しで別に読む。
        var byteReader = try ByteReader(source: source, bufferCapacity: 4 * 1_024)
        var headerCount = 0

        while offset < source.length {
            // PAX/GNU 拡張も数え、公開 entry が増えない走査でも中断する。
            try checkCancellation(every: headerCount)
            headerCount &+= 1
            let remaining = try Checked.sub(source.length, offset)
            guard remaining >= UInt64(TarHeaderBlock.size) else {
                if recoverDamagedArchives { break }
                throw KaitoError.truncated
            }

            try byteReader.seek(to: offset)
            let headerBytes = Array(try byteReader.readBytes(TarHeaderBlock.size))
            guard headerBytes.count == TarHeaderBlock.size else { throw KaitoError.truncated }
            if headerBytes.allSatisfy({ $0 == 0 }) {
                foundTerminator = true
                break
            }

            let header = TarHeaderBlock(bytes: headerBytes)
            try header.validateChecksum()
            let typeByte = header.typeFlag
            let headerSize = try header.size()
            var dataOffset = try Checked.add(offset, UInt64(TarHeaderBlock.size))

            if typeByte == UInt8(ascii: "x") || typeByte == UInt8(ascii: "X") ||
                typeByte == UInt8(ascii: "g") ||
                typeByte == UInt8(ascii: "L") || typeByte == UInt8(ascii: "K") {
                try Checked.size(headerSize, limit: limits.maxMetadataSize)
                if recoverDamagedArchives, headerSize > source.length - dataOffset { break }
                let payload = try readPayload(
                    source: source,
                    offset: dataOffset,
                    size: headerSize
                )
                switch typeByte {
                case UInt8(ascii: "x"), UInt8(ascii: "X"):
                    guard !hasLocalPAX else {
                        throw KaitoError.malformed("consecutive local pax headers")
                    }
                    let paxRecords = try TarPAXRecords.parse(
                        payload,
                        recordLimit: limits.maxMetadataRecordCount
                    )
                    try paxRecords.rejectForeignSparse()
                    localPAX = paxRecords.retained()
                    hasLocalPAX = true
                case UInt8(ascii: "g"):
                    let paxRecords = try TarPAXRecords.parse(
                        payload,
                        recordLimit: limits.maxMetadataRecordCount
                    )
                    try paxRecords.rejectGlobalSparse()
                    try globalPAX.merge(paxRecords.retained(), limits: limits)
                case UInt8(ascii: "L"):
                    guard longName == nil else {
                        throw KaitoError.malformed("duplicate GNU tar long-name header")
                    }
                    longName = try parseGNULongValue(payload, fieldName: "name")
                case UInt8(ascii: "K"):
                    guard longLink == nil else {
                        throw KaitoError.malformed("duplicate GNU tar long-link header")
                    }
                    longLink = try parseGNULongValue(payload, fieldName: "link")
                default:
                    break
                }
                let extensionEnd = try nextHeaderOffset(
                    dataOffset: dataOffset, size: headerSize, source: source,
                    recoverDamagedArchives: recoverDamagedArchives
                )
                layout?.recordExtension(type: typeByte, start: offset, end: extensionEnd)
                offset = extensionEnd
                continue
            }

            var pax = globalPAX
            try pax.merge(localPAX, limits: limits)
            try pax.rejectForeignSparse()

            let effectiveSize: UInt64
            if let paxSize = pax["size"] {
                effectiveSize = try TarPAXRecords.unsigned(paxSize, fieldName: "size")
            } else {
                effectiveSize = headerSize
            }
            var oldSparse: TarSparseMap?
            if typeByte == UInt8(ascii: "S") {
                guard !pax.hasGNUSparse else { throw KaitoError.malformed("conflicting GNU sparse maps") }
                let parsed = try TarSparseMap.parseOldGNU(
                    header: header, dataOffset: dataOffset, storedSize: effectiveSize, source: source, limits: limits
                )
                oldSparse = parsed.map
                dataOffset = parsed.dataOffset
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
            var sparse = oldSparse
            var sparseDataOffset = dataOffset
            var sparseVersion: String? = oldSparse == nil ? nil : "GNU.sparse old"
            var sparseName: [UInt8]?
            if TarHeaderBlock.entryKind(for: typeByte) == .file, pax.hasGNUSparse {
                let parsed = try TarSparseMap.parsePAX(
                    pax, dataOffset: dataOffset, storedSize: storedSize, source: source, limits: limits
                )
                sparse = parsed.map
                sparseDataOffset = parsed.dataOffset
                sparseVersion = parsed.version
                sparseName = parsed.name
            }

            let ustarName = header.path
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

            let declaredEncoding: String.Encoding? = nameIsPAX && !pax.isBinaryHeaderCharset
                ? .utf8
                : nil
            if let declaredEncoding {
                guard EncodingDetector.decode(bytes: selectedName, as: declaredEncoding) != nil else {
                    throw KaitoError.malformed("pax path is not valid UTF-8")
                }
            }

            let kind = TarHeaderBlock.entryKind(for: typeByte)
            let mode = try header.mode()
            let uid = try paxUnsignedOrHeader(
                pax["uid"],
                header: header.uidField,
                fieldName: "uid"
            )
            let gid = try paxUnsignedOrHeader(
                pax["gid"],
                header: header.gidField,
                fieldName: "gid"
            )
            let modificationDate = try parseModificationDate(
                pax: pax["mtime"],
                header: header
            )

            let headerLink = header.linkName
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
                "typeFlag": TarHeaderBlock.typeDescription(typeByte),
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
            let pendingLink: TarPendingText?
            if let selectedLink {
                guard !selectedLink.contains(0) else {
                    throw KaitoError.malformed("tar link contains NUL")
                }
                let linkEncoding: String.Encoding? = linkIsPAX && !pax.isBinaryHeaderCharset
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
                pendingLink = TarPendingText(
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
            pendingEntries.append(TarPendingEntry(
                name: TarPendingText(
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
            records.append(TarEntryRecord(
                dataOffset: sparseDataOffset,
                size: recoverDamagedArchives
                    ? min(storedSize, source.length - dataOffset)
                    : storedSize,
                sparse: sparse
            ))
            layout?.recordMember(header: offset, body: dataOffset, end: nextOffset)

            localPAX.removeAll()
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
        for (index, pending) in pendingEntries.enumerated() {
            try checkCancellation(every: index)
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
            for (index, (bytes, string)) in zip(undecoratedNames, decodedNames).enumerated() {
                try checkCancellation(every: index)
                if let string { archiveDecodedNames[bytes] = string }
            }
        }
        let entries = try TarEntryPublisher.publish(
            pendingEntries,
            policy: policy,
            archiveEncoding: archiveEncoding,
            archiveDecodedNames: archiveDecodedNames,
            limits: limits
        )
        let storage = layout.map { TarLayoutStorage(builder: $0, records: records, imageLength: source.length, end: offset) }
        return (entries, records, archiveEncoding, storage)
    }

    static func readPayload(
        source: any ByteSource,
        offset: UInt64,
        size: UInt64
    ) throws -> [UInt8] {
        try readByteRange(source: source, offset: offset, count: Checked.toInt(size))
    }

    static func nextHeaderOffset(
        dataOffset: UInt64,
        size: UInt64,
        source: any ByteSource,
        recoverDamagedArchives: Bool = false
    ) throws -> UInt64 {
        let rounded = try Checked.add(size, UInt64(TarHeaderBlock.size - 1))
        let blocks = rounded / UInt64(TarHeaderBlock.size)
        let padded = try Checked.mul(blocks, UInt64(TarHeaderBlock.size))
        let next = try Checked.add(dataOffset, padded)
        guard next <= source.length || recoverDamagedArchives else { throw KaitoError.truncated }
        return next
    }

    static func storedBodySize(
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
        case UInt8(ascii: "1"):
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
        case UInt8(ascii: "2"), UInt8(ascii: "3"), UInt8(ascii: "4"), UInt8(ascii: "5"), UInt8(ascii: "6"):
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
        guard remaining >= UInt64(TarHeaderBlock.size) else { return false }
        try reader.seek(to: offset)
        let block = Array(try reader.readBytes(TarHeaderBlock.size))
        if block.allSatisfy({ $0 == 0 }) { return true }
        do {
            try TarHeaderBlock(bytes: block).validateChecksum()
            return true
        } catch KaitoError.malformed {
            return false
        }
    }

    private static func parseModificationDate(
        pax: [UInt8]?,
        header: TarHeaderBlock
    ) throws -> Date? {
        if let pax {
            return Date(timeIntervalSince1970: try TarPAXRecords.time(pax))
        }
        return Date(timeIntervalSince1970: try header.modificationTime())
    }

    private static func paxUnsignedOrHeader(
        _ pax: [UInt8]?,
        header: [UInt8],
        fieldName: String
    ) throws -> UInt64 {
        if let pax { return try TarPAXRecords.unsigned(pax, fieldName: fieldName) }
        return try TarHeaderBlock.parseUnsigned(header, fieldName: fieldName)
    }

    static func parseGNULongValue(
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
}
