import Foundation

// IEEE P1281 (SUSP 1.10) / P1282 (RRIP) / Apple Technote FL 36 の公開仕様。
struct ISORockRidge {
    var name: [UInt8]?
    var mode: UInt32?
    var link: [UInt8]?
    var modified: Date?
    var relocated = false
    var child: UInt32?
    var parent: UInt32?
    var unsupported: String?
    var virtualSize: UInt64?

    private static func start(in area: [UInt8]) -> Int? {
        for offset in [0, 14] where area.count >= offset + 7 {
            if Array(area[offset..<offset+6]) == [83, 80, 7, 1, 190, 239] {
                return offset
            }
        }
        return nil
    }

    static func skip(in area: [UInt8]) -> Int? {
        start(in: area).map { Int(area[$0 + 6]) }
    }

    static func parse(_ initial: [UInt8], skip: Int?, source: any ByteSource,
                      volume: ISOVolume, budget: ISOMetadataBudget, isRoot: Bool = false) throws -> Self {
        guard let skip else { return Self() }
        // LEN_SKP は他 record 用。SP 自身は root の実際の位置 (0 / XA の 14) から読む。
        let areaStart = isRoot ? (start(in: initial) ?? skip) : skip
        guard areaStart <= initial.count else { return Self() }
        var result = Self()
        var area = Array(initial.dropFirst(areaStart))
        var visited: Set<UInt64> = []
        var ceCount = 0
        var ceBytes: UInt64 = 0
        var count = 0
        var nameBytes: [UInt8] = []
        var namePending = false
        var nameDone = false
        var linkBytes: [UInt8] = []
        var component: [UInt8] = []
        var componentPending = false
        var linkPending = false
        var linkSeen = false
        var linkDone = false
        var unresolvedLink = false
        while true {
            var pos = 0
            var continuation: (UInt32, UInt32, UInt32)?
            while pos + 4 <= area.count {
                let signature = String(decoding: area[pos..<pos+2], as: UTF8.self)
                // BA には length byte が無い。AA は通常の framing で飛ばせる。
                if signature == "BA" { break }
                let length = Int(area[pos + 2])
                guard length >= 4, length <= area.count - pos else { break }
                count += 1
                guard count <= budget.limits.maxMetadataRecordCount else {
                    throw KaitoError.limitExceeded("iso SUSP record count")
                }
                let b = Array(area[pos..<pos+length])
                pos += length
                if signature == "ST" { break }
                guard b[3] == 1 else { continue }
                switch signature {
                case "CE" where length >= 28:
                    guard continuation == nil else { throw KaitoError.malformed("iso CE chain") }
                    continuation = (ISOBytes.number(b, 4, width: 4), ISOBytes.number(b, 12, width: 4),
                                    ISOBytes.number(b, 20, width: 4))
                case "NM" where length >= 5:
                    if !nameDone, b[4] & 0x26 == 0 {
                        nameBytes += b.dropFirst(5)
                        guard nameBytes.count <= 1024 else { throw KaitoError.malformed("iso NM length") }
                        namePending = b[4] & 1 != 0
                        if !namePending { result.name = nameBytes; nameDone = true }
                    }
                case "PX" where length >= 36:
                    result.mode = ISOBytes.number(b, 4, width: 4)
                case "SL" where length >= 5:
                    if linkDone { continue }
                    linkSeen = true
                    linkPending = b[4] & 1 != 0
                    var p = 5
                    while p + 2 <= b.count {
                        let flags = b[p]
                        let n = Int(b[p + 1])
                        p += 2
                        guard n <= b.count - p else { throw KaitoError.malformed("iso SL component") }
                        if flags & 0x30 != 0 { unresolvedLink = true }
                        if flags & 8 != 0 {
                            guard linkBytes.isEmpty, component.isEmpty else { throw KaitoError.malformed("iso SL root") }
                            linkBytes = [47]
                        } else {
                            if flags & 2 != 0 { component += [46] }
                            else if flags & 4 != 0 { component += [46, 46] }
                            else { component += b[p..<p+n] }
                            componentPending = flags & 1 != 0
                            if !componentPending {
                                if !linkBytes.isEmpty, linkBytes.last != 47 { linkBytes.append(47) }
                                linkBytes += component
                                component.removeAll(keepingCapacity: true)
                            }
                        }
                        p += n
                        guard linkBytes.count + component.count <= 4096 else { throw KaitoError.malformed("iso SL length") }
                    }
                    guard p == b.count else { throw KaitoError.malformed("iso SL component") }
                    linkDone = !linkPending
                case "TF" where length >= 5:
                    let width = b[4] & 128 == 0 ? 7 : 17
                    var p = 5
                    for bit in 0..<7 where b[4] & (1 << bit) != 0 {
                        guard p + width <= b.count else { break }
                        if bit == 1 { result.modified = ISOBytes.date(Array(b[p..<p+width]), long: width == 17) }
                        p += width
                    }
                case "RE": result.relocated = true
                case "CL" where length >= 12: result.child = ISOBytes.number(b, 4, width: 4)
                case "PL" where length >= 12: result.parent = ISOBytes.number(b, 4, width: 4)
                case "SF":
                    result.unsupported = "sparse"
                    if length >= 20 {
                        result.virtualSize = UInt64(ISOBytes.number(b, 4, width: 4)) << 32
                            | UInt64(ISOBytes.number(b, 12, width: 4))
                    }
                case "ZF": result.unsupported = "zisofs"
                default: break
                }
            }
            guard let (block, offset, length) = continuation else { break }
            ceCount += 1
            ceBytes = try Checked.add(ceBytes, UInt64(length))
            guard ceCount <= 8, ceBytes <= 65536, length >= 4,
                  UInt64(offset) + UInt64(length) <= 2048 else { throw KaitoError.malformed("iso CE chain") }
            let range = try volume.range(lba: block, length: UInt64(offset) + UInt64(length))
            let start = try Checked.add(range.offset, UInt64(offset))
            guard visited.insert(start).inserted else { throw KaitoError.malformed("iso CE chain") }
            try Checked.size(UInt64(length), limit: budget.limits.maxMetadataSize)
            try budget.charge(UInt64(length))
            area = try readByteRange(source: source, offset: start, count: Int(length))
        }
        guard !namePending, !linkPending, !componentPending else { throw KaitoError.malformed("iso unfinished NM/SL") }
        if linkSeen, !unresolvedLink {
            guard !linkBytes.contains(0) else { throw KaitoError.malformed("iso SL NUL") }
            result.link = linkBytes
        } else if unresolvedLink { result.unsupported = "SL implementation-specific component" }
        return result
    }
}
