/// reader が所有する鍵導出の累積予算。失敗・password 変更でも払い戻さない。
final class KDFWorkBudget {
    private var remaining: UInt64
    private let subject: String

    init(limit: UInt64, subject: String) {
        remaining = limit
        self.subject = subject
    }

    func charge(_ work: UInt64) throws {
        guard work <= remaining else { throw KaitoError.limitExceeded(subject) }
        remaining -= work
    }
}
