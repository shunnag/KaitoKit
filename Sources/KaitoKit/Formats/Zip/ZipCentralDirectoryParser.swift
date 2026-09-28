import Foundation

// 中央ディレクトリの byte 列から公開 entry と読取用の record を作る。APPNOTE §4.3.12。
// 位置は ZipCentralDirectoryLocator（通常の open）か ZipLocalHeaderRecovery（復旧）が決め、
// どちらの経路もここで同じ名前・暗号・上限の検証を通す。

/// entry の暗号方式。AES は検証済みの 0x9901 extra を持つ。
enum ZipEntryEncryption: Sendable {
    case none
    case traditional
    case aes(WinZipAESMetadata)
}

/// 中央ディレクトリから得た、local header の検証と展開に使う値。
/// 復旧した entry では `availableCompressedSize` が source に実在する本文の大きさを示す。
struct ZipEntryRecord: Sendable {
    let localHeaderOffset: UInt64
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let crc32: UInt32?
    let storedCRC32: UInt32
    let flags: UInt16
    let method: UInt16
    let headerMethod: UInt16
    let encryption: ZipEntryEncryption
    let usesZIP64: Bool
    var availableCompressedSize: UInt64? = nil
    var hasKnownCompressedSize = true
}

/// 中央ディレクトリの位置。`archiveBase` は書庫内の相対 offset を絶対位置へ直す基準（SFX の前置きの長さ）で、
/// 分割巻では 0 のまま `diskLayout` が巻ごとに変換する。
struct ZipDirectoryLocation {
    let archiveBase: UInt64
    let offset: UInt64
    let size: UInt64
    let entryCount: Int
    var diskLayout: ZipDiskLayout? = nil
}

/// 解析済みの中央ディレクトリ。
struct ZipParsedDirectory {
    let location: ZipDirectoryLocation
    let entries: [ArchiveEntry]
    let records: [ZipEntryRecord]
    let nameEncoding: String.Encoding?
}

enum ZipCentralDirectoryParser {
    /// 書庫全体で推定した名前の符号化と、推定に参加した名前の復号結果（出現順）。
    private struct ArchiveNames {
        let encoding: String.Encoding?
        let decoded: [String?]
    }

    /// 中央 header の固定部と、名前・extra。comment は読み飛ばす。
    private struct CentralHeader {
        let versionMadeBy: UInt16
        let flags: UInt16
        let headerMethod: UInt16
        let dosTime: UInt16
        let dosDate: UInt16
        let storedCRC: UInt32
        let compressed32: UInt32
        let uncompressed32: UInt32
        let diskStart16: UInt16
        let externalAttributes: UInt32
        let localOffset32: UInt32
        let rawName: [UInt8]
        let extra: [UInt8]

        /// versionMadeBy の上位 byte。0 は MS-DOS / Windows。
        var hostOS: UInt8 { UInt8(truncatingIfNeeded: versionMadeBy >> 8) }
        var hasUTF8Names: Bool { flags & ZipGeneralPurposeFlag.utf8Names != 0 }
    }

    /// formatSpecific の辞書を CD 解析ごとに 8 枠の FIFO で共有する（COW）。
    /// key は実方式・versionMadeBy・flags・暗号種別・AES 強度・symlink の有無。
    private struct FormatSpecificCache {
        private static let capacity = 8
        private var slots: [(key: UInt64, value: [String: String])] = []
        private var nextReplacement = 0

        init() {
            slots.reserveCapacity(Self.capacity)
        }

