// Clean-room format inputs: 指定レポート Ch.00・06 の MacBinary、AppleSingle/Double、BinHex の散文に基づく。
// XADMaster / The Unarchiver / stuffit-go 等の実装ソースは参照していない。
import Foundation

struct StuffItEnvelope {
    let data: any ByteSource
    let resource: (any ByteSource)?
}

enum StuffItWrapper {
    static func xmodem(_ bytes: some Sequence<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = (crc & 0x8000 == 0) ? crc << 1 : (crc << 1) ^ 0x1021 }
        }
        return crc
    }
    static func region(_ source: any ByteSource, offset: UInt64, length: UInt64) throws -> any ByteSource {
        // RebasedByteSource の原点を data fork に合わせ、末尾の resource/padding も不可視にする。
        let rebased = try RebasedByteSource(source: source, baseOffset: offset)
        return try BoundedByteSource(source: rebased, baseOffset: 0, length: length)
    }
    static func unwrap(source: any ByteSource, prefix: [UInt8], limits: ReadLimits) throws -> StuffItEnvelope? {
        if prefix.count >= 4 {
            let magic = StuffItHeader.be32(prefix, 0)
            if magic == 0x00051607 || magic == 0x07160500 { throw KaitoError.unsupportedFormat }
            if magic == 0x00051600 || magic == 0x00160500 {
                return try appleSingle(source, littleEndian: magic == 0x00160500, limits: limits)
            }
        }
        if let wrapped = try macBinary(source, prefix: prefix) { return wrapped }
        let scan = try readByteRange(source: source, offset: 0, count: Int(min(source.length, 65_536)))
        let marker = Array("(This file must be converted with BinHex".utf8)
        if scan.count >= marker.count {
            for p in 0...scan.count - marker.count where scan[p] == marker[0] {
                if scan[p..<p + marker.count].elementsEqual(marker) {
                    return try binHex(source, offset: UInt64(p + marker.count), limits: limits)
                }
            }
        }
        return nil
    }
    private static func macBinary(_ source: any ByteSource, prefix b: [UInt8]) throws -> StuffItEnvelope? {
        guard b.count >= 128, b[0] == 0, (1...63).contains(b[1]), b[74] == 0, b[82] == 0,
              b[108..<116].allSatisfy({ $0 == 0 }), !b[2..<2 + Int(b[1])].contains(0) else { return nil }
        let dataSize = StuffItHeader.be32(b, 83), resourceSize = StuffItHeader.be32(b, 87)
        let expected = StuffItHeader.be16(b, 124)
        let xcrc = xmodem(b[0..<124])
        let usb = b.withUnsafeBytes { CRC16.update(UnsafeRawBufferPointer(rebasing: $0[..<124]), initial: 0xffff, folding: false) } ^ 0xffff
        if expected != xcrc && expected != usb {
            guard b[99..<126].allSatisfy({ $0 == 0 }), dataSize <= 0x7fffffff, resourceSize <= 0x7fffffff,
                  StuffItHeader.be32(b, 91) != 0, StuffItHeader.be32(b, 95) != 0 else { return nil }
        }
        let secondary = UInt64(StuffItHeader.be16(b, 120))
        let dataOffset = 128 + ((secondary + 127) & ~UInt64(127))
        let resourceOffset = try Checked.add(dataOffset, (dataSize + 127) & ~UInt64(127))
        return try StuffItEnvelope(data: region(source, offset: dataOffset, length: dataSize),
                                  resource: resourceSize == 0 ? nil : region(source, offset: resourceOffset, length: resourceSize))
    }
    private static func appleSingle(_ source: any ByteSource, littleEndian: Bool, limits: ReadLimits) throws -> StuffItEnvelope {
        let header = try readByteRange(source: source, offset: 0, count: 26)
        let version = StuffItHeader.be32(header, 4)
        guard version == 0x00020000 || version == 0x00000200 else { throw KaitoError.unsupportedFormat }
        func integer(_ b: [UInt8], _ p: Int, _ n: Int) -> UInt64 {
            var result: UInt64 = 0
            for i in 0..<n { result = result << 8 | UInt64(b[p + (littleEndian ? n - i - 1 : i)]) }
            return result
        }
        let count = Int(integer(header, 24, 2))
        guard count <= limits.maxMetadataRecordCount else { throw KaitoError.limitExceeded("AppleSingle descriptors") }
        try Checked.size(UInt64(count * 12), limit: limits.maxMetadataSize)
        let descriptors = try readByteRange(source: source, offset: 26, count: count * 12)
        let bodyStart = UInt64(26 + count * 12)
        var data: (any ByteSource)?, resource: (any ByteSource)?
        for p in stride(from: 0, to: descriptors.count, by: 12) {
            let id = integer(descriptors, p, 4), offset = integer(descriptors, p + 4, 4), length = integer(descriptors, p + 8, 4)
            guard offset >= bodyStart, try Checked.add(offset, length) <= source.length else {
                throw KaitoError.malformed("AppleSingle descriptor extent")
            }
            if id == 1 {
                guard data == nil else { throw KaitoError.malformed("AppleSingle duplicate data fork") }
                data = try region(source, offset: offset, length: length)
            } else if id == 2 {
                guard resource == nil else { throw KaitoError.malformed("AppleSingle duplicate resource fork") }
                resource = try region(source, offset: offset, length: length)
            }
        }
        guard let data else { throw KaitoError.unsupportedFormat }
        return StuffItEnvelope(data: data, resource: resource)
    }
    private static func binHex(_ source: any ByteSource, offset: UInt64, limits: ReadLimits) throws -> StuffItEnvelope {
        let input = try StuffItPackedInput(source: source, offset: offset, size: source.length - offset)
        func whitespace(_ byte: UInt8) -> Bool { byte == 32 || (9...13).contains(byte) }
        var previousSpace = false
        while true {
            let byte = try input.byte()
            if byte == 58 && previousSpace { break }
            previousSpace = whitespace(byte)
        }
        let alphabet = Array("!\"#$%&'()*+,-012345689@ABCDEFGHIJKLMNPQRSTUVXYZ[`abcdefhijklmpqr".utf8)
        var lookup = [Int](repeating: -1, count: 256)
        for (i, byte) in alphabet.enumerated() { lookup[Int(byte)] = i }
        var output = Data()
        var bits = 0, pending = 0
        var escape = false
        var remembered: UInt8 = 0
        while true {
            let encoded = try input.byte()
            if encoded == 58 { break }
            let value = lookup[Int(encoded)]
            if value < 0 {
                guard whitespace(encoded) else { throw KaitoError.malformed("BinHex alphabet") }
                continue
            }
            pending = (pending << 6) | value; bits += 6
            if bits < 8 { continue }
            bits -= 8
            let byte = UInt8((pending >> bits) & 255)
            pending &= (1 << bits) - 1
            var count = 1
            var literal = byte
            if escape {
                escape = false
                guard byte != 1 else { throw KaitoError.malformed("BinHex RLE90 count 1") }
                if byte == 0 { literal = 0x90; remembered = literal }
                else { literal = remembered; count = Int(byte) - 1 }
            } else if byte == 0x90 { escape = true; continue }
            else { remembered = literal }
            try Checked.size(Checked.add(UInt64(output.count), UInt64(count)), limit: limits.maxInMemorySize)
            for _ in 0..<count { output.append(literal) }
        }
        guard !escape else { throw KaitoError.truncated }
        guard let n = output.first, (1...63).contains(n) else { throw KaitoError.malformed("BinHex filename length") }
        let headerLength = Int(n) + 20
        guard output.count >= headerLength + 2 else { throw KaitoError.truncated }
        let h = Array(output[..<(headerLength + 2)])
        guard xmodem(h[..<headerLength]) == StuffItHeader.be16(h, headerLength) else { throw KaitoError.malformed("BinHex header CRC") }
        let d = StuffItHeader.be32(h, Int(n) + 12), r = StuffItHeader.be32(h, Int(n) + 16)
        let dataOffset = headerLength + 2
        let resourceOffset = try Checked.toInt(Checked.add(UInt64(dataOffset + 2), d))
        let end = try Checked.toInt(Checked.add(UInt64(resourceOffset + 2), r))
        guard end <= output.count else { throw KaitoError.truncated }
        // 実コーパスの 6-bit transport は最後の組をゼロで埋め、CRC の後に 1〜2 octet 残す。
        guard output.count - end <= 2, output[end...].allSatisfy({ $0 == 0 }) else {
            throw KaitoError.malformed("BinHex trailing decoded bytes")
        }
        func crc(at p: Int) -> UInt16 { UInt16(output[p]) << 8 | UInt16(output[p + 1]) }
        guard xmodem(output[dataOffset..<resourceOffset - 2]) == crc(at: resourceOffset - 2),
              xmodem(output[resourceOffset..<end - 2]) == crc(at: end - 2) else { throw KaitoError.malformed("BinHex fork CRC") }
        let decoded = DataByteSource(data: output)
        return try StuffItEnvelope(data: region(decoded, offset: UInt64(dataOffset), length: d),
                                  resource: r == 0 ? nil : region(decoded, offset: UInt64(resourceOffset), length: r))
    }
}
