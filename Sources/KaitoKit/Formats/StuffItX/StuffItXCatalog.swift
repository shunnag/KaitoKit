// 指定資料 Ch.03 の catalog と公開 fixture による整列補正に基づく。
import Foundation

struct StuffItXCatalog {
    struct Record {
        var name: [UInt8] = []
        var modified: Date?
        var permissions: UInt16?
        var link = false
        var metadata: [String: String] = [:]
    }
    static func parse(_ bytes: Data, count: Int, commentOnly: Bool = false, limits: ReadLimits) throws -> [Record] {
        try Checked.size(UInt64(bytes.count), limit: limits.maxMetadataSize)
        guard count <= limits.maxEntryCount else { throw KaitoError.limitExceeded("StuffIt X catalog records") }
        let input = try StuffItXBitReader(source: DataByteSource(bytes))
        var records: [Record] = []
        for _ in 0..<count {
            var record = Record(), fields = 0
            while true {
                let key = try input.p2()
                if key == 0 { input.align(); break }
                fields += 1
                guard fields <= limits.maxMetadataRecordCount else { throw KaitoError.limitExceeded("StuffIt X catalog fields") }
                if commentOnly && key != 9 { throw KaitoError.malformed("StuffIt X archive comment key") }
                switch key {
                case 1: record.name = try input.string(limit: limits.maxMetadataSize)
                case 2, 8:
                    let ticks = try input.packedBE(8)
                    let date = Date(timeIntervalSince1970: Double(ticks) / 10_000_000 - 11_644_473_600)
                    if key == 2 { record.modified = date }
                    record.metadata[key == 2 ? "mtimeTicks" : "ctimeTicks"] = String(ticks)
                case 3: record.metadata["catalog3"] = String(try input.packedBE(4))
                case 4, 5:
                    var info: [UInt8] = []
                    for _ in 0..<32 { info.append(try input.byte()) }
                    record.link = record.link || info.starts(with: "slnkrhap".utf8)
                    record.metadata["finderInfo\(key)"] = info.map { String(format: "%02x", $0) }.joined()
                case 6:
                    let owner = try input.byte(), mode = try input.packedBE(4)
                    record.permissions = UInt16(mode & 0xfff); record.metadata["posixMode"] = String(mode)
                    if owner != 0 {
                        record.metadata["uid"] = String(try input.packedBE(4))
                        record.metadata["gid"] = String(try input.packedBE(4))
                    }
                case 7: record.metadata["catalog7"] = String(try input.p2())
                case 9, 11, 12:
                    let string = try input.string(limit: limits.maxMetadataSize)
                    record.metadata[key == 9 ? "comment" : "catalog\(key)"] = String(decoding: string, as: UTF8.self)
                case 10:
                    let components = try Checked.toInt(input.p2())
                    guard components <= limits.maxPathComponentCount else { throw KaitoError.limitExceeded("StuffIt X catalog components") }
                    input.align()
                    var path: [String] = []
                    for _ in 0..<components { path.append(String(decoding: try input.string(limit: limits.maxMetadataSize), as: UTF8.self)) }
                    record.metadata["catalogPath"] = path.joined(separator: "/")
                default: throw KaitoError.malformed("StuffIt X catalog key \(key)")
                }
            }
            records.append(record)
        }
        guard input.isAtEnd else { throw KaitoError.malformed("StuffIt X catalog trailing bytes") }
        return records
    }
}
