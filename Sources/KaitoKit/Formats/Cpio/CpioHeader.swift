import Foundation

// 公開 cpio interchange format の byte 表に基づくヘッダ解析。
enum CpioVariant: String {
    case newc, crc, odc
    case binLittle = "bin-le", binBig = "bin-be"

    var headerSize: UInt64 {
        switch self {
        case .newc, .crc: 110
        case .odc: 76
        case .binLittle, .binBig: 26
        }
    }
    var alignment: UInt64 {
        switch self {
        case .newc, .crc: 4
        case .odc: 1
        case .binLittle, .binBig: 2
        }
    }
    var isBinary: Bool { self == .binLittle || self == .binBig }
}

struct CpioHeader {
    let variant: CpioVariant
    let mode, uid, gid, nlink: UInt32
    let dev, ino, mtime, fileSize, nameSize: UInt64
    let check: UInt32
    let rawRdev: [UInt8]

    static func variant(_ bytes: [UInt8]) -> CpioVariant? {
        if bytes.starts(with: [0xC7, 0x71]) { return .binLittle }
        if bytes.starts(with: [0x71, 0xC7]) { return .binBig }
        guard bytes.count >= 6 else { return nil }
        switch String(decoding: bytes.prefix(6), as: UTF8.self) {
        case "070701": return .newc
        case "070702": return .crc
        case "070707": return .odc
        default: return nil
        }
    }

    init(_ bytes: [UInt8]) throws {
        guard let variant = Self.variant(bytes) else { throw KaitoError.malformed("cpio header magic") }
        guard UInt64(bytes.count) >= variant.headerSize else { throw KaitoError.truncated }
        self.variant = variant
        func number(_ offset: Int, _ width: Int, _ radix: UInt64) throws -> UInt64 {
            var value: UInt64 = 0
            for byte in bytes[offset..<offset + width] {
                let digit: UInt64
                switch byte {
                case 48...57: digit = UInt64(byte - 48)
                case 65...70: digit = UInt64(byte - 65 + 10)
                case 97...102: digit = UInt64(byte - 97 + 10)
                default: throw KaitoError.malformed("cpio header field")
                }
                guard digit < radix else { throw KaitoError.malformed("cpio header field") }
                value = try Checked.add(Checked.mul(value, radix), digit)
            }
            return value
        }
        func word(_ offset: Int) -> UInt32 {
            let a = UInt32(bytes[offset]), b = UInt32(bytes[offset + 1])
            return variant == .binLittle ? a | (b << 8) : (a << 8) | b
        }
        // PDP / middle endian: 上位 word が先。各 16-bit word だけを検出 byte order で読む。
        func pdp(_ offset: Int) -> UInt64 { UInt64((word(offset) << 16) | word(offset + 2)) }
        switch variant {
        case .newc, .crc:
            let f = try stride(from: 6, to: 110, by: 8).map { try number($0, 8, 16) }
            ino = f[0]; mode = UInt32(f[1]); uid = UInt32(f[2]); gid = UInt32(f[3])
            nlink = UInt32(f[4]); mtime = f[5]; fileSize = f[6]
            dev = (f[7] << 32) | f[8]; nameSize = f[11]; check = UInt32(f[12])
            rawRdev = Array(bytes[78..<94])
        case .odc:
            let f = try stride(from: 6, to: 48, by: 6).map { try number($0, 6, 8) }
            dev = f[0]; ino = f[1]; mode = UInt32(f[2]); uid = UInt32(f[3]); gid = UInt32(f[4])
            nlink = UInt32(f[5]); mtime = try number(48, 11, 8)
            nameSize = try number(59, 6, 8); fileSize = try number(65, 11, 8); check = 0
            rawRdev = Array(bytes[42..<48])
        case .binLittle, .binBig:
            dev = UInt64(word(2)); ino = UInt64(word(4)); mode = word(6)
            uid = word(8); gid = word(10); nlink = word(12); mtime = pdp(16)
            nameSize = UInt64(word(20)); fileSize = pdp(22); check = 0
            rawRdev = Array(bytes[14..<16])
            guard fileSize < 0x8000_0000 else { throw KaitoError.malformed("cpio binary filesize is negative") }
        }
    }

    static func read(source: any ByteSource, at offset: UInt64) throws -> CpioHeader {
        let prefix = try readByteRange(source: source, offset: offset,
                                      count: Checked.toInt(min(6, Checked.sub(source.length, offset))))
        guard let variant = variant(prefix) else {
            if prefix.count < 6 { throw KaitoError.truncated }
            throw KaitoError.malformed("cpio header magic")
        }
        return try CpioHeader(readByteRange(source: source, offset: offset, count: Int(variant.headerSize)))
    }

