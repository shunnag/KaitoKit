import Foundation

final class TarLayoutStorage: Sendable {
    struct Member: Sendable {
        let groupStart: UInt64
        let headerOffset: UInt64
        let bodyStart: UInt64
        let end: UInt64
    }
    let members: [Member]
    // 本文長は既存の配列を COW 共有し、追加の記録は member ごとに 32 B に抑える。
    let records: [TarEntryRecord]
    let imageLength: UInt64
    let endOfArchiveOffset: UInt64
    let globalHeaderRanges: [Range<UInt64>]
    let unavailableReason: TarLayoutUnavailableReason?

    var layout: TarArchiveLayout? {
        guard unavailableReason == nil else { return nil }
        return TarArchiveLayout(imageLength: imageLength, endOfArchiveOffset: endOfArchiveOffset,
                                globalHeaderRanges: globalHeaderRanges, storage: self)
    }

    init(builder: Builder, records: [TarEntryRecord], imageLength: UInt64, end: UInt64) {
        self.imageLength = imageLength; self.endOfArchiveOffset = end
        self.globalHeaderRanges = builder.globals
        var reason = builder.reason
        if reason == nil {
            var cursor: UInt64 = 0, globalIndex = 0
            for (index, member) in builder.members.enumerated() {
                while globalIndex < builder.globals.count, builder.globals[globalIndex].lowerBound == cursor {
                    cursor = builder.globals[globalIndex].upperBound; globalIndex += 1
                }
                guard index < records.count, cursor == member.groupStart,
                      member.groupStart <= member.headerOffset, member.headerOffset < member.bodyStart,
                      member.bodyStart <= member.end, member.end <= end,
                      records[index].size <= member.end - member.bodyStart else { reason = .inconsistent; break }
                cursor = member.end
            }
            while globalIndex < builder.globals.count, builder.globals[globalIndex].lowerBound == cursor {
                cursor = builder.globals[globalIndex].upperBound; globalIndex += 1
            }
            if cursor != end || end > imageLength || globalIndex != builder.globals.count || builder.members.count != records.count {
                reason = .inconsistent
            }
        }
        self.unavailableReason = reason
        self.members = reason == nil ? builder.members : []
        self.records = reason == nil ? records : []
    }

    final class Builder {
        var members: [Member] = []
        var globals: [Range<UInt64>] = []
        var groupStart: UInt64?
        var reason: TarLayoutUnavailableReason?

        init(recovery: Bool) { reason = recovery ? .recoveryMode : nil }
        func recordExtension(type: UInt8, start: UInt64, end: UInt64) {
            guard reason == nil else { return }
            if type == UInt8(ascii: "g") {
                if groupStart != nil { reason = .interleavedGlobalHeader; members = []; globals = [] }
                else { globals.append(start..<end) }
            } else if groupStart == nil { groupStart = start }
        }
        func recordMember(header: UInt64, body: UInt64, end: UInt64) {
            guard reason == nil else { return }
            members.append(Member(groupStart: groupStart ?? header, headerOffset: header, bodyStart: body, end: end))
            groupStart = nil
        }
    }
}
