import Foundation
@testable import KaitoKit
import XCTest

final class RAR4LegacyVersionTests: XCTestCase {
    func testCompressedUnpackVersions15_20And26AreExplicitlyUnsupported() throws {
        for version: UInt8 in [15, 20, 26] {
            let reader = try ArchiveReader.open(data: makeArchive(unpackVersion: version))
            let entry = try XCTUnwrap(reader.entries.first)
            XCTAssertThrowsError(try reader.stream(entry)) { error in
                XCTAssertEqual(
                    error as? KaitoError,
                    .unsupportedMethod("RAR4 unpack version \(version)")
                )
            }
        }
    }

    private func makeArchive(unpackVersion: UInt8) -> Data {
        var archive = Data(RAR4Reader.signature)
        archive.append(contentsOf: makeHeader(
            type: 0x73,
            flags: 0,
            fields: [0, 0, 0, 0, 0, 0]
        ))

        var fields: [UInt8] = []
        appendLittle(UInt32(1), to: &fields)
        appendLittle(UInt32(1), to: &fields)
        fields.append(2)
        appendLittle(UInt32(0), to: &fields)
        appendLittle(UInt32(0), to: &fields)
        fields.append(unpackVersion)
        fields.append(0x31)
        appendLittle(UInt16("legacy.bin".utf8.count), to: &fields)
        appendLittle(UInt32(0x20), to: &fields)
        fields.append(contentsOf: "legacy.bin".utf8)
        archive.append(contentsOf: makeHeader(
            type: 0x74,
            flags: 0x8000,
            fields: fields
        ))
        archive.append(0)
        archive.append(contentsOf: makeHeader(type: 0x7b, flags: 0, fields: []))
        return archive
    }

    private func makeHeader(type: UInt8, flags: UInt16, fields: [UInt8]) -> [UInt8] {
        var body = [type]
        appendLittle(flags, to: &body)
        appendLittle(UInt16(7 + fields.count), to: &body)
        body.append(contentsOf: fields)
        var header: [UInt8] = []
        appendLittle(UInt16(truncatingIfNeeded: CRC32.checksum(body)), to: &header)
        header.append(contentsOf: body)
        return header
    }

    private func appendLittle<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
    }
}
