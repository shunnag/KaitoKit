import Foundation

// ARJ（Robert K. Jung / ARJ Software）の reader。実装入力は ARJ 2.86 配布物の TECHNOTE.TXT（2005 年 9 月版。
// 末尾の find_header() の C 抜粋は読まずに切除した `inbox/arj/technote-2012-prose.txt`）と、CC0 の Archive Team
// wiki（fileformats.archiveteam.org/wiki/ARJ）の散文である。圧縮 method 1〜3 は同 wiki の「LHA の lh6 と本質的に同じで
// 窓を 26 KB に限る」に従い、既存の LHA static-Huffman decoder を lh6 の parameter で使う（利用者所有の実物で
// 7-Zip / deark / unar と黒箱照合）。method 4 の bitstream には公開の記述が無く非対応。2026-09-21 の検証記録を参照。

enum ARJBytes {
    static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
}

/// 主 header と local file header に共通の basic header（technote の "basic header"）。
struct ARJHeader {
    static let identifier: [UInt8] = [0x60, 0xEA]
    static let maximumBasicSize = 2600
    static let flagGarbled: UInt8 = 0x01
    static let flagVolume: UInt8 = 0x04
    static let flagExtendedFilePosition: UInt8 = 0x08
    static let flagPathSymbol: UInt8 = 0x10

    let firstHeaderSize: Int
    let archiverVersion: UInt8
    let minimumVersion: UInt8
    let hostOS: UInt8
    let flags: UInt8
    let method: UInt8            // main header では security version
    let fileType: UInt8
    let dateTime: UInt32         // main header では作成日時
    let compressedSize: UInt32   // main header では更新日時
    let originalSize: UInt32     // main header では archive size
    let crc32: UInt32            // main header では security envelope position
    let filespecPosition: UInt16
    let accessMode: UInt16
    let extraData: [UInt8]
    let rawName: [UInt8]
    let rawComment: [UInt8]
    /// header id から extended header の終わりまでの byte 数。
    let totalSize: Int

    /// `bytes` の offset 0 に header id がある前提で読む。CRC が合わなければ malformed、id が無ければ nil。
    static func parse(_ b: [UInt8]) throws -> ARJHeader? {
        guard b.count >= 4, b[0] == identifier[0], b[1] == identifier[1] else { return nil }
        let basicSize = Int(ARJBytes.u16(b, 2))
        guard basicSize <= maximumBasicSize else { throw KaitoError.malformed("arj basic header size \(basicSize)") }
        guard basicSize > 0 else {
            return ARJHeader(firstHeaderSize: 0, archiverVersion: 0, minimumVersion: 0, hostOS: 0, flags: 0, method: 0, fileType: 0,
                             dateTime: 0, compressedSize: 0, originalSize: 0, crc32: 0, filespecPosition: 0, accessMode: 0,
                             extraData: [], rawName: [], rawComment: [], totalSize: 4)
        }
        guard b.count >= 4 + basicSize + 4 else { throw KaitoError.truncated }
        let basic = Array(b[4..<(4 + basicSize)])
        var crc = CRC32()
        crc.update(basic)
        guard crc.value == ARJBytes.u32(b, 4 + basicSize) else { throw KaitoError.malformed("arj header crc") }
        let firstSize = Int(basic[0])
        guard firstSize >= 30, firstSize <= basicSize else { throw KaitoError.malformed("arj first header size \(firstSize)") }
        var index = firstSize
        func cString() throws -> [UInt8] {
            guard let end = basic[index...].firstIndex(of: 0) else { throw KaitoError.malformed("arj header string") }
            defer { index = end + 1 }
            return Array(basic[index..<end])
        }
        let name = try cString()
        let comment = try cString()
        // extended header の列: 2 byte の size（0 で終わり）、本文、4 byte の CRC。
        var cursor = 4 + basicSize + 4
        var extendedCount = 0
        while true {
            guard b.count >= cursor + 2 else { throw KaitoError.truncated }
            let size = Int(ARJBytes.u16(b, cursor))
            cursor += 2
            if size == 0 { break }
            guard extendedCount < 16, b.count >= cursor + size + 4 else { throw KaitoError.truncated }
            cursor += size + 4
            extendedCount += 1
        }
        return ARJHeader(firstHeaderSize: firstSize, archiverVersion: basic[1], minimumVersion: basic[2], hostOS: basic[3],
                         flags: basic[4], method: basic[5], fileType: basic[6], dateTime: ARJBytes.u32(basic, 8),
                         compressedSize: ARJBytes.u32(basic, 12), originalSize: ARJBytes.u32(basic, 16), crc32: ARJBytes.u32(basic, 20),
                         filespecPosition: ARJBytes.u16(basic, 24), accessMode: ARJBytes.u16(basic, 26),
                         extraData: Array(basic[30..<firstSize]), rawName: name, rawComment: comment, totalSize: cursor)
    }

    var isEndMarker: Bool { totalSize == 4 }

