// Linux Standard Base「Package File Format」、rpm(8)、rpm.org の prose、
// RFC 1950/1951/1952 を許可資料とする利用者提供の実測 byte 表に基づくクリーンルーム実装。
// rpm / libarchive / 7-Zip / XADMaster / The Unarchiver / dpkg 等、他の実装 source は参照していない。
import Foundation

struct RpmHeader {
    enum Tag: UInt32, CaseIterable {
        case name = 1000, version = 1001, release = 1002, arch = 1022
        case payloadFormat = 1124, payloadCompressor = 1125, payloadFlags = 1126

        var metadataKey: String? {
            switch self {
            case .name: "rpmName"
            case .version: "rpmVersion"
            case .release: "rpmRelease"
            case .arch: "rpmArch"
            case .payloadFormat: "rpmPayloadFormat"
            case .payloadCompressor: "rpmPayloadCompressor"
            case .payloadFlags: nil
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
        var metadata: [String: String] = [:]
        for (tag, value) in values {
            if let key = tag.metadataKey { metadata[key] = value }
        }
        if isSource { metadata["rpmSourcePackage"] = "true" }
        self.metadata = metadata
        self.metadataSize = metadataSize
    }

    private static func section(source: any ByteSource, at start: UInt64, limits: ReadLimits,
                                collectValues: Bool, metadataSize: inout UInt64,
                                stringWork: inout UInt64) throws -> (end: UInt64, values: [Tag: String]) {
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
            // region trailer は BIN の範囲だけを検証し、内部の負 offset を追わない。
            guard type.isString else { continue }
            var cursor = try Checked.toInt(offset)
            let first = cursor
            for _ in 0..<count {
                let stringStart = cursor
                while cursor < store.count, store[cursor] != 0 { cursor += 1 }
                guard cursor < store.count else { throw KaitoError.malformed("rpm unterminated string") }
                cursor += 1
                // 同じ領域を重複参照する index でも走査量を有界にする。
                stringWork = try Checked.add(stringWork, UInt64(cursor - stringStart))
                try Checked.size(stringWork, limit: limits.maxTotalMetadataSize)
            }
            if collectValues, let tag {
                guard type == .string, count == 1 else { throw KaitoError.malformed("rpm string tag") }
                values[tag] = String(decoding: store[first..<(cursor - 1)], as: UTF8.self)
            }
        }
        return (end, values)
    }

    private static func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}
