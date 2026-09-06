import Foundation

struct SevenZipFileMetadata: Sendable, Equatable {
    let rawName: [UInt8]
    let name: String
    let hasStream: Bool
    let isEmptyFile: Bool
    let isAnti: Bool
    let creationTime: Date?
    let accessTime: Date?
    let modificationTime: Date?
    let windowsAttributes: UInt32?
    let startPosition: UInt64?
}

struct SevenZipParsedHeader: Sendable, Equatable {
    let streams: SevenZipStreamsInfo?
    let files: [SevenZipFileMetadata]
}

enum SevenZipHeaderParser {
    typealias StreamsDecoder = (SevenZipStreamsInfo, UInt64) throws -> [Data]

    static func parse(
        bytes: [UInt8],
        limits: ReadLimits,
        budget: SevenZipMetadataBudget,
        decodeStreams: StreamsDecoder
    ) throws -> SevenZipParsedHeader {
        var cursor = SevenZipHeaderCursor(bytes)
        guard SevenZipNID(rawValue: try cursor.readUInt8()) == .header else {
            throw KaitoError.malformed("7z decoded header does not start with kHeader")
        }

        var additionalStreams: [Data] = []
        var mainStreams: SevenZipStreamsInfo?
        var files: [SevenZipFileMetadata]?
        var sawArchiveProperties = false
        var sawAdditionalStreams = false

        while true {
            guard let nid = SevenZipNID(rawValue: try cursor.readUInt8()) else {
                throw KaitoError.malformed("unknown 7z header property")
            }
            switch nid {
            case .end:
                guard cursor.isAtEnd else {
                    throw KaitoError.malformed("bytes follow the 7z header terminator")
                }
                let finalFiles = files ?? []
                if !finalFiles.allSatisfy({ !$0.hasStream }) && mainStreams == nil {
                    throw KaitoError.malformed("7z files reference missing main streams")
                }
                return SevenZipParsedHeader(streams: mainStreams, files: finalFiles)

            case .archiveProperties:
                guard !sawArchiveProperties, mainStreams == nil, files == nil else {
                    throw KaitoError.malformed("misplaced 7z archive properties")
                }
                sawArchiveProperties = true
                try skipArchiveProperties(cursor: &cursor, limits: limits)

            case .additionalStreamsInfo:
                guard !sawAdditionalStreams, mainStreams == nil, files == nil else {
                    throw KaitoError.malformed("misplaced or duplicate 7z additional streams")
                }
                sawAdditionalStreams = true
                let streams = try SevenZipStreamsParser.parse(
                    cursor: &cursor,
                    limits: limits,
                    budget: budget
                )
                additionalStreams = try decodeStreams(streams, limits.maxMetadataSize)

            case .mainStreamsInfo:
                guard mainStreams == nil, files == nil else {
                    throw KaitoError.malformed("misplaced or duplicate 7z main streams")
                }
                mainStreams = try SevenZipStreamsParser.parse(
                    cursor: &cursor,
                    limits: limits,
                    externalStreams: additionalStreams,
                    budget: budget
                )

            case .filesInfo:
                guard files == nil else {
                    throw KaitoError.malformed("duplicate 7z FilesInfo")
                }
                files = try parseFilesInfo(
                    cursor: &cursor,
                    externalStreams: additionalStreams,
                    limits: limits,
                    budget: budget
                )

            default:
                throw KaitoError.malformed("unexpected 7z header property 0x\(String(nid.rawValue, radix: 16))")
            }
        }
    }

    private static func skipArchiveProperties(
        cursor: inout SevenZipHeaderCursor,
        limits: ReadLimits
    ) throws {
        var count = 0
        while true {
            let type = try cursor.readUInt8()
            if type == SevenZipNID.end.rawValue { return }
            guard count < limits.maxMetadataRecordCount else {
                throw KaitoError.limitExceeded("7z archive property count")
            }
            count += 1
            let size64 = try cursor.readNumber()
            try Checked.size(size64, limit: limits.maxMetadataSize)
            let size = try Checked.toInt(size64)
            guard size <= cursor.remaining else { throw KaitoError.truncated }
            try cursor.skip(size)
        }
    }

