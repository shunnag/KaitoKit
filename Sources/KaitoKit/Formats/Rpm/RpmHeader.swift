// Linux Standard Base「Package File Format」、rpm(8)、rpm.org の prose、
// RFC 1950/1951/1952 を許可資料とする利用者提供の実測 byte 表に基づくクリーンルーム実装。
// rpm / libarchive / 7-Zip / XADMaster / The Unarchiver / dpkg 等、他の実装 source は参照していない。
import Foundation

struct RpmFileList {
    struct File {
        let name: String
        let mode: UInt16
        let mtime: UInt32
        let size: UInt64
        let linkTarget: String
        let ino, dev, flags: UInt32
        let digest: String?

        var isGhost: Bool { flags & 0x40 != 0 }
        var kind: EntryKind {
            switch mode & 0o170000 {
            case 0o100000: .file
            case 0o040000: .directory
            case 0o120000: .symlink
            default: .other
            }
        }
    }
    let files: [File]
    let digestAlgorithm: UInt32?
}

struct RpmHeader {
    enum Tag: UInt32, CaseIterable {
        case name = 1000, version = 1001, release = 1002, arch = 1022
        case payloadFormat = 1124, payloadCompressor = 1125, payloadFlags = 1126
        case fileSizes = 1028, fileModes = 1030, fileMtimes = 1034, fileDigests = 1035
        case fileLinktos = 1036, fileFlags = 1037, fileDevices = 1095, fileInodes = 1096
        case dirIndexes = 1116, basenames = 1117, dirnames = 1118
        case longFileSizes = 5008, fileDigestAlgorithm = 5011, rpmFormat = 5114

        var fileValueType: ValueType? {
            switch self {
            case .fileModes: .int16
            case .fileSizes, .fileMtimes, .fileFlags, .fileDevices, .fileInodes,
                 .dirIndexes, .fileDigestAlgorithm, .rpmFormat: .int32
            case .longFileSizes: .int64
            case .basenames, .dirnames, .fileLinktos, .fileDigests: .stringArray
            default: nil
            }
        }

        var isPerFile: Bool {
            fileValueType != nil && self != .dirnames && self != .fileDigestAlgorithm && self != .rpmFormat
        }

        var metadataKey: String? {
            switch self {
            case .name: "rpmName"
            case .version: "rpmVersion"
            case .release: "rpmRelease"
            case .arch: "rpmArch"
            case .payloadFormat: "rpmPayloadFormat"
            case .payloadCompressor: "rpmPayloadCompressor"
            default: nil
            }
        }
    }

    enum ValueType: UInt32 {
        case null = 0, char, int8, int16, int32, int64, string, bin, stringArray, i18nString

        var width: UInt64 {
            switch self {
            case .null: 0
            case .int16: 2
            case .int32: 4
            case .int64: 8
            default: 1
            }
        }

        var isString: Bool { self == .string || self == .stringArray || self == .i18nString }
    }

    let payloadStart: UInt64
    let values: [Tag: String]
    let metadata: [String: String]
    let metadataSize: UInt64
    let fileList: RpmFileList?

    init(source: any ByteSource, limits: ReadLimits) throws {
        let lead = try readByteRange(source: source, offset: 0, count: 96)
        guard lead.starts(with: [0xed, 0xab, 0xee, 0xdb]) else { throw KaitoError.unsupportedFormat }
        // lead は旧式なので version / arch を受理条件にせず、source の印だけを保存する。
        let isSource = lead[6] == 0 && lead[7] == 1
        var metadataSize: UInt64 = 96
        var stringWork: UInt64 = 0
        let signature = try Self.section(source: source, at: 96, limits: limits,
            collectValues: false, metadataSize: &metadataSize, stringWork: &stringWork)
        // signature だけを 8-byte 境界へ進め、main の直後は payload として扱う。
        let mainStart = try Checked.add(signature.end, (8 - signature.end % 8) % 8)
        let main = try Self.section(source: source, at: mainStart, limits: limits,
            collectValues: true, metadataSize: &metadataSize, stringWork: &stringWork)
        payloadStart = main.end
        guard payloadStart <= source.length else { throw KaitoError.truncated }
        values = main.values
        fileList = main.fileList
        var metadata: [String: String] = [:]
        for (tag, value) in values {
            if let key = tag.metadataKey { metadata[key] = value }
        }
        if isSource { metadata["rpmSourcePackage"] = "true" }
        if let format = main.rpmFormat { metadata["rpmFormat"] = String(format) }
        self.metadata = metadata
        self.metadataSize = metadataSize
    }

