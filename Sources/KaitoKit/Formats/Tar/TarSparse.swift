import Foundation

// 参照仕様: libarchive の tar(5)（BSD-2-Clause の man page）"GNU tar Archives" 節の sparse 構造、
// および黒箱で観察した bsdtar --format pax の GNU.sparse 1.0 出力。GNU tar / libarchive の
// 実装 source は参照していない。

/// sparse entry の 1 fragment。`offset` は展開後 file 内の位置、`size` はその長さ。
struct TarSparseFragment: Equatable, Sendable {
    let offset: UInt64
    let size: UInt64
}

/// sparse map と実サイズ。fragment は昇順・非重複で、展開後サイズの中に収まる。
struct TarSparseMap: Equatable, Sendable {
    let realSize: UInt64
    let fragments: [TarSparseFragment]
    /// 本文に格納されている byte 数（全 fragment の合計）。
    let storedSize: UInt64

    init(realSize: UInt64, fragments: [TarSparseFragment], limits: ReadLimits) throws {
        guard fragments.count <= limits.maxMetadataRecordCount else {
            throw KaitoError.limitExceeded("tar sparse fragment count")
        }
        var cursor: UInt64 = 0
        var stored: UInt64 = 0
        var kept: [TarSparseFragment] = []
        kept.reserveCapacity(fragments.count)
        for fragment in fragments {
            guard fragment.offset >= cursor else {
                throw KaitoError.malformed("tar sparse map is not ascending")
            }
            let end = try Checked.add(fragment.offset, fragment.size)
            guard end <= realSize else {
                throw KaitoError.malformed("tar sparse fragment exceeds the real size")
            }
            stored = try Checked.add(stored, fragment.size)
            cursor = end
            if fragment.size > 0 { kept.append(fragment) }
        }
        self.realSize = realSize
        self.fragments = kept
        self.storedSize = stored
    }
}

// MARK: - sparse map の読み取り

extension TarSparseMap {
    /// 旧 GNU の sparse header の配置（tar(5) "GNU tar Archives"）。descriptor は offset と numbytes の
    /// 12 byte octal 二つ。header に 4 個、続く拡張 block に 21 個ずつ並び、numbytes が 0 の descriptor で終わる。
    private enum OldGNULayout {
        static let magicAndVersionRange = 257..<265
        static let magicAndVersion = Array("ustar  \0".utf8)
        static let headerDescriptorOffset = 386
        static let headerDescriptorCount = 4
        static let headerIsExtendedOffset = 482
        static let realSizeRange = 483..<495
        static let descriptorSize = 24
        static let numberFieldSize = 12
        static let extensionDescriptorCount = 21
        static let extensionIsExtendedOffset = 504
    }

    /// 旧 GNU の S 型。拡張 header は格納長に含めず、fragment 本文全体だけを 512 byte に揃える。
    /// 戻り値の dataOffset は拡張 block の後ろ、fragment 本文の開始。
    static func parseOldGNU(
        header: TarHeaderBlock,
        dataOffset: UInt64,
        storedSize: UInt64,
        source: any ByteSource,
        limits: ReadLimits
    ) throws -> (map: TarSparseMap, dataOffset: UInt64) {
        typealias Layout = OldGNULayout
        guard Array(header.bytes[Layout.magicAndVersionRange]) == Layout.magicAndVersion else {
            throw KaitoError.malformed("invalid old GNU sparse header")
        }
        let realSize = try TarHeaderBlock.parseUnsigned(
            Array(header.bytes[Layout.realSizeRange]), fieldName: "GNU sparse realsize"
        )
        try Checked.size(realSize, limit: limits.maxEntrySize)
        var fragments: [TarSparseFragment] = []
        var ended = false
        func appendDescriptors(_ bytes: [UInt8], start: Int, count: Int) throws {
            for index in 0..<count {
                if ended { break }
                let position = start + index * Layout.descriptorSize
                let sizeStart = position + Layout.numberFieldSize
                let size = try TarHeaderBlock.parseUnsigned(
                    Array(bytes[sizeStart..<(sizeStart + Layout.numberFieldSize)]), fieldName: "GNU sparse numbytes"
                )
                if size == 0 { ended = true; break }
                guard fragments.count < limits.maxMetadataRecordCount else {
                    throw KaitoError.limitExceeded("tar sparse fragment count")
                }
                let offset = try TarHeaderBlock.parseUnsigned(
                    Array(bytes[position..<sizeStart]), fieldName: "GNU sparse offset"
                )
                fragments.append(TarSparseFragment(offset: offset, size: size))
            }
        }
        let headerDescriptorBytes = UInt64(Layout.headerDescriptorCount * Layout.descriptorSize)
        try Checked.size(headerDescriptorBytes, limit: limits.maxMetadataSize)
        try appendDescriptors(header.bytes, start: Layout.headerDescriptorOffset, count: Layout.headerDescriptorCount)
        var extended = header.bytes[Layout.headerIsExtendedOffset] != 0
        var blocks: UInt64 = 0
        var cursor = dataOffset
        while extended {
            guard blocks < UInt64(limits.maxMetadataRecordCount) else {
                throw KaitoError.limitExceeded("tar sparse extension count")
            }
            blocks += 1
            try Checked.size(
                Checked.add(headerDescriptorBytes, Checked.mul(blocks, UInt64(TarHeaderBlock.size))),
                limit: limits.maxMetadataSize
            )
            let end = try Checked.add(cursor, UInt64(TarHeaderBlock.size))
            guard end <= source.length else { throw KaitoError.truncated }
            let block = try readByteRange(source: source, offset: cursor, count: TarHeaderBlock.size)
            try appendDescriptors(block, start: 0, count: Layout.extensionDescriptorCount)
            extended = block[Layout.extensionIsExtendedOffset] != 0
            cursor = end
        }
        let map = try TarSparseMap(realSize: realSize, fragments: fragments, limits: limits)
        guard map.storedSize == storedSize else {
            throw KaitoError.malformed("GNU sparse fragments do not match the stored size")
        }
        return (map, cursor)
    }

