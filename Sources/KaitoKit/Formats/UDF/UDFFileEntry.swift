import Foundation

/// 4/14.9 File Entry（tag 261）と 4/14.17 Extended File Entry（tag 266）の共通ビュー。
struct UDFFileEntry {
    let isExtended: Bool
    /// 4/14.6 icbtag。
    let strategyType: UInt16
    let fileType: UInt8
    let flags: UInt16
    let uid: UInt32
    let gid: UInt32
    let permissions: UInt32
    let linkCount: UInt16
    let informationLength: UInt64
    let modificationDate: Date?
    /// EFE だけが持つ stream directory の ICB（長さ 0 は無し）。
    let streamDirectory: UDFAllocation?
    let uniqueID: UInt64
    let allocationDescriptors: [UInt8]

    /// icbtag flags bit 0〜2: 0 short_ad、1 long_ad、2 ext_ad、3 inline data。
    var allocationType: UInt8 { UInt8(flags & 7) }

    init(_ b: [UInt8], tag: UDFTag, blockSize: Int) throws {
        guard b.count >= 176 else { throw KaitoError.truncated }
        isExtended = tag.identifier == 266
        strategyType = UDFBytes.u16(b, 20)
        fileType = b[27]
        flags = UDFBytes.u16(b, 34)
        uid = UDFBytes.u32(b, 36)
        gid = UDFBytes.u32(b, 40)
        permissions = UDFBytes.u32(b, 44)
        linkCount = UDFBytes.u16(b, 48)
        informationLength = UDFBytes.u64(b, 56)
        uniqueID = UDFBytes.u64(b, isExtended ? 200 : 160)
        let extendedAttributesLength: Int
        let allocationLength: Int
        let descriptorsOffset: Int
        if isExtended {
            guard b.count >= 216 else { throw KaitoError.truncated }
            modificationDate = UDFBytes.timestamp(b, 92)
            let stream = UDFAllocation.long(b, 152)
            streamDirectory = stream.length > 0 ? stream : nil
            extendedAttributesLength = Int(UDFBytes.u32(b, 208))
            allocationLength = Int(UDFBytes.u32(b, 212))
            descriptorsOffset = 216
        } else {
            modificationDate = UDFBytes.timestamp(b, 84)
            streamDirectory = nil
            extendedAttributesLength = Int(UDFBytes.u32(b, 168))
            allocationLength = Int(UDFBytes.u32(b, 172))
            descriptorsOffset = 176
        }
        // 4/13: FE は 1 論理 block に収まる。EA は読み飛ばす。
        guard extendedAttributesLength <= blockSize - descriptorsOffset,
              allocationLength <= blockSize - descriptorsOffset - extendedAttributesLength else {
            throw KaitoError.malformed("udf file entry lengths exceed the block")
        }
        let start = descriptorsOffset + extendedAttributesLength
        allocationDescriptors = Array(b[start..<(start + allocationLength)])
    }

    /// 4/14.9.5 permissions（other 0〜4、group 5〜9、owner 10〜14 の execute / write / read / chattr / delete）と
    /// icbtag flags bit 6〜8（setuid / setgid / sticky）を POSIX mode bits に写す。
    var posixPermissions: UInt16 {
        func triplet(_ shift: Int) -> UInt16 {
            let bits = UInt16((permissions >> UInt32(shift)) & 0x7)
            // UDF の bit 0 = execute、1 = write、2 = read は POSIX の x = 1、w = 2、r = 4 と同じ並び。
            return bits
        }
        var mode = triplet(10) << 6 | triplet(5) << 3 | triplet(0)
        if flags & 0x40 != 0 { mode |= 0o4000 }
        if flags & 0x80 != 0 { mode |= 0o2000 }
        if flags & 0x100 != 0 { mode |= 0o1000 }
        return mode
    }
}

/// 4/14.4 File Identifier Descriptor（tag 257）。
struct UDFFileIdentifier {
    let characteristics: UInt8
    let icb: UDFAllocation
    let name: String
    let totalLength: Int

    var isParent: Bool { characteristics & 0x08 != 0 }
    var isDeleted: Bool { characteristics & 0x04 != 0 }
    var isDirectory: Bool { characteristics & 0x02 != 0 }
    var isHidden: Bool { characteristics & 0x01 != 0 }
    var isMetadataStream: Bool { characteristics & 0x10 != 0 }

    /// `bytes[offset...]` から 1 つ解釈する。`location` は FID の先頭 byte を含む論理 block の番号。
    static func parse(_ bytes: [UInt8], offset: Int, location: UInt32) throws -> UDFFileIdentifier? {
        guard offset + 38 <= bytes.count else { return nil }
        // tag identifier 0 は未記録領域: directory の終端として扱う。
        if UDFBytes.u16(bytes, offset) == 0 { return nil }
        let identifierLength = Int(bytes[offset + 19])
        let implementationLength = Int(UDFBytes.u16(bytes, offset + 36))
        let raw = 38 + implementationLength + identifierLength
        let total = (raw + 3) / 4 * 4
        guard offset + total <= bytes.count else { throw KaitoError.truncated }
        let descriptor = Array(bytes[offset..<(offset + total)])
        guard let verified = try UDFTag.parse(descriptor, expectedLocation: location, label: "file identifier"),
              verified.identifier == 257 else {
            throw KaitoError.malformed("udf file identifier tag")
        }
        let characteristics = bytes[offset + 18]
        let nameStart = offset + 38 + implementationLength
        let nameBytes = bytes[nameStart..<(nameStart + identifierLength)]
        let name: String
        if identifierLength == 0 {
            guard characteristics & 0x08 != 0 || characteristics & 0x04 != 0 else {
                throw KaitoError.malformed("udf file identifier without a name")
            }
            name = ""
        } else {
            guard let decoded = UDFBytes.compressedUnicode(nameBytes) else {
                throw KaitoError.malformed("udf file identifier compression")
            }
            name = decoded
        }
        return UDFFileIdentifier(characteristics: characteristics, icb: UDFAllocation.long(bytes, offset + 20),
                                 name: name, totalLength: total)
    }
}
