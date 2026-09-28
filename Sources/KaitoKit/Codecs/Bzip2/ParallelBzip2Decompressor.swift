private import CBzip2
import Darwin
import Foundation

/// 連結された bzip2 stream を区間に分け、上限付きの worker で並列に復号して順に返す。
///
/// 入力を走査し、byte 境界の stream 開始（`Bzip2StreamLayout.isStreamStart`）を区間の
/// 候補にする。各区間は一つの完全な stream として worker が復号し、出力は区間の順に返す。
/// 区間が stream 終端でちょうど終わらない場合（偽の候補、展開上限の超過）や、圧縮上限内に
/// 次の候補がない場合は、その区間の先頭から直列の `Bzip2Decompressor` へ切り替える。
/// 保持量は worker 数、区間の圧縮上限と展開上限で抑える。
/// 失敗は latch しない。`read(into:)` は throw する時点で worker を放棄するので、instance を破棄する。
final class ParallelBzip2Decompressor: Decompressor {
    /// 同時に復号する worker 数の上限。
    private static let maximumWorkerCount = 8
    /// 一区間の圧縮 byte 数の上限。init の既定値でもある。
    private static let maximumIntervalSize = 8 * 1_048_576
    /// 一区間の展開 byte 数の上限。init の既定値でもある。
    private static let maximumIntervalOutputSize = 16 * 1_048_576
    /// worker が放棄を確かめるまでに書く展開 byte 数。
    private static let abandonmentCheckInterval = 1_048_576
    /// 走査で一度に読む圧縮 byte 数。
    private static let scanReadSize = 1_048_576
    /// 一回の `read(into:)` で返す byte 数の上限。
    private static let outputChunkSize = 256 * 1_024
    /// worker の完了を待つ間に Task の取消を確かめる間隔（秒）。
    private static let resultPollInterval: TimeInterval = 0.05

    /// Test hook: worker 数、保持 byte 数、直列への切替回数を観測する。本番の呼出元は渡さない。
    final class Diagnostics: @unchecked Sendable {
        private let lock = NSLock()
        private var live = 0, peak = 0, held = 0, peakHeld = 0, fallbacks = 0
        var liveWorkers: Int { lock.withLock { live } }
        var peakWorkers: Int { lock.withLock { peak } }
        var peakHeldBytes: Int { lock.withLock { peakHeld } }
        var fallbackCount: Int { lock.withLock { fallbacks } }
        fileprivate func worker(_ delta: Int) { lock.withLock { live += delta; peak = max(peak, live) } }
        fileprivate func bytes(_ delta: Int) { lock.withLock { held += delta; peakHeld = max(peakHeld, held) } }
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
        let range: Range<UInt64>
        let level: UInt8
        let crc: UInt32
    }
    private enum Scanned {
        case interval(Data, Range<UInt64>)
        case fallback(UInt64)
        case end
    }

    private let source: any ByteSource
    private let recorder: CompressedTarMapRecorder?
    private let workerCount: Int
    private let compressedLimit: Int
    private let workers: Workers
    private let diagnostics: Diagnostics?
    private let scannerReservation: Reservation
    private let injectedCandidates: [UInt64]
    private var scan = Data()
    private var scanStart: UInt64 = 0
    private var sourceOffset: UInt64 = 0
    private var searchOffset = 1
    private var jobs: [Job] = []
    private var nextJob = 0
    private var scanningFinished = false
    private var fallbackOffset: UInt64?
    private var serial: Bzip2Decompressor?
    private var current: Decoded?
    private var currentOffset = 0
    private var finished = false

