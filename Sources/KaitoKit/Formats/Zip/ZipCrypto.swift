import Foundation
import Synchronization

// 参照仕様: PKWARE APPNOTE.TXT 6.3.x, Traditional PKWARE Encryption.

// ZIP 従来暗号の 3 つの鍵状態。すべて UInt32 のラップ演算で更新する。
struct ZipCryptoKeys: Sendable {
    private static let initialKey0: UInt32 = 0x1234_5678
    private static let initialKey1: UInt32 = 0x2345_6789
    private static let initialKey2: UInt32 = 0x3456_7890

    private static let crcTable: [UInt32] = {
        (0..<256).map { value in
            var crc = UInt32(value)
            for _ in 0..<8 {
                let mask = UInt32.max &* (crc & 1)
                crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
            }
            return crc
        }
    }()

    private var key0 = Self.initialKey0
    private var key1 = Self.initialKey1
    private var key2 = Self.initialKey2

    init(password: String) {
        self.init(passwordBytes: Data(password.utf8))
    }

    init(passwordBytes: Data) {
        for byte in passwordBytes {
            update(with: byte)
        }
    }

    // 12 バイト暗号ヘッダを復号し、末尾の検査値を一定時間で照合する。
    mutating func validateAndConsumeHeader(
        _ encryptedHeader: Data,
        expectedCheckByte: UInt8
    ) throws {
        guard encryptedHeader.count == ZipCrypto.headerSize else {
            throw KaitoError.truncated
        }

        let header = decrypt(encryptedHeader)
        guard let actual = header.last,
              ZipConstantTime.equals(actual, expectedCheckByte) else {
            throw KaitoError.wrongPassword
        }
    }

    // 現在の鍵状態から暗号文を復号し、復号後のバイトで鍵を更新する。
    mutating func decrypt(_ ciphertext: Data) -> Data {
        var plaintext = [UInt8](ciphertext)
        plaintext.withUnsafeMutableBytes { buffer in
            decryptInPlace(buffer)
        }
        return Data(plaintext)
    }

    // 呼出側が所有する暗号文バッファを復号し、次の byte 用の鍵状態へ進める。
    mutating func decryptInPlace(_ ciphertext: UnsafeMutableRawBufferPointer) {
        for index in 0..<ciphertext.count {
            let decoded = ciphertext[index] ^ keyStreamByte()
            ciphertext[index] = decoded
            update(with: decoded)
        }
    }

    private func keyStreamByte() -> UInt8 {
        let temporary = key2 | 2
        let product = temporary &* (temporary ^ 1)
        return UInt8(truncatingIfNeeded: product >> 8)
    }

    private mutating func update(with byte: UInt8) {
        key0 = Self.crc32Update(key0, byte: byte)
        key1 = (key1 &+ (key0 & 0xFF)) &* 134_775_813 &+ 1
        key2 = Self.crc32Update(key2, byte: UInt8(truncatingIfNeeded: key1 >> 24))
    }

    private static func crc32Update(_ crc: UInt32, byte: UInt8) -> UInt32 {
        let index = Int(UInt8(truncatingIfNeeded: crc) ^ byte)
        return (crc >> 8) ^ crcTable[index]
    }
}

// 圧縮済み plaintext を必要な範囲だけ復号する ByteSource。通常は前進読みだが、
// 任意 offset の契約も、巻戻し時に鍵を再構築して満たす。
final class ZipCryptoByteSource: ByteSource {
    private static let replayChunkSize = 256 * 1_024

    private struct Cursor: Sendable {
        var offset: UInt64
        var keys: ZipCryptoKeys
    }

    private let source: any ByteSource
    private let bodyOffset: UInt64
    private let initialKeys: ZipCryptoKeys
    private let cursor: Mutex<Cursor>

    let length: UInt64

    init(
        source: any ByteSource,
        offset: UInt64,
        compressedSize: UInt64,
        password: String,
        crc32: UInt32,
        dosTime: UInt16,
        usesDataDescriptor: Bool
    ) throws {
        guard compressedSize >= UInt64(ZipCrypto.headerSize) else {
            throw KaitoError.truncated
        }
        let payloadEnd = try Checked.add(offset, compressedSize)
        guard payloadEnd <= source.length else { throw KaitoError.truncated }

        let header = try readByteRange(
            source: source,
            offset: offset,
            count: ZipCrypto.headerSize
        )
        var keys = ZipCryptoKeys(password: password)
        try keys.validateAndConsumeHeader(
            Data(header),
            expectedCheckByte: ZipCrypto.expectedHeaderCheckByte(
                crc32: crc32,
                dosTime: dosTime,
                usesDataDescriptor: usesDataDescriptor
            )
        )

        self.source = source
        self.bodyOffset = try Checked.add(offset, UInt64(ZipCrypto.headerSize))
        self.length = try Checked.sub(compressedSize, UInt64(ZipCrypto.headerSize))
        self.initialKeys = keys
        self.cursor = Mutex(Cursor(offset: 0, keys: keys))
    }

