// 指定資料 Ch.13 の continuing-MD5 と層状暗号。ブロック暗号化だけを CommonCrypto に委ねる。
private import CommonCrypto
import Foundation
import Synchronization

struct StuffItXContinuingMD5 {
    private var transform = MD5Transform()
    private var buffer = [UInt8](repeating: 0, count: 64)
    private(set) var byteCount: UInt64 = 0

    mutating func absorb(_ bytes: some Sequence<UInt8>) {
        for byte in bytes {
            buffer[Int(byteCount & 63)] = byte
            byteCount &+= 1
            if byteCount & 63 == 0 { transform.compress(buffer) }
        }
    }

    mutating func snapshot() -> [UInt8] {
        let bitCount = byteCount &* 8
        absorb([0x80])
        while byteCount & 63 != 56 { absorb([0]) }
        // length は一時 block にだけ置く。元の buffer・count・更新済み chaining words を残す。
        var temporary = buffer
        for i in 0..<8 { temporary[56 + i] = UInt8(truncatingIfNeeded: bitCount >> (8 * i)) }
        transform.compress(temporary)
        return transform.bytes
    }
}

final class StuffItXCrypto {
    struct Layer: Sendable {
        let cipher: UInt64
        let key: [UInt8]
        var prefixSize: Int { cipher == 3 ? key.count : (cipher == 0 ? 16 : 8) }
    }
    let layers: [Layer]
    let verifier: [UInt8]

    static func derive(_ password: [UInt8], length: Int) throws -> [UInt8] {
        guard (1...65_536).contains(length) else { throw KaitoError.limitExceeded("StuffIt X derivation length") }
        let rounded = (length + 15) & ~15
        var state = StuffItXContinuingMD5(), source = password
        for _ in 0..<256 {
            var output: [UInt8] = []
            output.reserveCapacity(rounded)
            for offset in stride(from: 0, to: rounded, by: 16) {
                state.absorb("StuffIt".utf8)
                state.absorb([UInt8(offset >> 8), UInt8(truncatingIfNeeded: offset)])
                state.absorb(source)
                output += state.snapshot()
            }
            source = output
        }
        return Array(source.prefix(length))
    }

    @discardableResult
    static func validate(_ algorithms: [StuffItXAlgorithm]) throws -> Int {
        var total: UInt64 = 0
        for record in algorithms where record.key == 4 {
            guard let count = record.keyLength, (1...65_536).contains(count) else {
                throw KaitoError.malformed("StuffIt X cipher key length")
            }
            let accepted: Bool
            switch record.value {
            case 0: accepted = [16, 24, 32].contains(count)
            case 1: accepted = (5...56).contains(count)
            case 2: accepted = count == 8
            // KSA 入力は K || salt。実例の 64 を含め、派生と salt の資源量を 1,024 で制限する。
            case 3: accepted = count <= 1_024
            default: throw KaitoError.unsupportedMethod("StuffIt X encryption \(record.value)")
            }
            guard accepted else { throw KaitoError.unsupportedMethod("StuffIt X cipher \(record.value) key length \(count)") }
            total = try Checked.add(total, count)
            guard total <= 65_536 else { throw KaitoError.limitExceeded("StuffIt X total key length") }
        }
        return Int(total)
    }

    init(password: String, algorithms: [StuffItXAlgorithm]) throws {
        let total = try Self.validate(algorithms)
        // password は正規化・終端追加をせず UTF-8 の明示長で渡す。
        let material = try Self.derive(Array(password.utf8), length: total)
        verifier = try Self.derive(material, length: 2)
        var offset = 0, layers: [Layer] = []
        for record in algorithms where record.key == 4 {
            let count = Int(record.keyLength!)
            layers.append(Layer(cipher: record.value, key: Array(material[offset..<offset + count])))
            offset += count
        }
        self.layers = layers
    }

    func decrypt(_ source: any ByteSource) throws -> any ByteSource {
        // 各層の prefix 長は暗号文と平文で不変なので、verifier 判定より先に完全な枠を要求できる。
        let minimum = 2 + layers.reduce(0) { $0 + $1.prefixSize }
        guard source.length >= UInt64(minimum) else { throw KaitoError.truncated }
        let stored = try readByteRange(source: source, offset: 0, count: 2)
        guard (stored[0] ^ verifier[0]) | (stored[1] ^ verifier[1]) == 0 else { throw KaitoError.wrongPassword }
        var input: any ByteSource = try RebasedByteSource(source: source, baseOffset: 2)
        for layer in layers.reversed() { input = try StuffItXCipherSource(source: input, layer: layer) }
        return input
    }

