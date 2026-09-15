import Foundation

// APPNOTE 6.3.9 §4.4 / §8 と WinZip の公開文書に基づく。
// 巻名・境界越しの読取は Info-ZIP 3.0 / 7zz 26.03 の実行結果でも確認した。
struct ZipDiskLayout: Sendable {
    struct Disk: Sendable {
        let start: UInt64
        let length: UInt64
    }

    let disks: [Disk]
    var lastDiskIndex: UInt64 { UInt64(disks.count - 1) }

    init(lengths: [UInt64]) throws {
        guard !lengths.isEmpty else { throw KaitoError.malformed("ZIP volume set is empty") }
        var start: UInt64 = 0
        var disks: [Disk] = []
        for length in lengths {
            // 空の巻も番号を占める。バイトを持たない巻へのレコード参照は拒否する。
            disks.append(Disk(start: start, length: length))
            start = try Checked.add(start, length)
        }
        self.disks = disks
    }

    func absoluteOffset(disk: UInt64, relative: UInt64, allowEnd: Bool = false) throws -> UInt64 {
        guard disk < UInt64(disks.count) else {
            throw KaitoError.malformed("ZIP disk index is outside the volume set")
        }
        let volume = disks[try Checked.toInt(disk)]
        guard relative < volume.length || (allowEnd && relative == volume.length) else {
            throw KaitoError.malformed("ZIP relative offset is outside its disk")
        }
        return try Checked.add(volume.start, relative)
    }

    func validate(end: ZipEndRecords.EndRecord) throws {
        let last = disks[disks.count - 1]
        guard end.diskNumber == UInt16.max || UInt64(end.diskNumber) == lastDiskIndex,
              end.centralDirectoryDisk == UInt16.max || UInt64(end.centralDirectoryDisk) <= lastDiskIndex,
              end.offset >= last.start,
              end.recordEnd <= (try Checked.add(last.start, last.length)) else {
            throw KaitoError.malformed("ZIP end record disagrees with the volume set")
        }
    }
}

enum ZipSplitVolumeSet {
    struct Naming: Equatable, Sendable {
        let stem: String
        let prefix: String
        let openedNumber: UInt64?
        var lastExtension: String {
            let ext = prefix.count == 1 ? "zip" : "zipx"
            return prefix.first == "Z" ? ext.uppercased() : ext
        }
    }

    struct Assembled: Sendable {
        let source: any ByteSource
        let layout: ZipDiskLayout
    }

    static func naming(for name: String) -> Naming? {
        guard let separator = name.lastIndex(of: "."), separator != name.startIndex else { return nil }
        let stem = String(name[..<separator])
        let ext = String(name[name.index(after: separator)...])
        let lower = ext.lowercased()
        if lower == "zip" || lower == "zipx" {
            let prefix = lower == "zip" ? "z" : "zx"
            return Naming(stem: stem, prefix: ext.first == "Z" ? prefix.uppercased() : prefix, openedNumber: nil)
        }
        let width = lower.hasPrefix("zx") ? 2 : 1
        guard lower.hasPrefix("z") else { return nil }
        let digits = ext.dropFirst(width)
        guard digits.utf8.count >= 2,
              digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              digits.utf8.contains(where: { $0 != 48 }) else { return nil }
        let number = UInt64(digits) ?? UInt64.max
        return Naming(stem: stem, prefix: ext.first == "Z" ? (width == 2 ? "ZX" : "Z") : (width == 2 ? "zx" : "z"), openedNumber: number)
    }

    // number は 1 始まり。99 の後も桁を切り捨てない。
    static func volumeName(_ naming: Naming, number: UInt64) -> String {
        let digits = String(number)
        return naming.stem + "." + naming.prefix + (digits.count < 2 ? "0" : "") + digits
    }

