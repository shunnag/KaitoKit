import Foundation
import KaitoKit
import XCTest

/// Tests/Fixtures/zip-golden の入力一覧・読み込みと、公開値を比べる読み方。
enum ZipGoldenCorpus {
    struct Generator: Codable {
        enum Kind: String, Codable {
            case largeStored = "large-stored-v1", smallUT = "small-ut-v1", smallDD = "small-dd-v1"
        }
        let kind: Kind
        let seed: UInt8
    }
    struct File: Codable {
        let path: String
        let sha256: String
        let generator: Generator?
        init(path: String, sha256: String, generator: Generator? = nil) {
            self.path = path; self.sha256 = sha256; self.generator = generator
        }
    }
    struct Input: Codable { let id: String; let origin: String; let files: [File]; let open: String }
    struct Mode { let name: String; let options: ReaderOptions }
    static var root: URL { ZipTestSupport.repositoryRoot.appendingPathComponent("Tests/Fixtures/zip-golden") }
    static var modes: [Mode] {
        [Mode(name: "expose-lazy", options: ReaderOptions(scanForSFXInData: true, appleDoublePolicy: .expose)),
         Mode(name: "expose-eager", options: ReaderOptions(lazyLocalHeaders: false, scanForSFXInData: true, appleDoublePolicy: .expose)),
         Mode(name: "merge-lazy", options: ReaderOptions(scanForSFXInData: true, appleDoublePolicy: .merge)),
         Mode(name: "merge-eager", options: ReaderOptions(lazyLocalHeaders: false, scanForSFXInData: true, appleDoublePolicy: .merge)),
         Mode(name: "hide-lazy", options: ReaderOptions(scanForSFXInData: true, appleDoublePolicy: .hide)),
         Mode(name: "expose-recovery", options: ReaderOptions(scanForSFXInData: true, recoverDamagedArchives: true, appleDoublePolicy: .expose))]
    }
    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        return String(decoding: bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, as: UTF8.self)
    }
    static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted, .fragmentsAllowed]) + Data([10])
    }
    static func publicValues() throws -> Data {
        let encoded = try Data(contentsOf: root.appendingPathComponent("public-values.json.lzfse"))
        let bytes = try (encoded as NSData).decompressed(using: .lzfse) as Data
        let expectedHash = try String(contentsOf: root.appendingPathComponent("public-values.json.sha256"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(bytes.sha256Hex, expectedHash, "decompressed public golden SHA-256")
        return bytes
    }
    static func decoded(_ file: File) throws -> Data {
        let bytes: Data
        if let generator = file.generator {
            bytes = try generated(generator)
        } else {
            let encoded = try String(contentsOf: root.appendingPathComponent(file.path), encoding: .utf8)
            bytes = try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
        }
        XCTAssertEqual(bytes.sha256Hex, file.sha256, file.path)
        return bytes
    }
    static func generated(_ generator: Generator) throws -> Data {
        switch generator.kind {
        case .largeStored:
            return try ZipTestSupport.makeArchive(entries: (0..<2).map {
                HandZipEntry(name: "large\($0)", uncompressedData: Data(repeating: generator.seed &+ UInt8($0), count: 1024 * 1024))
            })
        case .smallUT:
            let ut = try ZipTestSupport.extraField(identifier: 0x5455, payload: Data([3])
                + RawRecordArchiveBuilder.little(UInt32(1790000000)) + RawRecordArchiveBuilder.little(UInt32(1790000000)))
            return try ZipTestSupport.makeArchive(entries: (0..<2000).map {
                HandZipEntry(name: "d/f\($0)", uncompressedData: Data([generator.seed]), localExtra: ut, centralExtra: ut)
            })
        case .smallDD:
            return try ZipTestSupport.makeArchive(entries: (0..<2000).map { index in
                var entry = HandZipEntry(name: "d/f\(index)", uncompressedData: Data([generator.seed]), hasDataDescriptor: true)
                entry.dataDescriptorHasSignature = index % 2 == 0
                return entry
            })
        }
    }
    static func inputs() throws -> [Input] {
        let inputs = try JSONDecoder().decode([Input].self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        for input in inputs { for file in input.files { _ = try decoded(file) } }
        return inputs
    }
    static func withReader<T>(_ input: Input, options: ReaderOptions, body: (ArchiveReader) throws -> T) throws -> T {
        if input.files.count == 1 {
            return try body(ArchiveReader.open(data: decoded(input.files[0]), options: options))
        }
        let directory = try ZipTestSupport.temporaryDirectory(label: "zip-golden")
        defer { try? FileManager.default.removeItem(at: directory) }
        for file in input.files {
            try decoded(file).write(to: directory.appendingPathComponent(URL(fileURLWithPath: file.path).lastPathComponent.replacingOccurrences(of: ".b64", with: "")))
        }
        return try body(ArchiveReader.open(url: directory.appendingPathComponent(input.open), options: options))
    }
    static func raw(_ reader: ArchiveReader, _ entry: ArchiveEntry) -> [String: Any] {
        do {
            guard let raw = try reader.rawRecord(of: entry) else { return ["nil": true] }
            return ["recordRange": [raw.recordRange.lowerBound, raw.recordRange.upperBound],
                    "payloadRange": [raw.payloadRange.lowerBound, raw.payloadRange.upperBound],
                    "formatSpecific": raw.formatSpecific]
        } catch { return ["error": String(describing: error)] }
    }
    static func publicRows(_ input: Input, options: ReaderOptions) throws -> [[String: Any]] {
        do {
            let ascending = try withReader(input, options: options) { reader -> [[String: Any]] in
                var result: [[String: Any]] = [["open": "success", "format": String(describing: reader.format),
                    "nameEncoding": reader.nameEncoding.map { $0.rawValue as Any } ?? NSNull(), "count": reader.entries.count]]
                result += reader.entries.map { entry in
                    ["index": entry.index, "kind": String(describing: entry.kind),
                     "name": entry.name, "nameUTF8": hex(entry.name.utf8), "rawName": hex(entry.rawName.bytes),
                     "declaredEncoding": entry.rawName.declaredEncoding.map { $0.rawValue as Any } ?? NSNull(),
                     "isDirectoryHint": entry.rawName.isDirectoryHint,
                     "pathComponents": entry.pathComponents.map { hex($0.utf8) },
                     "compressedSize": entry.compressedSize.map { $0 as Any } ?? NSNull(),
                     "uncompressedSize": entry.uncompressedSize.map { $0 as Any } ?? NSNull(),
                     "crc32": entry.crc32.map { $0 as Any } ?? NSNull(),
                     "isEncrypted": entry.isEncrypted, "isIncomplete": entry.isIncomplete,
                     "posixPermissions": entry.posixPermissions.map { $0 as Any } ?? NSNull(),
                     "solidGroup": entry.solidGroup, "methodDescription": entry.methodDescription,
                     "formatSpecific": entry.formatSpecific,
                     "modificationDate": entry.modificationDate.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
                     "rawAscending": raw(reader, entry)]
                }
                return result
            }
            let descending = try withReader(input, options: options) { reader in
                reader.entries.reversed().map { ($0.index, raw(reader, $0)) }
            }
            var result = ascending
            for (index, raw) in descending { result[index + 1]["rawDescending"] = raw }
            return result
        } catch { return [["open": "failure", "error": String(describing: error)]] }
    }
    static func summary(_ rows: [[String: Any]]) throws -> [String: Any] {
        if rows.count <= 65 { return ["rows": rows] }
        return ["rowCount": rows.count, "sha256": try json(rows).sha256Hex,
                "first": Array(rows.prefix(17)), "last": Array(rows.suffix(16))]
    }

    static func generateInputs() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("inputs"), withIntermediateDirectories: true)
        var manifest: [Input] = []
        func save(_ id: String, _ bytes: Data, origin: String = "synthetic", generator: Generator? = nil) throws {
            let path = generator == nil ? "inputs/\(id).zip.b64" : "generated/\(id).zip"
            if generator == nil {
                try bytes.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed]).write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
            }
            manifest.append(Input(id: id, origin: origin, files: [File(path: path, sha256: bytes.sha256Hex, generator: generator)], open: "\(id).zip"))
        }
        let fixtures = ZipTestSupport.repositoryRoot.appendingPathComponent("Tests/Fixtures")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: fixtures, includingPropertiesForKeys: nil))
        let existing = enumerator.compactMap { $0 as? URL }.filter {
            $0.pathExtension == "b64" && !$0.path.contains("/zip-golden/")
        }.sorted { $0.path < $1.path }
        for url in existing {
            let encoded = try String(contentsOf: url, encoding: .utf8)
            guard let bytes = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
                  (try? FormatDetector.detect(data: bytes)) == .zip else { continue }
            let relative = String(url.path.dropFirst(fixtures.path.count + 1)).replacingOccurrences(of: ".b64", with: "")
            try save("existing-" + relative.replacingOccurrences(of: "/", with: "-"), bytes, origin: "existing")
        }
        guard manifest.count == 30 else { throw ZipTestSupportError.fixture("expected 30 baseline ZIP fixtures, got \(manifest.count)") }
        for signed in [false, true] {
            for shape in 0..<4 {
                let input = try RawRecordArchiveBuilder.descriptorEntry(signed: signed, zip64: shape > 0, localZIP64: shape != 2, centralZIP64: shape != 1)
                let original = try ZipTestSupport.makeArchive(entries: [input, HandZipEntry(name: "next")])
                let key = "descriptor-\(signed)-\(shape)"
                try save(key, original)
                let layout = try ZipTestSupport.layout(of: original)
                let size = (shape > 0 ? 20 : 12) + (signed ? 4 : 0)
                for field in stride(from: 0, to: shape > 0 ? 20 : 12, by: 4) {
                    var broken = original
                    broken[layout.localHeaderOffsets[1] - size + (signed ? 4 : 0) + field] ^= 1
                    try save("bad-\(key)-field-\(field)", broken)
                }
                let single = try ZipTestSupport.makeArchive(entries: [input])
                let singleLayout = try ZipTestSupport.layout(of: single)
                for retained in 0..<size {
                    let cd = singleLayout.centralDirectoryOffset - size + retained
                    var broken = Data(single.prefix(cd)) + single[singleLayout.centralDirectoryOffset...]
                    try ZipTestSupport.writeUInt32(UInt32(cd), to: &broken, at: broken.count - 6)
                    try save("short-\(key)-\(retained)", broken)
                }
            }
            for zip64 in [false, true] {
                try save("signature-crc-\(signed)-\(zip64)", ZipTestSupport.makeArchive(entries: [
                    RawRecordArchiveBuilder.descriptorEntry(contents: Data([0xAC, 0x0A, 0x7A, 0xD5]), signed: signed, zip64: zip64), HandZipEntry(name: "next")]))
            }
        }
        for wide in [false, true] {
            try save("sfx-\(wide)", ZipTestSupport.makeArchive(entries: [RawRecordArchiveBuilder.descriptorEntry(signed: true, zip64: false)], prefix: ZipTestSupport.makePEPrefix(count: 1024), forceZIP64End: wide))
        }
        let normal = try ZipTestSupport.makeArchive(entries: (0..<24).map { HandZipEntry(name: "d/f\($0)", uncompressedData: Data([UInt8($0)])) })
        let reader = try ArchiveReader.open(data: normal)
        let records = try reader.entries.map { try XCTUnwrap(reader.rawRecord(of: $0)) }
        try save("reverse", RawRecordArchiveBuilder.rebuildZIP(source: normal, records: records, localOrder: Array(records.indices.reversed()), centralOrder: Array(records.indices)))
        var shuffled = Array(records.indices)
        var state: UInt64 = 0x50314b
        for index in shuffled.indices.reversed() {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            shuffled.swapAt(index, Int(state % UInt64(index + 1)))
        }
        try save("shuffled", RawRecordArchiveBuilder.rebuildZIP(source: normal, records: records, localOrder: shuffled, centralOrder: Array(records.indices)))
        let names = ["a", "a/", "/a", "a//b", "/", "//", "a/b/c.txt", "café/one", "cafe\u{301}/two", "日本語/葉", String(repeating: "d/", count: 63) + "f", "abcdefghijklmnopq/leaf"]
        var entries = names.map { HandZipEntry(name: $0) }
        entries += [HandZipEntry(rawName: [0x93, 0xfa, 0x96, 0x7b, 0x8c, 0xea], flags: 0),
                    HandZipEntry(rawName: [0xEF, 0xBB, 0xBF, 0x61], flags: 0x0800),
                    HandZipEntry(rawName: [0xC0, 0xAF, 0xFF], flags: 0x0800),
                    HandZipEntry(rawName: Array(1...127), flags: 0x0800),
                    HandZipEntry(name: "link", uncompressedData: Data("a".utf8), externalAttributes: UInt32(0o120777) << 16), HandZipEntry(name: "empty/")]
        try save("names-kinds", ZipTestSupport.makeArchive(entries: entries))
        for (id, generator) in [
            ("small-ut", Generator(kind: .smallUT, seed: 0x78)),
            ("small-dd", Generator(kind: .smallDD, seed: 0x78)),
            ("large-stored", Generator(kind: .largeStored, seed: 0))
        ] {
            try save(id, generated(generator), generator: generator)
        }
        for gap in [100, 8192] {
            var bytes = normal
            let layout = try ZipTestSupport.layout(of: bytes)
            let insertion = layout.localHeaderOffsets[1]
            bytes.insert(contentsOf: repeatElement(UInt8(0), count: gap), at: insertion)
            for (index, cd) in layout.centralEntryOffsets.enumerated() where index > 0 {
                try ZipTestSupport.writeUInt32(UInt32(layout.localHeaderOffsets[index] + gap), to: &bytes, at: cd + gap + 42)
            }
            try ZipTestSupport.writeUInt32(UInt32(layout.centralDirectoryOffset + gap), to: &bytes, at: layout.endRecordOffset + gap + 16)
            try save("gap-\(gap)", bytes)
        }
        let pair = try ZipTestSupport.makeArchive(entries: [HandZipEntry(name: "first", uncompressedData: Data([1])), HandZipEntry(name: "second")])
        let pairLayout = try ZipTestSupport.layout(of: pair)
        for mutation in 0..<5 {
            var bytes = pair
            switch mutation {
            case 0: try ZipTestSupport.writeUInt32(2, to: &bytes, at: pairLayout.centralEntryOffsets[0] + 20)
            case 1: try ZipTestSupport.writeUInt16(.max, to: &bytes, at: pairLayout.localHeaderOffsets[0] + 26)
            case 2: try ZipTestSupport.writeUInt32(0, to: &bytes, at: pairLayout.centralEntryOffsets[1] + 42)
            case 3: bytes[pairLayout.localHeaderOffsets[1]] ^= 1
            default: try ZipTestSupport.writeUInt16(0x0840, to: &bytes, at: 6)
            }
            try save("bad-header-\(mutation)", bytes)
        }
        let descriptorPair = try ZipTestSupport.makeArchive(entries: [RawRecordArchiveBuilder.descriptorEntry(signed: true, zip64: false), HandZipEntry(name: "next")])
        let ddLayout = try ZipTestSupport.layout(of: descriptorPair)
        for offset in [6, ddLayout.centralEntryOffsets[0] + 8] {
            var bytes = descriptorPair
            try ZipTestSupport.writeUInt16(0x0800, to: &bytes, at: offset)
            try save("bad-dd-flag-\(offset)", bytes)
        }
        var overlap = descriptorPair
        try ZipTestSupport.writeUInt32(UInt32(ddLayout.localHeaderOffsets[1] - 1), to: &overlap, at: ddLayout.centralEntryOffsets[1] + 42)
        try save("bad-dd-overlap", overlap)
        try save("truncated-end", Data(normal.dropLast(8)))
        try save("incomplete", Data(pair.prefix(pairLayout.localHeaderOffsets[1] - 1)))

        let temporary = try ZipTestSupport.temporaryDirectory(label: "golden-generation")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source")
        let payload = Data("frozen encrypted raw record\n".utf8)
        try ZipTestSupport.write(payload, relativePath: "entry.txt", below: source)
        try ZipTestSupport.write(Data([0x42]), relativePath: "second.txt", below: source)
        let ditto = temporary.appendingPathComponent("ditto.zip")
        try ZipTestSupport.checkedRun("/usr/bin/ditto", arguments: ["-c", "-k", "--norsrc", "--noextattr", source.path, ditto.path])
        try save("ditto", Data(contentsOf: ditto))
        let crypto = temporary.appendingPathComponent("crypto.zip")
        guard FileManager.default.isExecutableFile(atPath: ZipTestSupport.infoZipPath) else { throw ZipTestSupportError.fixture("Info-ZIP required for golden generation") }
        try ZipTestSupport.makeInfoZip(sourceDirectory: source, paths: ["entry.txt"], archiveURL: crypto, options: ["-0", "-P", "raw-password"])
        try save("zipcrypto", Data(contentsOf: crypto))
        for strength in [128, 256] {
            let destination = temporary.appendingPathComponent("aes\(strength).zip")
            try ZipTestSupport.checkedRun(ZipTestSupport.sevenZipPath, arguments: ["a", "-tzip", "-mx=0", "-mem=AES\(strength)", "-praw-password", destination.path, "entry.txt"], currentDirectory: source)
            let original = try Data(contentsOf: destination)
            let layout = try ZipTestSupport.layout(of: original)
            for version in [1, 2] {
                var bytes = original
                let local = layout.localHeaderOffsets[0]
                let central = layout.centralEntryOffsets[0]
                let localExtra = local + 30 + Int(try ZipTestSupport.readUInt16(bytes, at: local + 26))
                let centralExtra = central + 46 + Int(try ZipTestSupport.readUInt16(bytes, at: central + 28))
                for (start, length) in [(localExtra, Int(try ZipTestSupport.readUInt16(bytes, at: local + 28))), (centralExtra, Int(try ZipTestSupport.readUInt16(bytes, at: central + 30)))] {
                    var cursor = start
                    while cursor + 4 <= start + length {
                        if try ZipTestSupport.readUInt16(bytes, at: cursor) == 0x9901 { try ZipTestSupport.writeUInt16(UInt16(version), to: &bytes, at: cursor + 4) }
                        cursor += 4 + Int(try ZipTestSupport.readUInt16(bytes, at: cursor + 2))
                    }
                }
                try ZipTestSupport.writeUInt32(version == 1 ? CRC32.checksum(payload) : 0, to: &bytes, at: local + 14)
                try ZipTestSupport.writeUInt32(version == 1 ? CRC32.checksum(payload) : 0, to: &bytes, at: central + 16)
                try save("aes\(strength)-ae\(version)", bytes)
            }
        }
        let split = try ZipSplitFixture(normal, below: temporary) { [$0.localHeaderOffsets[1] + 12, $0.centralDirectoryOffset + 7] }
        for (id, urls, open) in [("split-native", split.urls, "split.zip"), ("split-numbered", [temporary.appendingPathComponent("numbered.zip.001"), temporary.appendingPathComponent("numbered.zip.002")], "numbered.zip.001")] {
            if id == "split-numbered" {
                try Data(normal.prefix(normal.count / 2)).write(to: urls[0])
                try Data(normal.suffix(normal.count - normal.count / 2)).write(to: urls[1])
            }
            try FileManager.default.createDirectory(at: root.appendingPathComponent("inputs/\(id)"), withIntermediateDirectories: true)
            let files = try urls.map { url -> File in
                let data = try Data(contentsOf: url)
                let path = "inputs/\(id)/\(url.lastPathComponent).b64"
                try data.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed]).write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
                return File(path: path, sha256: data.sha256Hex)
            }
            manifest.append(Input(id: id, origin: "synthetic", files: files, open: open))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try (encoder.encode(manifest.sorted { $0.id < $1.id }) + Data([10])).write(to: root.appendingPathComponent("manifest.json"))
    }
}
