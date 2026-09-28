import CryptoKit
import Foundation
import KaitoKit
import XCTest

final class TarPublicValueGoldenTests: XCTestCase {
    func testFrozenPublicValues() throws {
        let env = ProcessInfo.processInfo.environment
        if env["KAITOKIT_WRITE_TAR_GOLDEN_INPUTS"] == "1" { try TarGoldenCorpus.generateInputs() }
        let inputs = try TarGoldenCorpus.inputs()
        let destination = TarGoldenCorpus.root.appendingPathComponent("public-values.json.lzfse")
        if env["KAITOKIT_WRITE_TAR_GOLDEN_INPUTS"] == "1", !FileManager.default.fileExists(atPath: destination.path) { return }
        let utc = TimeZone.current.secondsFromGMT() == 0
        var values: [String: Any] = [:], dated: [String: Any] = [:], full: [String: Any] = [:]
        for recording in [false, true] {
            for input in inputs {
                let data = try TarGoldenCorpus.decoded(input)
                for (mode, initial) in TarGoldenCorpus.modes {
                    let options = tarGoldenOptions(initial, recording: recording)
                    for method in TarGoldenCorpus.methods(input) {
                        let key = input.id + "/" + mode + "/" + method
                        let rows = try TarGoldenCorpus.publicRows(input, data: data, method: method, options: options)
                        let plain = try TarGoldenCorpus.summary(rows.map { $0.filter { $0.key != "modificationDate" } })
                        let all = try TarGoldenCorpus.summary(rows)
                        if !recording { values[key] = plain; if utc { dated[key] = all }; full[key] = rows }
                        else if try TarGoldenCorpus.json(plain) != TarGoldenCorpus.json(XCTUnwrap(values[key]))
                            || (utc && TarGoldenCorpus.json(all) != TarGoldenCorpus.json(XCTUnwrap(dated[key]))) {
                            try TarGoldenCorpus.dump([key + "/off": full[key]!, key + "/on": rows])
                            XCTFail("tar golden option on/off differ: \(key)")
                        }
                    }
                }
            }
        }
        if env["KAITOKIT_WRITE_TAR_GOLDEN"] == "1" {
            guard utc else { throw TarTestSupportError.commandFailed("write tar golden with TZ=UTC") }
            let bytes = try TarGoldenCorpus.json(["values": values, "utcValues": dated])
            try ((bytes as NSData).compressed(using: .lzfse) as Data).write(to: destination)
            try (bytes.sha256Hex + "\n").write(
                to: TarGoldenCorpus.root.appendingPathComponent("public-values.json.sha256"),
                atomically: true, encoding: .utf8)
        }
        let expectedBytes = try TarGoldenCorpus.publicValues()
        if let path = env["KAITOKIT_DUMP_TAR_GOLDEN"] {
            try expectedBytes.write(to: URL(fileURLWithPath: path))
        }
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: expectedBytes) as? [String: Any])
        if try TarGoldenCorpus.json(values) != TarGoldenCorpus.json(XCTUnwrap(expected["values"]))
            || (utc && TarGoldenCorpus.json(dated) != TarGoldenCorpus.json(XCTUnwrap(expected["utcValues"]))) {
            try TarGoldenCorpus.dump(["full": full, "actual": values, "utcActual": dated, "expected": expected])
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kaitokit-tar-golden-actual")
            try expectedBytes.write(to: directory.appendingPathComponent("expected.json"))
            var actual = expected
            actual["values"] = values
            if utc { actual["utcValues"] = dated }
            try TarGoldenCorpus.json(actual).write(to: directory.appendingPathComponent("actual.json"))
            XCTFail("tar public values differ; see $TMPDIR/kaitokit-tar-golden-actual/{expected,actual,all-rows}.json")
        }
        print("TAR-GOLDEN inputs=\(inputs.count) existing=\(inputs.filter { $0.origin == "existing" }.count) supplied=\(inputs.filter { $0.origin == "supplied" }.count) combinations=\(values.count) option=off,on UTC=\(utc)")
    }
}

