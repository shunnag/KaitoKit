import CryptoKit
import Foundation
@_spi(SevenZipEditLayout) internal import KaitoKit
import XCTest

final class SevenZipPublicValueGoldenTests: XCTestCase {
    func testFrozenPublicValues() throws {
        let destination = SevenZipGoldenCorpus.root.appendingPathComponent("public-values.json")
        let actual = try SevenZipGoldenCorpus.publicValues()
        if ProcessInfo.processInfo.environment["KAITOKIT_WRITE_7Z_PUBLIC_GOLDEN"] == "1" {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            guard !FileManager.default.fileExists(atPath: destination.path) else { return }
            try actual.write(to: destination, options: .withoutOverwriting)
            try (actual.sha256Hex + "\n").write(
                to: destination.appendingPathExtension("sha256"), atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(actual, try Data(contentsOf: destination))
        XCTAssertEqual(try SevenZipGoldenCorpus.publicValues {
            var options = $0
            options.recordsSevenZipEditLayout = true
            return options
        }, try Data(contentsOf: destination))
        let digest = try String(contentsOf: destination.appendingPathExtension("sha256"), encoding: .utf8)
        XCTAssertEqual(actual.sha256Hex + "\n", digest)
    }
}
