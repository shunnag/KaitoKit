// 指定レポート Ch.06「Finding MKey and SitC」の座標系に基づく。
import Foundation

struct StuffItResourceMap {
    var mkey: [UInt8]?
    var comment: [UInt8]?

    init(source: any ByteSource, limits: ReadLimits) throws {
        let header = try readByteRange(source: source, offset: 0, count: 16)
        let dataStart = StuffItHeader.be32(header, 0), mapStart = StuffItHeader.be32(header, 4)
        let dataEnd = try Checked.add(dataStart, StuffItHeader.be32(header, 8))
        let mapEnd = try Checked.add(mapStart, StuffItHeader.be32(header, 12))
        guard dataEnd <= source.length, mapEnd <= source.length, mapEnd - mapStart >= 28 else {
            throw KaitoError.malformed("StuffIt resource map extent")
        }
        func bytes(_ start: UInt64, _ count: Int, end: UInt64) throws -> [UInt8] {
            guard try Checked.add(start, UInt64(count)) <= end else { throw KaitoError.malformed("StuffIt resource reference extent") }
            try Checked.size(UInt64(count), limit: limits.maxMetadataSize)
            return try readByteRange(source: source, offset: start, count: count)
        }
        func count(_ value: UInt16) -> Int { value == 0xffff ? 0 : Int(value) + 1 }
        let map = try bytes(mapStart, 28, end: mapEnd)
        let types = mapStart + UInt64(StuffItHeader.be16(map, 24))
        let names = mapStart + UInt64(StuffItHeader.be16(map, 26))
        guard types >= mapStart + 28, names <= mapEnd else { throw KaitoError.malformed("StuffIt resource lists") }
        let typeCount = count(StuffItHeader.be16(try bytes(types, 2, end: mapEnd), 0))
        guard typeCount <= limits.maxMetadataRecordCount else { throw KaitoError.limitExceeded("StuffIt resource type count") }
        _ = try bytes(types + 2, typeCount * 8, end: mapEnd)
        var referenceCount = 0
        for i in 0..<typeCount {
            let type = try bytes(types + 2 + UInt64(i * 8), 8, end: mapEnd)
            let resources = count(StuffItHeader.be16(type, 4))
            guard resources <= limits.maxMetadataRecordCount - referenceCount else { throw KaitoError.limitExceeded("StuffIt resource count") }
            referenceCount += resources
            let references = types + UInt64(StuffItHeader.be16(type, 6))
            guard references >= types + 2 + UInt64(typeCount * 8) else { throw KaitoError.malformed("StuffIt resource reference list") }
            _ = try bytes(references, resources * 12, end: mapEnd)
            let isKey = type[..<4].elementsEqual("MKey".utf8), isComment = type[..<4].elementsEqual("SitC".utf8)
            for j in 0..<resources {
                let ref = try bytes(references + UInt64(j * 12), 12, end: mapEnd)
                let record = dataStart + UInt64(ref[5]) * 65536 + UInt64(ref[6]) * 256 + UInt64(ref[7])
                let length = StuffItHeader.be32(try bytes(record, 4, end: dataEnd), 0)
                guard try Checked.add(record + 4, length) <= dataEnd else { throw KaitoError.malformed("StuffIt resource data extent") }
                guard StuffItHeader.be16(ref, 0) == 0, isKey || isComment else { continue }
                if isKey {
                    guard mkey == nil, length == 8 else { throw KaitoError.malformed("StuffIt MKey resource") }
                    mkey = try bytes(record + 4, 8, end: dataEnd)
                } else {
                    guard comment == nil else { throw KaitoError.malformed("StuffIt duplicate SitC") }
                    comment = try bytes(record + 4, Checked.toInt(length), end: dataEnd)
                }
            }
        }
    }
}
