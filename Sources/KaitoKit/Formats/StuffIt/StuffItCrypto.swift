// 指定レポート Ch.02・05 の数式に基づく。標準 DES の鍵スケジュールや IP/FP は使用しない。
// 置換表の形式定数は classic-key-substitution.json から転記した。出自は design.md §10 に記載する。
import CryptoKit
import Foundation
import Synchronization

enum StuffItCrypto {
    static func first5(_ bytes: [UInt8]) -> [UInt8] { Array(Insecure.MD5.hash(data: bytes).prefix(5)) }
    static func sit5Key(password: [UInt8], hash: [UInt8]) throws -> [UInt8] {
        let key = first5(password)
        guard hash.count == 5 else { throw KaitoError.malformed("StuffIt 5 archive hash") }
        guard first5(key) == hash else { throw KaitoError.wrongPassword }
        return key
    }
    static func word(_ bytes: [UInt8]) -> UInt64 { bytes.reduce(0) { ($0 << 8) | UInt64($1) } }
    static func bytes(_ word: UInt64) -> [UInt8] {
        stride(from: 56, through: 0, by: -8).map { UInt8(truncatingIfNeeded: word >> $0) }
    }
    static func rol(_ value: UInt32, _ shift: Int) -> UInt32 { value << shift | value >> (32 - shift) }
    static func ror(_ value: UInt32, _ shift: Int) -> UInt32 { value >> shift | value << (32 - shift) }
    static func reverse(_ value: UInt32) -> UInt32 {
        var result: UInt32 = 0, input = value
        for _ in 0..<32 { result = result << 1 | (input & 1); input >>= 1 }
        return result
    }

    struct Permutation {
        private let rounds: [(UInt32, UInt32)]
        init(key: UInt64) {
            let nibbles = (0..<16).map { UInt32((key >> ((15 - $0) * 4)) & 15) }
            var result: [(UInt32, UInt32)] = []
            for r in 0..<16 {
                func n(_ i: Int) -> UInt32 { nibbles[(r + i) & 15] }
                let g = [(n(0) >> 2) | (n(13) << 2), (n(11) >> 2) | (n(6) << 2),
                         (n(3) >> 2) | (n(10) << 2), (n(8) >> 2) | (n(1) << 2)]
                let j = [(n(9) | (n(0) << 4)) & 63, (n(2) | (n(11) << 4)) & 63,
                         (n(14) | (n(3) << 4)) & 63, (n(5) | (n(8) << 4)) & 63]
                var k0: UInt32 = 0, k1: UInt32 = 0
                for i in 0..<4 { k0 |= g[i] << (i * 8); k1 |= j[i] << (i * 8) }
                result.append((reverse(k0), reverse(k1)))
            }
            rounds = result
        }
        func apply(_ input: UInt64, decrypt: Bool = false) -> UInt64 {
            var left = rol(reverse(UInt32(input >> 32)), 3)
            var right = rol(reverse(UInt32(truncatingIfNeeded: input)), 3)
            for index in 0..<16 {
                let key = rounds[decrypt ? 15 - index : index]
                let u = right ^ key.0, v = ror(right, 4) ^ key.1
                var f: UInt32 = 0
                for i in 0..<4 {
                    f ^= substitution[2 * i][Int((u >> (2 + 8 * i)) & 63)]
                    f ^= substitution[2 * i + 1][Int((v >> (2 + 8 * i)) & 63)]
                }
                (left, right) = (right, left ^ f)
            }
            return UInt64(reverse(ror(right, 3))) << 32 | UInt64(reverse(ror(left, 3)))
        }
    }

