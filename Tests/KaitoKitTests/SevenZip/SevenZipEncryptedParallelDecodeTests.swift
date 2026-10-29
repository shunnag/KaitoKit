import Foundation
private import CommonCrypto
import Synchronization
@testable import KaitoKit
import XCTest

final class SevenZipEncryptedParallelDecodeTests: XCTestCase {
    private struct Outcome: Equatable {
        var bytes = Data()
        var error: KaitoError?
    }

    // 既存 vector の packed byte を CommonCrypto の黒箱で暗号化する。
    // cycle power 63 は password の UTF-16LE byte を直接 key に置く既存の試験用経路。
    private func encrypted(_ plain: SevenZipParallelTestSupport.Fixture) throws -> SevenZipParallelTestSupport.Fixture {
        var fixture = plain
        fixture.aesPlaintextSize = UInt64(plain.packed.count)
        var input = plain.packed
        input.append(Data(repeating: 0, count: (16 - input.count % 16) % 16))
        var key = Data("secret".utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] })
        key.append(Data(repeating: 0, count: 32 - key.count))
        var output = Data(count: input.count), written = 0
        let status = output.withUnsafeMutableBytes { destination in
            input.withUnsafeBytes { source in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                        keyBytes.baseAddress, key.count, nil, source.baseAddress, input.count,
                        destination.baseAddress, destination.count, &written)
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess)); XCTAssertEqual(written, input.count)
        fixture.packed = output
        return fixture
    }

    private func outcome(_ archive: Data, threads: Int?, password: String = "secret", chunk: Int) -> Outcome {
        var result = Outcome(), buffer = [UInt8](repeating: 0, count: chunk)
        do {
            let reader = try ArchiveReader.open(data: archive, options: ReaderOptions(password: password, decodeThreads: threads))
            for entry in reader.entries {
                let stream = try reader.stream(entry)
                while true {
                    let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
                    if count == 0 { break }
                    result.bytes.append(contentsOf: buffer.prefix(count))
                }
            }
        } catch {
            XCTAssertTrue(error is KaitoError, "\(error)")
            result.error = error as? KaitoError
        }
        return result
    }

    func testEncryptedResetUnitsUseWorkersAndMatchSerialAndAutomatic() throws {
        for plain in [try SevenZipParallelTestSupport.compressed(), SevenZipParallelTestSupport.raw()] {
            let fixture = try encrypted(plain)
            let diagnostics = ParallelIndependentDecompressor.Diagnostics()
            let factory = try fixture.factory(workers: 8, diagnostics: diagnostics)
            XCTAssertEqual(try factory.parallelUnits()?.count, fixture.payloads.count)
            XCTAssertTrue(try factory.makeDecoder() is ParallelIndependentDecompressor)
            XCTAssertEqual(try factory.decodeAll(limit: 1 << 20), fixture.output)
            XCTAssertGreaterThan(diagnostics.peakWorkers, 0)
            let submissions = Mutex(0)
            ReaderOptions.$testingAutomaticThreads.withValue({ _ in 8 }) {
                for threads: Int? in [1, nil] {
                    submissions.withLock { $0 = 0 }
                    LeafDecodePool.$testingSubmission.withValue({ submissions.withLock { $0 += 1 } }) {
                        let result = outcome(fixture.archive(), threads: threads, chunk: 65_537)
                        XCTAssertNil(result.error); XCTAssertEqual(result.bytes, fixture.output)
                    }
                    XCTAssertEqual(submissions.withLock { $0 }, threads == 1 ? 0 : fixture.payloads.count - 1)
                }
            }
        }
    }

    func testWrongPasswordScanFallsBackToIdenticalSerialError() throws {
        let fixture = try encrypted(SevenZipParallelTestSupport.compressed())
        XCTAssertNil(try fixture.factory(workers: 8, password: "wrong").makeDictionaryResetIndex())
        XCTAssertTrue(try fixture.factory(workers: 8, password: "wrong").makeDecoder() is LZMA2Decoder)
        for chunk in [1, 7, 65_537, 262_144] {
            let serial = outcome(fixture.archive(), threads: 1, password: "wrong", chunk: chunk)
            XCTAssertEqual(serial.error, .wrongPassword)
            for threads: Int? in [nil, 8] {
                XCTAssertEqual(outcome(fixture.archive(), threads: threads, password: "wrong", chunk: chunk), serial)
            }
        }
    }

    func testCorruptionAndTruncationPreserveErrorAndPartialBytes() throws {
        let first = Data(repeating: 65, count: 65_003), prefix = Data(repeating: 66, count: 65_019)
        var compressed = try Hex.data("e00011000800003099abddc0cb070000")
        compressed.removeLast(); compressed[0] = 0xC0; compressed[6] = 1
        let last = Data(repeating: 67, count: 65_021)
        let plain = SevenZipParallelTestSupport.Fixture(
            packed: SevenZipParallelTestSupport.rawUnit(first) + SevenZipParallelTestSupport.rawUnit(prefix)
                + compressed + SevenZipParallelTestSupport.rawUnit(last) + Data([0]),
            payloads: [first, prefix + Data("abcabcabcabcabcabc".utf8), last])
        let corrupt = try encrypted(plain)
        XCTAssertTrue(try corrupt.factory(workers: 8).makeDecoder() is ParallelIndependentDecompressor)
        var malformed = plain
        malformed.packed[first.count + 3] = 3
        var truncated = plain
        truncated.packed.removeLast(32)
        var ciphertext = try encrypted(SevenZipParallelTestSupport.raw())
        ciphertext.packed[ciphertext.packed.count / 2] ^= 0x80
        var shortCiphertext = corrupt
        shortCiphertext.packed.removeLast(16)
        for fixture in [corrupt, try encrypted(malformed), try encrypted(truncated), ciphertext, shortCiphertext] {
            for chunk in [1, 7, 65_537, 262_144] {
                let serial = outcome(fixture.archive(), threads: 1, chunk: chunk)
                XCTAssertNotNil(serial.error)
                XCTAssertEqual(outcome(fixture.archive(), threads: nil, chunk: chunk), serial)
                XCTAssertEqual(outcome(fixture.archive(), threads: 8, chunk: chunk), serial)
                if fixture.packed == corrupt.packed { XCTAssertGreaterThanOrEqual(serial.bytes.count, first.count) }
            }
        }
    }

    func testBackwardSeekUsesDecryptedResetPointsAndFiltersKeepHeadRestart() throws {
        var plain = SevenZipParallelTestSupport.raw(); plain.folderCRC = nil
        let fixture = try encrypted(plain)
        for high in [false, true] {
            for workers in [1, 8] {
                let factory = try fixture.factory(workers: workers, avoidsHeaderScans: high)
                let coordinator = SevenZipFolderCoordinator(factory: factory)
                for index in [3, 1] {
                    let offset = UInt64(fixture.payloads.prefix(index).reduce(0) { $0 + $1.count })
                    XCTAssertEqual(try drain(coordinator.stream(offset: offset, length: UInt64(fixture.payloads[index].count)),
                        bufferSize: 65_537), fixture.payloads[index])
                }
                XCTAssertEqual(coordinator.lastBackwardRestart, workers == 8 && !high ? .fullIndex : .observed)
            }
        }
        // filter は unit の後で一つの直列 stream を包む。後方 seek の状態は共有しない。
        plain.filters = [([3], [0])]
        let filtered = try encrypted(plain)
        let factory = try filtered.factory(workers: 8)
        XCTAssertNil(try factory.makeDictionaryResetIndex())
        XCTAssertEqual(try factory.parallelUnits()?.count, plain.payloads.count)
        XCTAssertEqual(try factory.decodeAll(limit: 1 << 20),
                       try filtered.factory(workers: 1).decodeAll(limit: 1 << 20))
        XCTAssertNil(try factory.backwardRestartPoint(atOrBefore: 100_000))
    }

    func testAESBuffersCountAgainstParallelMemoryAndPasswordChangeDropsUnits() throws {
        let plain = SevenZipParallelTestSupport.raw(), fixture = try encrypted(plain)
        let units = try XCTUnwrap(fixture.factory(workers: 8).parallelUnits())
        let plainUnits = try XCTUnwrap(plain.factory(workers: 8).parallelUnits())
        XCTAssertEqual(units[0].heldBytes - plainUnits[0].heldBytes, AESCBCRandomAccess.scratchBytes)
        let maximum = try XCTUnwrap(units.map(\.heldBytes).max())
        for budget in [maximum * 3 - 1, maximum * 3] {
            let diagnostics = ParallelIndependentDecompressor.Diagnostics()
            let factory = try fixture.factory(workers: 8,
                limits: ReadLimits(parallelDecodeMemory: UInt64(budget)), diagnostics: diagnostics)
            XCTAssertEqual(try factory.makeDecoder() is ParallelIndependentDecompressor, budget == maximum * 3)
            XCTAssertEqual(try factory.decodeAll(limit: 1 << 20), fixture.output)
            XCTAssertLessThanOrEqual(diagnostics.peakHeldBytes, budget)
        }
        let reader = try ArchiveReader.open(data: fixture.archive(), options: ReaderOptions(password: "secret", decodeThreads: 8))
        XCTAssertEqual(try reader.read(reader.entries[0]), fixture.payloads[0])
        reader.password = "wrong"
        XCTAssertThrowsError(try reader.read(reader.entries[0])) { XCTAssertEqual($0 as? KaitoError, .wrongPassword) }
        reader.password = "secret"
        XCTAssertEqual(try reader.read(reader.entries[1]), fixture.payloads[1])
    }
    func testFrozenSevenZipCorpusMutationsMatchSerialErrorsAndPartialOutput() throws {
        let urls = try SevenZipGoldenCorpus.archives()
        XCTAssertEqual(urls.count, 33)
        var cases = 0
        for url in urls {
            let original = try Data(contentsOf: url)
            let nextOffset = (0..<8).reduce(UInt64(0)) { $0 | UInt64(original[12 + $1]) << ($1 * 8) }
            let span = min(original.count - 32, Int(nextOffset))
            guard span > 0 else { continue }
            var candidates: [Data] = []
            for position in Set([32, 32 + span / 2, 32 + span - 1]).sorted() {
                var candidate = original
                candidate[position] ^= 0x80
                candidates.append(candidate)
            }
            candidates.append(Data(original.dropLast(min(17, original.count - 32))))
            for password in url.lastPathComponent == "mix.7z" ? ["secret", "secret2"] : ["secret"] {
                for candidate in candidates {
                    for chunk in [7, 65_537] {
                        let serial = outcome(candidate, threads: 1, password: password, chunk: chunk)
                        for threads: Int? in [nil, 8] {
                            XCTAssertEqual(outcome(candidate, threads: threads, password: password, chunk: chunk), serial,
                                "\(url.lastPathComponent) chunk=\(chunk) threads=\(String(describing: threads))")
                        }
                    }
                    cases += 1
                }
            }
        }
        XCTAssertGreaterThan(cases, 100)
        print("7Z-CORRUPT corpus=Tests/Fixtures/sevenzip-edit archives=\(urls.count) mutations/passwords=\(cases) comparisons=\(cases * 4)")
    }

}
