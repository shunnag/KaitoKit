import Foundation

// Provenance: bitplane/rar-research's RAR13_FORMAT_SPECIFICATION.md and
// UNRAR 7.23 black-box archives. No third-party decoder source was used.
final class RAR13Reader: FormatReader {
    static let signature: [UInt8] = [0x52, 0x45, 0x7e, 0x5e]

    private struct Record {
        let dataOffset: UInt64
        let packedSize: UInt64
        let unpackedSize: UInt64
        let checksum: UInt16
        let method: UInt8
        let unpackVersion: UInt8
        let flags: UInt8
        let isSolid: Bool
        let kind: EntryKind
        let modificationDate: Date?
        let attributes: UInt8
        let comment: [UInt8]

        var isEncrypted: Bool { flags & 0x04 != 0 }
        var hasComment: Bool { flags & 0x08 != 0 }
        var isSplit: Bool { flags & 0x03 != 0 }
    }

    let format: ArchiveFormat = .rar
    let entries: [ArchiveEntry]
    let nameEncoding: String.Encoding?
    private let source: any ByteSource
    private let records: [Record]
    private let solidGroupMembers: [Int: [Int]]
    private let archiveCommentBytes: [UInt8]?
    private var password: String?
    private var solidCoordinators: [Int: RARSolidCoordinator<RAR15Decoder.SolidState>] = [:]
    private var activeSolidGroup: Int?

    var resolvedPassword: String? { password }

    static func hasSignature(source: any ByteSource) throws -> Bool {
        guard source.length >= 4 else { return false }
        return try readByteRange(source: source, offset: 0, count: 4) == signature
    }

