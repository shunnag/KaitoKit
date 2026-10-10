import Foundation

/// UDIF の consumer と葉の間の状態。葉はこの状態だけを保持し、disk source の deinit を妨げない。
/// in-flight の同じ chunk を共有し、先読みの失敗も要求された時だけ返す。
final class UDIFChunkCache: @unchecked Sendable {
    typealias Decode = @Sendable (UDIFChunk, @Sendable () -> Bool) throws -> [UInt8]

    final class Diagnostics: @unchecked Sendable {
        private let lock = NSLock()
        private var live = 0, peak = 0, held = 0, peakHeld = 0
        private var decoded: [Int: Int] = [:]
        var liveWorkers: Int { lock.withLock { live } }
        var peakWorkers: Int { lock.withLock { peak } }
        var heldBytes: Int { lock.withLock { held } }
        var peakHeldBytes: Int { lock.withLock { peakHeld } }
        func decodeCount(_ index: Int) -> Int { lock.withLock { decoded[index, default: 0] } }
        fileprivate func worker(_ delta: Int, index: Int) {
            lock.withLock {
                live += delta; peak = max(peak, live)
                if delta > 0 { decoded[index, default: 0] += 1 }
            }
        }
        fileprivate func bytes(_ delta: Int) { lock.withLock { held += delta; peakHeld = max(peakHeld, held) } }
    }

    fileprivate final class Budget: @unchecked Sendable {
        let capacity: Int
        private let lock = NSLock()
        private var held = 0
        let diagnostics: Diagnostics?
        init(_ capacity: Int, diagnostics: Diagnostics?) { self.capacity = capacity; self.diagnostics = diagnostics }
        func reserve(_ size: Int) -> Reservation? {
            lock.withLock {
                guard size <= capacity - held else { return nil }
                held += size
                return Reservation(size: size, budget: self)
            }
        }
        func release(_ size: Int) { lock.withLock { held -= size } }
    }

    fileprivate final class Reservation: Sendable {
        let size: Int
        private let budget: Budget
        fileprivate init(size: Int, budget: Budget) {
            self.size = size; self.budget = budget; budget.diagnostics?.bytes(size)
        }
        deinit { budget.diagnostics?.bytes(-size); budget.release(size) }
    }

    struct Decoded: Sendable {
        let bytes: [UInt8]
        fileprivate let reservation: Reservation?
    }

    private struct Abandoned: Error {}
    private final class Work: @unchecked Sendable {
        let group = LeafDecodePool.Group()
        let reservation: Reservation?
        private let condition = NSCondition()
        private var cancelled = false
        private var result: Result<[UInt8], any Error>?
        private var ticket: LeafDecodePool.Ticket?
        // cache lock が守る。要求済みの仕事は seek によって取り消さない。
        var demanded: Bool
        init(reservation: Reservation?, demanded: Bool) { self.reservation = reservation; self.demanded = demanded }
        var isCancelled: Bool { condition.withLock { cancelled } }
        func setTicket(_ ticket: LeafDecodePool.Ticket) { condition.withLock { if !cancelled { self.ticket = ticket } } }
        func cancel() {
            condition.lock(); cancelled = true; result = nil; ticket = nil; condition.broadcast(); condition.unlock()
        }
        func perform(_ chunk: UDIFChunk, index: Int, diagnostics: Diagnostics?, decode: Decode) {
            guard !isCancelled else { return }
            diagnostics?.worker(1, index: index)
            defer { diagnostics?.worker(-1, index: index) }
            var outcome: Result<[UInt8], any Error>? = Result { try decode(chunk, { self.isCancelled }) }
            condition.lock()
            if !cancelled { result = outcome }
            outcome = nil
            condition.broadcast(); condition.unlock()
        }
        func value(pool: LeafDecodePool) throws -> Result<[UInt8], any Error> {
            while true {
                try Task.checkCancellation()
                condition.lock()
                if cancelled { condition.unlock(); throw Abandoned() }
                if let result { condition.unlock(); return result }
                let ticket = ticket
                condition.unlock()
                // cache / condition の lock を持たず、要求中の chunk だけを caller が復号する。
                if let ticket, pool.runInline(ticket) { continue }
                condition.lock()
                if cancelled || result != nil { condition.unlock(); continue }
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
                condition.unlock()
            }
        }
    }

    private struct Entry {
        let work: Work
        var previous: Int?
        var next: Int?
    }
    private let lock = NSLock()
    private let chunks: [UDIFChunk]
    private let pool: LeafDecodePool
    private let budget: Budget
    private let diagnostics: Diagnostics?
    private let reservationSize: Int
    private let cacheLimit: Int
    let readAheadCount: Int
    private var pending: [Int: Work] = [:]
    private var cache: [Int: Entry] = [:]
    private var oldest: Int?, newest: Int?
    private var cachedBytes = 0
    private var lastReadEnd: UInt64?

    init(chunks: [UDIFChunk], budget: Int, decodeThreads: Int, pool: LeafDecodePool, diagnostics: Diagnostics?) {
        self.chunks = chunks; self.pool = pool; self.diagnostics = diagnostics
        self.budget = Budget(budget, diagnostics: diagnostics)
        // 過大 chunk の拒否は read 時に行う。LZFSE の一括入力も出力と同時に予約する。
        let maximum = chunks.filter { Self.needsDecode($0) }.map { chunk -> UInt64 in
            let output = min(chunk.byteCount, UDIFDiskByteSource.maximumChunkBytes)
            if case .lzfse = chunk.kind {
                let (sum, overflow) = output.addingReportingOverflow(chunk.dataLength)
                return overflow ? UInt64.max : sum
            }
            return output
        }.max() ?? 1
        reservationSize = max(1, Int(clamping: maximum))
        cacheLimit = min(budget, reservationSize > Int.max / 4 ? Int.max : reservationSize * 4)
        // consumer の現在 chunk にも一枠残す。明示した 1 は pool を使わず直列で読む。
        readAheadCount = decodeThreads > 1 ? min(decodeThreads, chunks.count, max(0, budget / reservationSize - 1)) : 0
    }

