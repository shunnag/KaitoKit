import Darwin
import Foundation
import Synchronization
@_spi(SevenZipEditLayout) @_spi(TarEditLayout) @testable import KaitoKit
import XCTest

final class ReopenExecutionOptionsTests: RAR4BuilderTestCase {
    private let payload = Data("execution options payload".utf8)

    private func fixtures() throws -> [(name: String, bytes: Data)] {
        [
            ("zip", try ZipTestSupport.makeArchive(entries: [HandZipEntry(name: "page", uncompressedData: payload)])),
            ("tar", try TarTestSupport.makeTar(entries: [HandTarEntry(name: "page", contents: payload)])),
            ("lha", try LHATestSupport.makeArchive(entries: [HandLHAEntry(name: "page", contents: payload, headerLevel: 2)])),
            ("rar4", makeArchive(files: [FileFixture(name: Array("page".utf8), contents: payload)])),
            ("rar5", RAR5TestSupport.archive(blocks: [RAR5TestSupport.storedFile(name: "page", contents: payload)])),
            ("7z-solid", SevenZipParallelTestSupport.raw().archive()),
            ("7z-compressed", try SevenZipParallelTestSupport.compressed().archive()),
            ("7z-independent", try ZipTestSupport.checkedInFixture("sevenzip/chain-lzma-lzma-lzma2-bcj2.7z")),
        ]
    }

    private func executionOptions(from original: ReaderOptions = ReaderOptions(), threads: Int = 4) -> ReaderOptions {
        var options = original
        options.decodeThreads = threads
        options.decodePowerPolicy = .alwaysUseAllCores
        options.inputLatency = .high
        options.limits.parallelDecodeMemory = 8 << 20
        return options
    }

    func testEverySharingFormatMatchesFreshOpenWithoutHeaderReads() throws {
        let originalOptions = ReaderOptions(decodeThreads: 1)
        for fixture in try fixtures() {
            let source = CountingByteSource(DataByteSource(fixture.bytes))
            let primary = try ArchiveReader.open(source: source, options: originalOptions)
            for entry in primary.entries { _ = try primary.read(entry) }
            for threads in [1, 4] {
                var options = executionOptions(from: originalOptions, threads: threads)
                options.limits.parallelDecodeMemory = threads == 1 ? 0 : 8 << 20
                source.reset()
                let reopened = try primary.reopen(options: options)
                XCTAssertEqual(source.bytesRead, 0, "\(fixture.name) must reuse parsed headers")
                let fresh = try ArchiveReader.open(data: fixture.bytes, options: options)
                XCTAssertEqual(reopened.entries, primary.entries, fixture.name)
                XCTAssertEqual(reopened.entries, fresh.entries, fixture.name)
                XCTAssertEqual(reopened.nameEncoding, fresh.nameEncoding, fixture.name)
                for entry in reopened.entries {
                    XCTAssertEqual(try reopened.read(entry), try fresh.read(entry), fixture.name)
                    XCTAssertEqual(try reopened.read(entry), try primary.read(entry), fixture.name)
                }
                source.reset()
                let again = try reopened.reopen()
                XCTAssertEqual(source.bytesRead, 0, "\(fixture.name) ordinary reopen must still share")
                XCTAssertEqual(again.entries, reopened.entries)
            }
        }
    }

    func testCP932NamesDoNotRepeatEncodingDetectionOrHeaderParsing() throws {
        let raw = Array(try XCTUnwrap("日本語の表紙.txt".data(using: .shiftJIS)))
        let bytes = try ZipTestSupport.makeArchive(entries: [HandZipEntry(rawName: raw, uncompressedData: payload)])
        let source = CountingByteSource(DataByteSource(bytes))
        let detections = Mutex(0)
        try EncodingDetector.$testingArchiveDetection.withValue({ detections.withLock { $0 += 1 } }) {
            let primary = try ArchiveReader.open(source: source)
            XCTAssertEqual(primary.nameEncoding, .shiftJIS)
            let before = detections.withLock { $0 }
            XCTAssertGreaterThan(before, 0)
            source.reset()
            for threads in 1...6 {
                let reopened = try primary.reopen(options: executionOptions(threads: threads))
                XCTAssertEqual(reopened.entries, primary.entries)
                XCTAssertEqual(reopened.nameEncoding, .shiftJIS)
            }
            XCTAssertEqual(detections.withLock { $0 }, before)
            XCTAssertEqual(source.bytesRead, 0)
        }
    }

