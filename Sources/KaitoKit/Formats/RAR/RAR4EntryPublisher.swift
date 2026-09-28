import Foundation

// Provenance:
// - RAR 1.5-4.x unofficial format notes:
//   https://github.com/bitplane/rar-research/blob/master/doc/RAR15_40_FORMAT_SPECIFICATION.md
// - libarchive's BSD-2-licensed archive_read_support_format_rar.c was consulted
//   for format behaviour (block traversal, optional-field order, Unicode-name
//   decoding, and extended timestamps), not for code or structure:
//   https://github.com/libarchive/libarchive/blob/master/libarchive/archive_read_support_format_rar.c
// No 7-Zip Rar29, unrar source, XADMaster, or The Unarchiver source was used.

/// Walks a RAR4 volume set, joins split file fragments, derives solid groups,
/// resolves undeclared name encodings, and publishes `ArchiveEntry` values with
/// the matching `RAR4EntryRecord` read plans.
enum RAR4EntryPublisher {
    static func parse(
        source: any ByteSource,
        sourceURL: URL?,
        sourceDirectoryAnchor: FileByteSource.DirectoryAnchor?,
        options: ReaderOptions,
        signatureOffset: UInt64,
        headerKeyCache: RAR3KeyCache,
        passwordEncodings: RAR4Reader.PasswordEncodingSelection
    ) throws -> RAR4ParsedArchive {
        var resolvedPassword = options.password
        let first = try RAR4VolumeParser.parseVolume(
            source: source,
            limits: options.limits,
            password: &resolvedPassword,
            passwordProvider: options.passwordProvider,
            headerKeyCache: headerKeyCache,
            passwordEncodings: passwordEncodings,
            signatureOffset: signatureOffset
        )
        guard first.mainHeader.isVolume, let sourceURL else {
            return try publish(
                pendingEntries: first.pendingEntries,
                records: first.records,
                mainHeader: first.mainHeader,
                policy: options.encodingPolicy,
                limits: options.limits,
                resolvedPassword: resolvedPassword
            )
        }

        let naming: RARVolumeNaming = first.mainHeader.flags & RAR4MainFlag.newNumbering != 0
            ? .rar4New
            : .rar4Old
        let locator = try RARVolumeLocator(
            firstVolumeURL: sourceURL,
            firstVolumeSource: source,
            firstVolumeDirectory: sourceDirectoryAnchor,
            naming: naming,
            maxMetadataSize: options.limits.maxMetadataSize,
            maxVolumeCount: options.limits.maxVolumeCount
        )
        var mergedEntries: [RAR4PendingEntry] = []
        var mergedRecords: [RAR4EntryRecord] = []
        var activeEntry: RAR4PendingEntry?
        var activeRecord: RAR4EntryRecord?
        var retainedMetadataSize: UInt64 = 0
        try mergeFragments(
            entries: first.pendingEntries,
            records: first.records,
            into: &mergedEntries,
            mergedRecords: &mergedRecords,
            activeEntry: &activeEntry,
            activeRecord: &activeRecord,
            retainedMetadataSize: &retainedMetadataSize,
            limits: options.limits
        )

        var current = first
        var volumeNumber: UInt64 = 0
        while current.requestsNextVolume {
            let nextNumber = try Checked.add(volumeNumber, 1)
            guard nextNumber < UInt64(options.limits.maxVolumeCount) else {
                throw KaitoError.limitExceeded("RAR4 volume count")
            }
            let located = try locator.locate(volumeNumber: nextNumber)
            let next = try RAR4VolumeParser.parseVolume(
                source: located.source,
                limits: options.limits,
                password: &resolvedPassword,
                passwordProvider: options.passwordProvider,
                headerKeyCache: headerKeyCache,
                passwordEncodings: passwordEncodings,
                signatureOffset: 0
            )
            guard next.mainHeader.isVolume else {
                throw KaitoError.malformed("RAR4 continuation is not marked as a volume")
            }
            guard next.mainHeader.isSolid == first.mainHeader.isSolid else {
                throw KaitoError.malformed("RAR4 solid flag changes between volumes")
            }
            guard (next.mainHeader.flags & RAR4MainFlag.newNumbering != 0) ==
                    (first.mainHeader.flags & RAR4MainFlag.newNumbering != 0) else {
                throw KaitoError.malformed("RAR4 numbering mode changes between volumes")
            }
            guard next.mainHeader.flags & RAR4MainFlag.firstVolume == 0 else {
                throw KaitoError.malformed("RAR4 continuation is marked as first volume")
            }
            try mergeFragments(
                entries: next.pendingEntries,
                records: next.records,
                into: &mergedEntries,
                mergedRecords: &mergedRecords,
                activeEntry: &activeEntry,
                activeRecord: &activeRecord,
                retainedMetadataSize: &retainedMetadataSize,
                limits: options.limits
            )
            current = next
            volumeNumber = nextNumber
        }
        guard activeEntry == nil, activeRecord == nil else { throw KaitoError.truncated }
        return try publish(
            pendingEntries: mergedEntries,
            records: mergedRecords,
            mainHeader: first.mainHeader,
            policy: options.encodingPolicy,
            limits: options.limits,
            resolvedPassword: resolvedPassword
        )
    }

