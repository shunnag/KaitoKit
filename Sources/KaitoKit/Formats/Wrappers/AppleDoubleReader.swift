import Foundation

/// How `__MACOSX/._name` (Finder / ditto ZIP) and `._name` (macOS tar) AppleDouble sidecars are exposed.
public enum AppleDoublePolicy: String, Sendable, CaseIterable {
    /// Sidecars are removed from the entry list. A sidecar that carries a resource fork is published
    /// as `name/..namedfork/rsrc` (`formatSpecific["fork"] == "resource"`) right after its data
    /// file; sidecars that hold only Finder information and extended attributes disappear. This is
    /// the default.
    case merge

    /// Sidecars and the `__MACOSX` directories are removed; resource forks are not published.
    case hide

    /// Every entry is listed exactly as the archive stores it.
    case expose
}

// 参照資料: AppleSingle/AppleDouble Formats for Foreign Files Developer's Note（Apple、1990、公開）。
// header: magic 00051607（AppleDouble）、version 00010000 / 00020000、filler 16 byte、entry 数（BE16）、
// entry ごとに id / offset / length（BE32）。resource fork は entry id 2。Finder 製 zip の sidecar は
// Finder info（id 9、xattr block を含む）と resource fork（長さ 0 が多い）の 2 entry を持つ（黒箱で確認）。
struct AppleDoubleHeader {
    static let magic: UInt32 = 0x0005_1607
    static let maximumEntries = 32
    static let headerSize = 26

    let resourceFork: (offset: UInt64, length: UInt64)?

    /// 先頭 byte 列から header を読む。AppleDouble でなければ nil、entry 表が壊れていれば malformed。
    init?(_ b: [UInt8], totalLength: UInt64?) throws {
        guard b.count >= Self.headerSize else { return nil }
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3]) }
        guard u32(0) == Self.magic, [0x0001_0000, 0x0002_0000].contains(u32(4)) else { return nil }
        let count = Int(b[24]) << 8 | Int(b[25])
        guard count <= Self.maximumEntries else { throw KaitoError.malformed("AppleDouble entry count") }
        guard b.count >= Self.headerSize + 12 * count else { throw KaitoError.truncated }
        var resource: (UInt64, UInt64)?
        for index in 0..<count {
            let base = Self.headerSize + 12 * index
            let id = u32(base), offset = UInt64(u32(base + 4)), length = UInt64(u32(base + 8))
            if let totalLength, length > 0 {
                guard try Checked.add(offset, length) <= totalLength else { throw KaitoError.malformed("AppleDouble entry extent") }
            }
            if id == 2, resource == nil { resource = (offset, length) }
        }
        resourceFork = resource
    }

    static func prefixLength(for entry: ArchiveEntry) -> Int {
        Int(min(entry.uncompressedSize ?? UInt64(headerSize + 12 * maximumEntries), UInt64(headerSize + 12 * maximumEntries)))
    }
}

/// ZIP / tar の entry 列から AppleDouble sidecar を取り除き、resource fork を fork entry として差し込む
/// `FormatReader`。内側の reader の entry index への写像を持ち、stream と rawRecord を転送する。
final class AppleDoubleReader: FormatReader {
    enum Mapping {
        case passthrough(Int)
        case resourceFork(sidecar: Int, offset: UInt64, length: UInt64)
    }

    let inner: any FormatReader
    let entries: [ArchiveEntry]
    private let mappings: [Mapping]
    var format: ArchiveFormat { inner.format }
    var nameEncoding: String.Encoding? { inner.nameEncoding }

    private init(inner: any FormatReader, entries: [ArchiveEntry], mappings: [Mapping]) {
        self.inner = inner
        self.entries = entries
        self.mappings = mappings
    }

