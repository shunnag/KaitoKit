import Foundation
import Synchronization
@testable import KaitoKit
import XCTest

final class ContainerParallelCodecTests: XCTestCase {
    private struct Corpus: Sendable {
        let archives: [Data]
        let payloads: [String: Data]
        let bzip2: Data
    }

    private static let corpus = Result<Corpus, Error> {
        try SevenZipTestSupport.requireSevenZip()
        let directory = try SevenZipTestSupport.temporaryDirectory(label: "container-parallel-codecs")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pattern = (0..<16_384).map { UInt8(truncatingIfNeeded: ($0 &* 31) ^ ($0 >> 3)) }
        let body = Data((0..<(10 * 1_048_576)).map { pattern[$0 % pattern.count] })
        let payloads = ["a.bin": body, "b.bin": Data(body.prefix(1_048_576))]
        for (name, data) in payloads { try SevenZipTestSupport.write(data, relativePath: name, below: directory) }
        var archives: [Data] = []
        for solid in ["off", "on"] {
            for threads in ["off", "on"] {
                let url = directory.appendingPathComponent("bzip2-\(solid)-\(threads).7z")
                try SevenZipTestSupport.makeArchive(sourceDirectory: directory, paths: payloads.keys.sorted(), archiveURL: url,
                    options: ["-m0=BZip2", "-mmt=\(threads)", "-ms=\(solid)", "-mhc=off"])
                archives.append(try Data(contentsOf: url))
            }
        }
        let zip = directory.appendingPathComponent("bzip2.zip")
        try SevenZipTestSupport.checkedRun(arguments: ["a", "-tzip", "-mm=BZip2", "-mmt=off", "-bd", "-bb0", zip.path, "a.bin", "b.bin"], currentDirectory: directory)
        let zipBytes = try Data(contentsOf: zip)
        archives.append(zipBytes)
        let range = try ZipModernFixtures.payloadRange(zipBytes)
        let packed = Data(zipBytes[range])
        XCTAssertGreaterThan(packed.withUnsafeBytes { Bzip2StreamLayout.blockMagicPositions(in: $0, baseBit: 0).count }, 9)
        return Corpus(archives: archives, payloads: payloads, bzip2: packed)
    }

    private func outcome(_ archive: Data, options: ReaderOptions) -> (bytes: Data, error: String?) {
        var output = Data()
        do {
            let reader = try ArchiveReader.open(data: archive, options: options)
            var buffer = [UInt8](repeating: 0, count: 65_537)
            for entry in reader.entries {
                let stream = try reader.stream(entry)
                while true {
                    let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
                    if count == 0 { break }
                    output.append(contentsOf: buffer.prefix(count))
                }
            }
            return (output, nil)
        } catch { return (output, String(describing: error)) }
    }

    func testSevenZipAndZipBzip2BlackBoxFixturesMatchAtAllThreadCounts() throws {
        let corpus = try Self.corpus.get()
        for archive in corpus.archives {
            for workers: Int? in [1, 2, 8, nil] {
                let reader = try ArchiveReader.open(data: archive, options: ReaderOptions(decodeThreads: workers))
                XCTAssertEqual(reader.entries.count, corpus.payloads.count)
                for entry in reader.entries { XCTAssertEqual(try reader.read(entry), corpus.payloads[entry.name]) }
                let reopened = try reader.reopen()
                for entry in reopened.entries.reversed() { XCTAssertEqual(try reopened.read(entry), corpus.payloads[entry.name]) }
            }
        }
    }

    func testBzip2CorruptAndTruncatedPayloadsMatchSerialErrorsAndPrefixes() throws {
        let corpus = try Self.corpus.get()
        for archive in corpus.archives {
            let range: Range<Int>
            if archive.starts(with: [0x50, 0x4b]) { range = try ZipModernFixtures.payloadRange(archive) }
            else { range = 32..<(32 + Int(LittleEndian.uint64(Array(archive.prefix(20)), at: 12))) }
            // Keep the container headers intact; mutate the packed stream, including
            // a late block after the first parallel run has already been emitted.
            var mutations: [Data] = []
            for offset in [range.lowerBound + 20, range.upperBound - 12] {
                var bytes = archive; bytes[offset] ^= 0x40; mutations.append(bytes)
            }
            for removed in [1, 5, min(200, range.count / 3)] {
                var bytes = archive
                bytes.replaceSubrange((range.upperBound - removed)..<range.upperBound, with: repeatElement(UInt8(0), count: removed))
                mutations.append(bytes)
            }
            mutations.append(Data(archive.prefix(range.lowerBound + range.count / 2)))
            for bytes in mutations {
                let serial = outcome(bytes, options: ReaderOptions(decodeThreads: 1))
                for workers in [2, 8] {
                    let actual = outcome(bytes, options: ReaderOptions(decodeThreads: workers))
                    XCTAssertEqual(actual.error, serial.error)
                    if serial.error == nil { XCTAssertEqual(actual.bytes, serial.bytes) }
                    else { XCTAssertTrue(serial.bytes.starts(with: actual.bytes) || actual.bytes.starts(with: serial.bytes)) }
                }
            }
        }
    }