    private static func needsDecode(_ chunk: UDIFChunk) -> Bool {
        switch chunk.kind { case .raw, .zero, .ignore: false; default: true }
    }

    func beginRead(at offset: UInt64, count: Int) -> Bool {
        lock.lock()
        let sequential = offset == lastReadEnd || (lastReadEnd == nil && offset == 0)
        lastReadEnd = offset + UInt64(count)
        if !sequential { cancelPending(onlySpeculative: true) }
        lock.unlock()
        return sequential
    }

    func read(_ index: Int, sequential: Bool, decode: @escaping Decode) throws -> Decoded {
        while true {
            try Task.checkCancellation()
            lock.lock()
            let work: Work
            let serial: Bool
            if let entry = cache[index] {
                touch(index); work = entry.work; serial = false
            } else if let existing = pending[index] {
                existing.demanded = true; work = existing; serial = false
            } else {
                work = makeWork(index, demanded: true)
                serial = readAheadCount == 0 || work.reservation == nil
                if !serial { submit(work, index: index, decode: decode) }
            }
            if sequential { fill(after: index, decode: decode) }
            lock.unlock()
            // 直列 fallback も同じ in-flight 表を使い、復号中は cache lock を解放する。
            if serial { work.perform(chunks[index], index: index, diagnostics: diagnostics, decode: decode) }
            do {
                let result = try work.value(pool: pool)
                lock.withLock {
                    if pending[index] === work {
                        pending.removeValue(forKey: index)
                        insert(work, at: index)
                    }
                }
                return Decoded(bytes: try result.get(), reservation: work.reservation)
            } catch is Abandoned {
                // 他 consumer のキャンセルによる放棄なら、新しい仕事でこの read を続ける。
                continue
            }
        }
    }

    func prefetch(after index: Int, decode: @escaping Decode) { lock.withLock { fill(after: index, decode: decode) } }

    private func makeWork(_ index: Int, demanded: Bool) -> Work {
        let work = Work(reservation: reserve(), demanded: demanded)
        pending[index] = work
        return work
    }

    private func reserve() -> Reservation? {
        while true {
            if let reservation = budget.reserve(reservationSize) { return reservation }
            guard let oldest else { return nil }
            remove(oldest)
        }
    }

    private func submit(_ work: Work, index: Int, decode: @escaping Decode) {
        let chunk = chunks[index], diagnostics = diagnostics
        // 登録と submit の間に cancel されないよう、cache lock 内で enqueue まで済ませる。
        let ticket = pool.submit(group: work.group) { work.perform(chunk, index: index, diagnostics: diagnostics, decode: decode) }
        work.setTicket(ticket)
    }

    private func fill(after index: Int, decode: @escaping Decode) {
        guard readAheadCount > 0, index + 1 < chunks.count else { return }
        // 窓から外れた先読みは解放する。要求中の chunk と通常 cache は保持する。
        let end = index + 1 + min(readAheadCount, chunks.count - index - 1)
        for (id, work) in pending where !work.demanded && (id <= index || id >= end) {
            pending.removeValue(forKey: id); work.cancel(); pool.cancel(group: work.group)
        }
        for id in (index + 1)..<end where Self.needsDecode(chunks[id]) && pending[id] == nil && cache[id] == nil {
            guard let reservation = reserve() else { break }
            let work = Work(reservation: reservation, demanded: false)
            pending[id] = work
            submit(work, index: id, decode: decode)
        }
    }

    func abandon() {
        lock.withLock {
            cancelPending(onlySpeculative: false)
            cache.removeAll(); oldest = nil; newest = nil; cachedBytes = 0; lastReadEnd = nil
        }
    }

    private func cancelPending(onlySpeculative: Bool) {
        for (index, work) in pending where !onlySpeculative || !work.demanded {
            pending.removeValue(forKey: index); work.cancel(); pool.cancel(group: work.group)
        }
    }

    // byte 上限付き LRU。hit・昇格・追放はいずれも辞書と隣接 index だけを触る。
    private func insert(_ work: Work, at index: Int) {
        guard let reservation = work.reservation, reservation.size <= cacheLimit else { return }
        while cachedBytes > cacheLimit - reservation.size, let oldest { remove(oldest) }
        cache[index] = Entry(work: work, previous: newest, next: nil)
        if let newest { cache[newest]?.next = index } else { oldest = index }
        newest = index; cachedBytes += reservation.size
    }

    private func touch(_ index: Int) {
        guard index != newest, let entry = cache[index] else { return }
        unlink(index, entry: entry)
        cache[index]?.previous = newest; cache[index]?.next = nil
        if let newest { cache[newest]?.next = index } else { oldest = index }
        newest = index
    }

    private func unlink(_ index: Int, entry: Entry) {
        if let previous = entry.previous { cache[previous]?.next = entry.next } else { oldest = entry.next }
        if let next = entry.next { cache[next]?.previous = entry.previous } else { newest = entry.previous }
    }

    private func remove(_ index: Int) {
        guard let entry = cache.removeValue(forKey: index) else { return }
        unlink(index, entry: entry)
        cachedBytes -= entry.work.reservation!.size
    }
}
