import Foundation
import Synchronization
@testable import KaitoKit
import XCTest

final class SevenZipEntryKDFTests: XCTestCase {
    private let plaintext = Data("Kaito KDF test!\n".utf8)

    private func reader(_ fixture: String = "distinct", limits: ReadLimits = ReadLimits()) throws -> SevenZipReader {
        try SevenZipReader(source: DataByteSource(TestFixtures.base64("sevenzip-kdf/\(fixture).7z")),
                           options: ReaderOptions(limits: limits, password: "anypw"))
    }

    private func exhaustedArchiveReader() throws -> ArchiveReader {
        let limits = ReadLimits(maxSevenZipEntryKDFWork: 2 * (UInt64(1) << 8))
        let reader = try ArchiveReader.open(data: TestFixtures.base64("sevenzip-kdf/distinct.7z"),
                                            options: ReaderOptions(limits: limits, password: "anypw"))
        // stream() ごとの preparePassword を通し、同じ password で予算が戻らないことも検査する。
        for entry in reader.entries.prefix(2) {
            XCTAssertEqual(try reader.stream(entry).readAll(), plaintext)
        }
        XCTAssertThrowsError(try reader.stream(reader.entries[2])) {
            XCTAssertEqual($0 as? KaitoError, .limitExceeded("7z entry KDF work"))
        }
        return reader
    }

    func testEntryKDFDefaultBudgetStopsBeforeDistinctSaltMiss() throws {
        let reader = try reader()
        let budget = ReadLimits().maxSevenZipEntryKDFWork
        XCTAssertEqual(budget, 16 * (1 << 24))
        // 既に消費した仕事を模擬する。残り 4 回分は実際の低 cycles fixture で使い切る。
        try reader.entryKDFBudget.charge(budget - 4 * 256)
        let derivations = Mutex(0)
        try SevenZipAESKeyCache.$didDeriveKey.withValue({ derivations.withLock { $0 += 1 } }) {
            for entry in reader.entries.prefix(4) {
                XCTAssertEqual(try reader.stream(for: entry, limits: ReadLimits()).readAll(), plaintext)
            }
            XCTAssertThrowsError(try reader.stream(for: reader.entries[4], limits: ReadLimits())) {
                XCTAssertEqual($0 as? KaitoError, .limitExceeded("7z entry KDF work"))
            }
        }
        XCTAssertEqual(derivations.withLock { $0 }, 4)
    }

    func testEntryKDFCallerCanRaiseLimit() throws {
        for count in [32, 33] {
            let limits = ReadLimits(maxSevenZipEntryKDFWork: UInt64(count * 256))
            let reader = try reader(limits: limits)
            for entry in reader.entries.prefix(32) {
                XCTAssertEqual(try reader.stream(for: entry, limits: limits).readAll(), plaintext)
            }
            if count == 33 {
                XCTAssertEqual(try reader.stream(for: reader.entries[32], limits: limits).readAll(), plaintext)
            } else {
                XCTAssertThrowsError(try reader.stream(for: reader.entries[32], limits: limits)) {
                    XCTAssertEqual($0 as? KaitoError, .limitExceeded("7z entry KDF work"))
                }
            }
        }
    }

    func testEntryKDFListingIsFreeAndCacheHitsAreFree() throws {
        let derivations = Mutex(0)
        try SevenZipAESKeyCache.$didDeriveKey.withValue({ derivations.withLock { $0 += 1 } }) {
            XCTAssertEqual(try reader(limits: ReadLimits(maxSevenZipEntryKDFWork: 0)).entries.count, 33)
            XCTAssertEqual(derivations.withLock { $0 }, 0)
            let limits = ReadLimits(maxSevenZipEntryKDFWork: 256)
            let reader = try reader("shared", limits: limits)
            for _ in 0..<2 {
                for entry in reader.entries {
                    XCTAssertEqual(try reader.stream(for: entry, limits: limits).readAll(), plaintext)
                }
            }
            XCTAssertEqual(derivations.withLock { $0 }, 1)
        }
    }

