import Darwin
import Foundation
@_spi(TarEditLayout) @testable import KaitoKit
import Synchronization
import XCTest
import zlib

final class CompressedTarSpliceTests: XCTestCase {
    private typealias S = TarSpliceTestSupport

    func testEditsAndThreeGenerationsInMemoryAndOnDisk() throws {
        let image = try S.corpus()
        for codec in S.Codec.allCases {
            let bytes = try S.encode(image, codec).data
            for disk in [false, true] {
                var options = S.options(disk: disk)
                let counting = CountingByteSource(DataByteSource(bytes))
                let baseReader = try ArchiveReader.open(source: counting, sourceURL: S.hint(codec), options: options)
                let base = try XCTUnwrap(baseReader.tarEditingSnapshot())
                let outputs = try S.cases(base, codec)
                counting.reset()
                for result in outputs {
                    options.recordsTarEditLayout = false
                    let actual = try S.open(result, codec, base: base, options: options)
                    XCTAssertNotNil(actual.tarEditingSnapshot(), result.name)
                    try S.equal(actual, S.full(result.bytes, codec, options: S.options(disk: disk)))
                    XCTAssertEqual(try TarEditTestSupport.bytes(XCTUnwrap(actual.tarEditingSnapshot()).image), result.image, result.name)
                    XCTAssertEqual(counting.bytesRead, 0)
                }
                var previous = base
                for generation in 0..<3 {
                    let result = try S.prefix(previous, codec, bytes: S.member("generation-\(generation)", Data([UInt8(generation)])))
                    let actual = try S.open(result, codec, base: previous, options: options)
                    try S.equal(actual, S.full(result.bytes, codec, options: S.options(disk: disk)))
                    previous = try XCTUnwrap(actual.tarEditingSnapshot())
                    if let image = previous.image as? SplicedTarImage {
                        XCTAssertLessThanOrEqual(image.leafCount, 8)
                        XCTAssertFalse(image.fragments.contains { $0.source is SplicedTarImage })
                        XCTAssertLessThanOrEqual(image.inMemorySize, options.limits.inMemorySingleFileLimit)
                    }
                    let descriptors = try fdCount()
                    _ = try actual.reopen()
                    XCTAssertEqual(try fdCount(), descriptors)
                }
            }
        }
    }

    func testFrozenEOFStraddlesAndWholeXZCheckChange() throws {
        for (name, codec) in [("strgz.tgz", S.Codec.tgz), ("strbz.tbz", .tbz), ("strxz.txz", .txz)] {
            let bytes = try TarEditTestSupport.fixture(name)
            let base = try XCTUnwrap(S.full(bytes, codec).tarEditingSnapshot())
            let eof = Int(try XCTUnwrap(base.layout).endOfArchiveOffset)
            let result = try S.edit("append", base, codec, a: eof, b: Int(base.image.length),
                                    replacement: S.member("after-straddle", Data([65])) + Data(count: 1024))
            try S.equal(S.open(result, codec, base: base), S.full(result.bytes, codec))
        }
        let base = try XCTUnwrap(S.full(TarEditTestSupport.fixture("third-xz-crc64.tar.xz"), .txz).tarEditingSnapshot())
        let bytes = try S.encode(TarEditTestSupport.bytes(base.image), .txz).data
        let result = S.Output(name: "CRC64 to CRC32", bytes: bytes, splice: .init(segments: [.encoded(output: S.payload(bytes, .txz))]), image: Data())
        try S.equal(S.open(result, .txz, base: base), S.full(bytes, .txz))
    }

