import Foundation

/// 独立した frame / member / chunk の結果を入力順に返す。葉は他の葉を待たない。
/// 失敗した単位は順番が来てから直列で再実行し、単位内の部分出力と元のエラーも保存する。
final class ParallelIndependentDecompressor: Decompressor {
    struct Unit: Sendable {
        let outputSize: Int
        let heldBytes: Int
        let makeDecoder: @Sendable () throws -> any Decompressor

        init(outputSize: UInt64, scratchBytes: UInt64,
             makeDecoder: @escaping @Sendable () throws -> any Decompressor) throws {
            self.outputSize = try Checked.toInt(outputSize)
            heldBytes = try Checked.toInt(Checked.add(Checked.add(outputSize, 1), scratchBytes))
            self.makeDecoder = makeDecoder
        }
    }

    final class Diagnostics: @unchecked Sendable {
        private let lock = NSLock()
        private var live = 0, peak = 0, held = 0, peakHeld = 0
        var liveWorkers: Int { lock.withLock { live } }
        var peakWorkers: Int { lock.withLock { peak } }
        var heldBytes: Int { lock.withLock { held } }
        var peakHeldBytes: Int { lock.withLock { peakHeld } }
        fileprivate func worker(_ delta: Int) { lock.withLock { live += delta; peak = max(peak, live) } }
        fileprivate func bytes(_ delta: Int) { lock.withLock { held += delta; peakHeld = max(peakHeld, held) } }
    }
    private final class Reservation: Sendable {
        let diagnostics: Diagnostics?
        let bytes: Int
        init(_ bytes: Int, _ diagnostics: Diagnostics?) {
            self.bytes = bytes; self.diagnostics = diagnostics; diagnostics?.bytes(bytes)
        }
        deinit { diagnostics?.bytes(-bytes) }
    }
    private struct Decoded: Sendable {
        let bytes: Data
        let reservation: Reservation
    }
    /// queue の予約を実行された leaf だけが結果へ移す。返却済みの予約を closure に残さない。
    private final class PendingJob: @unchecked Sendable {
        var reservation: Reservation?
        init(_ reservation: Reservation) { self.reservation = reservation }
    }
    private final class Workers: @unchecked Sendable {
        private let condition = NSCondition()
        private let group = LeafDecodePool.Group()
        private let diagnostics: Diagnostics?
        private var abandoned = false
        private var tickets: [Int: LeafDecodePool.Ticket] = [:]
        private var results: [Int: Result<Decoded, any Error>] = [:]

        init(_ diagnostics: Diagnostics?) { self.diagnostics = diagnostics }
        var isAbandoned: Bool { condition.withLock { abandoned } }
        func abandon() {
            condition.lock(); abandoned = true; results.removeAll(); tickets.removeAll(); condition.broadcast(); condition.unlock()
            LeafDecodePool.shared.cancel(group: group)
        }
        func submit(_ unit: Unit, id: Int) {
            let pending = PendingJob(Reservation(unit.heldBytes, diagnostics))
            let ticket = LeafDecodePool.shared.submit(group: group) { [self] in
                guard !isAbandoned else { return }
                diagnostics?.worker(1)
                defer { diagnostics?.worker(-1) }
                var result: Result<Decoded, any Error>? = Result {
                    let reservation = pending.reservation!
                    pending.reservation = nil
                    let decoder = try unit.makeDecoder()
                    // 余分な 1 byte で、宣言長の後の終端検査と過大な出力を両方確認する。
                    let capacity = unit.outputSize + 1
                    var output = Data(count: capacity)
                    try output.withUnsafeMutableBytes { destination in
                        var total = 0
                        while !decoder.isFinished, total < capacity {
                            if isAbandoned { throw CancellationError() }
                            let count = min(256 * 1_024, capacity - total)
                            let produced = try decoder.read(into: UnsafeMutableRawBufferPointer(
                                rebasing: destination[total..<(total + count)]))
                            guard produced > 0 || decoder.isFinished else {
                                throw KaitoError.malformed("independent decoder made no progress")
                            }
                            total += produced
                        }
                        guard total == unit.outputSize, decoder.isFinished else {
                            throw KaitoError.malformed("independent unit output size mismatch")
                        }
                    }
                    output.removeLast()
                    return Decoded(bytes: output, reservation: reservation)
                }
                condition.lock()
                if !abandoned { results[id] = result }
                result = nil
                condition.broadcast(); condition.unlock()
            }
            condition.withLock { if !abandoned { tickets[id] = ticket } }
        }
        func take(_ id: Int) throws -> Result<Decoded, any Error> {
            var hasWaited = false
            while true {
                try Task.checkCancellation()
                condition.lock()
                if let result = results.removeValue(forKey: id) { tickets.removeValue(forKey: id); condition.unlock(); return result }
                if abandoned { condition.unlock(); throw CancellationError() }
                let ticket = tickets[id]
                condition.unlock()
                // まず Dispatch に譲り、1 poll 待っても未開始の葉だけを lock の外で実行する。
                if hasWaited, let ticket, LeafDecodePool.shared.runInline(ticket) { continue }
                condition.lock()
                if results[id] != nil || abandoned { condition.unlock(); continue }
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
                condition.unlock()
                hasWaited = true
            }
        }
    }