    static func hostOSName(_ value: UInt8) -> String {
        switch value {
        case 0: "MS-DOS"
        case 1: "PRIMOS"
        case 2: "UNIX"
        case 3: "AMIGA"
        case 4: "MAC-OS"
        case 5: "OS/2"
        case 6: "APPLE GS"
        case 7: "ATARI ST"
        case 8: "NeXT"
        case 9: "VAX VMS"
        case 10: "WIN95"
        case 11: "WIN32"
        default: "host \(value)"
        }
    }
}

final class ARJReader: FormatReader {
    private struct Record {
        let header: ARJHeader
        let dataOffset: UInt64
    }

    let format: ArchiveFormat = .arj
    let entries: [ArchiveEntry]
    let nameEncoding: String.Encoding?
    private let source: any ByteSource
    private let records: [Record]

    /// header id を探す（technote の識別手順: id → basic size ≤ 2600 → CRC）。offset 0 に無ければ実行形式の
    /// 後ろを `maximumScan` byte まで走査する。
    static func findMainHeader(source: any ByteSource, maximumScan: UInt64) throws -> UInt64? {
        let count = try Checked.toInt(min(source.length, Checked.add(maximumScan, UInt64(ARJHeader.maximumBasicSize + 8))))
        guard count >= 4 else { return nil }
        let bytes = try readByteRange(source: source, offset: 0, count: count)
        let last = min(Int(maximumScan), bytes.count - 4)
        for index in 0...last where bytes[index] == 0x60 && bytes[index + 1] == 0xEA {
            if index > 0, !(bytes[0] == 0x4D && bytes[1] == 0x5A) { break }     // SFX でなければ先頭以外は見ない
            let size = Int(ARJBytes.u16(bytes, index + 2))
            guard size >= 7, size <= ARJHeader.maximumBasicSize, index + 4 + size + 4 <= bytes.count else { continue }
            var crc = CRC32()
            crc.update(Array(bytes[(index + 4)..<(index + 4 + size)]))
            if crc.value == ARJBytes.u32(bytes, index + 4 + size), bytes[index + 4 + 6] == 2 {   // main header は file type 2
                return UInt64(index)
            }
        }
        return nil
    }

