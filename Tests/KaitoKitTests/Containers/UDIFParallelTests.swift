import Compression
import Foundation
import Synchronization
@testable import KaitoKit
import XCTest
import zlib

final class UDIFParallelTests: XCTestCase {
    private struct Chunk: Sendable {
        let type: UInt32
        let body: Data
        let packed: Data
    }
    private struct Image: Sendable {
        let data: Data
        let body: Data
        let packedRanges: [Range<UInt64>]
    }
    private static let chunkSize = 65_536

    private static func chunk(_ type: UInt32, seed: Int) throws -> Chunk {
        let body = Data((0..<chunkSize).map { UInt8(truncatingIfNeeded: ($0 / 97 + seed * 31) ^ ($0 % 23)) })
        let packed: Data
        switch type {
        case 0, 2: return Chunk(type: type, body: Data(count: chunkSize), packed: Data())
        case 1: packed = body
        case 0x8000_0005:
            var output = Data(count: Int(compressBound(uLong(body.count))))
            var size = uLongf(output.count)
            let status = body.withUnsafeBytes { input in
                output.withUnsafeMutableBytes { destination in
                    compress2(destination.bindMemory(to: Bytef.self).baseAddress!, &size,
                              input.bindMemory(to: Bytef.self).baseAddress!, uLong(input.count), 6)
                }
            }
            guard status == Z_OK else { throw KaitoError.malformed("test zlib encoder") }
            output.removeLast(output.count - Int(size)); packed = output
        case 0x8000_0006: packed = try CompressedTarFramingTestSupport.bzip2(body).data
        case 0x8000_0007:
            var output = Data(count: body.count * 2)
            let size = body.withUnsafeBytes { input in
                output.withUnsafeMutableBytes { destination in
                    compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, destination.count,
                        input.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_LZFSE)
                }
            }
            guard size > 0 else { throw KaitoError.malformed("test lzfse encoder") }
            output.removeLast(output.count - size); packed = output
        case 0x8000_0008: packed = try CompressedTarFramingTestSupport.xz(body).data
        default: packed = Data([0]) // ADC / 未知 type の遅延拒否を検査する。
        }
        return Chunk(type: type, body: body, packed: packed)
    }

    /// 既存の DMGReaderTests と同じ mish / plist / koly の synthetic writer。
    private static func image(_ chunks: [Chunk]) throws -> Image {
        func put(_ value: UInt64, in data: inout Data, at offset: Int, width: Int = 8) {
            for i in 0..<width { data[offset + i] = UInt8(truncatingIfNeeded: value >> ((width - i - 1) * 8)) }
        }
        var table = Data(count: 204 + chunks.count * 40), data = Data(), body = Data()
        var ranges: [Range<UInt64>] = []
        table.replaceSubrange(0..<4, with: "mish".utf8)
        put(1, in: &table, at: 4, width: 4)
        put(UInt64(chunks.reduce(0) { $0 + $1.body.count } / 512), in: &table, at: 16)
        put(UInt64(chunks.count), in: &table, at: 200, width: 4)
        for (index, chunk) in chunks.enumerated() {
            let offset = 204 + index * 40
            put(UInt64(chunk.type), in: &table, at: offset, width: 4)
            put(UInt64(body.count / 512), in: &table, at: offset + 8)
            put(UInt64(chunk.body.count / 512), in: &table, at: offset + 16)
            put(UInt64(data.count), in: &table, at: offset + 24)
            put(UInt64(chunk.packed.count), in: &table, at: offset + 32)
            ranges.append(UInt64(data.count)..<UInt64(data.count + chunk.packed.count))
            data.append(chunk.packed); body.append(chunk.body)
        }
        let xml = try PropertyListSerialization.data(fromPropertyList:
            ["resource-fork": ["blkx": [["Data": table]]]], format: .xml, options: 0)
        var trailer = Data(count: 512)
        trailer.replaceSubrange(0..<4, with: "koly".utf8)
        put(4, in: &trailer, at: 4, width: 4); put(512, in: &trailer, at: 8, width: 4)
        put(UInt64(data.count), in: &trailer, at: 32)
        put(UInt64(data.count), in: &trailer, at: 216); put(UInt64(xml.count), in: &trailer, at: 224)
        put(UInt64(body.count / 512), in: &trailer, at: 492)
        return Image(data: data + xml + trailer, body: body, packedRanges: ranges)
    }

    private static func disk(_ image: Image, threads: Int, limits: ReadLimits = ReadLimits(),
                             source: (any ByteSource)? = nil, pool: LeafDecodePool = .shared,
                             diagnostics: UDIFChunkCache.Diagnostics? = nil) throws -> UDIFDiskByteSource {
        let file = source ?? DataByteSource(image.data)
        return try UDIFDiskByteSource(file: file, trailer: XCTUnwrap(UDIFTrailer.read(source: file)),
                                     limits: limits, decodeThreads: threads, pool: pool, diagnostics: diagnostics)
    }

    func testAllSupportedChunksSerialParallelAndRandomAccessAreByteIdentical() throws {
        for type: UInt32 in [0x8000_0005, 0x8000_0006, 0x8000_0007, 0x8000_0008, 1, 0, 2] {
            let image = try Self.image((0..<24).map { try Self.chunk(type, seed: $0) })
            let serial = try Self.disk(image, threads: 1)
            let parallel = try Self.disk(image, threads: 16)
            XCTAssertEqual(Data(try readByteRange(source: serial, offset: 0, count: image.body.count)), image.body)
            XCTAssertEqual(Data(try readByteRange(source: parallel, offset: 0, count: image.body.count)), image.body)
            var random: UInt64 = 0x4b6169746f
            for _ in 0..<120 {
                random = random &* 6_364_136_223_846_793_005 &+ 1
                let offset = Int(random % UInt64(image.body.count))
                let count = min(1 + Int((random >> 32) % 90_000), image.body.count - offset)
                let actual = try readByteRange(source: parallel, offset: UInt64(offset), count: count)
                XCTAssertEqual(actual, try readByteRange(source: serial, offset: UInt64(offset), count: count))
                XCTAssertEqual(Data(actual), image.body.subdata(in: offset..<(offset + count)))
            }
        }
        let mixed = try Self.image((0..<28).map {
            try Self.chunk([0x8000_0005, 1, 0, 0x8000_0006, 2, 0x8000_0007, 0x8000_0008][$0 % 7], seed: $0)
        })
        XCTAssertEqual(Data(try readByteRange(source: Self.disk(mixed, threads: 16), offset: 0, count: mixed.body.count)), mixed.body)
    }

    func testReadAheadCorruptionThrowsOnlyWhenItsChunkIsRead() throws {
        for type: UInt32 in [0x8000_0005, 0x8000_0006, 0x8000_0007, 0x8000_0008, 0x8000_0004, 0x8000_0099] {
            var chunks = try (0..<12).map { try Self.chunk(0x8000_0005, seed: $0) }
            let valid = try Self.chunk(type, seed: 6)
            let corrupt = Data(repeating: 0xff, count: valid.packed.count)
            chunks[6] = Chunk(type: type, body: valid.body, packed: corrupt)
            let image = try Self.image(chunks)
            var errors: [KaitoError] = []
            for threads in [1, 16] {
                let disk = try Self.disk(image, threads: threads)
                var earlier = Data()
                for index in 0..<6 {
                    earlier.append(contentsOf: try readByteRange(source: disk, offset: UInt64(index * Self.chunkSize), count: Self.chunkSize))
                }
                XCTAssertEqual(earlier, image.body.prefix(6 * Self.chunkSize))
                for _ in 0..<2 {
                    XCTAssertThrowsError(try readByteRange(source: disk, offset: UInt64(6 * Self.chunkSize), count: 1)) {
                        guard let error = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
                        errors.append(error)
                    }
                }
                // 失敗した先読みの後でも、離れた健全 chunk を読める。
                XCTAssertEqual(Data(try readByteRange(source: disk, offset: UInt64(10 * Self.chunkSize), count: 512)),
                    image.body.subdata(in: (10 * Self.chunkSize)..<(10 * Self.chunkSize + 512)))
            }
            XCTAssertEqual(errors.count, 4)
            XCTAssertTrue(errors.allSatisfy { $0 == errors.first }, "serial/parallel errors: \(errors)")
        }
    }

    func testMemoryBudgetBoundsCacheAndReadAheadAndZeroBudgetStaysSerial() throws {
        let image = try Self.image((0..<32).map { try Self.chunk(0x8000_0005, seed: $0) })
        for budget in [0, Self.chunkSize, Self.chunkSize * 3, Self.chunkSize * 18] {
            let diagnostics = UDIFChunkCache.Diagnostics(), submitted = Mutex(0)
            do {
                let disk = try Self.disk(image, threads: 16, limits: ReadLimits(parallelDecodeMemory: UInt64(budget)), diagnostics: diagnostics)
                try LeafDecodePool.$testingSubmission.withValue({ submitted.withLock { $0 += 1 } }) {
                    XCTAssertEqual(Data(try readByteRange(source: disk, offset: 0, count: image.body.count)), image.body)
                }
                XCTAssertLessThanOrEqual(diagnostics.peakHeldBytes, budget)
                XCTAssertEqual(submitted.withLock { $0 > 0 }, budget >= Self.chunkSize * 2)
            }
            XCTAssertEqual(diagnostics.heldBytes, 0)
        }
    }

    func testConcurrentConsumersShareInflightDecodeWithoutHoldingCacheLock() throws {
        let image = try Self.image((0..<8).map { try Self.chunk(0x8000_0005, seed: $0) })
        let gate = GateSource(image.data, range: image.packedRanges[0])
        let diagnostics = UDIFChunkCache.Diagnostics()
        let disk = try Self.disk(image, threads: 1, source: gate, diagnostics: diagnostics)
        let failures = Mutex<[String]>([]), group = DispatchGroup()
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let bytes = try readByteRange(source: disk, offset: 0, count: 4096)
                    if Data(bytes) != image.body.prefix(4096) { failures.withLock { $0.append("wrong bytes") } }
                } catch { failures.withLock { $0.append(String(describing: error)) } }
            }
        }
        XCTAssertEqual(gate.started.wait(timeout: .now() + 5), .success)
        defer { gate.release.signal() }
        // 別 chunk は gate を開く前に復号できる。
        XCTAssertEqual(Data(try readByteRange(source: disk, offset: UInt64(Self.chunkSize), count: 4096)),
            image.body.subdata(in: Self.chunkSize..<(Self.chunkSize + 4096)))
        gate.release.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(failures.withLock { $0 }, [])
        XCTAssertEqual(diagnostics.decodeCount(0), 1)
        XCTAssertGreaterThanOrEqual(diagnostics.peakWorkers, 2)
    }

    func testParallelLeavesFinishAheadWithoutDeliveringAFutureErrorEarly() throws {
        var chunks = try (0..<8).map { try Self.chunk(0x8000_0005, seed: $0) }
        chunks[1] = Chunk(type: chunks[1].type, body: chunks[1].body, packed: Data([0xff, 0xff]))
        let image = try Self.image(chunks)
        let gate = GateSource(image.data, range: image.packedRanges[0]), pool = LeafDecodePool(capacity: 2)
        let diagnostics = UDIFChunkCache.Diagnostics()
        let disk = try Self.disk(image, threads: 16, source: gate, pool: pool, diagnostics: diagnostics)
        let completed = DispatchSemaphore(value: 0), result = Mutex<Result<[UInt8], any Error>?>(nil)
        DispatchQueue.global().async {
            let bytes = Result { try readByteRange(source: disk, offset: 0, count: Self.chunkSize) }
            result.withLock { $0 = bytes }; completed.signal()
        }
        XCTAssertEqual(gate.started.wait(timeout: .now() + 5), .success)
        defer { gate.release.signal() }
        XCTAssertTrue(Self.eventually { diagnostics.decodeCount(3) > 0 })
        XCTAssertEqual(diagnostics.peakWorkers, 2)
        XCTAssertEqual(completed.wait(timeout: .now() + 0.05), .timedOut,
                       "a future failure must not complete or fail the earlier read")
        gate.release.signal()
        XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(Data(try XCTUnwrap(result.withLock { $0 }).get()), image.body.prefix(Self.chunkSize))
        let serial = try Self.disk(image, threads: 1)
        var errors: [KaitoError] = []
        for source in [serial, disk] {
            XCTAssertThrowsError(try readByteRange(source: source, offset: UInt64(Self.chunkSize), count: 1)) {
                if let error = $0 as? KaitoError { errors.append(error) } else { XCTFail("Unexpected error: \($0)") }
            }
        }
        XCTAssertEqual(errors.count, 2); XCTAssertEqual(errors.first, errors.last)
    }

    func testConcurrentReadersAndSeekOnTheSameParallelImage() throws {
        let image = try Self.image((0..<32).map { try Self.chunk(0x8000_0005, seed: $0) })
        let disk = try Self.disk(image, threads: 16), failures = Mutex<[String]>([])
        DispatchQueue.concurrentPerform(iterations: 8) { reader in
            do {
                for step in 0..<80 {
                    let offset = ((step * 7 + reader * 11) % 31) * Self.chunkSize + 113
                    let bytes = try readByteRange(source: disk, offset: UInt64(offset), count: 70_000)
                    if Data(bytes) != image.body.subdata(in: offset..<(offset + 70_000)) {
                        failures.withLock { $0.append("wrong random bytes") }
                    }
                }
                let independent = try Self.disk(image, threads: 16)
                if Data(try readByteRange(source: independent, offset: 0, count: image.body.count)) != image.body {
                    failures.withLock { $0.append("wrong independent bytes") }
                }
            } catch { failures.withLock { $0.append(String(describing: error)) } }
        }
        XCTAssertEqual(failures.withLock { $0 }, [])
    }

    func testReadersExceedingActiveCPUsFinishMultiChunkDecode() async throws {
        let image = try Self.image((0..<24).map { try Self.chunk(0x8000_0005, seed: $0) })
        let readers = max(12, 2 * ProcessInfo.processInfo.activeProcessorCount)
        try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<readers {
                group.addTask {
                    let disk = try Self.disk(image, threads: 16)
                    return Data(try readByteRange(source: disk, offset: 0, count: image.body.count))
                }
            }
            var completed = 0
            for try await bytes in group { XCTAssertEqual(bytes, image.body); completed += 1 }
            XCTAssertEqual(completed, readers)
        }
    }

    func testAbandonmentReleasesQueuedJobsWithoutRetainingTheDisk() throws {
        let image = try Self.image((0..<24).map { try Self.chunk(0x8000_0005, seed: $0) })
        let gate = GateSource(image.data, range: image.packedRanges[1]), pool = LeafDecodePool(capacity: 1)
        let diagnostics = UDIFChunkCache.Diagnostics()
        var disk: UDIFDiskByteSource? = try Self.disk(image, threads: 16, source: gate, pool: pool, diagnostics: diagnostics)
        weak let weakDisk = disk
        XCTAssertEqual(try readByteRange(source: XCTUnwrap(disk), offset: 0, count: 1), [image.body[0]])
        XCTAssertEqual(gate.started.wait(timeout: .now() + 5), .success)
        disk = nil
        XCTAssertNil(weakDisk)
        XCTAssertLessThanOrEqual(diagnostics.heldBytes, Self.chunkSize, "only the running gated leaf may retain its reservation")
        let drained = DispatchSemaphore(value: 0)
        pool.submit(group: LeafDecodePool.Group()) { drained.signal() }
        gate.release.signal()
        XCTAssertEqual(drained.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(Self.eventually { diagnostics.heldBytes == 0 })
        XCTAssertEqual(diagnostics.liveWorkers, 0)
        XCTAssertEqual(diagnostics.decodeCount(2), 0, "queued speculation must be cancelled")
    }

    func testReaderOptionsWireResolvedThreadsIntoDMG() throws {
        let image = try TestFixtures.gzipBase64("dmg/hfs-zlib.dmg")
        for threads in [1, 16] {
            let submitted = Mutex(0)
            try LeafDecodePool.$testingSubmission.withValue({ submitted.withLock { $0 += 1 } }) {
                let reader = try ArchiveReader.open(data: image, options: ReaderOptions(decodeThreads: threads))
                for entry in reader.entries where entry.kind == .file { _ = try reader.read(entry) }
            }
            XCTAssertEqual(submitted.withLock { $0 > 0 }, threads > 1)
        }
    }

    func testTaskCancellationReleasesQueuedSpeculationWhileALeafIsRunning() async throws {
        let image = try Self.image((0..<24).map { try Self.chunk(0x8000_0005, seed: $0) })
        let gate = GateSource(image.data, range: image.packedRanges[0]), pool = LeafDecodePool(capacity: 1)
        let diagnostics = UDIFChunkCache.Diagnostics()
        let disk = try Self.disk(image, threads: 16, source: gate, pool: pool, diagnostics: diagnostics)
        let read = Task.detached { try readByteRange(source: disk, offset: 0, count: 1) }
        XCTAssertEqual(gate.started.wait(timeout: .now() + 5), .success)
        defer { gate.release.signal() }
        read.cancel()
        do { _ = try await read.value; XCTFail("cancelled consumer succeeded") }
        catch { XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)") }
        XCTAssertLessThanOrEqual(diagnostics.heldBytes, Self.chunkSize)
        let drained = DispatchSemaphore(value: 0)
        pool.submit(group: LeafDecodePool.Group()) { drained.signal() }
        gate.release.signal()
        XCTAssertEqual(drained.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(diagnostics.decodeCount(1), 0)
        XCTAssertTrue(Self.eventually { diagnostics.heldBytes == 0 })
        // 一つの consumer のキャンセル後でも ByteSource の random read は再利用できる。
        XCTAssertEqual(Data(try readByteRange(source: disk, offset: UInt64(3 * Self.chunkSize), count: 512)),
                       image.body.subdata(in: (3 * Self.chunkSize)..<(3 * Self.chunkSize + 512)))
    }

    private static func eventually(_ predicate: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: 5)
        while !predicate(), Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        return predicate()
    }

    private final class GateSource: ByteSource {
        let data: Data
        let range: Range<UInt64>
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        private let gated = Mutex(false)
        init(_ data: Data, range: Range<UInt64>) { self.data = data; self.range = range }
        var length: UInt64 { UInt64(data.count) }
        func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
            if range.contains(offset), gated.withLock({ value in
                if value { return false }; value = true; return true
            }) {
                started.signal()
                guard release.wait(timeout: .now() + 10) == .success else { throw KaitoError.malformed("test gate timed out") }
            }
            return try DataByteSource(data).read(into: buffer, at: offset)
        }
    }
}