    private static func mergeFragments(
        entries: [RAR4PendingEntry],
        records: [RAR4EntryRecord],
        into completedEntries: inout [RAR4PendingEntry],
        mergedRecords: inout [RAR4EntryRecord],
        activeEntry: inout RAR4PendingEntry?,
        activeRecord: inout RAR4EntryRecord?,
        retainedMetadataSize: inout UInt64,
        limits: ReadLimits
    ) throws {
        guard entries.count == records.count else {
            throw KaitoError.malformed("RAR4 volume entry records are inconsistent")
        }
        for (entry, record) in zip(entries, records) {
            if record.firstFlags & RAR4FileFlag.splitBefore != 0 {
                guard let precedingEntry = activeEntry,
                      let precedingRecord = activeRecord,
                      precedingRecord.lastFlags & RAR4FileFlag.splitAfter != 0 else {
                    throw KaitoError.malformed(
                        "RAR4 split continuation has no preceding file part"
                    )
                }
                let merged = try mergeSplitParts(
                    precedingEntry,
                    precedingRecord,
                    entry,
                    record
                )
                activeEntry = merged.entry
                activeRecord = merged.record
            } else {
                guard activeEntry == nil, activeRecord == nil else {
                    throw KaitoError.malformed("RAR4 split continuation is missing")
                }
                activeEntry = entry
                activeRecord = record
            }

            if let finishedEntry = activeEntry,
               let finishedRecord = activeRecord,
               finishedRecord.lastFlags & RAR4FileFlag.splitAfter == 0 {
                guard completedEntries.count < limits.maxEntryCount else {
                    throw KaitoError.limitExceeded("archive entry count")
                }
                let nextRetainedMetadataSize = try Checked.add(
                    retainedMetadataSize,
                    RAR4VolumeParser.pendingMetadataCost(finishedEntry)
                )
                try Checked.size(
                    nextRetainedMetadataSize,
                    limit: limits.maxTotalMetadataSize
                )
                retainedMetadataSize = nextRetainedMetadataSize
                completedEntries.append(finishedEntry)
                mergedRecords.append(finishedRecord)
                activeEntry = nil
                activeRecord = nil
            }
        }
    }

    private static func mergeSplitParts(
        _ firstEntry: RAR4PendingEntry,
        _ firstRecord: RAR4EntryRecord,
        _ continuationEntry: RAR4PendingEntry,
        _ continuationRecord: RAR4EntryRecord
    ) throws -> (entry: RAR4PendingEntry, record: RAR4EntryRecord) {
        let splitMask = RAR4FileFlag.splitBefore | RAR4FileFlag.splitAfter
        guard firstEntry.rawName == continuationEntry.rawName,
              firstEntry.fallbackName == continuationEntry.fallbackName,
              firstEntry.decodedUnicodeName == continuationEntry.decodedUnicodeName,
              firstEntry.declaredEncoding == continuationEntry.declaredEncoding,
              firstEntry.kind == continuationEntry.kind,
              firstEntry.unpackedSize == continuationEntry.unpackedSize,
              firstEntry.modificationDate == continuationEntry.modificationDate,
              firstEntry.permissions == continuationEntry.permissions,
              firstEntry.isEncrypted == continuationEntry.isEncrypted,
              firstRecord.unpackVersion == continuationRecord.unpackVersion,
              firstRecord.method == continuationRecord.method,
              firstRecord.dictionarySize == continuationRecord.dictionarySize,
              firstRecord.salt == continuationRecord.salt,
              firstRecord.lastFlags & ~splitMask ==
                continuationRecord.firstFlags & ~splitMask else {
            throw KaitoError.malformed("RAR4 split file metadata changes between volumes")
        }

        let packedSize = try Checked.add(
            firstRecord.packedSize,
            continuationRecord.packedSize
        )
        let segmentCount = try Checked.add(
            UInt64(firstRecord.packedSegments.count),
            UInt64(continuationRecord.packedSegments.count)
        )
        guard segmentCount <= 65_536 else {
            throw KaitoError.limitExceeded("RAR4 split stream has too many segments")
        }
        var specific = firstEntry.formatSpecific
        specific["splitAfter"] = continuationRecord.lastFlags & RAR4FileFlag.splitAfter != 0
            ? "true"
            : "false"
        specific["volumeSegmentCount"] = String(segmentCount)
        specific["multiVolume"] = "true"

        return (
            RAR4PendingEntry(
                rawName: firstEntry.rawName,
                fallbackName: firstEntry.fallbackName,
                decodedUnicodeName: firstEntry.decodedUnicodeName,
                declaredEncoding: firstEntry.declaredEncoding,
                kind: firstEntry.kind,
                unpackedSize: firstEntry.unpackedSize,
                packedSize: packedSize,
                modificationDate: firstEntry.modificationDate,
                permissions: firstEntry.permissions,
                isEncrypted: firstEntry.isEncrypted,
                crc32: continuationEntry.crc32,
                methodDescription: firstEntry.methodDescription,
                formatSpecific: specific
            ),
            RAR4EntryRecord(
                packedSegments: firstRecord.packedSegments
                    + continuationRecord.packedSegments,
                packedPartCRC32: firstRecord.packedPartCRC32
                    + continuationRecord.packedPartCRC32,
                packedSize: packedSize,
                unpackedSize: firstRecord.unpackedSize,
                crc32: continuationRecord.crc32,
                firstFlags: firstRecord.firstFlags,
                lastFlags: continuationRecord.lastFlags,
                unpackVersion: firstRecord.unpackVersion,
                method: firstRecord.method,
                dictionarySize: firstRecord.dictionarySize,
                salt: firstRecord.salt
            )
        )
    }

