import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

/// Optional, host-local differential coverage for the BSD-2 libarchive RAR4
/// fixture corpus supplied to the M3 work. CI cleanly skips these tests when
/// either the corpus or the black-box `rar` executable is absent.
final class RAR4CorpusDifferentialTests: XCTestCase {
    private static let corpus = URL(
        fileURLWithPath: "/private/tmp/claude-501/-Users-nagash-cooViewer/37ef55f3-9116-4440-88b8-9a15060856ad/scratchpad/rar4-corpus",
        isDirectory: true
    )
    private static let passwords: [String?] = [nil, "password", "test", "12345678"]
    private static let malformedNames: Set<String> = [
        "test_read_format_rar_invalid1.rar",
        "test_read_format_rar_overflow.rar",
        "test_read_format_rar_endarc_huge.rar",
        "test_read_format_rar_newsub_huge.rar",
        "test_read_format_rar_symlink_huge.rar",
        "test_read_format_rar_noeof.rar",
        "test_read_format_rar_ppmd_use_after_free.rar",
        "test_read_format_rar_ppmd_use_after_free2.rar",
        "test_read_format_rar_unbound_staticdata.rar",
    ]
    // `rar` 7.23 reports a corrupt main-header CRC and unexpected end for this
    // libarchive cursor-regression fixture, so it cannot supply a successful
    // extraction oracle. KaitoKit intentionally keeps strict header CRCs.
    private static let blackBoxRejectedNames: Set<String> = [
        "test_read_format_rar_seek_data_cursor0.rar",
    ]
    private static let expectedSymlinks: [String: [(name: String, target: String)]] = [
        "test_read_format_rar.rar": [
            ("testlink", "test.txt"),
        ],
        "test_read_format_rar_compress_best.rar": [
            ("testlink", "LibarchiveAddingTest.html"),
        ],
        "test_read_format_rar_compress_normal.rar": [
            ("testlink", "LibarchiveAddingTest.html"),
        ],
        "test_read_format_rar_multivolume.part0001.rar": [
            ("testlink", "LibarchiveAddingTest.html"),
        ],
        "test_read_format_rar_unicode.rar": [
            ("表だよ/ファイル", "漢字長いファイル名long-filename-in-漢字.txt"),
        ],
    ]

    func testEveryExtractableCorpusEntryMatchesRAR723() throws {
        let archives = try corpusArchives(excludingMalformed: true)
        guard !archives.isEmpty else {
            throw XCTSkip("RAR4 differential corpus is absent")
        }
        try RAR5TestSupport.requireRAR()

        var comparedEntries = 0
        var comparedSymlinks = 0
        var oracleRejectedEntries = 0
        for archive in archives {
            let reader: ArchiveReader
            do {
                reader = try openWithKnownPassword(archive)
            } catch where Self.blackBoxRejectedNames.contains(archive.lastPathComponent) {
                print(
                    "RAR4 corpus archive: \(archive.lastPathComponent), "
                        + "black-box oracle rejects archive framing"
                )
                continue
            }
            var archiveMatches = 0
            var archiveOracleRejects = 0
            for entry in reader.entries where entry.kind == .file {
                guard let oracle = try firstSuccessfulOracle(
                    archive: archive,
                    entryName: entry.name
                ) else {
                    // Some libarchive password fixtures deliberately contain
                    // members for which the supplied password set is not an
                    // extraction oracle. They are not "extractable" for this
                    // differential and are reported by the aggregate count.
                    oracleRejectedEntries += 1
                    archiveOracleRejects += 1
                    print(
                        "RAR4 corpus member lacks supplied-password oracle: "
                            + "\(archive.lastPathComponent):\(entry.index):\(entry.name)"
                    )
                    continue
                }

                reader.password = oracle.password
                let actual = try hash(try reader.stream(entry))
                XCTAssertEqual(
                    actual.byteCount,
                    oracle.byteCount,
                    "\(archive.lastPathComponent):\(entry.index):\(entry.name)"
                )
                XCTAssertTrue(
                    actual.digest.elementsEqual(oracle.digest),
                    "\(archive.lastPathComponent):\(entry.index):\(entry.name)"
                )
                comparedEntries += 1
                archiveMatches += 1
            }
            let archiveSymlinks = try assertSymlinks(
                in: reader,
                archiveName: archive.lastPathComponent
            )
            comparedSymlinks += archiveSymlinks
            print(
                "RAR4 corpus archive: \(archive.lastPathComponent), "
                    + "\(archiveMatches) matched, "
                    + "\(archiveSymlinks) symlinks checked, "
                    + "\(archiveOracleRejects) lacked an oracle"
            )
        }

        XCTAssertGreaterThan(comparedEntries, 0)
        // Keep this visible in `swift test` output without coupling the test to
        // one revision of the external fixture corpus.
        print(
            "RAR4 corpus differential: \(archives.count) archives, "
                + "\(comparedEntries) entries matched, "
                + "\(comparedSymlinks) symlinks checked, "
                + "\(oracleRejectedEntries) entries lacked a supplied-password oracle"
        )
    }

    /// `rar p` succeeds but emits no bytes for a symbolic link, so it is not a
    /// payload oracle for these records. Pin the independently parsed name and
    /// the archived UTF-8 link-target bytes instead.
    private func assertSymlinks(
        in reader: ArchiveReader,
        archiveName: String
    ) throws -> Int {
        let actual = reader.entries.filter { $0.kind == .symlink }
        let expected = Self.expectedSymlinks[archiveName] ?? []
        XCTAssertEqual(
            actual.map(\.name),
            expected.map { $0.name },
            archiveName
        )
        for (entry, expectedLink) in zip(actual, expected) {
            XCTAssertEqual(entry.name, expectedLink.name, archiveName)
            XCTAssertEqual(
                try reader.read(entry),
                Data(expectedLink.target.utf8),
                "\(archiveName):\(entry.index):\(entry.name)"
            )
        }
        return actual.count
    }

