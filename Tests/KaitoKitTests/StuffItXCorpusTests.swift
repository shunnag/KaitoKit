// 外部の許諾済みコーパスは環境変数で明示したときだけ検証する。
import Foundation
import CryptoKit
@testable import KaitoKit
import XCTest

final class StuffItXCorpusTests: XCTestCase {
    func testExternalInventory() throws {
        guard let root = ProcessInfo.processInfo.environment["STUFFITX_CORPUS"] else { throw XCTSkip("外部コーパス未指定") }
        var inventory: [[String: Any]] = []
        for directory in ["cc0", "perf"] {
            let folder = URL(fileURLWithPath: root).appendingPathComponent(directory)
            for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path })
                where url.lastPathComponent.lowercased().contains("sitx") {
                var item: [String: Any] = ["file": directory + "/" + url.lastPathComponent]
                do {
                    let source = try FileByteSource(url: url)
                    let envelope = try XCTUnwrap(FormatDetector.stuffItInput(source: source, limits: ReadLimits()))
                    var wrapperHash = SHA256(), wrapperPosition: UInt64 = 0
                    try withUnsafeTemporaryAllocation(byteCount: 65_536, alignment: 16) { buffer in
                        while wrapperPosition < envelope.data.length {
                            let n = try envelope.data.read(into: buffer, at: wrapperPosition)
                            guard n > 0 else { throw KaitoError.truncated }
                            wrapperHash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[..<n])); wrapperPosition += UInt64(n)
                        }
                    }
                    item["unwrappedLength"] = wrapperPosition
                    item["unwrappedSHA256"] = wrapperHash.finalize().map { String(format: "%02x", $0) }.joined()
                    let elements = try StuffItXElementParser(source: envelope.data, limits: ReadLimits()).parse()
                    item["elements"] = elements.map { e -> [String: Any] in
                        var row: [String: Any] = ["type": e.type, "offset": e.offset,
                            "attributes": Dictionary(uniqueKeysWithValues: e.attributes.map { (String($0.key), $0.value) }),
                            "algorithms": e.algorithms.map { [$0.key, $0.value] }]
                        row["extra"] = e.extra
                        return row
                    }
                    if ProcessInfo.processInfo.environment["STUFFITX_VERIFY_STREAMS"] == "1" {
                        var results: [[String: Any]] = []
                        for element in elements where element.type == 1 {
                            let id = try XCTUnwrap(element.attributes[1])
                            let forks = elements.filter { $0.type == 3 && $0.attributes[3] == id }
                            let slots = Dictionary(grouping: forks, by: { $0.attributes[4]! })
                            let auxiliary = !forks.isEmpty && forks.allSatisfy { $0.extra == 3 }
                            let size = auxiliary ? element.attributes[5]! : slots.values.reduce(UInt64(0)) { $0 + $1[0].attributes[5]! }
                            let coordinator = StuffItXStreamCoordinator(source: envelope.data, element: element, size: size, limits: ReadLimits())
                            var position: UInt64 = 0
                            for slot in slots.keys.sorted() {
                                let group = slots[slot]!, length = auxiliary ? size : group[0].attributes[5]!
                                var result: [String: Any] = ["stream": id, "slot": slot, "length": length,
                                    "owners": group.map { $0.attributes[2]! }, "kind": group[0].extra!]
                                do {
                                    let decoder = try coordinator.stream(offset: position, length: length)
                                    var digest = SHA256(), count: UInt64 = 0
                                    try withUnsafeTemporaryAllocation(byteCount: 262_144, alignment: 16) { buffer in
                                        while true {
                                            let n = try decoder.read(into: buffer)
                                            if n == 0 { break }
                                            digest.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[..<n])); count += UInt64(n)
                                        }
                                    }
                                    XCTAssertEqual(count, length)
                                    result["sha256"] = digest.finalize().map { String(format: "%02x", $0) }.joined()
                                } catch KaitoError.unsupportedMethod(let detail) {
                                    result["error"] = KaitoError.unsupportedMethod(detail).description
                                } catch {
                                    result["error"] = String(describing: error)
                                    XCTFail("\(url.lastPathComponent) stream \(id): \(error)")
                                }
                                results.append(result); position += length
                            }
                        }
                        item["forkResults"] = results
                    }
                } catch { item["error"] = String(describing: error) }
                inventory.append(item)
            }
        }
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/" + (ProcessInfo.processInfo.environment["STUFFITX_INVENTORY"] ?? "slice3-inventory.json"))
        try JSONSerialization.data(withJSONObject: inventory, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        try StuffItXReaderTests.archive().write(to: output.deletingLastPathComponent().appendingPathComponent("slice3-container.sitx"))
    }
}
