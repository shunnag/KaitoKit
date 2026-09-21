import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

/// RAR5 の file copy（redirection type 5、`rar -oi`）。参照は同一内容の先行 entry の本文を返す。
/// 固定 fixture は RAR 7.23 が書いた 3 書庫（Tests/Fixtures/rar5/file-copy*.rar.b64）。
final class RAR5FileCopyTests: XCTestCase {
    private let expectedNames = ["a.txt", "b.txt", "sub/c.txt", "d.txt"]
    private let textSHA = "ac15dd767cb2eed6421721727c17c45970f4a7cb41dbb84487782d8290b7dad1"
    private let otherSHA = "94b306c8e7bf7f836da506b6c80297ecfead0481e6fe11086d8433d304a129eb"

    private func fixture(_ name: String) throws -> Data {
        let url = ZipTestSupport.repositoryRoot.appendingPathComponent("Tests/Fixtures/rar5/\(name).rar.b64")
        return try XCTUnwrap(Data(base64Encoded: Data(contentsOf: url), options: .ignoreUnknownCharacters))
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func read(_ stream: EntryStream, chunk: Int) throws -> Data {
        var output = Data(), buffer = [UInt8](repeating: 0, count: chunk)
        while stream.remaining > 0 {
            let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
            guard count > 0 else { throw KaitoError.truncated }
            output.append(contentsOf: buffer.prefix(count))
        }
        return output
    }

    private func assertReferences(_ reader: ArchiveReader, encrypted: Bool, solid: Bool, label: String) throws {
        XCTAssertEqual(reader.entries.map(\.name), expectedNames, label)
        XCTAssertEqual(reader.entries.map(\.kind), [.file, .file, .file, .file], label)
        XCTAssertEqual(reader.entries.map(\.uncompressedSize), [20_000, 20_000, 20_000, 18], label)
        XCTAssertEqual(reader.entries.map(\.isEncrypted), [encrypted, encrypted, encrypted, encrypted], label)
        for index in [1, 2] {
            let entry = reader.entries[index]
            XCTAssertEqual(entry.methodDescription, "RAR5 file copy", label)
            XCTAssertEqual(entry.compressedSize, 0, label)
            XCTAssertEqual(entry.formatSpecific["redirectionType"], "5", label)
            XCTAssertEqual(entry.formatSpecific["linkPath"], "a.txt", label)
            XCTAssertEqual(entry.formatSpecific["fileCopyTargetIndex"], "0", label)
            XCTAssertNil(entry.crc32, label)
            XCTAssertEqual(entry.solidGroup, reader.entries[0].solidGroup, label)
        }
        XCTAssertEqual(reader.entries[0].solidGroup >= 0, solid, label)
        XCTAssertEqual(reader.entries[3].solidGroup >= 0, solid, label)
        // 逆順・小さな chunk・reopen のどれでも参照先と同じ byte を返す。
        for entry in reader.entries.reversed() {
            let data = try read(reader.stream(entry), chunk: 4_099)
            XCTAssertEqual(sha(data), entry.name == "d.txt" ? otherSHA : textSHA, "\(label) \(entry.name)")
        }
        let reopened = try reader.reopen()
        for entry in reopened.entries {
            XCTAssertEqual(sha(try reopened.read(entry)), entry.name == "d.txt" ? otherSHA : textSHA, "\(label) \(entry.name)")
        }
    }

    func testCheckedInFixturesExposeReferencesAsFilesWithTargetContents() throws {
        try assertReferences(try ArchiveReader.open(data: fixture("file-copy")), encrypted: false, solid: false, label: "plain")
        try assertReferences(try ArchiveReader.open(data: fixture("file-copy-solid")), encrypted: false, solid: true, label: "solid")
        let aes = try fixture("file-copy-aes")
        try assertReferences(
            try ArchiveReader.open(data: aes, options: ReaderOptions(password: "KaitoFixture")),
            encrypted: true, solid: false, label: "aes"
        )
        // 参照は本文を持たないが、参照先が暗号化されていれば password が要る。
        let locked = try ArchiveReader.open(data: aes)
        XCTAssertThrowsError(try locked.read(locked.entries[1])) {
            XCTAssertEqual($0 as? KaitoError, .passwordRequired)
        }
    }

    func testAggregateBudgetCountsReferenceOutput() throws {
        let archive = try fixture("file-copy")
        let exact = try ArchiveReader.open(data: archive, options: ReaderOptions(limits: ReadLimits(maxTotalUncompressedSize: 60_018)))
        for entry in exact.entries { _ = try exact.read(entry) }
        XCTAssertThrowsError(try ArchiveReader.open(data: archive, options: ReaderOptions(limits: ReadLimits(maxTotalUncompressedSize: 60_017)))) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        let small = try ArchiveReader.open(data: archive, options: ReaderOptions(limits: ReadLimits(maxEntrySize: 19_999)))
        XCTAssertThrowsError(try small.read(small.entries[1])) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func testReferenceInheritsThePasswordCheckOfItsTarget() throws {
        // 参照は本文を持たないが、読み取りは参照先の復号なので誤った password は wrongPassword になる。
        let aes = try fixture("file-copy-aes")
        let wrong = try ArchiveReader.open(data: aes, options: ReaderOptions(password: "not-the-password"))
        XCTAssertEqual(wrong.entries[1].kind, .file)
        XCTAssertThrowsError(try wrong.read(wrong.entries[1])) {
            XCTAssertEqual($0 as? KaitoError, .wrongPassword)
        }
        XCTAssertThrowsError(try wrong.read(wrong.entries[0])) {
            XCTAssertEqual($0 as? KaitoError, .wrongPassword)
        }
        // 解決できない参照が `.other` に留まる分岐は RAR5ReaderTests の合成書庫で固定する。
    }

    func testGeneratedArchivesReferenceOnlyDuplicatesAboveRARsMinimumSize() throws {
        try RAR5TestSupport.requireRAR()
        let directory = try ZipTestSupport.temporaryDirectory(label: "rar5-file-copy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        var payload = [UInt8]()
        for _ in 0..<150_000 {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            payload.append(UInt8(truncatingIfNeeded: seed))
        }
        let data = Data(payload)
        for name in ["one.bin", "two.bin", "three.bin"] {
            try data.write(to: source.appendingPathComponent(name))
        }
        // rar 7.23 の -oi は既定 64 KB 未満の同一 file を参照にしない（rar.txt）。1 KB の複製で確認する。
        let small = Data(payload.prefix(1_024))
        for name in ["small1.bin", "small2.bin"] {
            try small.write(to: source.appendingPathComponent(name))
        }
        try Data("tail".utf8).write(to: source.appendingPathComponent("tail.txt"))
        let archiveURL = directory.appendingPathComponent("generated.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source, paths: ["one.bin", "two.bin", "three.bin", "small1.bin", "small2.bin", "tail.txt"],
            archiveURL: archiveURL, options: ["-m0", "-oi1"]
        )
        let reader = try ArchiveReader.open(url: archiveURL)
        XCTAssertEqual(reader.entries.map(\.name), ["one.bin", "two.bin", "three.bin", "small1.bin", "small2.bin", "tail.txt"])
        XCTAssertEqual(reader.entries.map { $0.formatSpecific["redirectionType"] }, [nil, "5", "5", nil, nil, nil])
        for entry in reader.entries.prefix(3).reversed() {
            XCTAssertEqual(try reader.read(entry), data, entry.name)
        }
        XCTAssertEqual(try reader.read(reader.entries[3]), small)
        XCTAssertEqual(try reader.read(reader.entries[4]), small)
        XCTAssertEqual(try reader.read(reader.entries[5]), Data("tail".utf8))
    }
}