    func testAppleDoubleMappingsAndStagedCompressedTarShareParsedState() throws {
        let tar = try TarTestSupport.makeTar(entries: [HandTarEntry(name: "page", contents: payload)])
        let cases: [(Data, URL?)] = [
            (try TestFixtures.base64("appledouble/finder.zip"), nil),
            (try TestFixtures.base64("appledouble/mac.tar"), nil),
            (try CompressedTarFramingTestSupport.gzip(tar).data, URL(fileURLWithPath: "/book.tar.gz")),
        ]
        for (bytes, hint) in cases {
            let source = CountingByteSource(DataByteSource(bytes))
            let primary = try ArchiveReader.open(source: source, sourceURL: hint)
            source.reset()
            let reopened = try primary.reopen(options: executionOptions())
            XCTAssertEqual(source.bytesRead, 0)
            let fresh = try ArchiveReader.open(source: DataByteSource(bytes), sourceURL: hint,
                                               options: executionOptions())
            XCTAssertEqual(reopened.entries, fresh.entries)
            for entry in reopened.entries {
                XCTAssertEqual(try reopened.read(entry), try fresh.read(entry))
                XCTAssertEqual(try primary.read(entry), try fresh.read(entry))
            }
        }
    }

    func testExecutionOptionsControlParallelDecoding() throws {
        guard LeafDecodePool.shared.capacity > 1 else { throw XCTSkip("parallel decoding requires two CPUs") }
        let fixture = SevenZipParallelTestSupport.raw()
        let primary = try ArchiveReader.open(data: fixture.archive(), options: ReaderOptions(decodeThreads: 1))
        for (threads, memory, parallel) in [(1, UInt64(64 << 20), false), (4, 0, false), (4, 64 << 20, true)] {
            var options = executionOptions(threads: threads)
            options.inputLatency = .low
            options.limits.parallelDecodeMemory = memory
            let reopened = try primary.reopen(options: options)
            let submissions = Mutex(0)
            try LeafDecodePool.$testingSubmission.withValue({ submissions.withLock { $0 += 1 } }) {
                for (entry, expected) in zip(reopened.entries, fixture.payloads) {
                    XCTAssertEqual(try reopened.read(entry), expected)
                }
            }
            XCTAssertEqual(submissions.withLock { $0 > 0 }, parallel)
        }
    }

    func testOpeningAndListingOptionChangesAreRejectedBeforeSourceReads() throws {
        let source = CountingByteSource(DataByteSource(try XCTUnwrap(fixtures().first).bytes))
        let reader = try ArchiveReader.open(source: source)
        let changes: [(String, (inout ReaderOptions) -> Void)] = [
            ("fileAccessPolicy", { $0.fileAccessPolicy = .bounded }),
            ("rar5QuickOpenPolicy", { $0.rar5QuickOpenPolicy = .always }),
            ("recordsSevenZipEditLayout", { $0.recordsSevenZipEditLayout = true }),
            ("recordsTarEditLayout", { $0.recordsTarEditLayout = true }),
            ("maximumSFXScanSize", { $0.maximumSFXScanSize = 0 }),
            ("scanForSFXInData", { $0.scanForSFXInData = true }),
            ("encodingPolicy", { $0.encodingPolicy = .utf8Only }),
            ("password", { $0.password = "changed" }),
            ("lazyLocalHeaders", { $0.lazyLocalHeaders = false }),
            ("recoverDamagedArchives", { $0.recoverDamagedArchives = true }),
            ("maxSevenZipAESCyclesPower", { $0.maxSevenZipAESCyclesPower = 1 }),
            ("maxRAR5KDFCountPower", { $0.maxRAR5KDFCountPower = 1 }),
            ("verifyRAR5Blake2sp", { $0.verifyRAR5Blake2sp = false }),
            ("appleDoublePolicy", { $0.appleDoublePolicy = .expose }),
        ]
        source.reset()
        for (name, change) in changes {
            var options = executionOptions()
            change(&options)
            XCTAssertThrowsError(try reader.reopen(options: options), name) {
                XCTAssertEqual($0 as? KaitoError, .unsupportedMethod("reopen cannot change \(name)"))
                XCTAssertTrue($0.localizedDescription.contains(name))
            }
        }
        XCTAssertEqual(source.bytesRead, 0)
        XCTAssertEqual(try reader.read(reader.entries[0]), payload)
    }

