import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

final class RawEntryRecordTests: XCTestCase {
    func testRawZIPRecordsRoundTripAfterReorderingAndDeletion() throws {
        let inputs = try [
            HandZipEntry(name: "stored.txt", uncompressedData: Data("stored\n".utf8)),
            RawRecordArchiveBuilder.descriptorEntry(name: "signed32.txt", signed: true, zip64: false),
            RawRecordArchiveBuilder.descriptorEntry(name: "unsigned32.txt", signed: false, zip64: false),
            RawRecordArchiveBuilder.descriptorEntry(name: "signed64.txt", signed: true, zip64: true),
            RawRecordArchiveBuilder.descriptorEntry(name: "unsigned64.txt", signed: false, zip64: true),
            HandZipEntry(name: "empty/"),
        ]
        let original = try ZipTestSupport.makeArchive(entries: inputs)
        let reader = try ArchiveReader.open(data: original)
        let records = try checkedRecords(reader: reader, bytes: original)
        let temporary = try ZipTestSupport.temporaryDirectory(label: "raw-roundtrip")
        defer { try? FileManager.default.removeItem(at: temporary) }

        // 全 entry の順序を逆転し、次に一部を削除する。CD 順も local 順から独立させる。
        for kept in [Array(inputs.indices), [1, 3, 5]] {
            let rebuilt = try RawRecordArchiveBuilder.rebuildZIP(
                source: original, records: records, localOrder: kept.reversed(), centralOrder: kept
            )
            let destination = temporary.appendingPathComponent("rebuilt-\(kept.count).zip")
            try rebuilt.write(to: destination)
            let reopened = try ArchiveReader.open(url: destination)
            XCTAssertEqual(reopened.entries.map(\.name), kept.map { String(decoding: inputs[$0].rawName, as: UTF8.self) })
            // 最後の CD entry から取得し、既存の local 順検証とキャッシュも通す。
            var relocated: [Int: RawEntryRecord] = [:]
            for entry in reopened.entries.reversed() {
                relocated[entry.index] = try XCTUnwrap(reopened.rawRecord(of: entry))
            }
            for (newIndex, oldIndex) in kept.enumerated() {
                let entry = reopened.entries[newIndex]
                XCTAssertEqual(try reopened.read(entry), inputs[oldIndex].uncompressedData)
                let newRecord = try XCTUnwrap(relocated[newIndex])
                XCTAssertEqual(slice(rebuilt, newRecord.recordRange), slice(original, records[oldIndex].recordRange))
            }
            let oracle = try ZipTestSupport.checkedRun("/usr/bin/unzip", arguments: ["-t", destination.path])
            XCTAssertTrue(oracle.succeeded, oracle.diagnostics)
            print("raw record rebuild: \(kept.count) entries, unzip -t: \(oracle.terminationStatus)")
        }
    }

    func testZIP32DescriptorsWithAndWithoutSignature() throws {
        for signed in [false, true] {
            let input = try RawRecordArchiveBuilder.descriptorEntry(signed: signed, zip64: false)
            let bytes = try ZipTestSupport.makeArchive(entries: [input])
            for lazy in [false, true] {
                let reader = try ArchiveReader.open(data: bytes, options: ReaderOptions(lazyLocalHeaders: lazy))
                let record = try XCTUnwrap(checkedRecords(reader: reader, bytes: bytes).first)
                XCTAssertEqual(record.recordRange.upperBound - record.payloadRange.upperBound, signed ? 16 : 12)
                XCTAssertEqual(record.formatSpecific["isZIP64"], "false")
                XCTAssertEqual(record.formatSpecific["hasDataDescriptor"], "true")
                XCTAssertEqual(record.formatSpecific["flags"], "0x0808")
                XCTAssertEqual(record.formatSpecific["method"], "8")
                XCTAssertEqual(record.formatSpecific["crc32"], String(format: "0x%08x", CRC32.checksum(input.uncompressedData)))
            }
        }
    }

