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
