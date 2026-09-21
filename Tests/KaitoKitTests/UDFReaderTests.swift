import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

/// UDF（ECMA-167 / OSTA UDF 1.02〜2.60）。fixture は macOS の hdiutil / newfs_udf が書いた 4 画像
/// （Tests/Fixtures/udf、generate.py）。内容の真値は生成時の原本と、macOS の UDF driver で mount した
/// 結果（generate.py の README 参照）。
final class UDFReaderTests: XCTestCase {
    private struct Expected {
        let kind: EntryKind
        let size: UInt64
        let sha: String?
        let link: String?
        let permissions: UInt16
    }

    private static let sha256Empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    private static let payload: [String: Expected] = [
        "readme.txt": Expected(kind: .file, size: 2_880, sha: "efe110a6cc29d1711091a93ff160466004e53f7a835209094e1131983276f25e", link: nil, permissions: 0o644),
        "forked.txt": Expected(kind: .file, size: 10, sha: "f080b24373c7b6f0bc3c0f894907f6cb643a305a7b5f8975282922d7b50b56df", link: nil, permissions: 0o644),
        "日本語 名前.txt": Expected(kind: .file, size: 8, sha: "8f25aabe30a0e7bd7cb4b72d9d0873db4d63ba0f279b6d1f4335783ee9d7b710", link: nil, permissions: 0o644),
        "link-to-readme": Expected(kind: .symlink, size: 0, sha: nil, link: "readme.txt", permissions: 0o755),
        "sub": Expected(kind: .directory, size: 0, sha: nil, link: nil, permissions: 0o755),
        "sub/small.bin": Expected(kind: .file, size: 2_304, sha: "a8b2beedb2cb53792d92eb492452bf399e8ba7fa5659c1c916b0ec7410e06cc5", link: nil, permissions: 0o755),
        "sub/link-up": Expected(kind: .symlink, size: 0, sha: nil, link: "sub/deeper/one.txt", permissions: 0o755),
        "sub/deeper": Expected(kind: .directory, size: 0, sha: nil, link: nil, permissions: 0o755),
        "sub/deeper/empty": Expected(kind: .file, size: 0, sha: sha256Empty, link: nil, permissions: 0o644),
        "sub/deeper/one.txt": Expected(kind: .file, size: 1, sha: "6b86b273ff34fce19d6b804eff5a3f5747ada4eaa22f1d49c01e52ddb7875b4b", link: nil, permissions: 0o644),
    ]
    private static let resourceFork = (size: UInt64(28), sha: "ee2effa8ee0e11ba24cdf1ddeff8c7ac514c4e917598fdcd2efb9020e488ad12")

    /// (fixture 名, 検出される形式, UDF revision, block size, resource fork stream を持つか)
    private static let fixtures: [(name: String, format: ArchiveFormat, revision: String, blockSize: Int, forks: Bool)] = [
        ("hybrid102.iso", .iso, "1.02", 2_048, false),
        ("pure150.iso", .udf, "1.50", 2_048, false),
        ("udf201-512.img", .udf, "2.01", 512, true),
        ("udf260-meta.img", .udf, "2.60", 2_048, true),
        // pure150.iso から合成した packet 書き込み媒体の構造（macOS の UDF driver で mount して原本と一致）。
        ("sparable150-relocated.iso", .udf, "1.50", 2_048, false),
        ("vat150.iso", .udf, "1.50", 2_048, false),
        ("vat2x.iso", .udf, "1.50", 2_048, false),
        // readme.txt の ICB が 2 block（DE + terminal entry、macOS も読む）と、strategy 4096 の連鎖
        // （古い DE + IE → 新しい DE + TE。macOS の driver は strategy 4096 を拒むため仕様からの実装を固定するだけ）。
        ("icb-two-entries.iso", .udf, "1.50", 2_048, false),
        ("icb-chain-4096.iso", .udf, "1.50", 2_048, false),
    ]

    private static func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/udf/\(name).gz.b64")
        let base64 = try String(contentsOf: url, encoding: .utf8)
        let gzip = try ArchiveReader.open(data: XCTUnwrap(Data(base64Encoded: base64, options: .ignoreUnknownCharacters)))
        return try gzip.read(gzip.entries[0])
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func read(_ stream: EntryStream, chunk: Int) throws -> Data {
        var output = Data(), buffer = [UInt8](repeating: 0, count: chunk)
        while stream.remaining > 0 {
            let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
            guard count > 0 else { throw KaitoError.truncated }
            output.append(contentsOf: buffer.prefix(count))
        }
        return output
    }

