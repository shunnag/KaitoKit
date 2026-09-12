// Clean-room format inputs: Ch.00・01・02・04・06 の境界条件から構成した検査。
// XADMaster / The Unarchiver / stuffit-go 等の実装ソースは参照していない。
import Foundation
@testable import KaitoKit
import XCTest

final class StuffItHardeningTests: XCTestCase {
    struct RefusingPassword: PasswordProvider {
        func password(for format: ArchiveFormat) throws -> String? { throw KaitoError.passwordRequired }
    }
    private func classicCRC(_ data: inout Data) {
        let crc = CRC16.checksum(Array(data[22..<132]))
        data[132] = UInt8(crc >> 8); data[133] = UInt8(crc & 255)
    }
    private func sit5CRC(_ data: inout Data) {
        let length = Int(data[106]) * 256 + Int(data[107])
        data[132] = 0; data[133] = 0
        let crc = CRC16.checksum(Array(data[100..<100 + length]))
        data[132] = UInt8(crc >> 8); data[133] = UInt8(crc & 255)
    }
    func testDirectoryStateValidation() throws {
        for pair: (UInt8, UInt8) in [(0x20, 0x21), (0x21, 0), (0x20, 0)] {
            var data = StuffItContainerTests.classic(payload: [], size: 0)
            data[22] = pair.0; data[23] = pair.1; classicCRC(&data)
            XCTAssertThrowsError(try ArchiveReader.open(data: data))
        }
        var begin = StuffItContainerTests.classic(payload: [], size: 0)
        begin[22] = 0x20; classicCRC(&begin)
        var end = begin; end[22] = 0x21; classicCRC(&end)
        var data = begin + StuffItContainerTests.classic().dropFirst(22) + end.dropFirst(22)
        var bytes = Array(data); StuffItContainerTests.put(UInt64(data.count), 4, 6, &bytes); data = Data(bytes)
        let reader = try ArchiveReader.open(data: data)
        XCTAssertEqual(reader.entries[0].kind, .directory)
        XCTAssertEqual(reader.entries[1].pathComponents, ["A", "A"])
        XCTAssertEqual(try reader.read(reader.entries[1]), Data([65, 66]))
    }
    func testSIT5CommentParentAndMarkerBoundaries() throws {
        var bad = StuffItContainerTests.sit5()
        bad[129] = 1; sit5CRC(&bad)
        XCTAssertThrowsError(try ArchiveReader.open(data: bad))
        bad = StuffItContainerTests.sit5(); bad[131] = 0; sit5CRC(&bad)
        XCTAssertThrowsError(try ArchiveReader.open(data: bad))
        let base = StuffItContainerTests.sit5()
        var marker = [UInt8](repeating: 0, count: 48)
        marker.replaceSubrange(0..<4, with: [0xa5, 0xa5, 0xa5, 0xa5]); marker[9] = 0x40
        marker.replaceSubrange(34..<38, with: [255, 255, 255, 255])
        var bytes = Array(base.prefix(100)) + marker + base.dropFirst(100)
        StuffItContainerTests.put(UInt64(bytes.count), 4, 84, &bytes)
        bytes[98] = 0; bytes[99] = 0
        StuffItContainerTests.put(UInt64(CRC16.checksum(Array(bytes[..<100]))), 2, 98, &bytes)
        let reader = try ArchiveReader.open(data: Data(bytes))
        XCTAssertEqual(reader.entries.count, 1)
        XCTAssertEqual(try reader.read(reader.entries[0]), Data([65, 66]))
    }
    func testEncodingAndMetadataLimits() throws {
        var data = StuffItContainerTests.classic()
        data[25] = 0x8e; classicCRC(&data)
        let fixed = try ArchiveReader.open(data: data, options: ReaderOptions(encodingPolicy: .fixed(.macOSRoman)))
        XCTAssertEqual(fixed.entries[0].name, "é"); XCTAssertEqual(fixed.entries[0].rawName.bytes, [0x8e])
        let auto = try ArchiveReader.open(data: data, options: ReaderOptions(encodingPolicy: .automatic(likelyLanguage: "en")))
        XCTAssertEqual(auto.entries[0].name, "é")
        for limits in [ReadLimits(maxEntrySize: 1), ReadLimits(maxEntryCount: 0), ReadLimits(maxMetadataSize: 10),
                       ReadLimits(maxPathComponentCount: 0), ReadLimits(maxTotalMetadataSize: 1)] {
            XCTAssertThrowsError(try ArchiveReader.open(data: data, options: ReaderOptions(limits: limits)))
        }
        let encrypted = try ArchiveReader.open(data: StuffItContainerTests.classic(method: 0x80),
                                              options: ReaderOptions(passwordProvider: RefusingPassword()))
        XCTAssertThrowsError(try encrypted.stream(encrypted.entries[0])) { XCTAssertEqual($0 as? KaitoError, .unsupportedMethod("StuffIt encryption")) }
    }
    func testCodecErrorsAreBoundedAndTyped() throws {
        for packed in [Data([0x90]), Data()] {
            XCTAssertThrowsError(try StuffItCodecTests.decode(packed, method: 1, size: 2)) { XCTAssertEqual($0 as? KaitoError, .truncated) }
        }
        XCTAssertThrowsError(try StuffItCodecTests.decode(Data([0x90, 1]), method: 1, size: 1)) {
            guard case KaitoError.malformed = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try StuffItCodecTests.decode(Data([0x90, 3]), method: 1, size: 2), Data([0, 0]))
        for method in [2, 3, 13, 15] {
            XCTAssertThrowsError(try StuffItCodecTests.decode(Data(), method: method, size: 1))
            XCTAssertThrowsError(try StuffItCodecTests.decode(Data(repeating: 0, count: 1000), method: method, size: 10,
                                                             limits: ReadLimits(maxDictionarySize: 1)))
        }
        XCTAssertThrowsError(try StuffItCodecTests.decode(Data(repeating: 0, count: 2000), method: 3, size: 1))
        XCTAssertThrowsError(try StuffItCodecTests.decode(Data([0x60]), method: 13, size: 1))
        let short = StuffItCodecTests.hex("4184041c08")
        XCTAssertThrowsError(try StuffItCodecTests.decode(short, method: 2, size: 8)) { XCTAssertEqual($0 as? KaitoError, .truncated) }
    }
    private func packedLSB(_ codes: [(Int, Int)]) -> Data {
        var result = Data(), bits = 0, value: UInt64 = 0
        for (code, width) in codes {
            value |= UInt64(code) << bits; bits += width
            while bits >= 8 { result.append(UInt8(value & 255)); value >>= 8; bits -= 8 }
        }
        if bits != 0 { result.append(UInt8(value)) }
        return result
    }
    func testLZWClearSlotsWidthChangesAndFullDictionary() throws {
        let clear = packedLSB([(65, 9), (256, 9)] + Array(repeating: (511, 9), count: 6) + [(66, 9)])
        XCTAssertEqual(try StuffItCodecTests.decode(clear, method: 2, size: 2), Data([65, 66]))
        var codes: [(Int, Int)] = []
        var width = 9
        for i in 0..<20_000 {
            codes.append((i & 255, width))
            if i > 0 && i + 257 == 1 << width && width < 14 { width += 1 }
        }
        XCTAssertEqual(try StuffItCodecTests.decode(packedLSB(codes), method: 2, size: 20_000, chunk: 313),
                       Data((0..<20_000).map { UInt8($0 & 255) }))
    }
    func testMethod13RejectsInvalidLengthGrammar() throws {
        func meta(_ symbol: Int) -> (Int, Int) { (StuffItTables.metaCodes[symbol], StuffItTables.metaLengths[symbol]) }
        let crossing = [(8, 8), meta(31)] + Array(repeating: [meta(36), (63, 6)], count: 5).flatMap { $0 }
        for packed in [packedLSB(crossing), packedLSB([(8, 8), meta(31), meta(33)])] {
            XCTAssertThrowsError(try StuffItCodecTests.decode(packed, method: 13, size: 1)) {
                guard case KaitoError.malformed = $0 else { return XCTFail("\($0)") }
            }
        }
        XCTAssertThrowsError(try StuffItPrefixTree.canonical([1, 1, 1]))
        let incomplete = try StuffItPrefixTree.canonical([1])
        let input = try StuffItPackedInput(source: DataByteSource(data: Data([128])), offset: 0, size: 1)
        XCTAssertThrowsError(try incomplete.decode(input, lsb: false))
    }
    func testHuffmanAllowsMoreLeavesThanByteValues() throws {
        var bits: [Int] = []
        func tree(_ low: Int, _ high: Int) {
            if high - low == 1 {
                bits.append(1)
                for shift in stride(from: 7, through: 0, by: -1) { bits.append((low >> shift) & 1) }
            } else {
                bits.append(0)
                let middle = (low + high) / 2
                tree(low, middle); tree(middle, high)
            }
        }
        tree(0, 257)
        bits.append(contentsOf: repeatElement(0, count: 8))
        var packed = Data()
        for start in stride(from: 0, to: bits.count, by: 8) {
            var byte: UInt8 = 0
            for i in 0..<8 { byte = byte << 1 | UInt8(start + i < bits.count ? bits[start + i] : 0) }
            packed.append(byte)
        }
        XCTAssertEqual(try StuffItCodecTests.decode(packed, method: 3, size: 1), Data([0]))
    }

    func testShortByteSourceAndChunkIndependence() throws {
        final class ShortSource: ByteSource {
            let data: Data
            init(_ data: Data) { self.data = data }
            var length: UInt64 { UInt64(data.count) }
            func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
                guard offset < length, !buffer.isEmpty else { return 0 }
                buffer[0] = data[Int(offset)]; return 1
            }
        }
        let source = ShortSource(StuffItWrapperTests.binHex(StuffItContainerTests.sit5(resource: [67])))
        let reader = try ArchiveReader.open(source: source)
        XCTAssertEqual(try reader.read(reader.entries[0]), Data([67]))
        XCTAssertEqual(try reader.read(reader.entries[1]), Data([65, 66]))
    }
}