    func testZIP64DescriptorsUseEightByteSizesForSmallEntries() throws {
        for signed in [false, true] {
            for fields in [(true, true), (true, false), (false, true)] {
                let input = try RawRecordArchiveBuilder.descriptorEntry(
                    signed: signed, zip64: true, localZIP64: fields.0, centralZIP64: fields.1
                )
                let bytes = try ZipTestSupport.makeArchive(entries: [input])
                let reader = try ArchiveReader.open(data: bytes)
                let record = try XCTUnwrap(checkedRecords(reader: reader, bytes: bytes).first)
                XCTAssertEqual(record.recordRange.upperBound - record.payloadRange.upperBound, signed ? 24 : 20)
                XCTAssertEqual(record.formatSpecific["isZIP64"], "true")
            }
        }
    }

    func testZIP64ExtraWithZeroLocalSizesStillUsesWideDescriptor() throws {
        var input = try RawRecordArchiveBuilder.descriptorEntry(signed: false, zip64: true, centralZIP64: false)
        input.localCompressedSize = 0
        input.localUncompressedSize = 0
        let bytes = try ZipTestSupport.makeArchive(entries: [input])
        let reader = try ArchiveReader.open(data: bytes)
        let record = try XCTUnwrap(checkedRecords(reader: reader, bytes: bytes).first)
        XCTAssertEqual(record.recordRange.upperBound - record.payloadRange.upperBound, 20)
    }

    func testSFXOffsetsAreAbsoluteAndZIP64EndDoesNotWidenZIP32Descriptor() throws {
        let prefix = ZipTestSupport.makePEPrefix(count: 1_024)
        for forceZIP64End in [false, true] {
            var bytes = try ZipTestSupport.makeArchive(
                entries: [RawRecordArchiveBuilder.descriptorEntry(signed: true, zip64: false)],
                prefix: prefix, forceZIP64End: forceZIP64End
            )
            let layout = try ZipTestSupport.layout(of: bytes)
            // version needed が 4.5 でも、entry に ZIP64 extra がなければ幅は 32 bit。
            try ZipTestSupport.writeUInt16(45, to: &bytes, at: layout.localHeaderOffsets[0] + 4)
            try ZipTestSupport.writeUInt16(45, to: &bytes, at: layout.centralEntryOffsets[0] + 6)
            let reader = try ArchiveReader.open(data: bytes, options: ReaderOptions(scanForSFXInData: true))
            let record = try XCTUnwrap(checkedRecords(reader: reader, bytes: bytes).first)
            XCTAssertEqual(record.recordRange.lowerBound, UInt64(prefix.count))
            XCTAssertEqual(record.recordRange.upperBound - record.payloadRange.upperBound, 16)
            XCTAssertEqual(record.formatSpecific["isZIP64"], "false")
        }
    }

    func testDescriptorCRCEqualToSignatureIsNotMistakenForSignature() throws {
        // GF(2) 上で CRC32 を逆算した 4 byte。CRC を偽装せず、実 payload でも照合する。
        let payload = Data([0xAC, 0x0A, 0x7A, 0xD5])
        XCTAssertEqual(CRC32.checksum(payload), 0x0807_4B50)
        for signed in [false, true] {
            for zip64 in [false, true] {
                let bytes = try ZipTestSupport.makeArchive(entries: [
                    RawRecordArchiveBuilder.descriptorEntry(contents: payload, signed: signed, zip64: zip64),
                    HandZipEntry(name: "next"),
                ])
                let reader = try ArchiveReader.open(data: bytes)
                let records = try checkedRecords(reader: reader, bytes: bytes)
                XCTAssertEqual(records[0].recordRange.upperBound, records[1].recordRange.lowerBound)
                XCTAssertEqual(try reader.read(reader.entries[0]), payload)
            }
        }
    }

    func testMalformedDescriptorThrowsWithoutChangingReadBehavior() throws {
        for signed in [false, true] {
            for zip64 in [false, true] {
                let input = try RawRecordArchiveBuilder.descriptorEntry(signed: signed, zip64: zip64)
                let original = try ZipTestSupport.makeArchive(entries: [input, HandZipEntry(name: "next")])
                let layout = try ZipTestSupport.layout(of: original)
                let descriptorSize = (zip64 ? 20 : 12) + (signed ? 4 : 0)
                let fieldsStart = layout.localHeaderOffsets[1] - descriptorSize + (signed ? 4 : 0)
                let mutations = zip64 ? [0, 4, 8, 12, 16] : [0, 4, 8]
                for field in mutations {
                    var bytes = original
                    bytes[fieldsStart + field] ^= 1
                    for lazy in [false, true] {
                        let reader = try ArchiveReader.open(data: bytes, options: ReaderOptions(lazyLocalHeaders: lazy))
                        XCTAssertEqual(try reader.read(reader.entries[0]), input.uncompressedData)
                        XCTAssertEqual(try reader.read(reader.entries[1]), Data())
                        // 通常の検証済みキャッシュがあっても、前の descriptor の異常を見逃さない。
                        assertMalformed { try reader.rawRecord(of: reader.entries[1]) }
                        assertMalformed { try reader.rawRecord(of: reader.entries[0]) }
                        XCTAssertEqual(try reader.read(reader.entries[0]), input.uncompressedData)
                    }
                }
            }
        }
    }

