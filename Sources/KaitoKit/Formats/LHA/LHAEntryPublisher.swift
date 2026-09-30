import Foundation

/// 検証済みの LHA member を公開 entry へ変換する。書庫単位の名前判定後、
/// pending を一件ずつ解放し、公開 index と raw member の位置を別々に保持する。
enum LHAEntryPublisher {
    static func publish(
        pendingEntries: inout [LHAPendingEntry?],
        records: [LHAEntryRecord],
        policy: EncodingPolicy,
        limits: ReadLimits,
        firstHeaderOffset: UInt64,
        terminator: LHAArchiveTerminator?
    ) throws -> LHAParsedArchive {
        guard pendingEntries.count == records.count else {
            throw KaitoError.malformed("LHA entry index is inconsistent")
        }
        let batchLimit = try Checked.toInt(min(limits.maxMetadataSize, UInt64(Int.max)))
        let archiveEncoding: String.Encoding?
        do {
            // Keep this temporary array in a narrow scope. Once archive-wide
            // detection is complete, pending entries are released one by one
            // as their public entries are built.
            let undeclaredNames = pendingEntries.compactMap { pending -> [UInt8]? in
                guard let pending,
                      pending.declaredEncoding == nil,
                      !pending.rawName.isEmpty else {
                    return nil
                }
                return pending.rawName
            }
            let windowsCount = pendingEntries.reduce(into: 0) { count, pending in
                if let pending,
                   pending.declaredEncoding == nil,
                   !pending.rawName.isEmpty,
                   pending.fromWindows {
                    count += 1
                }
            }
            let fromWindows = !undeclaredNames.isEmpty
                && windowsCount >= undeclaredNames.count - windowsCount
            archiveEncoding = EncodingDetector.detectArchiveEncoding(
                names: undeclaredNames,
                policy: policy,
                fromWindows: fromWindows,
                maximumBatchByteCount: batchLimit
            )
        }

        var entries: [ArchiveEntry] = []
        entries.reserveCapacity(pendingEntries.count)
        var publishedRecords: [LHAEntryRecord] = []
        publishedRecords.reserveCapacity(records.count)
        var unpublishedMembers: [LHAUnpublishedMember] = []
        var retainedMetadataSize: UInt64 = 0

        for index in pendingEntries.indices {
            try checkCancellation(every: index)
            guard let pending = pendingEntries[index] else {
                throw KaitoError.malformed("LHA pending entry is missing")
            }
            pendingEntries[index] = nil
            let decodedName: String
            if let declaredEncoding = pending.declaredEncoding {
                guard let decoded = EncodingDetector.decode(
                    bytes: pending.rawName,
                    as: declaredEncoding
                ) else {
                    throw KaitoError.malformed("LHA declared name encoding is invalid")
                }
                decodedName = decoded
            } else {
                decodedName = EncodingDetector.resolveUndeclaredName(
                    bytes: pending.rawName,
                    policy: policy,
                    archiveEncoding: archiveEncoding,
                    fromWindows: pending.fromWindows
                ).string
            }
            let (name, linkPath, kind) = normalizeName(decoded: decodedName, pending: pending)
            if name.isEmpty {
                // Some legacy archives contain unaddressable regular members
                // with a zero-length filename. Lhasa ignores these on
                // extraction; skip their public entry while retaining the
                // already-validated member boundary for traversal.
                if terminator != nil {
                    unpublishedMembers.append(LHAUnpublishedMember(position: index, record: records[index]))
                }
                continue
            }
            guard !name.utf8.contains(0) else {
                throw KaitoError.malformed("LHA entry name cannot be decoded safely")
            }
            let pathComponents = try ArchivePath.components(
                of: name,
                limit: limits.maxPathComponentCount,
                label: "LHA path component count"
            )
            guard !pathComponents.isEmpty else {
                throw KaitoError.malformed("LHA entry has no path component")
            }

            let specific = makeFormatSpecific(
                pending: pending,
                linkPath: linkPath,
                policy: policy,
                archiveEncoding: archiveEncoding
            )

            let metadataCost = try retainedMetadataCost(
                rawName: pending.rawName,
                name: name,
                pathComponents: pathComponents,
                formatSpecific: specific
            )
            retainedMetadataSize = try Checked.add(retainedMetadataSize, metadataCost)
            try Checked.size(retainedMetadataSize, limit: limits.maxTotalMetadataSize)

            let publishedIndex = entries.count
            entries.append(ArchiveEntry(
                index: publishedIndex,
                rawName: RawName(
                    bytes: pending.rawName,
                    declaredEncoding: pending.declaredEncoding,
                    isDirectoryHint: kind == EntryKind.directory
                ),
                name: name,
                pathComponents: pathComponents,
                kind: kind,
                uncompressedSize: pending.uncompressedSize,
                compressedSize: pending.compressedSize,
                modificationDate: pending.modificationDate,
                posixPermissions: pending.permissions,
                isEncrypted: false,
                solidGroup: -1,
                crc32: nil,
                methodDescription: pending.method,
                formatSpecific: specific,
                isIncomplete: records[index].compressedSize < pending.compressedSize
            ))
            publishedRecords.append(records[index])
        }
        guard !entries.isEmpty || records.isEmpty else {
            throw KaitoError.malformed("LHA file member has an empty filename")
        }
        return LHAParsedArchive(
            entries: entries,
            records: publishedRecords,
            nameEncoding: archiveEncoding,
            firstHeaderOffset: firstHeaderOffset,
            terminator: terminator,
            unpublishedMembers: unpublishedMembers
        )
    }