        mutating func value(
            method: UInt16,
            versionMadeBy: UInt16,
            flags: UInt16,
            encryption: ZipEntryEncryption,
            isSymbolicLink: Bool
        ) -> [String: String] {
            let encryptionKey: UInt64
            switch encryption {
            case .none: encryptionKey = 0
            case .traditional: encryptionKey = 1 << 48
            case let .aes(metadata):
                encryptionKey = (2 << 48) | (UInt64(metadata.strength.rawValue) << 50)
            }
            let key = UInt64(method) | UInt64(versionMadeBy) << 16 | UInt64(flags) << 32
                | encryptionKey | (isSymbolicLink ? UInt64(1) << 58 : 0)
            if let cached = slots.first(where: { $0.key == key }) {
                return cached.value
            }
            let encryptionDescription: String
            switch encryption {
            case .none: encryptionDescription = "none"
            case .traditional: encryptionDescription = "ZipCrypto"
            case let .aes(metadata):
                encryptionDescription = "AES-\(metadata.strength.keyLength * 8)"
            }
            var value: [String: String] = [
                "method": String(method),
                "versionMadeBy": String(versionMadeBy),
                "flags": ZipCentralDirectoryParser.flagsDescription(flags),
                "hostOS": String(UInt8(truncatingIfNeeded: versionMadeBy >> 8)),
                "encryption": encryptionDescription,
            ]
            if isSymbolicLink {
                value["linkTargetStoredAsData"] = "true"
            }
            if slots.count < Self.capacity {
                slots.append((key, value))
            } else {
                slots[nextReplacement] = (key, value)
                nextReplacement = (nextReplacement + 1) % Self.capacity
            }
            return value
        }
    }

