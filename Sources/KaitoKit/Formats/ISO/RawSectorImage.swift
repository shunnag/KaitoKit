import Foundation

// ECMA-130（CD-ROM の物理 sector）§14 の公開仕様に基づく。生 sector image（BIN/CUE、`.img`、`.mdf`）は
// 2352 byte の sector（sync 12 + header 4 + user data 2048 + EDC / ECC）の並びで、これを 2048 byte の論理 block
// に写して ISO 9660 / UDF の reader に渡す。Mode 2 の sector が user data の前に持つ 8 byte の sub-header と、
// sector 後ろの 96 byte の sub-channel（2448 byte 版）、sync / header を落とした 2336 byte 版は黒箱で判定する
// （logical sector 16 に ISO 9660 の `CD001` か ECMA-167 の認識列が現れる位置を採る）。EDC / ECC は検証しない。

/// 生 sector image の並び。
struct RawSectorLayout: Equatable {
    /// 1 sector の byte 数（2352、2448、2336）。
    let sectorSize: Int
    /// sector 内で 2048 byte の user data が始まる位置（Mode 1: 16、Mode 2 + sub-header: 24、2336 byte 版: 8）。
    let userDataOffset: Int
    /// sector の数。末尾の欠けた sector は user data まで揃っていれば数える（trailer だけが欠けた image）。
    let sectorCount: UInt64

    static func count(sectorSize: Int, userDataOffset: Int, length: UInt64) -> UInt64 {
        let full = length / UInt64(sectorSize)
        let remainder = length % UInt64(sectorSize)
        return full + (remainder >= UInt64(userDataOffset + userDataSize) ? 1 : 0)
    }

    static let userDataSize = 2048
    static let sync: [UInt8] = [0x00] + [UInt8](repeating: 0xFF, count: 10) + [0x00]
}

/// 生 sector の user data だけを連続した 2048 byte block として見せる。
final class RawSectorByteSource: ByteSource {
    private let inner: any ByteSource
    let layout: RawSectorLayout
    let length: UInt64

    init(inner: any ByteSource, layout: RawSectorLayout) {
        self.inner = inner
        self.layout = layout
        length = layout.sectorCount * UInt64(RawSectorLayout.userDataSize)
    }

    /// `source` が生 sector image なら包んで返す。判定は sync の並び（2352 / 2448）か、2336 byte 版では
    /// logical sector 16 の `CD001` だけを見る。ISO 9660 / UDF の記述子が見えない image は nil。
    static func wrapIfRaw(_ source: any ByteSource) throws -> RawSectorByteSource? {
        // logical sector 16 まで読める大きさが無ければ image ではない。
        guard source.length >= 17 * 2336 else { return nil }
        if let layout = try detect(source: source) {
            return RawSectorByteSource(inner: source, layout: layout)
        }
        return nil
    }

    /// 2048 byte block の image（logical sector 16 に volume descriptor がある）はそのまま、そうでなければ
    /// 生 sector image として包めるか試す。reader の入口で使う。
    static func wrapUnlessPlainImage(_ source: any ByteSource) throws -> (any ByteSource)? {
        guard source.length >= 17 * 2336 else { return nil }
        let plain = try readByteRange(source: source, offset: 32768, count: 8)
        if ISOReader.isPlausibleVolumeDescriptor(plain) || Array(plain[1..<6]) == Array("BEA01".utf8) { return nil }
        return try wrapIfRaw(source)
    }

