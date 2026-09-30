import Foundation

// 検証済み payload の配置と、書庫全体の名前判定前の metadata。
struct TarEntryRecord: Sendable {
    let dataOffset: UInt64
    let size: UInt64
    var sparse: TarSparseMap? = nil
}

struct TarPendingText {
    let bytes: [UInt8]
    let declaredEncoding: String.Encoding?
}

struct TarPendingEntry {
    let name: TarPendingText
    let link: TarPendingText?
    let kind: EntryKind
    let size: UInt64
    let isIncomplete: Bool
    let modificationDate: Date?
    let permissions: UInt16
    let formatSpecific: [String: String]
    var storedSize: UInt64? = nil
}