    func testAllNonExecutionLimitsAreRejected() throws {
        let reader = try ArchiveReader.open(data: XCTUnwrap(fixtures().first).bytes)
        let changes: [(inout ReadLimits) -> Void] = [
            { $0.maxEntrySize = 0 }, { $0.maxTotalUncompressedSize = 0 },
            { $0.maxInMemorySize = 0 },
            { $0.inMemorySingleFileLimit = 0 }, { $0.stagingFreeSpaceReserve = 0 },
            { $0.maxEntryCount = 0 }, { $0.maxMetadataSize = 0 },
            { $0.maxMetadataRecordCount = 0 }, { $0.maxPathComponentCount = 0 },
            { $0.maxTotalMetadataSize = 0 }, { $0.maxDictionarySize = 0 },
            { $0.maxJPEGBlocks = 0 }, { $0.maxVolumeCount = 0 },
            { $0.maxRAR5HeaderKDFWork = 0 }, { $0.maxSevenZipHeaderKDFWork = 0 },
            { $0.maxSevenZipEntryKDFWork = 0 }, { $0.maxStuffItXKDFWork = 0 },
            { $0.maxRAR5EntryKDFWork = 0 },
        ]
        for change in changes {
            var options = executionOptions()
            change(&options.limits)
            XCTAssertThrowsError(try reader.reopen(options: options)) {
                XCTAssertEqual($0 as? KaitoError, .unsupportedMethod(
                    "reopen cannot change limits (only parallelDecodeMemory may change)"))
            }
        }
    }

    func testOptionRejectionPreservesExhaustiveKaitoErrorSwitch() throws {
        let primary = try ArchiveReader.open(data: XCTUnwrap(fixtures().first).bytes)
        var changed = executionOptions()
        changed.encodingPolicy = .utf8Only
        var rejected: KaitoError?
        XCTAssertThrowsError(try primary.reopen(options: changed)) { rejected = $0 as? KaitoError }
        switch try XCTUnwrap(rejected) {
        case .unsupportedMethod(let reason):
            XCTAssertEqual(reason, "reopen cannot change encodingPolicy")
        case .unsupportedFormat, .malformed, .truncated, .passwordRequired, .wrongPassword,
             .checksumMismatch, .limitExceeded, .io, .notFound:
            XCTFail("expected an unsupported reopen operation")
        }
    }

    func testNondefaultOpeningOptionsMustMatch() throws {
        var original = ReaderOptions(encodingPolicy: .fixed(.shiftJIS), lazyLocalHeaders: false,
                                     appleDoublePolicy: .expose)
        original.limits.maxEntryCount = 123
        let primary = try ArchiveReader.open(data: XCTUnwrap(fixtures().first).bytes, options: original)
        XCTAssertThrowsError(try primary.reopen(options: ReaderOptions()))
        let reopened = try primary.reopen(options: executionOptions(from: original))
        XCTAssertEqual(reopened.entries, primary.entries)
        XCTAssertEqual(try reopened.read(reopened.entries[0]), payload)
    }

