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
