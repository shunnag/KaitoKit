import Darwin
import Foundation

/// `bytes` 全体を descriptor に書く。EINTR は再試行し、0 や負の戻りは `.io(errno)`。
/// 展開・staging・KaitoKitCompat の再配置が共有する write(2) の再試行規則。
package func writeAll(_ bytes: UnsafeRawBufferPointer, to descriptor: Int32) throws {
    guard !bytes.isEmpty else { return }
    guard let baseAddress = bytes.baseAddress else {
        throw KaitoError.malformed("write buffer has no storage")
    }
    var written = 0
    while written < bytes.count {
        let result = Darwin.write(descriptor, baseAddress.advanced(by: written), bytes.count - written)
        if result < 0, errno == EINTR { continue }
        guard result > 0 else { throw KaitoError.io(errno) }
        written += result
    }
}