    func testInputLatencyChangesPreserveConditionalRAR5QuickOpenListing() throws {
        let bytes = RAR5TestSupport.archive(blocks: [RAR5TestSupport.storedFile(name: "page", contents: payload)])
        for policy in [RAR5QuickOpenPolicy.never, .always, .highLatencyInput] {
            for latency in [InputLatency.low, .high] {
                var original = ReaderOptions()
                original.rar5QuickOpenPolicy = policy
                original.inputLatency = latency
                let source = CountingByteSource(DataByteSource(bytes))
                let primary = try ArchiveReader.open(source: source, options: original)
                var sameOptions = executionOptions(from: original)
                sameOptions.inputLatency = latency
                let same = try primary.reopen(options: sameOptions)
                XCTAssertEqual(try same.read(same.entries[0]), payload)
                var changed = executionOptions(from: original)
                changed.inputLatency = latency == .low ? .high : .low
                source.reset()
                let reopened = try primary.reopen(options: changed)
                XCTAssertEqual(source.bytesRead, 0)
                XCTAssertEqual(reopened.entries, primary.entries)
                XCTAssertEqual(try reopened.read(reopened.entries[0]), payload)
            }
        }
    }

    func testReadErrorsMatchFreshReaderAndLimitsAreInherited() throws {
        let original = ReaderOptions(limits: ReadLimits(maxInMemorySize: 0))
        for fixture in try fixtures() {
            let primary = try ArchiveReader.open(data: fixture.bytes, options: original)
            let options = executionOptions(from: original)
            let reopened = try primary.reopen(options: options)
            let fresh = try ArchiveReader.open(data: fixture.bytes, options: options)
            for entry in reopened.entries where entry.uncompressedSize != 0 {
                var expected: KaitoError?
                XCTAssertThrowsError(try fresh.read(entry)) { expected = $0 as? KaitoError }
                XCTAssertNotNil(expected)
                XCTAssertThrowsError(try reopened.read(entry)) { XCTAssertEqual($0 as? KaitoError, expected) }
                XCTAssertThrowsError(try primary.read(entry)) { XCTAssertEqual($0 as? KaitoError, expected) }
            }
            let inherited = try reopened.reopen()
            XCTAssertThrowsError(try inherited.read(XCTUnwrap(inherited.entries.first)))
        }
    }

    func testAutomaticExecutionSnapshotsResolveBeforeFormatCloneAndSurviveOrdinaryReopen() throws {
        let bytes = SevenZipParallelTestSupport.raw().archive()
        let primary = try ReaderOptions.$testingAutomaticThreads.withValue({ _ in 1 }) {
            try ArchiveReader.open(data: bytes)
        }
        let calls = Mutex(0)
        let options = executionOptions()
        var automatic = options
        automatic.decodeThreads = nil
        let reopened = try ReaderOptions.$testingAutomaticThreads.withValue({ policy in
            XCTAssertEqual(policy, .alwaysUseAllCores)
            return calls.withLock { $0 += 1; return 3 }
        }) {
            try primary.reopen(options: automatic)
        }
        XCTAssertEqual(calls.withLock { $0 }, 1)
        let seven = try XCTUnwrap(reopened.formatReaderForTesting as? SevenZipReader)
        XCTAssertTrue(seven.avoidsHeaderScans)
        XCTAssertFalse(try XCTUnwrap(primary.formatReaderForTesting as? SevenZipReader).avoidsHeaderScans)
        try ReaderOptions.$testingAutomaticThreads.withValue({ _ in XCTFail("snapshot must survive"); return 99 }) {
            let again = try reopened.reopen()
            XCTAssertTrue(try XCTUnwrap(again.formatReaderForTesting as? SevenZipReader).avoidsHeaderScans)
        }
        var low = automatic
        low.decodeThreads = 2
        low.inputLatency = .low
        let changed = try reopened.reopen(options: low)
        XCTAssertFalse(try XCTUnwrap(changed.formatReaderForTesting as? SevenZipReader).avoidsHeaderScans)
    }

