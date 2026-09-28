import Foundation

/// 書庫全体の展開後 size の予算。open 時に宣言済み size の合計を limit と照らし、
/// size 未宣言の entry は stream が実際に出した byte を index ごとに記録して加算する。
/// 一度でも超えたら、その reader の以後の stream は全て limitExceeded。
final class ArchiveOutputBudget {
    private let limit: UInt64
    private let declaredTotal: UInt64
    private var total: UInt64
    private var unknownEntrySizes: [Int: UInt64] = [:]
    private var limitWasExceeded = false

    init(entries: [ArchiveEntry], limit: UInt64) throws {
        self.limit = limit
        var declaredTotal: UInt64 = 0
        for (index, entry) in entries.enumerated() {
            try checkCancellation(every: index)
            guard let size = entry.uncompressedSize else { continue }
            let next = declaredTotal.addingReportingOverflow(size)
            guard !next.overflow, next.partialValue <= limit else {
                throw KaitoError.limitExceeded("total uncompressed size")
            }
            declaredTotal = next.partialValue
        }
        self.declaredTotal = declaredTotal
        self.total = declaredTotal
    }

    private init(limit: UInt64, declaredTotal: UInt64) {
        self.limit = limit
        self.declaredTotal = declaredTotal
        self.total = declaredTotal
    }

    func reopened() -> sending ArchiveOutputBudget {
        // The immutable entry sum was checked at open. Reset runtime charges
        // and terminal failures without walking a large shared entry array.
        ArchiveOutputBudget(limit: limit, declaredTotal: declaredTotal)
    }

    func ensureUsable() throws {
        guard !limitWasExceeded else {
            throw KaitoError.limitExceeded("total uncompressed size")
        }
    }

    func availableAdditionalSize(index: Int, producedSize: UInt64) throws -> UInt64 {
        try ensureUsable()
        let previouslyRecorded = unknownEntrySizes[index] ?? 0
        let replayAllowance = previouslyRecorded > producedSize
            ? previouslyRecorded - producedSize
            : 0
        let unallocatedAllowance = limit - total
        return try Checked.add(replayAllowance, unallocatedAllowance)
    }

    func recordUnknownEntry(index: Int, producedSize: UInt64) throws {
        try ensureUsable()
        let previous = unknownEntrySizes[index] ?? 0
        guard producedSize > previous else { return }
        let additional = try Checked.sub(producedSize, previous)
        guard additional <= limit - total else {
            limitWasExceeded = true
            throw KaitoError.limitExceeded("total uncompressed size")
        }
        let nextTotal = total + additional
        unknownEntrySizes[index] = producedSize
        total = nextTotal
    }

    func recordLimitExceeded() throws {
        limitWasExceeded = true
        throw KaitoError.limitExceeded("total uncompressed size")
    }
}
