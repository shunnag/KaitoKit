import Foundation

// ECMA-119 の公開仕様 (offset は 0-based)。両 endian の不一致は診断に残し LE を採用する。
enum ISOBytes {
    static func number(_ b: [UInt8], _ o: Int, width: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<width { value |= UInt32(b[o + i]) << (i * 8) }
        return value
    }

    static func mismatch(_ b: [UInt8], _ o: Int, width: Int) -> Bool {
        (0..<width).contains { b[o + $0] != b[o + width * 2 - 1 - $0] }
    }

    static func date(_ b: [UInt8], long: Bool = false) -> Date? {
        guard b.count >= (long ? 17 : 7) else { return nil }
        let fields: [Int]
        var fraction = 0.0
        if long {
            guard b.prefix(16).allSatisfy({ (48...57).contains($0) }) else { return nil }
            func digits(_ o: Int, _ n: Int) -> Int {
                b[o..<o+n].reduce(0) { $0 * 10 + Int($1 - 48) }
            }
            fields = [digits(0, 4), digits(4, 2), digits(6, 2), digits(8, 2), digits(10, 2), digits(12, 2)]
            fraction = Double(digits(14, 2)) / 100
        } else {
            fields = [1900 + Int(b[0])] + b[1..<6].map(Int.init)
        }
        let zone = Int(Int8(bitPattern: b[long ? 16 : 6]))
        guard fields[0] > 0, (1...12).contains(fields[1]), (1...31).contains(fields[2]),
              (0...23).contains(fields[3]), (0...59).contains(fields[4]),
              (0...59).contains(fields[5]), (-48...52).contains(zone) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: fields[0], month: fields[1], day: fields[2],
                                        hour: fields[3], minute: fields[4], second: fields[5])
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == fields[2] else { return nil }
        return date.addingTimeInterval(fraction - Double(zone * 900))
    }

    static func joliet(_ b: [UInt8]) -> String {
        let units = stride(from: 0, to: b.count - b.count % 2, by: 2).map {
            UInt16(b[$0]) << 8 | UInt16(b[$0 + 1])
        }
        return String(decoding: units, as: UTF16.self)
    }
}

struct ISODirectoryRecord {
    let lba: UInt32
    let ea: UInt8
    let length: UInt32
    let flags: UInt8
    let unit: UInt8
    let sequence: UInt32
    let identifier: [UInt8]
    let systemUse: [UInt8]
    let date: Date?
    let mismatch: Bool
    var special: Bool { identifier == [0] || identifier == [1] }

    init(_ b: [UInt8]) throws {
        guard b.count >= 34, Int(b[0]) == b.count else { throw KaitoError.malformed("iso directory record") }
        let nameEnd = 33 + Int(b[32])
        let start = nameEnd + (b[32] % 2 == 0 ? 1 : 0)
        guard b[32] > 0, start <= b.count else { throw KaitoError.malformed("iso identifier length") }
        lba = ISOBytes.number(b, 2, width: 4)
        ea = b[1]
        length = ISOBytes.number(b, 10, width: 4)
        flags = b[25]
        unit = b[26]
        sequence = ISOBytes.number(b, 28, width: 2)
        identifier = Array(b[33..<nameEnd])
        systemUse = Array(b[start...])
        date = ISOBytes.date(Array(b[18..<25]))
        mismatch = ISOBytes.mismatch(b, 2, width: 4) || ISOBytes.mismatch(b, 10, width: 4)
            || ISOBytes.mismatch(b, 28, width: 2)
    }
}

struct ISOVolume {
    let blockSize: UInt64
    let blocks: UInt32
    let limit: UInt64
    let sequence: UInt32
    let setSize: UInt32
    let root: ISODirectoryRecord
    let mismatch: Bool

    init(_ b: [UInt8], sourceLength: UInt64) throws {
        blockSize = UInt64(ISOBytes.number(b, 128, width: 2))
        guard [512, 1024, 2048].contains(blockSize) else { throw KaitoError.malformed("iso logical block size") }
        blocks = ISOBytes.number(b, 80, width: 4)
        limit = min(try Checked.mul(UInt64(blocks), blockSize), sourceLength)
        sequence = ISOBytes.number(b, 124, width: 2)
        setSize = ISOBytes.number(b, 120, width: 2)
        root = try ISODirectoryRecord(Array(b[156..<190]))
        guard root.identifier == [0], root.flags & 2 != 0 else { throw KaitoError.malformed("iso root directory") }
        mismatch = ISOBytes.mismatch(b, 80, width: 4)
            || [120, 124, 128].contains { ISOBytes.mismatch(b, $0, width: 2) } || root.mismatch
    }

    func range(lba: UInt32, ea: UInt8 = 0, length: UInt64) throws -> ISOSection {
        guard lba < blocks else { throw KaitoError.truncated }
        let offset = try Checked.mul(try Checked.add(UInt64(lba), UInt64(ea)), blockSize)
        guard try Checked.add(offset, length) <= limit else { throw KaitoError.truncated }
        return ISOSection(offset: offset, length: length)
    }
}

// 二つの木の走査・discard した候補にも共通の予算を使う。
final class ISOMetadataBudget {
    let limits: ReadLimits
    private var total: UInt64 = 0
    init(_ limits: ReadLimits) { self.limits = limits }
    func charge(_ bytes: UInt64) throws {
        total = try Checked.add(total, bytes)
        try Checked.size(total, limit: limits.maxTotalMetadataSize)
    }
}
