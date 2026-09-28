import Foundation

// 形式実装と公開 Reader 層の間だけで使う最小契約。
protocol FormatReader: AnyObject {
    var format: ArchiveFormat { get }
    var entries: [ArchiveEntry] { get }
    var nameEncoding: String.Encoding? { get }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream
    func rawRecord(for entry: ArchiveEntry, limits: ReadLimits) throws -> RawEntryRecord?
    func zipRawRecordLayout(at index: Int, limits: ReadLimits) throws -> ZipRawRecordLayout?
    func zipStream(at index: Int, limits: ReadLimits, aesKey: ZipAESKeyMaterial?, storedOnly: Bool) throws -> EntryStream?
    func setPassword(_ password: String?)

    /// 解析済みの不変状態を共有し、復号・cache・password の可変状態だけを新しくした reader。
    /// 共有できない形式は nil を返し、ArchiveReader は source から開き直す。
    /// 戻り値は別の isolation domain へ送れる。
    func reopened(options: ReaderOptions) throws -> sending (any FormatReader)?

    /// 復号に必須の resource / hash が無い entry を、password provider に問う前に診断する。
    func validateEncryptionSupport(for entry: ArchiveEntry) throws
}

extension FormatReader {
    // 独立した生レコードの移動を検証していない形式は範囲を公開しない。
    func rawRecord(for entry: ArchiveEntry, limits: ReadLimits) throws -> RawEntryRecord? { nil }
    func zipRawRecordLayout(at index: Int, limits: ReadLimits) throws -> ZipRawRecordLayout? { nil }
    func zipStream(at index: Int, limits: ReadLimits, aesKey: ZipAESKeyMaterial?, storedOnly: Bool) throws -> EntryStream? { nil }

    // 名前 encoding を持たない形式向けの既定値。
    var nameEncoding: String.Encoding? { nil }

    // 暗号を持たない形式は password 更新を無視する。
    func setPassword(_ password: String?) {}

    // 解析結果を共有する reopen を持たない形式は、ArchiveReader に開き直しを任せる。
    func reopened(options: ReaderOptions) throws -> sending (any FormatReader)? { nil }

    // 暗号を持たない形式、または対応状況を entry ごとに診断しない形式は何もしない。
    func validateEncryptionSupport(for entry: ArchiveEntry) throws {}

    /// `entries` に載っている entry だけを受け付け、その index を返す。他の reader の entry や
    /// 古い一覧の entry は `.notFound("<label> entry index N")`。
    @discardableResult
    func recordIndex(of entry: ArchiveEntry, label: String) throws -> Int {
        guard entries.indices.contains(entry.index), entries[entry.index] == entry else {
            throw KaitoError.notFound("\(label) entry index \(entry.index)")
        }
        return entry.index
    }
}