    static func encryptBlock(_ block: [UInt8], layer: Layer) throws -> [UInt8] {
        let algorithm: CCAlgorithm
        switch layer.cipher {
        case 0: algorithm = CCAlgorithm(kCCAlgorithmAES)
        case 1: algorithm = CCAlgorithm(kCCAlgorithmBlowfish)
        case 2: algorithm = CCAlgorithm(kCCAlgorithmDES)
        default: throw KaitoError.unsupportedMethod("StuffIt X block cipher \(layer.cipher)")
        }
        guard block.count == layer.prefixSize else { throw KaitoError.malformed("StuffIt X cipher block size") }
        // CommonCrypto は Blowfish を 8 バイト以上に制限する。5〜7 は周期を変えず 2 回並べる。
        // 元の鍵長による KDF・verifier は変更せず、巡回する鍵展開への入力だけを同値にする。
        let blockKey = layer.cipher == 1 && layer.key.count < kCCKeySizeMinBlowfish ? layer.key + layer.key : layer.key
        var output = [UInt8](repeating: 0, count: block.count), moved = 0
        let status = blockKey.withUnsafeBytes { key in
            block.withUnsafeBytes { input in
                output.withUnsafeMutableBytes { destination in
                    // 各ポインタは呼出中有効で、出力は一 block 分確保済み。CFB 復号でも E_K を使う。
                    CCCrypt(CCOperation(kCCEncrypt), algorithm, CCOptions(kCCOptionECBMode),
                            key.baseAddress, key.count, nil, input.baseAddress, input.count,
                            destination.baseAddress, destination.count, &moved)
                }
            }
        }
        guard status == kCCSuccess, moved == block.count else {
            throw KaitoError.malformed("CommonCrypto StuffIt X failure (\(status))")
        }
        return output
    }
}

// 復号中は固定量の先読みだけを保持する。任意位置読みは保持済み鍵からの再生で満たす。
private final class StuffItXCipherSource: ByteSource {
    private struct Cursor: @unchecked Sendable {
        // input・RC4 の可変状態はこの cursor が所有し、全アクセスを Mutex に限定する。
        let input: StuffItPackedInput
        let rc4: StuffItRC4?
        var feedback: [UInt8]
        var keystream: [UInt8] = []
        var used: Int
        var position: UInt64 = 0

        init(source: any ByteSource, layer: StuffItXCrypto.Layer, prefix: [UInt8]) throws {
            input = try StuffItPackedInput(source: source, offset: UInt64(prefix.count), size: source.length - UInt64(prefix.count))
            rc4 = layer.cipher == 3 ? try StuffItRC4(key: layer.key + prefix) : nil
            feedback = prefix; used = prefix.count
        }

        mutating func byte(layer: StuffItXCrypto.Layer) throws -> UInt8 {
            let ciphertext = try input.byte()
            let plaintext: UInt8
            if let rc4 { plaintext = rc4.transform(ciphertext) }
            else {
                if used == feedback.count {
                    keystream = try StuffItXCrypto.encryptBlock(feedback, layer: layer); used = 0
                }
                plaintext = ciphertext ^ keystream[used]
                feedback[used] = ciphertext; used += 1
            }
            position += 1
            return plaintext
        }
    }
    let length: UInt64
    private let source: any ByteSource
    private let layer: StuffItXCrypto.Layer
    private let prefix: [UInt8]
    private let cursor: Mutex<Cursor>

    init(source: any ByteSource, layer: StuffItXCrypto.Layer) throws {
        self.source = source; self.layer = layer
        prefix = try readByteRange(source: source, offset: 0, count: layer.prefixSize)
        length = source.length - UInt64(prefix.count)
        cursor = Mutex(try Cursor(source: source, layer: layer, prefix: prefix))
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        guard !buffer.isEmpty, offset < length else { return 0 }
        let count = Int(min(UInt64(buffer.count), length - offset))
        return try cursor.withLock { state in
            if offset < state.position { state = try Cursor(source: source, layer: layer, prefix: prefix) }
            while state.position < offset { _ = try state.byte(layer: layer) }
            for i in 0..<count { buffer[i] = try state.byte(layer: layer) }
            return count
        }
    }
}