    func testTruncatedDescriptorsCannotConsumeCentralDirectoryBytes() throws {
        for signed in [false, true] {
            for zip64 in [false, true] {
                let input = try RawRecordArchiveBuilder.descriptorEntry(signed: signed, zip64: zip64)
                let original = try ZipTestSupport.makeArchive(entries: [input])
                let layout = try ZipTestSupport.layout(of: original)
                let descriptorSize = (zip64 ? 20 : 12) + (signed ? 4 : 0)
                let payloadEnd = layout.centralDirectoryOffset - descriptorSize
                for retained in 0..<descriptorSize {
                    let newCentralOffset = payloadEnd + retained
                    var bytes = Data(original.prefix(newCentralOffset)) + original[layout.centralDirectoryOffset...]
                    try ZipTestSupport.writeUInt32(UInt32(newCentralOffset), to: &bytes, at: bytes.count - 22 + 16)
                    let reader = try ArchiveReader.open(data: bytes)
                    XCTAssertEqual(try reader.read(reader.entries[0]), input.uncompressedData)
                    assertMalformed { try reader.rawRecord(of: reader.entries[0]) }
                }
            }
        }
    }

    func testDescriptorCannotOverlapAnotherEntryInEitherRequestOrder() throws {
        let input = try RawRecordArchiveBuilder.descriptorEntry(signed: true, zip64: false)
        var bytes = try ZipTestSupport.makeArchive(entries: [input, HandZipEntry(name: "next")])
        let layout = try ZipTestSupport.layout(of: bytes)
        try ZipTestSupport.writeUInt32(
            UInt32(layout.localHeaderOffsets[1] - 1), to: &bytes, at: layout.centralEntryOffsets[1] + 42
        )
        for order in [[0, 1], [1, 0]] {
            let reader = try ArchiveReader.open(data: bytes)
            XCTAssertEqual(try reader.read(reader.entries[0]), input.uncompressedData)
            for index in order { assertMalformed { try reader.rawRecord(of: reader.entries[index]) } }
        }
    }

