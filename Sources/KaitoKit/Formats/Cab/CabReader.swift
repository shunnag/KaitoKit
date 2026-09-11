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
    private let hasNextCabinet: Bool
    private var folderCoordinators: [Int: SolidCoordinator] = [:]
    private var activeFolderIndex: Int?

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
                let block = try CabDataBlock(bytes, dataOffset: dataCursor.offset, folderOffset: size)
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
        hasNextCabinet = header.flags & 2 != 0
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        guard entries.indices.contains(entry.index), entries[entry.index] == entry else {
            throw KaitoError.notFound("cab entry index \(entry.index)")
        }
        let file = files[entry.index]
        guard file.continued == nil else { throw KaitoError.unsupportedMethod("cab multi-cabinet set") }
        let index = Int(file.folderIndex), folder = folders[Int(file.folderIndex)]
        guard folder.method <= 1 || folder.method == 3 else { throw KaitoError.unsupportedMethod("cab \(folder.methodName)") }
        try Checked.size(folderSizes[index], limit: limits.maxTotalUncompressedSize)
        if folder.method == 1 { try Checked.size(32768, limit: limits.maxDictionarySize) }
        if folder.method == 3 {
            guard (15...21).contains(folder.windowBits) else { throw KaitoError.malformed("cab LZX window bits") }
            try Checked.size(UInt64(1 << folder.windowBits), limit: limits.maxDictionarySize)
        }
        // 短いフォルダーを多数並べた入力でも復号バッファが累積しないよう、保持する復号器を一つに制限する。
        if let activeFolderIndex, activeFolderIndex != index {
            try folderCoordinators[activeFolderIndex]?.invalidateAndRelease()
        }
        activeFolderIndex = index
        let coordinator: SolidCoordinator
        if let cached = folderCoordinators[index] {
            coordinator = cached
        } else {
            let folderContinues = blocks[index].last?.uncompressedSize == 0
                || (hasNextCabinet && index == folders.count - 1)
            coordinator = SolidCoordinator(source: source, blocks: blocks[index], folder: folder,
                outputSize: folderSizes[index], dictionarySizeLimit: limits.maxDictionarySize,
                folderContinues: folderContinues)
            folderCoordinators[index] = coordinator
        }
        let decoder = try coordinator.stream(offset: file.folderOffset, length: file.size, entryIndex: entry.index)
        return try EntryStream(decompressor: decoder, length: file.size, expectedCRC32: nil,
            entryIndex: entry.index, limits: limits)
    }

    private final class SolidCoordinator {
        private let source: any ByteSource
        private let blocks: [CabDataBlock]
        private let folder: CabFolder
        private let outputSize, dictionarySizeLimit: UInt64
        private let folderContinues: Bool
        private var decoder: (any CabFolderDecoder)?
        private var generation: UInt64 = 0

        init(source: any ByteSource, blocks: [CabDataBlock], folder: CabFolder,
             outputSize: UInt64, dictionarySizeLimit: UInt64, folderContinues: Bool) {
            self.source = source; self.blocks = blocks; self.folder = folder
            self.outputSize = outputSize; self.dictionarySizeLimit = dictionarySizeLimit
            self.folderContinues = folderContinues
        }

        func invalidateAndRelease() throws {
            generation = try Checked.add(generation, 1)
            decoder = nil
        }

        func stream(offset: UInt64, length: UInt64, entryIndex: Int) throws -> SolidRangeDecompressor {
            let end = try Checked.add(offset, length)
            generation = try Checked.add(generation, 1)
            // 空ファイルは履歴再構築も不要。開始位置が後退するときだけ先頭からやり直す。
            if length > 0, decoder == nil || offset < decoder!.position {
                // 新しい辞書の確保前に旧辞書を解放する。初期化が失敗すればこの呼出しも失敗し、次回は再構築する。
                decoder = nil
                if folder.method == 3 {
                    decoder = try LZXFolderDecompressor(source: source, blocks: blocks, windowBits: folder.windowBits,
                        outputSize: outputSize, dictionarySizeLimit: dictionarySizeLimit, folderContinues: folderContinues)
                } else {
                    decoder = MSZIPDecompressor(source: source, blocks: blocks, stored: folder.method == 0)
                }
            }
            return SolidRangeDecompressor(coordinator: self, generation: generation,
                offset: offset, end: end, entryIndex: entryIndex)
        }

        func read(generation expected: UInt64, offset: inout UInt64, end: UInt64,
                  entryIndex: Int, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
            guard expected == generation else {
                throw KaitoError.malformed("a newer CAB folder stream invalidated this stream")
            }
            guard offset < end, !buffer.isEmpty else { return 0 }
            guard let decoder else { throw KaitoError.malformed("cab folder decoder is unavailable") }
            do {
                try decoder.skip(to: offset, entryIndex: entryIndex)
                let count = try Checked.toInt(min(UInt64(buffer.count), Checked.sub(end, offset)))
                let actual = try decoder.read(into: UnsafeMutableRawBufferPointer(rebasing: buffer[..<count]),
                    entryIndex: entryIndex)
                offset = try Checked.add(offset, UInt64(actual))
                return actual
            } catch {
                self.decoder = nil
                throw error
            }
        }
    }

    private final class SolidRangeDecompressor: Decompressor {
        private let coordinator: SolidCoordinator
        private let generation: UInt64
        private let end: UInt64
        private let entryIndex: Int
        private var offset: UInt64

        init(coordinator: SolidCoordinator, generation: UInt64, offset: UInt64, end: UInt64, entryIndex: Int) {
            self.coordinator = coordinator; self.generation = generation
            self.offset = offset; self.end = end; self.entryIndex = entryIndex
        }

        // 200 ファイルの実測では末尾一箇所の破損が全件を失敗させた。範囲終端で完了させ波及を防ぐ。
        var isFinished: Bool { offset == end }

        func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
            try coordinator.read(generation: generation, offset: &offset, end: end,
                entryIndex: entryIndex, into: buffer)
        }
    }
}
