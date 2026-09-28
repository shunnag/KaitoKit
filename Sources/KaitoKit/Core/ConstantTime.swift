import Foundation

/// 秘密値の比較。不一致の位置に依存する早期 return を行わず、全 byte の XOR を OR で畳む。
enum ConstantTime {
    static func equals(_ lhs: UInt8, _ rhs: UInt8) -> Bool {
        (lhs ^ rhs) == 0
    }

    static func equals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        lhs.withUnsafeBytes { leftBytes in
            rhs.withUnsafeBytes { rightBytes in
                let left = leftBytes.bindMemory(to: UInt8.self)
                let right = rightBytes.bindMemory(to: UInt8.self)
                for index in 0..<left.count {
                    difference |= left[index] ^ right[index]
                }
            }
        }
        return difference == 0
    }
}