    static func classicArchiveKey(password: [UInt8]) -> UInt64 {
        let seed: UInt64 = 0x0123456789abcdef
        let permutation = Permutation(key: seed)
        var key = seed
        for block in 0..<(password.count < 8 ? 1 : 2) {
            var value: UInt64 = 0
            for i in 0..<8 {
                let p = 8 * block + i
                value = value << 8 | UInt64(p < password.count ? password[p] & 127 : 0)
            }
            key = permutation.apply(key ^ value)
        }
        return key
    }
    struct ClassicKeys {
        let archive: Permutation
        let verifier: UInt64
        init(password: [UInt8], mkey: [UInt8]) throws {
            guard mkey.count == 8 else { throw KaitoError.malformed("StuffIt MKey length") }
            func verified(_ permutation: Permutation, _ value: UInt64) -> Bool {
                let check = permutation.apply((value & 0xffffffff00000000) | 4)
                return UInt32(truncatingIfNeeded: check) == UInt32(truncatingIfNeeded: value)
            }
            var candidate = Permutation(key: classicArchiveKey(password: password))
            var value = candidate.apply(word(mkey), decrypt: true)
            if !verified(candidate, value), password.count == 8 {
                // CC0 の 4.5 書庫は長さ 8 を 1 block で派生する。Ch.05 の派生を先に試し、
                // この差だけを MKey の検証付きで受理する。検証記録に実測値を残す。
                let seed: UInt64 = 0x0123456789abcdef
                candidate = Permutation(key: Permutation(key: seed).apply(seed ^ word(password.map { $0 & 127 })))
                value = candidate.apply(word(mkey), decrypt: true)
            }
            guard verified(candidate, value) else { throw KaitoError.wrongPassword }
            archive = candidate; verifier = value
        }
        func fork(trailer: [UInt8]) throws -> (key: UInt64, iv: UInt64) {
            guard trailer.count == 16 else { throw KaitoError.malformed("StuffIt encryption trailer") }
            let key = archive.apply(word(Array(trailer[..<8])), decrypt: true) ^ verifier
            return (key, Permutation(key: key).apply(word(Array(trailer[8...])), decrypt: true))
        }
    }
}

// 順列は fork ごとに固定領域へ作り、keystream の先頭から使用する。
final class StuffItRC4 {
    private let permutation: UnsafeMutablePointer<UInt8>
    private var i = 0
    private var j = 0
    init(key: [UInt8]) throws {
        guard !key.isEmpty else { throw KaitoError.malformed("StuffIt RC4 empty key") }
        permutation = .allocate(capacity: 256)
        for i in 0..<256 { permutation[i] = UInt8(i) }
        var j = 0
        for i in 0..<256 {
            j = (j + Int(permutation[i]) + Int(key[i % key.count])) & 255
            let temporary = permutation[i]; permutation[i] = permutation[j]; permutation[j] = temporary
        }
    }
    deinit { permutation.deallocate() }
    @inline(__always) func transform(_ byte: UInt8) -> UInt8 {
        i = (i + 1) & 255; j = (j + Int(permutation[i])) & 255
        let temporary = permutation[i]; permutation[i] = permutation[j]; permutation[j] = temporary
        return byte ^ permutation[(Int(permutation[i]) + Int(permutation[j])) & 255]
    }
}

