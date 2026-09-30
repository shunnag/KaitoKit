import Foundation

/// 名前と link を復号し、metadata 上限と過去の hard link 参照を検証して公開する。
enum TarEntryPublisher {
    static func publish(
        _ pendingEntries: [TarPendingEntry],
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
                   let normalizedTarget = ArchivePath.normalizedExtractionPath(link),
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
            if let normalizedName = ArchivePath.normalizedExtractionPath(resolvedName) {
                // hard link の解決後に挿入し、参照先を必ず過去の member に限定する。
                lastEntryByNormalizedPath[normalizedName] = entry.index
            }
        }
        return entries
    }

    private static func resolve(
        _ text: TarPendingText,
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
}