    static func assemble(
        url: URL, source: FileByteSource,
        directory: FileByteSource.DirectoryAnchor?, limits: ReadLimits
    ) throws -> Assembled? {
        guard let naming = naming(for: url.lastPathComponent), let directory else { return nil }
        // 宣言巻数の上限検査前に追加の openat を行わず、明示 symlink は単独扱いにする。
        guard directory.matchesRegularFile(source, named: url.lastPathComponent) else { return nil }
        let lastSource: FileByteSource
        let lastName: String
        if naming.openedNumber != nil {
            let preferred = naming.stem + "." + naming.lastExtension
            let alternative = naming.stem + "." + (naming.lastExtension == naming.lastExtension.lowercased()
                ? naming.lastExtension.uppercased() : naming.lastExtension.lowercased())
            if let opened = try directory.openRegularFile(named: preferred, label: "ZIP split") {
                lastSource = opened
                lastName = preferred
            } else if let opened = try directory.openRegularFile(named: alternative, label: "ZIP split") {
                lastSource = opened
                lastName = alternative
            } else {
                throw KaitoError.malformed("ZIP split archive is missing volume \(preferred)")
            }
        } else {
            lastSource = source
            lastName = url.lastPathComponent
        }
        guard let lastDisk = try ZipEndRecords.lastDiskIndex(source: lastSource, limits: limits) else {
            if naming.openedNumber != nil {
                throw KaitoError.malformed("ZIP end record is missing for \(url.lastPathComponent)")
            }
            return nil
        }
        if let number = naming.openedNumber, number > lastDisk {
            throw KaitoError.malformed("ZIP split archive does not contain \(url.lastPathComponent)")
        }
        guard lastDisk > 0 else { return nil }
        let count = try Checked.add(lastDisk, 1)
        guard limits.maxVolumeCount > 0, count <= UInt64(limits.maxVolumeCount) else {
            throw KaitoError.limitExceeded("ZIP split volume count")
        }
        try directory.verifyFirstVolumeIdentity(of: lastSource, named: lastName, label: "ZIP split")
        var segments: [SourceSegment] = []
        for number in 1...lastDisk {
            let name = volumeName(naming, number: number)
            let otherPrefix = naming.prefix == naming.prefix.lowercased()
                ? naming.prefix.uppercased() : naming.prefix.lowercased()
            let alternate = volumeName(Naming(stem: naming.stem, prefix: otherPrefix, openedNumber: nil), number: number)
            guard let segment = try directory.openRegularFile(named: name, label: "ZIP split")
                ?? directory.openRegularFile(named: alternate, label: "ZIP split") else {
                throw KaitoError.malformed("ZIP split archive is missing volume \(name)")
            }
            // 別名・差し替えによって、明示した巻と異なる内容を返さない。
            if number == naming.openedNumber, !segment.hasSameFileIdentity(as: source) {
                throw KaitoError.malformed("ZIP split volume changed during open: \(url.lastPathComponent)")
            }
            segments.append(SourceSegment(source: segment, offset: 0, length: segment.length))
        }
        segments.append(SourceSegment(source: lastSource, offset: 0, length: lastSource.length))
        let layout = try ZipDiskLayout(lengths: segments.map(\.length))
        let concatenated = try ConcatenatedByteSource(segments: segments, maximumLength: .max,
            maximumSegmentCount: limits.maxVolumeCount, label: "ZIP split volume set")
        // split PKSFX は対象外。終端だけが ZIP に見える別形式も dispatch 前に拒否する。
        let prefix = try readByteRange(source: concatenated, offset: 0, count: 4)
        guard [[0x50, 0x4b, 3, 4], [0x50, 0x4b, 7, 8], [0x50, 0x4b, 0x30, 0x30],
               [0x50, 0x4b, 5, 6]].contains(prefix) else {
            throw KaitoError.malformed("ZIP split volume set is not a ZIP archive (split SFX is unsupported)")
        }
        return Assembled(source: concatenated, layout: layout)
    }
}
