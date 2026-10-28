import Foundation

/// Decodes independent (non-solid) RAR5 members ahead of the reader on the
/// shared leaf pool while the caller still consumes earlier members in order.
///
/// Consecutive eligible members are grouped into batches so that tens of
/// thousands of 2 KiB files do not each pay a Dispatch round trip or a lock
/// hand-off. A batch publishes every member's verified output at once; `take`
/// hands each out once and the reader serves it through the ordinary verified
/// stream. A member whose decode failed is simply absent: the reader then
/// decodes it serially, which reproduces the exact error and partial output of
/// the serial path. A waiting consumer runs its own unstarted batch inline
/// after one poll, so a saturated pool never blocks the caller.
final class IndependentEntryPrefetcher: @unchecked Sendable {
    struct Candidate: Sendable {
        let index: Int
        let outputSize: Int
        /// Bytes a decoder of this member holds besides its output
        /// (compressed input, retained window, tables).
        let scratchBytes: Int
        /// A plain file segment, when a batch can read its packed input together.
        let packedSegment: SourceSegment?
        let headerOffset: UInt64?

        init(index: Int, outputSize: Int, scratchBytes: Int, packedSegment: SourceSegment? = nil, headerOffset: UInt64? = nil) {
            self.index = index
            self.outputSize = outputSize
            self.scratchBytes = scratchBytes
            self.packedSegment = packedSegment
            self.headerOffset = headerOffset
        }
    }

    /// Decodes the members of one batch in order; a nil element means that
    /// member must be decoded serially. `shouldStop` is polled between members
    /// and lets an abandoned batch end early.
    typealias BatchDecoder = @Sendable ([Candidate], _ shouldStop: () -> Bool) -> [Data?]

    /// Largest single member that is decoded ahead; bigger members stream
    /// serially so their first bytes are not delayed by a whole-member decode.
    static let maximumMemberSize = 8 * 1_024 * 1_024
    /// A batch closes once its output reaches this size or this many members.
    static let batchOutputTarget = 1 * 1_024 * 1_024
    static let batchMemberLimit = 128

    /// Releases the batch's memory reservation once both the registry entry
    /// and the (possibly never started) job have let go of it.
    private final class Reservation: @unchecked Sendable {
        private weak var owner: IndependentEntryPrefetcher?
        private let bytes: Int
        init(owner: IndependentEntryPrefetcher, bytes: Int) { self.owner = owner; self.bytes = bytes }
        deinit { owner?.release(bytes) }
    }

    // Mutable fields are guarded by the owner's condition lock, except
    // `reservation`, which only the consumer thread writes.
    private final class Batch: @unchecked Sendable {
        let members: [Candidate]
        let group = LeafDecodePool.Group()
        var ticket: LeafDecodePool.Ticket?
        var reservation: Reservation?
        var outputs: [Data?]?
        var remaining: Int
        var discarded = false
        var finished = false

        init(members: [Candidate]) {
            self.members = members
            remaining = members.count
        }
        var firstIndex: Int { members.first!.index }
        var lastIndex: Int { members.last!.index }

        func position(of index: Int) -> Int? {
            var low = 0, high = members.count
            while low < high {
                let middle = (low + high) / 2
                if members[middle].index < index { low = middle + 1 } else { high = middle }
            }
            return low < members.count && members[low].index == index ? low : nil
        }
    }

    private let condition = NSCondition()
    private let workers: Int
    private let memoryBudget: Int
    private let memberCount: Int
    private let candidate: (Int) -> Candidate?
    private let decodeBatch: BatchDecoder
    /// Live batches in member order: running, or finished with untaken output.
    private var batches: [Batch] = []
    private var runningBatches = 0
    private var heldBytes = 0
    private var servedMembers = 0
    private var cursor = 0
    private var abandoned = false

    /// Returns nil when fewer than two workers are available: prefetching is
    /// then pure overhead and the reader keeps its serial path.
    init?(
        workers requestedWorkers: Int,
        memoryBudget: Int,
        memberCount: Int,
        candidate: @escaping (Int) -> Candidate?,
        decodeBatch: @escaping BatchDecoder
    ) {
        let workers = min(requestedWorkers, LeafDecodePool.shared.capacity)
        guard workers >= 2, memberCount > 0 else { return nil }
        self.workers = workers
        self.memoryBudget = memoryBudget
        self.memberCount = memberCount
        self.candidate = candidate
        self.decodeBatch = decodeBatch
    }

    deinit { abandon() }