    /// sidecar が無ければ `inner` をそのまま返す。
    static func wrap(_ inner: any FormatReader, options: ReaderOptions) throws -> any FormatReader {
        guard options.appleDoublePolicy != .expose else { return inner }
        let source = inner.entries
        // 一段目: 名前で候補を選ぶ。`__MACOSX/a/._b` → `a/b`、`a/._b` → `a/b`。
        var sidecarTargets: [Int: [String]] = [:]
        var underMacOSX = Set<Int>()
        for entry in source {
            let components = entry.pathComponents
            guard !components.isEmpty else { continue }
            let macOSX = components[0] == "__MACOSX"
            if macOSX { underMacOSX.insert(entry.index) }
            guard entry.kind == .file, let leaf = components.last, leaf.hasPrefix("._"), leaf.count > 2 else { continue }
            var target = macOSX ? Array(components.dropFirst()) : components
            guard !target.isEmpty else { continue }
            target[target.count - 1] = String(leaf.dropFirst(2))
            sidecarTargets[entry.index] = target
        }
        guard !sidecarTargets.isEmpty || !underMacOSX.isEmpty else { return inner }

        // ZIP の directory 名は末尾に `/` を持つので、`pathComponents` で照合する。
        var indexByPath: [String: Int] = [:]
        for entry in source where entry.kind != .other && sidecarTargets[entry.index] == nil {
            let key = entry.pathComponents.joined(separator: "/")
            if indexByPath[key] == nil { indexByPath[key] = entry.index }
        }
        // 二段目: 先頭を読んで AppleDouble であることを確かめ、resource fork の位置を得る。
        var hidden = Set<Int>()
        var forks: [Int: (sidecar: Int, offset: UInt64, length: UInt64, entry: ArchiveEntry)] = [:]
        for (index, target) in sidecarTargets {
            let sidecar = source[index]
            let targetPath = target.joined(separator: "/")
            let targetIndex = indexByPath[targetPath]
            if sidecar.isEncrypted {
                // password 無しでは中身を確かめられない。Finder の `__MACOSX/` 配下だけは名前で隠せる。
                if options.appleDoublePolicy == .hide, underMacOSX.contains(index) { hidden.insert(index) }
                continue
            }
            let stream = try inner.stream(for: sidecar, limits: options.limits)
            var prefix = [UInt8](repeating: 0, count: AppleDoubleHeader.prefixLength(for: sidecar))
            var filled = 0
            while filled < prefix.count {
                let count = try prefix.withUnsafeMutableBytes { buffer in
                    try stream.read(into: UnsafeMutableRawBufferPointer(rebasing: buffer[filled...]))
                }
                if count == 0 { break }
                filled += count
            }
            guard let header = try AppleDoubleHeader(Array(prefix.prefix(filled)), totalLength: sidecar.uncompressedSize) else { continue }
            switch options.appleDoublePolicy {
            case .hide:
                hidden.insert(index)
            case .merge:
                // 参照先が無い sidecar は取りこぼさないためにそのまま残す。
                guard let targetIndex, source[targetIndex].kind == .file || source[targetIndex].kind == .directory else { continue }
                hidden.insert(index)
                if let fork = header.resourceFork, fork.length > 0, source[targetIndex].kind == .file {
                    forks[targetIndex] = (index, fork.offset, fork.length, sidecar)
                }
            case .expose:
                break
            }
        }
        // `__MACOSX` 配下に隠されなかった file が残らなければ、その directory entry も隠す。
        let macOSXVisibleFiles = underMacOSX.contains { source[$0].kind != .directory && !hidden.contains($0) }
        if !macOSXVisibleFiles {
            for index in underMacOSX where source[index].kind == .directory { hidden.insert(index) }
        }
        guard !hidden.isEmpty else { return inner }

        var entries: [ArchiveEntry] = []
        var mappings: [Mapping] = []
        for entry in source where !hidden.contains(entry.index) {
            entries.append(entry.reindexed(entries.count))
            mappings.append(.passthrough(entry.index))
            if let fork = forks[entry.index] {
                var specific = fork.entry.formatSpecific
                specific["fork"] = "resource"
                specific["appleDoubleSidecar"] = fork.entry.name
                let components = entry.pathComponents + ["..namedfork", "rsrc"]
                entries.append(ArchiveEntry(
                    index: entries.count,
                    rawName: RawName(bytes: Array(components.joined(separator: "/").utf8), declaredEncoding: .utf8),
                    name: components.joined(separator: "/"), pathComponents: components, kind: .file,
                    uncompressedSize: fork.length, compressedSize: nil,
                    modificationDate: fork.entry.modificationDate, posixPermissions: entry.posixPermissions,
                    isEncrypted: fork.entry.isEncrypted, solidGroup: fork.entry.solidGroup, crc32: nil,
                    methodDescription: fork.entry.methodDescription, formatSpecific: specific,
                    isIncomplete: fork.entry.isIncomplete))
                mappings.append(.resourceFork(sidecar: fork.sidecar, offset: fork.offset, length: fork.length))
            }
        }
        return AppleDoubleReader(inner: inner, entries: entries, mappings: mappings)
    }

