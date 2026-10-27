import Foundation
@testable import KaitoKit
import XCTest

final class RAR5EntryKDFTests: XCTestCase {
    private let password = String(repeating: "e\u{301}", count: 65)
    private let plaintext = Data("KaitoKit full UTF-8 password compatibility\n".utf8)

    private func reader(limit: UInt64 = 66) throws -> ArchiveReader {
        try ArchiveReader.open(data: TestFixtures.base64("rar5/password-full-p.rar"),
                               options: ReaderOptions(limits: ReadLimits(maxRAR5EntryKDFWork: limit),
                                                      password: password))
    }

    func testEntryKDFBudgetAccumulatesAcrossDistinctSaltsAndCacheHitsAreFree() throws {
        let reader = try reader()
        // 最初の salt は 127 scalar 候補と full UTF-8 候補の二回（count 0）を要する。
        for _ in 0..<2 { XCTAssertEqual(try reader.read(reader.entries[0]), plaintext) }
        XCTAssertThrowsError(try reader.read(reader.entries[1])) {
            XCTAssertEqual($0 as? KaitoError, .limitExceeded("RAR5 entry KDF work"))
        }
        let raised = try self.reader(limit: 99)
        for entry in raised.entries { XCTAssertEqual(try raised.read(entry), plaintext) }
        let zero = try self.reader(limit: 0)
        XCTAssertEqual(zero.entries.count, 2)
        XCTAssertThrowsError(try zero.read(zero.entries[0])) {
            XCTAssertEqual($0 as? KaitoError, .limitExceeded("RAR5 entry KDF work"))
        }
    }

    func testEntryKDFBudgetResetsOnlyForDifferentPassword() throws {
        let reader = try reader()
        XCTAssertEqual(try reader.read(reader.entries[0]), plaintext)
        reader.password = password
        XCTAssertThrowsError(try reader.read(reader.entries[1])) {
            XCTAssertEqual($0 as? KaitoError, .limitExceeded("RAR5 entry KDF work"))
        }
        reader.password = "wrong"
        for entry in reader.entries {
            for _ in 0..<2 {
                XCTAssertThrowsError(try reader.read(entry)) {
                    XCTAssertEqual($0 as? KaitoError, .wrongPassword)
                }
            }
        }
        reader.password = password
        XCTAssertEqual(try reader.read(reader.entries[1]), plaintext)
    }

    func testSolidEntriesShareReaderBudget() throws {
        let bytes = try TestFixtures.base64("rar5/password-full-p.rar")
        let original = try RAR5Reader(source: DataByteSource(bytes), options: ReaderOptions(password: password))
        let layouts = try RAR5TestSupport.blockLayouts(in: Array(bytes)).filter { !$0.data.isEmpty }
        let blocks = try zip(original.recordsForTesting, layouts).enumerated().map { index, pair in
            let (record, layout) = pair
            let encryption = try XCTUnwrap(record.encryption)
            let extra = RAR5TestSupport.extraRecord(type: 1, payload:
                [0, 1, encryption.kdfCount] + encryption.salt + encryption.initializationVector
                    + (encryption.checkValue ?? []))
            return RAR5TestSupport.storedFile(name: "file\(index)", contents: bytes.subdata(in: layout.data),
                unpackedSize: UInt64(plaintext.count), dataCRC32: CRC32.checksum(plaintext),
                compressionInfo: index == 0 ? 0 : 0x40, extra: extra)
        }
        let reader = try ArchiveReader.open(data: RAR5TestSupport.archive(mainFlags: 0x0004, blocks: blocks), options: ReaderOptions(
            limits: ReadLimits(maxRAR5EntryKDFWork: 66), password: password))
        XCTAssertGreaterThanOrEqual(reader.entries[0].solidGroup, 0)
        XCTAssertEqual(reader.entries[0].solidGroup, reader.entries[1].solidGroup)
        XCTAssertEqual(try reader.read(reader.entries[0]), plaintext)
        XCTAssertThrowsError(try reader.read(reader.entries[1])) {
            XCTAssertEqual($0 as? KaitoError, .limitExceeded("RAR5 entry KDF work"))
        }
    }

    func testEntryKDFBudgetIsFullOnReopen() throws {
        let reader = try reader()
        XCTAssertEqual(try reader.read(reader.entries[0]), plaintext)
        let reopened = try reader.reopen()
        XCTAssertEqual(try reopened.read(reopened.entries[1]), plaintext)
        XCTAssertThrowsError(try reader.read(reader.entries[1])) {
            XCTAssertEqual($0 as? KaitoError, .limitExceeded("RAR5 entry KDF work"))
        }
        // reopen は full UTF-8 の選択も引き継ぐため、各 salt は一回分で済む。
        XCTAssertEqual(try reopened.read(reopened.entries[0]), plaintext)
    }

    func testPasswordChangeUsesUTF8Spelling() throws {
        let nfc = "\u{E9}x", nfd = "e\u{301}x"
        var bytes = [UInt8](try TestFixtures.base64("rar5/password-full-p.rar"))
        let original = try RAR5Reader(source: DataByteSource(Data(bytes)), options: ReaderOptions(password: password))
        let layouts = try RAR5TestSupport.blockLayouts(in: bytes).filter { !$0.data.isEmpty }
        for (record, layout) in zip(original.recordsForTesting, layouts) {
            let encryption = try XCTUnwrap(record.encryption)
            let keys = try RAR5KeyDerivation.derive(password: nfc, salt: encryption.salt, count: encryption.kdfCount)
            let check = try XCTUnwrap(RAR5TestSupport.fileEncryptionCheckRange(in: bytes, layout: layout))
            bytes.replaceSubrange(check, with: keys.passwordCheckValue)
            var padded = Array(plaintext)
            padded += repeatElement(0, count: layout.data.count - padded.count)
            var previous = encryption.initializationVector, ciphertext: [UInt8] = []
            for offset in stride(from: 0, to: padded.count, by: 16) {
                let block = zip(padded[offset..<offset + 16], previous).map { $0 ^ $1 }
                previous = try CommonCryptoPrimitives.aesECBEncrypt(blocks: block, key: keys.encryptionKey)
                ciphertext += previous
            }
            bytes.replaceSubrange(layout.data, with: ciphertext)
            RAR5TestSupport.repairHeaderCRC(&bytes, layout: layout)
        }
        let reader = try ArchiveReader.open(data: Data(bytes), options: ReaderOptions(
            limits: ReadLimits(maxRAR5EntryKDFWork: 33), password: nfd))
        XCTAssertThrowsError(try reader.read(reader.entries[0])) {
            XCTAssertEqual($0 as? KaitoError, .wrongPassword)
        }
        reader.password = nfc
        XCTAssertEqual(try reader.read(reader.entries[0]), plaintext)
    }

    func testCancelledEntryDerivationRefundsBudgetForSameReaderAndPassword() async throws {
        let archive = try TestFixtures.base64("rar5/password-full-p.rar")
        let password = password
        let task = Task {
            let reader = try ArchiveReader.open(data: archive, options: ReaderOptions(
                limits: ReadLimits(maxRAR5EntryKDFWork: 66), password: password))
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try reader.stream(reader.entries[0])
                XCTFail("cancelled derivation succeeded")
            } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            return try await Task.detached { try reader.read(reader.entries[0]) }.value
        }
        let result = try await task.value
        XCTAssertEqual(result, plaintext)
    }
}
