import Foundation
import XCTest
@testable import KaitoKit

final class SevenZipInputLatencyTests: XCTestCase {
    typealias RecordingSource = SevenZipLZMA2ResetIndexTests.RecordingSource
    typealias RawSource = SevenZipLZMA2ResetIndexTests.RawSource
    private func read(_ coordinator: SevenZipFolderCoordinator, offset: UInt64, length: Int) throws -> Data {
        let decoder = try coordinator.stream(offset: offset, length: UInt64(length))
        return try EntryStream(decompressor: decoder, length: UInt64(length), expectedCRC32: nil,
            entryIndex: 0, limits: ReadLimits()).readAll()
    }
    private func scans(_ source: RecordingSource, offset: UInt64 = 1) -> Int {
        source.reads.filter { $0.count == 1 && $0.offset == offset }.count
    }
    func testHighSingleWorkerUsesObservedIndexWithoutScanningInBothOrders() throws {
        var fixture = SevenZipParallelTestSupport.raw(); fixture.folderCRC = nil
        for order in [[3, 1, 0, 2], [0, 3, 2, 1]] {
            let source = RecordingSource(DataByteSource(fixture.packed)), cache = SevenZipLZMA2ResetIndexCache()
            let factory = try fixture.factory(workers: 1, source: source, avoidsHeaderScans: true, resetIndexCache: cache)
            let coordinator = SevenZipFolderCoordinator(factory: factory)
            var previous = -1
            for index in order {
                let offset = UInt64(fixture.payloads.prefix(index).reduce(0) { $0 + $1.count })
                XCTAssertEqual(try read(coordinator, offset: offset, length: fixture.payloads[index].count), fixture.payloads[index])
                if index < previous, index > 0 {
                    XCTAssertEqual(coordinator.lastBackwardRestart, .observed)
                    XCTAssertEqual(try factory.backwardRestartPoint(atOrBefore: offset)?.uncompressedOffset, offset)
                }
                previous = index
            }
            XCTAssertEqual(scans(source), 0)
            XCTAssertNil(cache.index)
        }
    }
    func testLowKeepsParallelScanButSerialUsesObservations() throws {
        var fixture = SevenZipParallelTestSupport.raw(); fixture.folderCRC = nil
        for workers in [1, 16] {
            let source = RecordingSource(DataByteSource(fixture.packed))
            let coordinator = SevenZipFolderCoordinator(factory: try fixture.factory(workers: workers, source: source))
            for index in [3, 1] {
                let offset = UInt64(fixture.payloads.prefix(index).reduce(0) { $0 + $1.count })
                XCTAssertEqual(try read(coordinator, offset: offset, length: fixture.payloads[index].count), fixture.payloads[index])
            }
            XCTAssertEqual(scans(source), workers == 16 ? 1 : 0)
            XCTAssertEqual(coordinator.lastBackwardRestart, workers == 16 ? .fullIndex : .observed)
        }
    }
    func testCachedNilUsesLateObservedResetWithoutRescanning() throws {
        let raw = RawSource(chunks: 1250, resetChunks: [0, 1100])
        let source = RecordingSource(raw), cache = SevenZipLZMA2ResetIndexCache()
        let coder = SevenZipCoder(methodID: [0x21], inputCount: 1, outputCount: 1, properties: [8], firstInput: 0, firstOutput: 0)
        let folder = SevenZipFolder(coders: [coder], bindPairs: [], packedIndices: [0], inputCount: 1,
            outputCount: 1, finalOutputIndex: 0, unpackSizes: [raw.outputSize], digest: SevenZipDigest(value: nil))
        let factory = try SevenZipFolderDecoderFactory(source: source, folder: folder,
            packedRanges: [0: SevenZipPackRange(offset: 0, size: raw.length, digest: SevenZipDigest(value: nil))],
            limits: ReadLimits(parallelDecodeMemory: 1 << 30), password: nil, keyCache: SevenZipAESKeyCache(),
            maximumAESCyclesPower: 24, workers: 16, resetIndexCache: cache)
        XCTAssertNil(try factory.parallelUnits())
        XCTAssertEqual(source.reads.count, 1025 * 3)
        let coordinator = SevenZipFolderCoordinator(factory: factory)
        _ = try read(coordinator, offset: 1200 * 65536, length: 1)
        _ = try read(coordinator, offset: 1150 * 65536, length: 1)
        XCTAssertEqual(coordinator.lastBackwardRestart, .observed)
        XCTAssertEqual(try factory.backwardRestartPoint(atOrBefore: 1150 * 65536)?.uncompressedOffset, 1100 * 65536)
        XCTAssertEqual(source.reads.filter { $0.count == 1 && $0.offset % RawSource.chunkSize == 1 }.count, 1025)
    }
    func testCachedScanFailureDoesNotBreakObservedBackwardRead() throws {
        var fixture = SevenZipParallelTestSupport.raw(); fixture.folderCRC = nil
        let bad = fixture.payloads.prefix(3).reduce(0) { $0 + SevenZipParallelTestSupport.rawUnit($1).count }
        fixture.packed[bad] = 3
        var errors: [KaitoError] = []
        for workers in [1, 16] {
            let coordinator = SevenZipFolderCoordinator(factory: try fixture.factory(workers: workers))
            for index in [2, 1] {
                let offset = UInt64(fixture.payloads.prefix(index).reduce(0) { $0 + $1.count })
                XCTAssertEqual(try read(coordinator, offset: offset, length: fixture.payloads[index].count), fixture.payloads[index])
            }
            XCTAssertEqual(coordinator.lastBackwardRestart, .observed)
            let offset = UInt64(fixture.payloads.prefix(3).reduce(0) { $0 + $1.count })
            XCTAssertThrowsError(try read(coordinator, offset: offset, length: fixture.payloads[3].count)) {
                if let error = $0 as? KaitoError { errors.append(error) }
            }
        }
        XCTAssertEqual(errors.count, 2); XCTAssertEqual(errors.first, errors.last)
    }
    func testFolderCRCRestartsAtHeadWithoutBackwardScanAndStillVerifies() throws {
        for high in [false, true] {
            for corrupt in [false, true] {
                var fixture = SevenZipParallelTestSupport.raw()
                if corrupt { fixture.folderCRC = fixture.folderCRC! ^ 1 }
                let source = RecordingSource(DataByteSource(fixture.packed))
                let coordinator = SevenZipFolderCoordinator(factory: try fixture.factory(workers: 16, source: source, avoidsHeaderScans: high))
                _ = try read(coordinator, offset: UInt64(fixture.payloads[0].count + 1), length: 1)
                source.reset()
                _ = try read(coordinator, offset: 0, length: 1)
                XCTAssertEqual(coordinator.lastBackwardRestart, .head)
                XCTAssertEqual(scans(source), 0)
                if corrupt {
                    XCTAssertThrowsError(try read(coordinator, offset: 1, length: fixture.output.count - 1)) {
                        XCTAssertEqual($0 as? KaitoError, .checksumMismatch(entry: -1))
                    }
                } else { XCTAssertEqual(try read(coordinator, offset: 1, length: fixture.output.count - 1), fixture.output.dropFirst()) }
                XCTAssertEqual(scans(source), high ? 1 : 0)
            }
        }
    }
    func testFiltersHaveNoObserverAndNoScansAtHighLatency() throws {
        let sizes = [65003, 70005, 80008], count = sizes.reduce(0, +)
        for arm64 in [false, true] {
            var original = Data(repeating: arm64 ? 0 : 0x90, count: count), encoded = original
            for offset in stride(from: 0, to: count - 8, by: 8) {
                if arm64 {
                    original.replaceSubrange(offset..<offset + 4, with: SevenZipEditTestBytes.little(UInt32(0x94000000)))
                    encoded.replaceSubrange(offset..<offset + 4, with: SevenZipEditTestBytes.little(UInt32(0x94000000) | UInt32(offset / 4)))
                } else {
                    original.replaceSubrange(offset..<offset + 5, with: [0xe8, 0, 0, 0, 0])
                    encoded.replaceSubrange(offset..<offset + 5, with: [0xe8] + SevenZipEditTestBytes.little(UInt32(offset + 5)))
                }
            }
            var packed = Data(), payloads: [Data] = [], offset = 0
            for size in sizes {
                packed.append(SevenZipParallelTestSupport.rawUnit(Data(encoded[offset..<offset + size])))
                payloads.append(Data(original[offset..<offset + size])); offset += size
            }
            packed.append(0)
            let fixture = SevenZipParallelTestSupport.Fixture(packed: packed, payloads: payloads, filters: [([arm64 ? 0x0a : 0x04], [])])
            let source = RecordingSource(DataByteSource(packed)), cache = SevenZipLZMA2ResetIndexCache()
            let coordinator = SevenZipFolderCoordinator(factory: try fixture.factory(workers: 16, source: source, avoidsHeaderScans: true, resetIndexCache: cache))
            for index in [2, 1, 0] {
                let offset = UInt64(sizes.prefix(index).reduce(0, +))
                XCTAssertEqual(try read(coordinator, offset: offset, length: sizes[index]), payloads[index])
            }
            XCTAssertEqual(cache.observedCoverage, 0); XCTAssertEqual(scans(source), 0)
        }
    }
    func testFrozenObservationFallsBackToHeadInBothModes() throws {
        var fixture = SevenZipParallelTestSupport.raw(); fixture.folderCRC = nil
        var limits = ReadLimits(); limits.maxMetadataRecordCount = 2
        for high in [false, true] {
            let source = RecordingSource(DataByteSource(fixture.packed)), cache = SevenZipLZMA2ResetIndexCache()
            let coordinator = SevenZipFolderCoordinator(factory: try fixture.factory(workers: 1, limits: limits,
                source: source, avoidsHeaderScans: high, resetIndexCache: cache))
            _ = try read(coordinator, offset: UInt64(fixture.output.count - 1), length: 1)
            let offset = UInt64(fixture.payloads.prefix(2).reduce(0) { $0 + $1.count })
            _ = try read(coordinator, offset: offset, length: 1)
            XCTAssertTrue(cache.observationFrozen); XCTAssertEqual(coordinator.lastBackwardRestart, .head)
            XCTAssertEqual(scans(source), high ? 0 : 1)
        }
    }
    func testEncryptedLZMA2AtHighLatencyMatchesLow() throws {
        try SevenZipTestSupport.requireSevenZip()
        let directory = try SevenZipTestSupport.temporaryDirectory()
        let archive = directory.appendingPathComponent("encrypted.7z")
        let payload = Data(repeating: 42, count: 100000)
        try SevenZipTestSupport.write(payload, relativePath: "a.bin", below: directory)
        try SevenZipTestSupport.makeArchive(sourceDirectory: directory, paths: ["a.bin"], archiveURL: archive,
            options: ["-psecret", "-m0=LZMA2"])
        for latency in [InputLatency.low, .high] {
            var options = ReaderOptions(password: "secret", decodeThreads: 16); options.inputLatency = latency
            let reader = try ArchiveReader.open(url: archive, options: options)
            XCTAssertEqual(try reader.read(reader.entries[0]), payload)
        }
    }
    func testConcatenatedHintedArchiveMatchesSevenZipInRandomOrderWithDeferredScan() throws {
        try SevenZipTestSupport.requireSevenZip()
        let directory = try SevenZipTestSupport.temporaryDirectory(), archive = directory.appendingPathComponent("multi.7z")
        let names = (0..<6).map { "entry-\($0).bin" }
        for (index, name) in names.enumerated() {
            try SevenZipTestSupport.write(Data((0..<300000).map { UInt8(truncatingIfNeeded: $0 &* 31 + index) }), relativePath: name, below: directory)
        }
        try SevenZipTestSupport.makeArchive(sourceDirectory: directory, paths: names, archiveURL: archive,
            options: ["-mmt=4", "-m0=LZMA2:d=64k:c=256k", "-ms=on"])
        let bytes = try Data(contentsOf: archive)
        let hinted = CallCountingByteSource(DataByteSource(bytes), reportsNonLocalVolume: true)
        let source = RecordingSource(hinted)
        // 記録 source の外側にもヒントを残して最上位入力で解決する。
        let top = CallCountingByteSource(source, reportsNonLocalVolume: true)
        let joined = try ConcatenatedByteSource(segments: [SourceSegment(source: top, offset: 0, length: top.length)], maximumLength: top.length, label: "test")
        let reader = try ArchiveReader.open(source: joined, options: ReaderOptions(decodeThreads: 16))
        source.reset()
        var generator: UInt64 = 901
        var order = Array(reader.entries.indices)
        for index in stride(from: order.count - 1, through: 1, by: -1) {
            generator = generator &* 6364136223846793005 &+ 1
            order.swapAt(index, Int(generator % UInt64(index + 1)))
        }
        for (step, index) in (order + order.reversed()).enumerated() {
            let entry = reader.entries[index]
            let expected = try SevenZipTestSupport.checkedRun(arguments: ["e", "-so", "-bd", "-bb0", "-y", archive.path, entry.name]).standardOutput
            XCTAssertEqual(try reader.read(entry), expected)
            if step == 0 { XCTAssertEqual(scans(source, offset: 33), 0) }
        }
        XCTAssertEqual(scans(source, offset: 33), 1)
    }
    func testSeededRandomReadsAndMutationsMatchSerialReference() throws {
        var seed: UInt64 = 7401
        func next(_ bound: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int(seed % UInt64(bound)) }
        for _ in 0..<16 {
            var fixture = SevenZipParallelTestSupport.raw(sizes: (0..<4).map { _ in 100 + next(10000) }); fixture.folderCRC = nil
            for mutation in 0..<3 {
                var candidate = fixture
                if mutation > 0 {
                    let index = next(4), offset = fixture.payloads.prefix(index).reduce(0) { $0 + SevenZipParallelTestSupport.rawUnit($1).count }
                    candidate.packed[offset + (mutation == 1 ? 0 : 1)] = mutation == 1 ? 3 : 0xff
                }
                let order = (0..<12).map { _ in next(4) }
                var reference: [Result<Data, KaitoError>] = []
                let serial = SevenZipFolderCoordinator(factory: try candidate.factory(workers: 1))
                for index in 0..<4 {
                    let offset = UInt64(candidate.payloads.prefix(index).reduce(0) { $0 + $1.count })
                    do { reference.append(.success(try read(serial, offset: offset, length: candidate.payloads[index].count))) }
                    catch let error as KaitoError { reference.append(.failure(error)); break }
                }
                for high in [false, true] {
                    let coordinator = SevenZipFolderCoordinator(factory: try candidate.factory(workers: 16, avoidsHeaderScans: high))
                    for index in order {
                        let offset = UInt64(candidate.payloads.prefix(index).reduce(0) { $0 + $1.count })
                        let outcome: Result<Data, KaitoError>
                        do { outcome = .success(try read(coordinator, offset: offset, length: candidate.payloads[index].count)) }
                        catch let error as KaitoError { outcome = .failure(error) }
                        let expected = reference[min(index, reference.count - 1)]
                        XCTAssertEqual(outcome, expected)
                        if case .failure = outcome { break }
                    }
                }
            }
        }
    }
}
