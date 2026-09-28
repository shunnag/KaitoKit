import CryptoKit
import Foundation
@_spi(SevenZipEditLayout) internal import KaitoKit
import XCTest

/// Tests/Fixtures/sevenzip-edit の 7z 書庫と、公開値を JSON にする helper。
enum SevenZipGoldenCorpus {
    static let root = TestFixtures.url("sevenzip-edit")

    static func archives() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "7z" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func nullable<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
    static func json(_ value: Any) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(10)
        return data
    }
    static func error(_ error: any Error) -> [String: String] {
        ["type": String(reflecting: type(of: error)), "value": String(reflecting: error),
         "description": String(describing: error)]
    }

    static func content(reader: ArchiveReader, entry: ArchiveEntry) -> [String: Any] {
        do {
            let stream = try reader.stream(entry)
            var hash = SHA256(), length = 0
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
                if count == 0 { break }
                hash.update(data: Data(buffer.prefix(count)))
                length += count
            }
            return ["sha256": hash.finalize().map { String(format: "%02x", $0) }.joined(), "length": length]
        } catch { return ["error": self.error(error)] }
    }

    static func dump(url: URL, options: ReaderOptions) -> [String: Any] {
        do {
            let reader = try ArchiveReader.open(url: url, options: options)
            let entries: [[String: Any]] = reader.entries.map { entry in
                ["index": entry.index, "name": entry.name, "pathComponents": entry.pathComponents,
                 "rawName": ["bytes": entry.rawName.bytes,
                             "declaredEncoding": nullable(entry.rawName.declaredEncoding?.rawValue),
                             "isDirectoryHint": entry.rawName.isDirectoryHint],
                 "kind": entry.kind.rawValue, "uncompressedSize": nullable(entry.uncompressedSize),
                 "compressedSize": nullable(entry.compressedSize),
                 "modificationDate": nullable(entry.modificationDate?.timeIntervalSince1970),
                 "posixPermissions": nullable(entry.posixPermissions), "isEncrypted": entry.isEncrypted,
                 "isIncomplete": entry.isIncomplete, "solidGroup": entry.solidGroup,
                 "crc32": nullable(entry.crc32), "methodDescription": entry.methodDescription,
                 "formatSpecific": entry.formatSpecific, "content": content(reader: reader, entry: entry)]
            }
            return ["format": reader.format.rawValue, "nameEncoding": nullable(reader.nameEncoding?.rawValue), "entries": entries]
        } catch { return ["error": self.error(error)] }
    }

    static func publicValues(options: (ReaderOptions) -> ReaderOptions = { $0 }) throws -> Data {
        let urls = try archives()
        XCTAssertEqual(urls.count, 33)
        var values: [String: Any] = [:]
        for url in urls {
            for password in url.lastPathComponent == "mix.7z" ? ["secret", "secret2"] : ["secret"] {
                values[url.lastPathComponent + "/" + password] = dump(
                    url: url, options: options(ReaderOptions(password: password)))
            }
        }
        return try json(values)
    }
}
