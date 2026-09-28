// 参照仕様: PKWARE APPNOTE.TXT 6.3.x。ZIP の record 署名・固定長・extra ID・flag bit・method 番号に名前を付ける。
// 名前を付けるのは読取が扱う値だけ。未知の値は呼出側の `default:` がそのまま扱う。

/// record 先頭 4 byte の署名（little-endian で読んだ値）。APPNOTE §4.3。
enum ZipSignature {
    static let localHeader: UInt32 = 0x0403_4b50
    static let dataDescriptor: UInt32 = 0x0807_4b50
    static let centralHeader: UInt32 = 0x0201_4b50
    static let endOfCentralDirectory: UInt32 = 0x0605_4b50
    static let zip64End: UInt32 = 0x0606_4b50
    static let zip64Locator: UInt32 = 0x0706_4b50
}

/// 可変長部を除いた固定部の byte 数。EOCD の 22 byte は `ZipEndRecords.endMinimumSize`。
enum ZipRecordSize {
    static let localHeader = 30
    static let centralHeader = 46
    static let zip64Locator = 20
    /// ZIP64 EOCD の署名から central directory offset までの固定部。
    static let zip64EndFixed = 56
    /// ZIP64 EOCD の size 欄が数えない先頭部（署名 4 byte と size 欄 8 byte）。
    static let zip64EndLeadingFields = 12
    /// ZIP64 EOCD の size 欄の最小値（固定部 56 から先頭部 12 を除いた値）。
    static let zip64EndMinimumPayload = 44
}

/// extra field の header ID。APPNOTE §4.5 / §4.6。
enum ZipExtraFieldID {
    static let zip64: UInt16 = 0x0001
    static let ntfs: UInt16 = 0x000a
    static let extendedTimestamp: UInt16 = 0x5455
    static let unicodePath: UInt16 = 0x7075
    static let winZipAES: UInt16 = 0x9901
}

/// general purpose bit flag。APPNOTE §4.4.4。
enum ZipGeneralPurposeFlag {
    /// bit 0: 本文が暗号化されている。
    static let encrypted: UInt16 = 0x0001
    /// bit 1（method 14 のとき）: LZMA stream が EOS marker で終わる。
    static let lzmaEOSMarker: UInt16 = 0x0002
    /// bit 3: CRC とサイズが本文の後ろの data descriptor にある。
    static let dataDescriptor: UInt16 = 0x0008
    /// bit 6: strong encryption。読取は対応しない。
    static let strongEncryption: UInt16 = 0x0040
    /// bit 11: 名前と comment が UTF-8。
    static let utf8Names: UInt16 = 0x0800
}

/// compression method 番号。APPNOTE §4.4.5。
enum ZipMethod {
    static let stored: UInt16 = 0
    static let shrink: UInt16 = 1
    static let reduce1: UInt16 = 2
    static let reduce2: UInt16 = 3
    static let reduce3: UInt16 = 4
    static let reduce4: UInt16 = 5
    static let implode: UInt16 = 6
    static let deflate: UInt16 = 8
    static let deflate64: UInt16 = 9
    static let bzip2: UInt16 = 12
    static let lzma: UInt16 = 14
    /// Zstandard の旧 ID。現行の `zstd` と同じく展開する。
    static let zstdDeprecated: UInt16 = 20
    static let zstd: UInt16 = 93
    static let xz: UInt16 = 95
    static let jpeg: UInt16 = 96
    static let ppmd: UInt16 = 98
    /// WinZip AES の印。実際の method は 0x9901 extra に入る。
    static let winZipAES: UInt16 = 99
}
