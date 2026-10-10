public import Foundation

/// XZ の連続 block を上限付き worker で復号し、job の順に出力する。
/// 複数 stream、単一 block、保持量の上限で並列化できない入力は直列に渡す。
/// 枠の走査は計画時と recorder 設定時（直列ならその init）に二度行う。
/// throw と deinit は worker を待たずに放棄する。throw 後の instance は再利用しない。
final class ParallelXZDecompressor: Decompressor {
    private static let defaultTargetJobOutput = 16 * 1_048_576
    private static let outputChunkSize = 256 * 1_024
    private static let abandonmentCheckInterval = 1_048_576
    private static let resultPollInterval: TimeInterval = 0.05
    private static let spareJobCount = 2

    /// worker と保持領域の観測先。本番の呼出元は渡さない。
    final class Diagnostics: @unchecked Sendable {
        private let lock = NSLock()
        private var live = 0, peak = 0, held = 0, peakHeld = 0
        private var fallback = false
        var liveWorkers: Int { lock.withLock { live } }
        var peakWorkers: Int { lock.withLock { peak } }
        var peakHeldBytes: Int { lock.withLock { peakHeld } }
        var fellBackToSerial: Bool { lock.withLock { fallback } }
        fileprivate func worker(_ delta: Int) { lock.withLock { live += delta; peak = max(peak, live) } }
        fileprivate func bytes(_ delta: Int) { lock.withLock { held += delta; peakHeld = max(peakHeld, held) } }
        fileprivate func fallBack() { lock.withLock { fallback = true } }
    }

    private final class Reservation: Sendable {
        let size: Int
        let diagnostics: Diagnostics?
        init(_ size: Int, diagnostics: Diagnostics?) {
            self.size = size; self.diagnostics = diagnostics; diagnostics?.bytes(size)
        }
        deinit { diagnostics?.bytes(-size) }
    }
    private struct Job: Sendable {
        let blocks: Range<Int>
        let outputSize: Int
        let heldBytes: Int
    }
    private struct Decoded: Sendable {
        let bytes: Data
        let reservation: Reservation
    }
    /// queue の保持から結果へ予約を渡す。可変値に触れるのは実行された leaf 一つだけ。
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

