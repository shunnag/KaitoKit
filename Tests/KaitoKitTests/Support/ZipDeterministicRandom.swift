import Foundation

/// seed から決まる擬似乱数と、それを使った書庫のバイト列の変異（差分 fuzz 用）。
struct ZipDeterministicRandom {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 16) % UInt64(bound))
    }
    mutating func mutate(_ data: Data, operation: Int) -> Data {
        var bytes = Array(data)
        switch operation {
        case 0:
            for _ in 0..<(1 + next(min(16, bytes.count))) { bytes[next(bytes.count)] ^= 1 << next(8) }
        case 1:
            let count = 1 + next(min(32, bytes.count))
            let offset = next(bytes.count - count + 1)
            bytes.replaceSubrange(offset..<(offset + count), with: repeatElement(UInt8(next(256)), count: count))
        case 2:
            let choices = [0, bytes.count - 1, next(bytes.count)]
            bytes = Array(bytes.prefix(choices[next(3)]))
        default:
            let offset = next(bytes.count + 1)
            let count = 1 + next(64)
            bytes.insert(contentsOf: (0..<count).map { _ in UInt8(next(256)) }, at: offset)
        }
        return Data(bytes)
    }
}
