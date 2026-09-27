/// GyoshukuKit の LHA 編集用。header の解析を通った member の範囲。
@_spi(LHARawLayout)
public struct LHAMemberLayout: Sendable, Equatable {
    /// [headerOffset, dataOffset)。level 1 は拡張 header の列を含む。
    public let headerRange: Range<UInt64>
    /// level 1 は skip size から拡張 header を除いた長さ、または 0x42 の値。
    public let dataRange: Range<UInt64>
    public let headerLevel: UInt8
    public let method: String
    public let osID: UInt8?
    public let crc16: UInt16
    /// ArchiveReader.entries の index。公開しない member は nil。
    public let entryIndex: Int?
}

@_spi(LHARawLayout)
public enum LHAArchiveTerminator: Sendable, Equatable {
    case zeroByte(offset: UInt64)
    case emptyNameDirectoryMember(Range<UInt64>)
    case endOfFile
}

@_spi(LHARawLayout)
public enum LHATrailingBytes: Sendable, Equatable {
    case none
    case zeros(count: UInt64)
    case nonZero(count: UInt64)
    case unchecked(count: UInt64)
    case notApplicable
}

@_spi(LHARawLayout)
public struct LHAArchiveLayout: Sendable {
    public let archiveLength: UInt64
    /// 最初の header の offset（SFX の prefix 長）。member が無ければ終端の offset。
    public let firstHeaderOffset: UInt64
    /// 最後の member の data の終わり。member が無ければ firstHeaderOffset。
    public let endOfMembersOffset: UInt64
    public let terminator: LHAArchiveTerminator
    public let trailingBytes: LHATrailingBytes

    private let records: [LHAEntryRecord]
    private let unpublishedMembers: [LHAUnpublishedMember]

    init(archiveLength: UInt64, firstHeaderOffset: UInt64,
         terminator: LHAArchiveTerminator, trailingBytes: LHATrailingBytes,
         records: [LHAEntryRecord], unpublishedMembers: [LHAUnpublishedMember]) {
        self.archiveLength = archiveLength
        self.firstHeaderOffset = firstHeaderOffset
        self.terminator = terminator
        self.trailingBytes = trailingBytes
        self.records = records
        self.unpublishedMembers = unpublishedMembers
        let publishedEnd = records.last.map { $0.dataOffset + $0.compressedSize } ?? firstHeaderOffset
        let unpublishedEnd = unpublishedMembers.last.map {
            $0.record.dataOffset + $0.record.compressedSize
        } ?? firstHeaderOffset
        self.endOfMembersOffset = max(publishedEnd, unpublishedEnd)
    }

    /// 書庫の順の member 数。公開しない member を含み、空名の -lhd- の終端は含まない。
    public var memberCount: Int { records.count + unpublishedMembers.count }
    public var unpublishedMemberCount: Int { unpublishedMembers.count }

    /// position は書庫の順（0..<memberCount）。範囲外は KaitoError.notFound。
    public func member(at position: Int) throws -> LHAMemberLayout {
        guard position >= 0, position < memberCount else {
            throw KaitoError.notFound("LHA member position \(position)")
        }
        let (record, entryIndex) = record(at: position)
        let headerOffset: UInt64
        if position == 0 {
            headerOffset = firstHeaderOffset
        } else {
            let previous = self.record(at: position - 1).record
            headerOffset = previous.dataOffset + previous.compressedSize
        }
        return LHAMemberLayout(
            headerRange: headerOffset..<record.dataOffset,
            dataRange: record.dataOffset..<(record.dataOffset + record.compressedSize),
            headerLevel: record.headerLevel, method: record.method, osID: record.osID,
            crc16: record.crc16, entryIndex: entryIndex
        )
    }

    private func record(at position: Int) -> (record: LHAEntryRecord, entryIndex: Int?) {
        // 公開しない member だけを二分探索し、通常の書庫には対応表を持たせない。
        var lower = 0
        var upper = unpublishedMembers.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if unpublishedMembers[middle].position < position {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        if lower < unpublishedMembers.count, unpublishedMembers[lower].position == position {
            return (unpublishedMembers[lower].record, nil)
        }
        let entryIndex = position - lower
        return (records[entryIndex], entryIndex)
    }
}