        init(diagnostics: Diagnostics?) {
            self.diagnostics = diagnostics
        }
        var isAbandoned: Bool {
            condition.lock(); defer { condition.unlock() }; return abandoned
        }
        func abandon() {
            condition.lock(); abandoned = true; results.removeAll(); tickets.removeAll(); condition.broadcast(); condition.unlock()
            LeafDecodePool.shared.cancel(group: group)
        }
        func submit(_ job: Job, id: Int, source: any ByteSource,
                    stream: XZStreamLayout.Stream, limits: ReadLimits, last: Bool) {
            let pending = PendingJob(Reservation(job.heldBytes, diagnostics: diagnostics))
            let ticket = LeafDecodePool.shared.submit(group: group) { [self] in
                guard !isAbandoned else { return }
                diagnostics?.worker(1)
                defer { diagnostics?.worker(-1) }
                var result: Result<Decoded, any Error>? = Result {
                    let reservation = pending.reservation!
                    pending.reservation = nil
                    let synthetic = try XZSyntheticStream.make(source: source, stream: stream, blocks: stream.blocks[job.blocks])
                    let decoder = try XZDecompressor(source: synthetic, limits: limits)
                    let capacity = try Checked.toInt(Checked.add(UInt64(job.outputSize), 1))
                    var output = Data(count: capacity)
                    try output.withUnsafeMutableBytes { destination in
                        var total = 0
                        while !decoder.isFinished, total < capacity {
                            // Dispatch worker は Task を持たないため、出力の進行ごとに放棄を確認する。
                            if isAbandoned { throw CancellationError() }
                            let count = min(ParallelXZDecompressor.abandonmentCheckInterval, capacity - total)
                            let produced = try decoder.read(into: UnsafeMutableRawBufferPointer(rebasing: destination[total..<(total + count)]))
                            guard produced > 0 || decoder.isFinished else { throw KaitoError.malformed("XZ stream made no progress") }
                            total += produced
                        }
                        guard total == job.outputSize, decoder.isFinished else {
                            throw KaitoError.malformed("XZ job output size mismatch")
                        }
                    }
                    // 合成した Index では元の CRC を検査できない。最後の job の成功条件に含める。
                    if last { try validateIndex(source: source, range: stream.indexRange) }
                    output.removeLast()
                    return Decoded(bytes: output, reservation: reservation)
                }
                condition.lock()
                if !abandoned { results[id] = result }
                // 結果の所有者を辞書だけにしてから consumer を起こす。
                result = nil
                condition.broadcast(); condition.unlock()
            }
            condition.withLock { if !abandoned { tickets[id] = ticket } }
        }
        func take(_ id: Int) throws -> Decoded {
            var hasWaited = false
            while true {
                try Task.checkCancellation()
                condition.lock()
                if let result = results.removeValue(forKey: id) { tickets.removeValue(forKey: id); condition.unlock(); return try result.get() }
                if abandoned { condition.unlock(); throw CancellationError() }
                let ticket = tickets[id]
                condition.unlock()
                // まず Dispatch に譲り、1 poll 待っても未開始の葉だけを lock の外で実行する。
                if hasWaited, let ticket, LeafDecodePool.shared.runInline(ticket) { continue }
                condition.lock()
                if results[id] != nil || abandoned { condition.unlock(); continue }
                _ = condition.wait(until: Date(timeIntervalSinceNow: ParallelXZDecompressor.resultPollInterval))
                condition.unlock()
                hasWaited = true
            }
        }
        private func validateIndex(source: any ByteSource, range: Range<UInt64>) throws {
            let end = try Checked.sub(range.upperBound, 4)
            var offset = range.lowerBound, crc = CRC32()
            while offset < end {
                if isAbandoned { throw CancellationError() }
                let count = try Checked.toInt(min(UInt64(ParallelXZDecompressor.outputChunkSize), end - offset))
                crc.update(try readByteRange(source: source, offset: offset, count: count))
                offset = try Checked.add(offset, UInt64(count))
            }
            let bytes = try readByteRange(source: source, offset: end, count: 4)
            guard crc.value == LittleEndian.uint32(bytes, at: 0) else {
                throw KaitoError.malformed("invalid XZ stream")
            }
        }
    }

    private let source: any ByteSource
    private let limits: ReadLimits
    private let recorder: CompressedTarMapRecorder?
    private var serial: XZDecompressor?
    private var stream: XZStreamLayout.Stream?
    private var jobs: [Job] = []
    private var workers: Workers?
    private var workerCount = 0
    private var spareReservation: Reservation?
    private var submitted = 0
    private var emitted = 0
    private var current: Decoded?
    private var currentOffset = 0
    private var finished = false

    /// - Parameters:
    ///   - workers: reader が open 時に解決した要求並列数。
    ///   - targetJobOutput: job をまとめる出力目標。本番の呼出元は渡さない。
    ///   - diagnostics: 観測値の記録先。本番の呼出元は渡さない。
    init(source: any ByteSource, limits: ReadLimits, recorder: CompressedTarMapRecorder? = nil,
         workers: Int = ReaderOptions.automaticDecodeThreads(),
         targetJobOutput: Int = ParallelXZDecompressor.defaultTargetJobOutput,
         diagnostics: Diagnostics? = nil) throws {
        self.source = source; self.limits = limits; self.recorder = recorder
        let memoryBudget = limits.resolvedParallelDecodeMemory()
        let layout = try XZResourceValidator.validate(source: source, dictionaryLimit: limits.maxDictionarySize)
        if layout.streams.count == 1, let stream = layout.streams.first, stream.blocks.count >= 2 {
            let planned = try Self.plan(stream.blocks, target: UInt64(max(1, targetJobOutput)))
            let perJobBytes = planned.map(\.heldBytes).max()!
            let count = max(1, min(max(1, workers), planned.count, memoryBudget / perJobBytes - Self.spareJobCount))
            if count >= 2 {
                try XZResourceValidator.validate(source: source, dictionaryLimit: limits.maxDictionarySize, recorder: recorder)
                self.stream = stream; self.jobs = planned; self.workerCount = count
                self.workers = Workers(diagnostics: diagnostics)
                // recorder の再読と probe・結果受渡しに二つの job 分を予約する。
                spareReservation = Reservation(try Checked.toInt(Checked.mul(UInt64(perJobBytes), UInt64(Self.spareJobCount))),
                                               diagnostics: diagnostics)
                return
            }
        }
        diagnostics?.fallBack()
        serial = try XZDecompressor(source: source, limits: limits, recorder: recorder)
    }
    deinit { workers?.abandon() }
    var isFinished: Bool { serial?.isFinished ?? finished }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !isFinished else { return 0 }
        do {
            if let serial { return try serial.read(into: buffer) }
            try Task.checkCancellation()
            while emitted < jobs.count {
                if current == nil {
                    fillJobs()
                    current = try workers!.take(emitted)
                }
                let count = min(buffer.count, Self.outputChunkSize, jobs[emitted].outputSize - currentOffset)
                if count > 0 {
                    current!.bytes.withUnsafeBytes { bytes in
                        buffer.baseAddress!.copyMemory(from: bytes.baseAddress!.advanced(by: currentOffset), byteCount: count)
                    }
                    currentOffset += count
                }
                if currentOffset == jobs[emitted].outputSize {
                    try record(jobs[emitted])
                    current = nil; currentOffset = 0; emitted += 1
                    if emitted == jobs.count { finished = true; spareReservation = nil }
                }
                if count > 0 { return count }
            }
            finished = true
            return 0
        } catch {
            workers?.abandon(); current = nil; spareReservation = nil
            throw error
        }
    }

    private func fillJobs() {
        guard let stream, let workers else { return }
        while submitted < jobs.count, submitted - emitted < workerCount {
            workers.submit(jobs[submitted], id: submitted, source: source, stream: stream,
                           limits: limits, last: submitted == jobs.count - 1)
            submitted += 1
        }
    }
    private func record(_ job: Job) throws {
        guard let recorder, recorder.isRecording, let stream else { return }
        for block in stream.blocks[job.blocks] {
            try Task.checkCancellation()
            let range = block.compressedRange
            let bytes = try readByteRange(source: source, offset: range.lowerBound,
                                          count: Checked.toInt(Checked.sub(range.upperBound, range.lowerBound)))
            bytes.withUnsafeBytes { recorder.consumeXZ($0, at: range.lowerBound) }
        }
    }
    private static func plan(_ blocks: [XZStreamLayout.Block], target: UInt64) throws -> [Job] {
        var jobs: [Job] = [], start = 0, output: UInt64 = 0
        func append(until end: Int) throws {
            let compressed = try Checked.sub(blocks[end - 1].compressedRange.upperBound, blocks[start].compressedRange.lowerBound)
            jobs.append(Job(blocks: start..<end, outputSize: try Checked.toInt(output),
                            heldBytes: try Checked.toInt(Checked.add(output, compressed))))
            start = end; output = 0
        }
        for (index, block) in blocks.enumerated() {
            let combined = try Checked.add(output, block.outputSize)
            if index > start, combined > target { try append(until: index) }
            output = try Checked.add(output, block.outputSize)
            if block.outputSize > target { try append(until: index + 1) }
        }
        if start < blocks.count { try append(until: blocks.count) }
        return jobs
    }
}
