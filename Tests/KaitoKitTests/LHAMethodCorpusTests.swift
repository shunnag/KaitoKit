import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

final class LHAMethodCorpusTests: XCTestCase {
    private static let corpusRoot = URL(
        fileURLWithPath: "/private/tmp/claude-501/-Users-nagash-cooViewer/37ef55f3-9116-4440-88b8-9a15060856ad/scratchpad/lha-corpus",
        isDirectory: true
    )

    func testUNLHA32Level2LHXCorpus() throws {
        try assertCorpusMember(
            relativePath: "unlha32/h2_lhx.lzh",
            method: "-lhx-",
            size: 18_092,
            sha256: "8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643"
        )
    }

    func testUNLHA32LongLHXCorpus() throws {
        try assertCorpusMember(
            relativePath: "unlha32/lhx_long.lzh",
            method: "-lhx-",
            size: 1_241_658,
            sha256: "1211b353951c19b6e69a28c1f7ed5bdf123015e6e22b5d3109135c76f8488188"
        )
    }

    func testLHArkLH7Corpus() throws {
        try assertCorpusMember(
            relativePath: "lhark04d/lh7.lzh",
            method: "-lh7-",
            size: 18_092,
            sha256: "8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643"
        )
    }

    func testLHArkLongLH7Corpus() throws {
        try assertCorpusMember(
            relativePath: "lhark04d/lh7_long.lzh",
            method: "-lh7-",
            size: 399_527,
            sha256: "e48f3f7a442fe0364dc5623424e47ad08372c0de9b0a26249d6640a0a8d43cf7"
        )
    }

    func testPM2CorpusRemainsExplicitlyUnsupported() throws {
        let relativePaths = [
            "pmarc2/comment.pma",
            "pmarc2/long.pma",
            "pmarc2/pm2.pma",
        ]
        var foundCount = 0
        for relativePath in relativePaths {
            let archive = Self.corpusRoot.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: archive.path) else {
                continue
            }
            foundCount += 1
            let reader = try ArchiveReader.open(url: archive)
            let entry = try XCTUnwrap(reader.entries.first, relativePath)
            XCTAssertEqual(entry.methodDescription, "-pm2-", relativePath)
            XCTAssertThrowsError(try reader.stream(entry), relativePath) { error in
                XCTAssertEqual(
                    error as? KaitoError,
                    .unsupportedMethod("-pm2-"),
                    relativePath
                )
            }
        }
        guard foundCount > 0 else {
            throw XCTSkip("lhasa PMarc 2 corpus is absent")
        }
    }

    func testRareLegacyMethodsRemainExplicitlyUnsupported() throws {
        for method in ["-pm1-", "-lh2-", "-lh3-"] {
            let archive = try LHATestSupport.makeArchive(entries: [
                HandLHAEntry(
                    name: "legacy.bin",
                    contents: Data([0]),
                    method: method,
                    headerLevel: 0
                ),
            ])
            let reader = try ArchiveReader.open(data: archive)
            let entry = try XCTUnwrap(reader.entries.first)
            XCTAssertThrowsError(try reader.stream(entry), method) { error in
                XCTAssertEqual(
                    error as? KaitoError,
                    .unsupportedMethod(method),
                    method
                )
            }
        }
    }

    func testLHXAndLHArkCorpusMutantsDoNotCrashOrStall() throws {
        let relativePaths = [
            "unlha32/h2_lhx.lzh",
            "lhark04d/lh7.lzh",
        ]
        var seeds: [(bytes: [UInt8], dataOffset: Int, dataCount: Int)] = []
        for relativePath in relativePaths {
            let archive = Self.corpusRoot.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: archive.path) else {
                continue
            }
            let data = try Data(contentsOf: archive)
            let reader = try ArchiveReader.open(data: data)
            let entry = try XCTUnwrap(reader.entries.first, relativePath)
            let dataOffset = try XCTUnwrap(
                Int(entry.formatSpecific["dataOffset"] ?? ""),
                relativePath
            )
            let dataCount = try XCTUnwrap(
                entry.compressedSize.flatMap(Int.init(exactly:)),
                relativePath
            )
            XCTAssertGreaterThan(dataCount, 0, relativePath)
            seeds.append((Array(data), dataOffset, dataCount))
        }
        guard !seeds.isEmpty else {
            throw XCTSkip("LHX/LHArk lhasa corpus is absent")
        }

        var completed = 0
        for mutation in 0..<320 {
            let seed = seeds[mutation % seeds.count]
            var bytes = seed.bytes
            let first = seed.dataOffset
                + (mutation &* 131 &+ 17) % seed.dataCount
            bytes[first] ^= UInt8(truncatingIfNeeded: mutation | 1)
            if mutation.isMultiple(of: 5) {
                let second = seed.dataOffset
                    + (mutation &* 43 &+ 101) % seed.dataCount
                bytes[second] ^= 0x80
            }

            do {
                let reader = try LHAReader(
                    source: DataByteSource(data: Data(bytes)),
                    options: ReaderOptions()
                )
                if let entry = reader.entries.first {
                    _ = try reader.stream(
                        for: entry,
                        limits: ReadLimits()
                    ).readAll()
                }
            } catch {
                // A bounded rejection, including CRC failure, is expected.
            }
            completed += 1
        }
        XCTAssertEqual(completed, 320)
    }

    private func assertCorpusMember(
        relativePath: String,
        method: String,
        size: UInt64,
        sha256: String
    ) throws {
        let archive = Self.corpusRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: archive.path) else {
            throw XCTSkip("lhasa corpus archive is absent: \(relativePath)")
        }

        let reader = try ArchiveReader.open(url: archive)
        let entry = try XCTUnwrap(reader.entries.first, relativePath)
        XCTAssertEqual(reader.entries.count, 1, relativePath)
        XCTAssertEqual(entry.methodDescription, method, relativePath)
        XCTAssertEqual(entry.uncompressedSize, size, relativePath)
        let decoded = try reader.read(entry)
        XCTAssertEqual(UInt64(decoded.count), size, relativePath)
        XCTAssertEqual(hex(SHA256.hash(data: decoded)), sha256, relativePath)

        let executable = "/opt/homebrew/bin/lha"
        if FileManager.default.isExecutableFile(atPath: executable) {
            XCTAssertEqual(
                decoded,
                try lhasaMember(executable: executable, archive: archive),
                relativePath
            )
        }
    }

    private func lhasaMember(executable: String, archive: URL) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-pq", archive.path]
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let diagnostic = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            XCTFail(String(decoding: diagnostic, as: UTF8.self))
            return Data()
        }
        return data
    }

    private func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
