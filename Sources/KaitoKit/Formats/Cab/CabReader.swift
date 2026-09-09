// Microsoft [MS-CAB]、RFC 1951、zlib manual と利用者提供の実測 byte 表に基づくクリーンルーム実装。
// 他の archiver の実装 source は開かず、参照・引用していない。
import Foundation

final class CabReader: FormatReader {
    let format: ArchiveFormat = .cab
    let entries: [ArchiveEntry]
    let nameEncoding: String.Encoding?
    private let source: any ByteSource
    private let folders: [CabFolder]
    private let files: [CabFile]
    private let blocks: [[CabDataBlock]]
    private let folderSizes: [UInt64]

    init(source: any ByteSource, options: ReaderOptions) throws {
        self.source = source
        let limits = options.limits
        var cursor = CabCursor(source: source, end: source.length, offset: 0)
        let header = try CabHeader(cursor.read(36))
        guard header.cabinetSize >= 36, header.cabinetSize <= source.length else { throw KaitoError.truncated }
        cursor = CabCursor(source: source, end: header.cabinetSize, offset: 36)
        guard header.folderCount <= limits.maxEntryCount, header.fileCount <= limits.maxEntryCount else {
            throw KaitoError.limitExceeded("cab entry count")
        }
        var budget = CabMetadataBudget(limits: limits)
        try budget.charge(36)
        var folderReserve: UInt64 = 0, dataReserve: UInt64 = 0
        if header.flags & 4 != 0 {
            let reserve = try cursor.read(4)
            let headerReserve = UInt64(CabCursor.u16(reserve, 0))
            folderReserve = UInt64(reserve[2]); dataReserve = UInt64(reserve[3])
            try Checked.size(headerReserve, limit: limits.maxMetadataSize)
            try budget.charge(Checked.add(4, headerReserve))
            try cursor.skip(headerReserve)
        }
        for flag: UInt16 in [1, 2] where header.flags & flag != 0 {
            for _ in 0..<2 {
                let name = try cursor.name(limit: limits.maxMetadataSize, label: "cab cabinet name")
                try budget.charge(Checked.add(UInt64(name.count), 1))
            }
        }
        try cursor.validateRecords(count: header.folderCount, stride: Checked.add(8, folderReserve))
        var fileCursor = CabCursor(source: source, end: header.cabinetSize, offset: header.filesOffset)
        try fileCursor.validateRecords(count: header.fileCount, stride: 17)
        try budget.array(count: header.folderCount, stride: 128)
        try budget.array(count: header.fileCount, stride: 256)
        var folders: [CabFolder] = []
        for _ in 0..<header.folderCount {
            let folder = CabFolder(try cursor.read(8))
            guard folder.dataOffset <= header.cabinetSize else { throw KaitoError.truncated }
            folders.append(folder)
            try cursor.skip(folderReserve)
        }
        var files: [CabFile] = []
        for _ in 0..<header.fileCount {
            let bytes = try fileCursor.read(16)
            let name = try fileCursor.name(limit: limits.maxMetadataSize, label: "cab file name")
            let file = CabFile(bytes, name: name)
            guard file.continued != nil || Int(file.folderIndex) < folders.count else {
                throw KaitoError.malformed("cab folder index")
            }
            try Checked.size(file.size, limit: limits.maxEntrySize)
            try budget.charge(UInt64(name.count))
            files.append(file)
        }
        var blocks: [[CabDataBlock]] = [], folderSizes: [UInt64] = []
        var totalOutput: UInt64 = 0
        for folder in folders {
            var dataCursor = CabCursor(source: source, end: header.cabinetSize, offset: folder.dataOffset)
            try dataCursor.validateRecords(count: folder.blockCount, stride: Checked.add(8, dataReserve))
            guard folder.blockCount <= limits.maxMetadataRecordCount else {
                throw KaitoError.limitExceeded("cab block count")
            }
            try budget.array(count: folder.blockCount, stride: MemoryLayout<CabDataBlock>.stride)
            var folderBlocks: [CabDataBlock] = []
            var size: UInt64 = 0
            for _ in 0..<folder.blockCount {
                let bytes = try dataCursor.read(8)
                try dataCursor.skip(dataReserve)
                let block = try CabDataBlock(bytes, dataOffset: dataCursor.offset)
                try dataCursor.skip(UInt64(block.compressedSize))
                size = try Checked.add(size, UInt64(block.uncompressedSize))
                folderBlocks.append(block)
            }
            totalOutput = try Checked.add(totalOutput, size)
            try Checked.size(totalOutput, limit: limits.maxTotalUncompressedSize)
            blocks.append(folderBlocks); folderSizes.append(size)
        }
        for file in files where file.continued == nil {
            guard try Checked.add(file.folderOffset, file.size) <= folderSizes[Int(file.folderIndex)] else {
                throw KaitoError.malformed("cab file extent")
            }
        }
        // 宣言付き UTF-8 は archive-wide 推定へ混ぜず、未宣言名は cpio と同じ経路で解決する。
        let names = files.filter { $0.attributes & 0x80 == 0 }.map(\.name).filter {
            if case .fixed = options.encodingPolicy { return true }
            return !EncodingDetector.isStrictUTF8($0)
        }
        let encoding = EncodingDetector.detectArchiveEncoding(names: names, policy: options.encodingPolicy,
            maximumBatchByteCount: Int(clamping: limits.maxMetadataSize))
        var decoded: [[UInt8]: String] = [:]
        if let encoding {
            let strings = EncodingDetector.decodeArchiveNames(names, as: encoding,
                maximumBatchByteCount: Int(clamping: limits.maxMetadataSize))
            for (bytes, string) in zip(names, strings) { if let string { decoded[bytes] = string } }
        }
        var entries: [ArchiveEntry] = []
        for file in files {
            let declared: String.Encoding? = file.attributes & 0x80 != 0 ? .utf8 : nil
            let resolved = declared == .utf8 ? String(decoding: file.name, as: UTF8.self)
                : decoded[file.name] ?? EncodingDetector.resolveUndeclaredName(bytes: file.name,
                    policy: options.encodingPolicy, archiveEncoding: encoding).string
            let name = resolved.replacingOccurrences(of: "\\", with: "/")
            var componentCount = 0, inComponent = false
            for byte in name.utf8 {
                if byte == 47 { inComponent = false }
                else if !inComponent {
                    guard componentCount < limits.maxPathComponentCount else {
                        throw KaitoError.limitExceeded("cab path component count")
                    }
                    componentCount += 1; inComponent = true
                }
            }
            try budget.charge(Checked.mul(UInt64(componentCount), UInt64(MemoryLayout<String>.stride)))
            try budget.charge(Checked.mul(UInt64(name.utf8.count), 2))
            let parts = name.split(separator: "/").map(String.init)
            var specific = ["folder": String(file.folderIndex), "attributes": String(format: "%04x", file.attributes),
                "setID": String(header.setID), "cabinetIndex": String(header.cabinetIndex)]
            if let continued = file.continued { specific["continued"] = continued }
            // 継続 sentinel は先頭/末尾 folder に対応するが、単独 cabinet では抽出しない。
            let folderIndex = file.continued == nil ? Int(file.folderIndex)
                : file.folderIndex == 0xfffe ? max(0, folders.count - 1) : 0
            let method = folders.indices.contains(folderIndex) ? folders[folderIndex].methodName : "multi-cabinet set"
            for (key, value) in specific {
                try budget.charge(Checked.add(UInt64(key.utf8.count), UInt64(value.utf8.count)))
            }
            entries.append(ArchiveEntry(index: entries.count,
                rawName: RawName(bytes: file.name, declaredEncoding: declared), name: name, pathComponents: parts,
                kind: .file, uncompressedSize: file.size, compressedSize: nil,
                modificationDate: try? dosModificationDate(date: file.date, time: file.time),
                posixPermissions: nil, isEncrypted: false, solidGroup: Int(file.folderIndex), crc32: nil,
                methodDescription: "cab (\(method))", formatSpecific: specific))
        }
        self.entries = entries; self.folders = folders; self.files = files
        self.blocks = blocks; self.folderSizes = folderSizes; nameEncoding = encoding
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        guard entries.indices.contains(entry.index), entries[entry.index] == entry else {
            throw KaitoError.notFound("cab entry index \(entry.index)")
        }
        let file = files[entry.index]
        guard file.continued == nil else { throw KaitoError.unsupportedMethod("cab multi-cabinet set") }
        let index = Int(file.folderIndex), folder = folders[Int(file.folderIndex)]
        guard folder.method <= 1 else { throw KaitoError.unsupportedMethod("cab \(folder.methodName)") }
        try Checked.size(folderSizes[index], limit: limits.maxTotalUncompressedSize)
        if folder.method == 1 { try Checked.size(32768, limit: limits.maxDictionarySize) }
        let decoder = try MSZIPDecompressor(source: source, blocks: blocks[index], stored: folder.method == 0,
            offset: file.folderOffset, length: file.size, entryIndex: entry.index)
        return try EntryStream(decompressor: decoder, length: file.size, expectedCRC32: nil,
            entryIndex: entry.index, limits: limits, completionCheck: {
                guard decoder.checksumsMatch else { throw KaitoError.checksumMismatch(entry: entry.index) }
            })
    }
}
