private import CBzip2
import Darwin
import Foundation

final class ParallelBzip2Decompressor: Decompressor {
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
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
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
                        let capacity = min(1_048_576, destination.count - total)
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

    init(source: any ByteSource, recorder: CompressedTarMapRecorder? = nil,
         workers: Int = min(8, ProcessInfo.processInfo.activeProcessorCount),
         maximumCompressedSize: Int = 8 * 1_048_576, maximumOutputSize: Int = 16 * 1_048_576,
         injectedCandidates: [UInt64] = [], diagnostics: Diagnostics? = nil) throws {
        self.source = source; self.recorder = recorder
        self.workerCount = max(1, min(8, workers))
        self.compressedLimit = max(10, min(8 * 1_048_576, maximumCompressedSize))
        self.diagnostics = diagnostics
        self.injectedCandidates = injectedCandidates.filter { $0 > 0 && $0 < source.length }.sorted()
        self.workers = Workers(count: max(1, min(8, workers)), outputLimit: max(1, min(16 * 1_048_576, maximumOutputSize)), diagnostics: diagnostics)
        self.scannerReservation = Reservation(self.compressedLimit + 10, diagnostics: diagnostics)
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
                    let count = min(buffer.count, 256 * 1024, current.bytes.count - currentOffset)
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
                    // この始点は直前に検証済みの END。以後を従来の状態機械へ戻す。
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
                let job = Job(id: nextJob, range: range, level: bytes[bytes.startIndex + 3] - 0x30, crc: recorder == nil ? 0 : CRC32.checksum(bytes))
                nextJob += 1; jobs.append(job); workers.submit(bytes, id: job.id)
            case .fallback(let offset):
                fallbackOffset = offset; scanningFinished = true
            case .end: scanningFinished = true
            }
        }
    }

    private func scanInterval() throws -> Scanned {
        while scan.count < 10, sourceOffset < source.length { try refillScan() }
        if scan.isEmpty, sourceOffset == source.length { return .end }
        guard Self.isCandidate(scan, at: 0) else { return .fallback(scanStart) }
        while true {
            var candidate = Self.nextCandidate(scan, from: searchOffset)
            if let injected = injectedCandidates.first(where: { $0 > scanStart && $0 < scanStart + UInt64(scan.count) }) {
                let relative = Int(injected - scanStart)
                candidate = min(candidate ?? relative, relative)
            }
            if let candidate {
                guard candidate >= 10, candidate <= compressedLimit else { return .fallback(scanStart) }
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
            if scan.count >= compressedLimit + 10 { return .fallback(scanStart) }
            searchOffset = max(1, scan.count - 9)
            try refillScan()
        }
    }
    private func refillScan() throws {
        let requested = min(1_048_576, compressedLimit + 10 - scan.count, Int(min(UInt64(Int.max), source.length - sourceOffset)))
        guard requested > 0 else { return }
        var bytes = Data(count: requested)
        let count = try bytes.withUnsafeMutableBytes { try source.read(into: $0, at: sourceOffset) }
        guard count >= 0, count <= requested else { throw KaitoError.malformed("ByteSource returned an invalid byte count") }
        guard count > 0 else { throw KaitoError.truncated }
        bytes.removeLast(requested - count); scan.append(bytes); sourceOffset += UInt64(count)
    }
    private static func isCandidate(_ bytes: Data, at offset: Int) -> Bool {
        bytes.withUnsafeBytes { isCandidate($0, at: offset) }
    }
    private static func isCandidate(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> Bool {
        guard offset >= 0, offset + 10 <= bytes.count,
              bytes[offset] == 0x42, bytes[offset + 1] == 0x5a, bytes[offset + 2] == 0x68,
              (0x31...0x39).contains(bytes[offset + 3]) else { return false }
        let magic = bytes[(offset + 4)..<(offset + 10)]
        return magic.elementsEqual([0x31, 0x41, 0x59, 0x26, 0x53, 0x59]) || magic.elementsEqual([0x17, 0x72, 0x45, 0x38, 0x50, 0x90])
    }
    private static func nextCandidate(_ data: Data, from start: Int) -> Int? {
        data.withUnsafeBytes { bytes in
            guard bytes.count >= 10, let base = bytes.baseAddress else { return nil }
            var cursor = start
            while cursor <= bytes.count - 10 {
                guard let found = memchr(base.advanced(by: cursor), 0x42, bytes.count - 9 - cursor) else { return nil }
                let offset = base.distance(to: found)
                if isCandidate(bytes, at: offset) { return offset }
                cursor = offset + 1
            }
            return nil
        }
    }
}
