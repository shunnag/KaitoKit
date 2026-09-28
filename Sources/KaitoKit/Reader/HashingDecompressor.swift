import CryptoKit
import Foundation

/// 出力の digest を返せる Decompressor。hash 関数が異なる `HashingDecompressor` を一つの型で扱う。
protocol DigestDecompressor: Decompressor {
    var digest: [UInt8] { get }
}

extension DigestDecompressor {
    /// 小文字 16 進の digest。TOC や header の文字列と比較する。
    var hexDigest: String { digest.map { String(format: "%02x", $0) }.joined() }
}

/// 内側の decoder の出力を読みながら hash を更新し、完了時に digest を照合できるようにする。
/// 出力全体の保持や圧縮 data の再読込を避ける。xar・WIM・rpm の entry 検証が使う。
final class HashingDecompressor<Hash: HashFunction>: DigestDecompressor {
    private let decoder: any Decompressor
    private var hash = Hash()

    init(_ decoder: any Decompressor) { self.decoder = decoder }

    var isFinished: Bool { decoder.isFinished }

    /// ここまでに読んだ出力の digest。`finalize()` は状態を変えないので何度でも呼べる。
    var digest: [UInt8] { Array(hash.finalize()) }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let count = try decoder.read(into: buffer)
        guard count >= 0, count <= buffer.count else { throw KaitoError.malformed("decoder byte count") }
        hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[..<count]))
        return count
    }
}
