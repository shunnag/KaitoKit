import Foundation

// Consumer-owned window; only each Job's result crosses threads. Workers see
// password/salt bytes, never the reader, source, verifier, or authenticated cache.
final class ZipAESKeyLookAhead {
    private final class Job: @unchecked Sendable {
        let key: WinZipAESKeyCacheKey
        private let condition = NSCondition()
        private var finished = false
        private var result: WinZipAESDerivedKeys?
        var ticket: LeafDecodePool.Ticket?

        init(key: WinZipAESKeyCacheKey) { self.key = key }

        func run() {
            let result = try? WinZipAESDerivedKeys.derive(for: key)
            condition.lock()
            self.result = result
            finished = true
            condition.broadcast()
            condition.unlock()
        }

        func take() throws -> WinZipAESDerivedKeys? {
            var waited = false
            while true {
                try Task.checkCancellation()
                condition.lock()
                if finished {
                    let result = result
                    condition.unlock()
                    return result
                }
                condition.unlock()
                if waited, let ticket, LeafDecodePool.shared.runInline(ticket) { continue }
                condition.lock()
                if !finished { _ = condition.wait(until: Date(timeIntervalSinceNow: 0.001)) }
                condition.unlock()
                waited = true
            }
        }

        func discard() {
            if let ticket, LeafDecodePool.shared.discard(ticket) { return }
            // Already-running jobs finish before a replacement window is
            // allocated, so seeks/password changes cannot multiply its budget.
            condition.lock()
            while !finished { condition.wait() }
            condition.unlock()
        }
    }

    // Includes conservative headroom for contexts, result Data, pool ticket,
    // locks, and allocator overhead. Charge both the retained password Data and
    // the byte array used by CommonCryptoPrimitives while a job is deriving.
    static let scratchBytesPerJob = 4_096
    private let group = LeafDecodePool.Group()
    private var jobs: [Int: Job] = [:]
    private(set) var submittedCount = 0
    private(set) var servedCount = 0
    let capacity: Int

    init(workers: Int, memoryBudget: Int, passwordBytes: Int) {
        let passwordCost = passwordBytes.multipliedReportingOverflow(by: 2)
        let cost = Self.scratchBytesPerJob.addingReportingOverflow(passwordCost.partialValue)
        capacity = passwordCost.overflow || cost.overflow ? 0 : min(max(0, workers - 1), 8,
            LeafDecodePool.shared.capacity, max(0, memoryBudget) / cost.partialValue)
    }

    deinit { reset() }

    var count: Int { jobs.count }
    func contains(_ index: Int) -> Bool { jobs[index] != nil }

    func submit(index: Int, key: WinZipAESKeyCacheKey) {
        guard jobs.count < capacity, jobs[index] == nil else { return }
        let job = Job(key: key)
        jobs[index] = job
        submittedCount += 1
        job.ticket = LeafDecodePool.shared.submit(group: group) { job.run() }
    }

    func take(index: Int, key: WinZipAESKeyCacheKey) throws -> WinZipAESDerivedKeys? {
        guard let job = jobs[index] else { return nil }
        guard job.key == key else {
            reset()
            return nil
        }
        let result = try job.take()
        jobs.removeValue(forKey: index)
        if result != nil { servedCount += 1 }
        return result
    }

    func reset() {
        for job in jobs.values { job.discard() }
        jobs.removeAll(keepingCapacity: false)
    }

    func drop(through index: Int) {
        for old in jobs.keys.filter({ $0 <= index }) {
            jobs.removeValue(forKey: old)?.discard()
        }
    }
}
