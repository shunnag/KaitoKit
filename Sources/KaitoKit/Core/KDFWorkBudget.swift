/// reader が所有する鍵導出の累積予算。password 変更時に戻し、取消し時は導出分だけ返す。
final class KDFWorkBudget {
    private let limit: UInt64
    private var remaining: UInt64
    private let subject: String

    init(limit: UInt64, subject: String) {
        self.limit = limit
        remaining = limit
        self.subject = subject
    }

    func reset() {
        remaining = limit
    }

    func charge(_ work: UInt64) throws {
        guard work <= remaining else { throw KaitoError.limitExceeded(subject) }
        remaining -= work
    }

    func refund(_ work: UInt64) {
        remaining += min(work, limit - remaining)
    }
}