    /// tag の checksum と CRC を作り直す（3/7.2）。破壊テストで 1 field だけ変えるために使う。
    private static func reseal(_ image: inout Data, descriptorOffset: Int) {
        let crcLength = Int(image[descriptorOffset + 10]) | Int(image[descriptorOffset + 11]) << 8
        let body = Array(image[(descriptorOffset + 16)..<(descriptorOffset + 16 + crcLength)])
        let crc = UDFBytes.crc16(body[...])
        image[descriptorOffset + 8] = UInt8(crc & 0xFF)
        image[descriptorOffset + 9] = UInt8(crc >> 8)
        var sum: UInt8 = 0
        for index in 0..<16 where index != 4 { sum &+= image[descriptorOffset + index] }
        image[descriptorOffset + 4] = sum
    }

    // MARK: - fixtures

    func testFixturesListTheSameTreeAcrossRevisionsAndBlockSizes() throws {
        for item in Self.fixtures {
            let image = try Self.fixture(item.name)
            XCTAssertEqual(try FormatDetector.detect(data: image), item.format, item.name)
            let reader = try ArchiveReader.open(data: image)
            XCTAssertEqual(reader.format, item.format, item.name)
            XCTAssertEqual(reader.nameEncoding, .utf8, item.name)
            var names = Set(Self.payload.keys)
            if item.forks { names.insert("forked.txt/..namedfork/rsrc") }
            XCTAssertEqual(Set(reader.entries.map(\.name)), names, item.name)
            // 親 directory は子より前に並ぶ（先行順）。
            XCTAssertLessThan(try XCTUnwrap(reader.entries.firstIndex { $0.name == "sub" }),
                              try XCTUnwrap(reader.entries.firstIndex { $0.name == "sub/small.bin" }), item.name)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            for entry in reader.entries {
                let label = "\(item.name) \(entry.name)"
                XCTAssertEqual(entry.formatSpecific["fileSystem"], "udf", label)
                XCTAssertEqual(entry.formatSpecific["nameSource"], "udf", label)
                XCTAssertEqual(entry.formatSpecific["udfRevision"], item.revision, label)
                XCTAssertEqual(entry.methodDescription, "UDF (stored)", label)
                XCTAssertEqual(entry.solidGroup, -1, label)
                XCTAssertFalse(entry.isEncrypted, label)
                // 生成時刻（2026-09-21 15:06 JST）が時間帯付きで UTC に写る。
                let components = calendar.dateComponents([.year, .month, .day, .hour], from: try XCTUnwrap(entry.modificationDate, label))
                XCTAssertEqual([components.year, components.month, components.day, components.hour], [2026, 9, 21, 6], label)
                if entry.name == "forked.txt/..namedfork/rsrc" {
                    XCTAssertEqual(entry.kind, .file, label)
                    XCTAssertEqual(entry.uncompressedSize, Self.resourceFork.size, label)
                    XCTAssertEqual(entry.formatSpecific["fork"], "resource", label)
                    XCTAssertEqual(sha(try reader.read(entry)), Self.resourceFork.sha, label)
                    continue
                }
                let expected = try XCTUnwrap(Self.payload[entry.name], label)
                XCTAssertEqual(entry.kind, expected.kind, label)
                XCTAssertEqual(entry.uncompressedSize, expected.size, label)
                XCTAssertEqual(entry.compressedSize, expected.size, label)
                XCTAssertEqual(entry.posixPermissions, expected.permissions, label)
                XCTAssertEqual(entry.formatSpecific["uid"], "501", label)
                XCTAssertEqual(entry.formatSpecific["gid"], "20", label)
                XCTAssertEqual(entry.formatSpecific["linkPath"], expected.link, label)
                // hdiutil の UDF 1.02 / 1.50 は symlink 本文に生の path を書き、2.x は path component 列を書く。
                if expected.kind == .symlink {
                    XCTAssertEqual(entry.formatSpecific["linkTargetStoredAsData"], item.revision.hasPrefix("1.") ? "true" : nil, label)
                }
                if expected.kind == .file {
                    XCTAssertEqual(entry.formatSpecific["namedStreams"], item.forks && entry.name == "forked.txt" ? "1" : nil, label)
                    XCTAssertEqual(sha(try reader.read(entry)), expected.sha, label)
                    XCTAssertEqual(sha(try read(reader.stream(entry), chunk: 1)), expected.sha, "\(label) chunk 1")
                    XCTAssertEqual(sha(try read(reader.stream(entry), chunk: 700)), expected.sha, "\(label) chunk 700")
                } else {
                    XCTAssertEqual(try reader.read(entry), Data(), label)
                }
            }
            let reopened = try reader.reopen()
            XCTAssertEqual(reopened.entries, reader.entries, item.name)
            XCTAssertEqual(sha(try reopened.read(try XCTUnwrap(reopened.entries.first { $0.name == "readme.txt" }))),
                           Self.payload["readme.txt"]!.sha, item.name)
        }
    }