enum TarGoldenCorpus {
    struct Generator: Codable {
        enum Kind: String, Codable {
            case manyEntries = "many-entries-v1", gzipRichHeader = "gzip-rich-header-v1"
        }
        let kind: Kind
        let seed: UInt8
        let deflateAndTrailer: Data?
        init(kind: Kind, seed: UInt8, deflateAndTrailer: Data? = nil) {
            self.kind = kind; self.seed = seed; self.deflateAndTrailer = deflateAndTrailer
        }
    }
    struct Input: Codable {
        let id: String; let origin: String; let path: String; let suffix: String; let sha256: String
        let generator: Generator?
        init(id: String, origin: String, path: String, suffix: String, sha256: String, generator: Generator? = nil) {
            self.id = id; self.origin = origin; self.path = path; self.suffix = suffix
            self.sha256 = sha256; self.generator = generator
        }
    }
    static var repository: URL { TestFixtures.repositoryRoot }
    static var root: URL { TestFixtures.url("tar-golden") }
    static var modes: [(String, ReaderOptions)] {
        var unlimited = ReadLimits(); unlimited.maxEntrySize = .max; unlimited.maxTotalUncompressedSize = .max
        var disk = ReadLimits(); disk.inMemorySingleFileLimit = 0
        return [("default", ReaderOptions()), ("finder", ReaderOptions(limits: unlimited, appleDoublePolicy: .expose)),
                ("disk", ReaderOptions(limits: disk)), ("recovery", ReaderOptions(recoverDamagedArchives: true))]
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
    static func dump(_ values: [String: Any]) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kaitokit-tar-golden-actual")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json(values).write(to: dir.appendingPathComponent("all-rows.json"))
    }
    static func inputs() throws -> [Input] {
        let inputs = try JSONDecoder().decode([Input].self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        for input in inputs { _ = try decoded(input) }
        return inputs
    }
    static func decoded(_ input: Input) throws -> Data {
        let bytes: Data
        if let generator = input.generator {
            bytes = try generated(generator)
        } else {
            let text = try String(contentsOf: root.appendingPathComponent(input.path), encoding: .utf8)
            bytes = try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters))
        }
        XCTAssertEqual(bytes.sha256Hex, input.sha256, input.id)
        return bytes
    }
    static func generated(_ generator: Generator) throws -> Data {
        switch generator.kind {
        case .manyEntries:
            return try TarTestSupport.makeTar(entries: (0..<70).map {
                HandTarEntry(name: "f\($0)", contents: Data([generator.seed &+ UInt8($0)]))
            })
        case .gzipRichHeader:
            // 小さな圧縮 tail は凍結し、zlib の版による再符号化の差を持ち込まない。
            return gzipHeader(seed: generator.seed) + (try XCTUnwrap(generator.deflateAndTrailer))
        }
    }
    private static func gzipHeader(seed: UInt8) -> Data {
        var bytes = Data([0x1f, 0x8b, 8, 0x1e, 0, 0, 0, 0, 0, 3, 3, 0, 1, 2, 3])
            + Data("archive.tar\0".utf8) + Data(repeating: seed, count: 270_000) + Data([0])
        bytes.append(GyoshukuFramingTestSupport.le(GyoshukuFramingTestSupport.crc(bytes)).prefix(2))
        return bytes
    }
    static func methods(_ input: Input) -> [String] {
        var methods = ["url:" + input.suffix, "file", "counted", "data"]
        if input.suffix == "tar.gz" { methods += ["url:tgz", "url:gz", "url:tar.gz.001"] }
        if input.suffix == "tar.bz2" { methods += ["url:tbz", "url:tbz2", "url:bz2", "url:tar.gz"] }
        if input.suffix == "tar.xz" { methods += ["url:txz", "url:xz", "url:tar.gz"] }
        return methods
    }
    static func publicRows(_ input: Input, data: Data, method: String, options: ReaderOptions) throws -> [[String: Any]] {
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suffix = method.hasPrefix("url:") ? String(method.dropFirst(4)) : input.suffix
        let url = directory.appendingPathComponent(input.id + "." + suffix)
        do {
            let reader: ArchiveReader
            if method == "data" { reader = try ArchiveReader.open(data: data, options: options) }
            else {
                try data.write(to: url)
                switch method {
                case "file": reader = try ArchiveReader.open(source: FileByteSource(url: url), sourceURL: url, options: options)
                case "counted": reader = try ArchiveReader.open(source: CountingByteSource(FileByteSource(url: url)), sourceURL: url, options: options)
                default: reader = try ArchiveReader.open(url: url, options: options)
                }
            }
            var result: [[String: Any]] = [["open": "success", "format": String(describing: reader.format),
                "nameEncoding": reader.nameEncoding.map { $0.rawValue as Any } ?? NSNull(), "count": reader.entries.count]]
            let reopened = try reader.reopen()
            XCTAssertEqual(reopened.entries, reader.entries); XCTAssertEqual(reopened.format, reader.format)
            XCTAssertEqual(reopened.nameEncoding, reader.nameEncoding)
            for entry in reader.entries {
                let bytes = outcome { try reader.read(entry) }
                let streamed = streamOutcome { try reader.stream(entry) }
                XCTAssertEqual(try json(bytes), try json(outcome { try reopened.read(entry) }))
                XCTAssertEqual(try json(streamed), try json(streamOutcome { try reopened.stream(entry) }))
                result.append([
                    "index": entry.index, "kind": String(describing: entry.kind), "name": entry.name,
                    "nameUTF8": hex(entry.name.utf8), "rawName": hex(entry.rawName.bytes),
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
                    "read": bytes, "stream": streamed])
            }
            return result
        } catch { return [["open": "failure", "error": String(describing: error)]] }
    }
    static func outcome(_ body: () throws -> Data) -> [String: Any] {
        do { let data = try body(); return ["sha256": data.sha256Hex, "count": data.count] }
        catch { return ["error": String(describing: error)] }
    }
    static func streamOutcome(_ body: () throws -> EntryStream) -> [String: Any] {
        do {
            let stream = try body(); var hash = SHA256(), total = 0, buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
                if count == 0 { break }; total += count
                hash.update(data: Data(buffer.prefix(count)))
            }
            return ["sha256": hex(hash.finalize()), "count": total]
        } catch { return ["error": String(describing: error)] }
    }
    static func summary(_ rows: [[String: Any]]) throws -> [String: Any] {
        if rows.count <= 65 { return ["rows": rows] }
        return ["rowCount": rows.count, "sha256": try json(rows).sha256Hex, "first": Array(rows.prefix(17)), "last": Array(rows.suffix(16))]
    }
    static func generateInputs() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("inputs"), withIntermediateDirectories: true)
        var manifest: [Input] = []
        func save(_ id: String, _ bytes: Data, _ suffix: String, _ origin: String = "synthetic") throws {
            let generator: Generator?
            switch id {
            case "many-entries": generator = Generator(kind: .manyEntries, seed: 0)
            case "gzip-rich-header":
                generator = Generator(kind: .gzipRichHeader, seed: 65,
                                      deflateAndTrailer: Data(bytes.dropFirst(gzipHeader(seed: 65).count)))
            default: generator = nil
            }
            let path = generator == nil ? "inputs/\(id).\(suffix).b64" : "generated/\(id).\(suffix)"
            if let generator { XCTAssertEqual(try generated(generator), bytes, id) }
            else {
                try bytes.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed]).write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
            }
            manifest.append(Input(id: id, origin: origin, path: path, suffix: suffix, sha256: bytes.sha256Hex, generator: generator))
        }
        let fixtures = repository.appendingPathComponent("Tests/Fixtures")
        for path in ["appledouble/mac.tar", "singlefile/riscv.tar.xz", "singlefile/tar-compress.tar.Z", "zstd/bundle.tar.zst",
                     "lzip/bundle.tar.lz", "brotli/bundle.tar.br", "lz4-frame/legacy-tar.lz4", "lz4-frame/tar-linked.lz4"] {
            let text = try String(contentsOf: fixtures.appendingPathComponent(path + ".b64"), encoding: .utf8)
            let suffix = path.contains(".tar.") ? "tar." + path.components(separatedBy: ".tar.").last! : path.hasSuffix(".tar") ? "tar" : "tar.lz4"
            try save("existing-" + path.replacingOccurrences(of: "/", with: "-"), XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters)), suffix, "existing")
        }
        for file in try FileManager.default.contentsOfDirectory(at: fixtures.appendingPathComponent("tar-edit"), includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) where file.pathExtension == "b64" {
            let text = try String(contentsOf: file, encoding: .utf8), name = file.deletingPathExtension().lastPathComponent
            let suffix = name.hasSuffix("tgz") || name.hasSuffix("gz") && !name.hasSuffix("bz2") ? "tar.gz" : name.hasSuffix("tbz") || name.hasSuffix("bz2") ? "tar.bz2" : "tar.xz"
            try save("supplied-" + name, XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters)), suffix, "supplied")
        }
        for (name, tar) in try TarGoldenInputSupport.tarInputs() {
            try save(name, tar, "tar")
            for (codec, encoded) in [("gz", try GyoshukuFramingTestSupport.gzip(tar, chunkSize: 65_536).data),
                                     ("bz2", try GyoshukuFramingTestSupport.bzip2(tar, level: 1, chunkSize: 4096).data),
                                     ("xz", try GyoshukuFramingTestSupport.xz(tar, chunkSize: 4096).data)] {
                try save(name + "-" + codec, encoded, "tar." + codec)
            }
        }
        for (name, suffix, bytes) in try TarGoldenInputSupport.compressedInputs() { try save(name, bytes, suffix) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(manifest).write(to: root.appendingPathComponent("manifest.json"))
    }
}