    func read(
        into buffer: UnsafeMutableRawBufferPointer,
        at offset: UInt64
    ) throws -> Int {
        guard !buffer.isEmpty, offset < length else { return 0 }
        let available = try Checked.sub(length, offset)
        let requested = try Checked.toInt(min(UInt64(buffer.count), available))
        guard requested > 0 else { return 0 }

        return try cursor.withLock { state in
            if offset < state.offset {
                state = Cursor(offset: 0, keys: initialKeys)
            }
            try advance(&state, to: offset)

            let absoluteOffset = try Checked.add(bodyOffset, offset)
            let destination = UnsafeMutableRawBufferPointer(rebasing: buffer[..<requested])
            let actual = try source.read(into: destination, at: absoluteOffset)
            guard actual >= 0, actual <= requested else {
                throw KaitoError.malformed("ByteSource returned an invalid byte count")
            }
            guard actual > 0 else { return 0 }
            state.keys.decryptInPlace(
                UnsafeMutableRawBufferPointer(rebasing: destination[..<actual])
            )
            state.offset = try Checked.add(state.offset, UInt64(actual))
            return actual
        }
    }

    private func advance(_ state: inout Cursor, to target: UInt64) throws {
        while state.offset < target {
            let remaining = try Checked.sub(target, state.offset)
            let count = try Checked.toInt(
                min(UInt64(Self.replayChunkSize), remaining)
            )
            var scratch = [UInt8](repeating: 0, count: count)
            let absoluteOffset = try Checked.add(bodyOffset, state.offset)
            let actual = try scratch.withUnsafeMutableBytes { storage in
                try source.read(into: storage, at: absoluteOffset)
            }
            guard actual >= 0, actual <= count else {
                throw KaitoError.malformed("ByteSource returned an invalid byte count")
            }
            guard actual > 0 else { throw KaitoError.truncated }
            scratch.withUnsafeMutableBytes { storage in
                state.keys.decryptInPlace(
                    UnsafeMutableRawBufferPointer(rebasing: storage[..<actual])
                )
            }
            state.offset = try Checked.add(state.offset, UInt64(actual))
        }
    }
}

// ZIP 従来暗号の一括復号ヘルパー。入力は 12 バイトヘッダを含む。
enum ZipCrypto {
    static let headerSize = 12

    static func expectedHeaderCheckByte(
        crc32: UInt32,
        dosTime: UInt16,
        usesDataDescriptor: Bool
    ) -> UInt8 {
        if usesDataDescriptor {
            return UInt8(truncatingIfNeeded: dosTime >> 8)
        }
        return UInt8(truncatingIfNeeded: crc32 >> 24)
    }

    static func decrypt(
        payloadIncludingHeader payload: Data,
        password: String,
        crc32: UInt32,
        dosTime: UInt16,
        usesDataDescriptor: Bool
    ) throws -> Data {
        try decrypt(
            payloadIncludingHeader: payload,
            passwordBytes: Data(password.utf8),
            crc32: crc32,
            dosTime: dosTime,
            usesDataDescriptor: usesDataDescriptor
        )
    }

    static func decrypt(
        payloadIncludingHeader payload: Data,
        passwordBytes: Data,
        crc32: UInt32,
        dosTime: UInt16,
        usesDataDescriptor: Bool
    ) throws -> Data {
        guard payload.count >= headerSize else {
            throw KaitoError.truncated
        }

        let headerEnd = payload.index(payload.startIndex, offsetBy: headerSize)
        let encryptedHeader = Data(payload[payload.startIndex..<headerEnd])
        let encryptedBody = Data(payload[headerEnd..<payload.endIndex])
        let expected = expectedHeaderCheckByte(
            crc32: crc32,
            dosTime: dosTime,
            usesDataDescriptor: usesDataDescriptor
        )

        var keys = ZipCryptoKeys(passwordBytes: passwordBytes)
        try keys.validateAndConsumeHeader(encryptedHeader, expectedCheckByte: expected)
        return keys.decrypt(encryptedBody)
    }
}

// 秘密値の比較で不一致位置に依存する早期 return を行わない。
enum ZipConstantTime {
    static func equals(_ lhs: UInt8, _ rhs: UInt8) -> Bool {
        (lhs ^ rhs) == 0
    }

    static func equals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }

        var difference: UInt8 = 0
        var leftIndex = lhs.startIndex
        var rightIndex = rhs.startIndex
        while leftIndex < lhs.endIndex {
            difference |= lhs[leftIndex] ^ rhs[rightIndex]
            lhs.formIndex(after: &leftIndex)
            rhs.formIndex(after: &rightIndex)
        }
        return difference == 0
    }
}
