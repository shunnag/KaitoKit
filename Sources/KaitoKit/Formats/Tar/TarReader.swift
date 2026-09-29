import Foundation

// POSIX ustar/pax と GNU tar 拡張の公開仕様だけを参照したクリーンルーム実装。
final class TarReader: FormatReader {
    struct Record: Sendable {
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
    let layoutStorage: TarLayoutStorage?

    init(source: any ByteSource, options: ReaderOptions) throws {
        self.source = source
        let parsed = try Self.parse(
            source: source,
            policy: options.encodingPolicy,
            limits: options.limits,
            recoverDamagedArchives: options.recoverDamagedArchives,
            recordsLayout: options.recordsTarEditLayout
        )
        entries = parsed.entries
        nameEncoding = parsed.nameEncoding
        records = parsed.records
        layoutStorage = parsed.layout
    }

    private init(source: any ByteSource, entries: [ArchiveEntry],
                 nameEncoding: String.Encoding?, records: [Record], layoutStorage: TarLayoutStorage?) {
        self.source = source
        self.entries = entries
        self.nameEncoding = nameEncoding
        self.records = records
        self.layoutStorage = layoutStorage
    }

    func reopened(options: ReaderOptions) -> sending (any FormatReader)? {
        TarReader(source: source, entries: entries, nameEncoding: nameEncoding, records: records, layoutStorage: layoutStorage)
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        // entries と records は parse が同じ順に一つずつ積むので、entries の index で records も引ける。
        let record = records[try recordIndex(of: entry, label: "tar")]
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
        recoverDamagedArchives: Bool,
        recordsLayout: Bool
    ) throws -> (
        entries: [ArchiveEntry],
        records: [Record],
        nameEncoding: String.Encoding?,
        layout: TarLayoutStorage?
    ) {
        let layout = recordsLayout ? TarLayoutStorage.Builder(recovery: recoverDamagedArchives) : nil
        var pendingEntries: [PendingEntry] = []
        var records: [Record] = []
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
            let pendingLink: PendingText?
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
        let entries = try finalizeEntries(
            pendingEntries,
            policy: policy,
            archiveEncoding: archiveEncoding,
            archiveDecodedNames: archiveDecodedNames,
            limits: limits
        )
        let storage = layout.map { TarLayoutStorage(builder: $0, records: records, imageLength: source.length, end: offset) }
        return (entries, records, archiveEncoding, storage)
    }