    func testCompactionAndRetainedMemoryBudget() throws {
        let image = try S.corpus()
        for codec in S.Codec.allCases {
            for disk in [false, true] {
                let base = try XCTUnwrap(S.full(S.encode(image, codec).data, codec, options: S.options(disk: disk)).tarEditingSnapshot())
                let result = try S.prefix(base, codec, bytes: S.member("new", Data([42])))
                for policy in [TarSpliceStoragePolicy(maximumFragments: 1), TarSpliceStoragePolicy(maximumLeaves: 1)] {
                    let actual = try S.open(result, codec, base: base, options: S.options(disk: disk), policy: policy)
                    let snapshot = try XCTUnwrap(actual.tarEditingSnapshot())
                    XCTAssertFalse(snapshot.image is SplicedTarImage)
                    XCTAssertEqual(snapshot.image is FileByteSource, disk)
                    try S.equal(actual, S.full(result.bytes, codec, options: S.options(disk: disk)))
                }
                var options = S.options(disk: disk)
                options.limits.inMemorySingleFileLimit = disk ? 0 : base.image.length
                let actual = try S.open(result, codec, base: base, options: options)
                let composite = try XCTUnwrap(actual.tarEditingSnapshot()?.image as? SplicedTarImage)
                XCTAssertLessThanOrEqual(composite.inMemorySize, options.limits.inMemorySingleFileLimit)
                XCTAssertTrue(composite.fragments.contains { $0.source is FileByteSource })
                // base より低い閾値でも、保持した Data 全体を予算へ入れる。
                options.limits.inMemorySingleFileLimit = 1
                let compacted = try S.open(result, codec, base: base, options: options)
                XCTAssertTrue(compacted.tarEditingSnapshot()?.image is FileByteSource || disk)
                try S.equal(compacted, S.full(result.bytes, codec, options: options))
            }
        }
    }

    func testSegmentValidationFramingAndChecksums() throws {
        let image = try S.corpus()
        for codec in S.Codec.allCases {
            let bytes = try S.encode(image, codec).data
            let base = try XCTUnwrap(S.full(bytes, codec).tarEditingSnapshot()), payload = S.payload(bytes, codec)
            let honest: [CompressedTarSplice.Segment] = [.reused(output: payload, base: payload)]
            func reject(_ bytes: Data, _ segments: [CompressedTarSplice.Segment], _ reason: TarSpliceVerificationError.Reason,
                        hint: URL? = nil, options: ReaderOptions = S.options()) throws {
                try rejection(reason) { _ = try ArchiveReader.openSplicedCompressedTar(output: DataByteSource(bytes), sourceURL: hint ?? S.hint(codec),
                    base: base, splice: .init(segments: segments), options: options) }
            }
            try reject(bytes, [], .invalidSegments)
            for range in [(payload.lowerBound + 1)..<payload.upperBound, payload.lowerBound..<(payload.upperBound - 1),
                          payload.lowerBound..<(payload.upperBound + 1)] {
                try reject(bytes, [.reused(output: range, base: range)], .invalidSegments)
            }
            let middle = payload.lowerBound + (payload.upperBound - payload.lowerBound) / 2
            for start in [middle - 1, middle + 1] {
                try reject(bytes, [.encoded(output: payload.lowerBound..<middle), .encoded(output: start..<payload.upperBound)], .invalidSegments)
            }
            let chunk = try XCTUnwrap(base.chunkMap).chunks[0].compressedRange
            try reject(bytes, [.reused(output: payload.lowerBound..<(chunk.upperBound - 1), base: payload.lowerBound..<(chunk.upperBound - 1)),
                               .encoded(output: (chunk.upperBound - 1)..<payload.upperBound)], .invalidSegments)
            var bad = bytes
            let position = codec == .txz ? Int(payload.lowerBound) + 32 : Int(payload.lowerBound) + 7
            bad[position] ^= 1
            if codec == .txz { bad = bytes; bad[Int(chunk.upperBound - 1)] ^= 1 }
            try reject(bad, honest, .reusedBytesDiffer)
            try reject(bytes, honest, .baseNotSpliceable, hint: URL(fileURLWithPath: "/test.gz"))
            var recovery = S.options(); recovery.recoverDamagedArchives = true
            try reject(bytes, honest, .baseNotSpliceable, options: recovery)
            let fd = try fdCount()
            var limited = S.options(disk: true); limited.limits.maxEntrySize = UInt64(image.count - 1)
            XCTAssertThrowsError(try S.full(bytes, codec, options: limited)) { XCTAssertEqual($0 as? KaitoError, .limitExceeded("entry size")) }
            XCTAssertThrowsError(try ArchiveReader.openSplicedCompressedTar(output: DataByteSource(bytes), sourceURL: S.hint(codec), base: base,
                splice: .init(segments: honest), options: limited)) { XCTAssertEqual($0 as? KaitoError, .limitExceeded("entry size")) }
            XCTAssertEqual(try fdCount(), fd)
            if codec == .tgz {
                var bad = bytes; bad[bad.count - 8] ^= 1
                try reject(bad, honest, .checksumMismatch)
                let dropped = try S.dropping(base, codec, indices: [1])
                try reject(dropped.bytes, dropped.splice.segments, .dictionaryMismatch)
                try reject(bytes, [.reused(output: payload, base: payload), .encoded(output: payload.upperBound..<(payload.upperBound + 1))], .invalidSegments)
            }
            if codec == .txz {
                var bad = bytes; bad[bad.count - 16] ^= 1
                try reject(bad, honest, .checksumMismatch)
                bad = bytes
                bad[7] = 4
                bad.replaceSubrange(8..<12, with: CompressedTarFramingTestSupport.le(CompressedTarFramingTestSupport.crc(Data(bad[6..<8]))))
                try reject(bad, honest, .framingMismatch)
                // 正しい CRC の Index でも walk のサイズと違えば拒否する。
                var records = try S.xzRecords(bytes); records[0].1 += 512
                bad = Data(bytes.prefix(Int(payload.upperBound)))
                S.appendTail(&bad, image: image, codec: codec, records: records, flags: Data(bytes[6..<8]))
                try rejection(.framingMismatch, underlying: .malformed("XZ Index block sizes mismatch")) {
                    _ = try ArchiveReader.openSplicedCompressedTar(output: DataByteSource(bad), sourceURL: S.hint(codec), base: base,
                        splice: .init(segments: honest), options: S.options())
                }
            }
        }
    }

