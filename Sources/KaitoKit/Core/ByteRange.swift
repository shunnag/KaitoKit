import Foundation

/// source 内の連続する一範囲（開始 offset と byte 長）。ISO の section、UDF の extent が使う。
struct ByteRange: Sendable, Equatable {
    let offset: UInt64
    let length: UInt64
}