    private static func parseFilesInfo(
        cursor: inout SevenZipHeaderCursor,
        externalStreams: [Data],
        limits: ReadLimits,
        budget: SevenZipMetadataBudget
    ) throws -> [SevenZipFileMetadata] {
        let count = try SevenZipStreamsParser.boundedCount(
            try cursor.readNumber(),
            remaining: cursor.remaining,
            limit: limits.maxEntryCount,
            description: "7z file count"
        )
        // 各 file は後段で少なくとも 256 byte の保持 metadata として計上する。
        // count 比例の補助配列を確保する前にも同じ総量上限を適用する。
        try budget.reserve(
            count: count,
            bytesPerRecord: 256,
            description: "7z file metadata"
        )
        var emptyStreams = [Bool](repeating: false, count: count)
        var emptyFileProperty: [UInt8]?
        var antiProperty: [UInt8]?
        var rawNames: [[UInt8]]?
        var names: [String]?
        var creationTimes = [Date?](repeating: nil, count: count)
        var accessTimes = [Date?](repeating: nil, count: count)
        var modificationTimes = [Date?](repeating: nil, count: count)
        var attributes = [UInt32?](repeating: nil, count: count)
        var startPositions = [UInt64?](repeating: nil, count: count)
        var seen = Set<UInt8>()
        var propertyCount = 0

        while true {
            let rawID = try cursor.readUInt8()
            if rawID == SevenZipNID.end.rawValue { break }
            guard propertyCount < limits.maxMetadataRecordCount else {
                throw KaitoError.limitExceeded("7z file property count")
            }
            propertyCount += 1
            let repeatable = rawID == SevenZipNID.dummy.rawValue
                || rawID == SevenZipNID.comment.rawValue
                || SevenZipNID(rawValue: rawID) == nil
            if !repeatable, !seen.insert(rawID).inserted {
                throw KaitoError.malformed("duplicate 7z file property")
            }

            let size64 = try cursor.readNumber()
            try Checked.size(size64, limit: limits.maxMetadataSize)
            let size = try Checked.toInt(size64)
            guard size <= cursor.remaining else { throw KaitoError.truncated }
            var property = try cursor.readSubcursor(size)

            switch SevenZipNID(rawValue: rawID) {
            case .emptyStream:
                emptyStreams = try property.readBitVector(count: count)
                guard property.isAtEnd else {
                    throw KaitoError.malformed("7z EmptyStream has trailing bytes")
                }

            case .emptyFile:
                // EmptyStream が後に現れる FilesInfo も扱うため、件数確定まで保留する。
                emptyFileProperty = try property.readBytes(property.remaining)

            case .anti:
                antiProperty = try property.readBytes(property.remaining)

            case .name:
                let parsed = try parseNames(
                    property: &property,
                    count: count,
                    externalStreams: externalStreams,
                    budget: budget
                )
                rawNames = parsed.raw
                names = parsed.decoded

            case .creationTime:
                creationTimes = try parseTimes(
                    property: &property,
                    count: count,
                    externalStreams: externalStreams
                )

            case .accessTime:
                accessTimes = try parseTimes(
                    property: &property,
                    count: count,
                    externalStreams: externalStreams
                )

            case .modificationTime:
                modificationTimes = try parseTimes(
                    property: &property,
                    count: count,
                    externalStreams: externalStreams
                )

            case .windowsAttributes:
                attributes = try parseAttributes(
                    property: &property,
                    count: count,
                    externalStreams: externalStreams
                )

            case .startPosition:
                startPositions = try parseStartPositions(
                    property: &property,
                    count: count,
                    externalStreams: externalStreams
                )

            case .dummy:
                let bytes = try property.readBytes(property.remaining)
                guard bytes.allSatisfy({ $0 == 0 }) else {
                    throw KaitoError.malformed("nonzero 7z Dummy property")
                }

            default:
                // 未知 property は自己記述 length の範囲だけ読み飛ばす。
                try property.skip(property.remaining)
            }
        }

        guard let rawNames, let names,
              rawNames.count == count, names.count == count else {
            if count == 0 { return [] }
            throw KaitoError.malformed("7z FilesInfo is missing names")
        }
        let emptyCount = emptyStreams.lazy.filter { $0 }.count
        let emptyFiles = try parseDeferredBitVector(
            emptyFileProperty,
            count: emptyCount,
            label: "EmptyFile"
        )
        let antiFiles = try parseDeferredBitVector(
            antiProperty,
            count: emptyCount,
            label: "Anti"
        )

        var result: [SevenZipFileMetadata] = []
        result.reserveCapacity(count)
        var emptyIndex = 0
        for index in 0..<count {
            let isEmpty = emptyStreams[index]
            let isEmptyFile = isEmpty ? emptyFiles[emptyIndex] : false
            let isAnti = isEmpty ? antiFiles[emptyIndex] : false
            if isEmpty { emptyIndex += 1 }

            result.append(SevenZipFileMetadata(
                rawName: rawNames[index],
                name: names[index],
                hasStream: !isEmpty,
                isEmptyFile: isEmptyFile,
                isAnti: isAnti,
                creationTime: creationTimes[index],
                accessTime: accessTimes[index],
                modificationTime: modificationTimes[index],
                windowsAttributes: attributes[index],
                startPosition: startPositions[index]
            ))
        }
        return result
    }