    /// Turns a decoded member name into its published path, splitting the
    /// target off a Unix symbolic link stored as `name|target` in a `-lhd-`
    /// member. The name is empty when the member has no addressable path.
    private static func normalizeName(
        decoded decodedName: String,
        pending: LHAPendingEntry
    ) -> (name: String, linkPath: String?, kind: EntryKind) {
        // The caller decodes first: in CP932/CP936, 0x5c can be the trail byte
        // of a multibyte character and must not be rewritten as a raw byte.
        // Old DOS writers put backslash separators even in level-2 filename
        // extensions.
        let separatorNormalizedName = decodedName.replacingOccurrences(of: "\\", with: "/")
        let unixFileType = pending.extended.unixMode.map { $0 & 0o170000 }
        let isUnixSymbolicLink = pending.method == "-lhd-"
            && unixFileType == 0o120000
        var storedName = separatorNormalizedName
        var linkPath: String?
        if isUnixSymbolicLink,
           let separator = storedName.firstIndex(of: "|") {
            linkPath = String(storedName[storedName.index(after: separator)...])
            storedName = String(storedName[..<separator])
        }
        let isDirectory = !isUnixSymbolicLink
            && (pending.directoryHint || storedName.hasSuffix("/"))
        var name = relativeArchivePath(storedName)
        if name.isEmpty, isDirectory {
            // Empty -lhd- names denote the archive root. Keeping a dot
            // entry lets extraction drain/authenticate the member without
            // inventing a filesystem leaf.
            name = "."
        }
        let kind: EntryKind
        if isUnixSymbolicLink {
            kind = .symlink
        } else {
            kind = isDirectory ? .directory : .file
        }
        return (name, linkPath, kind)
    }

    /// The `formatSpecific` values published for one member. Auxiliary text
    /// (comment, group, user) is decoded like the member name.
    private static func makeFormatSpecific(
        pending: LHAPendingEntry,
        linkPath: String?,
        policy: EncodingPolicy,
        archiveEncoding: String.Encoding?
    ) -> [String: String] {
        var specific: [String: String] = [
            "attribute": String(format: "0x%02x", pending.attribute),
            "dataCRC16": String(format: "%04x", pending.crc16),
            "dataOffset": String(pending.dataOffset),
            "headerLevel": String(pending.headerLevel),
            "headerOffset": String(pending.headerOffset),
            "method": pending.method,
            "os": osDescription(pending.osID),
        ]
        if let linkPath {
            specific["linkPath"] = linkPath
        }
        if let osID = pending.osID {
            specific["osID"] = printableOSID(osID)
        }
        if let value = pending.extended.dosAttributes {
            specific["dosAttributes"] = String(format: "0x%04x", value)
        }
        if let value = pending.extended.codePage {
            specific["codePage"] = String(value)
        }
        if let value = pending.extended.uid {
            specific["uid"] = String(value)
        }
        if let value = pending.extended.gid {
            specific["gid"] = String(value)
        }
        if let value = pending.extended.windowsCreationDate {
            specific["creationTime"] = unixTimeDescription(value)
        }
        if let value = pending.extended.windowsAccessDate {
            specific["accessTime"] = unixTimeDescription(value)
        }
        if let value = pending.extended.comment {
            specific["comment"] = decodeAuxiliaryText(
                value,
                declaredEncoding: pending.declaredEncoding,
                policy: policy,
                archiveEncoding: archiveEncoding,
                fromWindows: pending.fromWindows
            )
        }
        if let value = pending.extended.group {
            specific["group"] = decodeAuxiliaryText(
                value,
                declaredEncoding: pending.declaredEncoding,
                policy: policy,
                archiveEncoding: archiveEncoding,
                fromWindows: pending.fromWindows
            )
        }
        if let value = pending.extended.user {
            specific["user"] = decodeAuxiliaryText(
                value,
                declaredEncoding: pending.declaredEncoding,
                policy: policy,
                archiveEncoding: archiveEncoding,
                fromWindows: pending.fromWindows
            )
        }
        return specific
    }