    /// pax の GNU.sparse.* から fragment map を組む。戻り値の dataOffset は fragment 本文の開始（1.0 では
    /// 本文先頭の map block の後ろ）、name は GNU.sparse.name。
    static func parsePAX(
        _ pax: TarPAXRecords,
        dataOffset: UInt64,
        storedSize: UInt64,
        source: any ByteSource,
        limits: ReadLimits
    ) throws -> (map: TarSparseMap, dataOffset: UInt64, version: String, name: [UInt8]?) {
        func decimal(_ bytes: ArraySlice<UInt8>, _ field: String) throws -> UInt64 {
            guard !bytes.isEmpty, bytes.count <= 20 else { throw KaitoError.malformed("invalid \(field)") }
            var value: UInt64 = 0
            for byte in bytes {
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else {
                    throw KaitoError.malformed("invalid \(field)")
                }
                value = try Checked.add(Checked.mul(value, 10), UInt64(byte - UInt8(ascii: "0")))
            }
            return value
        }
        func fragments(fromList list: [UInt8], field: String) throws -> [TarSparseFragment] {
            let numbers = try list.split(separator: UInt8(ascii: ","), omittingEmptySubsequences: false)
                .map { try decimal($0, field) }
            guard numbers.count.isMultiple(of: 2) else { throw KaitoError.malformed("odd \(field) length") }
            guard numbers.count / 2 <= limits.maxMetadataRecordCount else {
                throw KaitoError.limitExceeded("tar sparse fragment count")
            }
            return stride(from: 0, to: numbers.count, by: 2).map {
                TarSparseFragment(offset: numbers[$0], size: numbers[$0 + 1])
            }
        }

        if let major = pax["GNU.sparse.major"] {
            // 1.0: map は本文先頭の 512 byte block 列。改行区切りの十進で「fragment 数、offset、size…」。
            let minor = pax["GNU.sparse.minor"] ?? []
            guard try decimal(major[...], "GNU.sparse.major") == 1, try decimal(minor[...], "GNU.sparse.minor") == 0 else {
                throw KaitoError.unsupportedMethod("GNU sparse format \(String(decoding: major, as: UTF8.self)).\(String(decoding: minor, as: UTF8.self))")
            }
            guard let realsizeBytes = pax["GNU.sparse.realsize"] else {
                throw KaitoError.malformed("GNU sparse 1.0 without realsize")
            }
            let realSize = try decimal(realsizeBytes[...], "GNU.sparse.realsize")
            try Checked.size(realSize, limit: limits.maxEntrySize)
            // map を 512 byte ずつ読む。数値の個数が 1 + 2n になるまで、metadata 上限の範囲で続ける。
            var numbers: [UInt64] = []
            var consumedBlocks: UInt64 = 0
            var pending: [UInt8] = []
            var expectedCount: Int?
            while expectedCount.map({ numbers.count < 1 + 2 * $0 }) ?? true {
                let offset = try Checked.add(dataOffset, Checked.mul(consumedBlocks, 512))
                guard try Checked.mul(consumedBlocks + 1, 512) <= storedSize,
                      try Checked.add(offset, 512) <= source.length else {
                    throw KaitoError.malformed("GNU sparse 1.0 map exceeds the entry body")
                }
                try Checked.size(Checked.mul(consumedBlocks + 1, 512), limit: limits.maxMetadataSize)
                let block = try readByteRange(source: source, offset: offset, count: 512)
                consumedBlocks += 1
                for byte in block {
                    if byte == UInt8(ascii: "\n") {
                        numbers.append(try decimal(pending[...], "GNU.sparse map"))
                        pending.removeAll(keepingCapacity: true)
                        if expectedCount == nil {
                            guard let first = numbers.first, first <= UInt64(limits.maxMetadataRecordCount) else {
                                throw KaitoError.limitExceeded("tar sparse fragment count")
                            }
                            expectedCount = Int(first)
                        }
                        if let expectedCount, numbers.count == 1 + 2 * expectedCount { break }
                    } else if byte == 0 {
                        // block の残りは padding。
                        break
                    } else {
                        pending.append(byte)
                        guard pending.count <= 20 else { throw KaitoError.malformed("GNU sparse map number") }
                    }
                }
            }
            let count = expectedCount ?? 0
            let list = stride(from: 0, to: count, by: 1).map {
                TarSparseFragment(offset: numbers[1 + 2 * $0], size: numbers[2 + 2 * $0])
            }
            let map = try TarSparseMap(realSize: realSize, fragments: list, limits: limits)
            let mapBytes = try Checked.mul(consumedBlocks, 512)
            guard try Checked.sub(storedSize, mapBytes) == map.storedSize else {
                throw KaitoError.malformed("GNU sparse 1.0 fragments do not match the stored size")
            }
            return (map, try Checked.add(dataOffset, mapBytes), "GNU.sparse 1.0", pax["GNU.sparse.name"])
        }

        guard let sizeBytes = pax["GNU.sparse.size"] else {
            throw KaitoError.malformed("GNU sparse entry without size")
        }
        let realSize = try decimal(sizeBytes[...], "GNU.sparse.size")
        try Checked.size(realSize, limit: limits.maxEntrySize)
        let list: [TarSparseFragment]
        let version: String
        if let map = pax["GNU.sparse.map"] {
            list = try fragments(fromList: map, field: "GNU.sparse.map")
            version = "GNU.sparse 0.1"
        } else if let pairs = pax["GNU.sparse.map.0.0"] {
            list = try fragments(fromList: pairs, field: "GNU.sparse.offset/numbytes")
            if let declared = pax["GNU.sparse.numblocks"] {
                guard try decimal(declared[...], "GNU.sparse.numblocks") == UInt64(list.count) else {
                    throw KaitoError.malformed("GNU sparse 0.0 numblocks mismatch")
                }
            }
            version = "GNU.sparse 0.0"
        } else {
            throw KaitoError.malformed("GNU sparse entry without a map")
        }
        let map = try TarSparseMap(realSize: realSize, fragments: list, limits: limits)
        guard storedSize == map.storedSize else {
            throw KaitoError.malformed("GNU sparse fragments do not match the stored size")
        }
        return (map, dataOffset, version, pax["GNU.sparse.name"])
    }
}

