import Foundation
import KaitoKit

/// `drain` が decoder の異常を見つけたときの error。
enum DrainError: Error {
    /// 0 バイトしか返さないのに `isFinished` にならない。
    case noProgress
    /// `maxReads` 回読んでも終わらない。
    case tooManyReads
}

/// decoder が `isFinished` になるまで `bufferSize` バイトずつ読み、出力をつなげて返す。
///
/// 0 バイトの読み出しで終わらない decoder と、`maxReads` 回を超えて読む decoder は throw する。
func drain(_ decoder: any Decompressor, bufferSize: Int = 4096, maxReads: Int = .max) throws -> Data {
    precondition(bufferSize > 0)
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    var reads = 0
    while !decoder.isFinished {
        guard reads < maxReads else { throw DrainError.tooManyReads }
        let count = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
        reads += 1
        guard count > 0 || decoder.isFinished else { throw DrainError.noProgress }
        result.append(contentsOf: buffer.prefix(count))
    }
    return result
}

/// entry の stream を 0 バイトが返るまで `bufferSize` バイトずつ読み、出力をつなげて返す。
func drain(_ stream: EntryStream, bufferSize: Int = 4096) throws -> Data {
    precondition(bufferSize > 0)
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    while true {
        let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
        if count == 0 { return result }
        result.append(contentsOf: buffer.prefix(count))
    }
}
