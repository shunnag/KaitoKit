import Foundation

/// process 全体で共有する葉の実行枠。待機するのは結果を読む consumer だけ。
/// 空き枠ができてから Dispatch に投入する。consumer は未開始の自分の葉を実行でき、葉同士は待たない。
final class LeafDecodePool: @unchecked Sendable {
    static let shared = LeafDecodePool(capacity: CPUTopology.current.activeLogicalCPUs)
    @TaskLocal static var testingSubmission: (@Sendable () -> Void)?

    final class Group: Sendable {}
    /// claim と body の所有権は pool の lock が守る。実行先を一度だけ選び、保持領域を渡す。
    final class Ticket: @unchecked Sendable {
        fileprivate enum State { case unclaimed, claimedByWorker, claimedInline, cancelled }
        fileprivate let group: Group
        fileprivate var state = State.unclaimed
        fileprivate var body: (@Sendable () -> Void)?
        fileprivate init(group: Group, body: @escaping @Sendable () -> Void) {
            self.group = group; self.body = body
        }
    }

    let capacity: Int
    private let lock = NSLock()
    private let executor: @Sendable (@escaping @Sendable () -> Void) -> Void
    private var pending: [Ticket] = []
    private var running = 0
    private var peak = 0

    // Test hook: policy の異なる reader も同じ hardware 上限を共有する。
    var runningJobs: Int { lock.withLock { running } }
    var peakRunningJobs: Int { lock.withLock { peak } }

    convenience init(capacity: Int) {
        let queue = DispatchQueue(label: "KaitoKit.leafDecode", attributes: .concurrent)
        self.init(capacity: capacity, executor: { queue.async(execute: $0) })
    }

    // Test hook: Dispatch に渡ったまま未開始の job も再現する。
    init(capacity: Int, executor: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {
        self.capacity = max(1, capacity); self.executor = executor
    }

    @discardableResult
    func submit(group: Group, _ body: @escaping @Sendable () -> Void) -> Ticket {
        Self.testingSubmission?()
        let job = Ticket(group: group, body: body)
        let start = lock.withLock {
            if running < capacity {
                running += 1; peak = max(peak, running)
                return true
            }
            pending.append(job)
            return false
        }
        if start { execute(job) }
        return job
    }

    /// pending / Dispatch 未開始のどちらでも、実行枠を使わず caller が自分の葉を実行する。
    func runInline(_ ticket: Ticket) -> Bool {
        let body = lock.withLock {
            let body = claim(ticket, as: .claimedInline)
            if body != nil { pending.removeAll { $0 === ticket } }
            return body
        }
        guard let body else { return false }
        body()
        return true
    }

    // pool lock 内だけで呼ぶ。body は実行先へ移し、ticket に入力の capture を残さない。
    private func claim(_ ticket: Ticket, as state: Ticket.State) -> (@Sendable () -> Void)? {
        guard ticket.state == .unclaimed else { return nil }
        ticket.state = state
        let body = ticket.body
        ticket.body = nil
        return body
    }

    /// 未投入の job とその保持領域も即座に解放する。実行中の葉は自身で放棄を観測する。
    func cancel(group: Group) {
        let removed = lock.withLock {
            let removed = pending.filter { $0.group === group }.compactMap { claim($0, as: .cancelled) }
            pending.removeAll { $0.group === group }
            return removed
        }
        // captured object の deinit は pool の lock の外で行う。
        withExtendedLifetime(removed) {}
    }

    private func execute(_ job: Ticket) {
        executor { [self] in
            let body = lock.withLock { claim(job, as: .claimedByWorker) }
            body?()
            // inline 済みでも Dispatch の枠はここで返す。pending 除去では running を変えない。
            let next: Ticket? = lock.withLock {
                if !pending.isEmpty { return pending.removeFirst() }
                running -= 1
                return nil
            }
            if let next { execute(next) }
        }
    }
}