    func testRawRangesReusePayloadMetadataAndAliasValidation() throws {
        let original = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "first", uncompressedData: Data([1])), HandZipEntry(name: "second"),
        ])
        let layout = try ZipTestSupport.layout(of: original)
        for mutation in 0..<3 {
            var bytes = original
            switch mutation {
            case 0:
                try ZipTestSupport.writeUInt32(2, to: &bytes, at: layout.centralEntryOffsets[0] + 20)
            case 1:
                try ZipTestSupport.writeUInt16(.max, to: &bytes, at: layout.localHeaderOffsets[0] + 26)
            default:
                try ZipTestSupport.writeUInt32(0, to: &bytes, at: layout.centralEntryOffsets[1] + 42)
            }
            let reader = try ArchiveReader.open(data: bytes)
            for index in [1, 0] { assertMalformed { try reader.rawRecord(of: reader.entries[index]) } }
        }
    }

    func testDescriptorFlagDisagreementOnlyRejectsRawRecord() throws {
        let input = try RawRecordArchiveBuilder.descriptorEntry(signed: true, zip64: false)
        let original = try ZipTestSupport.makeArchive(entries: [input])
        let layout = try ZipTestSupport.layout(of: original)
        for offset in [layout.localHeaderOffsets[0] + 6, layout.centralEntryOffsets[0] + 8] {
            var bytes = original
            try ZipTestSupport.writeUInt16(0x0800, to: &bytes, at: offset)
            let reader = try ArchiveReader.open(data: bytes, options: ReaderOptions(lazyLocalHeaders: false))
            XCTAssertEqual(try reader.read(reader.entries[0]), input.uncompressedData)
            assertMalformed { try reader.rawRecord(of: reader.entries[0]) }
        }
    }

    func testDittoDataDescriptorsRoundTrip() throws {
        let temporary = try ZipTestSupport.temporaryDirectory(label: "raw-ditto")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try ZipTestSupport.write(Data(String(repeating: "ditto payload\n", count: 500).utf8), relativePath: "first.txt", below: source)
        try ZipTestSupport.write(Data("second ditto entry\n".utf8), relativePath: "second.txt", below: source)
        let archive = temporary.appendingPathComponent("ditto.zip")
        try ZipTestSupport.checkedRun("/usr/bin/ditto", arguments: ["-c", "-k", "--norsrc", "--noextattr", source.path, archive.path])
        let bytes = try Data(contentsOf: archive)
        let reader = try ArchiveReader.open(url: archive)
        let records = try checkedRecords(reader: reader, bytes: bytes)
        let descriptorCount = records.filter { $0.formatSpecific["hasDataDescriptor"] == "true" }.count
        XCTAssertGreaterThanOrEqual(descriptorCount, 2)
        let rebuilt = try RawRecordArchiveBuilder.rebuildZIP(source: bytes, records: records, localOrder: reader.entries.indices.reversed())
        let destination = temporary.appendingPathComponent("rebuilt.zip")
        try rebuilt.write(to: destination)
        let reopened = try ArchiveReader.open(url: destination)
        for entry in reopened.entries {
            let old = try XCTUnwrap(reader.entries.first { $0.name == entry.name })
            XCTAssertEqual(try reopened.read(entry), try reader.read(old))
        }
        let oracle = try ZipTestSupport.checkedRun("/usr/bin/unzip", arguments: ["-t", destination.path])
        print("raw record ditto: \(descriptorCount) descriptors, unzip -t: \(oracle.terminationStatus)")
    }

    func testEncryptedZipCryptoRecordMovesWithoutRequestingPassword() throws {
        let temporary = try ZipTestSupport.temporaryDirectory(label: "raw-zipcrypto")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        let payload = Data("encrypted raw record\n".utf8)
        try ZipTestSupport.write(payload, relativePath: "encrypted.txt", below: source)
        try ZipTestSupport.write(Data([0x42]), relativePath: "first.txt", below: source)
        let archive = temporary.appendingPathComponent("encrypted.zip")
        try ZipTestSupport.makeInfoZip(sourceDirectory: source, paths: ["first.txt", "encrypted.txt"], archiveURL: archive, options: ["-0", "-P", "raw-password"])
        let bytes = try Data(contentsOf: archive)
        let reader = try ArchiveReader.open(url: archive, options: ReaderOptions(passwordProvider: RawRecordForbiddenPasswordProvider()))
        let records = try reader.entries.map { try XCTUnwrap(reader.rawRecord(of: $0)) }
        XCTAssertTrue(reader.entries.allSatisfy(\.isEncrypted))
        XCTAssertTrue(records.allSatisfy { $0.formatSpecific["encryption"] == "ZipCrypto" })
        let rebuilt = try RawRecordArchiveBuilder.rebuildZIP(source: bytes, records: records, localOrder: [1, 0])
        let destination = temporary.appendingPathComponent("relocated.zip")
        try rebuilt.write(to: destination)
        let reopened = try ArchiveReader.open(url: destination, options: ReaderOptions(password: "raw-password"))
        XCTAssertEqual(try reopened.read(reopened.entries[0]), payload)
        try ZipTestSupport.checkedRun("/usr/bin/unzip", arguments: ["-P", "raw-password", "-t", destination.path])
    }

    func testEncryptedAE2RecordPreservesEnvelopeAndZeroStoredCRC() throws {
        let password = "raw-aes-password"
        let plaintext = Data("AES raw record\n".utf8)
        let salt = Data("12345678".utf8)
        let keys = try WinZipAESDerivedKeys.derive(for: WinZipAESKeyCacheKey(password: password, salt: salt, strength: .aes128))
        var cipher = try WinZipAESCTR(encryptionKey: keys.encryptionKey)
        let ciphertext = try cipher.transform(plaintext)
        let tag = Data(HMAC<Insecure.SHA1>.authenticationCode(for: ciphertext, using: SymmetricKey(data: keys.authenticationKey)).prefix(10))
        let envelope = salt + keys.passwordVerifier + ciphertext + tag
        let aes = try ZipTestSupport.extraField(identifier: 0x9901, payload: Data([2, 0, 0x41, 0x45, 1, 0, 0]))
        let input = HandZipEntry(name: "aes.txt", uncompressedData: plaintext, compressedData: envelope, method: 99, flags: 0x0801, localExtra: aes, centralExtra: aes, centralCRC32: 0, hasDataDescriptor: true)
        var bytes = try ZipTestSupport.makeArchive(entries: [HandZipEntry(name: "first"), input])
        let layout = try ZipTestSupport.layout(of: bytes)
        try ZipTestSupport.writeUInt32(0, to: &bytes, at: layout.centralDirectoryOffset - 12)
        let reader = try ArchiveReader.open(data: bytes, options: ReaderOptions(passwordProvider: RawRecordForbiddenPasswordProvider()))
        XCTAssertNil(reader.entries[1].crc32)
        let records = try reader.entries.map { try XCTUnwrap(reader.rawRecord(of: $0)) }
        XCTAssertEqual(slice(bytes, records[1].payloadRange), envelope)
        XCTAssertEqual(records[1].formatSpecific["encryption"], "AES-128")
        XCTAssertEqual(records[1].formatSpecific["crc32"], "0x00000000")
        XCTAssertEqual(records[1].formatSpecific["method"], "0")
        XCTAssertEqual(records[1].formatSpecific["headerMethod"], "99")
        let rebuilt = try RawRecordArchiveBuilder.rebuildZIP(source: bytes, records: records, localOrder: [1, 0])
        let reopened = try ArchiveReader.open(data: rebuilt, options: ReaderOptions(password: password))
        XCTAssertEqual(try reopened.read(reopened.entries[0]), plaintext)
        bytes[layout.centralDirectoryOffset - 12] = 1
        let malformed = try ArchiveReader.open(data: bytes)
        assertMalformed { try malformed.rawRecord(of: malformed.entries[1]) }
    }

    func testIncompleteRecoveryEntryReturnsNil() throws {
        let payload = Data("incomplete payload".utf8)
        let bytes = try ZipTestSupport.makeArchive(entries: [HandZipEntry(name: "partial", uncompressedData: payload)])
        let layout = try ZipTestSupport.layout(of: bytes)
        let reader = try ArchiveReader.open(data: Data(bytes.prefix(layout.centralDirectoryOffset - 3)), options: ReaderOptions(recoverDamagedArchives: true))
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertTrue(entry.isIncomplete)
        XCTAssertNil(try reader.rawRecord(of: entry))
        XCTAssertEqual(try reader.read(entry), Data(payload.dropLast(3)))
    }

    func testSolidSevenZipEntryReturnsNil() throws {
        let reader = try ArchiveReader.open(data: RawRecordArchiveBuilder.solidSevenZip())
        XCTAssertEqual(reader.format, .sevenZip)
        XCTAssertEqual(reader.entries.map(\.solidGroup), [0, 0])
        for entry in reader.entries { XCTAssertNil(try reader.rawRecord(of: entry)) }
        XCTAssertEqual(try reader.read(reader.entries[0]), Data([0x41]))
        XCTAssertEqual(try reader.read(reader.entries[1]), Data([0x42]))
    }

    func testRAREntryReturnsNil() throws {
        let payload = Data("rar raw record is unsupported".utf8)
        let bytes = RAR5TestSupport.archive(blocks: [RAR5TestSupport.storedFile(name: "entry", contents: payload)])
        let reader = try ArchiveReader.open(data: bytes)
        XCTAssertEqual(reader.format, .rar)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertNil(try reader.rawRecord(of: entry))
        XCTAssertEqual(try reader.read(entry), payload)
    }

    func testTarLHAAndOtherUnimplementedFormatsReturnNil() throws {
        var ar = ArArchiveBuilder()
        ar.member("entry/", payload: [0x41])
        let inputs = try [
            TarTestSupport.makeTar(entries: [HandTarEntry(name: "entry", contents: Data([0x41]))]),
            LHATestSupport.makeArchive(entries: [HandLHAEntry(name: "entry", contents: Data([0x41]), headerLevel: 0)]),
            ar.data,
        ]
        for bytes in inputs {
            let reader = try ArchiveReader.open(data: bytes)
            let entry = try XCTUnwrap(reader.entries.first)
            XCTAssertNil(try reader.rawRecord(of: entry))
            XCTAssertEqual(try reader.read(entry), Data([0x41]))
        }
    }

    func testRawRecordValidatesEntryIdentity() throws {
        let reader = try ArchiveReader.open(data: ZipTestSupport.makeArchive(entries: [HandZipEntry(name: "own")]))
        let other = try ArchiveReader.open(data: ZipTestSupport.makeArchive(entries: [HandZipEntry(name: "foreign"), HandZipEntry(name: "out-of-range")]))
        for entry in other.entries {
            XCTAssertThrowsError(try reader.rawRecord(of: entry)) { error in
                guard case KaitoError.notFound = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }

    func testRawRecordSupportsShortByteSourceReads() throws {
        let bytes = try ZipTestSupport.makeArchive(entries: [RawRecordArchiveBuilder.descriptorEntry(signed: true, zip64: true)])
        let reader = try ArchiveReader.open(source: RawRecordShortByteSource(data: bytes))
        _ = try checkedRecords(reader: reader, bytes: bytes)
    }

    private func checkedRecords(reader: ArchiveReader, bytes: Data) throws -> [RawEntryRecord] {
        let layout = try ZipTestSupport.layout(of: bytes)
        var records: [RawEntryRecord] = []
        for entry in reader.entries {
            let record = try XCTUnwrap(reader.rawRecord(of: entry))
            XCTAssertEqual(record.recordRange.lowerBound, UInt64(layout.localHeaderOffsets[entry.index]))
            let next = layout.localHeaderOffsets.filter { UInt64($0) > record.recordRange.lowerBound }.min()
                ?? layout.centralDirectoryOffset
            XCTAssertEqual(record.recordRange.upperBound, UInt64(next))
            XCTAssertLessThanOrEqual(record.recordRange.upperBound, UInt64(bytes.count))
            XCTAssertEqual(slice(bytes, record.recordRange).prefix(4), Data([0x50, 0x4B, 0x03, 0x04]))
            XCTAssertGreaterThanOrEqual(record.payloadRange.lowerBound, record.recordRange.lowerBound + 30)
            XCTAssertLessThanOrEqual(record.payloadRange.upperBound, record.recordRange.upperBound)
            XCTAssertEqual(record.payloadRange.upperBound - record.payloadRange.lowerBound, entry.compressedSize)
            let expected = try reader.read(entry)
            if entry.formatSpecific["method"] == "8" {
                let decoder = try DeflateDecompressor(source: DataByteSource(bytes), offset: record.payloadRange.lowerBound, compressedSize: record.payloadRange.upperBound - record.payloadRange.lowerBound)
                let stream = try EntryStream(decompressor: decoder, length: entry.uncompressedSize, expectedCRC32: entry.crc32, entryIndex: entry.index, limits: ReadLimits())
                XCTAssertEqual(try stream.readAll(), expected)
            } else {
                XCTAssertEqual(slice(bytes, record.payloadRange), expected)
            }
            let repeated = try XCTUnwrap(reader.rawRecord(of: entry))
            XCTAssertEqual(repeated.recordRange, record.recordRange)
            records.append(record)
        }
        return records
    }

    private func slice(_ bytes: Data, _ range: Range<UInt64>) -> Data {
        Data(bytes[Int(range.lowerBound)..<Int(range.upperBound)])
    }

    private func assertMalformed<T>(_ operation: () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case KaitoError.malformed = error else {
                return XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
        }
    }
}

private struct RawRecordForbiddenPasswordProvider: PasswordProvider {
    func password(for format: ArchiveFormat) throws -> String? {
        XCTFail("rawRecord must not request a password")
        throw KaitoError.passwordRequired
    }
}

private final class RawRecordShortByteSource: ByteSource {
    let source: DataByteSource
    var length: UInt64 { source.length }

    init(data: Data) { source = DataByteSource(data) }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        try source.read(into: UnsafeMutableRawBufferPointer(rebasing: buffer.prefix(3)), at: offset)
    }
}
