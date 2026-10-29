import Foundation
@_spi(ZipRawLayout) @testable import KaitoKit
import XCTest

final class ZipAESKeyLookAheadTests: XCTestCase {
    func testWindowRespectsThreadsAndMemoryIncludingPassword() {
        XCTAssertEqual(ZipAESKeyLookAhead(workers: 1, memoryBudget: 1 << 20, passwordBytes: 9).capacity, 0)
        XCTAssertEqual(ZipAESKeyLookAhead(workers: 4, memoryBudget: 1 << 20, passwordBytes: 9).capacity,
                       min(3, LeafDecodePool.shared.capacity))
        XCTAssertEqual(ZipAESKeyLookAhead(workers: 32, memoryBudget: 1 << 20, passwordBytes: 9).capacity,
                       min(8, LeafDecodePool.shared.capacity))
        XCTAssertEqual(ZipAESKeyLookAhead(workers: 8, memoryBudget: 8_192, passwordBytes: 9).capacity, 1)
        XCTAssertEqual(ZipAESKeyLookAhead(workers: 8, memoryBudget: 4_096, passwordBytes: 9).capacity, 0)
        XCTAssertEqual(ZipAESKeyLookAhead(workers: 8, memoryBudget: 4_105, passwordBytes: 9).capacity, 0)
        XCTAssertEqual(ZipAESKeyLookAhead(workers: 8, memoryBudget: 4_114, passwordBytes: 9).capacity, 1)
        XCTAssertEqual(ZipAESKeyLookAhead(workers: 8, memoryBudget: .max, passwordBytes: .max).capacity, 0)
    }

    func testSerialParallelMemoryDisabledAndHighLatencyReadsMatch() throws {
        let bytes = try archive()
        for (threads, budget, latency) in [(1, 1 << 20, InputLatency.low), (4, 1 << 20, .low),
                                           (4, 0, .low), (4, 1 << 20, .high)] {
            var options = ReaderOptions(limits: ReadLimits(parallelDecodeMemory: UInt64(budget)),
                                        password: "KaitoFuzz", decodeThreads: threads)
            options.inputLatency = latency
            let reader = try ZipReader(source: DataByteSource(bytes), options: options)
            for (i, entry) in reader.entries.enumerated() {
                XCTAssertEqual(try reader.stream(for: entry, limits: options.limits).readAll(), plain(i))
                XCTAssertLessThanOrEqual(reader.aesKeyLookAheadForTesting?.count ?? 0, 3)
            }
            if threads > 1 && budget > 0 && latency == .low {
                XCTAssertGreaterThan(try XCTUnwrap(reader.aesKeyLookAheadForTesting).servedCount, 0)
            } else {
                XCTAssertEqual(reader.aesKeyLookAheadForTesting?.submittedCount ?? 0, 0)
            }
        }
    }

    func testErrorOrderingForWrongPasswordCorruptVerifierTagHeaderAndTruncation() throws {
        let original = try archive()
        let layout = try ZipTestSupport.layout(of: original)
        let oracle = try ZipReader(source: DataByteSource(original), options: ReaderOptions())
        let second = try XCTUnwrap(oracle.zipRawRecordLayout(at: 1, limits: ReadLimits()))
        let payload = Int(second.payloadRange.lowerBound)
        for mutation in 0..<5 {
            var bytes = original
            switch mutation {
            case 0: bytes[payload + 16] ^= 1 // AES-256 verifier
            case 1: bytes[Int(second.payloadRange.upperBound) - 1] ^= 1 // authentication tag
            case 2: bytes[layout.localHeaderOffsets[1]] ^= 1
            case 3: bytes.removeLast(31) // truncated central directory / end
            default: bytes[layout.localHeaderOffsets[1] + 28] = 0xff // local extra length
            }
            XCTAssertEqual(outcomes(bytes, threads: 4, password: "KaitoFuzz"),
                           outcomes(bytes, threads: 1, password: "KaitoFuzz"), "mutation=\(mutation)")
        }
        XCTAssertEqual(outcomes(original, threads: 4, password: "wrong"),
                       outcomes(original, threads: 1, password: "wrong"))
        let reader = try ZipReader(source: DataByteSource(original), options: ReaderOptions(password: "wrong", decodeThreads: 4))
        XCTAssertThrowsError(try reader.stream(for: reader.entries[0], limits: ReadLimits())) {
            XCTAssertEqual($0 as? KaitoError, .wrongPassword)
        }
        XCTAssertNil(reader.aesKeyLookAheadForTesting)
        let truncated = try archive(truncatedEntry: 1)
        let serial = outcomes(truncated, threads: 1, password: "KaitoFuzz")
        XCTAssertEqual(outcomes(truncated, threads: 4, password: "KaitoFuzz"), serial)
        XCTAssertEqual(serial[0], .success(plain(0)))
        XCTAssertEqual(serial[1], .failure(String(describing: KaitoError.truncated)))
        XCTAssertEqual(serial[2], .success(plain(2)))
    }