// ByteSource の任意位置読み契約は、巻戻し時に fork の初期状態から再生して満たす。
final class StuffItCryptoSource: ByteSource {
    enum Mode: Sendable { case rc4([UInt8]); case classic(key: UInt64, iv: UInt64) }
    // input と順列の所有者はこの cursor だけで、全アクセスを Mutex 内に限定する。
    private struct Cursor: @unchecked Sendable {
        let input: StuffItPackedInput
        let rc4: StuffItRC4?
        var feedback: UInt64 = 0
        var block: UInt64 = 0
        var pending = 0
        var position: UInt64 = 0
        init(source: any ByteSource, offset: UInt64, stored: UInt64, mode: Mode) throws {
            input = try StuffItPackedInput(source: source, offset: offset, size: stored)
            switch mode {
            case .rc4(let key): rc4 = try StuffItRC4(key: key)
            case .classic(_, let iv): rc4 = nil; feedback = iv
            }
        }
        mutating func byte(mode: Mode) throws -> UInt8 {
            let result: UInt8
            switch mode {
            case .rc4:
                guard let rc4 else { throw KaitoError.malformed("StuffIt RC4 state") }
                result = try rc4.transform(input.byte())
            case .classic(let key, _):
                if pending == 0 {
                    let x0 = UInt32(try input.bits(32, lsb: false)), x1 = UInt32(try input.bits(32, lsb: false))
                    let a0 = UInt32(key >> 32), a1 = UInt32(truncatingIfNeeded: key)
                    let f1 = UInt32(truncatingIfNeeded: feedback)
                    block = (UInt64(x0) << 32 | UInt64(x1)) ^ key ^ feedback
                    feedback = UInt64(f1) << 32 | UInt64(StuffItCrypto.ror(x0 ^ x1 ^ a0 ^ a1 ^ f1, 1))
                    pending = 8
                }
                pending -= 1; result = UInt8(truncatingIfNeeded: block >> (pending * 8))
            }
            position += 1
            return result
        }
    }
    let length: UInt64
    private let source: any ByteSource
    private let offset: UInt64
    private let stored: UInt64
    private let mode: Mode
    private let cursor: Mutex<Cursor>

    init(source: any ByteSource, offset: UInt64, stored: UInt64, padding: UInt64 = 0, mode: Mode) throws {
        if case .classic = mode {
            guard stored % 8 == 0, padding <= stored else { throw KaitoError.malformed("StuffIt encrypted payload extent") }
        } else if padding != 0 { throw KaitoError.malformed("StuffIt RC4 padding") }
        self.source = source; self.offset = offset; self.stored = stored; self.mode = mode
        length = stored - padding
        cursor = Mutex(try Cursor(source: source, offset: offset, stored: stored, mode: mode))
    }
    func read(into buffer: UnsafeMutableRawBufferPointer, at requestedOffset: UInt64) throws -> Int {
        guard requestedOffset < length, !buffer.isEmpty else { return 0 }
        let count = Int(min(UInt64(buffer.count), length - requestedOffset))
        return try cursor.withLock { state in
            if requestedOffset < state.position { state = try Cursor(source: source, offset: offset, stored: stored, mode: mode) }
            while state.position < requestedOffset { _ = try state.byte(mode: mode) }
            for i in 0..<count { buffer[i] = try state.byte(mode: mode) }
            return count
        }
    }
}

