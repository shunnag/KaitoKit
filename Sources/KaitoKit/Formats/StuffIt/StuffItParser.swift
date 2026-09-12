// Clean-room format inputs: 指定レポート Ch.00・01・02 の散文だけに基づく。
// XADMaster / The Unarchiver / stuffit-go 等の実装ソースは参照していない。
import Foundation

enum StuffItHeader {
    static func be16(_ b: [UInt8], _ p: Int) -> UInt16 {
        UInt16(b[p]) << 8 | UInt16(b[p + 1])
    }
    static func be32(_ b: [UInt8], _ p: Int) -> UInt64 {
        UInt64(be16(b, p)) << 16 | UInt64(be16(b, p + 2))
    }
    static func signature(_ b: [UInt8]) -> String? {
        if b.count >= 14, Array(b[10..<14]) == Array("rLau".utf8) {
            let digit: (UInt8) -> Bool = { (48...57).contains($0) }
            if Array(b[0..<4]) == Array("SIT!".utf8)
                || Array(b[0..<4]) == Array("STin".utf8)
                || (b[0] == 83 && b[1] == 84 && b[2] == 105 && digit(b[3]))
                || (b[0] == 83 && b[1] == 84 && digit(b[2]) && digit(b[3])) {
                return "classic"
            }
        }
        if b.count >= 100, Array(b[0..<16]) == Array("StuffIt (c)1997-".utf8),
           Array(b[20..<80]) == Array(" Aladdin Systems, Inc., http://www.aladdinsys.com/StuffIt/\r\n".utf8) {
            return "stuffit5"
        }
        return nil
    }
    static func hex(_ b: some Sequence<UInt8>) -> String {
        b.map { String(format: "%02x", $0) }.joined()
    }
    static func macMetadata(_ b: [UInt8], type: Int, creator: Int, flags: Int) -> [String: String] {
        ["macType": String(bytes: b[type..<type + 4], encoding: .macOSRoman) ?? "",
         "macCreator": String(bytes: b[creator..<creator + 4], encoding: .macOSRoman) ?? "",
         "finderFlags": String(format: "%04x", be16(b, flags))]
    }
}

struct StuffItRecord {
    var rawName: [UInt8]
    var parent: Int?
    var directory = false
    var resource = false
    var encrypted = false
    var encryptionFlags: UInt8 = 0
    var entryKey: [UInt8] = []
    var padding: UInt64 = 0
    var method = 0
    var offset: UInt64 = 0
    var stored: UInt64 = 0
    var size: UInt64 = 0
    var crc: UInt16 = 0
    var modified: UInt64 = 0
    var metadata: [String: String] = [:]
}

struct StuffItParser {
    let source: any ByteSource
    let limits: ReadLimits
    var records: [StuffItRecord] = []
    var metadataSize: UInt64 = 0
    var totalSize: UInt64 = 0
    var archiveHash: [UInt8]?
    var archiveCommentBytes: [UInt8]?

    func bytes(_ offset: UInt64, _ count: Int, end: UInt64) throws -> [UInt8] {
        guard try Checked.add(offset, UInt64(count)) <= end else { throw KaitoError.truncated }
        try Checked.size(UInt64(count), limit: limits.maxMetadataSize)
        return try readByteRange(source: source, offset: offset, count: count)
    }

    mutating func append(_ record: StuffItRecord) throws {
        guard records.count < limits.maxEntryCount else { throw KaitoError.limitExceeded("StuffIt entry count") }
        try Checked.size(record.size, limit: limits.maxEntrySize)
        totalSize = try Checked.add(totalSize, record.size)
        try Checked.size(totalSize, limit: limits.maxTotalUncompressedSize)
        var cost = UInt64(record.rawName.count + 192)
        for (key, value) in record.metadata { cost = try Checked.add(cost, UInt64(key.utf8.count + value.utf8.count)) }
        metadataSize = try Checked.add(metadataSize, cost)
        try Checked.size(metadataSize, limit: limits.maxTotalMetadataSize)
        records.append(record)
    }

    mutating func classic() throws {
        let header = try bytes(0, 22, end: source.length)
        let end = StuffItHeader.be32(header, 6)
        guard end >= 22 else { throw KaitoError.malformed("StuffIt archive extent") }
        guard end <= source.length else { throw KaitoError.truncated }
        var position: UInt64 = 22
        var stack: [Int] = []
        while end - position >= 112 {
            let b = try bytes(position, 112, end: end)
            guard CRC16.checksum(Array(b[..<110])) == StuffItHeader.be16(b, 110) else {
                throw KaitoError.malformed("StuffIt classic header CRC")
            }
            position += 112
            let r = b[0] & 0x6f, d = b[1] & 0x6f
            let begin = r == 0x20 || d == 0x20
            let finish = r == 0x21 || d == 0x21
            guard !(begin && finish) else { throw KaitoError.malformed("StuffIt contradictory directory markers") }
            if finish {
                guard !stack.isEmpty else { throw KaitoError.malformed("StuffIt directory stack underflow") }
                stack.removeLast()
                continue
            }
            var record = StuffItRecord(rawName: Array(b[3..<3 + min(Int(b[2]), 31)]), parent: stack.last)
            record.modified = StuffItHeader.be32(b, 80)
            record.metadata = StuffItHeader.macMetadata(b, type: 66, creator: 70, flags: 74)
            record.metadata["container"] = "classic"
            record.metadata["modificationTime1904"] = String(record.modified)
            if b[2] > 31 {
                record.metadata["classicNameLength"] = String(b[2])
                record.metadata["classicNameStorage"] = StuffItHeader.hex(b[3..<66])
            }
            if begin {
                record.directory = true
                record.encrypted = (b[0] | b[1]) & 0x10 != 0
                let index = records.count
                try append(record)
                guard stack.count < limits.maxPathComponentCount else { throw KaitoError.limitExceeded("StuffIt path depth") }
                stack.append(index)
                continue
            }
            let ur = StuffItHeader.be32(b, 84), ud = StuffItHeader.be32(b, 88)
            let cr = StuffItHeader.be32(b, 92), cd = StuffItHeader.be32(b, 96)
            let next = try Checked.add(position, Checked.add(cr, cd))
            guard next <= end else { throw KaitoError.malformed("StuffIt fork exceeds archive extent") }
            if ur > 0 {
                var fork = record
                fork.resource = true; fork.method = Int(b[0] & 15); fork.encryptionFlags = b[0] & 0x90
                fork.encrypted = fork.encryptionFlags != 0
                fork.offset = position; fork.stored = cr; fork.size = ur; fork.crc = StuffItHeader.be16(b, 100)
                fork.padding = UInt64(b[104])
                try append(fork)
            }
            if ud > 0 || ur == 0 {
                record.method = Int(b[1] & 15); record.encryptionFlags = b[1] & 0x90
                record.encrypted = record.encryptionFlags != 0
                record.offset = position + cr; record.stored = cd; record.size = ud; record.crc = StuffItHeader.be16(b, 102)
                record.padding = UInt64(b[105])
                try append(record)
            }
            position = next
        }
        guard stack.isEmpty else { throw KaitoError.malformed("StuffIt unclosed directory") }
    }
}
