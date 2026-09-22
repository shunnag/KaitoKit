import CryptoKit
import Foundation

// rpm.org の prose と rpmbuild 6.1.0 の黒箱実測。単体 cpio の variant にはしない。
struct RpmStrippedPayload {
    static let magic = Array("07070X".utf8)

    struct Record {
        let fileIndex: Int
        let dataOffset, dataLength: UInt64
    }
    private struct LinkKey: Hashable {
        let dev, ino: UInt32
    }
    struct LinkGroup {
        var count: Int
        var lastFileIndex: Int
        var archiveIndex: Int = 0
    }

    let records: [Record]
    let fileList: RpmFileList
    let metadataSize: UInt64
    private let source: any ByteSource
    private let groups: [LinkKey: LinkGroup]

    init(source: any ByteSource, fileList: RpmFileList, limits: ReadLimits) throws {
        self.source = source
        self.fileList = fileList
        let files = fileList.files
        // group / seen / record の全件分の保持量。単体 allocation でなく総量上限で検査する。
        let allocation = try Checked.mul(UInt64(files.count), 256)
        try Checked.size(allocation, limit: limits.maxTotalMetadataSize)
        metadataSize = allocation
        var groups: [LinkKey: LinkGroup] = [:]
        var expectedCount = 0
        for (i, file) in files.enumerated() where !file.isGhost {
            expectedCount += 1
            if file.kind == .file {
                let key = LinkKey(dev: file.dev, ino: file.ino)
                if let group = groups[key] {
                    guard files[group.lastFileIndex].size == file.size else { throw KaitoError.malformed("rpm file list") }
                    groups[key] = LinkGroup(count: group.count + 1, lastFileIndex: i)
                } else {
                    groups[key] = LinkGroup(count: 1, lastFileIndex: i)
                }
            }
        }
        var records: [Record] = []
        var seen: Set<Int> = []
        var offset: UInt64 = 0
        while true {
            let magic = try readByteRange(source: source, offset: offset, count: 6)
            if magic == Array("070701".utf8) {
                let trailer = try CpioHeader.read(source: source, at: offset)
                let layout = try trailer.layout(at: offset)
                let name = try trailer.readName(source: source, at: layout.name, limit: limits.maxMetadataSize)
                guard name == Array("TRAILER!!!".utf8), trailer.fileSize == 0 else {
                    throw KaitoError.malformed("rpm stripped trailer")
                }
                guard layout.next <= source.length else { throw KaitoError.truncated }
                let nameEnd = try Checked.add(layout.name, trailer.nameSize)
                try Self.requireNUL(source: source, offset: nameEnd, count: Checked.sub(layout.data, nameEnd))
                let remaining = try Checked.sub(source.length, layout.next)
                guard remaining <= 512 else { throw KaitoError.malformed("rpm stripped trailer padding") }
                try Self.requireNUL(source: source, offset: layout.next, count: remaining)
                guard seen.count == expectedCount else { throw KaitoError.malformed("rpm missing payload member") }
                break
            }
            guard magic == Self.magic else { throw KaitoError.malformed("rpm stripped magic") }
            let bytes = try readByteRange(source: source, offset: offset, count: 16)
            var index: UInt64 = 0
            for byte in bytes[6..<14] {
                let digit: UInt64
                switch byte {
                case 48...57: digit = UInt64(byte - 48)
                case 65...70: digit = UInt64(byte - 55)
                case 97...102: digit = UInt64(byte - 87)
                default: throw KaitoError.malformed("rpm stripped index")
                }
                index = try Checked.add(Checked.mul(index, 16), digit)
            }
            guard bytes[14] == 0, bytes[15] == 0, index < UInt64(files.count) else {
                throw KaitoError.malformed("rpm stripped index")
            }
            let fileIndex = try Checked.toInt(index)
            let file = files[fileIndex]
            guard !file.isGhost, seen.insert(fileIndex).inserted else {
                throw KaitoError.malformed("rpm stripped repeated or ghost index")
            }
            guard records.count < limits.maxEntryCount else { throw KaitoError.limitExceeded("rpm entry count") }
            let size: UInt64
            switch file.kind {
            case .file:
                let key = LinkKey(dev: file.dev, ino: file.ino)
                size = groups[key]?.lastFileIndex == fileIndex ? file.size : 0
                if groups[key]?.lastFileIndex == fileIndex { groups[key]?.archiveIndex = records.count }
            case .symlink:
                size = file.size
                guard size > 0, size == UInt64(file.linkTarget.utf8.count) else {
                    throw KaitoError.malformed("rpm file list")
                }
                try Checked.size(size, limit: CpioReader.maximumLinkTargetSize)
                try Checked.size(size, limit: limits.maxMetadataSize)
            default: size = 0
            }
            try Checked.size(size, limit: limits.maxEntrySize)
            let dataOffset = try Checked.add(offset, 16)
            let end = try Checked.add(dataOffset, size)
            let padding = (4 - size % 4) % 4
            let next = try Checked.add(end, padding)
            guard next <= source.length else { throw KaitoError.truncated }
            try Self.requireNUL(source: source, offset: end, count: padding)
            records.append(Record(fileIndex: fileIndex, dataOffset: dataOffset, dataLength: size))
            offset = next
        }
        self.records = records
        self.groups = groups
    }

    func group(for file: RpmFileList.File) -> LinkGroup? {
        file.kind == .file ? groups[LinkKey(dev: file.dev, ino: file.ino)] : nil
    }

    func stream(at index: Int, limits: ReadLimits) throws -> EntryStream {
        let record = records[index]
        if fileList.digestAlgorithm == 8, record.dataLength > 0,
           let digest = fileList.files[record.fileIndex].digest {
            let hash = try RpmSHA256Decompressor(source: source, offset: record.dataOffset, length: record.dataLength)
            return try EntryStream(decompressor: hash, length: record.dataLength, expectedCRC32: nil,
                entryIndex: index, limits: limits, completionCheck: {
                    guard hash.digest == digest.lowercased() else { throw KaitoError.checksumMismatch(entry: index) }
                })
        }
        return try EntryStream(source: source, offset: record.dataOffset, length: record.dataLength, limits: limits)
    }

    private static func requireNUL(source: any ByteSource, offset: UInt64, count: UInt64) throws {
        let bytes = try readByteRange(source: source, offset: offset, count: Checked.toInt(count))
        guard bytes.allSatisfy({ $0 == 0 }) else { throw KaitoError.malformed("rpm stripped padding") }
    }
}

// staging 済み本文を読みながら更新し、完全読取の終端でだけ照合する。
private final class RpmSHA256Decompressor: Decompressor {
    private let copy: CopyDecompressor
    private var hash = SHA256()
    init(source: any ByteSource, offset: UInt64, length: UInt64) throws {
        copy = try CopyDecompressor(source: source, offset: offset, compressedSize: length)
    }
    var isFinished: Bool { copy.isFinished }
    var digest: String { hash.finalize().map { String(format: "%02x", $0) }.joined() }
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let count = try copy.read(into: buffer)
        hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[..<count]))
        return count
    }
}