    /// 内側の reader を開き直し、同じ写像を掛ける。
    func reopened(options: ReaderOptions) throws -> sending AppleDoubleReader {
        let reopenedInner: any FormatReader
        if let zip = inner as? ZipReader {
            reopenedInner = zip.reopened(options: options)
        } else if let tar = inner as? TarReader {
            reopenedInner = tar.reopened(options: options)
        } else {
            throw KaitoError.unsupportedMethod("AppleDouble merge reopen for \(inner.format.rawValue)")
        }
        return AppleDoubleReader(inner: reopenedInner, entries: entries, mappings: mappings)
    }

    private func innerEntry(_ index: Int) throws -> ArchiveEntry {
        guard inner.entries.indices.contains(index) else { throw KaitoError.notFound("archive entry index \(index)") }
        return inner.entries[index]
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        guard entries.indices.contains(entry.index), entries[entry.index] == entry else {
            throw KaitoError.notFound("archive entry index \(entry.index)")
        }
        switch mappings[entry.index] {
        case .passthrough(let index):
            return try inner.stream(for: try innerEntry(index), limits: limits)
        case .resourceFork(let sidecar, let offset, let length):
            let base = try inner.stream(for: try innerEntry(sidecar), limits: limits)
            return try EntryStream(decompressor: SliceDecompressor(stream: base, skip: offset, length: length),
                                   length: length, expectedCRC32: nil, entryIndex: entry.index, limits: limits)
        }
    }

    func rawRecord(for entry: ArchiveEntry, limits: ReadLimits) throws -> RawEntryRecord? {
        guard entries.indices.contains(entry.index), entries[entry.index] == entry,
              case .passthrough(let index) = mappings[entry.index] else { return nil }
        return try inner.rawRecord(for: try innerEntry(index), limits: limits)
    }

    func setPassword(_ password: String?) { inner.setPassword(password) }
}

private extension ArchiveEntry {
    func reindexed(_ index: Int) -> ArchiveEntry {
        ArchiveEntry(index: index, rawName: rawName, name: name, pathComponents: pathComponents, kind: kind,
                     uncompressedSize: uncompressedSize, compressedSize: compressedSize, modificationDate: modificationDate,
                     posixPermissions: posixPermissions, isEncrypted: isEncrypted, solidGroup: solidGroup, crc32: crc32,
                     methodDescription: methodDescription, formatSpecific: formatSpecific, isIncomplete: isIncomplete)
    }
}

/// 別 entry の stream の一部（`skip` byte 飛ばして `length` byte）を返す。
final class SliceDecompressor: Decompressor {
    private let stream: EntryStream
    private var toSkip: UInt64
    private var remaining: UInt64

    init(stream: EntryStream, skip: UInt64, length: UInt64) {
        self.stream = stream
        self.toSkip = skip
        self.remaining = length
    }

    var isFinished: Bool { remaining == 0 }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, remaining > 0 else { return 0 }
        while toSkip > 0 {
            let chunk = Int(min(toSkip, UInt64(buffer.count)))
            let count = try stream.read(into: UnsafeMutableRawBufferPointer(rebasing: buffer[..<chunk]))
            guard count > 0 else { throw KaitoError.truncated }
            toSkip -= UInt64(count)
        }
        let want = Int(min(remaining, UInt64(buffer.count)))
        let count = try stream.read(into: UnsafeMutableRawBufferPointer(rebasing: buffer[..<want]))
        guard count > 0 else { throw KaitoError.truncated }
        remaining -= UInt64(count)
        return count
    }
}