    func abandon() {
        condition.lock()
        abandoned = true
        let dropped = batches
        for batch in dropped { batch.discarded = true }
        batches.removeAll()
        runningBatches = 0
        condition.broadcast()
        condition.unlock()
        // Outside the lock: cancelling drops pending closures and clearing the
        // registry's references lets reservations release their bytes.
        for batch in dropped {
            LeafDecodePool.shared.cancel(group: batch.group)
            batch.reservation = nil
        }
    }

    /// The decoded, verified output of `index` if a batch produced it, or nil
    /// when it was never scheduled or failed. Batches that end before `index`
    /// are dropped: a caller that moved past them is not coming back in order.
    func take(_ index: Int) throws -> Data? {
        var hasWaited = false
        while true {
            try Task.checkCancellation()
            condition.lock()
            if abandoned { condition.unlock(); return nil }
            var dropped = dropBatches(before: index)
            guard let batch = batches.first(where: { $0.lastIndex >= index }),
                  let position = batch.position(of: index) else {
                condition.unlock()
                drop(dropped)
                return nil
            }
            if batch.finished {
                let output = batch.outputs?[position]
                if output != nil {
                    batch.outputs?[position] = nil
                    batch.remaining -= 1
                    servedMembers += 1
                }
                if batch.remaining == 0 {
                    batches.removeAll { $0 === batch }
                    dropped.append(batch)
                }
                condition.unlock()
                drop(dropped)
                return output
            }
            let ticket = batch.ticket
            condition.unlock()
            drop(dropped)
            // Yield to Dispatch once; a batch that still has not started then
            // runs on this thread, outside every lock.
            if hasWaited, let ticket, LeafDecodePool.shared.runInline(ticket) { continue }
            condition.lock()
            if !batch.finished, !abandoned {
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
            }
            condition.unlock()
            hasWaited = true
        }
    }

    /// Submits batches for the eligible members after `index` while worker
    /// slots, the retained batch window and the memory budget allow.
    func schedule(after index: Int) {
        condition.lock()
        defer { condition.unlock() }
        guard !abandoned else { return }
        if cursor <= index { cursor = index + 1 }
        while runningBatches < workers, batches.count < 2 * workers, cursor < memberCount {
            var members: [Candidate] = []
            var outputBytes = 0
            var scratchBytes = 0
            var packedSpan = PrefetchedPackedSpan.Plan()
            while cursor < memberCount, members.count < Self.batchMemberLimit,
                  outputBytes < Self.batchOutputTarget {
                guard let next = candidate(cursor) else {
                    cursor += 1
                    continue
                }
                guard next.outputSize <= Self.maximumMemberSize else {
                    // Too large to decode ahead; the first eligible member
                    // after it still starts a batch.
                    if members.isEmpty { cursor += 1; continue }
                    break
                }
                var nextSpan = packedSpan
                nextSpan.append(next)
                let available = memoryBudget - heldBytes - outputBytes
                let nextOutput = next.outputSize + 1
                let nextScratch = max(scratchBytes, next.scratchBytes)
                guard nextOutput <= available,
                      nextScratch <= available - nextOutput,
                      nextSpan.byteCount <= available - nextOutput - nextScratch else { break }
                members.append(next)
                outputBytes += next.outputSize + 1
                scratchBytes = nextScratch
                packedSpan = nextSpan
                cursor += 1
            }
            guard !members.isEmpty else { break }
            let batch = Batch(members: members)
            let reserved = outputBytes + scratchBytes + packedSpan.byteCount
            heldBytes += reserved
            batch.reservation = Reservation(owner: self, bytes: reserved)
            batches.append(batch)
            runningBatches += 1
            batch.ticket = submit(batch)
        }
    }

    // Called under the condition lock; the pool takes only its own lock.
    private func submit(_ batch: Batch) -> LeafDecodePool.Ticket {
        let reservation = batch.reservation
        return LeafDecodePool.shared.submit(group: batch.group) { [weak self] in
            guard let self else { return }
            let outputs: [Data?]
            if isStopped(batch) {
                outputs = []
            } else {
                outputs = decodeBatch(batch.members) { [weak self] in
                    self?.isStopped(batch) ?? true
                }
            }
            condition.lock()
            batch.finished = true
            if !batch.discarded { runningBatches -= 1 }
            if !abandoned, !batch.discarded, outputs.count == batch.members.count {
                batch.outputs = outputs
                batch.remaining = outputs.reduce(0) { $0 + ($1 == nil ? 0 : 1) }
            } else {
                batch.outputs = nil
                batch.remaining = 0
            }
            condition.broadcast()
            condition.unlock()
            withExtendedLifetime(reservation) {}
        }
    }

    private func isStopped(_ batch: Batch) -> Bool {
        condition.withLock { abandoned || batch.discarded }
    }

    private func release(_ bytes: Int) {
        guard bytes != 0 else { return }
        condition.lock()
        heldBytes -= bytes
        condition.unlock()
    }