    /// `recoveredBytes` は ZipLocalHeaderRecovery が組み直した中央 header 列。nil なら source の `location` を読む。
    /// `recovery` は復旧時だけ entry と同じ順で渡し、local header の位置と本文の実在範囲を与える。
    static func parse(
        source: any ByteSource,
        location: ZipDirectoryLocation,
        policy: EncodingPolicy,
        limits: ReadLimits,
        recoveredBytes: [UInt8]? = nil,
        recovery: [ZipRecoveryExtent] = []
    ) throws -> ZipParsedDirectory {
        let bytes = try recoveredBytes ?? readByteRange(
            source: source,
            offset: location.offset,
            count: try Checked.toInt(location.size)
        )
        // 固定部だけでも一件 46 バイト必要。偽の巨大 count で reserveCapacity を
        // 先に膨らませず、中央ディレクトリとの整合性を確保してから配列を予約する。
        guard location.entryCount <= bytes.count / ZipRecordSize.centralHeader else {
            throw KaitoError.malformed(
                "ZIP central-directory entry count exceeds its data"
            )
        }
        let minimumRetainedMetadata = try Checked.mul(
            UInt64(location.entryCount),
            256
        )
        try Checked.size(
            minimumRetainedMetadata,
            limit: limits.maxTotalMetadataSize
        )
        let archiveNames = try archiveNames(
            in: bytes,
            entryCount: location.entryCount,
            policy: policy,
            recordLimit: limits.maxMetadataRecordCount
        )
        var cursor = ZipByteCursor(bytes)
        var entries: [ArchiveEntry] = []
        var records: [ZipEntryRecord] = []
        entries.reserveCapacity(location.entryCount)
        records.reserveCapacity(location.entryCount)
        var retainedMetadataSize: UInt64 = 0
        var archiveNameIndex = 0
        var dosTimestampDecoder = DOSTimestampDecoder()
        var pathSplitter = PathComponentSplitter()
        var specificCache = FormatSpecificCache()

        for index in 0..<location.entryCount {
            try checkCancellation(every: index)
            let header = try readCentralHeader(&cursor)
            let extraFields = try ZipExtraFields.parse(
                header.extra,
                recordLimit: limits.maxMetadataRecordCount,
                tailPolicy: .ignoreUnparsableTail
            )
            let zip64 = try ZipExtraFields.resolveZIP64Values(
                compressed32: header.compressed32,
                uncompressed32: header.uncompressed32,
                localOffset32: header.localOffset32,
                diskStart16: header.diskStart16,
                fields: extraFields
            )
            guard location.diskLayout != nil || zip64.diskStart == 0 else {
                throw KaitoError.unsupportedMethod("spanned")
            }
            try Checked.size(zip64.compressedSize, limit: limits.maxEntrySize)
            try Checked.size(zip64.uncompressedSize, limit: limits.maxEntrySize)

            let extent = recovery.isEmpty ? nil : recovery[index]
            // 並べ替えと非重複検証にも同じ絶対位置を使うため、索引作成時に解決する。
            let absoluteLocalOffset = try extent?.headerOffset
                ?? location.diskLayout?.absoluteOffset(disk: UInt64(zip64.diskStart), relative: zip64.localHeaderOffset)
                ?? Checked.add(location.archiveBase, zip64.localHeaderOffset)
            guard absoluteLocalOffset < location.offset else {
                throw KaitoError.malformed("ZIP local header overlaps the central directory")
            }

            let (encryption, method, expectedCRC) = try classifyEncryption(header, extraFields: extraFields)
            let name = try resolveName(
                header,
                extraFields: extraFields,
                archiveNames: archiveNames,
                archiveNameIndex: &archiveNameIndex,
                policy: policy
            )
            let pathComponents = pathSplitter.split(name)
            guard pathComponents.count <= limits.maxPathComponentCount else {
                throw KaitoError.limitExceeded("ZIP path component count")
            }

            let unixMode = UInt16(truncatingIfNeeded: header.externalAttributes >> 16)
            let isSymbolicLink = unixMode & 0o170000 == 0o120000
            let dosDirectory = header.externalAttributes & 0x10 != 0 && zip64.uncompressedSize == 0
            let kind: EntryKind
            if isSymbolicLink {
                kind = .symlink
            } else if name.hasSuffix("/") || dosDirectory {
                kind = .directory
            } else {
                kind = .file
            }
            let permissions: UInt16? = unixMode == 0 ? nil : unixMode & 0o7777
            let modificationDate = try? ZipExtraFields.modificationDate(
                fields: extraFields,
                dosDate: header.dosDate,
                dosTime: header.dosTime,
                dosTimestampDecoder: &dosTimestampDecoder
            )
            let methodName = methodDescription(method)
            let specific = specificCache.value(
                method: method,
                versionMadeBy: header.versionMadeBy,
                flags: header.flags,
                encryption: encryption,
                isSymbolicLink: isSymbolicLink
            )

            let metadataCost = try retainedMetadataCost(
                rawName: header.rawName,
                name: name,
                components: pathComponents,
                specific: specific
            )
            retainedMetadataSize = try Checked.add(retainedMetadataSize, metadataCost)
            try Checked.size(retainedMetadataSize, limit: limits.maxTotalMetadataSize)

            let entry = ArchiveEntry(
                index: index,
                rawName: RawName(
                    bytes: header.rawName,
                    declaredEncoding: header.hasUTF8Names ? .utf8 : nil,
                    isDirectoryHint: kind == .directory
                ),
                name: name,
                pathComponents: pathComponents,
                kind: kind,
                uncompressedSize: extent?.unknownSize == true ? nil : zip64.uncompressedSize,
                compressedSize: extent?.unknownSize == true ? nil : zip64.compressedSize,
                modificationDate: modificationDate,
                posixPermissions: permissions,
                isEncrypted: header.flags & ZipGeneralPurposeFlag.encrypted != 0,
                solidGroup: -1,
                crc32: expectedCRC,
                methodDescription: methodName,
                formatSpecific: specific,
                isIncomplete: extent?.isIncomplete ?? false
            )
            entries.append(entry)
            records.append(ZipEntryRecord(
                localHeaderOffset: absoluteLocalOffset,
                compressedSize: zip64.compressedSize,
                uncompressedSize: zip64.uncompressedSize,
                crc32: expectedCRC,
                storedCRC32: header.storedCRC,
                flags: header.flags,
                method: method,
                headerMethod: header.headerMethod,
                encryption: encryption,
                usesZIP64: extraFields.contains { $0.identifier == ZipExtraFieldID.zip64 },
                availableCompressedSize: extent?.availableSize,
                hasKnownCompressedSize: extent?.unknownSize != true
            ))
        }

        guard cursor.remaining == 0 else {
            throw KaitoError.malformed("ZIP central-directory count does not match its data")
        }
        guard archiveNameIndex == archiveNames.decoded.count else {
            throw KaitoError.malformed("ZIP archive-name count is inconsistent")
        }
        return ZipParsedDirectory(
            location: location,
            entries: entries,
            records: records,
            nameEncoding: archiveNames.encoding
        )
    }

