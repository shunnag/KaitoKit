// 指定資料 Ch.07 の dispatch。圧縮属性の欠落と値ゼロは区別する。
import Foundation

enum StuffItXCodec {
    static func make(method: UInt64?, source: any ByteSource, size: UInt64, limits: ReadLimits) throws -> any Decompressor {
        try Checked.size(size, limit: limits.maxTotalUncompressedSize)
        guard let method else {
            guard source.length == size else { throw KaitoError.malformed("StuffIt X stored length") }
            return try CopyDecompressor(source: source, offset: 0, compressedSize: size)
        }
        let input = try StuffItXBitReader(source: source)
        switch method {
        case 1: return try StuffItXCyanide(input: input, size: size, limits: limits)
        case 2: return try StuffItXDarkhorse(input: input, exponent: Int(input.byte()), size: size, limits: limits)
        case 3: return try StuffItXDeflate(input: input, exponent: Int(input.byte()), size: size, limits: limits)
        case 4: return StuffItXBlend(input: input, size: size, limits: limits)
        case 5: return try StuffItXRC4Stored(input: input, size: size)
        default: throw KaitoError.unsupportedMethod("StuffIt X compression \(method)")
        }
    }
    static func name(_ method: UInt64?) -> String {
        guard let method else { return "StuffIt X Stored" }
        let names: [UInt64: String] = [0: "Brimstone", 1: "Cyanide", 2: "Darkhorse", 3: "Deflate",
                                      4: "Blend", 5: "RC4-stored", 6: "Iron", 7: "JPEG"]
        return "StuffIt X compression \(method) (\(names[method] ?? "Unknown"))"
    }
}