/// 格納された fragment 列と 0 埋めの穴から、展開後の file を順に返す。
final class TarSparseDecompressor: Decompressor {
    private let source: any ByteSource
    private let dataOffset: UInt64
    private let map: TarSparseMap
    private var position: UInt64 = 0
    private var fragmentIndex = 0
    private var storedCursor: UInt64
    private(set) var isFinished: Bool

    init(source: any ByteSource, dataOffset: UInt64, map: TarSparseMap) throws {
        guard try Checked.add(dataOffset, map.storedSize) <= source.length else {
            throw KaitoError.truncated
        }
        self.source = source
        self.dataOffset = dataOffset
        self.map = map
        self.storedCursor = dataOffset
        self.isFinished = map.realSize == 0
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !isFinished else { return 0 }
        let remainingTotal = map.realSize - position
        let capacity = try Checked.toInt(min(UInt64(buffer.count), remainingTotal))
        var produced = 0
        while produced < capacity {
            let want = UInt64(capacity - produced)
            let destination = UnsafeMutableRawBufferPointer(rebasing: buffer[produced..<capacity])
            if fragmentIndex < map.fragments.count {
                let fragment = map.fragments[fragmentIndex]
                if position < fragment.offset {
                    // 穴: 次の fragment までを 0 で埋める。
                    let hole = try Checked.toInt(min(want, fragment.offset - position))
                    destination.baseAddress!.initializeMemory(as: UInt8.self, repeating: 0, count: hole)
                    produced += hole
                    position += UInt64(hole)
                    continue
                }
                let within = position - fragment.offset
                let left = fragment.size - within
                let count = try Checked.toInt(min(want, left))
                let read = try source.read(
                    into: UnsafeMutableRawBufferPointer(rebasing: destination[..<count]), at: storedCursor
                )
                guard read > 0, read <= count else { throw KaitoError.truncated }
                produced += read
                position += UInt64(read)
                storedCursor += UInt64(read)
                if position == fragment.offset + fragment.size { fragmentIndex += 1 }
            } else {
                // 最後の fragment の後ろは file 末尾までの穴。
                let hole = try Checked.toInt(min(want, map.realSize - position))
                destination.baseAddress!.initializeMemory(as: UInt8.self, repeating: 0, count: hole)
                produced += hole
                position += UInt64(hole)
            }
        }
        if position == map.realSize { isFinished = true }
        return produced
    }
}
