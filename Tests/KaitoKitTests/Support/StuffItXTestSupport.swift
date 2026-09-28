import Foundation
@testable import KaitoKit
import XCTest

/// StuffIt X の codec を検査する StuffItX* テストが共有する helper。
///
/// StuffIt 1.5–5 の `StuffItTestSupport.decode` と引数の名前が同じで `method` の型だけが違うため、
/// 整数リテラルが別の codec へ解決されないよう別の namespace に置く。
enum StuffItXTestSupport {
    // 旧名: StuffItXCodecTests.decode / StuffItXCodecTests.collect
    /// StuffItX の圧縮番号 `method` の codec で `data` を `chunk` バイトずつ読み切る。
    static func decode(_ data: Data, method: UInt64?, size: Int, chunk: Int = 4096, limits: ReadLimits = ReadLimits()) throws -> Data {
        let decoder = try StuffItXCodec.make(method: method, source: DataByteSource(data), size: UInt64(size), limits: limits)
        return try collect(decoder, chunk: chunk)
    }

    /// `decoder` を `chunk` バイトの buffer で 0 を返すまで読み、読み終えた状態になっていることも確かめる。
    static func collect(_ decoder: any Decompressor, chunk: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: chunk), output = Data()
        while true {
            let n = try bytes.withUnsafeMutableBytes { try decoder.read(into: $0) }
            if n == 0 { break }; output.append(contentsOf: bytes[..<n])
        }
        XCTAssertTrue(decoder.isFinished)
        return output
    }
}
