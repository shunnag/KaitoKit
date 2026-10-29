// 参照: KaitoKit 自身の PPMd H / I の 6-byte state 配置・状態検索・mask 頻度集計。
// Symbol is the first byte of each packed state in both arena models.
enum PPMdStateScan {
    // The caller validates count * 6 bytes in its live arena, with count in
    // 1...256. Four states occupy 24 bytes, so +0/+6/+12/+18 are inside each
    // complete group. The tail reads only remaining states. Pointer advances
    // end at most one past the checked block; no arena mutation occurs here.
    @inline(__always)
    static func index(of symbol: UInt8, in states: UnsafePointer<UInt8>, count: Int) -> Int? {
        var bytes = states
        var index = 0
        while count - index >= 4 {
            if bytes[0] == symbol { return index }
            if bytes[6] == symbol { return index + 1 }
            if bytes[12] == symbol { return index + 2 }
            if bytes[18] == symbol { return index + 3 }
            bytes += 24
            index += 4
        }
        while index < count {
            if bytes.pointee == symbol { return index }
            bytes += 6
            index += 1
        }
        return nil
    }

    // Same checked count * 6 state span as index(). Symbols are UInt8 indices
    // into the caller's live 256-byte mask. A term is a byte frequency times
    // 0 or 1; count <= 256 and frequency sum <= 65,280 on every input. No
    // allocation or mutation of either span occurs during this scan.
    @inline(__always)
    static func unmasked(in states: UnsafePointer<UInt8>, count: Int,
                         mask: UnsafePointer<UInt8>, escapeCount: UInt8) -> (count: Int, frequency: Int) {
        var bytes = states
        var availableCount = 0
        var frequency = 0
        for _ in 0..<count {
            let available = mask[Int(bytes.pointee)] != escapeCount ? 1 : 0
            availableCount &+= available
            frequency &+= Int(bytes[1]) &* available
            bytes += 6
        }
        return (availableCount, frequency)
    }
}
