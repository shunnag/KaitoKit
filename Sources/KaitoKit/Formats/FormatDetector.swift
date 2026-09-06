import Foundation

/// Detects supported archive containers from their structural signatures.
public enum FormatDetector {
    private static let tarBlockSize = 512
    private static let zipEOCDMinimumSize = 22
    private static let zipMaximumCommentSize = 65_535

    /// Detects the archive format exposed by `source`.
    public static func detect(source: any ByteSource) throws -> ArchiveFormat {
        let prefixLength = try Checked.toInt(min(source.length, UInt64(tarBlockSize)))
        let prefix = try read(source: source, at: 0, count: prefixLength)

        // 512-byte 全体で検証できる tar checksum は短い magic より強い証拠になる。
        if try hasValidTarChecksum(prefix) {
            return .tar
        }
        if try isEmptyTar(source: source, firstBlock: prefix) {
            return .tar
        }

        if hasPrefix(prefix, [0x50, 0x4B, 0x03, 0x04])
            || hasPrefix(prefix, [0x50, 0x4B, 0x05, 0x06])
            || hasPrefix(prefix, [0x50, 0x4B, 0x07, 0x08]) {
            return .zip
        }
        if hasPrefix(prefix, [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00])
            || hasPrefix(prefix, [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]) {
            return .rar
        }
        if hasPrefix(prefix, [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) {
            return .sevenZip
        }
        if hasPrefix(prefix, [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) {
            return .xz
        }
        if try isLHAHeader(prefix, sourceLength: source.length) {
            return .lha
        }
        if hasPrefix(prefix, [0x1F, 0x8B]) {
            return .gzip
        }
        if isBzip2Header(prefix) {
            return .bzip2
        }
        if try isTarHeader(prefix) {
            return .tar
        }
        if try containsZipEOCD(source: source) {
            return .zip
        }

        throw KaitoError.unsupportedFormat
    }

    /// Detects the archive format in `data` without copying its storage.
    public static func detect(data: Data) throws -> ArchiveFormat {
        try detect(source: DataByteSource(data: data))
    }

    private static func hasPrefix(_ bytes: [UInt8], _ signature: [UInt8]) -> Bool {
        guard bytes.count >= signature.count else {
            return false
        }
        return bytes.indices.prefix(signature.count).allSatisfy { bytes[$0] == signature[$0] }
    }

    private static func isBzip2Header(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4,
              bytes[0] == 0x42,
              bytes[1] == 0x5A,
              bytes[2] == 0x68 else {
            return false
        }
        return (0x31...0x39).contains(bytes[3])
    }

    private static func isLHAHeader(
        _ bytes: [UInt8],
        sourceLength: UInt64
    ) throws -> Bool {
        guard bytes.count >= 7,
              bytes[2] == 0x2D,
              bytes[6] == 0x2D else {
            return false
        }

        let methodMatches =
            (bytes[3] == 0x6C && (bytes[4] == 0x68 || bytes[4] == 0x7A))
            || (bytes[3] == 0x70 && bytes[4] == 0x6D)
        guard methodMatches else {
            return false
        }

        // Level 0/1 のヘッダ長は先頭 1 バイトで、固定部より短い値は受け付けない。
        let headerSize = UInt64(bytes[0])
        guard headerSize >= 20 else {
            return false
        }
        let totalSize = try Checked.add(headerSize, 2)
        return totalSize <= sourceLength
    }

    private static func isTarHeader(_ bytes: [UInt8]) throws -> Bool {
        guard bytes.count >= tarBlockSize else {
            return false
        }

        if bytes[257] == 0x75,
           bytes[258] == 0x73,
           bytes[259] == 0x74,
           bytes[260] == 0x61,
           bytes[261] == 0x72 {
            return true
        }

        return try hasValidTarChecksum(bytes)
    }

    private static func hasValidTarChecksum(_ bytes: [UInt8]) throws -> Bool {
        guard bytes.count >= tarBlockSize else {
            return false
        }

        // 終端のゼロブロックを空の tar ヘッダと誤認しない。
        guard bytes[..<tarBlockSize].contains(where: { $0 != 0 }) else {
            return false
        }
        guard let recordedChecksum = try parseTarChecksum(bytes[148..<156]) else {
            return false
        }

        var unsignedSum: UInt64 = 0
        var signedSum: Int64 = 0
        for index in 0..<tarBlockSize {
            let byte: UInt8 = (148..<156).contains(index) ? 0x20 : bytes[index]
            unsignedSum = try Checked.add(unsignedSum, UInt64(byte))
            signedSum += Int64(Int8(bitPattern: byte))
        }

        // 古い実装が作った signed-char checksum も安全に認識する。
        return recordedChecksum == unsignedSum
            || (signedSum >= 0 && recordedChecksum == UInt64(signedSum))
    }

    private static func isEmptyTar(
        source: any ByteSource,
        firstBlock: [UInt8]
    ) throws -> Bool {
        guard firstBlock.count == tarBlockSize,
              firstBlock.allSatisfy({ $0 == 0 }),
              source.length >= UInt64(tarBlockSize * 2) else {
            return false
        }
        let secondBlock = try read(
            source: source,
            at: UInt64(tarBlockSize),
            count: tarBlockSize
        )
        return secondBlock.allSatisfy { $0 == 0 }
    }

    private static func parseTarChecksum(_ field: ArraySlice<UInt8>) throws -> UInt64? {
        var value: UInt64 = 0
        var sawDigit = false
        var reachedPadding = false
        var reachedNULTerminator = false

        for byte in field {
            if byte == 0 {
                reachedNULTerminator = true
                continue
            }
            if byte == 0x20 {
                if sawDigit {
                    reachedPadding = true
                }
                continue
            }
            guard !reachedNULTerminator,
                  !reachedPadding,
                  (0x30...0x37).contains(byte) else {
                return nil
            }
            sawDigit = true
            value = try Checked.mul(value, 8)
            value = try Checked.add(value, UInt64(byte - 0x30))
        }
        return sawDigit ? value : nil
    }

    private static func containsZipEOCD(source: any ByteSource) throws -> Bool {
        guard source.length >= UInt64(zipEOCDMinimumSize) else {
            return false
        }

        let maximumSearch = zipMaximumCommentSize + zipEOCDMinimumSize
        let searchLength = try Checked.toInt(min(source.length, UInt64(maximumSearch)))
        let searchOffset = try Checked.sub(source.length, UInt64(searchLength))
        let tail = try read(source: source, at: searchOffset, count: searchLength)
        guard tail.count >= zipEOCDMinimumSize else {
            return false
        }

        for index in stride(
            from: tail.count - zipEOCDMinimumSize,
            through: 0,
            by: -1
        ) {
            guard tail[index] == 0x50,
                  tail[index + 1] == 0x4B,
                  tail[index + 2] == 0x05,
                  tail[index + 3] == 0x06 else {
                continue
            }

            let highCommentLength = try Checked.shiftLeft(
                UInt64(tail[index + 21]),
                by: 8
            )
            let commentLength = UInt64(tail[index + 20]) | highCommentLength
            let recordLength = try Checked.add(UInt64(zipEOCDMinimumSize), commentLength)
            let recordEnd = try Checked.add(UInt64(index), recordLength)
            if recordEnd == UInt64(tail.count) {
                return true
            }
        }
        return false
    }

    private static func read(
        source: any ByteSource,
        at offset: UInt64,
        count: Int
    ) throws -> [UInt8] {
        guard count >= 0 else {
            throw KaitoError.malformed("negative detector read size")
        }
        let endOffset = try Checked.add(offset, UInt64(count))
        guard endOffset <= source.length else {
            throw KaitoError.truncated
        }
        guard count > 0 else {
            return []
        }

        var result = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let readOffset = try Checked.add(offset, UInt64(filled))
            let bytesRead = try result.withUnsafeMutableBytes { bytes -> Int in
                // filled..<count は result の有効範囲で、ByteSource に未充填部分だけを公開する。
                let destination = UnsafeMutableRawBufferPointer(rebasing: bytes[filled..<count])
                return try source.read(into: destination, at: readOffset)
            }
            guard bytesRead >= 0, bytesRead <= count - filled else {
                throw KaitoError.malformed("ByteSource returned an invalid byte count")
            }
            guard bytesRead != 0 else {
                throw KaitoError.truncated
            }
            filled += bytesRead
        }
        return result
    }
}
