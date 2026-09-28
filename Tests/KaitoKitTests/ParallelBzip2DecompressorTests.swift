import Foundation
@_spi(TarEditLayout) @testable import KaitoKit
import XCTest

final class ParallelBzip2DecompressorTests: XCTestCase {
    func testStreamsErrorsAndFalseCandidatesMatchSerial() throws {
        let body = Data((0..<180_000).map { UInt8(truncatingIfNeeded: $0 * 37) })
        for level in [1, 9] {
            let multiple = try GyoshukuFramingTestSupport.bzip2(body, level: level, chunkSize: 65_536).data
            let empty = try GyoshukuFramingTestSupport.bzip2(Data(), level: level).data
            let one = try GyoshukuFramingTestSupport.bzip2(body, level: level).data
            var broken = multiple; broken[broken.count / 2] ^= 64
            var falseCandidate = multiple
            falseCandidate.insert(contentsOf: [0x42, 0x5a, 0x68, 0x39, 0x31, 0x41, 0x59, 0x26, 0x53, 0x59], at: 30)
            for bytes in [multiple, one, empty, empty + multiple + empty + multiple, multiple + Data([1]), broken,
                          Data(multiple.dropLast(5)), falseCandidate, Data("BZh9broken".utf8)] {
                let serial = TarEditTestSupport.decodeOutcome(try Bzip2Decompressor(source: DataByteSource(bytes), offset: 0, compressedSize: UInt64(bytes.count), concatenatedStreams: true))
                for workers in [1, 2, 8] {
                    for injected: [UInt64] in [[], [25]] {
                        let diagnostics = ParallelBzip2Decompressor.Diagnostics()
                        let parallel = TarEditTestSupport.decodeOutcome(try ParallelBzip2Decompressor(source: DataByteSource(bytes), workers: workers,
                                                                                                    injectedCandidates: injected, diagnostics: diagnostics))
                        XCTAssertEqual(parallel.error, serial.error, "level \(level), workers \(workers)")
                        if serial.error == nil { XCTAssertEqual(parallel.bytes, serial.bytes) }
                        else { XCTAssertTrue(serial.bytes.starts(with: parallel.bytes) || parallel.bytes.starts(with: serial.bytes)) }
                        XCTAssertLessThanOrEqual(diagnostics.peakWorkers, workers)
                        XCTAssertLessThanOrEqual(diagnostics.peakHeldBytes, (workers + 2) * 24 * 1_048_576)
                    }
                }
            }
        }
    }

    func testBoundsFallbackAndCompressedInputReadOnce() throws {
        let bytes = try TarEditTestSupport.fixture("bz.tbz")
        let source = CountingByteSource(DataByteSource(bytes))
        let recorder = CompressedTarMapRecorder(format: .bzip2)
        let diagnostics = ParallelBzip2Decompressor.Diagnostics()
        let output = try drain(ParallelBzip2Decompressor(source: source, recorder: recorder, workers: 8, diagnostics: diagnostics), bufferSize: 65_536)
        XCTAssertEqual(source.bytesRead, UInt64(bytes.count))
        XCTAssertEqual(diagnostics.fallbackCount, 0)
        XCTAssertNotNil(recorder.finish(imageLength: UInt64(output.count), archiveLength: source.length).map)
        for (compressedLimit, outputLimit) in [(1024, 16 * 1_048_576), (8 * 1_048_576, 1_048_576)] {
            let counters = ParallelBzip2Decompressor.Diagnostics()
            let actual = try drain(ParallelBzip2Decompressor(source: DataByteSource(bytes), workers: 2,
                                                             maximumCompressedSize: compressedLimit, maximumOutputSize: outputLimit, diagnostics: counters), bufferSize: 65_536)
            XCTAssertEqual(actual, output); XCTAssertEqual(counters.fallbackCount, 1)
        }
        let large = Data(repeating: 65, count: 16 * 1_048_576 + 1)
        let packed = try GyoshukuFramingTestSupport.bzip2(large, chunkSize: large.count).data
        let counters = ParallelBzip2Decompressor.Diagnostics()
        XCTAssertEqual(try drain(ParallelBzip2Decompressor(source: DataByteSource(packed), workers: 2, diagnostics: counters), bufferSize: 65_536), large)
        XCTAssertEqual(counters.fallbackCount, 1)
    }

    func testHeaderCandidateAcrossScanWindows() throws {
        let part = try GyoshukuFramingTestSupport.bzip2(Data(repeating: 65, count: 65_536), level: 1).data
        // 短い source read で 10 byte の候補をあらゆる位置で窓にまたがせる。
        for stride in 1...13 {
            let bytes = part + part + part
            let source = ShortReads(bytes, stride: stride)
            XCTAssertEqual(try drain(ParallelBzip2Decompressor(source: source, workers: 2), bufferSize: 65_536), Data(repeating: 65, count: 3 * 65_536))
        }
    }

    func testDeinitAbandonsWorkersWithinTwoSeconds() throws {
        let bytes = try TarEditTestSupport.fixture("bz.tbz")
        let diagnostics = ParallelBzip2Decompressor.Diagnostics()
        var decoder: ParallelBzip2Decompressor? = try ParallelBzip2Decompressor(source: DataByteSource(bytes + bytes + bytes), workers: 8, diagnostics: diagnostics)
        var buffer = [UInt8](repeating: 0, count: 1)
        XCTAssertEqual(try buffer.withUnsafeMutableBytes { try decoder!.read(into: $0) }, 1)
        decoder = nil
        let deadline = Date(timeIntervalSinceNow: 2)
        while diagnostics.liveWorkers > 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertEqual(diagnostics.liveWorkers, 0)
    }

    func testCancellationAbandonsWorkers() async throws {
        let bytes = try TarEditTestSupport.fixture("bz.tbz")
        let diagnostics = ParallelBzip2Decompressor.Diagnostics()
        let task = Task.detached {
            let decoder = try ParallelBzip2Decompressor(source: DataByteSource(bytes + bytes + bytes + bytes), workers: 8, diagnostics: diagnostics)
            let stream = try EntryStream(decompressor: decoder, length: nil, expectedCRC32: nil, entryIndex: 0, limits: ReadLimits())
            return try SingleFileMaterializer.materialize(stream, limits: ReadLimits()).length
        }
        let startedDeadline = Date(timeIntervalSinceNow: 2)
        while diagnostics.liveWorkers == 0 && Date() < startedDeadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertGreaterThan(diagnostics.liveWorkers, 0)
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        let deadline = Date(timeIntervalSinceNow: 2)
        while diagnostics.liveWorkers > 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(diagnostics.liveWorkers, 0)
    }
}

private final class ShortReads: ByteSource {
    let source: DataByteSource
    let stride: Int
    init(_ bytes: Data, stride: Int) { source = DataByteSource(bytes); self.stride = stride }
    var length: UInt64 { source.length }
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        try source.read(into: UnsafeMutableRawBufferPointer(rebasing: buffer.prefix(stride)), at: offset)
    }
}
