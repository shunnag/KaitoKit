import Foundation

// PKWARE APPNOTE.TXT 6.3.10 §5.1（Shrinking）、§5.2（Reducing）、§5.3（Imploding）の公開仕様に基づく
// クリーンルーム実装。APPNOTE が暗黙にしている bit 順（byte 内 LSB 先頭）と終端（宣言された展開後サイズで
// 止まる）は、自作 encoder の出力を Info-ZIP unzip / 7-Zip / deark が同じ内容に展開することで確定した
//（2026-09-21 の検証記録）。Info-ZIP / 7-Zip / deark / PKZIP の実装ソースは開いていない。

/// 圧縮範囲を LSB 先頭で読む bit reader。入力が尽きたら truncated。
struct ZipLegacyBitReader {
    private let source: any ByteSource
    private let end: UInt64
    private var offset: UInt64
    private var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    private var bufferOffset = 0
    private var bufferCount = 0
    private var bits: UInt64 = 0
    private var bitCount = 0

    init(source: any ByteSource, offset: UInt64, compressedSize: UInt64) throws {
        end = try Checked.add(offset, compressedSize)
        guard end <= source.length else { throw KaitoError.truncated }
        self.source = source
        self.offset = offset
    }

    private mutating func fill() throws -> Bool {
        guard offset < end else { return false }
        let count = Int(min(UInt64(buffer.count), end - offset))
        let position = offset
        let source = self.source
        let read = try buffer.withUnsafeMutableBytes { raw in
            try source.read(into: UnsafeMutableRawBufferPointer(rebasing: raw[..<count]), at: position)
        }
        guard read > 0 else { throw KaitoError.truncated }
        offset += UInt64(read)
        bufferOffset = 0
        bufferCount = read
        return true
    }

    mutating func read(_ count: Int) throws -> Int {
        precondition(count >= 0 && count <= 32)
        while bitCount < count {
            if bufferOffset == bufferCount, try !fill() { throw KaitoError.truncated }
            bits |= UInt64(buffer[bufferOffset]) << UInt64(bitCount)
            bufferOffset += 1
            bitCount += 8
        }
        let value = Int(bits & ((1 << UInt64(count)) - 1))
        bits >>= UInt64(count)
        bitCount -= count
        return value
    }

    mutating func readBit() throws -> Int { try read(1) }
}

/// 展開後 byte を呼び出し側の buffer へ順に渡す共通の枝。`produce` が 1 byte ずつ生成する。
private struct OutputPump {
    let expectedSize: UInt64
    var produced: UInt64 = 0
    var isFinished: Bool { produced == expectedSize }
}

// MARK: - Shrink (method 1)

/// §5.1: 動的 LZW（9〜13 bit）。code 256 の後の 1 = code size 拡大、2 = 葉の部分クリア。
final class ShrinkDecompressor: Decompressor {
    private static let maximumBits = 13
    private var reader: ZipLegacyBitReader
    private var pump: OutputPump
    private var codeSize = 9
    /// code → (prefix code, 末尾 byte)。256 未満は literal。
    private var prefix = [Int](repeating: -1, count: 1 << maximumBits)
    private var suffix = [UInt8](repeating: 0, count: 1 << maximumBits)
    private var defined = [Bool](repeating: false, count: 1 << maximumBits)
    private var childCount = [Int](repeating: 0, count: 1 << maximumBits)
    private var nextCode = 257
    private var freeCodes: [Int] = []
    private var freeIndex = 0
    private var previousCode = -1
    /// 復号した文字列。`string(for:)` が末尾から詰めるので、有効部分は `pendingOffset..<pendingEnd`。
    private var pendingString = [UInt8](repeating: 0, count: (1 << maximumBits) + 1)
    private var pendingOffset = 0
    private var pendingEnd = 0

    init(source: any ByteSource, offset: UInt64, compressedSize: UInt64, expectedSize: UInt64) throws {
        reader = try ZipLegacyBitReader(source: source, offset: offset, compressedSize: compressedSize)
        pump = OutputPump(expectedSize: expectedSize)
        for code in 0..<256 { defined[code] = true }
    }

    var isFinished: Bool { pump.isFinished && pendingOffset == pendingEnd }

    private func allocate() -> Int? {
        if freeIndex < freeCodes.count {
            let code = freeCodes[freeIndex]
            freeIndex += 1
            return code
        }
        guard nextCode < (1 << Self.maximumBits) else { return nil }
        let code = nextCode
        nextCode += 1
        return code
    }