    init(source: any ByteSource, options: ReaderOptions) throws {
        self.source = source
        let limits = options.limits
        guard let start = try Self.findMainHeader(source: source, maximumScan: FormatDetector.maximumSFXScanSize) else {
            throw KaitoError.unsupportedFormat
        }
        var offset = start
        var metadata: UInt64 = 0
        func readHeader(at position: UInt64) throws -> ARJHeader {
            let available = Int(min(source.length - position, UInt64(ARJHeader.maximumBasicSize + 8 + 16 * (ARJHeader.maximumBasicSize + 6))))
            guard available >= 4 else { throw KaitoError.truncated }
            let bytes = try readByteRange(source: source, offset: position, count: available)
            guard let header = try ARJHeader.parse(bytes) else { throw KaitoError.malformed("arj header id") }
            metadata = try Checked.add(metadata, UInt64(header.totalSize))
            try Checked.size(metadata, limit: limits.maxTotalMetadataSize)
            return header
        }
        let main = try readHeader(at: offset)
        guard !main.isEndMarker, main.fileType == 2 else { throw KaitoError.malformed("arj main header") }
        offset += UInt64(main.totalSize)

        var headers: [Record] = []
        var rawNames: [[UInt8]] = []
        while true {
            guard offset < source.length else { throw KaitoError.truncated }
            let header = try readHeader(at: offset)
            offset += UInt64(header.totalSize)
            if header.isEndMarker { break }
            guard headers.count < limits.maxEntryCount else { throw KaitoError.limitExceeded("arj entry count") }
            let dataOffset = offset
            offset = try Checked.add(offset, UInt64(header.compressedSize))
            guard offset <= source.length else { throw KaitoError.truncated }
            headers.append(Record(header: header, dataOffset: dataOffset))
            rawNames.append(header.rawName)
        }

        // 名前: MS-DOS / OS/2 / Windows の host は書庫全体で 1 つの legacy encoding を判定する（LHA と同じ規則）。
        let policy = options.encodingPolicy
        let fromWindows = [10, 11].contains(main.hostOS)
        let archiveEncoding = EncodingDetector.detectArchiveEncoding(names: rawNames, policy: policy, fromWindows: fromWindows)
        nameEncoding = archiveEncoding

        var entries: [ArchiveEntry] = []
        var records: [Record] = []
        for record in headers {
            let header = record.header
            // file type 4（volume label）と 5（chapter label）は file ではない。
            guard header.fileType == 0 || header.fileType == 1 || header.fileType == 3 else { continue }
            let decoded = EncodingDetector.resolveUndeclaredName(bytes: header.rawName, policy: policy,
                                                                 archiveEncoding: archiveEncoding, fromWindows: fromWindows).string
            // PATHSYM_FLAG が無い DOS 名は `\` 区切り。decode 後に置き換える（CP932 の trail byte 0x5C を守る）。
            let normalized = header.flags & ARJHeader.flagPathSymbol != 0 ? decoded : decoded.replacingOccurrences(of: "\\", with: "/")
            let isDirectory = header.fileType == 3
            let components = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !components.isEmpty, components.count <= limits.maxPathComponentCount,
                  !components.contains(where: { $0 == "." || $0 == ".." }) else {
                throw KaitoError.malformed("arj file name \(normalized)")
            }
            let path = components.joined(separator: "/")
            let method: String
            switch header.method {
            case 0: method = "stored"
            case 1: method = "compressed most"
            case 2: method = "compressed"
            case 3: method = "compressed faster"
            case 4: method = "compressed fastest"
            case 8, 9: method = "no data"
            default: method = "method \(header.method)"
            }
            try Checked.size(UInt64(header.originalSize), limit: limits.maxEntrySize)
            var specific: [String: String] = ["hostOS": ARJHeader.hostOSName(header.hostOS),
                                              "archiverVersion": String(header.archiverVersion)]
            if header.fileType == 1 { specific["textMode"] = "true" }
            if header.flags & ARJHeader.flagVolume != 0 { specific["continuesInNextVolume"] = "true" }
            if header.flags & ARJHeader.flagExtendedFilePosition != 0, header.extraData.count >= 4 {
                specific["extendedFilePosition"] = String(ARJBytes.u32(header.extraData, 0))
            }
            if !header.rawComment.isEmpty {
                specific["comment"] = EncodingDetector.resolveUndeclaredName(bytes: header.rawComment, policy: policy,
                                                                             archiveEncoding: archiveEncoding, fromWindows: fromWindows).string
            }
            let attributes = header.accessMode
            let permissions: UInt16? = header.hostOS == 2 ? attributes : nil
            entries.append(ArchiveEntry(index: entries.count,
                rawName: RawName(bytes: header.rawName, declaredEncoding: nil, isDirectoryHint: isDirectory),
                name: path, pathComponents: components, kind: isDirectory ? .directory : .file,
                uncompressedSize: isDirectory ? 0 : UInt64(header.originalSize),
                compressedSize: isDirectory ? 0 : UInt64(header.compressedSize),
                modificationDate: Self.dosDate(header.dateTime), posixPermissions: permissions,
                isEncrypted: header.flags & ARJHeader.flagGarbled != 0, solidGroup: -1,
                crc32: isDirectory ? nil : header.crc32, methodDescription: method, formatSpecific: specific))
            records.append(record)
        }
        self.entries = entries
        self.records = records
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        guard entries.indices.contains(entry.index), entries[entry.index] == entry else {
            throw KaitoError.notFound("arj entry index \(entry.index)")
        }
        let record = records[entry.index]
        let header = record.header
        if entry.kind == .directory {
            return try EntryStream(source: DataByteSource(Data()), offset: 0, length: 0, limits: limits)
        }
        if header.flags & ARJHeader.flagGarbled != 0 { throw KaitoError.unsupportedMethod("ARJ garbled (encrypted) file") }
        if header.flags & ARJHeader.flagVolume != 0 || header.flags & ARJHeader.flagExtendedFilePosition != 0 {
            throw KaitoError.unsupportedMethod("ARJ multi-volume file")
        }
        let size = UInt64(header.originalSize)
        switch header.method {
        case 0:
            guard UInt64(header.compressedSize) == size else { throw KaitoError.malformed("arj stored size") }
            return try EntryStream(decompressor: CopyDecompressor(source: source, offset: record.dataOffset, compressedSize: size),
                                   length: size, expectedCRC32: header.crc32, entryIndex: entry.index, limits: limits)
        case 1, 2, 3:
            // Archive Team wiki: LHA の lh6 と同じ静的 Huffman + LZ77（窓 26 KB は 32 KB 窓の中で使う）。
            let decoder = try LZSStaticHuffmanDecoder(method: "-lh6-", source: source, offset: record.dataOffset,
                                                      compressedSize: UInt64(header.compressedSize), uncompressedSize: size, limits: limits)
            return try EntryStream(decompressor: decoder, length: size, expectedCRC32: header.crc32, entryIndex: entry.index, limits: limits)
        case 8, 9:
            return try EntryStream(source: DataByteSource(Data()), offset: 0, length: 0, limits: limits)
        default:
            throw KaitoError.unsupportedMethod("ARJ method \(header.method)")
        }
    }

    /// technote の time stamp: 上位 word が日付（1980 起点）、下位 word が時刻（2 秒単位）。
    static func dosDate(_ packed: UInt32) -> Date? {
        guard packed != 0 else { return nil }
        let time = Int(packed & 0xFFFF), date = Int(packed >> 16)
        let day = date & 0x1F, month = (date >> 5) & 0x0F, year = (date >> 9) + 1980
        let second = (time & 0x1F) * 2, minute = (time >> 5) & 0x3F, hour = time >> 11
        guard (1...31).contains(day), (1...12).contains(month), second <= 59, minute <= 59, hour <= 23 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))
    }
}
