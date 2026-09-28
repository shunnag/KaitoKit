import Foundation

// [MS-CFB] の on-disk 構造: header（§2.2）と directory entry（§2.6.1）。出典は CFBReader.swift の先頭。

enum CFBBytes {
    static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { LittleEndian.uint16(b, at: o) }
    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 { LittleEndian.uint32(b, at: o) }
    static func u64(_ b: [UInt8], _ o: Int) -> UInt64 { LittleEndian.uint64(b, at: o) }

    /// §2.6.1 directory entry の Creation / Modified Time（FILETIME）。0 は未設定、符号 bit が立つ値は捨てる。
    static func fileTime(_ value: UInt64) -> Date? {
        guard value != 0, value < 0x8000_0000_0000_0000 else { return nil }
        return WindowsFileTime.date(ticks: value)
    }
}

/// §2.2 の header（512 byte）。
struct CFBHeader {
    static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    static let size = 512
    static let headerDIFATEntries = 109
    // §2.1 の予約 sector 番号。
    static let maxRegularSector: UInt32 = 0xFFFF_FFFA
    static let difatSector: UInt32 = 0xFFFF_FFFC
    static let fatSector: UInt32 = 0xFFFF_FFFD
    static let endOfChain: UInt32 = 0xFFFF_FFFE
    static let freeSector: UInt32 = 0xFFFF_FFFF
    static let noStream: UInt32 = 0xFFFF_FFFF

    let majorVersion: UInt16
    let sectorShift: Int
    let miniSectorShift: Int
    let directorySectorCount: UInt32
    let fatSectorCount: UInt32
    let firstDirectorySector: UInt32
    let miniStreamCutoff: UInt32
    let firstMiniFATSector: UInt32
    let miniFATSectorCount: UInt32
    let firstDIFATSector: UInt32
    let difatSectorCount: UInt32
    let headerDIFAT: [UInt32]

    var sectorSize: Int { 1 << sectorShift }
    var miniSectorSize: Int { 1 << miniSectorShift }

    init(_ b: [UInt8]) throws {
        guard b.count >= Self.size else { throw KaitoError.truncated }
        guard Array(b[0..<8]) == Self.signature else { throw KaitoError.unsupportedFormat }
        majorVersion = CFBBytes.u16(b, 26)
        guard CFBBytes.u16(b, 28) == 0xFFFE else { throw KaitoError.malformed("cfb byte order") }
        let shift = Int(CFBBytes.u16(b, 30))
        switch (majorVersion, shift) {
        case (3, 9), (4, 12): sectorShift = shift
        default: throw KaitoError.unsupportedFormat
        }
        miniSectorShift = Int(CFBBytes.u16(b, 32))
        guard miniSectorShift == 6 else { throw KaitoError.malformed("cfb mini sector shift \(miniSectorShift)") }
        directorySectorCount = CFBBytes.u32(b, 40)
        fatSectorCount = CFBBytes.u32(b, 44)
        firstDirectorySector = CFBBytes.u32(b, 48)
        miniStreamCutoff = CFBBytes.u32(b, 56)
        guard miniStreamCutoff == 4096 else { throw KaitoError.malformed("cfb mini stream cutoff \(miniStreamCutoff)") }
        firstMiniFATSector = CFBBytes.u32(b, 60)
        miniFATSectorCount = CFBBytes.u32(b, 64)
        firstDIFATSector = CFBBytes.u32(b, 68)
        difatSectorCount = CFBBytes.u32(b, 72)
        headerDIFAT = (0..<Self.headerDIFATEntries).map { CFBBytes.u32(b, 76 + $0 * 4) }
    }
}

/// §2.6.1 の directory entry（128 byte）。
struct CFBDirectoryEntry {
    static let size = 128
    enum ObjectType: UInt8 { case unallocated = 0, storage = 1, stream = 2, root = 5 }

    let name: String
    let type: ObjectType
    let leftSibling: UInt32
    let rightSibling: UInt32
    let child: UInt32
    let clsid: [UInt8]
    let created: UInt64
    let modified: UInt64
    let startSector: UInt32
    let size: UInt64

    init(_ b: [UInt8], _ o: Int, majorVersion: UInt16) throws {
        guard let type = ObjectType(rawValue: b[o + 66]) else { throw KaitoError.malformed("cfb directory entry type \(b[o + 66])") }
        self.type = type
        let nameLength = Int(CFBBytes.u16(b, o + 64))
        guard nameLength <= 64, nameLength % 2 == 0 else { throw KaitoError.malformed("cfb directory entry name length \(nameLength)") }
        // 終端の null を除く UTF-16LE。unallocated entry は名前が空。
        var units: [UInt16] = []
        var index = 0
        while index + 1 < nameLength {
            let unit = CFBBytes.u16(b, o + index)
            if unit == 0 { break }
            units.append(unit)
            index += 2
        }
        name = String(decoding: units, as: UTF16.self)
        leftSibling = CFBBytes.u32(b, o + 68)
        rightSibling = CFBBytes.u32(b, o + 72)
        child = CFBBytes.u32(b, o + 76)
        clsid = Array(b[(o + 80)..<(o + 96)])
        created = CFBBytes.u64(b, o + 100)
        modified = CFBBytes.u64(b, o + 108)
        startSector = CFBBytes.u32(b, o + 116)
        // §2.6.3: version 3 では上位 32 bit が未初期化のことがあるので下位だけを使う。
        size = majorVersion == 3 ? UInt64(CFBBytes.u32(b, o + 120)) : CFBBytes.u64(b, o + 120)
    }

    /// CLSID を registry 形式（`{xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}`）で。全 0 なら nil。
    var clsidString: String? {
        guard clsid.contains(where: { $0 != 0 }) else { return nil }
        let a = String(format: "%08X", CFBBytes.u32(clsid, 0))
        let bPart = String(format: "%04X", CFBBytes.u16(clsid, 4))
        let c = String(format: "%04X", CFBBytes.u16(clsid, 6))
        let d = clsid[8..<10].map { String(format: "%02X", $0) }.joined()
        let e = clsid[10..<16].map { String(format: "%02X", $0) }.joined()
        return "{\(a)-\(bPart)-\(c)-\(d)-\(e)}"
    }
}