    /// `code` の文字列を `pendingString` の末尾から詰め、先頭の index を返す。長さは表の大きさを超えない。
    private func string(for code: Int) throws -> Int {
        var index = pendingString.count
        var current = code
        while current >= 256 {
            guard defined[current], index > 1 else { throw KaitoError.malformed("ZIP shrink code chain") }
            index -= 1
            pendingString[index] = suffix[current]
            current = prefix[current]
        }
        index -= 1
        pendingString[index] = UInt8(current)
        return index
    }

    /// §5.1.3: 他の code の prefix になっていない code をすべて解放し、低い番号から再利用する。
    private func partialClear() {
        var leaves: [Int] = []
        for code in 257..<(1 << Self.maximumBits) where defined[code] && childCount[code] == 0 { leaves.append(code) }
        for code in leaves {
            defined[code] = false
            if prefix[code] >= 0 { childCount[prefix[code]] -= 1 }
            prefix[code] = -1
        }
        // 前回までの clear で解放され、まだ再利用していない code も低い番号順で残す。
        freeCodes = (257..<nextCode).filter { !defined[$0] }
        freeIndex = 0
    }

    private func decodeNextString() throws {
        while true {
            let code = try reader.read(codeSize)
            if code == 256 {
                let escape = try reader.read(codeSize)
                switch escape {
                case 1:
                    guard codeSize < Self.maximumBits else { throw KaitoError.malformed("ZIP shrink code size") }
                    codeSize += 1
                case 2:
                    partialClear()
                default:
                    throw KaitoError.malformed("ZIP shrink escape \(escape)")
                }
                continue
            }
            var start: Int
            let end = pendingString.count
            if previousCode >= 0 {
                // 直前の code + 今回の先頭文字を新しい code として登録する（KwKwK は今回の code 自身）。
                // 直前の code が部分クリアで解放済みでも登録は行う（prefix として参照だけ残す）。
                // 黒箱で確定: unzip / 7-Zip / deark はこの規約の stream だけを受け入れる（検証記録参照）。
                if defined[code] {
                    start = try string(for: code)
                } else {
                    // KwKwK: 直前の文字列 + その先頭 byte。1 byte 左へずらして末尾に先頭 byte を置く。
                    start = try string(for: previousCode)
                    guard start > 0 else { throw KaitoError.malformed("ZIP shrink code chain") }
                    for index in start..<end { pendingString[index - 1] = pendingString[index] }
                    start -= 1
                    pendingString[end - 1] = pendingString[start]
                }
                if let newCode = allocate() {
                    if !defined[code], newCode != code { throw KaitoError.malformed("ZIP shrink undefined code \(code)") }
                    defined[newCode] = true
                    prefix[newCode] = previousCode
                    suffix[newCode] = pendingString[start]
                    childCount[previousCode] += 1
                } else if !defined[code] {
                    throw KaitoError.malformed("ZIP shrink undefined code \(code)")
                }
            } else {
                guard defined[code] else { throw KaitoError.malformed("ZIP shrink first code") }
                start = try string(for: code)
            }
            previousCode = code
            pendingOffset = start
            pendingEnd = end
            return
        }
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !isFinished else { return 0 }
        var written = 0
        while written < buffer.count, !isFinished {
            if pendingOffset == pendingEnd {
                guard !pump.isFinished else { break }
                try decodeNextString()
            }
            let remaining = Int(min(UInt64(pendingEnd - pendingOffset), pump.expectedSize - pump.produced))
            let count = min(remaining, buffer.count - written)
            pendingString.withUnsafeBytes { bytes in
                buffer.baseAddress!.advanced(by: written).copyMemory(from: bytes.baseAddress!.advanced(by: pendingOffset), byteCount: count)
            }
            pendingOffset += count
            written += count
            pump.produced += UInt64(count)
            if pump.isFinished { pendingOffset = pendingEnd }
        }
        return written
    }
}

// MARK: - Reduce (methods 2-5)