// 数値表の行と添字は入力 JSON の順序を保持する。
extension StuffItCrypto {
    static let substitution: [[UInt32]] = [
        [
            0x02080800, 0x00080000, 0x02000002, 0x02080802, 0x02000000, 0x00080802, 0x00080002, 0x02000002,
            0x00080802, 0x02080800, 0x02080000, 0x00000802, 0x02000802, 0x02000000, 0x00000000, 0x00080002,
            0x00080000, 0x00000002, 0x02000800, 0x00080800, 0x02080802, 0x02080000, 0x00000802, 0x02000800,
            0x00000002, 0x00000800, 0x00080800, 0x02080002, 0x00000800, 0x02000802, 0x02080002, 0x00000000,
            0x00000000, 0x02080802, 0x02000800, 0x00080002, 0x02080800, 0x00080000, 0x00000802, 0x02000800,
            0x02080002, 0x00000800, 0x00080800, 0x02000002, 0x00080802, 0x00000002, 0x02000002, 0x02080000,
            0x02080802, 0x00080800, 0x02080000, 0x02000802, 0x02000000, 0x00000802, 0x00080002, 0x00000000,
            0x00080000, 0x02000000, 0x02000802, 0x02080800, 0x00000002, 0x02080002, 0x00000800, 0x00080802,
        ],
        [
            0x40108010, 0x00000000, 0x00108000, 0x40100000, 0x40000010, 0x00008010, 0x40008000, 0x00108000,
            0x00008000, 0x40100010, 0x00000010, 0x40008000, 0x00100010, 0x40108000, 0x40100000, 0x00000010,
            0x00100000, 0x40008010, 0x40100010, 0x00008000, 0x00108010, 0x40000000, 0x00000000, 0x00100010,
            0x40008010, 0x00108010, 0x40108000, 0x40000010, 0x40000000, 0x00100000, 0x00008010, 0x40108010,
            0x00100010, 0x40108000, 0x40008000, 0x00108010, 0x40108010, 0x00100010, 0x40000010, 0x00000000,
            0x40000000, 0x00008010, 0x00100000, 0x40100010, 0x00008000, 0x40000000, 0x00108010, 0x40008010,
            0x40108000, 0x00008000, 0x00000000, 0x40000010, 0x00000010, 0x40108010, 0x00108000, 0x40100000,
            0x40100010, 0x00100000, 0x00008010, 0x40008000, 0x40008010, 0x00000010, 0x40100000, 0x00108000,
        ],
        [
            0x04000001, 0x04040100, 0x00000100, 0x04000101, 0x00040001, 0x04000000, 0x04000101, 0x00040100,
            0x04000100, 0x00040000, 0x04040000, 0x00000001, 0x04040101, 0x00000101, 0x00000001, 0x04040001,
            0x00000000, 0x00040001, 0x04040100, 0x00000100, 0x00000101, 0x04040101, 0x00040000, 0x04000001,
            0x04040001, 0x04000100, 0x00040101, 0x04040000, 0x00040100, 0x00000000, 0x04000000, 0x00040101,
            0x04040100, 0x00000100, 0x00000001, 0x00040000, 0x00000101, 0x00040001, 0x04040000, 0x04000101,
            0x00000000, 0x04040100, 0x00040100, 0x04040001, 0x00040001, 0x04000000, 0x04040101, 0x00000001,
            0x00040101, 0x04000001, 0x04000000, 0x04040101, 0x00040000, 0x04000100, 0x04000101, 0x00040100,
            0x04000100, 0x00000000, 0x04040001, 0x00000101, 0x04000001, 0x00040101, 0x00000100, 0x04040000,
        ],
        [
            0x00401008, 0x10001000, 0x00000008, 0x10401008, 0x00000000, 0x10400000, 0x10001008, 0x00400008,
            0x10401000, 0x10000008, 0x10000000, 0x00001008, 0x10000008, 0x00401008, 0x00400000, 0x10000000,
            0x10400008, 0x00401000, 0x00001000, 0x00000008, 0x00401000, 0x10001008, 0x10400000, 0x00001000,
            0x00001008, 0x00000000, 0x00400008, 0x10401000, 0x10001000, 0x10400008, 0x10401008, 0x00400000,
            0x10400008, 0x00001008, 0x00400000, 0x10000008, 0x00401000, 0x10001000, 0x00000008, 0x10400000,
            0x10001008, 0x00000000, 0x00001000, 0x00400008, 0x00000000, 0x10400008, 0x10401000, 0x00001000,
            0x10000000, 0x10401008, 0x00401008, 0x00400000, 0x10401008, 0x00000008, 0x10001000, 0x00401008,
            0x00400008, 0x00401000, 0x10400000, 0x10001008, 0x00001008, 0x10000000, 0x10000008, 0x10401000,
        ],
        [
            0x08000000, 0x00010000, 0x00000400, 0x08010420, 0x08010020, 0x08000400, 0x00010420, 0x08010000,
            0x00010000, 0x00000020, 0x08000020, 0x00010400, 0x08000420, 0x08010020, 0x08010400, 0x00000000,
            0x00010400, 0x08000000, 0x00010020, 0x00000420, 0x08000400, 0x00010420, 0x00000000, 0x08000020,
            0x00000020, 0x08000420, 0x08010420, 0x00010020, 0x08010000, 0x00000400, 0x00000420, 0x08010400,
            0x08010400, 0x08000420, 0x00010020, 0x08010000, 0x00010000, 0x00000020, 0x08000020, 0x08000400,
            0x08000000, 0x00010400, 0x08010420, 0x00000000, 0x00010420, 0x08000000, 0x00000400, 0x00010020,
            0x08000420, 0x00000400, 0x00000000, 0x08010420, 0x08010020, 0x08010400, 0x00000420, 0x00010000,
            0x00010400, 0x08010020, 0x08000400, 0x00000420, 0x00000020, 0x00010420, 0x08010000, 0x08000020,
        ],
        [
            0x80000040, 0x00200040, 0x00000000, 0x80202000, 0x00200040, 0x00002000, 0x80002040, 0x00200000,
            0x00002040, 0x80202040, 0x00202000, 0x80000000, 0x80002000, 0x80000040, 0x80200000, 0x00202040,
            0x00200000, 0x80002040, 0x80200040, 0x00000000, 0x00002000, 0x00000040, 0x80202000, 0x80200040,
            0x80202040, 0x80200000, 0x80000000, 0x00002040, 0x00000040, 0x00202000, 0x00202040, 0x80002000,
            0x00002040, 0x80000000, 0x80002000, 0x00202040, 0x80202000, 0x00200040, 0x00000000, 0x80002000,
            0x80000000, 0x00002000, 0x80200040, 0x00200000, 0x00200040, 0x80202040, 0x00202000, 0x00000040,
            0x80202040, 0x00202000, 0x00200000, 0x80002040, 0x80000040, 0x80200000, 0x00202040, 0x00000000,
            0x00002000, 0x80000040, 0x80002040, 0x80202000, 0x80200000, 0x00002040, 0x00000040, 0x80200040,
        ],
        [
            0x00004000, 0x00000200, 0x01000200, 0x01000004, 0x01004204, 0x00004004, 0x00004200, 0x00000000,
            0x01000000, 0x01000204, 0x00000204, 0x01004000, 0x00000004, 0x01004200, 0x01004000, 0x00000204,
            0x01000204, 0x00004000, 0x00004004, 0x01004204, 0x00000000, 0x01000200, 0x01000004, 0x00004200,
            0x01004004, 0x00004204, 0x01004200, 0x00000004, 0x00004204, 0x01004004, 0x00000200, 0x01000000,
            0x00004204, 0x01004000, 0x01004004, 0x00000204, 0x00004000, 0x00000200, 0x01000000, 0x01004004,
            0x01000204, 0x00004204, 0x00004200, 0x00000000, 0x00000200, 0x01000004, 0x00000004, 0x01000200,
            0x00000000, 0x01000204, 0x01000200, 0x00004200, 0x00000204, 0x00004000, 0x01004204, 0x01000000,
            0x01004200, 0x00000004, 0x00004004, 0x01004204, 0x01000004, 0x01004200, 0x01004000, 0x00004004,
        ],
        [
            0x20800080, 0x20820000, 0x00020080, 0x00000000, 0x20020000, 0x00800080, 0x20800000, 0x20820080,
            0x00000080, 0x20000000, 0x00820000, 0x00020080, 0x00820080, 0x20020080, 0x20000080, 0x20800000,
            0x00020000, 0x00820080, 0x00800080, 0x20020000, 0x20820080, 0x20000080, 0x00000000, 0x00820000,
            0x20000000, 0x00800000, 0x20020080, 0x20800080, 0x00800000, 0x00020000, 0x20820000, 0x00000080,
            0x00800000, 0x00020000, 0x20000080, 0x20820080, 0x00020080, 0x20000000, 0x00000000, 0x00820000,
            0x20800080, 0x20020080, 0x20020000, 0x00800080, 0x20820000, 0x00000080, 0x00800080, 0x20020000,
            0x20820080, 0x00800000, 0x20800000, 0x20000080, 0x00820000, 0x00020080, 0x20020080, 0x20800000,
            0x00000080, 0x20820000, 0x00820080, 0x00000000, 0x20000000, 0x20800080, 0x00020000, 0x00820080,
        ],
    ]
}