    func testPasswordProviderIsRetainedAndCurrentPasswordIsInherited() throws {
        let originalProvider = Provider(), ignoredProvider = Provider()
        let options = ReaderOptions(passwordProvider: originalProvider)
        let bytes = try ZipModernFixtures.data("xz-aes.zip")
        let primary = try ArchiveReader.open(data: bytes, options: options)
        var replacement = executionOptions(from: options)
        replacement.passwordProvider = ignoredProvider
        let reopened = try primary.reopen(options: replacement)
        XCTAssertEqual(try reopened.read(reopened.entries[0]), ZipModernFixtures.payload)
        XCTAssertEqual(originalProvider.calls.withLock { $0 }, 1)
        XCTAssertEqual(ignoredProvider.calls.withLock { $0 }, 0)
        primary.password = "wrong"
        let wrong = try primary.reopen(options: replacement)
        XCTAssertEqual(wrong.password, "wrong")
        XCTAssertThrowsError(try wrong.read(wrong.entries[0])) { XCTAssertEqual($0 as? KaitoError, .wrongPassword) }
        XCTAssertEqual(try reopened.read(reopened.entries[0]), ZipModernFixtures.payload)
    }

    func testRuntimePasswordChangesPreserveOpeningOptionsAcrossReopenChains() throws {
        for fixture in try fixtures() {
            for original in [ReaderOptions(), ReaderOptions(password: "opening")] {
                try checkPasswordReopenChain(bytes: fixture.bytes, options: original)
            }
        }
    }

    func testRuntimePasswordChangesSurviveFallbackReopenChains() throws {
        var cpio = CpioArchiveBuilder()
        cpio.record("page", payload: Array(payload))
        cpio.trailer()
        let original = ReaderOptions(password: "opening")
        try checkPasswordReopenChain(bytes: cpio.data, options: original)
        try checkPasswordReopenChain(bytes: CompressedTarFramingTestSupport.bzip2(payload).data, options: original)
        try checkPasswordReopenChain(bytes: CompressedTarFramingTestSupport.gzip(cpio.data).data, options: original,
                                     sourceURL: URL(fileURLWithPath: "/book.cpio.gz"))
    }

    private func checkPasswordReopenChain(bytes: Data, options: ReaderOptions, sourceURL: URL? = nil) throws {
        let primary = try ArchiveReader.open(source: DataByteSource(bytes), sourceURL: sourceURL, options: options)
        let expected = try primary.entries.map { try primary.read($0) }
        primary.password = "x"
        let direct = try primary.reopen(options: options)
        let ordinary = try primary.reopen()
        let changed = try ordinary.reopen(options: executionOptions(from: options))
        changed.password = "y"
        let chained = try changed.reopen(options: options)
        for reader in [direct, ordinary] { XCTAssertEqual(reader.password, "x") }
        for reader in [changed, chained] { XCTAssertEqual(reader.password, "y") }
        for reader in [primary, direct, ordinary, changed, chained] {
            XCTAssertEqual(reader.entries, primary.entries)
            for (entry, data) in zip(reader.entries, expected) { XCTAssertEqual(try reader.read(entry), data) }
        }
        chained.password = nil
        XCTAssertNil(try chained.reopen(options: options).password)
        var incompatible = options
        incompatible.password = "x"
        XCTAssertThrowsError(try primary.reopen(options: incompatible)) {
            XCTAssertEqual($0 as? KaitoError, .unsupportedMethod("reopen cannot change password"))
        }
    }

