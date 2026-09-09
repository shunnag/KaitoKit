import Foundation

// 欠損が確認された入力だけに使い、既存 codec の切断通知を正常な終端へ変換する。
// 一度の呼出しを 1 byte に限定し、例外で未報告の出力を失わないようにする。
final class RecoveryDecompressor: Decompressor {
    private let input: any Decompressor
    private var stopped = false
    private let maximumOutputSize: UInt64?
    private var produced: UInt64 = 0

    init(_ input: any Decompressor, maximumOutputSize: UInt64?) {
        self.input = input
        self.maximumOutputSize = maximumOutputSize
    }

    var isFinished: Bool { stopped || input.isFinished }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        var written = 0
        while written < buffer.count, !isFinished {
            do {
                let count = try input.read(into: UnsafeMutableRawBufferPointer(
                    rebasing: buffer[written..<(written + 1)]
                ))
                guard count == 0 || count == 1 else {
                    throw KaitoError.malformed("decompressor returned an invalid byte count")
                }
                if count == 0 {
                    guard input.isFinished else { throw KaitoError.truncated }
                    break
                }
                if let maximumOutputSize, produced >= maximumOutputSize {
                    throw KaitoError.malformed("entry output exceeds its declared size")
                }
                produced = try Checked.add(produced, UInt64(count))
                written += count
            } catch KaitoError.truncated {
                stopped = true
            }
        }
        return written
    }
}