    func testStoredBridgeAndBaseImageSelfCheck() throws {
        let bytes = try S.encode(S.corpus(), .tgz).data, base = try XCTUnwrap(S.full(bytes, .tgz).tarEditingSnapshot())
        let prefix = try S.member("prefix", Data([1])), raw = try S.rawGzip(prefix, dictionary: Data(), final: false, level: 0, flush: Z_BLOCK)
        var output = Data(bytes.prefix(10)) + raw + bytes[10..<(bytes.count - 8)]
        S.appendTail(&output, image: try prefix + TarEditTestSupport.bytes(base.image), codec: .tgz, records: [], flags: Data())
        let boundary = UInt64(10 + raw.count), end = UInt64(output.count - 8)
        try rejection(.encodedSegmentInvalid) {
            _ = try ArchiveReader.openSplicedCompressedTar(output: DataByteSource(output), sourceURL: S.hint(.tgz), base: base,
                splice: .init(segments: [.encoded(output: 10..<boundary), .reused(output: boundary..<end, base: 10..<UInt64(bytes.count - 8))]), options: S.options())
        }
        guard case .gzip(let original) = base.chunkMap else { return XCTFail("gzip map") }
        var points = original.points
        points[1] = .init(compressedOffset: points[1].compressedOffset, imageOffset: points[1].imageOffset + 512, crc32: points[1].crc32)
        let corrupt = GzipChunkMap(headerLength: original.headerLength, points: points, trailerOffset: original.trailerOffset,
            trailerCRC32: original.trailerCRC32, imageLength: original.imageLength, compressedChecksums: original.compressedChecksums)
        let changed = TarEditingSnapshot(container: base.container, image: base.image, archive: base.archive, layout: base.layout,
            layoutUnavailableReason: nil, chunkMap: .gzip(corrupt), chunkMapUnavailableReason: nil, archiveIdentity: nil, limits: base.limits)
        let boundary2 = original.points[1].compressedOffset
        try rejection(.inconsistentBaseMap) {
            _ = try ArchiveReader.openSplicedCompressedTar(output: DataByteSource(bytes), sourceURL: S.hint(.tgz), base: changed,
                splice: .init(segments: [.reused(output: 10..<boundary2, base: 10..<boundary2), .encoded(output: boundary2..<original.trailerOffset)]), options: S.options())
        }
        try rejection(.inconsistentBaseMap) {
            let range = UInt64(10)..<original.trailerOffset
            _ = try ArchiveReader.openSplicedCompressedTar(output: DataByteSource(bytes), sourceURL: S.hint(.tgz), base: changed,
                splice: .init(segments: [.reused(output: range, base: range)]), options: S.options())
        }
    }