/// §5.2: follower set による確率的復号と、DLE（144）による RLE の 2 段。
final class ReduceDecompressor: Decompressor {
    private var reader: ZipLegacyBitReader
    private var pump: OutputPump
    private let lengthBits: Int
    private var followers: [[UInt8]] = []
    private var followerBits: [Int] = []
    private var lastByte = 0
    private var setsRead = false
    private var state = 0
    private var v = 0
    private var length = 0
    private var window = [UInt8](repeating: 0, count: 4_096)
    private var windowOffset = 0
    private var copyRemaining = 0
    private var copyDistance = 0

    init(source: any ByteSource, offset: UInt64, compressedSize: UInt64, expectedSize: UInt64, factor: Int) throws {
        guard (1...4).contains(factor) else { throw KaitoError.unsupportedMethod("ZIP reduce factor \(factor)") }
        reader = try ZipLegacyBitReader(source: source, offset: offset, compressedSize: compressedSize)
        pump = OutputPump(expectedSize: expectedSize)
        lengthBits = 8 - factor
    }

    var isFinished: Bool { pump.isFinished }

    /// §5.2.2〜5.2.3: S(255) から S(0) の順に、6 bit の N(j) と N(j) 個の 8 bit。
    private func readFollowerSets() throws {
        followers = [[UInt8]](repeating: [], count: 256)
        followerBits = [Int](repeating: 0, count: 256)
        for j in stride(from: 255, through: 0, by: -1) {
            let count = try reader.read(6)
            guard count <= 32 else { throw KaitoError.malformed("ZIP reduce follower set size") }
            var set: [UInt8] = []
            for _ in 0..<count { set.append(UInt8(try reader.read(8))) }
            followers[j] = set
            // B(N) = N − 1 を表す最小 bit 数。N = 1 のときは 0 bit ではなく 1 bit（deark の黒箱で確定、検証記録参照）。
            followerBits[j] = count <= 2 ? 1 : Int.bitWidth - (count - 1).leadingZeroBitCount
        }
        setsRead = true
    }

    /// §5.2.4 の 1 byte。
    private func nextIntermediateByte() throws -> Int {
        let set = followers[lastByte]
        let value: Int
        if set.isEmpty {
            value = try reader.read(8)
        } else if try reader.readBit() != 0 {
            value = try reader.read(8)
        } else {
            let index = try reader.read(followerBits[lastByte])
            guard index < set.count else { throw KaitoError.malformed("ZIP reduce follower index") }
            value = Int(set[index])
        }
        lastByte = value
        return value
    }

    private func emit(_ byte: UInt8, into buffer: UnsafeMutableRawBufferPointer, at index: Int) {
        buffer[index] = byte
        window[windowOffset] = byte
        windowOffset = (windowOffset + 1) & (window.count - 1)
        pump.produced += 1
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !isFinished else { return 0 }
        if !setsRead { try readFollowerSets() }
        var written = 0
        while written < buffer.count, !pump.isFinished {
            if copyRemaining > 0 {
                // §5.2.5 state 3: 出力の先頭より前は 0 として扱う。
                let byte: UInt8 = UInt64(copyDistance) > pump.produced ? 0 : window[(windowOffset - copyDistance) & (window.count - 1)]
                emit(byte, into: buffer, at: written)
                written += 1
                copyRemaining -= 1
                continue
            }
            let c = try nextIntermediateByte()
            switch state {
            case 0:
                if c == 144 { state = 1 } else { emit(UInt8(c), into: buffer, at: written); written += 1 }
            case 1:
                if c == 0 {
                    emit(144, into: buffer, at: written); written += 1
                    state = 0
                } else {
                    v = c
                    length = c & ((1 << lengthBits) - 1)
                    state = length == (1 << lengthBits) - 1 ? 2 : 3
                }
            case 2:
                length += c
                state = 3
            default:
                copyDistance = (v >> lengthBits) * 256 + c + 1
                copyRemaining = length + 3
                state = 0
            }
        }
        return written
    }
}

// MARK: - Implode (method 6)

/// §5.3.7〜5.3.8 の Shannon-Fano 木。bit 長の並びから code を作り、LSB 先頭で 1 bit ずつ読んで照合する。
struct ImplodeTree {
    private var codeToSymbol: [Int: Int] = [:]      // (length << 16 | code) → symbol
    private let maximumLength: Int