    func testAutomaticThreadsUsePowerPolicyAndExplicitThreadsOverrideIt() throws {
        let bytes = try archive()
        try ReaderOptions.$testingAutomaticThreads.withValue({ policy in
            policy == .alwaysUseAllCores ? 4 : 1
        }) {
            for (policy, threads, expected) in [
                (DecodePowerPolicy.reduceInLowPowerMode, Optional<Int>.none, 0),
                (.reduceInLowPowerModeOrThermalPressure, nil, 0),
                (.alwaysUseAllCores, nil, 3), (.reduceInLowPowerMode, 4, 3)
            ] {
                let options = ReaderOptions(password: "KaitoFuzz", decodeThreads: threads, decodePowerPolicy: policy)
                let reader = try ZipReader(source: DataByteSource(bytes), options: options)
                _ = try reader.stream(for: reader.entries[0], limits: options.limits).readAll()
                XCTAssertEqual(reader.aesKeyLookAheadForTesting?.capacity ?? 0, min(expected, LeafDecodePool.shared.capacity))
            }
        }
    }

    func testSeekPasswordChangeAndReopenDiscardSpeculation() throws {
        let bytes = try archive()
        let options = ReaderOptions(password: "KaitoFuzz", decodeThreads: 4)
        let reader = try ZipReader(source: DataByteSource(bytes), options: options)
        _ = try reader.stream(for: reader.entries[0], limits: options.limits).readAll()
        XCTAssertGreaterThan(try XCTUnwrap(reader.aesKeyLookAheadForTesting).count, 0)
        _ = try reader.stream(for: reader.entries[5], limits: options.limits).readAll()
        XCTAssertEqual(reader.aesKeyLookAheadForTesting?.count, 0)
        _ = try reader.stream(for: reader.entries[6], limits: options.limits).readAll()
        reader.setPassword("wrong")
        XCTAssertNil(reader.aesKeyLookAheadForTesting)
        XCTAssertThrowsError(try reader.stream(for: reader.entries[7], limits: options.limits)) {
            XCTAssertEqual($0 as? KaitoError, .wrongPassword)
        }
        reader.setPassword("KaitoFuzz")
        _ = try reader.stream(for: reader.entries[0], limits: options.limits).readAll()
        let reopened = try XCTUnwrap(reader.reopened(options: options) as? ZipReader)
        XCTAssertNil(reopened.aesKeyLookAheadForTesting)
        XCTAssertEqual(try reopened.stream(for: reopened.entries[0], limits: options.limits).readAll(), plain(0))
    }

    func testSpeculativeKeysEnterCacheOnlyAfterAuthentication() throws {
        let original = try archive()
        let oracle = try ZipReader(source: DataByteSource(original), options: ReaderOptions())
        let layout = try XCTUnwrap(oracle.zipRawRecordLayout(at: 1, limits: ReadLimits()))
        for damaged in [false, true] {
            var bytes = original
            if damaged { bytes[Int(layout.payloadRange.upperBound) - 1] ^= 1 }
            let options = ReaderOptions(password: "KaitoFuzz", decodeThreads: 4)
            let reader = try ZipReader(source: DataByteSource(bytes), options: options)
            _ = try reader.stream(for: reader.entries[0], limits: options.limits).readAll()
            let stream = try reader.stream(for: reader.entries[1], limits: options.limits)
            XCTAssertEqual(try cachedCount(reader), 1)
            XCTAssertEqual(reader.aesKeyLookAheadForTesting?.servedCount, 1)
            if damaged {
                XCTAssertThrowsError(try stream.readAll()) { XCTAssertEqual($0 as? KaitoError, .wrongPassword) }
                XCTAssertEqual(try cachedCount(reader), 1)
            } else {
                XCTAssertEqual(try stream.readAll(), plain(1))
                XCTAssertEqual(try cachedCount(reader), 2)
            }
        }
    }

