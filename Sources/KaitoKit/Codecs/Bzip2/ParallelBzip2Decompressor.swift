private import CBzip2
import Foundation

/// stream 内の block run を上限付き worker で復号し、元の順に返す。
/// 元の stream の終端と CRC が確認できない場合は、その header から直列で再生する。
/// 検証済みの出力を再生時に読み捨てるため、返す byte 列に重複はない。
/// 失敗時には worker を放棄する。throw 後の instance は破棄する。
final class ParallelBzip2Decompressor: Decompressor {
    /// 同時に復号する worker 数の上限。
    private static let maximumWorkerCount = 8
    /// 一区間の圧縮 byte 数の上限。init の既定値でもある。
    private static let maximumIntervalSize = 8 * 1_048_576
    /// 一区間の展開 byte 数の上限。init の既定値でもある。
    private static let maximumIntervalOutputSize = 16 * 1_048_576
    /// worker が放棄を確かめるまでに書く展開 byte 数。
    private static let abandonmentCheckInterval = 1_048_576
    /// 一回の `read(into:)` で返す byte 数の上限。
    private static let outputChunkSize = 256 * 1_024
    /// worker の完了を待つ間に Task の取消を確かめる間隔（秒）。
    private static let resultPollInterval: TimeInterval = 0.05

    /// Test hook: worker 数、保持 byte 数、直列への切替回数を観測する。本番の呼出元は渡さない。
    final class Diagnostics: @unchecked Sendable {
        private let lock = NSLock()
        private var live = 0, peak = 0, held = 0, peakHeld = 0, fallbacks = 0, decodedRuns = 0
        var liveWorkers: Int { lock.withLock { live } }
        var peakWorkers: Int { lock.withLock { peak } }
        var peakHeldBytes: Int { lock.withLock { peakHeld } }
        var fallbackCount: Int { lock.withLock { fallbacks } }
        var decodedRunCount: Int { lock.withLock { decodedRuns } }
        fileprivate func worker(_ delta: Int) { lock.withLock { live += delta; peak = max(peak, live) } }
        fileprivate func bytes(_ delta: Int) { lock.withLock { held += delta; peakHeld = max(peakHeld, held) } }
        fileprivate func decoded() { lock.withLock { decodedRuns += 1 } }
        fileprivate func fallback() { lock.withLock { fallbacks += 1 } }
    }

    private final class Reservation: Sendable {
        let size: Int
        let diagnostics: Diagnostics?
        init(_ size: Int, diagnostics: Diagnostics?) {
            self.size = size; self.diagnostics = diagnostics; diagnostics?.bytes(size)
        }
        deinit { diagnostics?.bytes(-size) }
    }
    private struct Decoded: Sendable {
        let bytes: Data
        let reservation: Reservation
    }
    private enum Outcome: Sendable {
        case decoded(Decoded)
        case invalid
    }
    private final class Workers: @unchecked Sendable {
        private let condition = NSCondition()
        private let queue = DispatchQueue(label: "KaitoKit.bzip2", attributes: .concurrent)
        private let slots: DispatchSemaphore
        private var abandoned = false
        private var results: [Int: Outcome] = [:]
        let diagnostics: Diagnostics?
        let outputLimit: Int

        init(count: Int, outputLimit: Int, diagnostics: Diagnostics?) {
            slots = DispatchSemaphore(value: count)
            self.outputLimit = outputLimit; self.diagnostics = diagnostics
        }
        var isAbandoned: Bool {
            condition.lock(); defer { condition.unlock() }; return abandoned
        }
        func abandon() {
            condition.lock(); abandoned = true; results.removeAll(); condition.broadcast(); condition.unlock()
        }
        func submit(_ bytes: Data, id: Int) {
            let inputReservation = Reservation(bytes.count, diagnostics: diagnostics)
            queue.async { [self, inputReservation] in
                slots.wait()
                defer { slots.signal(); withExtendedLifetime(inputReservation) {} }
                guard !isAbandoned else { return }
                diagnostics?.worker(1)
                defer { diagnostics?.worker(-1) }
                let result = decode(bytes).map(Outcome.decoded) ?? .invalid
                condition.lock()
                if !abandoned { results[id] = result }
                condition.broadcast(); condition.unlock()
            }
        }
        func take(_ id: Int) throws -> Outcome {
            while true {
                condition.lock()
                if let result = results.removeValue(forKey: id) { condition.unlock(); return result }
                if abandoned { condition.unlock(); return .invalid }
                _ = condition.wait(until: Date(timeIntervalSinceNow: ParallelBzip2Decompressor.resultPollInterval))
                condition.unlock()
                try Task.checkCancellation()
            }
        }