    func testReusedGzipMustContainFinalBlock() throws {
        // EOF を含む有効な tar prefix でも、DEFLATE の最終 block は省けない。
        let image = try TarTestSupport.makeTar(entries: []) + Data(count: 32_768)
        let bytes = try S.encode(image, .tgz).data
        let base = try XCTUnwrap(S.full(bytes, .tgz).tarEditingSnapshot())
        let chunk = try XCTUnwrap(base.chunkMap).chunks[0]
        var output = Data(bytes.prefix(Int(chunk.compressedRange.upperBound)))
        S.appendTail(&output, image: Data(image.prefix(Int(chunk.imageRange.upperBound))),
                     codec: .tgz, records: [], flags: Data())
        XCTAssertThrowsError(try S.full(output, .tgz))
        try rejection(.encodedSegmentInvalid) {
            _ = try ArchiveReader.openSplicedCompressedTar(output: DataByteSource(output), sourceURL: S.hint(.tgz), base: base,
                splice: .init(segments: [.reused(output: chunk.compressedRange, base: chunk.compressedRange)]), options: S.options())
        }
    }

    func testEnvelopeMetadataLimitsAndEmptyTarMatchFullOpen() throws {
        let empty = try TarTestSupport.makeTar(entries: [])
        for codec in S.Codec.allCases {
            let bytes = try S.encode(empty, codec).data
            let base = try XCTUnwrap(S.full(bytes, codec).tarEditingSnapshot())
            let range = S.payload(bytes, codec)
            let result = S.Output(name: "empty", bytes: bytes, splice: .init(segments: [.reused(output: range, base: range)]), image: empty)
            try S.equal(S.open(result, codec, base: base), S.full(bytes, codec))
            var options = S.options(); options.limits.maxEntryCount = 0
            XCTAssertThrowsError(try S.open(result, codec, base: base, options: options)) {
                XCTAssertEqual($0 as? KaitoError, .limitExceeded("archive entry count"))
            }
            XCTAssertThrowsError(try S.full(bytes, codec, options: options)) {
                XCTAssertEqual($0 as? KaitoError, .limitExceeded("archive entry count"))
            }
            options = S.options(); options.limits.maxTotalMetadataSize = 1
            let fullError = Result { try S.full(bytes, codec, options: options) }
            XCTAssertThrowsError(try S.open(result, codec, base: base, options: options)) { error in
                guard case .failure(let expected) = fullError else { return XCTFail("full open accepted metadata limit") }
                XCTAssertEqual(error as? KaitoError, expected as? KaitoError)
            }
        }
        let bytes = try S.encode(empty, .tgz).data
        let base = try XCTUnwrap(S.full(bytes, .tgz).tarEditingSnapshot()), range = S.payload(bytes, .tgz)
        for name in ["a/b/c", "/"] {
            var named = bytes; named[3] = 8
            let extra = Data((name + "\0").utf8); named.insert(contentsOf: extra, at: 10)
            let payload = (range.lowerBound + UInt64(extra.count))..<(range.upperBound + UInt64(extra.count))
            let result = S.Output(name: name, bytes: named, splice: .init(segments: [.reused(output: payload, base: range)]), image: empty)
            var options = S.options(); options.limits.maxPathComponentCount = 1
            let fullError = Result { try S.full(named, .tgz, options: options) }
            XCTAssertThrowsError(try S.open(result, .tgz, base: base, options: options)) { error in
                guard case .failure(let expected) = fullError else { return XCTFail("full open accepted invalid name") }
                XCTAssertEqual((error as? TarSpliceVerificationError)?.underlying ?? error as? KaitoError, expected as? KaitoError)
            }
        }
    }

    func testRepeatedGzipPointsAndEmptyBzipStreams() throws {
        let image = try S.corpus()
        for codec in [S.Codec.tgz, .tbz] {
            let encoded = try S.encode(image, codec)
            let base = try XCTUnwrap(S.full(encoded.data, codec).tarEditingSnapshot())
            var bytes = encoded.data
            if codec == .tgz {
                bytes.insert(contentsOf: [0, 0, 0, 255, 255, 0, 0, 0, 255, 255], at: encoded.chunks[0].compressed.upperBound)
                bytes.insert(contentsOf: [0, 0, 0, 255, 255], at: 10)
            } else {
                bytes.insert(contentsOf: try CompressedTarFramingTestSupport.bzip2(Data()).data, at: encoded.chunks[0].compressed.upperBound)
            }
            let result = S.Output(name: "empty boundaries", bytes: bytes,
                                  splice: .init(segments: [.encoded(output: S.payload(bytes, codec))]), image: image)
            let reader = try S.open(result, codec, base: base)
            try S.equal(reader, S.full(bytes, codec))
            let next = try XCTUnwrap(reader.tarEditingSnapshot()), range = S.payload(bytes, codec)
            let reused = S.Output(name: "reuse empty boundaries", bytes: bytes, splice: .init(segments: [.reused(output: range, base: range)]), image: image)
            try S.equal(S.open(reused, codec, base: next), S.full(bytes, codec))
        }
    }

