// Clean-room format inputs: 指定レポート Ch.00・02 の散文に基づく。RC4 は未実装。
// XADMaster / The Unarchiver / stuffit-go 等の実装ソースは参照していない。
import Foundation

extension StuffItParser {
    mutating func stuffIt5() throws {
        let fixed = try bytes(0, 100, end: source.length)
        guard fixed[82] == 5 else { throw KaitoError.malformed("StuffIt 5 archive version") }
        let first = StuffItHeader.be32(fixed, 94)
        let end = StuffItHeader.be32(fixed, 84)
        guard first >= 100, end >= first else { throw KaitoError.malformed("StuffIt 5 archive extent") }
        guard end <= source.length else { throw KaitoError.truncated }
        var header = try bytes(0, Checked.toInt(first), end: end)
        let expected = StuffItHeader.be16(header, 98)
        header[98] = 0; header[99] = 0
        guard CRC16.checksum(header) == expected else { throw KaitoError.malformed("StuffIt 5 archive header CRC") }
        var cursor = 100
        func advance(_ count: Int) throws {
            guard count <= header.count - cursor else { throw KaitoError.malformed("StuffIt 5 optional metadata extent") }
            cursor += count
        }
        let flags = fixed[83]
        if flags & 0x10 != 0 { try advance(14) }
        var comment = 0, auxiliary = 0
        if flags & 0x20 != 0 {
            try advance(4)
            comment = Int(StuffItHeader.be16(header, cursor - 4))
            auxiliary = Int(StuffItHeader.be16(header, cursor - 2))
        }
        if flags & 0x80 != 0 {
            try advance(1)
            guard header[cursor - 1] == 5 else { throw KaitoError.malformed("StuffIt 5 password hash length") }
            try advance(5)
        }
        if flags & 0x40 != 0 {
            try advance(2)
            let count = Int(StuffItHeader.be16(header, cursor - 2))
            guard count <= limits.maxMetadataRecordCount else { throw KaitoError.limitExceeded("StuffIt 5 metadata records") }
            try advance(20 * count)
        }
        try advance(comment + auxiliary)
        var position = first
        var remaining = UInt64(StuffItHeader.be16(fixed, 92))
        var directories: [UInt64: (index: Int, children: Int)] = [:]
        var rootChildren = Int(remaining)
        while remaining > 0 {
            let h = try bytes(position, 48, end: end)
            guard h[0..<4].allSatisfy({ $0 == 0xa5 }) else { throw KaitoError.malformed("StuffIt 5 entry signature") }
            let directory = h[9] & 0x40 != 0
            if directory && StuffItHeader.be32(h, 34) == 0xffff_ffff {
                position += 48
                continue
            }
            let length = Int(StuffItHeader.be16(h, 6))
            guard length >= 48 else { throw KaitoError.malformed("StuffIt 5 primary header size") }
            var primary = try bytes(position, length, end: end)
            let crc = StuffItHeader.be16(primary, 32)
            primary[32] = 0; primary[33] = 0
            guard CRC16.checksum(primary) == crc else { throw KaitoError.malformed("StuffIt 5 primary header CRC") }
            let encrypted = h[9] & 0x20 != 0
            let ud = directory ? 0 : StuffItHeader.be32(h, 34)
            let cd = directory ? 0 : StuffItHeader.be32(h, 38)
            let kd = directory ? 0 : Int(h[47])
            guard directory || kd == (encrypted && ud > 0 ? 5 : 0) else { throw KaitoError.malformed("StuffIt 5 data key length") }
            let n = Int(StuffItHeader.be16(h, 30))
            let t = 48 + kd + n
            guard t <= length else { throw KaitoError.malformed("StuffIt 5 filename extent") }
            if length != t {
                guard length >= t + 4, length == t + 4 + Int(StuffItHeader.be16(primary, t)) else {
                    throw KaitoError.malformed("StuffIt 5 entry comment length")
                }
            }
            let parentOffset = StuffItHeader.be32(h, 26)
            var parent: Int?
            if parentOffset != 0 {
                guard var found = directories[parentOffset], found.children > 0 else {
                    throw KaitoError.malformed("StuffIt 5 missing parent or child count mismatch")
                }
                parent = found.index; found.children -= 1; directories[parentOffset] = found
            } else {
                guard rootChildren > 0 else { throw KaitoError.malformed("StuffIt 5 root count mismatch") }
                rootChildren -= 1
            }
            var record = StuffItRecord(rawName: Array(primary[48 + kd..<t]), parent: parent)
            record.directory = directory; record.encrypted = encrypted
            record.modified = StuffItHeader.be32(h, 14)
            let q = h[4] == 1 ? 36 : 32
            var payload = position + UInt64(length + q)
            let secondary = try bytes(position + UInt64(length), q, end: end)
            record.metadata = StuffItHeader.macMetadata(secondary, type: 4, creator: 8, flags: 12)
            record.metadata["container"] = "stuffit5"
            record.metadata["modificationTime1904"] = String(record.modified)
            if length > t { record.metadata["commentBytes"] = StuffItHeader.hex(primary[t + 4..<length]) }
            let hasResource = secondary[1] & 1 != 0
            var ur: UInt64 = 0, cr: UInt64 = 0, resourceMethod = 0, resourceCRC: UInt16 = 0
            if hasResource {
                let descriptor = try bytes(payload, 14, end: end)
                ur = StuffItHeader.be32(descriptor, 0); cr = StuffItHeader.be32(descriptor, 4)
                resourceCRC = StuffItHeader.be16(descriptor, 8); resourceMethod = Int(descriptor[12] & 15)
                let kr = Int(descriptor[13])
                guard kr == (encrypted && ur > 0 ? 5 : 0) else { throw KaitoError.malformed("StuffIt 5 resource key length") }
                _ = try bytes(payload + 14, kr, end: end)
                payload += UInt64(14 + kr)
            }
            remaining -= 1
            if directory {
                let children = Int(StuffItHeader.be16(h, 46))
                directories[position] = (records.count, children)
                remaining = try Checked.add(remaining, UInt64(children))
                guard remaining <= UInt64(limits.maxEntryCount) else { throw KaitoError.limitExceeded("StuffIt 5 entry count") }
                try append(record)
                position = payload
            } else {
                let next = try Checked.add(payload, Checked.add(cr, cd))
                guard next <= end else { throw KaitoError.malformed("StuffIt 5 fork exceeds archive extent") }
                if hasResource {
                    var fork = record
                    fork.resource = true; fork.method = resourceMethod; fork.crc = resourceCRC
                    fork.offset = payload; fork.size = ur; fork.stored = cr
                    try append(fork)
                }
                if ud > 0 || !hasResource {
                    record.method = Int(h[46] & 15); record.crc = StuffItHeader.be16(h, 42)
                    record.offset = payload + cr; record.size = ud; record.stored = cd
                    try append(record)
                }
                position = next
            }
        }
        guard rootChildren == 0, directories.values.allSatisfy({ $0.children == 0 }) else {
            throw KaitoError.malformed("StuffIt 5 incomplete directory counts")
        }
    }
}