    private static func section(source: any ByteSource, at start: UInt64, limits: ReadLimits,
                                collectValues: Bool, metadataSize: inout UInt64,
                                stringWork: inout UInt64) throws
        -> (end: UInt64, values: [Tag: String], fileList: RpmFileList?, rpmFormat: UInt64?) {
        let header = try readByteRange(source: source, offset: start, count: 16)
        guard header.starts(with: [0x8e, 0xad, 0xe8]) else { throw KaitoError.malformed("rpm header magic") }
        let nindex = UInt64(be32(header, 8)), hsize = UInt64(be32(header, 12))
        let indexSize = try Checked.mul(nindex, 16)
        try Checked.size(hsize, limit: limits.maxMetadataSize)
        try Checked.size(indexSize, limit: limits.maxMetadataSize)
        let indexStart = try Checked.add(start, 16)
        let storeStart = try Checked.add(indexStart, indexSize)
        let end = try Checked.add(storeStart, hsize)
        guard end <= source.length else { throw KaitoError.truncated }
        guard nindex <= UInt64(limits.maxMetadataRecordCount) else {
            throw KaitoError.limitExceeded("rpm index count")
        }
        metadataSize = try Checked.add(metadataSize, Checked.sub(end, start))
        try Checked.size(metadataSize, limit: limits.maxTotalMetadataSize)
        let indexes = try readByteRange(source: source, offset: indexStart, count: Checked.toInt(indexSize))
        let store = try readByteRange(source: source, offset: storeStart, count: Checked.toInt(hsize))
        var values: [Tag: String] = [:]
        var numbers: [Tag: [UInt64]] = [:]
        var strings: [Tag: [String]] = [:]
        var fileCount: UInt64?
        func account(_ size: UInt64) throws {
            try Checked.size(size, limit: limits.maxMetadataSize)
            metadataSize = try Checked.add(metadataSize, size)
            try Checked.size(metadataSize, limit: limits.maxTotalMetadataSize)
        }
        for position in stride(from: 0, to: indexes.count, by: 16) {
            let tag = Tag(rawValue: be32(indexes, position))
            guard let type = ValueType(rawValue: be32(indexes, position + 4)) else {
                throw KaitoError.malformed("rpm index entry")
            }
            let offset = UInt64(be32(indexes, position + 8))
            let count = UInt64(be32(indexes, position + 12))
            guard offset < hsize,
                  try Checked.add(offset, Checked.mul(count, type.width)) <= hsize else {
                throw KaitoError.malformed("rpm index entry")
            }
            let fileTag = collectValues ? tag.flatMap { $0.fileValueType == nil ? nil : $0 } : nil
            if let fileTag {
                guard type == fileTag.fileValueType, numbers[fileTag] == nil, strings[fileTag] == nil else {
                    throw KaitoError.malformed("rpm file list")
                }
                if fileTag.isPerFile || fileTag == .dirnames {
                    guard count <= (try Checked.add(UInt64(limits.maxEntryCount), 1)) else {
                        throw KaitoError.limitExceeded("rpm file count")
                    }
                } else if count != 1 {
                    throw KaitoError.malformed("rpm file list")
                }
                if fileTag.isPerFile {
                    if let fileCount, fileCount != count { throw KaitoError.malformed("rpm file list") }
                    fileCount = count
                }
                let stride = type.isString ? MemoryLayout<String>.stride : MemoryLayout<UInt64>.stride
                try account(Checked.mul(count, UInt64(stride)))
                if !type.isString {
                    var array: [UInt64] = []
                    array.reserveCapacity(try Checked.toInt(count))
                    var cursor = try Checked.toInt(offset)
                    for _ in 0..<count {
                        var value: UInt64 = 0
                        for _ in 0..<type.width {
                            value = (value << 8) | UInt64(store[cursor])
                            cursor += 1
                        }
                        array.append(value)
                    }
                    numbers[fileTag] = array
                }
            }
            // region trailer は BIN の範囲だけを検証し、内部の負 offset を追わない。
            guard type.isString else { continue }
            var cursor = try Checked.toInt(offset)
            let first = cursor
            var array: [String] = []
            if fileTag != nil { array.reserveCapacity(try Checked.toInt(count)) }
            for _ in 0..<count {
                let stringStart = cursor
                while cursor < store.count, store[cursor] != 0 { cursor += 1 }
                guard cursor < store.count else { throw KaitoError.malformed("rpm unterminated string") }
                cursor += 1
                // 同じ領域を重複参照する index でも走査量を有界にする。
                stringWork = try Checked.add(stringWork, UInt64(cursor - stringStart))
                try Checked.size(stringWork, limit: limits.maxTotalMetadataSize)
                if fileTag != nil {
                    // 不正 UTF-8 の置換で最大 3 倍になる分も、復号前に見積もる。
                    try account(Checked.mul(UInt64(cursor - stringStart), 3))
                    array.append(String(decoding: store[stringStart..<(cursor - 1)], as: UTF8.self))
                }
            }
            if let fileTag {
                strings[fileTag] = array
            } else if collectValues, let tag {
                guard type == .string, count == 1 else { throw KaitoError.malformed("rpm string tag") }
                values[tag] = String(decoding: store[first..<(cursor - 1)], as: UTF8.self)
            }
        }
        if let indexes = numbers[.dirIndexes], let dirs = strings[.dirnames] {
            guard indexes.allSatisfy({ $0 < UInt64(dirs.count) }) else { throw KaitoError.malformed("rpm file list") }
        }
        var fileList: RpmFileList?
        if let bases = strings[.basenames], let dirs = strings[.dirnames], let indexes = numbers[.dirIndexes],
           let modes = numbers[.fileModes], let mtimes = numbers[.fileMtimes],
           let sizes = numbers[.longFileSizes] ?? numbers[.fileSizes], let links = strings[.fileLinktos],
           let inodes = numbers[.fileInodes], let devices = numbers[.fileDevices], let flags = numbers[.fileFlags] {
            try account(Checked.mul(UInt64(bases.count), UInt64(MemoryLayout<RpmFileList.File>.stride)))
            var files: [RpmFileList.File] = []
            files.reserveCapacity(bases.count)
            for i in bases.indices {
                let dir = dirs[try Checked.toInt(indexes[i])]
                let nameSize = try Checked.add(UInt64(dir.utf8.count), UInt64(bases[i].utf8.count))
                guard nameSize > 0 else { throw KaitoError.malformed("rpm file list") }
                try Checked.size(Checked.add(nameSize, 1), limit: CpioReader.maximumNameSize)
                try account(nameSize)
                let digest = strings[.fileDigests]?[i]
                files.append(RpmFileList.File(name: dir + bases[i], mode: UInt16(modes[i]), mtime: UInt32(mtimes[i]),
                    size: sizes[i], linkTarget: links[i], ino: UInt32(inodes[i]), dev: UInt32(devices[i]),
                    flags: UInt32(flags[i]), digest: digest?.isEmpty == false ? digest : nil))
            }
            fileList = RpmFileList(files: files, digestAlgorithm: numbers[.fileDigestAlgorithm].map { UInt32($0[0]) })
        }
        return (end, values, fileList, numbers[.rpmFormat]?.first)
    }

    private static func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}
