// Clean-room format inputs: 指定レポート Ch.00・06 の記述から wrapper と CRC を構成する。
// XADMaster / The Unarchiver / stuffit-go 等の実装ソースは参照していない。
import Foundation
@testable import KaitoKit
import XCTest

final class StuffItWrapperTests: XCTestCase {
    static func macBinary(_ data: Data, resource: Data = StuffItSlice2CryptoTests.resources(), version: Int = 2, usb: Bool = false) -> Data {
        var h = [UInt8](repeating: 0, count: 256)
        h[1] = 1; h[2] = 65
        StuffItContainerTests.put(UInt64(data.count), 4, 83, &h)
        StuffItContainerTests.put(UInt64(resource.count), 4, 87, &h)
        h[94] = 1; h[98] = 1
        if version != 1 {
            h[121] = 1
            if version == 3 { h.replaceSubrange(102..<106, with: "mBIN".utf8) }
            let crc = usb ? h.withUnsafeBytes { CRC16.update(UnsafeRawBufferPointer(rebasing: $0[..<124]), initial: 0xffff, folding: false) } ^ 0xffff
                          : StuffItWrapper.xmodem(h[..<124])
            StuffItContainerTests.put(UInt64(crc), 2, 124, &h)
        } else { h.removeLast(128) }
        return Data(h) + data + Data(repeating: 0, count: (128 - data.count % 128) % 128) + resource
    }
    static func appleSingle(_ data: Data, little: Bool = false, double: Bool = false) -> Data {
        let resource = StuffItSlice2CryptoTests.resources()
        var h = [UInt8](repeating: 0, count: 50)
        func put(_ value: UInt64, _ n: Int, _ p: Int) {
            for i in 0..<n { h[p + i] = UInt8(truncatingIfNeeded: value >> (8 * (little ? i : n - i - 1))) }
        }
        put(double ? 0x00051607 : 0x00051600, 4, 0); put(0x00020000, 4, 4); put(2, 2, 24)
        put(1, 4, 26); put(UInt64(50 + resource.count), 4, 30); put(UInt64(data.count), 4, 34)
        put(2, 4, 38); put(50, 4, 42); put(UInt64(resource.count), 4, 46)
        return Data(h) + resource + data
    }
    static func binHex(_ data: Data, corruptFork: Bool = false) -> Data {
        let resource = StuffItSlice2CryptoTests.resources()
        var h = [UInt8](repeating: 0, count: 23)
        h[0] = 1; h[1] = 65
        StuffItContainerTests.put(UInt64(data.count), 4, 13, &h)
        StuffItContainerTests.put(UInt64(resource.count), 4, 17, &h)
        StuffItContainerTests.put(UInt64(StuffItWrapper.xmodem(h[..<21])), 2, 21, &h)
        var decoded = h + data + [0, 0] + resource + [0, 0]
        StuffItContainerTests.put(UInt64(StuffItWrapper.xmodem(data)) ^ (corruptFork ? 1 : 0), 2, 23 + data.count, &decoded)
        StuffItContainerTests.put(UInt64(StuffItWrapper.xmodem(resource)), 2, decoded.count - 2, &decoded)
        let escaped = decoded.flatMap { $0 == 0x90 ? [UInt8(0x90), 0] : [$0] }
        let alphabet = Array("!\"#$%&'()*+,-012345689@ABCDEFGHIJKLMNPQRSTUVXYZ[`abcdefhijklmpqr".utf8)
        var result = Array("(This file must be converted with BinHex 4.0)\r\n\r\n:".utf8)
        var value = 0, bits = 0
        for byte in escaped {
            value = (value << 8) | Int(byte); bits += 8
            while bits >= 6 { bits -= 6; result.append(alphabet[(value >> bits) & 63]) }
            value &= (1 << bits) - 1
        }
        if bits > 0 { result.append(alphabet[(value << (6 - bits)) & 63]) }
        result.append(58)
        return Data(result)
    }
    func testWrapperForkBoundsAndPreservation() throws {
        let inner = StuffItContainerTests.classic()
        for wrapped in [Self.macBinary(inner), Self.macBinary(inner, version: 1), Self.macBinary(inner, version: 3),
                        Self.macBinary(inner, usb: true), Self.appleSingle(inner), Self.appleSingle(inner, little: true), Self.binHex(inner)] {
            let source = DataByteSource(data: wrapped)
            let envelope = try XCTUnwrap(FormatDetector.stuffItInput(source: source, limits: ReadLimits()))
            XCTAssertEqual(envelope.data.length, UInt64(inner.count))
            XCTAssertEqual(envelope.resource?.length, UInt64(Self.emptyResourceSize))
            let reader = try StuffItReader(source: envelope.data, resourceFork: envelope.resource, options: ReaderOptions())
            XCTAssertNotNil(reader.archiveResourceFork)
            XCTAssertEqual(try ArchiveReader.open(data: wrapped).format, .stuffIt)
            XCTAssertEqual(try reader.stream(for: reader.entries[0], limits: ReadLimits()).readAll(), Data([65, 66]))
        }
    }
    private static var emptyResourceSize: Int { StuffItSlice2CryptoTests.resources().count }
    func testRejectedWrappersAndMemoryLimit() throws {
        let inner = StuffItContainerTests.classic()
        for bad in [Self.appleSingle(inner, double: true), Self.macBinary(Data([1, 2, 3])),
                    Self.macBinary(Self.macBinary(inner)), Self.binHex(inner, corruptFork: true)] {
            XCTAssertThrowsError(try ArchiveReader.open(data: bad))
        }
        var options = ReaderOptions(); options.limits.maxInMemorySize = 20
        XCTAssertThrowsError(try ArchiveReader.open(data: Self.binHex(inner), options: options)) { error in
            guard case KaitoError.limitExceeded = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try ArchiveReader.open(data: Data(repeating: 32, count: 65_536) + Self.binHex(inner)))
    }
}
