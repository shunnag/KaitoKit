import Foundation
import Synchronization
@_spi(ZipRawLayout) @testable import KaitoKit
import XCTest

final class ZipLocalReadAheadTests: XCTestCase {
    func testEveryFrozenInputAndModeWithBothPolicies() throws {
        for input in try ZipGoldenCorpus.inputs() {
            let parts = try input.files.map { try ZipGoldenCorpus.decoded($0) }
            let source: any ByteSource
            if parts.count > 1 {
                source = try ConcatenatedByteSource(segments: parts.map {
                    SourceSegment(source: DataByteSource($0), offset: 0, length: UInt64($0.count))
                }, maximumLength: .max, label: "golden")
            } else { source = DataByteSource(parts[0]) }
            let layout = input.id == "split-native" ? try ZipDiskLayout(lengths: parts.map { UInt64($0.count) }) : nil
            for mode in ZipGoldenCorpus.modes {
                var options = mode.options
                options.password = "raw-password"
                for reverse in [false, true] {
                    XCTAssertEqual(
                        ZipDifferentialSnapshot(source: source, options: options, policy: .standard, diskLayout: layout, reverse: reverse),
                        ZipDifferentialSnapshot(source: source, options: options, policy: .disabled, diskLayout: layout, reverse: reverse),
                        "\(input.id) \(mode.name) reverse=\(reverse)")
                }
            }
        }
    }

    func testSmallRecordsUseBoundedForwardWindowsForRawAndEagerOpen() throws {
        for id in ["small-ut", "small-dd"] {
            let bytes = try fixture(id)
            let layout = try ZipTestSupport.layout(of: bytes)
            let bound = UInt64(layout.centralDirectoryOffset)
            for eager in [false, true] {
                let source = ZipWindowTestSource(DataByteSource(bytes))
                let options = ReaderOptions(lazyLocalHeaders: !eager, appleDoublePolicy: .expose)
                let reader = try ZipReader(source: source, options: options)
                let reads: [Range<UInt64>]
                if eager {
                    let lazySource = ZipWindowTestSource(DataByteSource(bytes))
                    _ = try ZipReader(source: lazySource, options: ReaderOptions())
                    reads = Array(source.reads.dropFirst(lazySource.reads.count))
                } else {
                    source.reset()
                    for index in reader.entries.indices { XCTAssertNotNil(try reader.zipRawRecordLayout(at: index, limits: options.limits)) }
                    reads = source.reads
                }
                XCTAssertLessThanOrEqual(reads.count, (Int(bound) + 32767) / 32768 + 8)
                XCTAssertLessThanOrEqual(reads.reduce(0) { $0 + $1.count }, Int(bound))
                assertWindows(reads, lower: 0, bound: bound)
                print("ZIP-WINDOW \(id) eager=\(eager) reads=\(reads.count) bytes=\(reads.reduce(0) { $0 + $1.count }) local=\(bound)")
            }
        }
    }

    func testLargeRecordsAndSmallMetadataLimitPreserveExactReadSequence() throws {
        let bytes = try ZipTestSupport.makeArchive(entries: (0..<2).map {
            HandZipEntry(name: "large-\($0)", uncompressedData: Data(repeating: 0x78, count: 4 * 1024 * 1024))
        })
        try assertExactReads(bytes, limits: ReadLimits())
        let small = try ZipTestSupport.makeArchive(entries: (0..<600).map {
            HandZipEntry(name: "long-component-keeps-record-above-sixty-four-bytes-\($0)", uncompressedData: Data([0x78]))
        })
        try assertExactReads(small, limits: ReadLimits(maxMetadataSize: 64))
    }