    func testEntryKDFBudgetIsSharedWithPackedSPI() throws {
        let limits = ReadLimits(maxSevenZipEntryKDFWork: 256)
        let reader = try reader(limits: limits)
        XCTAssertEqual(try reader.decryptedPackedStream(folder: 0, packedInput: 0).readAll(), plaintext)
        XCTAssertEqual(try reader.stream(for: reader.entries[0], limits: limits).readAll(), plaintext)
        XCTAssertThrowsError(try reader.decryptedPackedStream(folder: 1, packedInput: 0)) {
            XCTAssertEqual($0 as? KaitoError, .limitExceeded("7z entry KDF work"))
        }
    }

    func testEntryKDFBudgetAccumulatesAcrossEntryStreams() throws {
        _ = try exhaustedArchiveReader()
    }

    func testEntryKDFBudgetResetsForDifferentPassword() throws {
        let reader = try exhaustedArchiveReader()
        let derivations = Mutex(0)
        reader.password = "other"
        try SevenZipAESKeyCache.$didDeriveKey.withValue({ derivations.withLock { $0 += 1 } }) {
            let stream = try reader.stream(reader.entries[2])
            XCTAssertThrowsError(try stream.readAll()) {
                XCTAssertEqual($0 as? KaitoError, .wrongPassword)
            }
        }
        XCTAssertEqual(derivations.withLock { $0 }, 1)
        reader.password = "anypw"
        XCTAssertEqual(try reader.stream(reader.entries[2]).readAll(), plaintext)
    }

    func testEntryKDFBudgetDoesNotResetForSamePassword() throws {
        let reader = try exhaustedArchiveReader()
        reader.password = "anypw"
        XCTAssertThrowsError(try reader.stream(reader.entries[2])) {
            XCTAssertEqual($0 as? KaitoError, .limitExceeded("7z entry KDF work"))
        }
    }

    func testEntryKDFBudgetIsFullOnReopen() throws {
        let reader = try exhaustedArchiveReader()
        let reopened = try reader.reopen()
        for entry in reopened.entries.prefix(2) {
            XCTAssertEqual(try reopened.stream(entry).readAll(), plaintext)
        }
        for archive in [reader, reopened] {
            XCTAssertThrowsError(try archive.stream(archive.entries[2])) {
                XCTAssertEqual($0 as? KaitoError, .limitExceeded("7z entry KDF work"))
            }
        }
    }

    func testEntryKDFDerivationObservesCancellation() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let properties = try SevenZipAESProperties(bytes: [0x88, 0, 1], maximumCyclesPower: 24)
            return try SevenZipAESKeyCache().key(password: "anypw", properties: properties)
        }
        do { _ = try await task.value; XCTFail("cancelled derivation succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testEntryKDFDerivationOutsideTask() throws {
        XCTAssertTrue(withUnsafeCurrentTask { $0 == nil })
        let reader = try reader(limits: ReadLimits(maxSevenZipEntryKDFWork: 256))
        XCTAssertEqual(try reader.stream(for: reader.entries[0], limits: ReadLimits()).readAll(), plaintext)
    }

    func testKeyCacheEvictionRechargesAndDirectKeysStayFree() throws {
        let cache = SevenZipAESKeyCache()
        let budget = KDFWorkBudget(limit: UInt64(SevenZipAESKeyCache.capacity * 256), subject: "test KDF work")
        func properties(_ salt: UInt8, power: UInt8 = 8) throws -> SevenZipAESProperties {
            try SevenZipAESProperties(bytes: [0x80 | power, 0] + [salt], maximumCyclesPower: 24)
        }
        for index in 0..<SevenZipAESKeyCache.capacity {
            _ = try cache.key(password: "p", properties: properties(UInt8(index)), chargeKDFWork: budget.charge)
        }
        // direct key も保持上限を共有するが SHA-256 の予算は使わない。
        _ = try cache.key(password: "p", properties: properties(255, power: 63), chargeKDFWork: budget.charge)
        XCTAssertThrowsError(try cache.key(password: "p", properties: properties(0), chargeKDFWork: budget.charge)) {
            XCTAssertEqual($0 as? KaitoError, .limitExceeded("test KDF work"))
        }
    }
}
