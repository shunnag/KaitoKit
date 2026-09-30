import Foundation

// LHAHeaderParser が検証した member と、LHAEntryPublisher が公開する書庫の値。
struct LHAEntryRecord: Sendable {
    let method: String
    let dataOffset: UInt64
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let crc16: UInt16
    let headerLevel: UInt8
    let osID: UInt8?
}

struct LHAUnpublishedMember: Sendable {
    let position: Int
    let record: LHAEntryRecord
}

struct LHAParsedArchive {
    let entries: [ArchiveEntry]
    let records: [LHAEntryRecord]
    let nameEncoding: String.Encoding?
    let firstHeaderOffset: UInt64
    let terminator: LHAArchiveTerminator?
    let unpublishedMembers: [LHAUnpublishedMember]
}

/// 文字コード判定前の member。payload の境界・サイズは解析時に検証済み。
struct LHAPendingEntry {
    let rawName: [UInt8]
    let declaredEncoding: String.Encoding?
    let method: String
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let modificationDate: Date?
    let permissions: UInt16?
    let crc16: UInt16
    let headerLevel: UInt8
    let osID: UInt8?
    let fromWindows: Bool
    let attribute: UInt8
    let directoryHint: Bool
    let extended: LHAExtendedHeader
    let headerOffset: UInt64
    let dataOffset: UInt64
}
