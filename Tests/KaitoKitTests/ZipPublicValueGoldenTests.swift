import CryptoKit
import Foundation
import KaitoKit
import XCTest

// Step 0 の byte を保持する。圧縮は Foundation、入力は b518014 の test support と固定 SHA-256 を使う。
final class ZipPublicValueGoldenTests: XCTestCase {
    func testFrozenPublicValues() throws {
        let environment = ProcessInfo.processInfo.environment
        if environment["KAITOKIT_WRITE_ZIP_GOLDEN_INPUTS"] == "1" {
            try ZipGoldenCorpus.generateInputs()
        }
        let inputs = try ZipGoldenCorpus.inputs()
        XCTAssertEqual(inputs.filter { $0.origin == "existing" }.count, 30)
        let utc = TimeZone.current.secondsFromGMT() == 0
        var values: [String: Any] = [:]
        var datedValues: [String: Any] = [:]
        var fullRows: [String: Any] = [:]
        for input in inputs {
            for mode in ZipGoldenCorpus.modes {
                let key = input.id + "/" + mode.name
                let rows = try ZipGoldenCorpus.publicRows(input, options: mode.options)
                let plain = rows.map { row in row.filter { $0.key != "modificationDate" } }
                values[key] = try ZipGoldenCorpus.summary(plain)
                if utc { datedValues[key] = try ZipGoldenCorpus.summary(rows) }
                fullRows[key] = rows
            }
        }
        let destination = ZipGoldenCorpus.root.appendingPathComponent("public-values.json.lzfse")
        if environment["KAITOKIT_WRITE_ZIP_GOLDEN"] == "1" {
            guard utc else { throw ZipTestSupportError.fixture("generate golden values with TZ=UTC") }
            let bytes = try ZipGoldenCorpus.json(["values": values, "utcValues": datedValues])
            let compressed = try (bytes as NSData).compressed(using: .lzfse) as Data
            try compressed.write(to: destination)
            try (bytes.sha256Hex + "\n").write(
                to: ZipGoldenCorpus.root.appendingPathComponent("public-values.json.sha256"),
                atomically: true, encoding: .utf8)
        }
        // 入力生成のみの初回も、その場の公開値を保存せず次の UTC 生成へ進める。
        if environment["KAITOKIT_WRITE_ZIP_GOLDEN_INPUTS"] == "1",
           !FileManager.default.fileExists(atPath: destination.path) { return }
        let expectedBytes = try ZipGoldenCorpus.publicValues()
        if let path = environment["KAITOKIT_DUMP_ZIP_GOLDEN"] {
            try expectedBytes.write(to: URL(fileURLWithPath: path))
        }
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: expectedBytes) as? [String: Any])
        let matches = try ZipGoldenCorpus.json(values) == ZipGoldenCorpus.json(XCTUnwrap(expected["values"]))
            && (!utc || ZipGoldenCorpus.json(datedValues) == ZipGoldenCorpus.json(XCTUnwrap(expected["utcValues"])))
        if !matches {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kaitokit-zip-golden-actual")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try ZipGoldenCorpus.json(fullRows).write(to: directory.appendingPathComponent("all-rows.json"))
            try expectedBytes.write(to: directory.appendingPathComponent("expected.json"))
            var actual = expected
            actual["values"] = values
            if utc { actual["utcValues"] = datedValues }
            try ZipGoldenCorpus.json(actual).write(to: directory.appendingPathComponent("actual.json"))
            XCTFail("ZIP public values differ; expected.json, actual.json and full all-rows.json: \(directory.path)")
        }
        print("ZIP-GOLDEN inputs=\(inputs.count) existing=30 modes=6 UTC=\(utc)")
    }
}
