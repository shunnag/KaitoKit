import Foundation

// Format reference: RARLab, "RAR 5.0 archive format",
// https://www.rarlab.com/technote.htm (accessed 2026-09-06).
// This is a clean-room implementation of the published format description.
// RARLab/UnRAR, 7-Zip, XADMaster, and The Unarchiver source code were not used.

/// Walks a RAR5 volume set, joins split file fragments into one pending entry
/// per file, and publishes them as `ArchiveEntry` values with the matching
/// `RAR5EntryRecord` read plans (solid groups, redirections, file copies).
enum RAR5EntryPublisher {
    static func parse(
        source: any ByteSource,
        sourceURL: URL?,
        sourceDirectoryAnchor: FileByteSource.DirectoryAnchor?,
        options: ReaderOptions,
        passwordSelection: RAR5PasswordSelection
    ) throws -> (entries: [ArchiveEntry], records: [RAR5EntryRecord], password: String?) {
        var resolvedPassword = options.password
        // One archive-encryption envelope can occur per volume. Retaining every
        // reachable context makes the cumulative work accounting match actual
        // derivations rather than charging harmless repeated envelopes.
        let headerKeyCache = RAR5KeyCache(
            capacity: max(1, options.limits.maxVolumeCount),
            passwordSelection: passwordSelection
        )
        var headerKDFBudget = RAR5HeaderKDFWorkBudget(
            limit: options.limits.maxRAR5HeaderKDFWork
        )
        let first = try RAR5VolumeParser.parseVolume(
            source: source,
            volumeNumber: 0,
            options: options,
            password: &resolvedPassword,
            keyCache: headerKeyCache,
            expectedHeaderEncryption: nil,
            headerKDFBudget: &headerKDFBudget
        )
        guard first.volumeNumber == 0 else {
            throw KaitoError.malformed(
                "RAR5 volume number \(first.volumeNumber) does not match expected 0"
            )
        }
        if first.archiveFlags.contains(RAR5ArchiveFlags.volumeNumber), first.volumeNumber == 0 {
            throw KaitoError.malformed(
                "RAR5 first volume has an explicit volume number"
            )
        }

        // A missing volume is not a truncated single archive: split entries are
        // never recovered.
        if options.recoverDamagedArchives,
           !first.sawEndHeader, first.archiveFlags.contains(RAR5ArchiveFlags.volume) {
            throw KaitoError.truncated
        }

        guard first.archiveFlags.contains(RAR5ArchiveFlags.volume), let sourceURL else {
            if first.endFlags.contains(RAR5EndFlags.moreVolumes),
               !first.archiveFlags.contains(RAR5ArchiveFlags.volume) {
                throw KaitoError.malformed(
                    "RAR5 non-volume requests a continuation volume"
                )
            }
            let published = try publish(
                first.pending,
                archiveFlags: first.archiveFlags,
                recoverDamagedArchives: options.recoverDamagedArchives
            )
            return (published.entries, published.records, resolvedPassword)
        }

        // The locator authenticates an unencrypted main header immediately. If
        // headers are encrypted it validates the leading type-4 envelope, and
        // parseVolume below authenticates/decrypts the main header and checks
        // the volume marker and number before accepting any packed ranges.
        let locator = try RARVolumeLocator(
            firstVolumeURL: sourceURL,
            firstVolumeSource: source,
            firstVolumeDirectory: sourceDirectoryAnchor,
            naming: .rar5,
            maxMetadataSize: options.limits.maxMetadataSize,
            maxVolumeCount: options.limits.maxVolumeCount
        )
        var merged: [RAR5PendingEntry] = []
        var activeSplit: RAR5PendingEntry?
        var current = first
        var volumeNumber: UInt64 = 0
        var totalRetainedMetadata = current.retainedMetadataSize
        var totalServiceHeaders = current.serviceHeaderCount

        try mergeFragments(
            current.pending,
            into: &merged,
            activeSplit: &activeSplit,
            limits: options.limits
        )

        while current.endFlags.contains(RAR5EndFlags.moreVolumes) {
            let nextNumber = try Checked.add(volumeNumber, 1)
            guard nextNumber < UInt64(options.limits.maxVolumeCount) else {
                throw KaitoError.limitExceeded("RAR5 volume count")
            }
            let located = try locator.locate(volumeNumber: nextNumber)
            let next = try RAR5VolumeParser.parseVolume(
                source: located.source,
                volumeNumber: nextNumber,
                options: options,
                password: &resolvedPassword,
                keyCache: headerKeyCache,
                expectedHeaderEncryption: first.headersEncrypted,
                headerKDFBudget: &headerKDFBudget
            )
            guard next.archiveFlags.contains(RAR5ArchiveFlags.volume) else {
                throw KaitoError.malformed(
                    "RAR5 continuation is not marked as a volume"
                )
            }
            guard next.volumeNumber == nextNumber else {
                throw KaitoError.malformed(
                    "RAR5 volume number \(next.volumeNumber) does not match expected \(nextNumber)"
                )
            }
            let nextIsSolid = next.archiveFlags.contains(RAR5ArchiveFlags.solid)
            let firstIsSolid = first.archiveFlags.contains(RAR5ArchiveFlags.solid)
            guard nextIsSolid == firstIsSolid else {
                throw KaitoError.malformed(
                    "RAR5 solid archive flag changes between volumes"
                )
            }

            totalRetainedMetadata = try Checked.add(
                totalRetainedMetadata,
                next.retainedMetadataSize
            )
            try Checked.size(
                totalRetainedMetadata,
                limit: options.limits.maxTotalMetadataSize
            )
            totalServiceHeaders = try checkedMetadataRecordSum(
                totalServiceHeaders,
                next.serviceHeaderCount,
                limit: options.limits.maxMetadataRecordCount,
                label: "RAR5 service header count"
            )

            try mergeFragments(
                next.pending,
                into: &merged,
                activeSplit: &activeSplit,
                limits: options.limits
            )
            current = next
            volumeNumber = nextNumber
        }

        guard activeSplit == nil else { throw KaitoError.truncated }
        guard merged.count <= options.limits.maxEntryCount else {
            throw KaitoError.limitExceeded("RAR5 entry count")
        }
        let published = try publish(
            merged,
            archiveFlags: first.archiveFlags,
            recoverDamagedArchives: options.recoverDamagedArchives
        )
        return (published.entries, published.records, resolvedPassword)
    }

