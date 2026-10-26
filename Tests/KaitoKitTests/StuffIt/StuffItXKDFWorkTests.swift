import Foundation
@testable import KaitoKit
import XCTest

final class StuffItXKDFWorkTests: XCTestCase {
    typealias Writer = StuffItXContainerTests.Writer

    private func catalogArchive(length: Int) -> Data {
        var w = Writer(data: Data("StuffIt!".utf8)); w.element(7, extra: 5)
        let algorithms: [(UInt64, UInt64, UInt64?)] = stride(from: 0, to: length, by: 1_024).map {
            (4, 3, UInt64(min(1_024, length - $0)))
        }
        w.element(5, [(5, 0)], algorithms); w.frames([]); w.frames([]); w.element(0)
        return w.data
    }

    private func entryArchive(length: UInt64 = 16, encryptedCatalog: Bool = false) throws -> Data {
        var w = Writer(data: Data("StuffIt!".utf8)); w.element(7, extra: 5)
        for id: UInt64 in [1, 2] { w.element(2, [(1, id), (2, 0)]) }
        var catalog = Writer()
        for name in ["a", "b"] { catalog.p2(1); catalog.string(Data(name.utf8)); catalog.p2(0); catalog.align() }
        let ciphers: [(UInt64, UInt64)] = [(3, length)]
        let algorithms: [(UInt64, UInt64, UInt64?)] = [(4, 3, length)]
        w.element(5, [(5, UInt64(catalog.data.count))], encryptedCatalog ? algorithms : [])
        w.frames([encryptedCatalog ? Data(try StuffItXCryptoTests.seal(Array(catalog.data), ciphers: ciphers)) : catalog.data])
        w.frames([])
        for id: UInt64 in [1, 2] {
            w.element(3, [(2, id), (3, id + 10), (4, 0), (5, 1)], extra: 0)
            w.element(1, [(1, id + 10), (5, 1)], algorithms)
            w.frames([Data(try StuffItXCryptoTests.seal([65], ciphers: ciphers))]); w.frames([])
        }
        w.element(0); return w.data
    }

    func testMaximumAcceptedKeyLengthIsRejectedBeforeDerivation() throws {
        let data = catalogArchive(length: 65_536)
        XCTAssertEqual(data, try TestFixtures.base64("stuffitx-kdf/catalog65536.sitx"))
        XCTAssertEqual(try StuffItXCrypto.validate(StuffItXCryptoTests.records(Array(repeating: (3, 1_024), count: 64))), 65_536)
        XCTAssertThrowsError(try ArchiveReader.open(data: data, options: ReaderOptions(password: "x"))) {
            XCTAssertEqual($0 as? KaitoError, .limitExceeded("StuffIt X KDF work"))
        }
        XCTAssertThrowsError(try ArchiveReader.open(data: data)) {
            XCTAssertEqual($0 as? KaitoError, .passwordRequired)
        }
        let limit = ReadLimits().maxStuffItXKDFWork
        XCTAssertEqual(limit, 1 << 22)
        XCTAssertLessThanOrEqual(try StuffItXCrypto.work(passwordLength: 1, keyLength: 4_032), limit)
        XCTAssertGreaterThan(try StuffItXCrypto.work(passwordLength: 1, keyLength: 4_033), limit)
        XCTAssertGreaterThan(try StuffItXCrypto.work(passwordLength: 1, keyLength: 4_096), limit)
        XCTAssertGreaterThan(try StuffItXCrypto.work(passwordLength: 1, keyLength: 8_192), limit)
    }

    func testLargerDerivationRequiresEnoughCallerBudget() throws {
        let data = try entryArchive(length: 128)
        let work = try StuffItXCrypto.work(passwordLength: 8, keyLength: 128)
        for limit in [work - 1, work] {
            let reader = try ArchiveReader.open(data: data, options: ReaderOptions(
                limits: ReadLimits(maxStuffItXKDFWork: limit), password: "password"))
            if limit == work { XCTAssertEqual(try reader.read(reader.entries[0]), Data([65])) }
            else {
                XCTAssertThrowsError(try reader.read(reader.entries[0])) {
                    XCTAssertEqual($0 as? KaitoError, .limitExceeded("StuffIt X KDF work"))
                }
            }
        }
    }