    /// - Parameters:
    ///   - injectedCandidates: Test hook: 走査に加える偽の区間候補（絶対 offset）。本番の呼出元は渡さない。
    ///   - diagnostics: Test hook: 観測値の記録先。本番の呼出元は渡さない。
    init(source: any ByteSource, recorder: CompressedTarMapRecorder? = nil,
         workers: Int = min(ParallelBzip2Decompressor.maximumWorkerCount, ProcessInfo.processInfo.activeProcessorCount),
         maximumCompressedSize: Int = ParallelBzip2Decompressor.maximumIntervalSize,
         maximumOutputSize: Int = ParallelBzip2Decompressor.maximumIntervalOutputSize,
         injectedCandidates: [UInt64] = [], diagnostics: Diagnostics? = nil) throws {
        self.source = source; self.recorder = recorder
        self.workerCount = max(1, min(Self.maximumWorkerCount, workers))
        self.compressedLimit = max(Bzip2StreamLayout.headerLength, min(Self.maximumIntervalSize, maximumCompressedSize))
        self.diagnostics = diagnostics
        self.injectedCandidates = injectedCandidates.filter { $0 > 0 && $0 < source.length }.sorted()
        self.workers = Workers(count: max(1, min(Self.maximumWorkerCount, workers)),
                               outputLimit: max(1, min(Self.maximumIntervalOutputSize, maximumOutputSize)), diagnostics: diagnostics)
        self.scannerReservation = Reservation(self.compressedLimit + Bzip2StreamLayout.headerLength, diagnostics: diagnostics)
        if workerCount < 2 { try fallBack(at: 0) }
    }
    deinit { workers.abandon() }
    var isFinished: Bool { serial?.isFinished ?? finished }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !isFinished else { return 0 }
        do {
            while true {
                if let serial { return try serial.read(into: buffer) }
                if let current, currentOffset < current.bytes.count {
                    let count = min(buffer.count, Self.outputChunkSize, current.bytes.count - currentOffset)
                    current.bytes.withUnsafeBytes { bytes in
                        buffer.baseAddress!.copyMemory(from: bytes.baseAddress!.advanced(by: currentOffset), byteCount: count)
                    }
                    currentOffset += count
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
                    recorder?.appendBzip2(compressedRange: job.range, outputSize: UInt64(output.bytes.count), level: job.level, crc: job.crc)
                    current = output
                case .invalid:
                    // この始点は直前の区間が検証済みの END で終わった位置。以後は直列 decoder で復号する。
                    try fallBack(at: job.range.lowerBound)
                }
            }
        } catch {
            workers.abandon()
            throw error
        }
    }

    private func fallBack(at offset: UInt64) throws {
        workers.abandon(); diagnostics?.fallback()
        jobs = []; scan = Data(); current = nil
        serial = try Bzip2Decompressor(source: source, offset: offset, compressedSize: source.length - offset,
                                      concatenatedStreams: true, recorder: recorder)
    }
    private func fillJobs() throws {
        // scanner と完了通知の受け渡しに各 1 区間を残す。消費済みの出力は先に解放する。
        while !scanningFinished, jobs.count < workerCount {
            switch try scanInterval() {
            case .interval(let bytes, let range):
                let levelDigit = bytes[bytes.startIndex + Bzip2StreamLayout.streamHeaderLength - 1]
                let job = Job(id: nextJob, range: range, level: levelDigit - Bzip2StreamLayout.levelDigitBase,
                              crc: recorder == nil ? 0 : CRC32.checksum(bytes))
                nextJob += 1; jobs.append(job); workers.submit(bytes, id: job.id)
            case .fallback(let offset):
                fallbackOffset = offset; scanningFinished = true
            case .end: scanningFinished = true
            }
        }
    }

    private func scanInterval() throws -> Scanned {
        while scan.count < Bzip2StreamLayout.headerLength, sourceOffset < source.length { try refillScan() }
        if scan.isEmpty, sourceOffset == source.length { return .end }
        guard Self.isCandidate(scan, at: 0) else { return .fallback(scanStart) }
        while true {
            var candidate = Self.nextCandidate(scan, from: searchOffset)
            if let injected = injectedCandidates.first(where: { $0 > scanStart && $0 < scanStart + UInt64(scan.count) }) {
                let relative = Int(injected - scanStart)
                candidate = min(candidate ?? relative, relative)
            }
            if let candidate {
                guard candidate >= Bzip2StreamLayout.headerLength, candidate <= compressedLimit else { return .fallback(scanStart) }
                let bytes = Data(scan.prefix(candidate)), range = scanStart..<(scanStart + UInt64(candidate))
                scan = Data(scan.dropFirst(candidate)); scanStart = range.upperBound; searchOffset = 1
                return .interval(bytes, range)
            }
            if sourceOffset == source.length {
                guard scan.count <= compressedLimit else { return .fallback(scanStart) }
                let bytes = scan, range = scanStart..<sourceOffset
                scan = Data(); scanStart = sourceOffset; searchOffset = 1
                return .interval(bytes, range)
            }
            if scan.count >= compressedLimit + Bzip2StreamLayout.headerLength { return .fallback(scanStart) }
            // 末尾の headerLength - 1 byte は次の refill 後に候補の先頭になり得る。
            searchOffset = max(1, scan.count - (Bzip2StreamLayout.headerLength - 1))
            try refillScan()
        }
    }
    private func refillScan() throws {
        let requested = min(Self.scanReadSize, compressedLimit + Bzip2StreamLayout.headerLength - scan.count,
                            Int(min(UInt64(Int.max), source.length - sourceOffset)))
        guard requested > 0 else { return }
        var bytes = Data(count: requested)
        let count = try bytes.withUnsafeMutableBytes { try source.read(into: $0, at: sourceOffset) }
        guard count >= 0, count <= requested else { throw KaitoError.malformed("ByteSource returned an invalid byte count") }
        guard count > 0 else { throw KaitoError.truncated }
        bytes.removeLast(requested - count); scan.append(bytes); sourceOffset += UInt64(count)
    }
    private static func isCandidate(_ bytes: Data, at offset: Int) -> Bool {
        bytes.withUnsafeBytes { Bzip2StreamLayout.isStreamStart($0, at: offset) }
    }
    private static func nextCandidate(_ data: Data, from start: Int) -> Int? {
        data.withUnsafeBytes { bytes in
            let headerLength = Bzip2StreamLayout.headerLength
            guard bytes.count >= headerLength, let base = bytes.baseAddress else { return nil }
            var cursor = start
            while cursor <= bytes.count - headerLength {
                guard let found = memchr(base.advanced(by: cursor), Int32(Bzip2StreamLayout.signature[0]),
                                         bytes.count - (headerLength - 1) - cursor) else { return nil }
                let offset = base.distance(to: found)
                if Bzip2StreamLayout.isStreamStart(bytes, at: offset) { return offset }
                cursor = offset + 1
            }
            return nil
        }
    }
}