    private static func publish(
        pendingEntries: [RAR4PendingEntry],
        records: [RAR4EntryRecord],
        mainHeader: RAR4MainHeader,
        policy: EncodingPolicy,
        limits: ReadLimits,
        resolvedPassword: String?
    ) throws -> RAR4ParsedArchive {
        guard pendingEntries.count == records.count else {
            throw KaitoError.malformed("RAR4 entry index is inconsistent")
        }
        let undecoratedNames = pendingEntries.compactMap { pending -> [UInt8]? in
            pending.decodedUnicodeName == nil ? pending.fallbackName : nil
        }
        let batchLimit = try Checked.toInt(min(
            limits.maxMetadataSize,
            UInt64(Int.max)
        ))
        let archiveEncoding = EncodingDetector.detectArchiveEncoding(
            names: undecoratedNames,
            policy: policy,
            fromWindows: true,
            maximumBatchByteCount: batchLimit
        )

        var entries: [ArchiveEntry] = []
        entries.reserveCapacity(pendingEntries.count)

        // FHD_SOLID marks a file as continuing the dictionary of the previous
        // compressed file. Consequently a group becomes observable only at
        // the first continuation: its independent predecessor is then the
        // group leader. Directories and method 0x30 never join or break the run:
        // stored members leave all solid state untouched regardless of flags or
        // unpack version (RAR 6.24 behaviour).
        var solidGroups = [Int](repeating: -1, count: pendingEntries.count)
        var previousFileIndex: Int?
        for index in pendingEntries.indices {
            try checkCancellation(every: index)
            guard pendingEntries[index].kind != .directory
                && records[index].method != RAR4Method.stored else { continue }
            let continuesSolidStream = records[index].firstFlags & RAR4FileFlag.solid != 0
            if continuesSolidStream {
                guard mainHeader.isSolid else {
                    throw KaitoError.malformed(
                        "RAR4 solid file is not in a solid archive"
                    )
                }
                guard let predecessor = previousFileIndex else {
                    throw KaitoError.malformed(
                        "first RAR4 file cannot continue a solid stream"
                    )
                }
                let group = solidGroups[predecessor] >= 0
                    ? solidGroups[predecessor]
                    : predecessor
                solidGroups[predecessor] = group
                solidGroups[index] = group
            }
            previousFileIndex = index
        }

        for (index, pending) in pendingEntries.enumerated() {
            try checkCancellation(every: index)
            let unresolved = pending.decodedUnicodeName == nil
            let decoded = pending.decodedUnicodeName ??
                EncodingDetector.resolveUndeclaredName(
                    bytes: pending.fallbackName,
                    policy: policy,
                    archiveEncoding: archiveEncoding,
                    fromWindows: true
                ).string
            let name = decoded.replacingOccurrences(of: "\\", with: "/")
            guard !name.isEmpty, !name.utf8.contains(0) else {
                throw KaitoError.malformed("RAR4 entry name cannot be decoded safely")
            }
            let components = name
                .utf8.split(separator: 0x2F, omittingEmptySubsequences: true)
                .map { String(decoding: $0, as: UTF8.self) }
            guard components.count <= limits.maxPathComponentCount else {
                throw KaitoError.limitExceeded("RAR4 path component count")
            }

            entries.append(ArchiveEntry(
                index: index,
                rawName: RawName(
                    bytes: pending.rawName,
                    declaredEncoding: pending.declaredEncoding,
                    isDirectoryHint: pending.kind == .directory
                ),
                name: name,
                pathComponents: components,
                kind: pending.kind,
                uncompressedSize: pending.unpackedSize,
                compressedSize: pending.packedSize,
                modificationDate: pending.modificationDate,
                posixPermissions: pending.permissions,
                isEncrypted: pending.isEncrypted,
                solidGroup: solidGroups[index],
                crc32: pending.crc32,
                methodDescription: pending.methodDescription,
                formatSpecific: pending.formatSpecific.merging(
                    ["nameSource": unresolved ? "legacy" : "unicode"],
                    uniquingKeysWith: { current, _ in current }
                )
            ))
        }
        return RAR4ParsedArchive(
            entries: entries,
            records: records,
            nameEncoding: archiveEncoding,
            resolvedPassword: resolvedPassword
        )
    }
}
