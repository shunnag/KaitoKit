import Foundation

// ECMA-119 / SUSP / RRIP の公開 field table から組み立てる test-only writer。
// 外部 writer/reader の実装 source から導出していない。
struct ISOImageBuilder {
    var data: Data
    let blockSize: Int
    var nextSector = 22
    var rootLBA: UInt32 { lba(20) }
    var jolietLBA: UInt32 { lba(21) }

    init(blockSize: Int = 2048, joliet: Bool = false, sectors: Int = 32) {
        self.blockSize = blockSize
        data = Data(repeating: 0, count: sectors * 2048)
        descriptor(16, type: 1, root: rootLBA)
        if joliet { descriptor(17, type: 2, root: jolietLBA) }
        descriptor(joliet ? 18 : 17, type: 255, root: rootLBA)
    }

    func lba(_ sector: Int) -> UInt32 { UInt32(sector * 2048 / blockSize) }

    mutating func descriptor(_ sector: Int, type: UInt8, root: UInt32) {
        var b = [UInt8](repeating: 0, count: 2048)
        b[0] = type; b.replaceSubrange(1..<6, with: "CD001".utf8); b[6] = 1
        Self.both(&b, 80, UInt32(data.count / blockSize))
        Self.both(&b, 120, 1, width: 2); Self.both(&b, 124, 1, width: 2)
        Self.both(&b, 128, UInt32(blockSize), width: 2)
        b.replaceSubrange(156..<190, with: Self.record([0], lba: root, length: 2048, flags: 2))
        b[881] = 1
        if type == 2 { b.replaceSubrange(88..<91, with: [37, 47, 64]) }
        write(b, at: sector * 2048)
    }

    mutating func write(_ bytes: [UInt8], at offset: Int) {
        precondition(offset >= 0 && offset + bytes.count <= data.count)
        data.replaceSubrange(offset..<offset+bytes.count, with: bytes)
    }

    mutating func root(_ records: [[UInt8]], systemUse: [UInt8] = [], joliet: Bool = false, length: Int = 2048, ea: UInt8 = 0) {
        let lba = joliet ? jolietLBA : rootLBA
        write([UInt8](repeating: 0, count: length), at: (Int(lba) + Int(ea)) * blockSize)
        let dot = Self.record([0], lba: lba, length: UInt32(length), flags: 2, ea: ea, su: systemUse)
        directory(lba, [dot, Self.record([1], lba: lba, length: UInt32(length), flags: 2)] + records, ea: ea)
        write(Self.record([0], lba: lba, length: UInt32(length), flags: 2, ea: ea), at: (joliet ? 17 : 16) * 2048 + 156)
    }

    mutating func directory(_ lba: UInt32, _ records: [[UInt8]], ea: UInt8 = 0) {
        var offset = (Int(lba) + Int(ea)) * blockSize
        for record in records {
            if offset % 2048 + record.count > 2048 { offset += 2048 - offset % 2048 }
            write(record, at: offset)
            offset += record.count
        }
    }

    mutating func file(_ name: String, payload: [UInt8] = Array("payload".utf8), su: [UInt8] = [], flags: UInt8 = 0, ea: UInt8 = 0) -> [UInt8] {
        let lba = lba(nextSector)
        nextSector += max(1, (Int(ea) * blockSize + payload.count + 2047) / 2048)
        write(payload, at: (Int(lba) + Int(ea)) * blockSize)
        return Self.record(Array(name.utf8), lba: lba, length: UInt32(payload.count), flags: flags, ea: ea, su: su)
    }

    static func both(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32, width: Int = 4) {
        for i in 0..<width {
            bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i))
            bytes[offset + 2 * width - 1 - i] = bytes[offset + i]
        }
    }

    static func record(_ name: [UInt8], lba: UInt32, length: UInt32 = 0, flags: UInt8 = 0,
                       ea: UInt8 = 0, su: [UInt8] = [], unit: UInt8 = 0, sequence: UInt32 = 1) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 33 + name.count + (name.count % 2 == 0 ? 1 : 0))
        b[1] = ea; both(&b, 2, lba); both(&b, 10, length)
        b.replaceSubrange(18..<25, with: [126, 9, 9, 12, 30, 0, 0])
        b[25] = flags; b[26] = unit; both(&b, 28, sequence, width: 2)
        b[32] = UInt8(name.count); b.replaceSubrange(33..<33+name.count, with: name)
        b += su
        if b.count % 2 != 0 { b.append(0) }
        b[0] = UInt8(b.count)
        return b
    }

    static func su(_ signature: String, _ payload: [UInt8] = []) -> [UInt8] {
        Array(signature.utf8) + [UInt8(payload.count + 4), 1] + payload
    }
    static func sp(_ skip: UInt8 = 0) -> [UInt8] { su("SP", [190, 239, skip]) }
    static func nm(_ name: String, flags: UInt8 = 0) -> [UInt8] { su("NM", [flags] + name.utf8) }
    static func numberEntry(_ signature: String, _ number: UInt32) -> [UInt8] {
        var b = su(signature, [UInt8](repeating: 0, count: 8)); both(&b, 4, number); return b
    }
    static func ce(_ lba: UInt32, offset: UInt32 = 0, length: UInt32) -> [UInt8] {
        var b = su("CE", [UInt8](repeating: 0, count: 24))
        both(&b, 4, lba); both(&b, 12, offset); both(&b, 20, length); return b
    }
    static func px(_ mode: UInt32, old: Bool = false) -> [UInt8] {
        var b = su("PX", [UInt8](repeating: 0, count: old ? 32 : 40)); both(&b, 4, mode); return b
    }
    static func ucs2(_ name: String) -> [UInt8] {
        name.utf16.flatMap { [UInt8($0 >> 8), UInt8(truncatingIfNeeded: $0)] }
    }
}