    func testMaximumEntryKeyListsWithoutDerivingAndFailsOnRead() throws {
        var w = Writer(data: Data("StuffIt!".utf8)); w.element(7, extra: 5)
        w.element(2, [(1, 1), (2, 0)])
        var catalog = Writer(); catalog.p2(1); catalog.string(Data("a".utf8)); catalog.p2(0); catalog.align()
        w.element(5, [(5, UInt64(catalog.data.count))]); w.frames([catalog.data]); w.frames([])
        w.element(3, [(2, 1), (3, 10), (4, 0), (5, 1)], extra: 0)
        w.element(1, [(1, 10), (5, 1)], Array(repeating: (4, 3, 1_024), count: 64))
        w.frames([]); w.frames([]); w.element(0)
        let reader = try ArchiveReader.open(data: w.data)
        XCTAssertEqual(reader.entries.count, 1)
        XCTAssertThrowsError(try reader.read(reader.entries[0])) {
            XCTAssertEqual($0 as? KaitoError, .passwordRequired)
        }
        reader.password = "x"
        XCTAssertThrowsError(try reader.read(reader.entries[0])) {
            XCTAssertEqual($0 as? KaitoError, .limitExceeded("StuffIt X KDF work"))
        }
    }

    func testReaderBudgetIsSharedAcrossStreamsAndPasswordChanges() throws {
        let data = try entryArchive()
        let work = try StuffItXCrypto.work(passwordLength: 8, keyLength: 16)
        let reader = try ArchiveReader.open(data: data, options: ReaderOptions(
            limits: ReadLimits(maxStuffItXKDFWork: work), password: "password"))
        XCTAssertEqual(try reader.read(reader.entries[0]), Data([65]))
        XCTAssertEqual(try reader.read(reader.entries[0]), Data([65]))
        XCTAssertThrowsError(try reader.read(reader.entries[1])) {
            XCTAssertEqual($0 as? KaitoError, .limitExceeded("StuffIt X KDF work"))
        }
        reader.password = "new"
        XCTAssertThrowsError(try reader.read(reader.entries[0])) {
            XCTAssertEqual($0 as? KaitoError, .limitExceeded("StuffIt X KDF work"))
        }
    }

    func testCatalogAndEntryShareReaderBudget() throws {
        let data = try entryArchive(encryptedCatalog: true)
        let work = try StuffItXCrypto.work(passwordLength: 8, keyLength: 16)
        for limit in [work, 2 * work] {
            let reader = try ArchiveReader.open(data: data, options: ReaderOptions(
                limits: ReadLimits(maxStuffItXKDFWork: limit), password: "password"))
            XCTAssertEqual(reader.entries.count, 2)
            if limit == 2 * work { XCTAssertEqual(try reader.read(reader.entries[0]), Data([65])) }
            else {
                XCTAssertThrowsError(try reader.read(reader.entries[0])) {
                    XCTAssertEqual($0 as? KaitoError, .limitExceeded("StuffIt X KDF work"))
                }
            }
        }
    }

    func testWorkMatchesObservedContinuingMD5BlockCount() throws {
        func observed(_ password: [UInt8], length: Int) -> (UInt64, [UInt8]) {
            var state = StuffItXContinuingMD5(), source = password, work: UInt64 = 0
            let rounded = (length + 15) & ~15
            for _ in 0..<256 {
                var output: [UInt8] = []
                for offset in stride(from: 0, to: rounded, by: 16) {
                    let before = state.byteCount / 64
                    state.absorb("StuffIt".utf8); state.absorb([UInt8(offset >> 8), UInt8(truncatingIfNeeded: offset)])
                    state.absorb(source); output += state.snapshot()
                    work += state.byteCount / 64 - before + 1
                }
                source = output
            }
            return (work, Array(source.prefix(length)))
        }
        for passwordLength in [0, 8, 47, 48, 55, 56, 64, 128] {
            for length in [1, 16, 17, 64, 81] {
                let (materialWork, material) = observed(Array(repeating: 65, count: passwordLength), length: length)
                let (verifierWork, _) = observed(material, length: 2)
                XCTAssertEqual(try StuffItXCrypto.work(passwordLength: passwordLength, keyLength: length), materialWork + verifierWork)
            }
        }
    }

    func testDerivationObservesCancellation() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try StuffItXCrypto.derive([65], length: 16)
        }
        do { _ = try await task.value; XCTFail("cancelled derivation succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
