import Foundation

/// process 全体で共有する葉の実行枠。待機するのは結果を読む consumer だけ。
/// 空き枠ができてから Dispatch に投入し、実行中の葉は他の job を待たない。
final class LeafDecodePool: @unchecked Sendable {
    static let shared = LeafDecodePool(capacity: CPUTopology.current.activeLogicalCPUs)
    @TaskLocal static var testingSubmission: (@Sendable () -> Void)?

    final class Group: Sendable {}
    private struct Job: Sendable {
        let group: Group
        let body: @Sendable () -> Void
    }

    let capacity: Int
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "KaitoKit.leafDecode", attributes: .concurrent)
    private var pending: [Job] = []
    private var running = 0
    private var peak = 0

    // Test hook: policy の異なる reader も同じ hardware 上限を共有する。
    var runningJobs: Int { lock.withLock { running } }
    var peakRunningJobs: Int { lock.withLock { peak } }

    init(capacity: Int) { self.capacity = max(1, capacity) }

    func submit(group: Group, _ body: @escaping @Sendable () -> Void) {
        Self.testingSubmission?()
        let job = Job(group: group, body: body)
        let start = lock.withLock {
            if running < capacity {
                running += 1; peak = max(peak, running)
                return true
            }
            pending.append(job)
            return false
        }
        if start { execute(job) }
    }

    /// 未投入の job とその保持領域も即座に解放する。実行中の葉は自身で放棄を観測する。
    func cancel(group: Group) {
        let removed = lock.withLock {
            let removed = pending.filter { $0.group === group }
            pending.removeAll { $0.group === group }
            return removed
        }
        // captured object の deinit は pool の lock の外で行う。
        withExtendedLifetime(removed) {}
    }

    private func execute(_ job: Job) {
        queue.async { [self] in
            job.body()
            let next: Job? = lock.withLock {
                if !pending.isEmpty { return pending.removeFirst() }
                running -= 1
                return nil
            }
            if let next { execute(next) }
        }
    }
}