    func testReorderedHeadersSFXGapsAndRandomStreams() throws {
        for id in ["reverse", "shuffled", "sfx-false", "sfx-true", "gap-100", "gap-8192"] {
            let bytes = try fixture(id)
            let layout = try ZipTestSupport.layout(of: bytes)
            let lower = UInt64(try XCTUnwrap(layout.localHeaderOffsets.min()))
            let bound = UInt64(layout.centralDirectoryOffset)
            var traces: [[Range<UInt64>]] = []
            for policy in [ZipLocalReadAheadPolicy.disabled, .standard] {
                let source = ZipWindowTestSource(DataByteSource(bytes))
                let reader = try ZipReader(source: source, options: ReaderOptions(), readAhead: policy)
                source.reset()
                for index in reader.entries.indices { _ = try reader.zipRawRecordLayout(at: index, limits: ReadLimits()) }
                traces.append(source.reads)
                assertWindows(source.reads, lower: lower, bound: bound)
                var random = ZipDeterministicRandom(state: 0x50314b)
                var indices = Array(reader.entries.indices)
                for i in indices.indices.reversed() { indices.swapAt(i, random.next(i + 1)) }
                let randomReader = try ZipReader(source: DataByteSource(bytes), options: ReaderOptions(), readAhead: policy)
                let oracle = try ZipReader(source: DataByteSource(bytes), options: ReaderOptions(), readAhead: .disabled)
                for index in indices {
                    XCTAssertEqual(try randomReader.stream(for: randomReader.entries[index], limits: ReadLimits()).readAll(),
                                   try oracle.stream(for: oracle.entries[index], limits: ReadLimits()).readAll(), id)
                }
            }
            XCTAssertLessThanOrEqual(traces[1].reduce(0) { $0 + $1.count },
                                    Int(bound - lower) + traces[0].reduce(0) { $0 + $1.count }, id)
            if id == "gap-100" { XCTAssertEqual(traces[1].count, 1) }
            if id == "gap-8192" { XCTAssertEqual(traces[1].first?.count, 30); XCTAssertEqual(traces[1].count, 2) }
        }
    }

    func testSpeculativeFailuresFallBackAndShortReadsRepeat() throws {
        let bytes = try fixture("small-ut")
        let layout = try ZipTestSupport.layout(of: bytes)
        let failureRange = UInt64(layout.localHeaderOffsets[10])..<UInt64(layout.localHeaderOffsets[10] + 30)
        for fault in [ZipWindowTestSource.Fault.throwLarge, .zeroLarge, .overReturnLarge, .throwRange(failureRange), .short] {
            var outcomes: [[ZipLayoutOutcome]] = []
            var publicOutcomes: [[ZipTestOutcome<ZipRawSnapshot?>]] = []
            var streamOutcomes: [[ZipTestOutcome<Data>]] = []
            for policy in [ZipLocalReadAheadPolicy.disabled, .standard] {
                let source = ZipWindowTestSource(DataByteSource(bytes))
                let reader = try ZipReader(source: source, options: ReaderOptions(), readAhead: policy)
                source.reset(fault: fault)
                outcomes.append(reader.entries.indices.map { index in
                    ZipLayoutOutcome { try reader.zipRawRecordLayout(at: index, limits: ReadLimits()) }
                })
                assertWindows(source.reads, lower: 0, bound: UInt64(layout.centralDirectoryOffset))
                let publicSource = ZipWindowTestSource(DataByteSource(bytes))
                let publicReader = try ZipReader(source: publicSource, options: ReaderOptions(), readAhead: policy)
                XCTAssertEqual(publicReader.entries, reader.entries)
                publicSource.reset(fault: fault)
                publicOutcomes.append(publicReader.entries.map { entry in
                    ZipTestOutcome { try publicReader.rawRecord(for: entry, limits: ReadLimits()).map(ZipRawSnapshot.init) }
                })
                assertWindows(publicSource.reads, lower: 0, bound: UInt64(layout.centralDirectoryOffset))
                let streamSource = ZipWindowTestSource(DataByteSource(bytes))
                let streamReader = try ZipReader(source: streamSource, options: ReaderOptions(), readAhead: policy)
                streamSource.reset(fault: fault)
                streamOutcomes.append(streamReader.entries.map { entry in
                    ZipTestOutcome { try streamReader.stream(for: entry, limits: ReadLimits()).readAll() }
                })
                assertWindows(streamSource.reads, lower: 0, bound: UInt64(layout.centralDirectoryOffset))
            }
            XCTAssertEqual(outcomes[0], outcomes[1], "\(fault)")
            XCTAssertEqual(publicOutcomes[0], publicOutcomes[1], "\(fault)")
            XCTAssertEqual(streamOutcomes[0], streamOutcomes[1], "\(fault)")
        }
    }

