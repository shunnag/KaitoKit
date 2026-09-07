import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

final class LHAMacBinaryTests: XCTestCase {
    func testMacLHAMemberExposesOnlyDataForkAndAuthenticatesEnvelope() throws {
        let dataFork = Data((0..<513).map { UInt8(truncatingIfNeeded: $0 * 17) })
        let resourceFork = Data((0..<197).map { UInt8(truncatingIfNeeded: $0 * 29) })
        let wrapped = makeMacBinary(
            name: "page.bin",
            dataFork: dataFork,
            resourceFork: resourceFork
        )
        let archive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "page.bin",
                contents: wrapped,
                headerLevel: 2,
                creatorOS: 0x6D
            ),
        ])

        let reader = try ArchiveReader.open(data: archive)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.formatSpecific["osID"], "m")
        // The public metadata remains the size recorded in the LHA header, as
        // in lhasa's listing; the stream is the filtered data-fork view.
        XCTAssertEqual(entry.uncompressedSize, UInt64(wrapped.count))
        let stream = try reader.stream(entry)
        XCTAssertEqual(stream.remaining, UInt64(dataFork.count))
        XCTAssertEqual(try stream.readAll(), dataFork)
        XCTAssertEqual(stream.remaining, 0)
    }

    func testMacintoshPlainMemberPassesThroughWithoutMacBinaryFalsePositive() throws {
        var plain = Data("not a MacBinary header".utf8)
        plain.append(Data((0..<257).map { UInt8(truncatingIfNeeded: $0) }))
        let archive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "plain.dat",
                contents: plain,
                headerLevel: 1,
                creatorOS: 0x6D
            ),
        ])

        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(try reader.read(reader.entries[0]), plain)
    }

    func testLevelZeroMacintoshMarkerDoesNotEnableMacBinaryUnwrapping() throws {
        let wrapped = makeMacBinary(
            name: "level-zero.bin",
            dataFork: Data("data fork".utf8),
            resourceFork: Data("resource fork".utf8)
        )
        let archive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "level-zero.bin",
                contents: wrapped,
                headerLevel: 0,
                creatorOS: 0x6D
            ),
        ])

        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(try reader.read(reader.entries[0]), wrapped)
    }

    func testMacBinaryIIHeaderCRCIsAccepted() throws {
        let dataFork = Data("authenticated data fork".utf8)
        let wrapped = makeMacBinary(
            name: "crc.bin",
            dataFork: dataFork,
            resourceFork: Data("resource".utf8),
            includeHeaderCRC: true
        )
        XCTAssertEqual(Array(wrapped[124..<126]), [0x7A, 0xAB])
        let archive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "crc.bin",
                contents: wrapped,
                headerLevel: 2,
                creatorOS: 0x6D
            ),
        ])

        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(try reader.read(reader.entries[0]), dataFork)
    }

    func testMacBinaryIIComputedZeroHeaderCRCIsAccepted() throws {
        let dataFork = Data("zero crc data fork".utf8)
        var wrapped = makeMacBinary(
            name: "zero-crc.bin",
            dataFork: dataFork,
            resourceFork: Data()
        )
        // These otherwise ordinary creation-time bytes make CRC-CCITT over
        // bytes 0...123 exactly zero. The version markers deliberately fail
        // the legacy-I zero-fill heuristic, proving the zero is authenticated.
        wrapped[wrapped.startIndex + 91] = 0xDF
        wrapped[wrapped.startIndex + 92] = 0x8E
        wrapped[wrapped.startIndex + 122] = 129
        wrapped[wrapped.startIndex + 123] = 129
        let authenticatedHeader = Array(wrapped.prefix(124))
        XCTAssertEqual(macBinaryHeaderCRC(authenticatedHeader[...]), 0)
        XCTAssertEqual(Array(wrapped[124..<126]), [0, 0])

        let archive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "zero-crc.bin",
                contents: wrapped,
                headerLevel: 2,
                creatorOS: 0x6D
            ),
        ])
        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(try reader.read(reader.entries[0]), dataFork)
    }

    func testInvalidMacBinaryIIHeaderCRCPassesThrough() throws {
        let dataFork = Data("not unwrapped".utf8)
        var wrapped = makeMacBinary(
            name: "bad-crc.bin",
            dataFork: dataFork,
            resourceFork: Data(),
            includeHeaderCRC: true
        )
        wrapped[wrapped.startIndex + 73] ^= 0x01
        let archive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "bad-crc.bin",
                contents: wrapped,
                headerLevel: 2,
                creatorOS: 0x6D
            ),
        ])

        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(try reader.read(reader.entries[0]), wrapped)
    }

    func testCRCLessMacBinaryRequiresLegacyZeroFill() throws {
        let dataFork = Data("legacy lookalike".utf8)
        let valid = makeMacBinary(
            name: "legacy.bin",
            dataFork: dataFork,
            resourceFork: Data()
        )
        let nameTerminator = 2 + "legacy.bin".utf8.count

        for changedOffset in [nameTerminator, 101] {
            var lookalike = valid
            lookalike[lookalike.startIndex + changedOffset] = 1
            let archive = try LHATestSupport.makeArchive(entries: [
                HandLHAEntry(
                    name: "legacy.bin",
                    contents: lookalike,
                    headerLevel: 2,
                    creatorOS: 0x6D
                ),
            ])
            let reader = try ArchiveReader.open(data: archive)
            XCTAssertEqual(try reader.read(reader.entries[0]), lookalike)
        }
    }

    func testCompatibleTrailingDataIsDrainedAndAuthenticated() throws {
        let dataFork = Data("visible fork".utf8)
        var wrapped = makeMacBinary(
            name: "extended.bin",
            dataFork: dataFork,
            resourceFork: Data("resource".utf8)
        )
        wrapped.append(Data([0x4D, 0x42, 0x45, 0x58]))
        let crc = CRC16.checksum(Array(wrapped))
        let goodArchive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "extended.bin",
                contents: wrapped,
                headerLevel: 2,
                creatorOS: 0x6D
            ),
        ])
        let badArchive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "extended.bin",
                contents: wrapped,
                headerLevel: 2,
                creatorOS: 0x6D,
                dataCRC16: crc ^ 1
            ),
        ])

        let goodReader = try ArchiveReader.open(data: goodArchive)
        XCTAssertEqual(try goodReader.read(goodReader.entries[0]), dataFork)

        let badReader = try ArchiveReader.open(data: badArchive)
        XCTAssertThrowsError(try badReader.read(badReader.entries[0])) { error in
            XCTAssertEqual(error as? KaitoError, .checksumMismatch(entry: 0))
        }
    }

    func testMacBinaryEnvelopeCRCStillCoversHeaderPaddingAndResourceFork() throws {
        let wrapped = makeMacBinary(
            name: "empty",
            dataFork: Data(),
            resourceFork: Data("resource data".utf8)
        )
        let goodCRC = CRC16.checksum(Array(wrapped))
        let archive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "empty",
                contents: wrapped,
                headerLevel: 2,
                creatorOS: 0x6D,
                dataCRC16: goodCRC ^ 1
            ),
        ])
        let reader = try ArchiveReader.open(data: archive)

        XCTAssertThrowsError(try reader.stream(reader.entries[0])) { error in
            XCTAssertEqual(error as? KaitoError, .checksumMismatch(entry: 0))
        }
    }

    func testMacLHACorpusDataForksMatchKnownLhasaDigests() throws {
        let fixtures: [(String, Int, String)] = [
            (
                "l1_lh0.lzh",
                6_829,
                "5c423e9bdf915d23972369959f5a71bfbcc1d32d09fb8d7198755861d289966e"
            ),
            (
                "l1_lh1.lzh",
                18_092,
                "8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643"
            ),
            (
                "l1_lh5.lzh",
                18_092,
                "8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643"
            ),
            (
                "l1_subdir.lzh",
                11,
                "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
            ),
            (
                "l2_lh0.lzh",
                6_829,
                "5c423e9bdf915d23972369959f5a71bfbcc1d32d09fb8d7198755861d289966e"
            ),
            (
                "l2_lh1.lzh",
                18_092,
                "8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643"
            ),
            (
                "l2_lh5.lzh",
                18_092,
                "8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643"
            ),
            (
                "l2_subdir.lzh",
                11,
                "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
            ),
        ]
        let corpusDirectory = try requireCorpus(fixtures.map(\.0))

        for (filename, expectedSize, expectedDigest) in fixtures {
            let archive = corpusDirectory.appendingPathComponent(filename)
            let reader = try ArchiveReader.open(url: archive)
            let entry = try XCTUnwrap(reader.entries.first, filename)
            let decoded = try reader.read(entry)
            XCTAssertEqual(decoded.count, expectedSize, filename)
            XCTAssertEqual(sha256(decoded), expectedDigest, filename)
        }
    }

    func testMacLHAFullPathCorpusMembersAlsoExposeTheirDataForks() throws {
        let filenames = ["l1_full_subdir.lzh", "l2_full_subdir.lzh"]
        let corpusDirectory = try requireCorpus(filenames)

        for filename in filenames {
            let archive = corpusDirectory.appendingPathComponent(filename)
            let reader = try ArchiveReader.open(url: archive)
            let decoded = try reader.read(try XCTUnwrap(reader.entries.first))
            XCTAssertEqual(decoded, Data("hello world".utf8), filename)
        }
    }

    func testMacLHANoMacBinaryCorpusMembersRemainPlain() throws {
        let filenames = ["l1_nm_lh5.lzh", "l2_nm_lh5.lzh"]
        let corpusDirectory = try requireCorpus(filenames)

        for filename in filenames {
            let archive = corpusDirectory.appendingPathComponent(filename)
            let reader = try ArchiveReader.open(url: archive)
            let decoded = try reader.read(try XCTUnwrap(reader.entries.first))
            XCTAssertEqual(decoded.count, 18_092, filename)
            XCTAssertEqual(
                sha256(decoded),
                "8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643",
                filename
            )
        }
    }

    func testMacLHALevelZeroCorpusMemberRemainsWrappedWithoutOSMarker() throws {
        let filename = "l0_lh0.lzh"
        let corpusDirectory = try requireCorpus([filename])
        let archive = corpusDirectory.appendingPathComponent(filename)
        let reader = try ArchiveReader.open(url: archive)
        let decoded = try reader.read(try XCTUnwrap(reader.entries.first))

        XCTAssertEqual(decoded.count, 7_040)
        XCTAssertEqual(
            sha256(decoded),
            "c3ccce5d607be6bcc09ffe0146069c8d8b4d72bd3d2d9ef788e6d855331b1df9"
        )
    }

    private func requireCorpus(_ filenames: [String]) throws -> URL {
        guard let root = LHATestSupport.corpusRoot else {
            throw XCTSkip("set KAITOKIT_LHA_CORPUS to run the LHA corpus tests")
        }
        let corpusDirectory = root.appendingPathComponent("maclha_224", isDirectory: true)
        let manager = FileManager.default
        let missing = filenames.filter {
            !manager.fileExists(
                atPath: corpusDirectory.appendingPathComponent($0).path
            )
        }
        guard missing.isEmpty else {
            throw XCTSkip("MacLHA corpus is absent: \(missing.joined(separator: ", "))")
        }
        return corpusDirectory
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeMacBinary(
        name: String,
        dataFork: Data,
        resourceFork: Data,
        includeHeaderCRC: Bool = false
    ) -> Data {
        let nameBytes = Array(name.utf8)
        precondition((1...63).contains(nameBytes.count))
        precondition(dataFork.count <= Int(UInt32.max))
        precondition(resourceFork.count <= Int(UInt32.max))

        var header = [UInt8](repeating: 0, count: 128)
        header[1] = UInt8(nameBytes.count)
        header.replaceSubrange(2..<(2 + nameBytes.count), with: nameBytes)
        header.replaceSubrange(65..<69, with: Array("BINA".utf8))
        header.replaceSubrange(69..<73, with: Array("TEST".utf8))
        writeUInt32BE(UInt32(dataFork.count), in: &header, at: 83)
        writeUInt32BE(UInt32(resourceFork.count), in: &header, at: 87)
        if includeHeaderCRC {
            header[122] = 129
            header[123] = 129
            writeUInt16BE(macBinaryHeaderCRC(header[..<124]), in: &header, at: 124)
        }

        var result = Data(header)
        result.append(dataFork)
        appendPadding(to: &result, forPayloadSize: dataFork.count)
        result.append(resourceFork)
        appendPadding(to: &result, forPayloadSize: resourceFork.count)
        return result
    }

    private func appendPadding(to data: inout Data, forPayloadSize size: Int) {
        let padding = (128 - size % 128) % 128
        data.append(Data(repeating: 0, count: padding))
    }

    private func writeUInt32BE(
        _ value: UInt32,
        in bytes: inout [UInt8],
        at offset: Int
    ) {
        bytes[offset] = UInt8(truncatingIfNeeded: value >> 24)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value)
    }

    private func writeUInt16BE(
        _ value: UInt16,
        in bytes: inout [UInt8],
        at offset: Int
    ) {
        bytes[offset] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value)
    }

    private func macBinaryHeaderCRC(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0
                    ? (crc << 1) ^ 0x1021
                    : crc << 1
            }
        }
        return crc
    }
}
