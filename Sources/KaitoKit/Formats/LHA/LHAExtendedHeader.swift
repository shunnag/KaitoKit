import Foundation

// Clean-room extended-header grammar from Masaru Oki's public LHa for UNIX
// `header.doc` (translated by Koji Arai) and the same project's public README
// extension notes; LHAHeaderParser.swift names the full set of inputs.

/// Fields collected from one member's extended-header chain.
///
/// Every record is a type byte, its data, and the size of the next record;
/// a zero next-size ends the chain. Level 1 stores the chain after the base
/// header and counts it in the skip size, with two-byte sizes. Levels 2 and 3
/// store it inside the declared total header, with two-byte and four-byte
/// sizes respectively. Level 0 has no chain; its parser fills the Unix fields
/// from the fixed 'U' extension directly.
struct LHAExtendedHeader {
    var headerCRC16: UInt16?
    var headerCRCFieldOffset: Int?
    var filename: [UInt8]?
    var directory: [UInt8]?
    var comment: [UInt8]?
    var dosAttributes: UInt16?
    var windowsCreationDate: Date?
    var windowsModificationDate: Date?
    var windowsAccessDate: Date?
    var compressedSize64: UInt64?
    var uncompressedSize64: UInt64?
    var codePage: UInt32?
    var unixMode: UInt16?
    var gid: UInt16?
    var uid: UInt16?
    var group: [UInt8]?
    var user: [UInt8]?
    var unixModificationDate: Date?

    /// Extension type 0x40 carries the standard MS-DOS attribute word;
    /// bit 0x10 marks a directory even when the base attribute does not.
    var hasDOSDirectoryAttribute: Bool {
        dosAttributes.map { ($0 & 0x10) != 0 } ?? false
    }

    /// Reads the level-1 chain that follows the base header in the source.
    /// `headerBytes` is the base header followed by every record, which is
    /// the range the optional common-header CRC authenticates.
    mutating func readLevel1Chain(
        source: any ByteSource,
        offset: UInt64,
        firstSize: UInt16,
        skipSize: UInt64,
        base: [UInt8],
        limits: ReadLimits
    ) throws -> (totalSize: UInt64, recordCount: Int, headerBytes: [UInt8]) {
        var currentSize = UInt64(firstSize)
        var currentOffset = offset
        var totalSize: UInt64 = 0
        var recordCount = 0
        var fullHeader = base

        while currentSize != 0 {
            guard currentSize >= 3 else {
                throw KaitoError.malformed("LHA extended header is smaller than its envelope")
            }
            guard recordCount < limits.maxMetadataRecordCount else {
                throw KaitoError.limitExceeded("LHA extended-header count")
            }
            let nextTotalSize = try Checked.add(totalSize, currentSize)
            let fullMetadataSize = try Checked.add(UInt64(base.count), nextTotalSize)
            try Checked.size(fullMetadataSize, limit: limits.maxMetadataSize)
            guard nextTotalSize <= skipSize else {
                throw KaitoError.malformed("LHA level-1 extension chain exceeds the skip size")
            }
            let chunk = try LHAHeaderParser.readHeaderBytes(
                source: source,
                offset: currentOffset,
                size: currentSize
            )
            let size = chunk.count
            let type = chunk[0]
            let data = Array(chunk[1..<(size - 2)])
            let crcFieldOffset = fullHeader.count + 1
            try apply(
                type: type,
                data: data,
                crcFieldOffset: crcFieldOffset
            )
            let nextSize = LittleEndian.uint16(chunk, at: size - 2)
            fullHeader.append(contentsOf: chunk)

            let nextOffset = try Checked.add(currentOffset, currentSize)
            guard nextOffset > currentOffset else {
                throw KaitoError.malformed("LHA extended-header loop made no progress")
            }
            currentOffset = nextOffset
            totalSize = nextTotalSize
            currentSize = UInt64(nextSize)
            recordCount += 1
        }
        return (totalSize, recordCount, fullHeader)
    }

    /// Parses the level-2 chain inside `header`. `endOffset` is where the
    /// chain's terminating next-size field ends.
    mutating func parseLevel2Chain(
        _ header: [UInt8],
        limits: ReadLimits
    ) throws -> (recordCount: Int, endOffset: Int) {
        var currentSize = Int(LittleEndian.uint16(header, at: 24))
        var cursor = LHAHeaderParser.level2MinimumHeaderSize
        var recordCount = 0

        while currentSize != 0 {
            guard currentSize >= 3 else {
                throw KaitoError.malformed("LHA extended header is smaller than its envelope")
            }
            guard recordCount < limits.maxMetadataRecordCount else {
                throw KaitoError.limitExceeded("LHA extended-header count")
            }
            guard cursor <= header.count, currentSize <= header.count - cursor else {
                throw KaitoError.malformed("LHA level-2 extension overruns the total header")
            }
            let end = cursor + currentSize
            let type = header[cursor]
            let data = Array(header[(cursor + 1)..<(end - 2)])
            try apply(
                type: type,
                data: data,
                crcFieldOffset: cursor + 1
            )
            let nextSize = LittleEndian.uint16(header, at: end - 2)
            guard end > cursor else {
                throw KaitoError.malformed("LHA extended-header loop made no progress")
            }
            cursor = end
            currentSize = Int(nextSize)
            recordCount += 1
        }
        // Some writers pad the remainder of a level-2 header after the
        // terminating next-size value.  The bytes are bounded by the declared
        // total header size (and maxMetadataSize), and are authenticated when
        // the optional common-header CRC is present, so leave them
        // uninterpreted for compatibility.
        return (recordCount, cursor)
    }