    private static func checkedMetadataRecordSum(
        _ lhs: Int,
        _ rhs: Int,
        limit: Int,
        label: String
    ) throws -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow, sum <= limit else {
            throw KaitoError.limitExceeded(label)
        }
        return sum
    }

    private static func mergeFragments(
        _ fragments: [RAR5PendingEntry],
        into completed: inout [RAR5PendingEntry],
        activeSplit: inout RAR5PendingEntry?,
        limits: ReadLimits
    ) throws {
        for fragment in fragments {
            if fragment.splitBefore {
                guard let active = activeSplit, active.splitAfter else {
                    throw KaitoError.malformed(
                        "RAR5 split continuation has no preceding file part"
                    )
                }
                activeSplit = try mergeSplitParts(active, fragment)
            } else {
                guard activeSplit == nil else {
                    throw KaitoError.malformed(
                        "RAR5 split continuation is missing"
                    )
                }
                activeSplit = fragment
            }

            if let active = activeSplit, !active.splitAfter {
                guard completed.count < limits.maxEntryCount else {
                    throw KaitoError.limitExceeded("RAR5 entry count")
                }
                completed.append(active)
                activeSplit = nil
            }
        }
    }

    private static func mergeSplitParts(
        _ first: RAR5PendingEntry,
        _ continuation: RAR5PendingEntry
    ) throws -> RAR5PendingEntry {
        let expectedVolume = try Checked.add(first.lastVolumeNumber, 1)
        guard continuation.firstVolumeNumber == expectedVolume,
              continuation.lastVolumeNumber == expectedVolume else {
            throw KaitoError.malformed(
                "RAR5 split file parts are not in consecutive volumes"
            )
        }
        guard first.rawName == continuation.rawName,
              first.name == continuation.name,
              first.pathComponents == continuation.pathComponents,
              first.kind == continuation.kind,
              first.compression == continuation.compression,
              first.attributes == continuation.attributes,
              first.hostOS == continuation.hostOS,
              first.permissions == continuation.permissions,
              first.modificationDate == continuation.modificationDate else {
            throw KaitoError.malformed(
                "RAR5 split file metadata changes between volumes"
            )
        }
        guard splitEncryptionParametersMatch(
                  first.extras.encryption,
                  continuation.extras.encryption
              ),
              first.extras.creationDate == continuation.extras.creationDate,
              first.extras.accessDate == continuation.extras.accessDate,
              first.extras.version == continuation.extras.version,
              first.extras.redirection == continuation.extras.redirection,
              first.extras.ownerName == continuation.extras.ownerName,
              first.extras.groupName == continuation.extras.groupName,
              first.extras.ownerID == continuation.extras.ownerID,
              first.extras.groupID == continuation.extras.groupID else {
            throw KaitoError.malformed(
                "RAR5 split file extra metadata changes between volumes"
            )
        }

        let unpackedSize: UInt64?
        switch (first.unpackedSize, continuation.unpackedSize) {
        case let (lhs?, rhs?):
            guard lhs == rhs else {
                throw KaitoError.malformed(
                    "RAR5 split file unpacked size changes between volumes"
                )
            }
            unpackedSize = lhs
        case let (lhs?, nil):
            unpackedSize = lhs
        case let (nil, rhs?):
            unpackedSize = rhs
        case (nil, nil):
            unpackedSize = nil
        }

        let segmentCount = try Checked.add(
            UInt64(first.packedSegments.count),
            UInt64(continuation.packedSegments.count)
        )
        guard segmentCount <= 65_536 else {
            throw KaitoError.limitExceeded("RAR5 split stream has too many segments")
        }
        let packedSize = try Checked.add(first.packedSize, continuation.packedSize)
        var extras = first.extras
        // Non-final parts authenticate their packed slice. Only the final part's
        // hash, CRC, and checksum-MAC flag describe the unpacked logical file
        // published to callers. RAR may add flag 0x0002 only in that final
        // encryption record while retaining one salt, IV, key, and CBC stream.
        extras.encryption = continuation.extras.encryption
        extras.hash = continuation.extras.hash

        return RAR5PendingEntry(
            rawName: first.rawName,
            name: first.name,
            pathComponents: first.pathComponents,
            kind: first.kind,
            unpackedSize: unpackedSize,
            packedSize: packedSize,
            modificationDate: first.modificationDate,
            permissions: first.permissions,
            crc32: continuation.crc32,
            compression: first.compression,
            firstHeaderFlags: first.firstHeaderFlags,
            lastHeaderFlags: continuation.lastHeaderFlags,
            packedSegments: first.packedSegments + continuation.packedSegments,
            packedPartIntegrity: first.packedPartIntegrity
                + continuation.packedPartIntegrity,
            firstVolumeNumber: first.firstVolumeNumber,
            lastVolumeNumber: continuation.lastVolumeNumber,
            attributes: first.attributes,
            hostOS: first.hostOS,
            extras: extras
        )
    }

    /// Split headers repeat the file-encryption parameters, but flag 0x0002 is
    /// local to the checksum/hash stored in that header. In particular, RAR
    /// sets it for the final unpacked-file digest while earlier headers carry
    /// an untweaked digest of their packed ciphertext range.
    private static func splitEncryptionParametersMatch(
        _ first: RAR5EncryptionRecord?,
        _ continuation: RAR5EncryptionRecord?
    ) -> Bool {
        switch (first, continuation) {
        case (nil, nil):
            return true
        case let (first?, continuation?):
            return first.version == continuation.version
                && (first.flags ^ continuation.flags) & ~UInt64(0x0002) == 0
                && first.kdfCount == continuation.kdfCount
                && first.salt == continuation.salt
                && first.initializationVector == continuation.initializationVector
                && first.checkValue == continuation.checkValue
        default:
            return false
        }
    }

    private static func publish(
        _ pending: [RAR5PendingEntry],
        archiveFlags: RAR5ArchiveFlags,
        recoverDamagedArchives: Bool
    ) throws -> (entries: [ArchiveEntry], records: [RAR5EntryRecord]) {
        var solidGroups = [Int](repeating: -1, count: pending.count)
        if archiveFlags.contains(RAR5ArchiveFlags.solid) {
            var previousFileIndex: Int?
            for index in pending.indices {
                try checkCancellation(every: index)
                guard pending[index].kind != .directory
                    && !RAR5RedirectionType.isZeroBody(pending[index].extras.redirection?.type) else { continue }
                if pending[index].compression.isSolid {
                    guard let predecessor = previousFileIndex else {
                        throw KaitoError.malformed(
                            "first RAR5 file cannot continue a solid stream"
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
        } else if pending.contains(where: {
            $0.kind != .directory
                && !RAR5RedirectionType.isZeroBody($0.extras.redirection?.type)
                && $0.compression.isSolid
        }) {
            throw KaitoError.malformed("RAR5 solid file is not in a solid archive")
        }

        var entries: [ArchiveEntry] = []
        var records: [RAR5EntryRecord] = []
        var lastEntryByNormalizedPath: [String: Int] = [:]
        entries.reserveCapacity(pending.count)
        records.reserveCapacity(pending.count)

        for (index, item) in pending.enumerated() {
            try checkCancellation(every: index)
            let zeroBodyRedirection = RAR5RedirectionType.isZeroBody(
                item.extras.redirection?.type
            )
            // A file copy (type 5) is published as a `.file` of its target's size
            // only when the target resolves to an earlier regular file; otherwise
            // it stays a zero-body `.other`.
            var fileCopyTarget: (index: Int, entry: ArchiveEntry)?
            if let redirection = item.extras.redirection, redirection.type == RAR5RedirectionType.fileCopy,
               let normalizedTarget = normalizedExtractionPath(redirection.target),
               let targetIndex = lastEntryByNormalizedPath[normalizedTarget],
               entries.indices.contains(targetIndex),
               entries[targetIndex].kind == .file,
               entries[targetIndex].formatSpecific["fileCopyTargetIndex"] == nil,
               entries[targetIndex].uncompressedSize == item.unpackedSize {
                fileCopyTarget = (targetIndex, entries[targetIndex])
            }
            let publishedUnpackedSize: UInt64? = fileCopyTarget != nil
                ? item.unpackedSize
                : (zeroBodyRedirection ? 0 : item.unpackedSize)
            let publishedPackedSize = zeroBodyRedirection ? 0 : item.packedSize
            var specific: [String: String] = [
                "rarVersion": item.compression.version == 0 ? "5" : "7",
                "compressionInfo": "0x" + String(item.compression.rawValue, radix: 16),
                "method": String(item.compression.method),
                "dictionarySize": String(item.compression.dictionarySize),
                "hostOS": String(item.hostOS),
                "attributes": "0x" + String(item.attributes, radix: 16),
                "solid": item.compression.isSolid ? "true" : "false",
                "splitBefore": item.splitBefore ? "true" : "false",
                "splitAfter": item.splitAfter ? "true" : "false",
                "multiVolume": item.isMultiVolume ? "true" : "false",
                "volumeSegmentCount": String(item.packedSegments.count),
                "unpackedSizeUnknown": item.unpackedSize == nil ? "true" : "false",
                "encryption": item.extras.encryption == nil ? "none" : "RAR5 AES-256",
            ]
            if let hash = item.extras.hash {
                specific["hashType"] = hash.type == 0 ? "BLAKE2sp" : String(hash.type)
                specific["hash"] = hash.digest.map {
                    let digits = String($0, radix: 16)
                    return $0 < 16 ? "0" + digits : digits
                }.joined()
            }
            if let version = item.extras.version { specific["fileVersion"] = String(version) }
            if let redirection = item.extras.redirection {
                specific["linkPath"] = redirection.target
                specific["redirectionType"] = String(redirection.type)
                specific["redirectionTargetIsDirectory"] = redirection.flags & 1 != 0 ? "true" : "false"
                if redirection.type == RAR5RedirectionType.hardLink,
                   let normalizedTarget = normalizedExtractionPath(redirection.target),
                   let targetIndex = lastEntryByNormalizedPath[normalizedTarget],
                   entries.indices.contains(targetIndex) {
                    let target = entries[targetIndex]
                    if target.kind == .file ||
                        (target.kind == .hardlink &&
                            target.formatSpecific["hardLinkTargetIndex"] != nil) {
                        specific["hardLinkTargetIndex"] = String(targetIndex)
                    }
                }
                if let fileCopyTarget {
                    specific["fileCopyTargetIndex"] = String(fileCopyTarget.index)
                }
            } else if item.kind == .symlink {
                specific["linkTargetStoredAsData"] = "true"
            }
            if let date = item.extras.creationDate {
                specific["creationTime"] = String(date.timeIntervalSince1970)
            }
            if let date = item.extras.accessDate {
                specific["accessTime"] = String(date.timeIntervalSince1970)
            }
            if let owner = item.extras.ownerName { specific["owner"] = owner }
            if let group = item.extras.groupName { specific["group"] = group }
            if let ownerID = item.extras.ownerID { specific["uid"] = String(ownerID) }
            if let groupID = item.extras.groupID { specific["gid"] = String(groupID) }

            let methodDescription: String
            if fileCopyTarget != nil {
                methodDescription = "RAR5 file copy"
            } else if item.compression.method == 0 {
                methodDescription = "RAR5 stored"
            } else {
                methodDescription = "RAR5 method \(item.compression.method)"
            }
            let entry = ArchiveEntry(
                index: index,
                rawName: RawName(
                    bytes: item.rawName,
                    declaredEncoding: .utf8,
                    isDirectoryHint: item.kind == .directory
                ),
                name: item.name,
                pathComponents: item.pathComponents,
                kind: fileCopyTarget != nil ? .file : item.kind,
                uncompressedSize: publishedUnpackedSize,
                compressedSize: publishedPackedSize,
                modificationDate: item.modificationDate,
                posixPermissions: item.permissions,
                // A file copy reads its target's body, so encryption and solid
                // group follow the target.
                isEncrypted: fileCopyTarget?.entry.isEncrypted
                    ?? (!zeroBodyRedirection && item.extras.encryption != nil),
                solidGroup: fileCopyTarget?.entry.solidGroup ?? solidGroups[index],
                crc32: zeroBodyRedirection ? nil : item.crc32,
                methodDescription: methodDescription,
                formatSpecific: specific,
                isIncomplete: recoverDamagedArchives && item.isIncomplete
            )
            entries.append(entry)
            if let normalizedName = normalizedExtractionPath(item.name) {
                // Resolve hard links before insertion so targets are always
                // earlier archive members and cannot form forward cycles.
                lastEntryByNormalizedPath[normalizedName] = entry.index
            }
            records.append(RAR5EntryRecord(
                packedSegments: zeroBodyRedirection ? [] : item.packedSegments,
                packedPartIntegrity: zeroBodyRedirection
                    ? []
                    : item.packedPartIntegrity,
                packedSize: publishedPackedSize,
                availablePackedSize: item.availablePackedSize,
                isIncomplete: recoverDamagedArchives && item.isIncomplete,
                unpackedSize: publishedUnpackedSize,
                compression: item.compression,
                encryption: item.extras.encryption,
                hash: item.extras.hash,
                redirectionType: item.extras.redirection?.type,
                requiresPreviousVolume: !zeroBodyRedirection && item.splitBefore,
                requiresNextVolume: !zeroBodyRedirection && item.splitAfter
            ))
        }
        return (entries, records)
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
}