    private static func readCentralHeader(_ cursor: inout ZipByteCursor) throws -> CentralHeader {
        guard cursor.remaining >= ZipRecordSize.centralHeader else {
            throw KaitoError.malformed("ZIP central-directory entry count exceeds its data")
        }
        guard try cursor.readUInt32LE() == ZipSignature.centralHeader else {
            throw KaitoError.malformed("invalid ZIP central-header signature")
        }
        let versionMadeBy = try cursor.readUInt16LE()
        _ = try cursor.readUInt16LE() // 展開に必要なバージョン
        let flags = try cursor.readUInt16LE()
        let headerMethod = try cursor.readUInt16LE()
        let dosTime = try cursor.readUInt16LE()
        let dosDate = try cursor.readUInt16LE()
        let storedCRC = try cursor.readUInt32LE()
        let compressed32 = try cursor.readUInt32LE()
        let uncompressed32 = try cursor.readUInt32LE()
        let nameLength = Int(try cursor.readUInt16LE())
        let extraLength = Int(try cursor.readUInt16LE())
        let commentLength = Int(try cursor.readUInt16LE())
        let diskStart16 = try cursor.readUInt16LE()
        _ = try cursor.readUInt16LE() // 内部属性
        let externalAttributes = try cursor.readUInt32LE()
        let localOffset32 = try cursor.readUInt32LE()

        guard nameLength > 0 else {
            throw KaitoError.malformed("ZIP entry has an empty name")
        }
        let variableLength = try Checked.add(UInt64(nameLength), UInt64(extraLength))
        let fullVariableLength = try Checked.add(variableLength, UInt64(commentLength))
        guard fullVariableLength <= UInt64(cursor.remaining) else {
            throw KaitoError.malformed("ZIP central variable fields overrun the directory")
        }
        let rawName = try cursor.readBytes(nameLength)
        let extra = try cursor.readBytes(extraLength)
        try cursor.skip(commentLength)
        guard !rawName.contains(0) else {
            throw KaitoError.malformed("ZIP entry name contains NUL")
        }
        return CentralHeader(
            versionMadeBy: versionMadeBy,
            flags: flags,
            headerMethod: headerMethod,
            dosTime: dosTime,
            dosDate: dosDate,
            storedCRC: storedCRC,
            compressed32: compressed32,
            uncompressed32: uncompressed32,
            diskStart16: diskStart16,
            externalAttributes: externalAttributes,
            localOffset32: localOffset32,
            rawName: rawName,
            extra: extra
        )
    }

    /// 暗号方式と、展開に使う実方式・照合する CRC を決める。AES は 0x9901 の方式を使い、AE-2 は CRC を照合しない。
    private static func classifyEncryption(
        _ header: CentralHeader,
        extraFields: [ZipExtraField]
    ) throws -> (encryption: ZipEntryEncryption, method: UInt16, expectedCRC: UInt32?) {
        let aes = try parseAESExtra(fields: extraFields, headerMethod: header.headerMethod)
        guard header.flags & ZipGeneralPurposeFlag.strongEncryption == 0 else {
            throw KaitoError.unsupportedMethod("strong ZIP encryption")
        }
        if let aes {
            guard header.flags & ZipGeneralPurposeFlag.encrypted != 0 else {
                throw KaitoError.malformed("WinZip AES entry lacks the encryption flag")
            }
            if aes.vendorVersion == .ae2, header.storedCRC != 0 {
                throw KaitoError.malformed("WinZip AE-2 entry has a nonzero CRC")
            }
            return (.aes(aes), aes.compressionMethod, aes.vendorVersion == .ae2 ? nil : header.storedCRC)
        }
        if header.flags & ZipGeneralPurposeFlag.encrypted != 0 {
            return (.traditional, header.headerMethod, header.storedCRC)
        }
        return (.none, header.headerMethod, header.storedCRC)
    }

