// RFC 1321 §3.3–3.5 の数式と定数に基づく圧縮関数。padding と byte count は呼出側が管理する。
struct MD5Transform {
    private var h: [UInt32] = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476]

    var bytes: [UInt8] {
        h.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * $0)) } }
    }

    mutating func compress(_ block: [UInt8]) {
        precondition(block.count == 64)
        var words = [UInt32](repeating: 0, count: 16)
        for i in 0..<64 { words[i / 4] |= UInt32(block[i]) << (8 * (i % 4)) }
        var a = h[0], b = h[1], c = h[2], d = h[3]
        for i in 0..<64 {
            let f: UInt32, index: Int
            switch i {
            case 0..<16: f = (b & c) | (~b & d); index = i
            case 16..<32: f = (b & d) | (c & ~d); index = (5 * i + 1) % 16
            case 32..<48: f = b ^ c ^ d; index = (3 * i + 5) % 16
            default: f = c ^ (b | ~d); index = (7 * i) % 16
            }
            let value = a &+ f &+ Self.constants[i] &+ words[index]
            let shift = Self.shifts[(i / 16) * 4 + i % 4]
            let next = b &+ ((value << shift) | (value >> (32 - shift)))
            a = d; d = c; c = b; b = next
        }
        h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
    }

    private static let shifts = [7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21]
    private static let constants: [UInt32] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
        0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
        0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
        0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
        0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391
    ]
}