    init(source: any ByteSource, options: ReaderOptions) throws {
        self.source = source
        password = options.password
        let limits = options.limits
        guard try Self.hasSignature(source: source) else { throw KaitoError.unsupportedFormat }
        guard source.length >= 7 else { throw KaitoError.truncated }
        let main = try readByteRange(source: source, offset: 0, count: 7)
        let mainSize = Int(LittleEndian.uint16(main, at: 4))
        guard mainSize >= 7 else { throw KaitoError.malformed("RAR1.3 main header size") }
        guard UInt64(mainSize) <= source.length else { throw KaitoError.truncated }
        let mainFlags = main[6]
        archiveCommentBytes = try Self.readArchiveComment(
            source: source, mainSize: mainSize, flags: mainFlags, limits: limits
        )
        var offset = UInt64(mainSize)
        var metadata = UInt64(mainSize)
        try Checked.size(metadata, limit: limits.maxTotalMetadataSize)

        var records: [Record] = []
        var rawNames: [[UInt8]] = []
        var solidGroups: [Int] = []
        var previousFileIndex: Int?
        while offset < source.length {
            try checkCancellation(every: records.count)
            guard source.length - offset >= 21 else { throw KaitoError.truncated }
            let fixed = try readByteRange(source: source, offset: offset, count: 21)
            let headSize = Int(LittleEndian.uint16(fixed, at: 10))
            let nameSize = Int(fixed[19])
            guard headSize >= 21 + nameSize, nameSize > 0 else {
                throw KaitoError.malformed("RAR1.3 file header size")
            }
            let rawVersion = fixed[18]
            guard (1...20).contains(rawVersion), fixed[20] <= 7 else {
                throw KaitoError.malformed("RAR1.3 file header version or method")
            }
            let header = try readByteRange(source: source, offset: offset, count: headSize)
            let rawName = Array(header[21..<(21 + nameSize)])
            let packedSize = UInt64(LittleEndian.uint32(header, at: 0))
            let unpackedSize = UInt64(LittleEndian.uint32(header, at: 4))
            let dataOffset = try Checked.add(offset, UInt64(headSize))
            let end = try Checked.add(dataOffset, packedSize)
            guard end <= source.length else { throw KaitoError.truncated }
            metadata = try Checked.add(metadata, UInt64(headSize))
            try Checked.size(metadata, limit: limits.maxTotalMetadataSize)
            guard records.count < limits.maxEntryCount else {
                throw KaitoError.limitExceeded("RAR1.3 entry count")
            }

            let flags = header[17]
            let comment: [UInt8]
            if flags & 0x08 != 0 {
                let start = 21 + nameSize
                guard header.count >= start + 2 else {
                    throw KaitoError.malformed("RAR1.3 file comment header")
                }
                let length = Int(LittleEndian.uint16(header, at: start))
                guard start + 2 + length == header.count else {
                    throw KaitoError.malformed("RAR1.3 file comment length")
                }
                comment = Array(header[(start + 2)...])
            } else {
                comment = []
            }
            let kind: EntryKind = header[16] & 0x10 != 0 ? .directory : .file
            if kind == .directory, packedSize != 0 || unpackedSize != 0 {
                throw KaitoError.malformed("RAR1.3 directory contains data")
            }
            let method = header[20]
            let requestsSolidContinuation = kind == .file && method != 0 &&
                (mainFlags & 0x08 != 0 || flags & 0x10 != 0)
            let isSolid = requestsSolidContinuation && previousFileIndex != nil
            if kind == .file, method != 0 {
                if requestsSolidContinuation {
                    guard mainFlags & 0x08 != 0 else {
                        throw KaitoError.malformed("RAR1.3 solid file is not in a solid archive")
                    }
                    if flags & 0x10 != 0 || previousFileIndex != nil {
                        guard let predecessor = previousFileIndex else {
                            throw KaitoError.malformed("RAR1.3 first file cannot continue a solid stream")
                        }
                        let group = solidGroups[predecessor] >= 0 ? solidGroups[predecessor] : predecessor
                        solidGroups[predecessor] = group
                        solidGroups.append(group)
                    } else {
                        solidGroups.append(-1)
                    }
                } else {
                    solidGroups.append(-1)
                }
                previousFileIndex = records.count
            } else {
                solidGroups.append(-1)
            }
            records.append(Record(
                dataOffset: dataOffset, packedSize: packedSize, unpackedSize: unpackedSize,
                checksum: LittleEndian.uint16(header, at: 8), method: method,
                unpackVersion: rawVersion, flags: flags, isSolid: isSolid, kind: kind,
                modificationDate: ARJReader.dosDate(LittleEndian.uint32(header, at: 12)),
                attributes: header[16], comment: comment
            ))
            rawNames.append(rawName)
            offset = end
        }

        let batchLimit = try Checked.toInt(min(limits.maxMetadataSize, UInt64(Int.max)))
        let archiveEncoding = EncodingDetector.detectArchiveEncoding(
            names: rawNames, policy: options.encodingPolicy,
            fromWindows: true, maximumBatchByteCount: batchLimit
        )
        nameEncoding = archiveEncoding
        var entries: [ArchiveEntry] = []
        entries.reserveCapacity(records.count)
        for (index, record) in records.enumerated() {
            try checkCancellation(every: index)
            let decoded = EncodingDetector.resolveUndeclaredName(
                bytes: rawNames[index], policy: options.encodingPolicy,
                archiveEncoding: archiveEncoding, fromWindows: true
            ).string
            let name = decoded.replacingOccurrences(of: "\\", with: "/")
            guard !name.isEmpty, !name.utf8.contains(0) else {
                throw KaitoError.malformed("RAR1.3 entry name cannot be decoded safely")
            }
            let components = name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !components.isEmpty, components.count <= limits.maxPathComponentCount,
                  !components.contains(where: { $0 == "." || $0 == ".." }) else {
                throw KaitoError.malformed("RAR1.3 entry path")
            }
            let isDirectory = record.kind == .directory
            let permissions: UInt16? = isDirectory ? 0o755 : (record.attributes & 1 != 0 ? 0o444 : 0o644)
            var specific = [
                "container": "RAR1.3",
                "unpackVersion": String(record.unpackVersion),
                "crc16": String(format: "%04x", record.checksum),
            ]
            if let archiveCommentBytes {
                specific["archiveComment"] = EncodingDetector.resolveUndeclaredName(
                    bytes: archiveCommentBytes, policy: options.encodingPolicy,
                    archiveEncoding: archiveEncoding, fromWindows: true
                ).string
            }
            if record.hasComment {
                specific["comment"] = EncodingDetector.resolveUndeclaredName(
                    bytes: record.comment, policy: options.encodingPolicy,
                    archiveEncoding: archiveEncoding, fromWindows: true
                ).string
            }
            entries.append(ArchiveEntry(
                index: index,
                rawName: RawName(bytes: rawNames[index], declaredEncoding: nil, isDirectoryHint: isDirectory),
                name: name, pathComponents: components, kind: record.kind,
                uncompressedSize: isDirectory ? 0 : record.unpackedSize,
                compressedSize: isDirectory ? 0 : record.packedSize,
                modificationDate: record.modificationDate, posixPermissions: permissions,
                isEncrypted: record.isEncrypted, solidGroup: solidGroups[index], crc32: nil,
                methodDescription: record.method == 0 ? "RAR1.3 stored" : "RAR1.3 normal",
                formatSpecific: specific
            ))
        }
        self.entries = entries
        self.records = records
        var groups: [Int: [Int]] = [:]
        for entry in entries where entry.solidGroup >= 0 {
            groups[entry.solidGroup, default: []].append(entry.index)
        }
        solidGroupMembers = groups
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        try recordIndex(of: entry, label: "RAR1.3")
        let record = records[entry.index]
        if record.kind == .directory {
            return try EntryStream.empty(entryIndex: entry.index, limits: limits)
        }
        if entry.solidGroup >= 0, record.method != 0 {
            return try streamSolidEntry(entry, group: entry.solidGroup, limits: limits)
        }
        return try Self.makeVerifiedStream(
            source: source, entry: entry, record: record, limits: limits, state: nil,
            password: password
        )
    }