    private static func parseDeferredBitVector(
        _ bytes: [UInt8]?,
        count: Int,
        label: String
    ) throws -> [Bool] {
        guard let bytes else { return [Bool](repeating: false, count: count) }
        var cursor = SevenZipHeaderCursor(bytes)
        let result = try cursor.readBitVector(count: count)
        guard cursor.isAtEnd else {
            throw KaitoError.malformed("7z \(label) has trailing bytes")
        }
        return result
    }

    private static func parseNames(
        property: inout SevenZipHeaderCursor,
        count: Int,
        externalStreams: [Data],
        budget: SevenZipMetadataBudget
    ) throws -> (raw: [[UInt8]], decoded: [String]) {
        var values = try valueCursor(property: &property, externalStreams: externalStreams)
        var rawNames: [[UInt8]] = []
        var names: [String] = []
        rawNames.reserveCapacity(count)
        names.reserveCapacity(count)

        for _ in 0..<count {
            var raw: [UInt8] = []
            var terminated = false
            while values.remaining >= 2 {
                let low = try values.readUInt8()
                let high = try values.readUInt8()
                if low == 0, high == 0 {
                    terminated = true
                    break
                }
                try budget.reserve(2, description: "7z file-name metadata")
                raw.append(low)
                raw.append(high)
            }
            guard terminated, !raw.isEmpty,
                  let name = String(data: Data(raw), encoding: .utf16LittleEndian),
                  !name.isEmpty,
                  !name.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw KaitoError.malformed("invalid UTF-16LE 7z file name")
            }
            try budget.reserve(
                UInt64(name.utf8.count),
                description: "7z decoded file-name metadata"
            )
            rawNames.append(raw)
            names.append(name)
        }
        guard values.isAtEnd else {
            throw KaitoError.malformed("7z Name property has trailing bytes")
        }
        return (rawNames, names)
    }

    private static func parseTimes(
        property: inout SevenZipHeaderCursor,
        count: Int,
        externalStreams: [Data]
    ) throws -> [Date?] {
        let defined = try property.readDefinedVector(count: count)
        var values = try valueCursor(property: &property, externalStreams: externalStreams)
        var result = [Date?](repeating: nil, count: count)
        for index in 0..<count where defined[index] {
            result[index] = fileTimeDate(try values.readUInt64LE())
        }
        guard values.isAtEnd else {
            throw KaitoError.malformed("7z time property has trailing bytes")
        }
        return result
    }

    private static func parseAttributes(
        property: inout SevenZipHeaderCursor,
        count: Int,
        externalStreams: [Data]
    ) throws -> [UInt32?] {
        let defined = try property.readDefinedVector(count: count)
        var values = try valueCursor(property: &property, externalStreams: externalStreams)
        var result = [UInt32?](repeating: nil, count: count)
        for index in 0..<count where defined[index] {
            result[index] = try values.readUInt32LE()
        }
        guard values.isAtEnd else {
            throw KaitoError.malformed("7z attributes property has trailing bytes")
        }
        return result
    }

    private static func parseStartPositions(
        property: inout SevenZipHeaderCursor,
        count: Int,
        externalStreams: [Data]
    ) throws -> [UInt64?] {
        let defined = try property.readDefinedVector(count: count)
        var values = try valueCursor(property: &property, externalStreams: externalStreams)
        var result = [UInt64?](repeating: nil, count: count)
        for index in 0..<count where defined[index] {
            result[index] = try values.readUInt64LE()
        }
        guard values.isAtEnd else {
            throw KaitoError.malformed("7z StartPos property has trailing bytes")
        }
        return result
    }

    private static func valueCursor(
        property: inout SevenZipHeaderCursor,
        externalStreams: [Data]
    ) throws -> SevenZipHeaderCursor {
        let external = try property.readUInt8()
        switch external {
        case 0:
            return try property.readSubcursor(property.remaining)
        case 1:
            let index64 = try property.readNumber()
            guard index64 < UInt64(externalStreams.count), property.isAtEnd else {
                throw KaitoError.malformed("invalid external 7z property stream")
            }
            return SevenZipHeaderCursor([UInt8](externalStreams[Int(index64)]))
        default:
            throw KaitoError.malformed("invalid 7z external-data flag")
        }
    }

    private static func fileTimeDate(_ value: UInt64) -> Date? {
        let seconds = Double(value) / 10_000_000.0 - 11_644_473_600.0
        guard seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