    func testConcurrentSplicesShareOnlyImmutableLeaves() throws {
        let bytes = try S.encode(S.corpus(), .tgz).data
        let base = try XCTUnwrap(S.full(bytes, .tgz, options: S.options(disk: true)).tarEditingSnapshot())
        let range = S.payload(bytes, .tgz), failures = Mutex<[String]>([])
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            do {
                let reader = try ArchiveReader.openSplicedCompressedTar(output: DataByteSource(bytes), sourceURL: S.hint(.tgz), base: base,
                    splice: .init(segments: [.reused(output: range, base: range)]), options: S.options(disk: true))
                let reopened = try reader.reopen()
                if try reopened.read(reopened.entries[0]) != reader.read(reader.entries[0]) {
                    failures.withLock { $0.append("content differs") }
                }
            } catch { failures.withLock { $0.append(String(describing: error)) } }
        }
        XCTAssertEqual(failures.withLock { $0 }, [])
    }

    func testMissingStreamsOrBlocksMatchFullTarParsing() throws {
        for codec in [S.Codec.tbz, .txz] {
            let base = try XCTUnwrap(S.full(S.encode(S.corpus(), codec).data, codec).tarEditingSnapshot())
            for missing: Set<Int> in [[1], [3], [8]] {
                let result = try S.dropping(base, codec, indices: missing)
                let expected = Result { try S.full(result.bytes, codec) }
                let actual = Result { try S.open(result, codec, base: base) }
                switch (actual, expected) {
                case (.success(let a), .success(let b)): try S.equal(a, b)
                case (.failure(let a), .failure(let b)): XCTAssertEqual(a as? KaitoError, b as? KaitoError)
                default: XCTFail("\(codec) \(missing): \(actual) vs \(expected)")
                }
            }
        }
    }

    func testBaseRewriteWithRestoredMtimeAndOutputIdentityChange() throws {
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("base.tgz")
        let image = try S.corpus(), bytes = try CompressedTarFramingTestSupport.gzip(image, chunkSize: 16_384, level: 0).data
        try bytes.write(to: url)
        let base = try XCTUnwrap(ArchiveReader.open(url: url, options: S.options()).tarEditingSnapshot())
        var changed = image; changed[513] ^= 1
        let rewritten = try CompressedTarFramingTestSupport.gzip(changed, chunkSize: 16_384, level: 0).data
        XCTAssertEqual(bytes.count, rewritten.count)
        var info = stat(); XCTAssertEqual(stat(url.path, &info), 0)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: rewritten)
        var times = [info.st_atimespec, info.st_mtimespec]
        XCTAssertEqual(futimens(handle.fileDescriptor, &times), 0)
        try handle.close()
        XCTAssertTrue(base.archiveIsUnchanged())
        XCTAssertNoThrow(try S.full(rewritten, .tgz))
        let range = S.payload(bytes, .tgz), splice = CompressedTarSplice(segments: [.reused(output: range, base: range)])
        try rejection(.reusedBytesDiffer) {
            _ = try ArchiveReader.openSplicedCompressedTar(output: DataByteSource(rewritten), sourceURL: url, base: base, splice: splice, options: S.options())
        }
        // base の archive は変更済みでも、検証済み byte を運んだ output は通る。
        let valid = try ArchiveReader.openSplicedCompressedTar(output: DataByteSource(bytes), sourceURL: url, base: base, splice: splice, options: S.options())
        try S.equal(valid, S.full(bytes, .tgz))
        try rejection(.outputChanged) {
            _ = try ArchiveReader.openSplicedCompressedTar(output: SpliceChangingIdentity(bytes), sourceURL: url, base: base, splice: splice, options: S.options(disk: true))
        }
    }

    func testMidVerificationCancellationClosesStaging() async throws {
        let image = try TarTestSupport.makeTar(entries: [HandTarEntry(name: "large", contents: Data(count: 70 * 1_048_576))])
        let bytes = try CompressedTarFramingTestSupport.gzip(image).data
        let original = try XCTUnwrap(S.full(bytes, .tgz, options: S.options(disk: true)).tarEditingSnapshot())
        let cancelling = SpliceCancellingSource(original.image)
        let base = TarEditingSnapshot(container: original.container, image: cancelling, archive: original.archive,
            layout: original.layout, layoutUnavailableReason: nil, chunkMap: original.chunkMap, chunkMapUnavailableReason: nil,
            archiveIdentity: nil, limits: original.limits)
        let range = S.payload(bytes, .tgz)
        let descriptors = try fdCount()
        let task = Task.detached {
            _ = try ArchiveReader.openSplicedCompressedTar(output: DataByteSource(bytes), sourceURL: S.hint(.tgz), base: base,
                splice: .init(segments: [.reused(output: range, base: range)]), options: S.options(disk: true))
        }
        do { _ = try await task.value; XCTFail("expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertGreaterThanOrEqual(cancelling.bytesRead.withLock { $0 }, 63 * 1_048_576)
        XCTAssertLessThan(cancelling.bytesRead.withLock { $0 }, original.image.length)
        XCTAssertEqual(try fdCount(), descriptors)

        // encoded の staging は既存 materializer の取消し点を使う。
        let reachedStaging = Mutex(false)
        let encodedTask = Task.detached {
            try SingleFileMaterializer.$availableTemporarySpace.withValue({
                reachedStaging.withLock { $0 = true }
                withUnsafeCurrentTask { $0?.cancel() }
                return UInt64.max
            }) {
                _ = try ArchiveReader.openSplicedCompressedTar(output: DataByteSource(bytes), sourceURL: S.hint(.tgz), base: original,
                    splice: .init(segments: [.encoded(output: range)]), options: S.options(disk: true))
            }
        }
        do { _ = try await encodedTask.value; XCTFail("expected encoded cancellation") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertTrue(reachedStaging.withLock { $0 })
        XCTAssertEqual(try fdCount(), descriptors)
    }

    private func rejection(_ reason: TarSpliceVerificationError.Reason, underlying: KaitoError? = nil,
                           file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) throws {
        let descriptors = try fdCount()
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as? TarSpliceVerificationError)?.reason, reason, String(describing: error), file: file, line: line)
            if let underlying { XCTAssertEqual((error as? TarSpliceVerificationError)?.underlying, underlying, file: file, line: line) }
        }
        XCTAssertEqual(try fdCount(), descriptors, file: file, line: line)
    }
    private func fdCount() throws -> Int { try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count }
}

