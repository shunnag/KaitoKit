import Compression
import Foundation

// 参照仕様: RFC 7932 §9.1（stream header の WBITS）、RFC 9841 §6（large window の 14 bit 形）と
// §8.1（shared brotli framing の署名は WBITS の無効組合せ）、Apple Compression の streaming API
//（COMPRESSION_BROTLI は decode 対応）。brotli には magic も長さも checksum も無いため、
// 検出は拡張子と header の妥当性、末尾は decoder の END で判定する。
struct BrotliStreamHeader: Equatable {
    /// RFC 7932 の WBITS（10〜24）または RFC 9841 large window の WBITS（10〜62）。
    let windowBits: Int
    let isLargeWindow: Bool

    /// sliding window の大きさ `(1 << WBITS) - 16`。
    var windowSize: UInt64 { (UInt64(1) << UInt64(windowBits)) - 16 }

    /// 先頭 2 byte から WBITS を読む。bit は各 byte の LSB から順に並ぶ（RFC 7932 §1.5.1）。
    init(prefix: [UInt8]) throws {
        guard let first = prefix.first else { throw KaitoError.truncated }
        if first & 0x01 == 0 {
            windowBits = 16
            isLargeWindow = false
            return
        }
        let n = Int((first >> 1) & 0x07)
        if n != 0 {
            windowBits = 17 + n
            isLargeWindow = false
            return
        }
        let m = Int((first >> 4) & 0x07)
        switch m {
        case 0:
            windowBits = 17
            isLargeWindow = false
        case 1:
            // 00010001 は RFC 9841 の large window 指示。bit 7 が立つと WBITS としては無効で、
            // 0x91 0x0A 0x42 0x52 は shared brotli framing の署名（RFC 9841 §8.1）。
            guard first & 0x80 == 0 else {
                if prefix.count >= 4, Array(prefix[..<4]) == [0x91, 0x0A, 0x42, 0x52] {
                    throw KaitoError.unsupportedMethod("shared brotli framing stream")
                }
                throw KaitoError.malformed("brotli WBITS pattern is invalid")
            }
            guard prefix.count >= 2 else { throw KaitoError.truncated }
            let bits = Int(prefix[1] & 0x3F)
            guard (10...62).contains(bits) else {
                throw KaitoError.malformed("brotli large window WBITS is out of range")
            }
            windowBits = bits
            isLargeWindow = true
        default:
            windowBits = 8 + m
            isLargeWindow = false
        }
    }
}

/// Apple Compression に委ねる brotli の streaming decoder。単一 stream で、END の後に
/// 入力が残れば `malformed`。出力サイズと checksum は形式に無い。
final class BrotliDecompressor: Decompressor {
    static let chunkSize = 256 * 1_024

    private let source: any ByteSource
    private let compressedEnd: UInt64
    private var sourceOffset: UInt64
    private var input = [UInt8](repeating: 0, count: chunkSize)
    private var inputOffset = 0
    private var inputCount = 0
    private var stream = compression_stream(
        dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
        dst_size: 0,
        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
        src_size: 0,
        state: nil
    )
    private var streamWasInitialized = false
    private var finished = false

    /// 試し復号で確保を許す window の上限。これを超える window は header だけで形式を認め、
    /// 実際の確保は利用者が読むときに起こす。
    static let maximumProbeWindowSize: UInt64 = 16 * 1_024 * 1_024

    /// stream header を検証し、window を `limits.maxDictionarySize` と照合する。
    static func validateHeader(source: any ByteSource, offset: UInt64 = 0, limits: ReadLimits) throws -> BrotliStreamHeader {
        guard source.length > offset else { throw KaitoError.truncated }
        let count = try Checked.toInt(min(4, Checked.sub(source.length, offset)))
        let header = try BrotliStreamHeader(prefix: readByteRange(source: source, offset: offset, count: count))
        try Checked.size(header.windowSize, limit: limits.maxDictionarySize)
        return header
    }

