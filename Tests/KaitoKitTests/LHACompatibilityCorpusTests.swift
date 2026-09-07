import Foundation
@testable import KaitoKit
import XCTest

final class LHACompatibilityCorpusTests: XCTestCase {
    private static let corpusRoot = URL(
        fileURLWithPath: "/private/tmp/claude-501/-Users-nagash-cooViewer/37ef55f3-9116-4440-88b8-9a15060856ad/scratchpad/lha-corpus",
        isDirectory: true
    )

    func testDirectoryAndRelativeNameCorpusArchivesExtractSafely() throws {
        let fixtures = [
            "lhmelt_16536/h0_subdir.lzh",
            "lhmelt_16536/h1_subdir.lzh",
            "lhmelt_16536/h2_subdir.lzh",
            "lha_osk_201/h0_subdir.lzh",
            "lha_unix114i/h0_subdir.lzh",
            "maclha_224/l1_full_subdir.lzh",
            "maclha_224/l2_full_subdir.lzh",
            "tascal_lha_051h/abspath.lzh",
            "regression/abspath.lzh",
            "regression/badterm.lzh",
            "lha_amiga_122/lh0_dirs_bug.lzh",
            "regression/empty_fn.lzh",
        ]

        for relativePath in fixtures {
            let archive = try corpusFixture(relativePath)
            let reader = try ArchiveReader.open(url: archive)
            let stopsAtEmptyRoot = relativePath == "lha_osk_201/h0_subdir.lzh"
                || relativePath == "lha_unix114i/h0_subdir.lzh"
            XCTAssertEqual(reader.entries.isEmpty, stopsAtEmptyRoot, relativePath)
            for entry in reader.entries {
                XCTAssertFalse(entry.name.hasPrefix("/"), relativePath)
                XCTAssertFalse(hasDrivePrefix(entry.name), relativePath)
                XCTAssertFalse(entry.name.utf8.contains(0), relativePath)
            }
            try extractAll(reader, label: archive.deletingPathExtension().lastPathComponent)
        }

        let amiga = try ArchiveReader.open(
            url: corpusFixture("lha_amiga_122/lh0_dirs_bug.lzh")
        )
        XCTAssertEqual(amiga.entries[2].name, "MainDir/02_EmptyDir/")
        XCTAssertEqual(amiga.entries[2].kind, .directory)

        let anonymous = try ArchiveReader.open(
            url: corpusFixture("regression/empty_fn.lzh")
        )
        XCTAssertEqual(anonymous.entries.count, 2)
        XCTAssertEqual(
            anonymous.entries.map(\.name),
            [
                "Picasso96Install/Picasso96/P96Speed/catalogs/deutsch/P96Speed.catalog",
                "Picasso96Install/Picasso96/P96Speed/Compare.dat",
            ]
        )
    }