private final class SpliceChangingIdentity: ByteSourceFileIdentityProviding {
    let source: DataByteSource
    let calls = Mutex<Int64>(0)
    init(_ bytes: Data) { source = DataByteSource(bytes) }
    var length: UInt64 { source.length }
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int { try source.read(into: buffer, at: offset) }
    func currentFileIdentity() throws -> ByteSourceFileIdentity {
        let version = calls.withLock { value in defer { value += 1 }; return value }
        return .init(device: 1, inode: 2, size: length, modificationSeconds: version, modificationNanoseconds: 0)
    }
}

private final class SpliceCancellingSource: ByteSource {
    let source: any ByteSource
    let bytesRead = Mutex<UInt64>(0)
    let cancelAfter: UInt64
    let minimumReadSize: Int
    init(_ source: any ByteSource, cancelAfter: UInt64 = 10 * 1_048_576, minimumReadSize: Int = 0) {
        self.source = source; self.cancelAfter = cancelAfter; self.minimumReadSize = minimumReadSize
    }
    var length: UInt64 { source.length }
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        let count = try source.read(into: buffer, at: offset)
        let total = bytesRead.withLock { $0 += UInt64(count); return $0 }
        if total >= cancelAfter, buffer.count >= minimumReadSize { withUnsafeCurrentTask { $0?.cancel() } }
        return count
    }
}