    func testChangedSaltDiscardsSpeculativeKey() throws {
        let ahead = ZipAESKeyLookAhead(workers: 4, memoryBudget: 1 << 20, passwordBytes: 9)
        let key = WinZipAESKeyCacheKey(password: "KaitoFuzz", salt: Data(repeating: 0, count: 16), strength: .aes256)
        ahead.submit(index: 1, key: key)
        let changed = WinZipAESKeyCacheKey(password: "KaitoFuzz", salt: Data(repeating: 1, count: 16), strength: .aes256)
        XCTAssertNil(try ahead.take(index: 1, key: changed))
        XCTAssertEqual(ahead.count, 0)
        XCTAssertEqual(ahead.servedCount, 0)
    }

    func testManySmall7zzEntriesAllStrengths() throws {
        // Set this to reuse the 2,000-entry benchmark archives. The ordinary
        // suite generates 128-entry archives with the same deterministic bytes.
        let supplied = ProcessInfo.processInfo.environment["KAITO_ZIP_AES_FIXTURE_DIR"]
        let directory = supplied.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("kaito-aes-\(UUID().uuidString)")
        if supplied == nil {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { if supplied == nil { try? FileManager.default.removeItem(at: directory) } }
        let count = supplied == nil ? 128 : 2000
        for bits in [128, 192, 256] {
            let url = directory.appendingPathComponent("aes\(bits).zip")
            if supplied == nil {
                try ZipTestSupport.requireExecutable(ZipTestSupport.sevenZipPath)
                let input = directory.appendingPathComponent("input\(bits)")
                try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
                for i in 0..<count {
                    try fixturePlain(i).write(to: input.appendingPathComponent(String(format: "%04d.bin", i)))
                }
                _ = try ZipTestSupport.checkedRun(ZipTestSupport.sevenZipPath,
                    arguments: ["a", "-tzip", "-mem=AES\(bits)", "-pKaitoFuzz", url.path, "."], currentDirectory: input)
            }
            let reader = try ArchiveReader.open(url: url, options: ReaderOptions(password: "KaitoFuzz", decodeThreads: 4))
            XCTAssertEqual(reader.entries.count, count)
            for (i, entry) in reader.entries.enumerated() { XCTAssertEqual(try reader.read(entry), fixturePlain(i)) }
        }
    }

    private func outcomes(_ bytes: Data, threads: Int, password: String) -> [ZipTestOutcome<Data>] {
        do {
            let reader = try ZipReader(source: DataByteSource(bytes), options: ReaderOptions(password: password, decodeThreads: threads))
            return reader.entries.map { entry in ZipTestOutcome { try reader.stream(for: entry, limits: ReadLimits()).readAll() } }
        } catch { return [.failure(String(describing: error))] }
    }

    private func plain(_ i: Int) -> Data { Data((0..<(i + 1)).map { UInt8(truncatingIfNeeded: $0 + i) }) }
    private func cachedCount(_ reader: ZipReader) throws -> Int {
        try XCTUnwrap(Mirror(reflecting: reader).children.first { $0.label == "aesDerivedKeyCache" }?.value
            as? [WinZipAESKeyCacheKey: WinZipAESDerivedKeys]).count
    }
    private func fixturePlain(_ i: Int) -> Data { Data((0..<127).map { UInt8(truncatingIfNeeded: $0 * 29 + i) }) }
    private func archive(truncatedEntry: Int? = nil) throws -> Data {
        let entries = try (0..<16).map { i -> HandZipEntry in
            let strength = WinZipAESStrength.aes256
            let salt = Data((0..<16).map { UInt8(truncatingIfNeeded: i * 17 + $0) })
            let keys = try WinZipAESDerivedKeys.derive(for: WinZipAESKeyCacheKey(password: "KaitoFuzz", salt: salt, strength: strength))
            var ctr = try WinZipAESCTR(encryptionKey: keys.encryptionKey)
            let ciphertext = try ctr.transform(plain(i))
            let tag = Data(CommonCryptoPrimitives.hmacSHA1(data: ciphertext, key: keys.authenticationKey).prefix(10))
            let extra = try ZipTestSupport.extraField(identifier: 0x9901, payload: Data([2, 0, 65, 69, 3, 0, 0]))
            let payload = salt + keys.passwordVerifier + ciphertext + tag
            return HandZipEntry(name: "entry-\(i)", uncompressedData: plain(i),
                compressedData: i == truncatedEntry ? Data(payload.prefix(12)) : payload, method: 99, flags: 0x0801,
                localExtra: extra, centralExtra: extra, centralCRC32: 0, localCRC32: 0)
        }
        return try ZipTestSupport.makeArchive(entries: entries)
    }
}
