import Foundation
@testable import KaitoKit
import XCTest

final class RARMultiVolumeSFXTests: XCTestCase {
    private struct VolumeSet {
        let label: String
        let firstFixture: String
        let secondFixture: String
        let firstName: String
        let secondName: String
    }

    private let sets = [
        VolumeSet(
            label: "RAR5 partN",
            firstFixture: "rar5/sfx-part1.rar",
            secondFixture: "rar5/sfx-part2.rar",
            firstName: "five.part1.exe",
            secondName: "five.part2.rar"
        ),
        VolumeSet(
            label: "RAR4 partN",
            firstFixture: "rar4/sfx-new-part1.rar",
            secondFixture: "rar4/sfx-new-part2.rar",
            firstName: "four.part1.exe",
            secondName: "four.part2.rar"
        ),
        VolumeSet(
            label: "RAR4 r00",
            firstFixture: "rar4/sfx-old-first.rar",
            secondFixture: "rar4/sfx-old-second.r00",
            firstName: "four.exe",
            secondName: "four.r00"
        ),
    ]

    func testSFXMultiVolumeSetsReadBothPartsAndReopen() throws {
        for item in sets {
            let (directory, firstURL) = try writeSet(item)
            defer { try? FileManager.default.removeItem(at: directory) }
            let reader = try ArchiveReader.open(url: firstURL)
            try assertContents(reader, label: item.label)
            try assertContents(reader.reopen(), label: item.label)
            if item.label == "RAR5 partN" {
                var options = ReaderOptions()
                options.rar5QuickOpenPolicy = .always
                let quickOpen = try ArchiveReader.open(url: firstURL, options: options)
                try assertContents(quickOpen, label: item.label)
            }
        }
    }

    func testUnrarAcceptsReferenceSFXSets() throws {
        let candidates = ["/opt/homebrew/bin/unrar", "/usr/local/bin/unrar"]
        guard let unrar = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw XCTSkip("unrar is unavailable")
        }
        for item in sets {
            let (directory, firstURL) = try writeSet(item)
            defer { try? FileManager.default.removeItem(at: directory) }
            _ = try ZipTestSupport.checkedRun(unrar, arguments: ["t", firstURL.path])
        }
    }

    private func writeSet(_ item: VolumeSet) throws -> (directory: URL, firstURL: URL) {
        let directory = try ZipTestSupport.temporaryDirectory(label: "rar-sfx-volume")
        let firstURL = directory.appendingPathComponent(item.firstName)
        let prefix = ZipTestSupport.makePEPrefix(count: 4_096)
        try (prefix + TestFixtures.base64(item.firstFixture)).write(to: firstURL)
        let secondURL = directory.appendingPathComponent(item.secondName)
        try TestFixtures.base64(item.secondFixture).write(to: secondURL)
        return (directory, firstURL)
    }

    private func assertContents(_ reader: ArchiveReader, label: String) throws {
        XCTAssertEqual(reader.entries.count, 2, label)
        let expected = [
            Data(repeating: UInt8(ascii: "A"), count: 700),
            Data(repeating: UInt8(ascii: "B"), count: 700),
        ]
        for (index, payload) in expected.enumerated() {
            let entry = reader.entries[index]
            XCTAssertTrue(entry.name.hasSuffix(index == 0 ? "/a.txt" : "/b.txt"), label)
            XCTAssertEqual(try reader.read(entry), payload, label)
        }
    }
}