    static func headerGroup(_ member: TarMemberLayout, layout: TarArchiveLayout,
                            source: any ByteSource, limits: ReadLimits) throws -> TarHeaderGroup {
        let paxLocal = [UInt8(ascii: "x"), UInt8(ascii: "X")]
        let gnuLong = [UInt8(ascii: "L"), UInt8(ascii: "K")]
        do {
            var global = TarPAXRecords(), local = TarPAXRecords()
            for range in layout.globalHeaderRanges where range.lowerBound < member.headerOffset {
                let header = TarHeaderBlock(bytes: try readByteRange(source: source, offset: range.lowerBound, count: TarHeaderBlock.size))
                try header.validateChecksum()
                guard header.typeFlag == UInt8(ascii: "g") else { throw KaitoError.truncated }
                let size = try header.size()
                try Checked.size(size, limit: limits.maxMetadataSize)
                let body = try Checked.add(range.lowerBound, UInt64(TarHeaderBlock.size))
                guard try nextHeaderOffset(dataOffset: body, size: size, source: source) == range.upperBound else { throw KaitoError.truncated }
                let paxRecords = try TarPAXRecords.parse(readPayload(source: source, offset: body, size: size), recordLimit: limits.maxMetadataRecordCount)
                try paxRecords.rejectGlobalSparse()
                try global.merge(paxRecords.retained(), limits: limits)
            }
            var cursor = member.groupRange.lowerBound
            var extensions: [TarHeaderGroup.Extension] = []
            while cursor < member.headerOffset {
                let header = TarHeaderBlock(bytes: try readByteRange(source: source, offset: cursor, count: TarHeaderBlock.size))
                try header.validateChecksum()
                let type = header.typeFlag
                guard (paxLocal + gnuLong).contains(type) else { throw KaitoError.truncated }
                let size = try header.size()
                try Checked.size(size, limit: limits.maxMetadataSize)
                let body = try Checked.add(cursor, UInt64(TarHeaderBlock.size))
                let end = try nextHeaderOffset(dataOffset: body, size: size, source: source)
                guard end <= member.headerOffset else { throw KaitoError.truncated }
                let payload = try readPayload(source: source, offset: body, size: size)
                if paxLocal.contains(type) {
                    local = try TarPAXRecords.parse(payload, recordLimit: limits.maxMetadataRecordCount).retained()
                } else { _ = try parseGNULongValue(payload, fieldName: type == UInt8(ascii: "L") ? "name" : "link") }
                extensions.append(.init(typeFlag: type, headerOffset: cursor, payloadRange: body..<(body + size), end: end))
                cursor = end
            }
            guard cursor == member.headerOffset else { throw KaitoError.truncated }
            let header = TarHeaderBlock(bytes: try readByteRange(source: source, offset: cursor, count: TarHeaderBlock.size))
            try header.validateChecksum()
            let type = header.typeFlag
            guard !(paxLocal + gnuLong + [UInt8(ascii: "g")]).contains(type) else { throw KaitoError.truncated }
            try global.merge(local, limits: limits)
            let headerSize = try header.size()
            let effectiveSize = try global["size"].map { try TarPAXRecords.unsigned($0, fieldName: "size") } ?? headerSize
            let extensionStart = try Checked.add(cursor, UInt64(TarHeaderBlock.size))
            var body = extensionStart
            if type == UInt8(ascii: "S") {
                body = try TarSparseMap.parseOldGNU(
                    header: header, dataOffset: body, storedSize: effectiveSize, source: source, limits: limits
                ).dataOffset
            }
            var reader = try ByteReader(source: source, bufferCapacity: 4 * 1024)
            let size = try storedBodySize(typeByte: type, declaredSize: effectiveSize,
                                          hasAuthoritativePAXSize: global["size"] != nil, dataOffset: body,
                                          source: source, reader: &reader, recoverDamagedArchives: false)
            guard body == member.bodyRange.lowerBound, size == member.bodyRange.upperBound - body,
                  try nextHeaderOffset(dataOffset: body, size: size, source: source) == member.groupRange.upperBound else {
                throw KaitoError.truncated
            }
            return TarHeaderGroup(extensions: extensions, headerOffset: cursor, typeFlag: type,
                                  sparseExtensionRange: body > extensionStart ? extensionStart..<body : nil)
        } catch {
            throw KaitoError.malformed("tar layout does not match the image")
        }
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

        for (index, pending) in pendingEntries.enumerated() {
            try checkCancellation(every: index)
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
            let pathComponents = try ArchivePath.components(
                of: resolvedName,
                limit: limits.maxPathComponentCount,
                label: "tar entry path component count"
            )

            var specific = pending.formatSpecific
            if let pendingLink = pending.link {
                let link = try resolve(
                    pendingLink,
                    policy: policy,
                    archiveEncoding: archiveEncoding,
                    archiveDecodedNames: archiveDecodedNames,
                    invalidDeclaredMessage: "pax linkpath is not valid UTF-8"
                )
                try ArchivePath.validateComponentCount(
                    of: link,
                    limit: limits.maxPathComponentCount,
                    label: "tar link component count"
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
        let rounded = try Checked.add(size, UInt64(TarHeaderBlock.size - 1))
        let blocks = rounded / UInt64(TarHeaderBlock.size)
        let padded = try Checked.mul(blocks, UInt64(TarHeaderBlock.size))
        let next = try Checked.add(dataOffset, padded)
        guard next <= source.length || recoverDamagedArchives else { throw KaitoError.truncated }
        return next
    }

    /// FormatDetector の入口。判定は `TarHeaderBlock.isPlausibleMemberHeader`。
    static func isPlausibleMemberHeader(_ header: [UInt8]) -> Bool {
        TarHeaderBlock.isPlausibleMemberHeader(header)
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
}