    func testAbsoluteDrivePrefixesBecomeRelativeButDotDotRemainsUnsafe() throws {
        let archive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "C:\\pages\\cover.txt",
                contents: Data("cover".utf8),
                headerLevel: 0,
                permissions: nil
            ),
            HandLHAEntry(
                name: "/../outside.txt",
                contents: Data("outside".utf8),
                headerLevel: 0,
                permissions: nil
            ),
        ])
        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(reader.entries.map(\.name), ["pages/cover.txt", "../outside.txt"])

        let destination = temporaryDestination(label: "relative-drive")
        defer { try? FileManager.default.removeItem(at: destination) }
        _ = try reader.extract(reader.entries[0], to: destination)
        XCTAssertThrowsError(try reader.extract(reader.entries[1], to: destination)) { error in
            guard case let KaitoError.malformed(reason) = error else {
                return XCTFail("expected traversal rejection, got \(error)")
            }
            XCTAssertTrue(reason.contains("unsafe component"))
        }
    }

    func testMorphOSNULTerminatedNamesUseOnlyThePathPrefix() throws {
        for relativePath in [
            "morphos_lha_2717/h0_metadata.lzh",
            "morphos_lha_2717/h1_metadata.lzh",
        ] {
            let reader = try ArchiveReader.open(url: corpusFixture(relativePath))
            let entry = try XCTUnwrap(reader.entries.first)
            XCTAssertEqual(entry.name, "metadata.txt", relativePath)
            XCTAssertEqual(entry.uncompressedSize, 29, relativePath)
            XCTAssertEqual(try reader.read(entry).count, 29, relativePath)
        }
    }

    func testOS2EAPayloadDirectoryDoesNotBlockItsChildren() throws {
        let reader = try ArchiveReader.open(
            url: corpusFixture("lh2_222/easubdir.lzh")
        )
        XCTAssertEqual(reader.entries.map(\.name), [
            "subdir", "subdir/subdir2/hello.txt", "Apply-Ea.Cmd",
        ])
        XCTAssertEqual(reader.entries.map(\.kind), [.directory, .file, .file])
        XCTAssertEqual(reader.entries[0].uncompressedSize, 570)
        XCTAssertEqual(try reader.read(reader.entries[0]).count, 570)
        try extractAll(reader, label: "os2-ea")
    }

    func testOS9Creator4BLevel2UndercountUsesCompletedExtensionChain() throws {
        let fixtures = [
            "lha_osk_201/h2_lh0.lzh",
            "lha_osk_201/h2_lh1.lzh",
            "lha_osk_201/h2_lh5.lzh",
            "lha_osk_201/h2_subdir.lzh",
        ]
        for relativePath in fixtures {
            let reader = try ArchiveReader.open(url: corpusFixture(relativePath))
            XCTAssertTrue(reader.entries.allSatisfy {
                $0.formatSpecific["headerLevel"] == "2"
            }, relativePath)
            XCTAssertTrue(reader.entries.allSatisfy {
                $0.formatSpecific["osID"] == "K"
                    && $0.formatSpecific["os"] == "OS/68K"
            }, relativePath)
            for entry in reader.entries {
                _ = try reader.read(entry)
            }
            try extractAll(reader, label: "osk-level2")
        }
    }

    func testLevel3FourByteHeaderAndExtensionSizes() throws {
        let fixtures = [
            "lha_os2_208/h3_lfn.lzh",
            "lha_os2_208/h3_lh0.lzh",
            "lha_os2_208/h3_lh5.lzh",
            "lha_os2_208/h3_subdir.lzh",
        ]
        for relativePath in fixtures {
            let reader = try ArchiveReader.open(url: corpusFixture(relativePath))
            XCTAssertTrue(reader.entries.allSatisfy {
                $0.formatSpecific["headerLevel"] == "3"
            }, relativePath)
            for entry in reader.entries {
                _ = try reader.read(entry)
            }
            try extractAll(reader, label: "level3")
        }
    }

    func testInvalidPMArcDOSTimestampDegradesToNil() throws {
        let reader = try ArchiveReader.open(
            url: corpusFixture("pmarc124/mtcd.pma")
        )
        XCTAssertEqual(reader.entries.count, 2)
        XCTAssertTrue(reader.entries.allSatisfy { $0.modificationDate == nil })
        XCTAssertTrue(reader.entries.allSatisfy { $0.methodDescription == "-pm1-" })
    }

    func testLArcArchivesMayEndAtTheFinalPayloadWithoutAZeroMarker() throws {
        let fixtures: [(String, UInt64)] = [
            ("larc333/initial.lzs", 4_234),
            ("generated/lzs/lzs.lzs", 18_092),
            ("generated/lzs/long.lzs", 1_241_658),
        ]
        for (relativePath, expectedSize) in fixtures {
            let reader = try ArchiveReader.open(url: corpusFixture(relativePath))
            let entry = try XCTUnwrap(reader.entries.first)
            XCTAssertEqual(entry.uncompressedSize, expectedSize, relativePath)
            XCTAssertEqual(UInt64(try reader.read(entry).count), expectedSize, relativePath)
        }
    }

    private func corpusFixture(_ relativePath: String) throws -> URL {
        let url = Self.corpusRoot.appendingPathComponent(relativePath)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw XCTSkip("LHA compatibility corpus is unavailable: \(url.path)")
        }
        return url
    }

    private func extractAll(_ reader: ArchiveReader, label: String) throws {
        let destination = temporaryDestination(label: label)
        defer { try? FileManager.default.removeItem(at: destination) }
        for entry in reader.entries where entry.kind != .directory {
            _ = try reader.extract(entry, to: destination)
        }
        let directories = reader.entries
            .filter { $0.kind == .directory }
            .sorted {
                if $0.pathComponents.count != $1.pathComponents.count {
                    return $0.pathComponents.count > $1.pathComponents.count
                }
                return $0.index < $1.index
            }
        for entry in directories {
            _ = try reader.extract(entry, to: destination)
        }
    }

    private func temporaryDestination(label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "KaitoKit-LHA-compat-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func hasDrivePrefix(_ name: String) -> Bool {
        let bytes = Array(name.utf8.prefix(2))
        guard bytes.count == 2 else { return false }
        return ((0x41...0x5A).contains(bytes[0]) || (0x61...0x7A).contains(bytes[0]))
            && bytes[1] == 0x3A
    }
}