    func layout(at offset: UInt64) throws -> (name: UInt64, data: UInt64, next: UInt64) {
        let name = try Checked.add(offset, variant.headerSize)
        let relativeEnd = try Checked.add(variant.headerSize, nameSize)
        let namePadding = (variant.alignment - relativeEnd % variant.alignment) % variant.alignment
        let data = try Checked.add(Checked.add(name, nameSize), namePadding)
        let dataPadding = (variant.alignment - fileSize % variant.alignment) % variant.alignment
        let next = try Checked.add(Checked.add(data, fileSize), dataPadding)
        return (name, data, next)
    }

    func readName(source: any ByteSource, at offset: UInt64, limit: UInt64) throws -> [UInt8] {
        guard nameSize >= 2 else { throw KaitoError.malformed("cpio name size") }
        guard nameSize <= CpioReader.maximumNameSize else { throw KaitoError.limitExceeded("cpio name size") }
        try Checked.size(nameSize, limit: limit)
        let bytes = try readByteRange(source: source, offset: offset, count: Checked.toInt(nameSize))
        guard let nul = bytes.firstIndex(of: 0), nul > 0,
              bytes[nul...].allSatisfy({ $0 == 0 }) else {
            throw KaitoError.malformed("cpio name is not terminated")
        }
        return Array(bytes[..<nul])
    }

    private static func plausible(source: any ByteSource, at offset: UInt64) throws -> (CpioHeader, [UInt8], UInt64) {
        let header = try read(source: source, at: offset)
        guard [0, 0o010000, 0o020000, 0o040000, 0o060000, 0o100000, 0o120000, 0o140000]
            .contains(header.mode & 0o170000) else { throw KaitoError.malformed("cpio mode") }
        let layout = try header.layout(at: offset)
        guard layout.next <= source.length else { throw KaitoError.truncated }
        let name = try header.readName(source: source, at: layout.name, limit: CpioReader.maximumNameSize)
        return (header, name, layout.next)
    }

    static func probe(_ prefix: [UInt8], source: any ByteSource) -> CpioVariant? {
        guard let variant = variant(prefix), !variant.isBinary else { return nil }
        return (try? plausible(source: source, at: 0))?.0.variant
    }

    static func probeBinary(source: any ByteSource, recoverDamagedArchives: Bool = false) -> Bool {
        do {
            var offset: UInt64 = 0
            for index in 0..<4 {
                let candidate: (CpioHeader, [UInt8], UInt64)
                do { candidate = try plausible(source: source, at: offset) }
                catch KaitoError.truncated {
                    // 既定では到達しない救済分岐。最低2個の完全な record が先行すること。
                    if recoverDamagedArchives && index >= 2 {
                        return (try? isTruncatedBinaryRecord(source: source, at: offset)) == true
                    }
                    return false
                }
                let (header, name, next) = candidate
                if index == 0, !header.variant.isBinary { return false }
                if name == Array("TRAILER!!!".utf8) { return true }
                guard let following = try CpioReader.skipNULRun(source: source, from: next) else { return false }
                if following == source.length { return true }
                offset = following
            }
            return true
        } catch { return false }
    }

    private static func isTruncatedBinaryRecord(source: any ByteSource, at offset: UInt64) throws -> Bool {
        let remaining = try Checked.sub(source.length, offset)
        let bytes = try readByteRange(source: source, offset: offset, count: Checked.toInt(min(26, remaining)))
        // EOFという理由だけで未知の短いごみを受理しない。binary magic 2 bytesは必須。
        guard let variant = variant(bytes), variant.isBinary else { return false }
        // 未到着のheader bytesは検証用にだけ0で埋める。recordとして公開・countしない。
        let header = try CpioHeader(bytes + Array(repeating: 0, count: 26 - bytes.count))
        guard [0, 0o010000, 0o020000, 0o040000, 0o060000, 0o100000, 0o120000, 0o140000]
            .contains(header.mode & 0o170000) else { return false }
        if bytes.count >= 22 {
            guard (2...CpioReader.maximumNameSize).contains(header.nameSize) else { return false }
        }
        if bytes.count < 26 { return true }
        let layout = try header.layout(at: offset)
        guard layout.next > source.length else { return false }
        let availableNameSize = min(header.nameSize, source.length - layout.name)
        let name = try readByteRange(source: source, offset: layout.name, count: Checked.toInt(availableNameSize))
        if let first = name.first, first == 0 { return false }
        if let nul = name.firstIndex(of: 0) {
            guard name[nul...].allSatisfy({ $0 == 0 }) else { return false }
        } else if availableNameSize == header.nameSize {
            return false
        }
        // header/nameの存在するbyteまで正常で、残りのname/padding/dataが物理EOFで欠けている。
        return true
    }

}
