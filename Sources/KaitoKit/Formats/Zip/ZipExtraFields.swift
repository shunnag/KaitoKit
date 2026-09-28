import Foundation

// extra field の分解と、中央 header・local header・復旧が共有する extra の解釈（ZIP64・Unicode path・日時）。
// APPNOTE §4.5 / §4.6。

/// header ID と本体に分けた一つの extra field。
struct ZipExtraField {
    let identifier: UInt16
    let data: [UInt8]
}

enum ZipExtraFields {
    /// 4 byte 未満の端数や、長さが残りを超える field が末尾にあるときの扱い。
    /// `.zeroPadding` は 0 だけの端数を許し（local header）、`.ignoreUnparsableTail` は解けない末尾を捨てる（中央 header）。
    enum TailPolicy {
        case strict
        case zeroPadding
        case ignoreUnparsableTail
    }

    /// extra 領域を field に分ける。field 数が `recordLimit` に達すると limitExceeded。
    static func parse(
        _ bytes: [UInt8],
        recordLimit: Int,
        tailPolicy: TailPolicy = .strict
    ) throws -> [ZipExtraField] {
        guard recordLimit >= 0 else {
            throw KaitoError.limitExceeded("ZIP extra-field record count")
        }
        var cursor = ZipByteCursor(bytes)
        var fields: [ZipExtraField] = []
        while cursor.remaining > 0 {
            guard cursor.remaining >= 4 else {
                switch tailPolicy {
                case .ignoreUnparsableTail:
                    return fields
                case .zeroPadding:
                    let tail = try cursor.readBytes(cursor.remaining)
                    guard tail.allSatisfy({ $0 == 0 }) else {
                        throw KaitoError.malformed("truncated ZIP extra-field header")
                    }
                    return fields
                case .strict:
                    break
                }
                throw KaitoError.malformed("truncated ZIP extra-field header")
            }
            guard fields.count < recordLimit else {
                throw KaitoError.limitExceeded("ZIP extra-field record count")
            }
            let identifier = try cursor.readUInt16LE()
            let length = Int(try cursor.readUInt16LE())
            guard length <= cursor.remaining else {
                if tailPolicy == .ignoreUnparsableTail {
                    return fields
                }
                throw KaitoError.malformed("ZIP extra field overruns its containing header")
            }
            fields.append(ZipExtraField(
                identifier: identifier,
                data: try cursor.readBytes(length)
            ))
        }
        return fields
    }

    /// 同じ ID が二つ以上あれば nil。
    static func unique(
        _ identifier: UInt16,
        in fields: [ZipExtraField]
    ) -> [UInt8]? {
        var result: [UInt8]?
        for field in fields where field.identifier == identifier {
            guard result == nil else { return nil }
            result = field.data
        }
        return result
    }

    /// ZIP64 extra で 0xFFFF / 0xFFFFFFFF の欄を置き換えた後の値。
    struct ZIP64Values {
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
        let diskStart: UInt32
    }

    /// 0xFFFFFFFF / 0xFFFF の欄だけを、ZIP64 extra から APPNOTE の順（展開後・圧縮後・offset・disk）に読む。
    static func resolveZIP64Values(
        compressed32: UInt32,
        uncompressed32: UInt32,
        localOffset32: UInt32,
        diskStart16: UInt16,
        fields: [ZipExtraField]
    ) throws -> ZIP64Values {
        let needsZIP64 = compressed32 == UInt32.max
            || uncompressed32 == UInt32.max
            || localOffset32 == UInt32.max
            || diskStart16 == UInt16.max
        guard needsZIP64 else {
            return ZIP64Values(
                compressedSize: UInt64(compressed32),
                uncompressedSize: UInt64(uncompressed32),
                localHeaderOffset: UInt64(localOffset32),
                diskStart: UInt32(diskStart16)
            )
        }
        guard let data = unique(ZipExtraFieldID.zip64, in: fields) else {
            throw KaitoError.malformed("ZIP64 central values are missing")
        }
        var cursor = ZipByteCursor(data)
        let uncompressed = uncompressed32 == UInt32.max
            ? try cursor.readUInt64LE() : UInt64(uncompressed32)
        let compressed = compressed32 == UInt32.max
            ? try cursor.readUInt64LE() : UInt64(compressed32)
        let local = localOffset32 == UInt32.max
            ? try cursor.readUInt64LE() : UInt64(localOffset32)
        let disk = diskStart16 == UInt16.max
            ? try cursor.readUInt32LE() : UInt32(diskStart16)
        return ZIP64Values(
            compressedSize: compressed,
            uncompressedSize: uncompressed,
            localHeaderOffset: local,
            diskStart: disk
        )
    }

    /// Info-ZIP Unicode Path extra（version 1）。元の名前の CRC-32 が一致するときだけ UTF-8 名を返す。
    static func unicodePath(
        from fields: [ZipExtraField],
        rawName: [UInt8]
    ) -> String? {
        for field in fields where field.identifier == ZipExtraFieldID.unicodePath {
            guard field.data.count >= 5, field.data[0] == 1 else { continue }
            let expected = LittleEndian.uint32(field.data, at: 1)
            guard CRC32.checksum(rawName) == expected else { continue }
            let nameBytes = Array(field.data.dropFirst(5))
            guard let decoded = EncodingDetector.decode(bytes: nameBytes, as: .utf8),
                  !decoded.isEmpty else { continue }
            return decoded
        }
        return nil
    }

    /// NTFS extra、extended timestamp extra の mtime、DOS 日時の順に更新日時を決める。
    static func modificationDate(
        fields: [ZipExtraField],
        dosDate: UInt16,
        dosTime: UInt16,
        dosTimestampDecoder: inout DOSTimestampDecoder
    ) throws -> Date? {
        var unixDate: Date?
        if let timestamp = fields.first(where: { $0.identifier == ZipExtraFieldID.extendedTimestamp })?.data,
           timestamp.count >= 5,
           timestamp[0] & 0x01 != 0 {
            let seconds = Int32(bitPattern: LittleEndian.uint32(timestamp, at: 1))
            unixDate = Date(timeIntervalSince1970: TimeInterval(seconds))
        }

        var ntfsDate: Date?
        if let ntfs = fields.first(where: { $0.identifier == ZipExtraFieldID.ntfs })?.data,
           ntfs.count >= 4 {
            var cursor = ZipByteCursor(ntfs)
            try cursor.skip(4)
            while cursor.remaining > 0 {
                guard cursor.remaining >= 4 else {
                    throw KaitoError.malformed("truncated ZIP NTFS extra field")
                }
                let tag = try cursor.readUInt16LE()
                let length = Int(try cursor.readUInt16LE())
                guard length <= cursor.remaining else {
                    throw KaitoError.malformed("ZIP NTFS attribute overruns its extra field")
                }
                if tag == 1, length >= 8 {
                    let ticks = try cursor.readUInt64LE()
                    let interval = WindowsFileTime.secondsSince1970(ticks: ticks)
                    guard interval.isFinite else {
                        throw KaitoError.malformed("ZIP NTFS timestamp is out of range")
                    }
                    ntfsDate = Date(timeIntervalSince1970: interval)
                    break
                }
                try cursor.skip(length)
            }
        }
        if let ntfsDate { return ntfsDate }
        if let unixDate { return unixDate }
        return try dosTimestampDecoder.modificationDate(date: dosDate, time: dosTime)
    }
}