    func testReopenStartsEmptyPreservesPolicyAndCapsEachFill() throws {
        let bytes = try fixture("small-ut")
        let bound = UInt64(try ZipTestSupport.layout(of: bytes).centralDirectoryOffset)
        let limits = ReadLimits(maxMetadataSize: 160)
        for policy in [ZipLocalReadAheadPolicy.disabled, .standard] {
            let source = ZipWindowTestSource(DataByteSource(bytes))
            let options = ReaderOptions(limits: limits)
            let reader = try ZipReader(source: source, options: options, readAhead: policy)
            source.reset()
            for index in reader.entries.indices { _ = try reader.zipRawRecordLayout(at: index, limits: limits) }
            let first = source.reads
            assertWindows(first, lower: 0, bound: bound, maximum: 160)
            source.reset()
            let reopened = reader.reopened(options: options)
            XCTAssertTrue(source.reads.isEmpty)
            for index in reopened.entries.indices { _ = try reopened.zipRawRecordLayout(at: index, limits: limits) }
            XCTAssertEqual(source.reads, first)
            source.reset()
            _ = try reader.zipRawRecordLayout(at: reader.entries.count - 1, limits: limits)
            XCTAssertTrue(source.reads.isEmpty)
        }
    }

    func testOffsetsBeyondFourGiBWithLocalOnlyAndCentralOnlyZIP64() throws {
        let shift: UInt64 = (1 << 32) + 12345
        for local in [false, true] {
            let bytes = try ZipTestSupport.makeArchive(entries: [RawRecordArchiveBuilder.descriptorEntry(
                signed: true, zip64: true, localZIP64: local, centralZIP64: !local)])
            let layout = try ZipTestSupport.layout(of: bytes)
            let source = ZipSparseTestSource(length: shift + UInt64(bytes.count), segments: [(shift, bytes)])
            let options = ReaderOptions()
            XCTAssertEqual(ZipDifferentialSnapshot(source: source, options: options, policy: .standard),
                           ZipDifferentialSnapshot(source: source, options: options, policy: .disabled))
            let counting = ZipWindowTestSource(source)
            let reader = try ZipReader(source: counting, options: options)
            counting.reset()
            let raw = try XCTUnwrap(reader.zipRawRecordLayout(at: 0, limits: options.limits))
            XCTAssertEqual(raw.recordRange.lowerBound, shift)
            XCTAssertEqual(raw.localHasZIP64Extra, local)
            XCTAssertEqual(raw.centralHasZIP64Extra, !local)
            assertWindows(counting.reads, lower: shift, bound: shift + UInt64(layout.centralDirectoryOffset))
        }
    }

    func testAmbiguousDescriptorHasSameFailure() throws {
        let signature: UInt32 = 0x08074b50
        let entry = HandZipEntry(name: "ambiguous", centralCRC32: signature,
            centralCompressedSize: signature, centralUncompressedSize: signature, hasDataDescriptor: true)
        let bytes = try ZipTestSupport.makeArchive(entries: [entry])
        let layout = try ZipTestSupport.layout(of: bytes)
        let payloadStart = layout.centralDirectoryOffset - 16
        let payloadEnd = UInt64(payloadStart) + UInt64(signature)
        let cd = payloadEnd + 16
        var suffix = Data(bytes[layout.centralDirectoryOffset...])
        try ZipTestSupport.writeUInt32(UInt32(cd), to: &suffix, at: suffix.count - 6)
        let descriptor = (0..<4).reduce(Data()) { data, _ in data + RawRecordArchiveBuilder.little(signature) }
        let source = ZipSparseTestSource(length: cd + UInt64(suffix.count), segments: [
            (0, Data(bytes.prefix(payloadStart))), (payloadEnd, descriptor), (cd, suffix)])
        for policy in [ZipLocalReadAheadPolicy.disabled, .standard] {
            let reader = try ZipReader(source: source, options: ReaderOptions(), readAhead: policy)
            XCTAssertEqual(ZipLayoutOutcome { try reader.zipRawRecordLayout(at: 0, limits: ReadLimits()) },
                           .failure(String(describing: KaitoError.malformed("ambiguous ZIP data descriptor"))))
        }
    }