    /// Parses the level-3 chain inside `header` and returns its record count.
    mutating func parseLevel3Chain(
        _ header: [UInt8],
        limits: ReadLimits
    ) throws -> Int {
        var currentSize = UInt64(LittleEndian.uint32(header, at: 28))
        var cursor = LHAHeaderParser.level3MinimumHeaderSize
        var recordCount = 0

        while currentSize != 0 {
            guard currentSize >= 5 else {
                throw KaitoError.malformed("LHA extended header is smaller than its envelope")
            }
            guard recordCount < limits.maxMetadataRecordCount else {
                throw KaitoError.limitExceeded("LHA extended-header count")
            }
            let size = try Checked.toInt(currentSize)
            guard cursor <= header.count, size <= header.count - cursor else {
                throw KaitoError.malformed("LHA level-3 extension overruns the total header")
            }
            let end = cursor + size
            let type = header[cursor]
            let data = Array(header[(cursor + 1)..<(end - 4)])
            try apply(
                type: type,
                data: data,
                crcFieldOffset: cursor + 1
            )
            let nextSize = LittleEndian.uint32(header, at: end - 4)
            guard end > cursor else {
                throw KaitoError.malformed("LHA extended-header loop made no progress")
            }
            cursor = end
            currentSize = UInt64(nextSize)
            recordCount += 1
        }
        return recordCount
    }

    /// Applies one record. `crcFieldOffset` is where the record's data begins
    /// within the authenticated header bytes, used by the 0x00 common header.
    private mutating func apply(
        type: UInt8,
        data: [UInt8],
        crcFieldOffset: Int
    ) throws {
        switch type {
        case 0x00:
            guard data.count >= 2 else {
                throw KaitoError.malformed("LHA common extension lacks its CRC16")
            }
            guard headerCRC16 == nil else {
                throw KaitoError.malformed("duplicate LHA common extension")
            }
            headerCRC16 = LittleEndian.uint16(data, at: 0)
            headerCRCFieldOffset = crcFieldOffset
        case 0x01:
            if !data.isEmpty { filename = data }
        case 0x02:
            if !data.isEmpty { directory = data }
        case 0x3F:
            comment = data
        case 0x40:
            guard data.count == 2 else {
                throw KaitoError.malformed("invalid LHA MS-DOS attribute extension")
            }
            dosAttributes = LittleEndian.uint16(data, at: 0)
        case 0x41:
            guard data.count == 24 else {
                throw KaitoError.malformed("invalid LHA Windows timestamp extension")
            }
            windowsCreationDate = try Self.windowsFileTime(LittleEndian.uint64(data, at: 0))
            windowsModificationDate = try Self.windowsFileTime(LittleEndian.uint64(data, at: 8))
            windowsAccessDate = try Self.windowsFileTime(LittleEndian.uint64(data, at: 16))
        case 0x42:
            guard data.count == 16 else {
                throw KaitoError.malformed("invalid LHA 64-bit size extension")
            }
            guard uncompressedSize64 == nil,
                  compressedSize64 == nil else {
                throw KaitoError.malformed("duplicate LHA 64-bit size extension")
            }
            // UNLHA32 records packed (compressed) size first, then original size.
            compressedSize64 = LittleEndian.uint64(data, at: 0)
            uncompressedSize64 = LittleEndian.uint64(data, at: 8)
        case 0x46:
            guard data.count == 4 else {
                throw KaitoError.malformed("invalid LHA code-page extension")
            }
            guard codePage == nil else {
                throw KaitoError.malformed("duplicate LHA code-page extension")
            }
            codePage = LittleEndian.uint32(data, at: 0)
        case 0x50:
            guard data.count == 2 else {
                throw KaitoError.malformed("invalid LHA Unix permission extension")
            }
            unixMode = LittleEndian.uint16(data, at: 0)
        case 0x51:
            guard data.count == 4 else {
                throw KaitoError.malformed("invalid LHA Unix uid/gid extension")
            }
            // header.doc stores GID before UID.
            gid = LittleEndian.uint16(data, at: 0)
            uid = LittleEndian.uint16(data, at: 2)
        case 0x52:
            group = data
        case 0x53:
            user = data
        case 0x54:
            guard data.count == 4 else {
                throw KaitoError.malformed("invalid LHA Unix timestamp extension")
            }
            unixModificationDate = Date(
                timeIntervalSince1970: Double(LittleEndian.uint32(data, at: 0))
            )
        case 0x7F, 0xFF:
            break
        default:
            // Unknown extensions remain skippable by construction: their size is
            // authenticated/bounded by the surrounding chain.
            break
        }
    }

    /// Checks the 0x00 common-header CRC when the chain carried one. The CRC
    /// covers `header` with its own two-byte field zeroed.
    func validateHeaderCRCIfPresent(_ header: [UInt8]) throws {
        guard let expected = headerCRC16,
              let crcOffset = headerCRCFieldOffset else {
            return
        }
        guard crcOffset >= 0, crcOffset <= header.count - 2 else {
            throw KaitoError.malformed("LHA common CRC lies outside its header")
        }
        var authenticated = header
        authenticated[crcOffset] = 0
        authenticated[crcOffset + 1] = 0
        guard CRC16.checksum(authenticated) == expected else {
            throw KaitoError.malformed("LHA header CRC mismatch")
        }
    }

    private static func windowsFileTime(_ ticks: UInt64) throws -> Date? {
        // A zero FILETIME denotes an unavailable timestamp in this extension;
        // it must not turn a valid DOS base time into 1601-01-01.
        guard ticks != 0 else { return nil }
        let seconds = WindowsFileTime.secondsSince1970(ticks: ticks)
        guard seconds.isFinite else {
            throw KaitoError.malformed("LHA Windows timestamp is out of range")
        }
        return Date(timeIntervalSince1970: seconds)
    }
}