        private func decode(_ bytes: Data) -> Decoded? {
            var stream = bz_stream()
            guard BZ2_bzDecompressInit(&stream, 0, 0) == BZ_OK else { return nil }
            defer { BZ2_bzDecompressEnd(&stream) }
            let reservation = Reservation(outputLimit, diagnostics: diagnostics)
            var output = Data(count: outputLimit)
            let produced: Int? = bytes.withUnsafeBytes { input in
                output.withUnsafeMutableBytes { destination in
                    stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: CChar.self).baseAddress)
                    stream.avail_in = UInt32(input.count)
                    defer { stream.next_in = nil; stream.next_out = nil }
                    var total = 0
                    while total < destination.count {
                        // worker は Task を持たない。放棄は最大 1 MiB の出力ごとに観測する。
                        if isAbandoned { return nil }
                        let capacity = min(ParallelBzip2Decompressor.abandonmentCheckInterval, destination.count - total)
                        stream.next_out = destination.bindMemory(to: CChar.self).baseAddress!.advanced(by: total)
                        stream.avail_out = UInt32(capacity)
                        let before = stream.avail_in
                        let status = BZ2_bzDecompress(&stream)
                        let count = capacity - Int(stream.avail_out)
                        total += count
                        if status == BZ_STREAM_END { return stream.avail_in == 0 ? total : nil }
                        guard status == BZ_OK, count > 0 || stream.avail_in < before else { return nil }
                        // avail_in == 0 でも、libbz2 に残る出力を最後まで排出する。
                    }
                    // 上限ちょうどで END だけが残る場合は、1 byte の別領域で確かめる。
                    var probe: CChar = 0
                    return withUnsafeMutablePointer(to: &probe) { pointer in
                        stream.next_out = pointer; stream.avail_out = 1
                        let status = BZ2_bzDecompress(&stream)
                        return status == BZ_STREAM_END && stream.avail_in == 0 && stream.avail_out == 1 ? total : nil
                    }
                }
            }
            guard let produced else { return nil }
            output.removeLast(output.count - produced)
            return Decoded(bytes: output, reservation: reservation)
        }
    }

    private struct Job {
        let id: Int
        let streamStart: UInt64
        let end: Bzip2BlockScanner.StreamEnd?
    }

    private let source: any ByteSource
    private let recorder: CompressedTarMapRecorder?
    private let workerCount: Int
    private let workers: Workers
    private let diagnostics: Diagnostics?
    private let scannerReservation: Reservation
    private var scanner: Bzip2BlockScanner?
    private var jobs: [Job] = []
    private var nextJob = 0
    private var scanningFinished = false
    private var fallbackOffset: UInt64?
    private var serial: Bzip2Decompressor?
    private var serialSkip: UInt64 = 0
    private var outputStreamStart: UInt64?
    private var streamOutput: UInt64 = 0
    private var current: Decoded?
    private var currentOffset = 0
    private var finished = false

    /// - Parameters:
    ///   - injectedCandidates: Test hook: 偽の stream 開始候補（絶対 byte offset）。
    ///   - injectedBitCandidates: Test hook: 偽の block 開始候補（絶対 bit offset）。
    ///   - diagnostics: Test hook: 観測値の記録先。本番の呼出元は渡さない。
    init(source: any ByteSource, recorder: CompressedTarMapRecorder? = nil,
         workers: Int = min(ParallelBzip2Decompressor.maximumWorkerCount, ProcessInfo.processInfo.activeProcessorCount),
         maximumCompressedSize: Int = ParallelBzip2Decompressor.maximumIntervalSize,
         maximumOutputSize: Int = ParallelBzip2Decompressor.maximumIntervalOutputSize,
         injectedCandidates: [UInt64] = [], injectedBitCandidates: [UInt64] = [], diagnostics: Diagnostics? = nil) throws {
        self.source = source; self.recorder = recorder
        self.workerCount = max(1, min(Self.maximumWorkerCount, workers))
        let compressedLimit = max(Bzip2StreamLayout.headerLength, min(Self.maximumIntervalSize, maximumCompressedSize))
        let outputLimit = max(1, min(Self.maximumIntervalOutputSize, maximumOutputSize))
        self.diagnostics = diagnostics
        self.workers = Workers(count: workerCount, outputLimit: outputLimit, diagnostics: diagnostics)
        // 窓、再 framing の一時コピー、候補配列、読み込み領域を含む予約。
        self.scannerReservation = Reservation(4 * compressedLimit + Bzip2BlockScanner.readSize + Bzip2StreamLayout.headerLength,
                                              diagnostics: diagnostics)
        self.scanner = try Bzip2BlockScanner(source: source, compressedLimit: compressedLimit, outputLimit: outputLimit,
                                            recordsChecksum: recorder != nil, injectedCandidates: injectedCandidates,
                                            injectedBitCandidates: injectedBitCandidates)
        if workerCount < 2 { try fallBack(at: 0) }
    }
    deinit { workers.abandon() }
    var isFinished: Bool { serial?.isFinished ?? finished }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !isFinished else { return 0 }
        do {
            while true {
                try Task.checkCancellation()
                if let serial {
                    try discardSerialPrefix(serial)
                    return try serial.read(into: buffer)
                }
                if let current, currentOffset < current.bytes.count {
                    let count = min(buffer.count, Self.outputChunkSize, current.bytes.count - currentOffset)
                    current.bytes.withUnsafeBytes { bytes in
                        buffer.baseAddress!.copyMemory(from: bytes.baseAddress!.advanced(by: currentOffset), byteCount: count)
                    }
                    currentOffset += count
                    streamOutput = try Checked.add(streamOutput, UInt64(count))
                    return count
                }
                current = nil; currentOffset = 0
                try fillJobs()
                if jobs.isEmpty {
                    if let fallbackOffset { try fallBack(at: fallbackOffset); continue }
                    finished = true; return 0
                }
                let job = jobs.removeFirst()
                switch try workers.take(job.id) {
                case .decoded(let output):
                    diagnostics?.decoded()
                    if outputStreamStart != job.streamStart { outputStreamStart = job.streamStart; streamOutput = 0 }
                    if let end = job.end {
                        let total = try Checked.add(streamOutput, UInt64(output.bytes.count))
                        recorder?.appendBzip2(compressedRange: end.range, outputSize: total, level: end.level, crc: end.crc)
                    }
                    current = output
                case .invalid:
                    try fallBack(at: job.streamStart)
                }
            }
        } catch {
            workers.abandon()
            throw error
        }
    }

    private func fallBack(at offset: UInt64) throws {
        workers.abandon(); diagnostics?.fallback()
        jobs = []; scanner = nil; current = nil
        serialSkip = outputStreamStart == offset ? streamOutput : 0
        serial = try Bzip2Decompressor(source: source, offset: offset, compressedSize: Checked.sub(source.length, offset),
                                      concatenatedStreams: true, recorder: recorder)
    }

    private func discardSerialPrefix(_ serial: Bzip2Decompressor) throws {
        guard serialSkip > 0 else { return }
        var buffer = [UInt8](repeating: 0, count: Self.outputChunkSize)
        while serialSkip > 0 {
            try Task.checkCancellation()
            let requested = Int(min(UInt64(buffer.count), serialSkip))
            let count = try buffer.withUnsafeMutableBytes {
                try serial.read(into: UnsafeMutableRawBufferPointer(rebasing: $0[..<requested]))
            }
            guard count > 0 else { throw KaitoError.truncated }
            serialSkip = try Checked.sub(serialSkip, UInt64(count))
        }
    }

    private func fillJobs() throws {
        // 消費済みの出力を解放してから、最大 W 区間までを投入する。
        while !scanningFinished, jobs.count < workerCount, let scanner {
            switch try scanner.next() {
            case .run(let run):
                let job = Job(id: nextJob, streamStart: run.streamStart, end: run.end)
                nextJob += 1; jobs.append(job); workers.submit(run.bytes, id: job.id)
            case .fallback(let offset):
                fallbackOffset = offset; scanningFinished = true
            case .end: scanningFinished = true
            }
        }
    }
}
