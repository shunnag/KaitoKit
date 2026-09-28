import Foundation

// 参照仕様: Igor Pavlov, LZMA SDK lzma-specification.txt (2015-06-14)、
// 「lzma file format」と「Range Decoder」。既存 raw LZMA decoder を再利用する。
struct LZMAAloneHeader {
    let properties: [UInt8]
    let dictionarySize: UInt64
    let uncompressedSize: UInt64?

    init(bytes: [UInt8], limits: ReadLimits) throws {
        // 13-byte header と range coder の初期値 5 bytes が必要。
        guard bytes.count >= 18 else { throw KaitoError.truncated }
        guard bytes[0] < 9 * 5 * 5, bytes[13] == 0 else {
            throw KaitoError.malformed("invalid LZMA_Alone properties or range prefix")
        }
        properties = Array(bytes[..<5])
        dictionarySize = UInt64(bytes[1])
            | (UInt64(bytes[2]) << 8)
            | (UInt64(bytes[3]) << 16)
            | (UInt64(bytes[4]) << 24)
        try Checked.size(max(4_096, dictionarySize), limit: limits.maxDictionarySize)
        var size: UInt64 = 0
        for index in 0..<8 {
            size |= UInt64(bytes[5 + index]) << (index * 8)
        }
        if size == UInt64.max {
            uncompressedSize = nil
        } else {
            try Checked.size(size, limit: limits.maxEntrySize)
            try Checked.size(size, limit: limits.maxTotalUncompressedSize)
            uncompressedSize = size
        }
    }

    static func read(source: any ByteSource, limits: ReadLimits) throws -> Self {
        try Self(bytes: readByteRange(source: source, offset: 0, count: 18), limits: limits)
    }

    static func isPlausible(_ bytes: [UInt8], limits: ReadLimits) -> Bool {
        guard let header = try? Self(bytes: bytes, limits: limits) else { return false }
        let lc = Int(bytes[0]) % 9
        let lp = Int(bytes[0]) / 9 % 5
        let pb = Int(bytes[0]) / 45
        // magic が無いため検出は保守的に行う。通常の 2^n / 3*2^n 辞書だけを
        // 候補とし、ゼロ埋めを拒否する。raw decoder 自体の受理範囲は狭めない。
        let dictionary = header.dictionarySize
        let isPowerOfTwo = dictionary > 0 && dictionary & (dictionary - 1) == 0
        let third = dictionary / 3
        let isThreeTimesPowerOfTwo = dictionary.isMultiple(of: 3)
            && third > 0 && third & (third - 1) == 0
        return lc + lp <= 4 && pb <= 4 && dictionary >= 4_096
            && (isPowerOfTwo || isThreeTimesPowerOfTwo)
    }
}