    init(_ reader: inout ZipLegacyBitReader, symbolCount: Int) throws {
        let byteCount = try reader.read(8) + 1
        var lengths: [Int] = []
        for _ in 0..<byteCount {
            let pair = try reader.read(8)
            let count = (pair >> 4) + 1
            let length = (pair & 0x0F) + 1
            for _ in 0..<count { lengths.append(length) }
        }
        guard lengths.count == symbolCount else { throw KaitoError.malformed("ZIP implode tree size \(lengths.count)") }
        // §5.3.8: 長さで安定 sort → 最長から code を割り当て（増分 2^(16−長さ)）→ 16 bit を反転 → 元の順序へ。
        let order = lengths.indices.sorted { lengths[$0] < lengths[$1] }
        var code = 0, increment = 0, last = 0
        var codes = [Int](repeating: 0, count: symbolCount)
        for index in order.indices.reversed() {
            code += increment
            let length = lengths[order[index]]
            if length != last { last = length; increment = 1 << (16 - length) }
            guard code <= 0xFFFF else { throw KaitoError.malformed("ZIP implode tree overflow") }
            var reversed = 0
            for bit in 0..<16 where code & (1 << bit) != 0 { reversed |= 1 << (15 - bit) }
            codes[order[index]] = reversed
        }
        var table: [Int: Int] = [:]
        for symbol in 0..<symbolCount {
            let key = lengths[symbol] << 16 | (codes[symbol] & ((1 << lengths[symbol]) - 1))
            guard table[key] == nil else { throw KaitoError.malformed("ZIP implode tree is not a prefix code") }
            table[key] = symbol
        }
        codeToSymbol = table
        maximumLength = lengths.max() ?? 1
    }

    func decode(_ reader: inout ZipLegacyBitReader) throws -> Int {
        var code = 0
        for length in 1...maximumLength {
            code |= try reader.readBit() << (length - 1)
            if let symbol = codeToSymbol[length << 16 | code] { return symbol }
        }
        throw KaitoError.malformed("ZIP implode code")
    }
}

final class ImplodeDecompressor: Decompressor {
    private var reader: ZipLegacyBitReader
    private var pump: OutputPump
    private let bigWindow: Bool
    private let literalTree: ImplodeTree?
    private let lengthTree: ImplodeTree
    private let distanceTree: ImplodeTree
    private let minimumMatch: Int
    private var window: [UInt8]
    private var windowOffset = 0
    private var copyRemaining = 0
    private var copyDistance = 0

    init(source: any ByteSource, offset: UInt64, compressedSize: UInt64, expectedSize: UInt64, flags: UInt16) throws {
        var reader = try ZipLegacyBitReader(source: source, offset: offset, compressedSize: compressedSize)
        bigWindow = flags & 0x0002 != 0
        let threeTrees = flags & 0x0004 != 0
        literalTree = threeTrees ? try ImplodeTree(&reader, symbolCount: 256) : nil
        lengthTree = try ImplodeTree(&reader, symbolCount: 64)
        distanceTree = try ImplodeTree(&reader, symbolCount: 64)
        minimumMatch = threeTrees ? 3 : 2
        window = [UInt8](repeating: 0, count: bigWindow ? 8_192 : 4_096)
        self.reader = reader
        pump = OutputPump(expectedSize: expectedSize)
    }

    var isFinished: Bool { pump.isFinished }

    private func emit(_ byte: UInt8, into buffer: UnsafeMutableRawBufferPointer, at index: Int) {
        buffer[index] = byte
        window[windowOffset] = byte
        windowOffset = (windowOffset + 1) & (window.count - 1)
        pump.produced += 1
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !isFinished else { return 0 }
        var written = 0
        while written < buffer.count, !pump.isFinished {
            if copyRemaining > 0 {
                let byte: UInt8 = UInt64(copyDistance) > pump.produced ? 0 : window[(windowOffset - copyDistance) & (window.count - 1)]
                emit(byte, into: buffer, at: written)
                written += 1
                copyRemaining -= 1
                continue
            }
            if try reader.readBit() != 0 {
                let literal = try literalTree.map { try $0.decode(&reader) } ?? reader.read(8)
                emit(UInt8(literal), into: buffer, at: written)
                written += 1
            } else {
                var distance = try reader.read(bigWindow ? 7 : 6)
                distance |= try distanceTree.decode(&reader) << (bigWindow ? 7 : 6)
                var length = try lengthTree.decode(&reader) + minimumMatch
                if length == 63 + minimumMatch { length += try reader.read(8) }
                copyDistance = distance + 1
                copyRemaining = length
            }
        }
        return written
    }
}