    func testContainerPoliciesAvoidLeafSubmissionsAndScannerReadAmplification() throws {
        let corpus = try Self.corpus.get()
        for archive in [corpus.archives[0], try XCTUnwrap(corpus.archives.last)] {
            let baseline = CountingByteSource(DataByteSource(archive))
            let serial = try ArchiveReader.open(source: baseline, options: ReaderOptions(decodeThreads: 1))
            for entry in serial.entries { _ = try serial.read(entry) }
            for mode in 0..<4 {
                var options = ReaderOptions(decodeThreads: mode == 2 ? nil : 8)
                if mode == 0 { options.inputLatency = .high }
                if mode == 1 { options.limits.parallelDecodeMemory = 1 }
                if mode == 2 { options.decodePowerPolicy = .reduceInLowPowerMode }
                if mode == 3 { options.decodeThreads = 1 }
                let submissions = Mutex(0)
                let source = CountingByteSource(DataByteSource(archive))
                try ReaderOptions.$testingAutomaticThreads.withValue({ policy in
                    XCTAssertEqual(policy, .reduceInLowPowerMode)
                    return 1
                }) {
                    try LeafDecodePool.$testingSubmission.withValue({ submissions.withLock { $0 += 1 } }) {
                        let reader = try ArchiveReader.open(source: source, options: options)
                        for entry in reader.entries { _ = try reader.read(entry) }
                    }
                }
                XCTAssertEqual(submissions.withLock { $0 }, 0)
                XCTAssertEqual(source.bytesRead, baseline.bytesRead)
            }
            let submissions = Mutex(0)
            try LeafDecodePool.$testingSubmission.withValue({ submissions.withLock { $0 += 1 } }) {
                let reader = try ArchiveReader.open(data: archive, options: ReaderOptions(decodeThreads: 8))
                for entry in reader.entries { _ = try reader.read(entry) }
            }
            XCTAssertGreaterThan(submissions.withLock { $0 }, 1)
        }
    }

    func testFirstBzip2StreamAndFilteredSevenZipKeepSerialSemantics() throws {
        let corpus = try Self.corpus.get(), packed = corpus.bzip2
        let source = DataByteSource(Data([1, 2, 3]) + packed + packed + Data([0xff]))
        let range = try BoundedByteSource(source: source, baseOffset: 3, length: UInt64(packed.count * 2 + 1))
        let expected = TarEditTestSupport.decodeOutcome(try Bzip2Decompressor(
            source: range, offset: 0, compressedSize: range.length))
        for budget in [UInt64(1), UInt64(512 * 1_048_576)] {
            var limits = ReadLimits(); limits.parallelDecodeMemory = budget
            let actual = TarEditTestSupport.decodeOutcome(try ParallelBzip2Decompressor(
                source: range, limits: limits, workers: 8, concatenatedStreams: false))
            XCTAssertNil(actual.error); XCTAssertEqual(actual.bytes, expected.bytes)
        }
        for bytes in [Data(packed.dropLast(5)), Data(packed.prefix(packed.count / 2))] {
            let source = DataByteSource(bytes)
            let serial = TarEditTestSupport.decodeOutcome(try Bzip2Decompressor(source: source, offset: 0, compressedSize: source.length))
            let parallel = TarEditTestSupport.decodeOutcome(try ParallelBzip2Decompressor(source: source, workers: 8, concatenatedStreams: false))
            XCTAssertEqual(parallel.error, serial.error)
            XCTAssertTrue(serial.bytes.starts(with: parallel.bytes) || parallel.bytes.starts(with: serial.bytes))
        }
        // BZip2 -> Copy is deliberately outside the simple-folder optimization.
        let folder = SevenZipFolder(coders: [
            SevenZipCoder(methodID: [0x04, 0x02, 0x02], inputCount: 1, outputCount: 1, properties: [], firstInput: 0, firstOutput: 0),
            SevenZipCoder(methodID: [0], inputCount: 1, outputCount: 1, properties: [], firstInput: 1, firstOutput: 1)],
            bindPairs: [SevenZipBindPair(input: 1, output: 0)], packedIndices: [0], inputCount: 2, outputCount: 2,
            finalOutputIndex: 1, unpackSizes: [UInt64(expected.bytes.count), UInt64(expected.bytes.count)], digest: SevenZipDigest(value: nil))
        let factory = try SevenZipFolderDecoderFactory(source: DataByteSource(packed), folder: folder,
            packedRanges: [0: SevenZipPackRange(offset: 0, size: UInt64(packed.count), digest: SevenZipDigest(value: nil))],
            limits: ReadLimits(), password: nil, keyCache: SevenZipAESKeyCache(), maximumAESCyclesPower: 24, workers: 8)
        let submissions = Mutex(0)
        try LeafDecodePool.$testingSubmission.withValue({ submissions.withLock { $0 += 1 } }) {
            XCTAssertEqual(try factory.decodeAll(limit: 64 * 1_048_576), expected.bytes)
        }
        XCTAssertEqual(submissions.withLock { $0 }, 0)
    }

