import Foundation

/// A process-wide byte budget that can be shared by parallel decoders.
///
/// Each participating decoder reserves independently. A reservation that cannot
/// be satisfied in full receives the remaining bytes, or zero when the budget is
/// exhausted. Decoders keep their existing serial fallbacks; no decoder waits
/// for memory. This is a budget for allocations covered by `parallelDecodeMemory`,
/// not a process RSS limit or a limit on archive metadata and serial decoding.
public final class ParallelDecodeMemoryBudget: @unchecked Sendable, Equatable {
    /// Set this with `$active.withValue(_:)` around reader creation and use.
    /// Readers and their decoders in the same task tree share this budget while
    /// retaining their own reservations. The default is no shared budget.
    @TaskLocal public static var active: ParallelDecodeMemoryBudget?

    public let capacity: Int
    private let lock = NSLock()
    private var available: Int

    public init(capacity: UInt64) {
        self.capacity = Int(clamping: capacity)
        available = self.capacity
    }

    public static func == (lhs: ParallelDecodeMemoryBudget, rhs: ParallelDecodeMemoryBudget) -> Bool {
        lhs === rhs
    }

    fileprivate func reserve(_ requested: Int, allowPartial: Bool) -> Int {
        lock.withLock {
            guard allowPartial || requested <= available else { return 0 }
            let granted = min(max(0, requested), available)
            available -= granted
            return granted
        }
    }

    fileprivate func release(_ bytes: Int) {
        lock.withLock { available += bytes }
    }

    var availableBytes: Int { lock.withLock { available } }
}

struct ParallelDecodeMemoryReservation: Sendable {
    private final class Lease: @unchecked Sendable {
        let amount: Int
        let budget: ParallelDecodeMemoryBudget

        init(amount: Int, budget: ParallelDecodeMemoryBudget) {
            self.amount = amount
            self.budget = budget
        }

        deinit {
            budget.release(amount)
        }
    }

    let amount: Int
    private let lease: Lease?

    init(upTo requested: Int, budget: ParallelDecodeMemoryBudget?) {
        let granted = budget?.reserve(requested, allowPartial: true) ?? requested
        amount = granted
        lease = granted > 0 ? budget.map { Lease(amount: granted, budget: $0) } : nil
    }

    init?(exactly requested: Int, budget: ParallelDecodeMemoryBudget?) {
        let granted = budget?.reserve(requested, allowPartial: false) ?? requested
        guard granted == requested else { return nil }
        amount = granted
        lease = granted > 0 ? budget.map { Lease(amount: granted, budget: $0) } : nil
    }
}