    func testProviderSuppliedPasswordSurvivesReopenOptionsChains() throws {
        for fixture in ["xz-aes.zip", "xz-zipcrypto.zip"] {
            let provider = Provider()
            let original = ReaderOptions(passwordProvider: provider)
            let primary = try ArchiveReader.open(data: ZipModernFixtures.data(fixture), options: original)
            XCTAssertEqual(try primary.read(primary.entries[0]), ZipModernFixtures.payload)
            XCTAssertEqual(primary.password, ZipModernFixtures.password)
            let direct = try primary.reopen(options: original)
            let ordinary = try primary.reopen()
            let changed = try ordinary.reopen(options: executionOptions(from: original))
            let chained = try changed.reopen(options: original)
            for reader in [direct, ordinary, changed, chained] {
                XCTAssertEqual(reader.password, ZipModernFixtures.password)
                XCTAssertEqual(try reader.read(reader.entries[0]), ZipModernFixtures.payload)
            }
            XCTAssertEqual(provider.calls.withLock { $0 }, 1)
        }
    }

    func testBoundedReplacementDetectionMatchesOrdinaryReopenForEveryFormat() throws {
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var original = ReaderOptions()
        original.fileAccessPolicy = .bounded
        for fixture in try fixtures() {
            let url = directory.appendingPathComponent(fixture.name)
            try fixture.bytes.write(to: url)
            let primary = try ArchiveReader.open(url: url, options: original)
            let ordinary = try primary.reopen()
            let changed = try primary.reopen(options: executionOptions(from: original))
            FileAccessPolicy.releaseIdleCachedHandles()
            let replacement = directory.appendingPathComponent("replacement")
            try fixture.bytes.write(to: replacement)
            XCTAssertEqual(Darwin.rename(replacement.path, url.path), 0)
            let afterReplacement = try primary.reopen(options: executionOptions(from: original))
            for reader in [primary, ordinary, changed, afterReplacement] {
                XCTAssertThrowsError(try reader.read(XCTUnwrap(reader.entries.first)), fixture.name) {
                    XCTAssertEqual($0 as? KaitoError, .io(ESTALE), fixture.name)
                }
            }
        }
    }

    func testPersistentReplacementKeepsOriginalSourceLikeOrdinaryReopen() throws {
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("archive.zip")
        try XCTUnwrap(fixtures().first).bytes.write(to: url)
        let primary = try ArchiveReader.open(url: url)
        let replacement = directory.appendingPathComponent("replacement")
        try Data("replacement".utf8).write(to: replacement)
        XCTAssertEqual(Darwin.rename(replacement.path, url.path), 0)
        for reader in [try primary.reopen(), try primary.reopen(options: executionOptions())] {
            XCTAssertEqual(try reader.read(reader.entries[0]), payload)
        }
    }

    func testPrimaryAndFiveReopenedReadersReadConcurrentlyForEveryFormat() async throws {
        for fixture in try fixtures() {
            let source = CountingByteSource(DataByteSource(fixture.bytes))
            let primary = try ArchiveReader.open(source: source)
            let expected = try primary.entries.map { try primary.read($0) }
            var sessions: [ReadingSession] = []
            for threads in 1...5 {
                sessions.append(ReadingSession(reader: try primary.reopen(options: executionOptions(threads: threads))))
            }
            sessions.append(ReadingSession(reader: primary))
            try await withThrowingTaskGroup(of: Bool.self) { group in
                for session in sessions {
                    group.addTask { try await session.checkReads(expected: expected) }
                }
                for try await matches in group { XCTAssertTrue(matches, fixture.name) }
            }
        }
    }

    private actor ReadingSession {
        let reader: ArchiveReader
        init(reader: sending ArchiveReader) { self.reader = reader }

        func checkReads(expected: [Data]) throws -> Bool {
            for round in 0..<12 {
                for index in reader.entries.indices {
                    let selected = round.isMultiple(of: 2) ? index : reader.entries.count - 1 - index
                    if try reader.read(reader.entries[selected]) != expected[selected] { return false }
                }
            }
            return true
        }
    }

    private final class Provider: PasswordProvider {
        let calls = Mutex(0)
        func password(for format: ArchiveFormat) throws -> String? {
            calls.withLock { $0 += 1 }
            return ZipModernFixtures.password
        }
    }
}