    private func rawZstd(_ body: Data) -> Data {
        // RFC 8878 single-segment frame with a one-byte content size and raw block.
        precondition(body.count < 256)
        let block = body.count << 3 | 1
        return Data([0x28, 0xb5, 0x2f, 0xfd, 0x20, UInt8(body.count),
                     UInt8(truncatingIfNeeded: block), UInt8(truncatingIfNeeded: block >> 8), 0]) + body
    }

    func testZipXZAndConcatenatedZstdUseBoundedParallelDecoders() throws {
        let directory = try SevenZipTestSupport.temporaryDirectory(label: "zip-parallel-modern")
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = Data(repeating: 0x61, count: 36 * 1_048_576)
        let input = try SevenZipTestSupport.write(body, relativePath: "input", below: directory)
        try ZipTestSupport.requireExecutable(ZipTestSupport.xzPath, reason: "xz is unavailable")
        try ZipTestSupport.checkedRun(ZipTestSupport.xzPath, arguments: ["-k", "-T2", "--block-size=4MiB", input.path])
        let xz = try Data(contentsOf: input.appendingPathExtension("xz"))
        // Small independent raw zstd frames exercise frame parallelism without
        // depending on a writer's choice to produce one frame for the whole file.
        let half = Data("parallel ZIP zstd payload".utf8)
        let zstd = rawZstd(half) + rawZstd(half)
        for (method, packed, plain) in [(UInt16(95), xz, body), (93, zstd, half + half), (20, zstd, half + half)] {
            let archive = try ZipTestSupport.makeArchive(entries: [HandZipEntry(name: "first", uncompressedData: plain, compressedData: packed, method: method),
                                                              HandZipEntry(name: "next", uncompressedData: Data([9, 8, 7]))])
            let serial = outcome(archive, options: ReaderOptions(decodeThreads: 1))
            let submissions = Mutex(0)
            LeafDecodePool.$testingSubmission.withValue({ submissions.withLock { $0 += 1 } }) {
                let actual = outcome(archive, options: ReaderOptions(decodeThreads: 8))
                XCTAssertNil(actual.error); XCTAssertEqual(actual.bytes, serial.bytes)
            }
            XCTAssertGreaterThan(submissions.withLock { $0 }, 1)
            for offset in [packed.count / 2, packed.count - 5] {
                var damaged = packed; damaged[offset] ^= 4
                let changed = try ZipTestSupport.makeArchive(entries: [HandZipEntry(name: "first", uncompressedData: plain, compressedData: damaged, method: method)])
                let expected = outcome(changed, options: ReaderOptions(decodeThreads: 1))
                let actual = outcome(changed, options: ReaderOptions(decodeThreads: 8))
                XCTAssertEqual(actual.error, expected.error)
                XCTAssertTrue(expected.bytes.starts(with: actual.bytes) || actual.bytes.starts(with: expected.bytes))
            }
        }
    }

    func testCancelledContainerStreamsPropagateCancellation() async throws {
        let corpus = try Self.corpus.get()
        for bytes in [corpus.archives[0], try XCTUnwrap(corpus.archives.last)] {
            let cancelled = await Task.detached {
                withUnsafeCurrentTask { $0?.cancel() }
                do {
                    let reader = try ArchiveReader.open(data: bytes, options: ReaderOptions(decodeThreads: 8))
                    _ = try reader.read(reader.entries[0])
                    return false
                } catch { return error is CancellationError }
            }.value
            XCTAssertTrue(cancelled)
        }
    }
}
