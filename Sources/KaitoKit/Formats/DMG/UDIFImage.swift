import Compression
import Foundation

// Apple の UDIF disk image（.dmg）。実装入力は Joachim Metz の "Mac OS disk image types"（libmodi の GFDL 文書、
// `inbox/dmg/libmodi-disk-image-types.asciidoc`）の koly / mish / blkx の表と、CC0 の Archive Team wiki、
// hdiutil が書いた image の黒箱観察である。全 field は big-endian。2026-09-22 の検証記録を参照。

enum UDIFBytes {
    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }
    static func u64(_ b: [UInt8], _ o: Int) -> UInt64 { UInt64(u32(b, o)) << 32 | UInt64(u32(b, o + 4)) }
}

/// koly（UDIF resource file、file 末尾の 512 byte）。
struct UDIFTrailer {
    static let signature: [UInt8] = Array("koly".utf8)
    static let size = 512
    let version: UInt32
    let flags: UInt32
    let dataForkOffset: UInt64
    let dataForkLength: UInt64
    let xmlOffset: UInt64
    let xmlLength: UInt64
    let sectorCount: UInt64

    init?(_ b: [UInt8]) {
        guard b.count >= Self.size, Array(b[0..<4]) == Self.signature, UDIFBytes.u32(b, 8) == 512 else { return nil }
        version = UDIFBytes.u32(b, 4)
        flags = UDIFBytes.u32(b, 12)
        dataForkOffset = UDIFBytes.u64(b, 24)
        dataForkLength = UDIFBytes.u64(b, 32)
        xmlOffset = UDIFBytes.u64(b, 216)
        xmlLength = UDIFBytes.u64(b, 224)
        sectorCount = UDIFBytes.u64(b, 492)
    }

    /// file 末尾の koly を読む。無ければ nil。
    static func read(source: any ByteSource) throws -> UDIFTrailer? {
        guard source.length >= UInt64(size) else { return nil }
        return UDIFTrailer(try readByteRange(source: source, offset: source.length - UInt64(size), count: size))
    }
}

/// blkx の 1 chunk（BLKXChunkEntry）。sector は disk 全体に対する絶対 sector 番号にしてある。
struct UDIFChunk {
    enum Kind {
        case zero            // 0x00000000: 0 埋め
        case raw             // 0x00000001
        case ignore          // 0x00000002: 読まない領域（0 として見せる）
        case adc             // 0x80000004: Apple Data Compression（非対応）
        case zlib            // 0x80000005
        case bzip2           // 0x80000006
        case lzfse           // 0x80000007
        case xz              // 0x80000008（hdiutil の ULMO は xz container、黒箱）
        case unknown(UInt32)
    }
    let kind: Kind
    let sector: UInt64
    let sectorCount: UInt64
    let dataOffset: UInt64      // file 内の絶対 offset（data fork offset を加えたもの）
    let dataLength: UInt64

    var byteOffset: UInt64 { sector * 512 }
    var byteCount: UInt64 { sectorCount * 512 }
}

/// blkx（mish table）1 つ = disk の 1 区画（partition map、partition、free space …）。
struct UDIFBlockTable {
    let name: String
    let identifier: Int
    let firstSector: UInt64
    let sectorCount: UInt64
    let chunks: [UDIFChunk]
}

/// koly + XML plist から chunk 表を組み立て、展開後の disk 全体を 512 byte sector の連続として見せる。
// cache は lock で守る。
final class UDIFDiskByteSource: ByteSource, @unchecked Sendable {
    let trailer: UDIFTrailer
    let tables: [UDIFBlockTable]
    /// disk 順に並べた chunk（zero / ignore を含む）。
    let chunks: [UDIFChunk]
    let length: UInt64
    private let file: any ByteSource
    private let limits: ReadLimits
    private let lock = NSLock()
    private var cache: [(index: Int, data: [UInt8])] = []
    private static let cacheEntries = 4
    /// 1 chunk の展開後サイズの上限（hdiutil は 2048 sector = 1 MiB）。
    static let maximumChunkBytes: UInt64 = 64 << 20

