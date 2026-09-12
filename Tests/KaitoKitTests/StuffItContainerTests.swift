// Clean-room format inputs: 指定レポート Ch.00・01・02 の記述から組み立てる検査用容器。
// XADMaster / The Unarchiver / stuffit-go 等の実装ソースは参照していない。
import Foundation
@testable import KaitoKit
import XCTest

final class StuffItContainerTests: XCTestCase {
    static func put(_ value: UInt64, _ bytes: Int, _ offset: Int, _ b: inout [UInt8]) {
        for i in 0..<bytes { b[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * (bytes - i - 1))) }
    }
    static func classic(method: UInt8 = 0, payload: [UInt8] = [65, 66], size: UInt64 = 2) -> Data {
        var b = [UInt8](repeating: 0, count: 134)
        b.replaceSubrange(0..<4, with: "SIT!".utf8)
        b.replaceSubrange(10..<14, with: "rLau".utf8)
        put(UInt64(134 + payload.count), 4, 6, &b)
        b[23] = method; b[24] = 1; b[25] = 65
        put(size, 4, 110, &b); put(UInt64(payload.count), 4, 118, &b)
        put(UInt64(CRC16.checksum(payload)), 2, 124, &b)
        put(UInt64(CRC16.checksum(Array(b[22..<132]))), 2, 132, &b)
        return Data(b + payload)
    }
    static func sit5(payload: [UInt8] = [65, 66], resource: [UInt8]? = nil) -> Data {
        var b = [UInt8](repeating: 0, count: 181 + (resource == nil ? 0 : 14))
        b.replaceSubrange(0..<80, with: "StuffIt (c)1997-2001 Aladdin Systems, Inc., http://www.aladdinsys.com/StuffIt/\r\n".utf8)
        b[82] = 5; put(UInt64(b.count + payload.count + (resource?.count ?? 0)), 4, 84, &b)
        put(1, 2, 92, &b); put(100, 4, 94, &b)
        b.replaceSubrange(100..<104, with: [0xa5, 0xa5, 0xa5, 0xa5])
        b[104] = 3; put(49, 2, 106, &b); put(1, 2, 130, &b); b[148] = 65
        put(UInt64(payload.count), 4, 134, &b); put(UInt64(payload.count), 4, 138, &b)
        put(UInt64(CRC16.checksum(payload)), 2, 142, &b)
        if let resource {
            b[150] = 1
            put(UInt64(resource.count), 4, 181, &b); put(UInt64(resource.count), 4, 185, &b)
            put(UInt64(CRC16.checksum(resource)), 2, 189, &b)
        }
        put(UInt64(CRC16.checksum(Array(b[100..<149]))), 2, 132, &b)
        put(UInt64(CRC16.checksum(Array(b[0..<100]))), 2, 98, &b)
        return Data(b + (resource ?? []) + payload)
    }

    func testStoredContainersAndForks() throws {
        for data in [Self.classic(), Self.sit5(), Self.sit5(resource: [67])] {
            let reader = try ArchiveReader.open(data: data)
            XCTAssertEqual(reader.format, .stuffIt)
            XCTAssertEqual(try reader.read(try XCTUnwrap(reader.entries.last)), Data([65, 66]))
            if reader.entries.count == 2 {
                XCTAssertEqual(reader.entries[0].pathComponents, ["A", "..namedfork", "rsrc"])
                XCTAssertEqual(reader.entries[0].name, "A/..namedfork/rsrc")
                XCTAssertEqual(reader.entries[0].formatSpecific["fork"], "resource")
                XCTAssertEqual(try reader.read(reader.entries[0]), Data([67]))
            }
        }
    }
    func testHeaderCRCsAndExtent() throws {
        for base in [Self.classic(), Self.sit5()] {
            var bad = base; bad[132] ^= 1
            XCTAssertThrowsError(try ArchiveReader.open(data: bad))
            XCTAssertThrowsError(try ArchiveReader.open(data: base.dropLast()))
        }
        var bad = Self.sit5(); bad[98] ^= 1
        XCTAssertThrowsError(try ArchiveReader.open(data: bad))
    }
    func testUnsupportedAndEncryptedListBeforeReading() throws {
        for method: UInt8 in [4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 0x80] {
            let reader = try ArchiveReader.open(data: Self.classic(method: method))
            XCTAssertEqual(reader.entries.count, 1)
            XCTAssertEqual(reader.entries[0].isEncrypted, method == 0x80)
            XCTAssertThrowsError(try reader.stream(reader.entries[0])) { error in
                guard case KaitoError.unsupportedMethod(let name) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(name, method == 0x80 ? "StuffIt encryption" : "StuffIt method \(method)")
            }
        }
    }
    func testSignaturesDoNotScanForSFX() throws {
        for signature in ["SIT!", "STin", "STi0", "STi9", "ST00", "ST99"] {
            var data = Self.classic(); data.replaceSubrange(0..<4, with: signature.utf8)
            XCTAssertEqual(try FormatDetector.detect(data: data), .stuffIt)
        }
        XCTAssertThrowsError(try ArchiveReader.open(data: Data(repeating: 0, count: 512) + Self.classic()))
        XCTAssertThrowsError(try ArchiveReader.open(data: Self.classic(size: 1)).read(
            ArchiveReader.open(data: Self.classic(size: 1)).entries[0]))
    }
}