    func testCancelledTaskCanScanAlreadyOpenedReader() async throws {
        let bytes = try fixture("small-dd")
        let reader = try ArchiveReader.open(data: bytes, options: ReaderOptions(appleDoublePolicy: .expose))
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            for index in reader.entries.indices {
                let spi = try reader.zipRawRecordLayout(at: index)
                let raw = try reader.rawRecord(of: reader.entries[index])
                guard spi?.recordRange == raw?.recordRange else { return false }
            }
            return true
        }
        let value = try await task.value
        XCTAssertTrue(value)
    }

    private func fixture(_ id: String) throws -> Data {
        let input = try XCTUnwrap(ZipGoldenCorpus.inputs().first { $0.id == id })
        return try ZipGoldenCorpus.decoded(input.files[0])
    }
    private func assertExactReads(_ bytes: Data, limits: ReadLimits) throws {
        var traces: [[Range<UInt64>]] = []
        for policy in [ZipLocalReadAheadPolicy.disabled, .standard] {
            let source = ZipWindowTestSource(DataByteSource(bytes))
            let reader = try ZipReader(source: source, options: ReaderOptions(limits: limits), readAhead: policy)
            source.reset()
            for index in reader.entries.indices { _ = try reader.zipRawRecordLayout(at: index, limits: limits) }
            traces.append(source.reads)
        }
        XCTAssertEqual(traces[0], traces[1])
    }
    private func assertWindows(_ reads: [Range<UInt64>], lower: UInt64, bound: UInt64,
                               maximum: Int = 256 * 1024, file: StaticString = #filePath, line: UInt = #line) {
        for range in reads {
            XCTAssertGreaterThanOrEqual(range.lowerBound, lower, file: file, line: line)
            XCTAssertLessThanOrEqual(range.upperBound, bound, file: file, line: line)
            XCTAssertLessThanOrEqual(range.count, maximum, file: file, line: line)
        }
    }
}

final class ZipWindowTestSource: ByteSource {
    enum Fault: Sendable { case none, throwLarge, zeroLarge, overReturnLarge, throwRange(Range<UInt64>), short }
    struct State { var reads: [Range<UInt64>] = []; var fault: Fault = .none }
    private let source: any ByteSource
    private let state = Mutex(State())
    init(_ source: any ByteSource) { self.source = source }
    var length: UInt64 { source.length }
    var reads: [Range<UInt64>] { state.withLock { $0.reads } }
    func reset(fault: Fault = .none) { state.withLock { $0 = State(fault: fault) } }
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        let range = offset..<(offset + UInt64(buffer.count))
        let fault = state.withLock { $0.reads.append(range); return $0.fault }
        switch fault {
        case .throwLarge where buffer.count > 64: throw KaitoError.io(5)
        case .zeroLarge where buffer.count > 64: return 0
        case .overReturnLarge where buffer.count > 64: return buffer.count + 1
        case .throwRange(let bad) where range.overlaps(bad): throw KaitoError.io(5)
        case .short: return try source.read(into: UnsafeMutableRawBufferPointer(rebasing: buffer.prefix(3)), at: offset)
        default: return try source.read(into: buffer, at: offset)
        }
    }
}

struct ZipSparseTestSource: ByteSource {
    let length: UInt64
    let segments: [(UInt64, Data)]
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        guard offset < length else { return 0 }
        let count = Int(min(UInt64(buffer.count), length - offset))
        buffer.initializeMemory(as: UInt8.self, repeating: 0)
        let wanted = offset..<(offset + UInt64(count))
        for (start, bytes) in segments {
            let end = start + UInt64(bytes.count)
            let lower = max(wanted.lowerBound, start)
            let upper = min(wanted.upperBound, end)
            if lower < upper {
                bytes.withUnsafeBytes { source in
                    UnsafeMutableRawBufferPointer(rebasing: buffer[Int(lower - offset)..<Int(upper - offset)])
                        .copyMemory(from: UnsafeRawBufferPointer(rebasing: source[Int(lower - start)..<Int(upper - start)]))
                }
            }
        }
        return count
    }
}