    /// UTF-8 flag の名前、Unicode path extra、書庫全体で推定した符号化、名前ごとの推定の順に名前を決める。
    /// 書庫全体の推定に参加する名前は `archiveNameIndex` を一つ進める。
    private static func resolveName(
        _ header: CentralHeader,
        extraFields: [ZipExtraField],
        archiveNames: ArchiveNames,
        archiveNameIndex: inout Int,
        policy: EncodingPolicy
    ) throws -> String {
        let rawName = header.rawName
        let unicodeName = ZipExtraFields.unicodePath(from: extraFields, rawName: rawName)
        let hasUTF8Flag = header.hasUTF8Names
        let name: String
        if hasUTF8Flag,
           let decoded = EncodingDetector.decode(bytes: rawName, as: .utf8) {
            name = decoded
        } else if let unicodeName {
            name = unicodeName
        } else {
            let archiveDecodedName: String?
            if !hasUTF8Flag,
               participatesInArchiveDetection(rawName, policy: policy) {
                guard archiveNameIndex < archiveNames.decoded.count else {
                    throw KaitoError.malformed("ZIP archive-name index is inconsistent")
                }
                archiveDecodedName = archiveNames.decoded[archiveNameIndex]
                archiveNameIndex += 1
            } else {
                archiveDecodedName = nil
            }
            name = archiveDecodedName ??
                EncodingDetector.resolveUndeclaredName(
                    bytes: rawName,
                    policy: policy,
                    archiveEncoding: archiveNames.encoding,
                    fromWindows: header.hostOS == 0
                ).string
        }
        guard !name.isEmpty, !name.utf8.contains(0) else {
            throw KaitoError.malformed("ZIP entry name cannot be decoded safely")
        }
        return name
    }

    private static func archiveNames(
        in bytes: [UInt8],
        entryCount: Int,
        policy: EncodingPolicy,
        recordLimit: Int
    ) throws -> ArchiveNames {
        var cursor = ZipByteCursor(bytes)
        var undecoratedNames: [[UInt8]] = []
        undecoratedNames.reserveCapacity(entryCount)
        var windowsNameCount = 0

        for index in 0..<entryCount {
            try checkCancellation(every: index)
            guard cursor.remaining >= ZipRecordSize.centralHeader,
                  try cursor.readUInt32LE() == ZipSignature.centralHeader else {
                throw KaitoError.malformed("invalid ZIP central-header signature")
            }
            let versionMadeBy = try cursor.readUInt16LE()
            try cursor.skip(2) // 展開に必要なバージョン
            let flags = try cursor.readUInt16LE()
            try cursor.skip(18) // method から uncompressed size まで
            let nameLength = Int(try cursor.readUInt16LE())
            let extraLength = Int(try cursor.readUInt16LE())
            let commentLength = Int(try cursor.readUInt16LE())
            try cursor.skip(12) // disk number から local-header offset まで

            guard nameLength > 0 else {
                throw KaitoError.malformed("ZIP entry has an empty name")
            }
            let variableLength = try Checked.add(UInt64(nameLength), UInt64(extraLength))
            let fullVariableLength = try Checked.add(variableLength, UInt64(commentLength))
            guard fullVariableLength <= UInt64(cursor.remaining) else {
                throw KaitoError.malformed("ZIP central variable fields overrun the directory")
            }
            let rawName = try cursor.readBytes(nameLength)
            let extra = try cursor.readBytes(extraLength)
            try cursor.skip(commentLength)
            guard !rawName.contains(0) else {
                throw KaitoError.malformed("ZIP entry name contains NUL")
            }

            guard flags & ZipGeneralPurposeFlag.utf8Names == 0 else { continue }
            let extraFields = try ZipExtraFields.parse(
                extra,
                recordLimit: recordLimit,
                tailPolicy: .ignoreUnparsableTail
            )
            guard ZipExtraFields.unicodePath(from: extraFields, rawName: rawName) == nil else { continue }
            guard participatesInArchiveDetection(rawName, policy: policy) else { continue }
            undecoratedNames.append(rawName)
            if UInt8(truncatingIfNeeded: versionMadeBy >> 8) == 0 {
                windowsNameCount += 1
            }
        }

        guard cursor.remaining == 0 else {
            throw KaitoError.malformed("ZIP central-directory count does not match its data")
        }
        let fromWindows = windowsNameCount >= undecoratedNames.count - windowsNameCount
        let encoding = EncodingDetector.detectArchiveEncoding(
            names: undecoratedNames,
            policy: policy,
            fromWindows: fromWindows
        )
        guard let encoding else {
            return ArchiveNames(encoding: nil, decoded: [])
        }
        let decodedNames = EncodingDetector.decodeArchiveNames(
            undecoratedNames,
            as: encoding
        )
        return ArchiveNames(encoding: encoding, decoded: decodedNames)
    }

    private static func participatesInArchiveDetection(
        _ rawName: [UInt8],
        policy: EncodingPolicy
    ) -> Bool {
        switch policy {
        case .fixed:
            return true
        case .automatic, .utf8Only:
            return !EncodingDetector.isStrictUTF8(rawName)
        }
    }