    private let units: [Unit]
    private let workerCount: Int
    private let workers: Workers
    private var spare: Reservation?
    private var submitted = 0, emitted = 0, currentOffset = 0
    private var current: Decoded?
    private var replaying = false
    private var serial: (any Decompressor)?
    private var terminalError: (any Error)?
    private(set) var isFinished = false

    /// 予約は実行中・待機中・未返却の出力に渡す。追加の一単位分は失敗時の直列再実行用。
    /// 走査や予算で並列化できないときは、呼出元が元の直列 decoder に戻す。
    init?(units: [Unit], limits: ReadLimits, workers: Int, diagnostics: Diagnostics? = nil) {
        guard units.count >= 2, let maximum = units.map(\.heldBytes).max(), maximum > 0 else { return nil }
        let count = min(max(1, workers), LeafDecodePool.shared.capacity, units.count,
                        max(0, limits.resolvedParallelDecodeMemory() / maximum - 1))
        guard count >= 2 else { return nil }
        self.units = units; workerCount = count; self.workers = Workers(diagnostics)
        spare = Reservation(maximum, diagnostics)
    }
    deinit { workers.abandon() }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if let terminalError { throw terminalError }
        guard !buffer.isEmpty, !isFinished else { return 0 }
        do {
            try Task.checkCancellation()
            while emitted < units.count {
                if replaying {
                    if serial == nil { serial = try units[emitted].makeDecoder() }
                    let count = try serial!.read(into: buffer)
                    if count > 0 { return count }
                    guard serial!.isFinished else { throw KaitoError.malformed("independent decoder made no progress") }
                    serial = nil; emitted += 1
                    continue
                }
                if current == nil {
                    while submitted < units.count, submitted - emitted < workerCount {
                        workers.submit(units[submitted], id: submitted); submitted += 1
                    }
                    switch try workers.take(emitted) {
                    case .success(let decoded): current = decoded
                    case .failure:
                        workers.abandon(); replaying = true
                        continue
                    }
                }
                let count = min(buffer.count, 256 * 1_024, units[emitted].outputSize - currentOffset)
                if count > 0 {
                    current!.bytes.withUnsafeBytes { bytes in
                        buffer.baseAddress!.copyMemory(from: bytes.baseAddress!.advanced(by: currentOffset), byteCount: count)
                    }
                    currentOffset += count
                }
                if currentOffset == units[emitted].outputSize {
                    current = nil; currentOffset = 0; emitted += 1
                    if emitted == units.count { isFinished = true; spare = nil }
                }
                if count > 0 { return count }
            }
            isFinished = true; spare = nil
            return 0
        } catch {
            terminalError = error; workers.abandon(); current = nil; serial = nil; spare = nil
            throw error
        }
    }
}