    /// 検出用の試し復号。header の WBITS が有効で、先頭 64 KiB（またはそれ未満の全体）を
    /// Apple Compression が error なく消費できれば true。magic の無い形式を名前だけで受理しない。
    static func isPlausibleStream(source: any ByteSource, limits: ReadLimits) -> Bool {
        guard source.length > 0,
              let prefix = try? readByteRange(source: source, offset: 0, count: Int(min(4, source.length))),
              let header = try? BrotliStreamHeader(prefix: prefix) else { return false }
        // 大きな window は試し復号せずに形式だけ認める。辞書上限を超えるものは reader の open で
        // `limitExceeded` になり、上限内でも 16 MiB を超える window の確保は検出段階では起こさない。
        guard header.windowSize <= min(limits.maxDictionarySize, maximumProbeWindowSize) else { return true }
        let probeSize = Int(min(UInt64(64 * 1_024), source.length))
        guard let input = try? readByteRange(source: source, offset: 0, count: probeSize) else { return false }
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_BROTLI)
            != COMPRESSION_STATUS_ERROR else { return false }
        defer { compression_stream_destroy(&stream) }
        let outputCapacity = 64 * 1_024
        let output = UnsafeMutableRawBufferPointer.allocate(byteCount: outputCapacity, alignment: 1)
        defer { output.deallocate() }
        var consumedTotal = 0
        var iterations = 0
        // 全体が 64 KiB 以下なら FINALIZE を立て、切り詰めた stream を END で誤認しない。
        let flags = UInt64(probeSize) == source.length ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
        while consumedTotal < input.count, iterations < 64 {
            iterations += 1
            let status: compression_status = input.withUnsafeBytes { inputBytes in
                stream.src_ptr = inputBytes.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: consumedTotal)
                stream.src_size = input.count - consumedTotal
                stream.dst_ptr = output.baseAddress!.assumingMemoryBound(to: UInt8.self)
                stream.dst_size = outputCapacity
                defer {
                    stream.src_ptr = UnsafePointer<UInt8>(bitPattern: 1)!
                    stream.dst_ptr = UnsafeMutablePointer<UInt8>(bitPattern: 1)!
                }
                return compression_stream_process(&stream, flags)
            }
            let consumed = (input.count - consumedTotal) - stream.src_size
            let produced = outputCapacity - stream.dst_size
            consumedTotal += consumed
            switch status {
            case COMPRESSION_STATUS_END:
                // END の後に入力が残れば末尾ゴミなので stream として受理しない。
                return consumedTotal == input.count
            case COMPRESSION_STATUS_OK:
                if consumed == 0, produced == 0 { return false }
            default:
                return false
            }
        }
        return true
    }

    init(source: any ByteSource, offset: UInt64 = 0, compressedSize: UInt64? = nil,
         limits: ReadLimits) throws {
        let size = try compressedSize ?? Checked.sub(source.length, offset)
        let end = try Checked.add(offset, size)
        guard end <= source.length else { throw KaitoError.truncated }
        self.source = source
        self.compressedEnd = end
        self.sourceOffset = offset
        _ = try Self.validateHeader(source: source, offset: offset, limits: limits)
        let status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_BROTLI)
        guard status != COMPRESSION_STATUS_ERROR else {
            throw KaitoError.malformed("Compression could not initialize brotli decoding")
        }
        streamWasInitialized = true
    }

    deinit {
        if streamWasInitialized {
            compression_stream_destroy(&stream)
        }
    }

    var isFinished: Bool { finished }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !finished else { return 0 }
        let outputCapacity = min(buffer.count, Self.chunkSize)
        var totalProduced = 0

        while totalProduced < outputCapacity {
            if inputOffset == inputCount {
                try refillInput()
            }
            let availableInput = inputCount - inputOffset
            let inputExhausted = sourceOffset == compressedEnd
            // Apple の decoder は入力を全部消費してから出力を小分けに返すことがある。
            // 入力が尽きていても FINALIZE 付きで呼び続け、END が来るまで出力を引き出す。
            guard availableInput > 0 || inputExhausted else { throw KaitoError.truncated }
            let availableOutput = outputCapacity - totalProduced
            let flags = inputExhausted ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0

            let status: compression_status = try input.withUnsafeMutableBytes { inputBytes in
                guard let inputBase = inputBytes.baseAddress,
                      let outputBase = buffer.baseAddress else {
                    throw KaitoError.malformed("brotli buffer has no storage")
                }
                stream.src_ptr = UnsafePointer(
                    inputBase.assumingMemoryBound(to: UInt8.self).advanced(by: inputOffset)
                )
                stream.src_size = availableInput
                stream.dst_ptr = outputBase.assumingMemoryBound(to: UInt8.self).advanced(by: totalProduced)
                stream.dst_size = availableOutput
                defer {
                    stream.src_ptr = UnsafePointer<UInt8>(bitPattern: 1)!
                    stream.dst_ptr = UnsafeMutablePointer<UInt8>(bitPattern: 1)!
                }
                return compression_stream_process(&stream, flags)
            }

            guard stream.src_size <= availableInput,
                  stream.dst_size <= availableOutput else {
                throw KaitoError.malformed("Compression returned invalid brotli buffer accounting")
            }
            let consumed = availableInput - stream.src_size
            let produced = availableOutput - stream.dst_size
            inputOffset += consumed
            totalProduced += produced

            switch status {
            case COMPRESSION_STATUS_END:
                // brotli に連結や padding の規定は無い。END 時点で未消費の入力があれば末尾ゴミ。
                let consumedEnd = try Checked.sub(sourceOffset, UInt64(inputCount - inputOffset))
                guard consumedEnd == compressedEnd else {
                    throw KaitoError.malformed("brotli stream has trailing bytes")
                }
                finished = true
                return totalProduced

            case COMPRESSION_STATUS_OK:
                if totalProduced > 0 { return totalProduced }
                if consumed == 0 {
                    // 入力も出力も進まない: 入力が尽きていれば stream の途中で切れている。
                    throw inputExhausted ? KaitoError.truncated : KaitoError.malformed("brotli stream made no progress")
                }

            case COMPRESSION_STATUS_ERROR:
                // 切り詰められた stream では、Apple の decoder は最後の入力を OK で受け取った後、入力の無い
                // FINALIZE の呼び出しで ERROR を返す（黒箱で観察）。破損は入力が残っている呼び出しで
                // ERROR になるので、入力が尽きた後の空呼び出しでの ERROR だけを truncated とする。
                if availableInput == 0, inputExhausted {
                    throw KaitoError.truncated
                }
                throw KaitoError.malformed("invalid brotli stream")

            default:
                throw KaitoError.malformed("Compression returned an unknown brotli status")
            }
        }
        return totalProduced
    }

    private func refillInput() throws {
        guard sourceOffset < compressedEnd else {
            inputOffset = 0
            inputCount = 0
            return
        }
        let remaining = try Checked.sub(compressedEnd, sourceOffset)
        let requested = try Checked.toInt(min(UInt64(Self.chunkSize), remaining))
        let count = try input.withUnsafeMutableBytes { storage in
            // storage は chunkSize の固定領域で、先頭 requested byte だけを要求する。
            try source.read(into: UnsafeMutableRawBufferPointer(rebasing: storage[..<requested]), at: sourceOffset)
        }
        guard count > 0, count <= requested else { throw KaitoError.truncated }
        sourceOffset = try Checked.add(sourceOffset, UInt64(count))
        inputOffset = 0
        inputCount = count
    }
}