    static func detect(source: any ByteSource) throws -> RawSectorLayout? {
        let head = try readByteRange(source: source, offset: 0, count: 2448 + 12)
        guard Array(head[0..<12]) == RawSectorLayout.sync else {
            // sync / header を持たない 2336 byte 版（sub-header 8 + user data 2048 + EDC / ECC 280）。
            return try layoutIfVolumeDescriptor(source: source, sectorSize: 2336, candidates: [8])
        }
        for sectorSize in [2352, 2448] where Array(head[sectorSize..<(sectorSize + 12)]) == RawSectorLayout.sync {
            // header の byte 15 が Sector Mode（ECMA-130 §14.2）。volume descriptor を持つ logical sector 16 の
            // sector で見る。Mode 1 は user data が 16 から、Mode 2 は 16 から（sub-header 無し）か 24 から
            // （sub-header 8 byte）。
            guard source.length >= UInt64(17 * sectorSize) else { return nil }
            let mode = try readByteRange(source: source, offset: UInt64(16 * sectorSize + 15), count: 1)[0]
            let candidates: [Int]
            switch mode {
            case 1: candidates = [16]
            case 2: candidates = [24, 16]
            default: return nil
            }
            return try layoutIfVolumeDescriptor(source: source, sectorSize: sectorSize, candidates: candidates)
        }
        return nil
    }

    /// 候補の user data 位置ごとに logical sector 16 を読み、ISO 9660 の volume descriptor か ECMA-167 の
    /// 認識列（BEA01）が見えたものを採る。
    private static func layoutIfVolumeDescriptor(source: any ByteSource, sectorSize: Int, candidates: [Int]) throws -> RawSectorLayout? {
        let sectorCount = source.length / UInt64(sectorSize)
        guard sectorCount >= 17 else { return nil }
        for offset in candidates {
            let probe = try readByteRange(source: source, offset: UInt64(16 * sectorSize + offset), count: 8)
            if ISOReader.isPlausibleVolumeDescriptor(probe) || Array(probe[1..<6]) == Array("BEA01".utf8) {
                return RawSectorLayout(sectorSize: sectorSize, userDataOffset: offset,
                                       sectorCount: RawSectorLayout.count(sectorSize: sectorSize, userDataOffset: offset, length: source.length))
            }
        }
        return nil
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        guard offset < length, !buffer.isEmpty else { return 0 }
        let userDataSize = UInt64(RawSectorLayout.userDataSize)
        let count = Int(min(UInt64(buffer.count), length - offset))
        var written = 0
        var position = offset
        // 連続する sector をまとめて 1 回で読み、user data だけを写す。
        let sectorsPerRead = min(32, Int((UInt64(count) + userDataSize - 1) / userDataSize) + 1)
        var raw = [UInt8](repeating: 0, count: layout.sectorSize * sectorsPerRead)
        while written < count {
            let sector = position / userDataSize
            let inSector = Int(position % userDataSize)
            let sectorsWanted = min(sectorsPerRead, Int((UInt64(count - written) + UInt64(inSector) + userDataSize - 1) / userDataSize))
            let rawOffset = sector * UInt64(layout.sectorSize)
            // 最後の sector は trailer が欠けていてもよい。存在する分だけ読む。
            let rawCount = Int(min(UInt64(sectorsWanted * layout.sectorSize), inner.length - rawOffset))
            let read = try raw.withUnsafeMutableBytes { bytes in
                try readFully(source: inner, into: UnsafeMutableRawBufferPointer(rebasing: bytes[..<rawCount]), at: rawOffset)
            }
            guard read == rawCount else { throw KaitoError.truncated }
            for index in 0..<sectorsWanted where written < count {
                let start = index * layout.sectorSize + layout.userDataOffset + (index == 0 ? inSector : 0)
                let take = min(RawSectorLayout.userDataSize - (index == 0 ? inSector : 0), count - written)
                guard start + take <= read else { throw KaitoError.truncated }
                raw.withUnsafeBytes { bytes in
                    buffer.baseAddress!.advanced(by: written).copyMemory(from: bytes.baseAddress!.advanced(by: start), byteCount: take)
                }
                written += take
                position += UInt64(take)
            }
        }
        return written
    }

    private func readFully(source: any ByteSource, into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        var total = 0
        while total < buffer.count {
            let read = try source.read(into: UnsafeMutableRawBufferPointer(rebasing: buffer[total...]), at: offset + UInt64(total))
            if read == 0 { break }
            total += read
        }
        return total
    }
}
