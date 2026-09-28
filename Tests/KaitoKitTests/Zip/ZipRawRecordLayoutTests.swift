import Foundation
@_spi(ZipRawLayout) @testable import KaitoKit
import XCTest

final class ZipRawRecordLayoutTests: XCTestCase {
    func testEncryptionCRCAndMethodAgreeWithEveryGoldenInput() throws {
        var checked = 0
        for input in try ZipGoldenCorpus.inputs() {
            for mode in ZipGoldenCorpus.modes {
                guard (try? ZipGoldenCorpus.withReader(input, options: mode.options, body: { $0.entries.count })) != nil else { continue }
                try ZipGoldenCorpus.withReader(input, options: mode.options) { reader in
                    for entry in reader.entries {
                        guard let layout = try? reader.zipRawRecordLayout(at: entry.index) else { continue }
                        let context = "\(input.id) \(mode.name) \(entry.index)"
                        let raw = try XCTUnwrap(reader.rawRecord(of: entry))
                        XCTAssertEqual(layout.compressionMethod, entry.formatSpecific["method"].flatMap(UInt16.init), context)
                        XCTAssertEqual(ZipReader.crc32Description(layout.storedCRC32), raw.formatSpecific["crc32"], context)
                        switch layout.encryption {
                        case .none:
                            XCTAssertFalse(entry.isEncrypted, context)
                            XCTAssertEqual(entry.formatSpecific["encryption"], "none", context)
                            XCTAssertEqual(entry.crc32, layout.storedCRC32, context)
                        case .zipCrypto:
                            XCTAssertTrue(entry.isEncrypted, context)
                            XCTAssertEqual(entry.formatSpecific["encryption"], "ZipCrypto", context)
                            XCTAssertEqual(entry.crc32, layout.storedCRC32, context)
                        case .winZipAES(let strength, let version):
                            XCTAssertTrue(entry.isEncrypted, context)
                            XCTAssertEqual(entry.formatSpecific["encryption"], "AES-\(64 + Int(strength) * 64)", context)
                            XCTAssertTrue([1, 2].contains(version), context)
                            if version == 2 {
                                XCTAssertNil(entry.crc32, context)
                                XCTAssertEqual(layout.storedCRC32, 0, context)
                            } else {
                                XCTAssertEqual(entry.crc32, layout.storedCRC32, context)
                            }
                        }
                        checked += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }

    func testEveryGoldenInputModeAndCallOrder() throws {
        for input in try ZipGoldenCorpus.inputs() {
            let bytes = try input.files.reduce(Data()) { try $0 + ZipGoldenCorpus.decoded($1) }
            for mode in ZipGoldenCorpus.modes {
                var options = mode.options
                options.passwordProvider = ZipLayoutForbiddenPasswordProvider()
                for order in 0..<3 {
                    let open = try? ZipGoldenCorpus.withReader(input, options: options) { $0.entries.count }
                    guard open != nil else { continue }
                    try ZipGoldenCorpus.withReader(input, options: options) { left in
                        try ZipGoldenCorpus.withReader(input, options: options) { right in
                            let indices = order == 2 ? Array(left.entries.indices.reversed()) : Array(left.entries.indices)
                            for index in indices {
                                let context = "\(input.id) \(mode.name) order=\(order) index=\(index)"
                                let publicValue: ZipLayoutOutcome
                                let spiValue: ZipLayoutOutcome
                                if order == 1 {
                                    publicValue = ZipLayoutOutcome { try left.rawRecord(of: left.entries[index]) }
                                    spiValue = ZipLayoutOutcome { try right.zipRawRecordLayout(at: index) }
                                } else {
                                    spiValue = ZipLayoutOutcome { try left.zipRawRecordLayout(at: index) }
                                    publicValue = ZipLayoutOutcome { try right.rawRecord(of: right.entries[index]) }
                                }
                                XCTAssertEqual(spiValue, publicValue, context)
                                XCTAssertEqual(ZipLayoutOutcome { try left.rawRecord(of: left.entries[index]) }, publicValue, context)
                                XCTAssertEqual(ZipLayoutOutcome { try right.zipRawRecordLayout(at: index) }, spiValue, context)
                                if let layout = try? left.zipRawRecordLayout(at: index) {
                                    XCTAssertEqual(layout.localHasZIP64Extra, try localHasZIP64(bytes, at: Int(layout.recordRange.lowerBound)), context)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func testOutOfRangeAndNonZIP() throws {
        let inputs = try [
            ZipTestSupport.makeArchive(entries: [HandZipEntry(name: "own")]),
            TarTestSupport.makeTar(entries: [HandTarEntry(name: "entry", contents: Data([1]))]),
            LHATestSupport.makeArchive(entries: [HandLHAEntry(name: "entry", contents: Data([1]), headerLevel: 0)]),
            RawRecordArchiveBuilder.solidSevenZip(),
        ]
        for bytes in inputs {
            let reader = try ArchiveReader.open(data: bytes)
            for index in [-1, reader.entries.count] {
                XCTAssertThrowsError(try reader.zipRawRecordLayout(at: index)) {
                    guard case KaitoError.notFound(let text) = $0 else { return XCTFail("\($0)") }
                    XCTAssertEqual(text, "archive entry index \(index)")
                }
            }
            if reader.format != .zip {
                for index in reader.entries.indices { XCTAssertNil(try reader.zipRawRecordLayout(at: index)) }
            }
        }
    }

    func testCRC32DescriptionAllBytePositionsAndMillionSeededValues() {
        for position in 0..<4 {
            for byte in UInt32(0)...255 {
                let value = byte << (position * 8)
                XCTAssertEqual(ZipReader.crc32Description(value), String(format: "0x%08x", value))
            }
        }
        for value: UInt32 in [0, 1, 0x7fffffff, 0x80000000, 0xffffffff] {
            XCTAssertEqual(ZipReader.crc32Description(value), String(format: "0x%08x", value))
        }
        var state: UInt64 = 0x50314b_c32
        for _ in 0..<1_000_000 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let value = UInt32(truncatingIfNeeded: state >> 16)
            XCTAssertEqual(ZipReader.crc32Description(value), String(format: "0x%08x", value))
        }
    }

    // GK の field 走査と同じ境界。検証済み local extra だけを渡す。
    private func localHasZIP64(_ bytes: Data, at offset: Int) throws -> Bool {
        let name = Int(try ZipTestSupport.readUInt16(bytes, at: offset + 26))
        let length = Int(try ZipTestSupport.readUInt16(bytes, at: offset + 28))
        var cursor = offset + 30 + name
        let end = cursor + length
        while cursor + 4 <= end {
            let identifier = try ZipTestSupport.readUInt16(bytes, at: cursor)
            let size = Int(try ZipTestSupport.readUInt16(bytes, at: cursor + 2))
            guard cursor + 4 + size <= end else { break }
            if identifier == 1 { return true }
            cursor += 4 + size
        }
        return false
    }

    // 旧名: MetadataParsingTests
    func testZIPFlagsMatchPrintfForEveryValue() {
        for flags in UInt16.min...UInt16.max {
            XCTAssertEqual(ZipReader.flagsDescription(flags), String(format: "0x%04x", flags))
        }
    }
}

struct ZipLayoutForbiddenPasswordProvider: PasswordProvider {
    func password(for format: ArchiveFormat) throws -> String? {
        XCTFail("raw layout must not request a password")
        throw KaitoError.passwordRequired
    }
}

enum ZipLayoutOutcome: Equatable {
    case none
    case value(Range<UInt64>, Range<UInt64>, Bool, Bool)
    case failure(String)
    init(_ body: () throws -> RawEntryRecord?) {
        do {
            if let value = try body() {
                self = .value(value.recordRange, value.payloadRange, value.formatSpecific["hasDataDescriptor"] == "true", value.formatSpecific["isZIP64"] == "true")
            } else { self = .none }
        } catch { self = .failure(String(describing: error)) }
    }
    init(_ body: () throws -> ZipRawRecordLayout?) {
        do {
            if let value = try body() { self = .value(value.recordRange, value.payloadRange, value.hasDataDescriptor, value.isZIP64) }
            else { self = .none }
        } catch { self = .failure(String(describing: error)) }
    }
}