    /// Makes absolute-looking legacy member names relative without resolving
    /// any components. In particular, `..` remains present so Extractor's
    /// existing traversal check still rejects it.
    private static func relativeArchivePath(_ path: String) -> String {
        let bytes = path.utf8
        var start = bytes.startIndex

        while start != bytes.endIndex, bytes[start] == 0x2F {
            start = bytes.index(after: start)
        }

        if start != bytes.endIndex {
            let colon = bytes.index(after: start)
            if colon != bytes.endIndex {
                let first = bytes[start]
                let isDriveLetter = (0x41...0x5A).contains(first)
                    || (0x61...0x7A).contains(first)
                if isDriveLetter, bytes[colon] == 0x3A {
                    start = bytes.index(after: colon)
                    while start != bytes.endIndex, bytes[start] == 0x2F {
                        start = bytes.index(after: start)
                    }
                }
            }
        }
        return String(decoding: bytes[start...], as: UTF8.self)
    }

    private static func decodeAuxiliaryText(
        _ bytes: [UInt8],
        declaredEncoding: String.Encoding?,
        policy: EncodingPolicy,
        archiveEncoding: String.Encoding?,
        fromWindows: Bool
    ) -> String {
        if let declaredEncoding,
           let decoded = EncodingDetector.decode(bytes: bytes, as: declaredEncoding) {
            return decoded
        }
        return EncodingDetector.resolveUndeclaredName(
            bytes: bytes,
            policy: policy,
            archiveEncoding: archiveEncoding,
            fromWindows: fromWindows
        ).string
    }

    private static func retainedMetadataCost(
        rawName: [UInt8],
        name: String,
        pathComponents: [String],
        formatSpecific: [String: String]
    ) throws -> UInt64 {
        var total: UInt64 = 256
        total = try Checked.add(total, UInt64(rawName.count))
        total = try Checked.add(total, UInt64(name.utf8.count))
        for component in pathComponents {
            total = try Checked.add(total, UInt64(component.utf8.count))
        }
        for (key, value) in formatSpecific {
            total = try Checked.add(total, UInt64(key.utf8.count))
            total = try Checked.add(total, UInt64(value.utf8.count))
        }
        return total
    }

    private static func osDescription(_ value: UInt8?) -> String {
        guard let value else { return "unspecified" }
        switch value {
        case 0: return "generic"
        case 0x20: return "LHARK"
        case 0x32: return "OS/2"
        case 0x33: return "OS/386"
        case 0x39: return "OS-9"
        case 0x41: return "Amiga"
        case 0x43: return "CP/M"
        case 0x46: return "FLEX"
        case 0x48: return "Human68k"
        case 0x4A: return "Java"
        case 0x4B: return "OS/68K"
        case 0x4D: return "MS-DOS"
        case 0x52: return "Runser"
        case 0x54: return "TownsOS"
        case 0x55: return "Unix"
        case 0x58: return "X-OSK"
        case 0x57: return "Windows NT"
        case 0x61: return "Atari"
        case 0x6D: return "Macintosh"
        case 0x77: return "Windows 95"
        default: return String(format: "0x%02x", value)
        }
    }

    private static func printableOSID(_ value: UInt8) -> String {
        if (0x20...0x7E).contains(value) {
            return String(UnicodeScalar(value))
        }
        return String(format: "0x%02x", value)
    }

    private static func unixTimeDescription(_ date: Date) -> String {
        String(format: "%.7f", date.timeIntervalSince1970)
    }
}