    private func streamSolidEntry(
        _ entry: ArchiveEntry,
        group: Int,
        limits: ReadLimits
    ) throws -> EntryStream {
        if let activeSolidGroup, activeSolidGroup != group {
            solidCoordinators[activeSolidGroup]?.invalidateAndRelease()
        }
        activeSolidGroup = group
        let coordinator: RARSolidCoordinator<RAR15Decoder.SolidState>
        if let existing = solidCoordinators[group] {
            coordinator = existing
        } else {
            guard let indices = solidGroupMembers[group], !indices.isEmpty,
                  indices.first == group, indices.contains(entry.index) else {
                throw KaitoError.malformed("RAR1.3 solid group membership is inconsistent")
            }
            for index in indices {
                let record = records[index]
                guard record.method != 0, record.unpackVersion == 2, !record.isSplit else {
                    throw KaitoError.unsupportedMethod("RAR1.3 unsupported solid stream member")
                }
            }
            let capturedSource = source
            let capturedEntries = entries
            let capturedRecords = records
            let capturedPassword = password
            coordinator = RARSolidCoordinator<RAR15Decoder.SolidState>(
                formatLabel: "RAR1.3", entryIndices: indices,
                dictionarySize: UInt64(RAR15Decoder.windowSize), limits: limits
            ) { index, state in
                guard capturedEntries.indices.contains(index), capturedRecords.indices.contains(index) else {
                    throw KaitoError.malformed("RAR1.3 solid coordinator references an invalid entry")
                }
                return try Self.makeVerifiedStream(
                    source: capturedSource, entry: capturedEntries[index], record: capturedRecords[index],
                    limits: limits, state: state, password: capturedPassword
                )
            }
            solidCoordinators[group] = coordinator
        }
        let range = try coordinator.stream(entryIndex: entry.index, unpackedSize: records[entry.index].unpackedSize)
        return try EntryStream(
            decompressor: range, length: records[entry.index].unpackedSize,
            expectedCRC32: nil, entryIndex: entry.index, limits: limits
        )
    }

