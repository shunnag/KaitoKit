import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

final class RAR5RecoveryTests: XCTestCase {
    private let recovery = ReaderOptions(recoverDamagedArchives: true)
    private let intactDigest = "6e52d167ea72ee81982ae496592b9bd63e87005c46a4752dad1c2c47dcd8a0a1"

    private func fixture() throws -> Data {
        try decodeFixture(ZipTestSupport.repositoryRoot.appendingPathComponent(
            "Tests/Fixtures/rar/rar5-recovery.rar.b64"
        ))
    }

    private func decodeFixture(_ url: URL) throws -> Data {
        try XCTUnwrap(Data(
            base64Encoded: String(contentsOf: url, encoding: .utf8),
            options: .ignoreUnknownCharacters
        ))
    }

    private func digest(_ payloads: [Data]) -> String {
        let concatenated = payloads.map {
            SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
        }.joined()
        return SHA256.hash(data: Data(concatenated.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    func testIntactFixtureIsIdenticalWithRecoveryOnAndOff() throws {
        let archive = try fixture()
        XCTAssertEqual(archive.count, 701)
        let strict = try ArchiveReader.open(data: archive)
        let recovered = try ArchiveReader.open(data: archive, options: recovery)
        XCTAssertEqual(strict.entries, recovered.entries)
        XCTAssertEqual(strict.entries.map(\.name), ["one.txt", "two.txt", "tail.bin"])
        XCTAssertTrue(strict.entries.allSatisfy { !$0.isIncomplete })
        let payloads = try strict.entries.map { try strict.read($0) }
        XCTAssertEqual(payloads.map(\.count), [33, 33, 512])
        XCTAssertEqual(try recovered.entries.map { try recovered.read($0) }, payloads)
        XCTAssertEqual(digest(payloads), intactDigest)
    }

    func testFourTruncationPointsMatchMeasuredOracle() throws {
        let archive = try fixture()
        let intact = try ArchiveReader.open(data: archive)
        let originals = try intact.entries.map { try intact.read($0) }
        for (cut, sizes, incomplete) in [
            (693, [33, 33, 512], [false, false, false]),
            (400, [33, 33, 219], [false, false, true]),
            (160, [33, 33], [false, false]),
            (130, [33, 0], [false, true]),
        ] {
            let reader = try ArchiveReader.open(data: Data(archive.prefix(cut)), options: recovery)
            XCTAssertEqual(reader.entries.count, sizes.count, "cut=\(cut)")
            XCTAssertEqual(reader.entries.map(\.name), Array(intact.entries.prefix(sizes.count).map(\.name)))
            XCTAssertEqual(reader.entries.map(\.isIncomplete), incomplete, "cut=\(cut)")
            let payloads = try reader.entries.map { try reader.read($0) }
            XCTAssertEqual(payloads.map(\.count), sizes, "cut=\(cut)")
            for index in payloads.indices {
                XCTAssertEqual(payloads[index], originals[index].prefix(sizes[index]), "cut=\(cut)")
                XCTAssertEqual(reader.entries[index].compressedSize, intact.entries[index].compressedSize)
                XCTAssertEqual(reader.entries[index].uncompressedSize, intact.entries[index].uncompressedSize)
            }
            if cut == 693 { XCTAssertEqual(digest(payloads), intactDigest) }
            let reopened = try reader.reopen()
            XCTAssertEqual(try reopened.entries.map { try reopened.read($0) }, payloads)
            print("RAR5 recovery cut=\(cut) entries=\(reader.entries.count) incomplete=\(reader.entries.map(\.isIncomplete)) bytes=\(payloads.map(\.count)) digest=\(digest(payloads))")
        }
    }

    func testStrictModePreservesTruncationErrorAtAllFourPoints() throws {
        let archive = try fixture()
        for cut in [693, 400, 160, 130] {
            for options in [ReaderOptions(), ReaderOptions(recoverDamagedArchives: false)] {
                XCTAssertThrowsError(try ArchiveReader.open(data: Data(archive.prefix(cut)), options: options)) {
                    XCTAssertEqual($0 as? KaitoError, .truncated, "cut=\(cut)")
                    XCTAssertEqual(String(describing: $0), "The archive is truncated")
                }
            }
        }
    }

    func testTruncatedVolumeIsNeverRecoveredFromDataOrURL() throws {
        let archive = RAR5TestSupport.archive(mainFlags: 1, blocks: [
            RAR5TestSupport.storedFile(name: "file", contents: Data(repeating: 42, count: 32)),
        ])
        let layouts = try RAR5TestSupport.blockLayouts(in: Array(archive))
        let temporary = try ZipTestSupport.temporaryDirectory(label: "rar5-recovery-volume")
        defer { try? FileManager.default.removeItem(at: temporary) }
        for cut in [try XCTUnwrap(layouts.last).offset, layouts[1].data.lowerBound + 5] {
            let truncated = Data(archive.prefix(cut))
            let url = try ZipTestSupport.write(truncated, relativePath: "cut.part1.rar", below: temporary)
            XCTAssertThrowsError(try ArchiveReader.open(data: truncated, options: recovery)) {
                XCTAssertEqual($0 as? KaitoError, .truncated)
            }
            XCTAssertThrowsError(try ArchiveReader.open(url: url, options: recovery)) {
                XCTAssertEqual($0 as? KaitoError, .truncated)
            }
        }
    }

    func testTruncatedContinuationVolumeIsNotRecovered() throws {
        let temporary = try ZipTestSupport.temporaryDirectory(label: "rar5-recovery-continuation")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let first = RAR5TestSupport.archive(mainFlags: 1, endFlags: 1, blocks: [
            RAR5TestSupport.storedFile(name: "first", contents: Data([1])),
        ])
        let next = RAR5TestSupport.archive(mainFlags: 3, mainVolumeNumber: 1, blocks: [
            RAR5TestSupport.storedFile(name: "next", contents: Data(repeating: 2, count: 32)),
        ])
        let url = try ZipTestSupport.write(first, relativePath: "cut.part1.rar", below: temporary)
        let layouts = try RAR5TestSupport.blockLayouts(in: Array(next))
        for cut in [try XCTUnwrap(layouts.last).offset, layouts[1].data.lowerBound + 5] {
            _ = try ZipTestSupport.write(
                Data(next.prefix(cut)), relativePath: "cut.part2.rar", below: temporary
            )
            XCTAssertThrowsError(try ArchiveReader.open(url: url, options: recovery)) {
                XCTAssertEqual($0 as? KaitoError, .truncated)
            }
        }
    }

    func testTruncatedEncryptedEndHeaderKeepsCompleteEntriesAndPasswordErrors() throws {
        let archive = try decodeFixture(ZipTestSupport.repositoryRoot.appendingPathComponent(
            "Tests/Fixtures/rar5/header_encrypted_method3.rar.b64"
        ))
        let strict = try ArchiveReader.open(data: archive, options: ReaderOptions(password: "secret"))
        let cut = Data(archive.dropLast())
        let recovered = try ArchiveReader.open(
            data: cut, options: ReaderOptions(password: "secret", recoverDamagedArchives: true)
        )
        XCTAssertEqual(strict.entries, recovered.entries)
        for entry in strict.entries {
            XCTAssertEqual(try strict.read(entry), try recovered.read(entry))
        }
        for enabled in [false, true] {
            XCTAssertThrowsError(try ArchiveReader.open(
                data: cut, options: ReaderOptions(password: "wrong", recoverDamagedArchives: enabled)
            )) {
                XCTAssertEqual($0 as? KaitoError, .wrongPassword)
            }
        }
    }

    func testSolidIncompleteMemberIsListedButCannotBeRead() throws {
        let first = Data("complete first member".utf8)
        let archive = RAR5TestSupport.archive(mainFlags: 4, blocks: [
            RAR5TestSupport.storedFile(name: "first", contents: first),
            RAR5TestSupport.storedFile(name: "last", contents: Data(repeating: 7, count: 32), compressionInfo: 0x40),
        ])
        let layouts = try RAR5TestSupport.blockLayouts(in: Array(archive))
        let reader = try ArchiveReader.open(
            data: Data(archive.prefix(layouts[2].data.lowerBound + 5)), options: recovery
        )
        XCTAssertEqual(reader.entries.map(\.solidGroup), [0, 0])
        XCTAssertEqual(reader.entries.map(\.isIncomplete), [false, true])
        XCTAssertEqual(try reader.read(reader.entries[0]), first)
        XCTAssertThrowsError(try reader.read(reader.entries[1])) {
            XCTAssertEqual($0 as? KaitoError, .truncated)
        }
        XCTAssertEqual(try reader.read(reader.entries[0]), first)
    }

    func testRecoveryPreservesDeclaredPackedSizeLimit() throws {
        // 展開サイズを小さくしても、宣言された圧縮サイズの上限検査は省略できない。
        let archive = RAR5TestSupport.archive(blocks: [
            RAR5TestSupport.storedFile(name: "large", contents: Data(repeating: 0, count: 512), unpackedSize: 1),
        ])
        let layouts = try RAR5TestSupport.blockLayouts(in: Array(archive))
        let reader = try ArchiveReader.open(
            data: Data(archive.prefix(layouts[1].data.lowerBound + 1)),
            options: ReaderOptions(limits: ReadLimits(maxEntrySize: 64), recoverDamagedArchives: true)
        )
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertTrue(entry.isIncomplete)
        XCTAssertEqual(entry.compressedSize, 512)
        XCTAssertThrowsError(try reader.read(entry)) {
            guard case KaitoError.limitExceeded = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func testCRCVerifiedHeaderBoundsErrorsAreNotRecovered() throws {
        let valid = RAR5TestSupport.storedFile(name: "valid", contents: Data([1]))
        let invalidHeaders = [
            RAR5TestSupport.block(type: 2, specific: []),
            RAR5TestSupport.block(type: 3, specific: []),
            RAR5TestSupport.block(type: 5, specific: []),
            // data-area フラグはあるが、共通 header にサイズの vint が無い。
            RAR5TestSupport.block(type: 2, flags: 2, specific: []),
            RAR5TestSupport.storedFile(name: "invalid", contents: Data(), extra:
                RAR5TestSupport.extraRecord(type: 5, payload: [1, 0, 20])),
            RAR5TestSupport.storedFile(name: "invalid", contents: Data(), extra:
                RAR5TestSupport.extraRecord(type: 6, payload: [1, 20])),
        ]
        for header in invalidHeaders {
            let archive = RAR5TestSupport.archive(blocks: [valid, header])
            for enabled in [false, true] {
                XCTAssertThrowsError(try ArchiveReader.open(
                    data: archive, options: ReaderOptions(recoverDamagedArchives: enabled)
                )) {
                    XCTAssertEqual($0 as? KaitoError, .truncated)
                }
            }
        }
    }

    func testRecoveryDoesNotIgnoreHeaderCRCOrCompletePayloadCRC() throws {
        var archive = try fixture()
        archive[145] ^= 1
        XCTAssertThrowsError(try ArchiveReader.open(data: Data(archive.prefix(400)), options: recovery)) {
            XCTAssertEqual($0 as? KaitoError, .malformed("RAR5 header CRC mismatch at offset 138"))
        }
        archive = try fixture()
        archive[181] ^= 1
        let reader = try ArchiveReader.open(data: Data(archive.prefix(693)), options: recovery)
        XCTAssertThrowsError(try reader.read(reader.entries[2])) {
            XCTAssertEqual($0 as? KaitoError, .checksumMismatch(entry: 2))
        }
    }

    func testAllCheckedInRAR5FixturesStayCompleteByDefault() throws {
        let root = ZipTestSupport.repositoryRoot.appendingPathComponent("Tests/Fixtures")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var checked = 0
        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".rar.b64") {
            let archive = try decodeFixture(url)
            guard archive.starts(with: RAR5Reader.signature) else { continue }
            let name = url.lastPathComponent
            var options = ReaderOptions()
            if name.contains("ascii127") { options.password = String(repeating: "A", count: 127) }
            else if name.contains("ascii128") { options.password = String(repeating: "A", count: 128) }
            else if name.contains("kana128") { options.password = String(repeating: "か", count: 128) }
            else if name.contains("emoji130") { options.password = String(repeating: "😀", count: 130) }
            else if name.contains("password-full") { options.password = String(repeating: "e\u{301}", count: 65) }
            else if name.contains("header_encrypted") { options.password = "secret" }
            let reader = try ArchiveReader.open(data: archive, options: options)
            XCTAssertTrue(reader.entries.allSatisfy { !$0.isIncomplete }, name)
            options.recoverDamagedArchives = true
            let recovered = try ArchiveReader.open(data: archive, options: options)
            XCTAssertEqual(reader.entries, recovered.entries, name)
            for entry in reader.entries {
                XCTAssertEqual(try reader.read(entry), try recovered.read(entry), name)
            }
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 14)
        print("RAR5 intact checked-in fixtures verified=\(checked)")
    }
}