    func testHybridPrefersTheUDFTreeAndFallsBackToISO9660WhenItIsDamaged() throws {
        let original = try Self.fixture("hybrid102.iso")
        XCTAssertEqual(try ArchiveReader.open(data: original).entries.first?.formatSpecific["nameSource"], "udf")
        XCTAssertEqual(try FormatDetector.detect(data: original), .iso)

        // FSD の tag checksum を壊す: UDF の木は読めないので Rock Ridge / Joliet の木へ戻る。
        let volume = try UDFVolume(source: DataByteSource(original), limits: ReadLimits())
        let fsdOffset = Int(try volume.physicalSector(partition: Int(volume.fileSetLocation.partition!), block: volume.fileSetLocation.block)) * volume.blockSize
        var damaged = original
        damaged[fsdOffset + 4] ^= 0xFF
        let fallback = try ArchiveReader.open(data: damaged)
        XCTAssertEqual(fallback.format, .iso)
        XCTAssertNotEqual(fallback.entries.first?.formatSpecific["nameSource"], "udf")
        XCTAssertTrue(["rockRidge", "joliet"].contains(fallback.entries.first?.formatSpecific["nameSource"] ?? ""))
        XCTAssertEqual(sha(try fallback.read(try XCTUnwrap(fallback.entries.first { $0.name == "readme.txt" }))), Self.payload["readme.txt"]!.sha)
        // UDF 専用 image の同じ破損は malformed。
        let pure = try Self.fixture("pure150.iso")
        let pureVolume = try UDFVolume(source: DataByteSource(pure), limits: ReadLimits())
        let pureFSD = Int(try pureVolume.physicalSector(partition: 0, block: pureVolume.fileSetLocation.block)) * pureVolume.blockSize
        var pureDamaged = pure
        pureDamaged[pureFSD + 4] ^= 0xFF
        XCTAssertThrowsError(try ArchiveReader.open(data: pureDamaged)) {
            guard case .malformed(let reason) = $0 as? KaitoError, reason.contains("file set descriptor") else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
        // 上限超過は UDF 側で起きても ISO の木に戻さず、そのまま伝える。
        XCTAssertThrowsError(try ArchiveReader.open(data: original, options: ReaderOptions(limits: ReadLimits(maxEntryCount: 3)))) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func testStructuralDamageIsRejectedWithTypedErrors() throws {
        let image = try Self.fixture("pure150.iso")
        let blockSize = 2_048
        let sectors = image.count / blockSize
        // anchor 3 箇所を消すと volume が見つからない。
        var noAnchor = image
        for lba in [256, sectors - 1, sectors - 257] { noAnchor[(lba * blockSize)..<(lba * blockSize + 16)] = Data(count: 16) }
        XCTAssertThrowsError(try ArchiveReader.open(data: noAnchor)) {
            guard case .malformed(let reason) = $0 as? KaitoError, reason.contains("anchor") else { return XCTFail("Unexpected error: \($0)") }
        }
        // anchor が 1 つ残れば開ける（3/8.4.2.1 は 2 つ以上を要求するが、読み取りは残りで足りる）。
        var oneAnchor = image
        for lba in [256, sectors - 1] { oneAnchor[(lba * blockSize)..<(lba * blockSize + 16)] = Data(count: 16) }
        XCTAssertEqual(try ArchiveReader.open(data: oneAnchor).entries.count, 10)

        // LVD の logical block size を書き換えると anchor の block size と食い違う。main VDS だけ壊すと
        // reserve VDS（3/8.4.2.2）で開けるので、両方の LVD を書き換える。
        let volume = try UDFVolume(source: DataByteSource(image), limits: ReadLimits())
        let anchor = Array(image[(256 * blockSize)..<(256 * blockSize + 32)])
        var lvdOffsets: [Int] = []
        for location in [Int(UDFBytes.u32(anchor, 20)), Int(UDFBytes.u32(anchor, 28))] {
            for index in 0..<16 {
                let offset = (location + index) * blockSize
                if UDFBytes.u16(Array(image[offset..<(offset + 2)]), 0) == 6 { lvdOffsets.append(offset); break }
            }
        }
        XCTAssertEqual(lvdOffsets.count, 2)
        var mainOnly = image
        mainOnly[lvdOffsets[0] + 212] = 0; mainOnly[lvdOffsets[0] + 213] = 0x04 // 1024
        Self.reseal(&mainOnly, descriptorOffset: lvdOffsets[0])
        XCTAssertEqual(try ArchiveReader.open(data: mainOnly).entries.count, 10, "reserve VDS takes over")
        var badBlockSize = mainOnly
        badBlockSize[lvdOffsets[1] + 212] = 0; badBlockSize[lvdOffsets[1] + 213] = 0x04
        Self.reseal(&badBlockSize, descriptorOffset: lvdOffsets[1])
        XCTAssertThrowsError(try ArchiveReader.open(data: badBlockSize)) {
            guard case .malformed(let reason) = $0 as? KaitoError, reason.contains("block size") else { return XCTFail("Unexpected error: \($0)") }
        }
        // CRC だけ壊す（checksum は合わせる）。
        var badCRC = image
        for lvd in lvdOffsets {
            badCRC[lvd + 84] ^= 0x01
            var sum: UInt8 = 0
            for index in 0..<16 where index != 4 { sum &+= badCRC[lvd + index] }
            badCRC[lvd + 4] = sum
        }
        XCTAssertThrowsError(try ArchiveReader.open(data: badCRC)) {
            guard case .malformed(let reason) = $0 as? KaitoError, reason.contains("CRC") else { return XCTFail("Unexpected error: \($0)") }
        }

        // root directory の FID を壊す。
        let fsdOffset = Int(try volume.physicalSector(partition: 0, block: volume.fileSetLocation.block)) * blockSize
        let rootICB = UDFAllocation.long(Array(image[fsdOffset..<(fsdOffset + 512)]), 400)
        let rootOffset = Int(try volume.physicalSector(partition: 0, block: rootICB.block)) * blockSize
        let rootEntry = Array(image[rootOffset..<(rootOffset + blockSize)])
        let firstAD = UDFAllocation.short(rootEntry, 176 + Int(UDFBytes.u32(rootEntry, 168)))
        let directoryOffset = Int(try volume.physicalSector(partition: 0, block: firstAD.block)) * blockSize
        var badFID = image
        badFID[directoryOffset + 40 + 18] ^= 0x40 // 2 つ目の FID の characteristics: 予約 bit
        XCTAssertThrowsError(try ArchiveReader.open(data: badFID)) {
            guard case .malformed(let reason) = $0 as? KaitoError, reason.contains("file identifier") else { return XCTFail("Unexpected error: \($0)") }
        }
        // 同じ場所を存在 bit（hidden）に変えて tag を作り直すと、hidden として公開される。
        var hidden = image
        hidden[directoryOffset + 40 + 18] |= 0x01
        Self.reseal(&hidden, descriptorOffset: directoryOffset + 40)
        let hiddenReader = try ArchiveReader.open(data: hidden)
        XCTAssertEqual(hiddenReader.entries.filter { $0.formatSpecific["hidden"] == "true" }.count, 1)

        // partition の最後の block（この fixture では sub/deeper/one.txt の本文）を落とすと、open は
        // 通り（anchor 256 と全 ICB は残る）、その file の読み取りだけが truncated になる。
        let partition = volume.partitions[0]
        let cut = Data(image.prefix(Int(partition.start + partition.length - 1) * blockSize))
        let cutReader = try ArchiveReader.open(data: cut)
        XCTAssertEqual(cutReader.entries.count, 10)
        var truncated: [String] = []
        for entry in cutReader.entries where entry.kind == .file {
            do { _ = try cutReader.read(entry) } catch KaitoError.truncated { truncated.append(entry.name) }
        }
        XCTAssertEqual(truncated, ["sub/deeper/one.txt"])
    }

    func testMetadataPartitionFallsBackToTheMirrorFile() throws {
        let image = try Self.fixture("udf260-meta.img")
        let volume = try UDFVolume(source: DataByteSource(image), limits: ReadLimits())
        XCTAssertEqual(volume.partitions.count, 2)
        guard case .metadata(let runs, let mirror) = volume.partitions[1].kind else { return XCTFail("metadata partition expected") }
        XCTAssertFalse(runs.isEmpty)
        XCTAssertNotNil(mirror)
        // metadata file の FE を壊すと mirror file から同じ写像を得る。
        let anchor = Array(image[(256 * 2_048)..<(256 * 2_048 + 32)])
        let mainLocation = Int(UDFBytes.u32(anchor, 20))
        var lvdOffset = 0
        for index in 0..<16 where UDFBytes.u16(Array(image[((mainLocation + index) * 2_048)..<((mainLocation + index) * 2_048 + 2)]), 0) == 6 {
            lvdOffset = (mainLocation + index) * 2_048
        }
        let lvd = Array(image[lvdOffset..<(lvdOffset + 2_048)])
        var mapOffset = 440
        if lvd[mapOffset] == 1 { mapOffset += 6 }
        XCTAssertEqual(lvd[mapOffset], 2)
        let metadataFileBlock = UDFBytes.u32(lvd, mapOffset + 40)
        let mirrorBlock = UDFBytes.u32(lvd, mapOffset + 44)
        var damaged = image
        damaged[Int(volume.partitions[0].start + metadataFileBlock) * 2_048 + 4] ^= 0xFF
        let reader = try ArchiveReader.open(data: damaged)
        XCTAssertEqual(reader.entries.count, 11)
        XCTAssertEqual(sha(try reader.read(try XCTUnwrap(reader.entries.first { $0.name == "readme.txt" }))), Self.payload["readme.txt"]!.sha)
        // 両方壊れると開けない。
        damaged[Int(volume.partitions[0].start + mirrorBlock) * 2_048 + 4] ^= 0xFF
        XCTAssertThrowsError(try ArchiveReader.open(data: damaged)) {
            guard case .malformed = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func testSparableAndVirtualPartitionsRequireTheirTables() throws {
        // sparing table の tag を壊すと開けない（再配置された packet は表なしでは読めない）。
        let sparable = try Self.fixture("sparable150-relocated.iso")
        let volume = try UDFVolume(source: DataByteSource(sparable), limits: ReadLimits())
        guard case .sparable(let packetLength, let table) = volume.partitions[0].kind else { return XCTFail("sparable partition expected") }
        XCTAssertEqual(packetLength, 32)
        XCTAssertEqual(table.map(\.original), [0])
        XCTAssertEqual(try volume.physicalSector(partition: 0, block: 5), UInt64(table[0].mapped) + 5)
        // partition は 28 block で packet 0（32 block）に収まるので全 block が再配置先に写る。
        XCTAssertEqual(try volume.physicalSector(partition: 0, block: 27), UInt64(table[0].mapped) + 27)
        var noTable = sparable
        noTable[310 * 2_048 + 4] ^= 0xFF
        XCTAssertThrowsError(try ArchiveReader.open(data: noTable)) {
            guard case .malformed(let reason) = $0 as? KaitoError, reason.contains("sparing table") else { return XCTFail("Unexpected error: \($0)") }
        }

        for name in ["vat150.iso", "vat2x.iso"] {
            let image = try Self.fixture(name)
            let vatVolume = try UDFVolume(source: DataByteSource(image), limits: ReadLimits())
            XCTAssertEqual(vatVolume.partitions.count, 2, name)
            guard case .virtual(let entries, let physical) = vatVolume.partitions[1].kind else { return XCTFail("virtual partition expected") }
            XCTAssertEqual(physical, 0, name)
            XCTAssertEqual(entries.count, 28, name)
            XCTAssertEqual(entries[1], 2, name)
            // VAT ICB（最終 sector）を消すと virtual partition を解決できない。
            var noVAT = image
            let last = (noVAT.count / 2_048 - 1) * 2_048
            noVAT[last..<(last + 16)] = Data(count: 16)
            XCTAssertThrowsError(try ArchiveReader.open(data: noVAT), name) {
                guard case .malformed(let reason) = $0 as? KaitoError, reason.contains("VAT") else { return XCTFail("Unexpected error: \($0)") }
            }
            // root directory の本文が指す virtual block 3 を未使用にすると malformed。
            var unused = image
            let entryOffset = last + 176 + (name == "vat2x.iso" ? 152 : 0) + 3 * 4
            unused[entryOffset..<(entryOffset + 4)] = Data([0xFF, 0xFF, 0xFF, 0xFF])
            Self.reseal(&unused, descriptorOffset: last)
            XCTAssertThrowsError(try ArchiveReader.open(data: unused), name) {
                guard case .malformed(let reason) = $0 as? KaitoError, reason.contains("unused") else { return XCTFail("Unexpected error: \($0)") }
            }
        }
    }

    func testLimitsApply() throws {
        let image = try Self.fixture("udf201-512.img")
        XCTAssertThrowsError(try ArchiveReader.open(data: image, options: ReaderOptions(limits: ReadLimits(maxEntrySize: 2_000)))) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertThrowsError(try ArchiveReader.open(data: image, options: ReaderOptions(limits: ReadLimits(maxEntryCount: 5)))) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertThrowsError(try ArchiveReader.open(data: image, options: ReaderOptions(limits: ReadLimits(maxPathComponentCount: 2)))) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertThrowsError(try ArchiveReader.open(data: image, options: ReaderOptions(limits: ReadLimits(maxTotalMetadataSize: 4_096)))) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertEqual(try ArchiveReader.open(data: image, options: ReaderOptions(limits: ReadLimits(maxPathComponentCount: 4))).entries.count, 11)
    }

    // MARK: - structures

    func testBasicTypes() {
        // 3/7.2.6 の例: 70 6A 77 → 3299。
        XCTAssertEqual(UDFBytes.crc16([0x70, 0x6A, 0x77][...]), 0x3299)
        XCTAssertEqual(UDFBytes.compressedUnicode([8, 0x61, 0xE9][...]), "aé")
        XCTAssertEqual(UDFBytes.compressedUnicode([16, 0x65, 0xE5, 0x30, 0x42][...]), "日あ")
        XCTAssertEqual(UDFBytes.compressedUnicode([254, 0x61][...]), "")
        XCTAssertNil(UDFBytes.compressedUnicode([9, 0x61][...]))
        XCTAssertNil(UDFBytes.compressedUnicode([16, 0x61][...]))
        var dstring = [UInt8](repeating: 0, count: 32)
        dstring[0] = 8; dstring[1] = 0x41; dstring[2] = 0x42; dstring[31] = 3
        XCTAssertEqual(UDFBytes.dstring(dstring, 0, length: 32), "AB")
        XCTAssertEqual(UDFBytes.dstring([UInt8](repeating: 0, count: 32), 0, length: 32), "")
        dstring[31] = 32
        XCTAssertNil(UDFBytes.dstring(dstring, 0, length: 32))

        // 1/7.3 timestamp: 2026-09-21 15:06:37 JST（type 1、+540 分）→ 06:06:37 UTC。
        var stamp = [UInt8](repeating: 0, count: 12)
        let zone: UInt16 = 0x1000 | 540
        stamp[0] = UInt8(zone & 0xFF); stamp[1] = UInt8(zone >> 8)
        stamp[2] = UInt8(2026 & 0xFF); stamp[3] = UInt8(2026 >> 8)
        stamp[4] = 9; stamp[5] = 21; stamp[6] = 15; stamp[7] = 6; stamp[8] = 37; stamp[9] = 50
        XCTAssertEqual(UDFBytes.timestamp(stamp, 0)?.timeIntervalSince1970, 1_789_970_797.5)
        // -2047 は時間帯不明: UTC 扱い。
        let unknown: UInt16 = 0x1000 | (UInt16(bitPattern: -2047) & 0x0FFF)
        stamp[0] = UInt8(unknown & 0xFF); stamp[1] = UInt8(unknown >> 8); stamp[9] = 0
        XCTAssertEqual(UDFBytes.timestamp(stamp, 0)?.timeIntervalSince1970, 1_789_970_797.5 + 540 * 60 - 0.5)
        stamp[4] = 13
        XCTAssertNil(UDFBytes.timestamp(stamp, 0))
        XCTAssertNil(UDFBytes.timestamp([UInt8](repeating: 0, count: 12), 0))
    }

    func testExtentDecompressorReturnsRecordedZeroAndInlineRunsInOrder() throws {
        let backing = DataByteSource(Data([UInt8](0..<64)))
        let extents: [UDFDataExtent] = [
            .recorded(ISOSection(offset: 10, length: 5)),
            .zero(3),
            .inline([0xAA, 0xBB]),
            .zero(0),
            .recorded(ISOSection(offset: 0, length: 2)),
        ]
        let expected = Data([10, 11, 12, 13, 14, 0, 0, 0, 0xAA, 0xBB, 0, 1])
        for chunk in [1, 2, 7, 64] {
            let stream = try EntryStream(decompressor: UDFExtentDecompressor(source: backing, extents: extents),
                                         length: 12, expectedCRC32: nil, entryIndex: 0, limits: ReadLimits())
            XCTAssertEqual(try read(stream, chunk: chunk), expected, "chunk \(chunk)")
        }
    }

    // MARK: - runtime oracle

    /// hdiutil makehybrid で大きめの木（複数 block にまたがる directory、1 block を超える file 群）を作り、
    /// UDF 専用 image と ISO 9660 / Joliet との hybrid が同じ名前と内容を返すことを確認する。
    func testMakehybridTreesMatchTheSourceFiles() throws {
        let hdiutil = "/usr/bin/hdiutil"
        try ZipTestSupport.requireExecutable(hdiutil, reason: "hdiutil is unavailable; UDF runtime image skipped")
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("deep/er/still"), withIntermediateDirectories: true)
        var seed: UInt64 = 0x0D15_EA5E
        var digests: [String: String] = [:]
        func random(_ count: Int) -> Data {
            var bytes = [UInt8](repeating: 0, count: count)
            for index in bytes.indices {
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                bytes[index] = UInt8(truncatingIfNeeded: seed >> 24)
            }
            return Data(bytes)
        }
        func write(_ name: String, _ data: Data) throws {
            try data.write(to: source.appendingPathComponent(name))
            digests[name] = sha(data)
        }
        try write("large.bin", random(3_000_000))
        try write("deep/er/still/tail.txt", Data("tail\n".utf8))
        for index in 0..<220 { try write("many-\(String(format: "%03d", index)).txt", Data("entry \(index)\n".utf8)) }
        try ZipTestSupport.checkedRun(hdiutil, arguments: ["makehybrid", "-quiet", "-udf", "-udf-version", "1.02", "-o", "pure.iso", "src"],
                                      currentDirectory: temporary)
        try ZipTestSupport.checkedRun(hdiutil, arguments: ["makehybrid", "-quiet", "-iso", "-joliet", "-udf", "-udf-version", "1.50", "-o", "hybrid.iso", "src"],
                                      currentDirectory: temporary)
        for (name, format) in [("pure.iso", ArchiveFormat.udf), ("hybrid.iso", .iso)] {
            let url = temporary.appendingPathComponent(name)
            XCTAssertEqual(try FormatDetector.detect(url: url), format, name)
            let reader = try ArchiveReader.open(url: url)
            let files = reader.entries.filter { $0.kind == .file }
            XCTAssertEqual(files.count, digests.count, name)
            XCTAssertEqual(reader.entries.filter { $0.kind == .directory }.map(\.name).sorted(), ["deep", "deep/er", "deep/er/still"], name)
            for entry in files {
                XCTAssertEqual(entry.formatSpecific["nameSource"], "udf", "\(name) \(entry.name)")
                XCTAssertEqual(sha(try reader.read(entry)), digests[entry.name], "\(name) \(entry.name)")
            }
            let large = try XCTUnwrap(files.first { $0.name == "large.bin" })
            XCTAssertEqual(sha(try read(reader.stream(large), chunk: 65_537)), digests["large.bin"], name)
        }
    }
}