    private static func readArchiveComment(
        source: any ByteSource,
        mainSize: Int,
        flags: UInt8,
        limits: ReadLimits
    ) throws -> [UInt8]? {
        guard flags & 0x02 != 0 else { return nil }
        let extensionBytes = try readByteRange(source: source, offset: 7, count: mainSize - 7)
        guard extensionBytes.count >= 2 else { throw KaitoError.malformed("RAR1.3 archive comment header") }
        let length = Int(LittleEndian.uint16(extensionBytes, at: 0))
        if flags & 0x10 == 0 {
            guard 2 + length <= extensionBytes.count else {
                throw KaitoError.malformed("RAR1.3 archive comment length")
            }
            return Array(extensionBytes[2..<(2 + length)])
        }
        guard length >= 2, extensionBytes.count >= 4 else {
            throw KaitoError.malformed("RAR1.3 packed comment header")
        }
        let unpackedSize = UInt64(LittleEndian.uint16(extensionBytes, at: 2))
        let packedEnd = 2 + length
        guard packedEnd <= extensionBytes.count else {
            throw KaitoError.malformed("RAR1.3 packed comment length")
        }
        let decrypted = RAR13LegacyCipher.decryptComment(Array(extensionBytes[4..<packedEnd]))
        try Checked.size(unpackedSize, limit: limits.maxEntrySize)
        let decoder = try RAR15Decoder(
            source: DataByteSource(data: Data(decrypted)), offset: 0,
            compressedSize: UInt64(decrypted.count), expectedSize: unpackedSize,
            unpackVersion: 15, method: 0x33,
            dictionarySize: UInt64(RAR15Decoder.windowSize),
            isSolid: false, limits: limits
        )
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: max(1, Int(min(unpackedSize, 64 * 1_024))))
        while output.count < unpackedSize {
            let count = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
            guard count > 0 else { throw KaitoError.truncated }
            output.append(buffer, count: count)
        }
        guard decoder.isFinished else { throw KaitoError.truncated }
        return Array(output)
    }

    private static func makeVerifiedStream(
        source: any ByteSource,
        entry: ArchiveEntry,
        record: Record,
        limits: ReadLimits,
        state: RAR15Decoder.SolidState?,
        password: String?
    ) throws -> EntryStream {
        guard !record.isSplit else { throw KaitoError.unsupportedMethod("RAR1.3 multi-volume file") }
        do {
            let payloadSource: any ByteSource
            let payloadOffset: UInt64
            if record.isEncrypted {
                guard let password else { throw KaitoError.passwordRequired }
                payloadSource = try RAR13EncryptedByteSource(
                    source: source, offset: record.dataOffset,
                    length: record.packedSize, password: password
                )
                payloadOffset = 0
            } else {
                payloadSource = source
                payloadOffset = record.dataOffset
            }
            let base: any Decompressor
            if record.method == 0 {
                guard record.packedSize == record.unpackedSize else {
                    throw KaitoError.malformed("RAR1.3 stored entry has unequal sizes")
                }
                base = try CopyDecompressor(
                    source: payloadSource, offset: payloadOffset, compressedSize: record.packedSize
                )
            } else {
                guard record.unpackVersion == 2 else {
                    throw KaitoError.unsupportedMethod("RAR1.3 unpack version \(record.unpackVersion)")
                }
                base = try RAR15Decoder(
                    source: payloadSource, offset: payloadOffset,
                    compressedSize: record.packedSize, expectedSize: record.unpackedSize,
                    unpackVersion: 13, method: record.method + 0x30,
                    dictionarySize: UInt64(RAR15Decoder.windowSize),
                    isSolid: record.isSolid, limits: limits, solidState: state
                )
            }
            let protected: any Decompressor = record.isEncrypted
                ? RARPasswordAmbiguousDecompressor(base: base, expectedSize: record.unpackedSize)
                : base
            let verified = RAR13ChecksumDecompressor(
                base: protected, expectedSize: record.unpackedSize,
                expectedChecksum: record.checksum, entryIndex: entry.index,
                mismatchIsWrongPassword: record.isEncrypted
            )
            return try EntryStream(
                decompressor: verified, length: record.unpackedSize,
                expectedCRC32: nil, entryIndex: entry.index, limits: limits,
                checksumMismatchIsWrongPassword: record.isEncrypted
            )
        } catch {
            guard record.isEncrypted else { throw error }
            try RARPasswordAmbiguousDecompressor.rethrowNormalized(error)
        }
    }

    func setPassword(_ password: String?) {
        guard self.password != password else { return }
        self.password = password
        for coordinator in solidCoordinators.values {
            coordinator.invalidateAndRelease()
        }
        solidCoordinators.removeAll(keepingCapacity: false)
        activeSolidGroup = nil
    }
}

private final class RAR13ChecksumDecompressor: Decompressor {
    private let base: any Decompressor
    private let expectedSize: UInt64
    private let expectedChecksum: UInt16
    private let entryIndex: Int
    private let mismatchIsWrongPassword: Bool
    private var produced: UInt64 = 0
    private var checksum: UInt32 = 0
    private var finished = false
    private var terminalError: (any Error)?

    var isFinished: Bool { finished && terminalError == nil }

    init(
        base: any Decompressor,
        expectedSize: UInt64,
        expectedChecksum: UInt16,
        entryIndex: Int,
        mismatchIsWrongPassword: Bool = false
    ) {
        self.base = base
        self.expectedSize = expectedSize
        self.expectedChecksum = expectedChecksum
        self.entryIndex = entryIndex
        self.mismatchIsWrongPassword = mismatchIsWrongPassword
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if let terminalError { throw terminalError }
        guard !finished, !buffer.isEmpty else { return 0 }
        do {
            let requested = Int(min(UInt64(buffer.count), expectedSize - produced))
            if requested == 0 {
                finished = true
                try verify()
                return 0
            }
            let count = try base.read(into: UnsafeMutableRawBufferPointer(rebasing: buffer.prefix(requested)))
            guard count > 0, count <= requested else { throw KaitoError.truncated }
            for byte in buffer.prefix(count) {
                checksum = (checksum + UInt32(byte)) & 0xffff
                checksum = ((checksum << 1) | (checksum >> 15)) & 0xffff
            }
            produced += UInt64(count)
            if produced == expectedSize {
                finished = true
                try verify()
            }
            return count
        } catch {
            terminalError = error
            throw error
        }
    }

    private func verify() throws {
        guard produced == expectedSize, base.isFinished else {
            throw KaitoError.malformed("RAR1.3 decoder did not finish")
        }
        guard checksum == UInt32(expectedChecksum) else {
            if mismatchIsWrongPassword { throw KaitoError.wrongPassword }
            throw KaitoError.checksumMismatch(entry: entryIndex)
        }
    }
}