    // Called under the condition lock; returns the batches to drop outside it.
    private func dropBatches(before index: Int) -> [Batch] {
        guard let first = batches.first, first.lastIndex < index else { return [] }
        var dropped: [Batch] = []
        batches.removeAll { batch in
            guard batch.lastIndex < index else { return false }
            batch.discarded = true
            if !batch.finished { runningBatches -= 1 }
            dropped.append(batch)
            return true
        }
        return dropped
    }

    // Called outside the lock: cancellation and reservation release lock again.
    private func drop(_ dropped: [Batch]) {
        for batch in dropped {
            if !batch.finished { LeafDecodePool.shared.cancel(group: batch.group) }
            batch.reservation = nil
        }
    }

    // Test hooks.
    func waitForScheduledBatchesForTesting() {
        condition.lock()
        while runningBatches > 0 { condition.wait() }
        condition.unlock()
    }

    var liveBatchCount: Int { condition.withLock { batches.count } }
    var runningBatchCount: Int { condition.withLock { runningBatches } }
    var heldByteCount: Int { condition.withLock { heldBytes } }
    var servedMemberCount: Int { condition.withLock { servedMembers } }
}

/// The packed bodies of one prefetch batch, read from their shared file with a
/// single call and presented at the file's absolute offsets. Any offset outside
/// the span reads zero bytes, which the decoder reports as truncation and the
/// reader then decodes serially; the span itself holds the same file bytes.
final class PrefetchedPackedSpan: ByteSource {
    static let maximumSpan = 16 * 1_024 * 1_024

    private let bytes: Data
    private let base: UInt64
    var length: UInt64 { base + UInt64(bytes.count) }

    private init(bytes: Data, base: UInt64) {
        self.bytes = bytes
        self.base = base
    }

    /// Incremental planning keeps batch assembly linear in its member count.
    /// Scheduling and reading use the same eligibility and byte count so the
    /// complete packed allocation is reserved before a worker starts.
    struct Plan {
        private var file: FileByteSource?
        private var base: UInt64 = 0
        private var end: UInt64 = 0
        private var packed: UInt64 = 0
        private var members = 0
        private var eligible = true

        mutating func append(_ member: IndependentEntryPrefetcher.Candidate) {
            members += 1
            guard eligible else { return }
            guard let segment = member.packedSegment,
                  let segmentFile = segment.source as? FileByteSource else { eligible = false; return }
            if members == 1 {
                file = segmentFile
                base = member.headerOffset ?? segment.offset
                end = base
            }
            let (nextEnd, endOverflow) = segment.offset.addingReportingOverflow(segment.length)
            let (nextPacked, packedOverflow) = packed.addingReportingOverflow(segment.length)
            guard segmentFile === file, segment.offset >= end, !endOverflow, !packedOverflow else {
                eligible = false; return
            }
            end = nextEnd
            packed = nextPacked
        }

        var byteCount: Int {
            guard eligible, members >= 2, let file else { return 0 }
            let span = end - base
            // Once span is bounded, the gap test cannot overflow.
            guard span > 0, span <= UInt64(maximumSpan), end <= file.length,
                  span <= min(packed, UInt64(maximumSpan)) * 2 + 1_024 * 1_024 else { return 0 }
            return Int(span)
        }

        func read() -> PrefetchedPackedSpan? {
            let count = byteCount
            guard count > 0, let file else { return nil }
            var bytes = Data(count: count)
            let read = bytes.withUnsafeMutableBytes { destination -> Int in
                var filled = 0
                while filled < count {
                    guard let actual = try? file.read(
                        into: UnsafeMutableRawBufferPointer(rebasing: destination[filled...]),
                        at: base + UInt64(filled)
                    ), actual > 0 else { return filled }
                    filled += actual
                }
                return filled
            }
            guard read == count else { return nil }
            return PrefetchedPackedSpan(bytes: bytes, base: base)
        }
    }

    static func read(members: [IndependentEntryPrefetcher.Candidate]) -> PrefetchedPackedSpan? {
        var plan = Plan()
        for member in members { plan.append(member) }
        return plan.read()
    }

    func covers(_ offset: UInt64, length: UInt64) -> Bool {
        offset >= base && length <= UInt64(bytes.count) && offset - base <= UInt64(bytes.count) - length
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        guard !buffer.isEmpty, offset >= base, offset < length else { return 0 }
        let start = Int(offset - base)
        let count = min(buffer.count, bytes.count - start)
        bytes.withUnsafeBytes { source in
            buffer.baseAddress!.copyMemory(from: source.baseAddress!.advanced(by: start), byteCount: count)
        }
        return count
    }
}