    private static func parseAESExtra(
        fields: [ZipExtraField],
        headerMethod: UInt16
    ) throws -> WinZipAESMetadata? {
        var data: [UInt8]?
        for field in fields where field.identifier == ZipExtraFieldID.winZipAES {
            guard data == nil, headerMethod == ZipMethod.winZipAES else {
                throw KaitoError.malformed("ambiguous WinZip AES metadata")
            }
            data = field.data
        }
        guard let data else {
            if headerMethod == ZipMethod.winZipAES {
                throw KaitoError.malformed("WinZip AES extra field is missing")
            }
            return nil
        }
        guard data.count == 7 else {
            throw KaitoError.malformed("invalid WinZip AES extra-field length")
        }
        var cursor = ZipByteCursor(data)
        let version = try cursor.readUInt16LE()
        let vendor0 = try cursor.readUInt8()
        let vendor1 = try cursor.readUInt8()
        let strength = try cursor.readUInt8()
        let method = try cursor.readUInt16LE()
        // WinZipAESMetadata(extraFieldPayload:) は同じ欠陥の一部を unsupportedMethod とする。
        // 中央ディレクトリでは malformed に揃え、EOCD 候補の再試行判定へ同じ分類で渡す。
        guard let vendorVersion = WinZipAESVendorVersion(rawValue: version),
              vendor0 == 0x41, vendor1 == 0x45,
              let keyStrength = WinZipAESStrength(rawValue: strength),
              method != ZipMethod.winZipAES else {
            throw KaitoError.malformed("invalid WinZip AES metadata")
        }
        return WinZipAESMetadata(vendorVersion: vendorVersion, strength: keyStrength, compressionMethod: method)
    }

    // MARK: formatSpecific の値の表記

    static func flagsDescription(_ flags: UInt16) -> String {
        String(unsafeUninitializedCapacity: 6) { buffer in
            buffer[0] = 0x30
            buffer[1] = 0x78
            for index in 0..<4 {
                let digit = UInt8((flags >> (12 - index * 4)) & 0x0f)
                buffer[index + 2] = digit < 10 ? digit + 0x30 : digit + 0x57
            }
            return 6
        }
    }

    static func crc32Description(_ crc: UInt32) -> String {
        String(unsafeUninitializedCapacity: 10) { buffer in
            buffer[0] = 0x30
            buffer[1] = 0x78
            for index in 0..<8 {
                let digit = UInt8((crc >> (28 - index * 4)) & 0x0f)
                buffer[index + 2] = digit < 10 ? digit + 0x30 : digit + 0x57
            }
            return 10
        }
    }

    private static func methodDescription(_ method: UInt16) -> String {
        switch method {
        case ZipMethod.stored: "stored"
        case ZipMethod.shrink: "shrink"
        case ZipMethod.reduce1...ZipMethod.reduce4: "reduce\(method - 1)"
        case ZipMethod.implode: "implode"
        case ZipMethod.deflate: "deflate"
        case ZipMethod.deflate64: "deflate64"
        case ZipMethod.bzip2: "bzip2"
        case ZipMethod.lzma: "lzma"
        case ZipMethod.zstdDeprecated, ZipMethod.zstd: "zstd"
        case ZipMethod.xz: "xz"
        case ZipMethod.jpeg: "jpeg"
        case ZipMethod.ppmd: "ppmd"
        default: "method \(method)"
        }
    }

    private static func retainedMetadataCost(
        rawName: [UInt8],
        name: String,
        components: [String],
        specific: [String: String]
    ) throws -> UInt64 {
        var size: UInt64 = 256
        size = try Checked.add(size, UInt64(rawName.count))
        size = try Checked.add(size, UInt64(name.utf8.count))
        size = try Checked.add(
            size,
            try Checked.mul(
                UInt64(components.count),
                UInt64(MemoryLayout<String>.stride)
            )
        )
        for component in components {
            size = try Checked.add(size, UInt64(component.utf8.count))
        }
        for (key, value) in specific {
            size = try Checked.add(size, UInt64(key.utf8.count))
            size = try Checked.add(size, UInt64(value.utf8.count))
        }
        return size
    }
}
