import Foundation
@_spi(TarEditLayout) @testable import KaitoKit
import XCTest

final class ParallelBzip2DecompressorTests: XCTestCase {
    private struct Corpus: Sendable {
        let image: Data
        let packed: [Int: Data]
    }
    private static let corpus = Result<Corpus, Error> {
        let text = Array("bzip2 block decoding preserves the tar stream and its original chunk map.\n".utf8)
        var state: UInt64 = 0x189c82f0
        var body = [UInt8](repeating: 0, count: 10 * 1_048_576)
        for index in body.indices {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            body[index] = index < 128 * 1024 ? text[index % text.count] : UInt8(truncatingIfNeeded: state)
        }
        let image = try TarTestSupport.makeTar(entries: [HandTarEntry(name: "blocks", contents: Data(body))])
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var packed: [Int: Data] = [:]
        for level in [1, 9] {
            let input = try TarTestSupport.write(image, relativePath: "input-\(level).tar", below: directory)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/bzip2")
            process.arguments = ["-\(level)", "-k", input.path]
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw TarTestSupportError.commandFailed("bzip2 \(level)") }
            packed[level] = try Data(contentsOf: input.appendingPathExtension("bz2"))
        }
        return Corpus(image: image, packed: packed)
    }

    func testSingleStreamBlockRunsMatchSerialAndMap() throws {
        let corpus = try Self.corpus.get()
        for level in [1, 9] {
            let packed = try XCTUnwrap(corpus.packed[level])
            XCTAssertGreaterThan(packed.count, 8 * 1_048_576)
            let positions = packed.withUnsafeBytes { Bzip2StreamLayout.blockMagicPositions(in: $0, baseBit: 0) }
            XCTAssertGreaterThan(positions.count, 10)
            XCTAssertTrue(positions.contains { $0 % 8 != 0 })
            let serialRecorder = CompressedTarMapRecorder(format: .bzip2)
            let serial = try drain(Bzip2Decompressor(source: DataByteSource(packed), offset: 0, compressedSize: UInt64(packed.count),
                                                   concatenatedStreams: true, recorder: serialRecorder), bufferSize: 65_536)
            XCTAssertEqual(serial, corpus.image)
            let expectedMap = try XCTUnwrap(serialRecorder.finish(imageLength: UInt64(serial.count), archiveLength: UInt64(packed.count)).map)
            XCTAssertEqual(expectedMap.chunks.count, 1)
            for workers in [2, 8] {
                let source = CountingByteSource(DataByteSource(packed))
                let recorder = CompressedTarMapRecorder(format: .bzip2)
                let diagnostics = ParallelBzip2Decompressor.Diagnostics()
                let actual = try drain(ParallelBzip2Decompressor(source: source, recorder: recorder, workers: workers,
                                                                 diagnostics: diagnostics), bufferSize: 65_536)
                XCTAssertEqual(actual, serial)
                XCTAssertEqual(recorder.finish(imageLength: UInt64(actual.count), archiveLength: source.length).map, expectedMap)
                XCTAssertEqual(source.bytesRead, source.length)
                XCTAssertEqual(diagnostics.fallbackCount, 0)
                XCTAssertGreaterThan(diagnostics.decodedRunCount, 1)
                XCTAssertGreaterThanOrEqual(diagnostics.peakWorkers, 1)
                XCTAssertLessThanOrEqual(diagnostics.peakWorkers, workers)
                XCTAssertLessThanOrEqual(diagnostics.peakHeldBytes, (workers + 2) * 24 * 1_048_576)
            }
        }
    }

    func testFalseBitCandidatesReplayEmittedPrefixAndPreserveMap() throws {
        let corpus = try Self.corpus.get(), packed = try XCTUnwrap(corpus.packed[9])
        let positions = packed.withUnsafeBytes { Bzip2StreamLayout.blockMagicPositions(in: $0, baseBit: 0) }
        let falseByteBit = (positions[10] / 8 + 100) * 8
        let leading = try CompressedTarFramingTestSupport.bzip2(Data("preceding stream".utf8)).data
        for prefix in [Data(), leading] {
            let bytes = prefix + packed
            let serialRecorder = CompressedTarMapRecorder(format: .bzip2)
            let serial = try drain(Bzip2Decompressor(source: DataByteSource(bytes), offset: 0, compressedSize: UInt64(bytes.count),
                                                   concatenatedStreams: true, recorder: serialRecorder), bufferSize: 65_536)
            let expectedMap = try XCTUnwrap(serialRecorder.finish(imageLength: UInt64(serial.count), archiveLength: UInt64(bytes.count)).map)
            for alignment: UInt64 in [0, 3] {
                let diagnostics = ParallelBzip2Decompressor.Diagnostics(), recorder = CompressedTarMapRecorder(format: .bzip2)
                let decoder = try ParallelBzip2Decompressor(source: DataByteSource(bytes), recorder: recorder, workers: 2,
                    injectedBitCandidates: [UInt64(prefix.count) * 8 + falseByteBit + alignment], diagnostics: diagnostics)
                XCTAssertEqual(try drain(decoder, bufferSize: 65_536), serial)
                XCTAssertEqual(diagnostics.fallbackCount, 1)
                XCTAssertGreaterThanOrEqual(diagnostics.decodedRunCount, prefix.isEmpty ? 1 : 2)
                XCTAssertEqual(recorder.finish(imageLength: UInt64(serial.count), archiveLength: UInt64(bytes.count)).map, expectedMap)
            }
        }
    }

    func testBlockTruncationCorruptionAndCombinedCRCMatchSerial() throws {
        let corpus = try Self.corpus.get(), packed = try XCTUnwrap(corpus.packed[9])
        let positions = packed.withUnsafeBytes { Bzip2StreamLayout.blockMagicPositions(in: $0, baseBit: 0) }
        let boundary = positions[10]
        var atBoundary = Data(packed.prefix(Int((boundary + 7) / 8)))
        if boundary % 8 != 0 { atBoundary[atBoundary.count - 1] &= UInt8.max << (8 - Int(boundary % 8)) }
        let midBlock = Data(packed.prefix(Int((boundary + positions[11]) / 16)))
        var flipped = packed
        flipped[Int(boundary / 8) + 150] ^= 4
        var badCombined = packed
        let eos = try XCTUnwrap(packed.withUnsafeBytes { Bzip2StreamLayout.endMagicPositions(in: $0, baseBit: 0).last })
        let crcBit = eos + Bzip2StreamLayout.magicBitCount
        badCombined[Int(crcBit / 8)] ^= 0x80 >> Int(crcBit % 8)
        let missingCRC = Data(packed.dropLast(3))
        for bytes in [atBoundary, midBlock, flipped, badCombined, missingCRC] {
            let serial = TarEditTestSupport.decodeOutcome(try Bzip2Decompressor(source: DataByteSource(bytes), offset: 0,
                                                                              compressedSize: UInt64(bytes.count), concatenatedStreams: true))
            let diagnostics = ParallelBzip2Decompressor.Diagnostics()
            let actual = TarEditTestSupport.decodeOutcome(try ParallelBzip2Decompressor(source: DataByteSource(bytes), workers: 2,
                                                                                       diagnostics: diagnostics))
            XCTAssertNotNil(serial.error)
            XCTAssertEqual(actual.error, serial.error)
            XCTAssertTrue(serial.bytes.starts(with: actual.bytes) || actual.bytes.starts(with: serial.bytes))
            XCTAssertGreaterThanOrEqual(actual.bytes.count, 8_000_000)
            XCTAssertEqual(Data(actual.bytes.prefix(8_000_000)), Data(corpus.image.prefix(8_000_000)))
            XCTAssertEqual(diagnostics.fallbackCount, 1)
            XCTAssertGreaterThanOrEqual(diagnostics.decodedRunCount, 1)
        }
    }

    func testBitMagicAlignmentOverlapAndReframing() throws {
        // 1 MiB の窓境界を全ての bit 整列と byte 分割でまたがせる。
        let windowSize = 1_048_576
        for alignment in 0..<8 {
            for split in 1...6 {
                let bit = UInt64((windowSize - split) * 8 + alignment)
                var bytes = [UInt8](repeating: 0, count: windowSize + 16)
                for (index, byte) in Bzip2StreamLayout.blockMagic.enumerated() {
                    let offset = Int(bit / 8) + index
                    bytes[offset] |= byte >> alignment
                    if alignment != 0 { bytes[offset + 1] |= byte << (8 - alignment) }
                }
                let found = bytes.withUnsafeBytes { raw in
                    let first = Bzip2StreamLayout.blockMagicPositions(in: UnsafeRawBufferPointer(rebasing: raw[..<windowSize]), baseBit: 0)
                    let second = Bzip2StreamLayout.blockMagicPositions(in: UnsafeRawBufferPointer(rebasing: raw[(windowSize - 9)...]),
                                                                     baseBit: UInt64((windowSize - 9) * 8))
                    return Set(first + second)
                }
                XCTAssertEqual(found, [bit])
            }
        }
        let corpus = try Self.corpus.get(), packed = try XCTUnwrap(corpus.packed[9])
        let positions = packed.withUnsafeBytes { Bzip2StreamLayout.blockMagicPositions(in: $0, baseBit: 0) }
        let eos = try XCTUnwrap(packed.withUnsafeBytes { Bzip2StreamLayout.endMagicPositions(in: $0, baseBit: 0).last })
        var output: [UInt8] = []
        for (index, first) in positions.enumerated() {
            let end = index + 1 < positions.count ? positions[index + 1] : eos
            let framed = packed.withUnsafeBytes { raw in
                Bzip2StreamLayout.reframe(stream: 9, bits: raw, firstBit: first, bitCount: end - first,
                    blockCRCs: [Bzip2StreamLayout.crc(in: raw, atBit: first + Bzip2StreamLayout.magicBitCount)])
            }
            output.append(contentsOf: try drain(Bzip2Decompressor(source: DataByteSource(Data(framed)), offset: 0,
                                                                  compressedSize: UInt64(framed.count)), bufferSize: 65_536))
        }
        XCTAssertEqual(Data(output), corpus.image)
    }

    func testBlockCandidatesAcrossReadWindows() throws {
        let corpus = try Self.corpus.get(), packed = try XCTUnwrap(corpus.packed[9])
        let positions = packed.withUnsafeBytes { Bzip2StreamLayout.blockMagicPositions(in: $0, baseBit: 0) }
        let bit = try XCTUnwrap(positions.dropFirst().first { $0 % 8 != 0 })
        for split: UInt64 in [1, 3, 6] {
            let source = CountingByteSource(SplitRead(packed, boundary: bit / 8 + split))
            let diagnostics = ParallelBzip2Decompressor.Diagnostics()
            XCTAssertEqual(try drain(ParallelBzip2Decompressor(source: source, workers: 2, diagnostics: diagnostics),
                                     bufferSize: 65_536), corpus.image)
            XCTAssertEqual(source.bytesRead, source.length)
            XCTAssertEqual(diagnostics.fallbackCount, 0)
        }
    }

    func testStreamsErrorsAndFalseCandidatesMatchSerial() throws {
        let body = Data((0..<180_000).map { UInt8(truncatingIfNeeded: $0 * 37) })
        for level in [1, 9] {
            let multiple = try CompressedTarFramingTestSupport.bzip2(body, level: level, chunkSize: 65_536).data
            let empty = try CompressedTarFramingTestSupport.bzip2(Data(), level: level).data
            let one = try CompressedTarFramingTestSupport.bzip2(body, level: level).data
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
        for (compressedLimit, outputLimit, fallbacks) in [(1024, 16 * 1_048_576, 0), (8 * 1_048_576, 1_048_576, 0),
                                                         (32, 16 * 1_048_576, 1), (8 * 1_048_576, 1, 1)] {
            let counters = ParallelBzip2Decompressor.Diagnostics()
            let actual = try drain(ParallelBzip2Decompressor(source: DataByteSource(bytes), workers: 2,
                                                             maximumCompressedSize: compressedLimit, maximumOutputSize: outputLimit, diagnostics: counters), bufferSize: 65_536)
            XCTAssertEqual(actual, output); XCTAssertEqual(counters.fallbackCount, fallbacks)
        }
        let large = Data(repeating: 65, count: 16 * 1_048_576 + 1)
        let packed = try CompressedTarFramingTestSupport.bzip2(large, chunkSize: large.count).data
        let counters = ParallelBzip2Decompressor.Diagnostics()
        XCTAssertEqual(try drain(ParallelBzip2Decompressor(source: DataByteSource(packed), workers: 2, diagnostics: counters), bufferSize: 65_536), large)
        XCTAssertEqual(counters.fallbackCount, 1)
    }

    func testHeaderCandidateAcrossScanWindows() throws {
        let part = try CompressedTarFramingTestSupport.bzip2(Data(repeating: 65, count: 65_536), level: 1).data
        // 短い source read で 10 byte の候補をあらゆる位置で窓にまたがせる。
        for stride in 1...13 {
            let bytes = part + part + part
            let source = ShortReads(bytes, stride: stride)
            XCTAssertEqual(try drain(ParallelBzip2Decompressor(source: source, workers: 2), bufferSize: 65_536), Data(repeating: 65, count: 3 * 65_536))
        }
    }

    func testDeinitAbandonsWorkersWithinTwoSeconds() throws {
        let bytes = try XCTUnwrap(Self.corpus.get().packed[1])
        let diagnostics = ParallelBzip2Decompressor.Diagnostics()
        var decoder: ParallelBzip2Decompressor? = try ParallelBzip2Decompressor(source: DataByteSource(bytes), workers: 8, diagnostics: diagnostics)
        var buffer = [UInt8](repeating: 0, count: 1)
        XCTAssertEqual(try buffer.withUnsafeMutableBytes { try decoder!.read(into: $0) }, 1)
        let deadline = Date(timeIntervalSinceNow: 2)
        decoder = nil
        while diagnostics.liveWorkers > 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertEqual(diagnostics.liveWorkers, 0)
        XCTAssertLessThan(Date(), deadline)
    }

    func testCancellationAbandonsWorkers() async throws {
        let bytes = try XCTUnwrap(Self.corpus.get().packed[1])
        let diagnostics = ParallelBzip2Decompressor.Diagnostics()
        let task = Task.detached {
            let decoder = try ParallelBzip2Decompressor(source: DataByteSource(bytes), workers: 8, diagnostics: diagnostics)
            let stream = try EntryStream(decompressor: decoder, length: nil, expectedCRC32: nil, entryIndex: 0, limits: ReadLimits())
            return try SingleFileMaterializer.materialize(stream, limits: ReadLimits()).length
        }
        let startedDeadline = Date(timeIntervalSinceNow: 2)
        while diagnostics.liveWorkers == 0 && Date() < startedDeadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertGreaterThan(diagnostics.liveWorkers, 0)
        let deadline = Date(timeIntervalSinceNow: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        while diagnostics.liveWorkers > 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(diagnostics.liveWorkers, 0)
        XCTAssertLessThan(Date(), deadline)
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

    private final class SplitRead: ByteSource {
        let source: DataByteSource
        let boundary: UInt64
        init(_ bytes: Data, boundary: UInt64) { source = DataByteSource(bytes); self.boundary = boundary }
        var length: UInt64 { source.length }
        func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
            let size = offset < boundary ? min(buffer.count, Int(boundary - offset)) : buffer.count
            return try source.read(into: UnsafeMutableRawBufferPointer(rebasing: buffer.prefix(size)), at: offset)
        }
    }
}
