// Clean-room format inputs: 指定レポート Ch.04 の method 0・1・2・3・13・15 と圧縮 method 名前空間に基づく。
// XADMaster / The Unarchiver / stuffit-go 等の実装ソースは参照していない。
import Foundation

enum StuffItCodec {
    static func make(method: Int, source: any ByteSource, offset: UInt64, stored: UInt64,
                     size: UInt64, limits: ReadLimits) throws -> any Decompressor {
        try Checked.size(size, limit: limits.maxEntrySize)
        switch method {
        case 0:
            guard stored == size else { throw KaitoError.malformed("StuffIt stored length mismatch") }
            return try CopyDecompressor(source: source, offset: offset, compressedSize: stored)
        case 1:
            return StuffItRLE90(input: try StuffItPackedInput(source: source, offset: offset, size: stored), size: size)
        case 2:
            return try StuffItLZW(input: StuffItPackedInput(source: source, offset: offset, size: stored), size: size, limits: limits)
        case 3:
            return try StuffItHuffman(input: StuffItPackedInput(source: source, offset: offset, size: stored), size: size, limits: limits)
        case 13:
            return try StuffItMethod13(input: StuffItPackedInput(source: source, offset: offset, size: stored), size: size, limits: limits)
        case 15:
            return try StuffItArsenic(input: StuffItPackedInput(source: source, offset: offset, size: stored), size: size, limits: limits)
        default:
            throw KaitoError.unsupportedMethod("StuffIt method \(method)")
        }
    }
}