    init(file: any ByteSource, trailer: UDIFTrailer, limits: ReadLimits) throws {
        self.file = file
        self.trailer = trailer
        self.limits = limits
        guard trailer.version == 4 else { throw KaitoError.unsupportedMethod("UDIF version \(trailer.version)") }
        // 各 chunk の sector 範囲を調べる前に、disk 全体が byte 数へ変換できることを保証する。
        length = try Checked.mul(trailer.sectorCount, 512)
        guard trailer.xmlLength > 0 else { throw KaitoError.unsupportedMethod("UDIF image without a block map") }
        try Checked.size(trailer.xmlLength, limit: limits.maxMetadataSize)
        guard try Checked.add(trailer.xmlOffset, trailer.xmlLength) <= file.length else { throw KaitoError.truncated }
        let xml = try readByteRange(source: file, offset: trailer.xmlOffset, count: Int(trailer.xmlLength))
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(xml), format: nil) as? [String: Any],
              let resources = plist["resource-fork"] as? [String: Any],
              let blocks = resources["blkx"] as? [[String: Any]] else {
            throw KaitoError.malformed("udif plist")
        }
        var tables: [UDIFBlockTable] = []
        var all: [UDIFChunk] = []
        for block in blocks {
            guard let data = block["Data"] as? Data else { throw KaitoError.malformed("udif blkx data") }
            let b = [UInt8](data)
            // mish: signature、version 1、start sector、sector count、…、entry 数（offset 200）、entry（40 byte）× n。
            guard b.count >= 204, Array(b[0..<4]) == Array("mish".utf8), UDIFBytes.u32(b, 4) == 1 else {
                throw KaitoError.malformed("udif mish header")
            }
            let firstSector = UDIFBytes.u64(b, 8)
            let sectorCount = UDIFBytes.u64(b, 16)
            let count = Int(UDIFBytes.u32(b, 200))
            guard b.count >= 204 + count * 40, count <= 1 << 20 else { throw KaitoError.malformed("udif mish entry count") }
            var chunks: [UDIFChunk] = []
            for index in 0..<count {
                let o = 204 + index * 40
                let type = UDIFBytes.u32(b, o)
                let chunkSector = UDIFBytes.u64(b, o + 8)
                let chunkCount = UDIFBytes.u64(b, o + 16)
                let dataOffset = UDIFBytes.u64(b, o + 24)
                let dataLength = UDIFBytes.u64(b, o + 32)
                let kind: UDIFChunk.Kind
                switch type {
                case 0x0000_0000: kind = .zero
                case 0x0000_0001: kind = .raw
                case 0x0000_0002: kind = .ignore
                case 0x8000_0004: kind = .adc
                case 0x8000_0005: kind = .zlib
                case 0x8000_0006: kind = .bzip2
                case 0x8000_0007: kind = .lzfse
                case 0x8000_0008: kind = .xz
                case 0x7FFF_FFFE: continue                 // comment
                case 0xFFFF_FFFF: continue                 // terminator
                default: kind = .unknown(type)
                }
                guard chunkCount > 0 else { continue }
                let absolute = try Checked.add(firstSector, chunkSector)
                guard try Checked.add(absolute, chunkCount) <= trailer.sectorCount else { throw KaitoError.malformed("udif chunk beyond the disk") }
                let fileOffset = try Checked.add(trailer.dataForkOffset, dataOffset)
                if case .raw = kind { guard dataLength == chunkCount * 512 else { throw KaitoError.malformed("udif raw chunk size") } }
                if dataLength > 0 { guard try Checked.add(fileOffset, dataLength) <= file.length else { throw KaitoError.truncated } }
                chunks.append(UDIFChunk(kind: kind, sector: absolute, sectorCount: chunkCount, dataOffset: fileOffset, dataLength: dataLength))
            }
            let name = (block["Name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (block["CFName"] as? String) ?? ""
            let identifier = Int((block["ID"] as? String) ?? "") ?? tables.count
            tables.append(UDIFBlockTable(name: name, identifier: identifier, firstSector: firstSector, sectorCount: sectorCount, chunks: chunks))
            all.append(contentsOf: chunks)
        }
        all.sort { $0.sector < $1.sector }
        // chunk は重ならず、隙間は 0 として読む。
        for index in 1..<max(all.count, 1) where all[index].sector < all[index - 1].sector + all[index - 1].sectorCount {
            throw KaitoError.malformed("udif chunks overlap")
        }
        self.tables = tables
        chunks = all
    }

    /// `offset` を含む chunk の index（隙間なら nil）。
    private func chunkIndex(containing offset: UInt64) -> Int? {
        var low = 0, high = chunks.count
        while low < high {
            let mid = (low + high) / 2
            if chunks[mid].byteOffset + chunks[mid].byteCount <= offset { low = mid + 1 }
            else if chunks[mid].byteOffset > offset { high = mid }
            else { return mid }
        }
        return nil
    }

    /// 次の chunk の開始 offset（隙間の長さを決めるため）。
    private func nextChunkOffset(after offset: UInt64) -> UInt64 {
        var low = 0, high = chunks.count
        while low < high {
            let mid = (low + high) / 2
            if chunks[mid].byteOffset <= offset { low = mid + 1 } else { high = mid }
        }
        return low < chunks.count ? chunks[low].byteOffset : length
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        guard offset < length, !buffer.isEmpty else { return 0 }
        let count = Int(min(UInt64(buffer.count), length - offset))
        var written = 0
        while written < count {
            let position = offset + UInt64(written)
            guard let index = chunkIndex(containing: position) else {
                let gapEnd = nextChunkOffset(after: position)
                let take = Int(min(UInt64(count - written), gapEnd - position))
                buffer.baseAddress!.advanced(by: written).initializeMemory(as: UInt8.self, repeating: 0, count: take)
                written += take
                continue
            }
            let chunk = chunks[index]
            let inChunk = Int(position - chunk.byteOffset)
            let take = Int(min(UInt64(count - written), chunk.byteCount - UInt64(inChunk)))
            switch chunk.kind {
            case .zero, .ignore:
                buffer.baseAddress!.advanced(by: written).initializeMemory(as: UInt8.self, repeating: 0, count: take)
            case .raw:
                var total = 0
                while total < take {
                    let read = try file.read(into: UnsafeMutableRawBufferPointer(rebasing: buffer[(written + total)..<(written + take)]),
                                             at: chunk.dataOffset + UInt64(inChunk + total))
                    guard read > 0 else { throw KaitoError.truncated }
                    total += read
                }
            default:
                let decoded = try decodedChunk(index)
                decoded.withUnsafeBytes { bytes in
                    buffer.baseAddress!.advanced(by: written).copyMemory(from: bytes.baseAddress!.advanced(by: inChunk), byteCount: take)
                }
            }
            written += take
        }
        return written
    }

    private func decodedChunk(_ index: Int) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache.firstIndex(where: { $0.index == index }) {
            let entry = cache.remove(at: hit)
            cache.append(entry)
            return entry.data
        }
        let chunk = chunks[index]
        guard chunk.byteCount <= Self.maximumChunkBytes else { throw KaitoError.unsupportedMethod("UDIF chunk of \(chunk.byteCount) bytes") }
        let expected = Int(chunk.byteCount)
        let output: [UInt8]
        switch chunk.kind {
        case .zlib:
            output = try Self.drain(DeflateDecompressor(source: file, offset: chunk.dataOffset, compressedSize: chunk.dataLength, zlibWrapped: true), expected: expected)
        case .bzip2:
            output = try Self.drain(Bzip2Decompressor(source: file, offset: chunk.dataOffset, compressedSize: chunk.dataLength), expected: expected)
        case .xz:
            output = try Self.drain(XZDecompressor(source: file, offset: chunk.dataOffset, compressedSize: chunk.dataLength, limits: limits), expected: expected)
        case .lzfse:
            let input = try readByteRange(source: file, offset: chunk.dataOffset, count: Int(chunk.dataLength))
            var result = [UInt8](repeating: 0, count: expected)
            let produced = input.withUnsafeBufferPointer { src in
                result.withUnsafeMutableBufferPointer { dst in
                    compression_decode_buffer(dst.baseAddress!, expected, src.baseAddress!, input.count, nil, COMPRESSION_LZFSE)
                }
            }
            guard produced == expected else { throw KaitoError.malformed("udif lzfse chunk expanded to \(produced) bytes") }
            output = result
        case .adc:
            throw KaitoError.unsupportedMethod("UDIF ADC compression (UDCO)")
        case .unknown(let type):
            throw KaitoError.unsupportedMethod("UDIF chunk type 0x\(String(type, radix: 16))")
        case .zero, .raw, .ignore:
            fatalError("handled inline")
        }
        cache.append((index, output))
        if cache.count > Self.cacheEntries { cache.removeFirst() }
        return output
    }

    private static func drain(_ decompressor: any Decompressor, expected: Int) throws -> [UInt8] {
        var result = [UInt8](repeating: 0, count: expected)
        var filled = 0
        try result.withUnsafeMutableBytes { bytes in
            while filled < expected {
                let count = try decompressor.read(into: UnsafeMutableRawBufferPointer(rebasing: bytes[filled...]))
                if count == 0 { break }
                filled += count
            }
        }
        guard filled == expected else { throw KaitoError.malformed("udif chunk expanded to \(filled) bytes") }
        // 宣言長に達しても終端・checksum が未検証の場合がある。余剰出力は cache せず拒否する。
        if !decompressor.isFinished {
            var byte: UInt8 = 0
            let additional = try withUnsafeMutableBytes(of: &byte) { try decompressor.read(into: $0) }
            guard additional == 0 else { throw KaitoError.malformed("udif chunk output exceeds its declared size") }
            guard decompressor.isFinished else { throw KaitoError.truncated }
        }
        return result
    }
}
