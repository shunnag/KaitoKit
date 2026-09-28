import Foundation

/// 件数 loop で cancel を確かめる間隔の mask。1,024 件ごと。
let cancellationCheckMask = 0x3ff

/// `counter` が 1,024 の倍数のときだけ `Task.checkCancellation()` を呼ぶ。header・entry・record の
/// loop で使い、復号の内側 loop では使わない。
@inline(__always)
func checkCancellation<Counter: BinaryInteger>(every counter: Counter) throws {
    if counter & Counter(cancellationCheckMask) == 0 { try Task.checkCancellation() }
}
