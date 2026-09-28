import Foundation
@testable import KaitoKit
import XCTest

/// Tests/Fixtures/zip-modern（XZ・Zstandard・AES の ZIP）の読み込みと、その payload の位置。
enum ZipModernFixtures {
    static let password = "KaitoFixture"
    static let payload = Data(String(repeating: "XZ and Zstandard ZIP interoperability 日本語\n", count: 800).utf8)
    static func data(_ name: String) throws -> Data { try TestFixtures.base64("zip-modern/" + name) }
    static func payloadRange(_ bytes: Data) throws -> Range<Int> {
        let layout = try ZipTestSupport.layout(of: bytes)
        let local = try XCTUnwrap(layout.localHeaderOffsets.first)
        let central = try XCTUnwrap(layout.centralEntryOffsets.first)
        let start = local + 30 + Int(try ZipTestSupport.readUInt16(bytes, at: local + 26))
            + Int(try ZipTestSupport.readUInt16(bytes, at: local + 28))
        return start..<(start + Int(try ZipTestSupport.readUInt32(bytes, at: central + 20)))
    }
}
