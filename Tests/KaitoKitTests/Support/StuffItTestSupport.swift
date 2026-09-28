import Foundation
@testable import KaitoKit
import XCTest

/// StuffIt 1.5–5 の codec を検査する StuffIt* テストが共有する helper。
enum StuffItTestSupport {
    /// 固定の vector を 16 進で書いたもの。16 進として読めない文字列はテストの誤りなので、その場で止める。
    static func hex(_ text: String) -> Data {
        do {
            return try Hex.data(text)
        } catch {
            preconditionFailure("invalid StuffIt test vector: \(error)")
        }
    }

    /// `method` の codec で `input` を `chunk` バイトずつ読み切る。`size` を超えて出力したら失敗にする。
    static func decode(_ input: Data, method: Int, size: Int, chunk: Int = 7, limits: ReadLimits = ReadLimits()) throws -> Data {
        let decoder = try StuffItCodec.make(method: method, source: DataByteSource(data: input), offset: 0,
                                            stored: UInt64(input.count), size: UInt64(size), limits: limits)
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: chunk)
        while true {
            let count = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
            if count == 0 { break }
            output.append(contentsOf: buffer[..<count])
            if output.count > size { XCTFail("出力長の超過"); break }
        }
        XCTAssertTrue(decoder.isFinished)
        return output
    }
}