    func testMalformedCorpusTerminatesWithSuccessOrStructuredError() throws {
        let archives = try corpusArchives(excludingMalformed: false).filter {
            Self.malformedNames.contains($0.lastPathComponent)
        }
        guard !archives.isEmpty else {
            throw XCTSkip("RAR4 malformed-input corpus is absent")
        }

        var limits = ReadLimits()
        limits.maxEntrySize = 256 * 1_024 * 1_024
        limits.maxInMemorySize = 256 * 1_024 * 1_024
        limits.maxDictionarySize = 64 * 1_024 * 1_024
        limits.maxMetadataSize = 1 * 1_024 * 1_024
        limits.maxTotalMetadataSize = 8 * 1_024 * 1_024
        limits.maxMetadataRecordCount = 100_000

        for archive in archives {
            do {
                let reader = try ArchiveReader.open(
                    url: archive,
                    options: ReaderOptions(limits: limits)
                )
                for entry in reader.entries where entry.kind != .directory {
                    do {
                        let stream = try reader.stream(entry)
                        _ = try hash(stream)
                    } catch is KaitoError {
                        // A bounded, typed rejection is the expected result for
                        // malformed members that survive header parsing.
                    }
                }
            } catch is KaitoError {
                // A bounded, typed rejection during open is also expected.
            }
        }
    }

    private func corpusArchives(excludingMalformed: Bool) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: Self.corpus.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            at: Self.corpus,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            let name = url.lastPathComponent
            let isArchive = url.pathExtension.lowercased() == "rar"
                || url.pathExtension.lowercased() == "exe"
            guard isArchive, !name.hasSuffix(".uu") else { return false }
            // Let RARVolumeLocator own continuation discovery; opening a later
            // volume directly would count one logical archive repeatedly.
            if name.range(of: #"\.part0*(?:2|3|4)\.rar$"#, options: .regularExpression) != nil {
                return false
            }
            return !excludingMalformed || !Self.malformedNames.contains(name)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func openWithKnownPassword(_ archive: URL) throws -> ArchiveReader {
        var lastError: Error = KaitoError.passwordRequired
        for password in Self.passwords {
            do {
                return try ArchiveReader.open(
                    url: archive,
                    options: ReaderOptions(password: password)
                )
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private struct OracleDigest {
        let password: String?
        let byteCount: UInt64
        let digest: SHA256.Digest
    }

    private func firstSuccessfulOracle(
        archive: URL,
        entryName: String
    ) throws -> OracleDigest? {
        for password in Self.passwords {
            if let result = try oracleDigest(
                archive: archive,
                entryName: entryName,
                password: password
            ) {
                return result
            }
        }
        return nil
    }

    private func oracleDigest(
        archive: URL,
        entryName: String,
        password: String?
    ) throws -> OracleDigest? {
        let directory = try ZipTestSupport.temporaryDirectory(label: "rar4-oracle")
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("stdout")
        let diagnostics = directory.appendingPathComponent("stderr")
        let selection = directory.appendingPathComponent("member-list.utf8")
        try Data((entryName + "\n").utf8).write(to: selection)
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              FileManager.default.createFile(atPath: diagnostics.path, contents: nil) else {
            throw ZipTestSupportError.fixture("could not create RAR oracle capture files")
        }
        let outputHandle = try FileHandle(forWritingTo: output)
        let diagnosticsHandle = try FileHandle(forWritingTo: diagnostics)
        defer {
            try? outputHandle.close()
            try? diagnosticsHandle.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: RAR5TestSupport.executablePath)
        process.arguments = [
            "p",
            "-inul",
            "-scfl",
            password.map { "-p\($0)" } ?? "-p-",
            archive.path,
            "@\(selection.path)",
        ]
        // Keep the child locale deterministic. Member selection itself uses
        // an explicitly UTF-8 list file because Foundation's Process argv
        // bridge cannot reliably pass non-ASCII masks to this CLI on macOS.
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        environment["LANG"] = "en_US.UTF-8"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = diagnosticsHandle
        try process.run()
        process.waitUntilExit()
        try outputHandle.close()
        try diagnosticsHandle.close()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            return nil
        }

        let value = try hashFile(output)
        return OracleDigest(
            password: password,
            byteCount: value.byteCount,
            digest: value.digest
        )
    }

    private func hash(
        _ stream: EntryStream
    ) throws -> (byteCount: UInt64, digest: SHA256.Digest) {
        var digest = SHA256()
        var byteCount: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 1 * 1_024 * 1_024)
        while true {
            let count = try buffer.withUnsafeMutableBytes { storage -> Int in
                let count = try stream.read(into: storage)
                if count > 0 {
                    digest.update(
                        bufferPointer: UnsafeRawBufferPointer(rebasing: storage[..<count])
                    )
                }
                return count
            }
            guard count > 0 else { break }
            byteCount = try Checked.add(byteCount, UInt64(count))
        }
        return (byteCount, digest.finalize())
    }

    private func hashFile(
        _ url: URL
    ) throws -> (byteCount: UInt64, digest: SHA256.Digest) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var byteCount: UInt64 = 0
        while let chunk = try handle.read(upToCount: 1 * 1_024 * 1_024), !chunk.isEmpty {
            digest.update(data: chunk)
            byteCount = try Checked.add(byteCount, UInt64(chunk.count))
        }
        return (byteCount, digest.finalize())
    }
}
