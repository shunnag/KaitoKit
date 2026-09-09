// xar の公開形式説明・xar(1)、RFC 1950/1951、LZMA SDK lzma-specification.txt、
// XZ file-format spec に対応する利用者提供の実測 byte 表に基づくクリーンルーム実装。
// xar / libarchive / 7-Zip / XADMaster / The Unarchiver 等、他の archiver の source は参照していない。

struct XarHeader {
    enum ChecksumAlgorithm: UInt32 {
        case none = 0, sha1 = 1, md5 = 2, sha256 = 3, sha512 = 4
    }
    let size: UInt64
    let compressedTOCLength: UInt64
    let uncompressedTOCLength: UInt64
    let checksumAlgorithm: ChecksumAlgorithm?
    let heapStart: UInt64

    static func probe(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 28 && bytes.prefix(4).elementsEqual([0x78, 0x61, 0x72, 0x21])
            && number(bytes, 4, 2) >= 28 && number(bytes, 6, 2) == 1
    }

    init(source: any ByteSource) throws {
        let bytes = try readByteRange(source: source, offset: 0, count: 28)
        guard bytes.prefix(4).elementsEqual([0x78, 0x61, 0x72, 0x21]) else { throw KaitoError.unsupportedFormat }
        guard Self.number(bytes, 6, 2) == 1 else { throw KaitoError.unsupportedFormat }
        size = Self.number(bytes, 4, 2)
        guard size >= 28 else { throw KaitoError.malformed("xar header size") }
        compressedTOCLength = Self.number(bytes, 8, 8)
        uncompressedTOCLength = Self.number(bytes, 16, 8)
        checksumAlgorithm = ChecksumAlgorithm(rawValue: UInt32(Self.number(bytes, 24, 4)))
        heapStart = try Checked.add(size, compressedTOCLength)
        guard heapStart <= source.length else { throw KaitoError.truncated }
    }

    private static func number(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> UInt64 {
        bytes[offset..<offset + count].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
