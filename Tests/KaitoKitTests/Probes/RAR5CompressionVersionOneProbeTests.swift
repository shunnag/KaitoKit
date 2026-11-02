import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

final class RAR5CompressionVersionOneProbeTests: XCTestCase {
    func testActualArchiveMatchesExpectedSizeAndSHA256() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["KAITO_RAR5_V1_ARCHIVE"],
              let expectedSHA256 = environment["KAITO_RAR5_V1_SHA256"] else {
            throw XCTSkip("set KAITO_RAR5_V1_ARCHIVE and KAITO_RAR5_V1_SHA256")
        }
        let options = ReaderOptions(limits: ReadLimits(
            maxEntrySize: 6 << 30,
            maxDictionarySize: 8 << 30
        ))
        let url = URL(fileURLWithPath: path)
        let reader = try ArchiveReader.open(url: url, options: options)
        let entry = try XCTUnwrap(reader.entries.first)
        let limited = try ArchiveReader.open(
            url: url,
            options: ReaderOptions(limits: ReadLimits(
                maxEntrySize: 6 << 30,
                maxDictionarySize: 5 << 30
            ))
        )
        XCTAssertThrowsError(try limited.stream(limited.entries[0])) { error in
            guard case .limitExceeded = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        let stream = try reader.stream(entry)
        var hash = SHA256()
        var count: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let read = try buffer.withUnsafeMutableBytes { storage in
                try stream.read(into: storage)
            }
            if read == 0 { break }
            buffer.withUnsafeBytes { storage in
                hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: storage[..<read]))
            }
            count += UInt64(read)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(count, 5 << 30)
        XCTAssertEqual(digest, expectedSHA256)
        print("RAR5-V1 bytes=\(count) sha256=\(digest)")
    }
}
