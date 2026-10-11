import CryptoKit
import Foundation

// 参照仕様: https://tukaani.org/xz/xz-file-format.txt と LZMA SDK の公開ドメイン文書。
// Apple Compression の内部実装や liblzma のソースは参照していない。

/// XZ block check の累積器。stream flags の check 種別ごとに一つ持つ。
enum XZBlockCheck {
    case none
    case crc32(CRC32)
    case crc64(CRC64)
    case sha256(SHA256)

    /// 予約された check 種別（2, 3, 5...9, 11...15）は nil。その stream は native decoder に渡す。
    init?(type: UInt8) {
        switch type {
        case 0: self = .none
        case 1: self = .crc32(CRC32())
        case 4: self = .crc64(CRC64())
        case 10: self = .sha256(SHA256())
        default: return nil
        }
    }

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        switch self {
        case .none: break
        case .crc32(var crc): crc.update(bytes); self = .crc32(crc)
        case .crc64(var crc): crc.update(bytes); self = .crc64(crc)
        case .sha256(var hash): hash.update(bufferPointer: bytes); self = .sha256(hash)
        }
    }

    /// block 末尾に格納された check と一致するかどうか。
    func matches(_ stored: [UInt8]) -> Bool {
        switch self {
        case .none: return stored.isEmpty
        case .crc32(let crc): return stored.count == 4 && LittleEndian.uint32(stored, at: 0) == crc.value
        case .crc64(let crc): return stored.count == 8 && LittleEndian.uint64(stored, at: 0) == crc.value
        case .sha256(let hash): return stored.count == 32 && Array(hash.finalize()) == stored
        }
    }
}

/// 検証済みの XZ 配置を KaitoKit 自身の LZMA2 decoder で直列に復号する。
///
/// 出力は Apple Compression 経路（`XZDecompressor`）と byte 単位で同じになる。壊れた入力への
/// 振る舞いも同じにするため、復号済みの出力を `holdback` byte 分だけ保留してから返し、
/// 自分の decoder が失敗したら Compression 経路を先頭から再生して、そこまでに返した byte の
/// 続きとその経路のエラーをそのまま呼出元に渡す。Compression 経路は一回の read で最大
/// `holdback` byte しか返さないので、再生経路が失敗する read の開始位置は、こちらが
/// 失敗を見つけた位置から `holdback` 以上手前にはならない。こちらの検出位置が Compression
/// 経路より遅くならないこと（同じ復号規則の違反を同じ symbol か、それより前で検出する）が前提。
///
/// 失敗は latch する。read が throw した後は同じエラーを投げ続ける。
final class XZNativeDecompressor: Decompressor {
    /// Compression 経路の一回の read の出力上限。再生の正しさはこの等式に依る。
    static let holdback = XZDecompressor.chunkSize
    private static let pieceSize = XZDecompressor.chunkSize
    /// 一回の read 分 + 保留分 + 復号中の一片が常に収まる。
    private static let ringCapacity = 3 * holdback

    private let source: any ByteSource
    private let limits: ReadLimits
    private let recorder: CompressedTarMapRecorder?
    private let layout: XZStreamLayout
    private let diagnostics: ParallelXZDecompressor.Diagnostics?

    private var streamIndex = 0
    private var blockIndex = 0
    private var block: LZMA2Decoder?
    private var check = XZBlockCheck.none
    private var ring: UnsafeMutableRawBufferPointer?
    private var decoded: UInt64 = 0
    private var delivered: UInt64 = 0
    private var decodingFinished = false

    private var replay: XZDecompressor?
    private var replayQueue: [UInt8] = []
    private var replayQueueOffset = 0
    private var replaySkip: UInt64 = 0
    private var replayFinished = false
    private var terminalError: (any Error)?

    /// 全 block が LZMA2 だけの filter chain で、check 種別が既知の stream だけを native で復号する。
    /// 前置 filter と予約 check は Compression 経路に任せる。
    static func isEligible(_ layout: XZStreamLayout) -> Bool {
        layout.streams.allSatisfy { stream in
            XZBlockCheck(type: stream.checkType) != nil && stream.blocks.allSatisfy { $0.filterCount == 1 }
        }
    }

    /// - Parameters:
    ///   - layout: `XZResourceValidator.validate` が返した、source 全体の配置。
    ///   - recorder: tar 配置の記録先。block ごとに圧縮 byte を再読して渡す。
    init(source: any ByteSource, layout: XZStreamLayout, limits: ReadLimits,
         recorder: CompressedTarMapRecorder? = nil, diagnostics: ParallelXZDecompressor.Diagnostics? = nil) {
        self.source = source
        self.layout = layout
        self.limits = limits
        self.recorder = recorder
        self.diagnostics = diagnostics
    }

    deinit {
        ring?.deallocate()
    }

    var isFinished: Bool {
        if replay != nil { return replayFinished && replayQueueOffset == replayQueue.count }
        return decodingFinished && delivered == decoded
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if let terminalError { throw terminalError }
        guard !buffer.isEmpty else { return 0 }
        do {
            if replay != nil { return try serveReplay(into: buffer) }
            // Compression 経路と同じく、一回の read で返すのは最大 256 KiB。
            let wanted = min(buffer.count, Self.holdback)
            do {
                while !decodingFinished, deliverableCount < wanted {
                    try Task.checkCancellation()
                    try decodePiece()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 自分の decoder の失敗は、Compression 経路の結果に置き換える。
                try beginReplay()
                return try serveReplay(into: buffer)
            }
            let count = min(wanted, deliverableCount)
            if count > 0 {
                copyFromRing(to: buffer.baseAddress!, count: count)
                delivered += UInt64(count)
            }
            if isFinished { releaseRing() }
            return count
        } catch {
            terminalError = error
            releaseRing()
            replay = nil
            block = nil
            throw error
        }
    }

    // MARK: - native 復号

    private var deliverableCount: Int {
        let pending = Int(decoded - delivered)
        return decodingFinished ? pending : max(0, pending - Self.holdback)
    }

    private func decodePiece() throws {
        if block == nil {
            try beginNextBlock()
            if decodingFinished { return }
        }
        let ring = try ensureRing()
        let writePosition = Int(decoded % UInt64(Self.ringCapacity))
        let room = min(Self.pieceSize, Self.ringCapacity - writePosition)
        let destination = UnsafeMutableRawBufferPointer(rebasing: ring[writePosition..<(writePosition + room)])
        let count = try block!.read(into: destination)
        guard count >= 0, count <= room else {
            throw KaitoError.malformed("LZMA2 decoder returned an invalid byte count")
        }
        if count > 0 {
            check.update(UnsafeRawBufferPointer(rebasing: destination[..<count]))
            decoded += UInt64(count)
        }
        if block!.isFinished {
            try finishBlock()
        } else if count == 0 {
            throw KaitoError.malformed("XZ block made no progress")
        }
    }

    private func beginNextBlock() throws {
        while true {
            guard streamIndex < layout.streams.count else {
                decodingFinished = true
                return
            }
            let stream = layout.streams[streamIndex]
            guard blockIndex < stream.blocks.count else {
                try Self.verifyIndex(source: source, range: stream.indexRange)
                streamIndex += 1
                blockIndex = 0
                continue
            }
            let next = stream.blocks[blockIndex]
            guard let check = XZBlockCheck(type: stream.checkType) else {
                throw KaitoError.unsupportedMethod("XZ check type \(stream.checkType)")
            }
            self.check = check
            block = try Self.makeBlockDecoder(next, source: source, limits: limits)
            return
        }
    }

    private func finishBlock() throws {
        let stream = layout.streams[streamIndex]
        let current = stream.blocks[blockIndex]
        try Self.verifyCheck(check, block: current, stream: stream, source: source)
        if let recorder, recorder.isRecording {
            try Self.record(current, source: source, recorder: recorder)
        }
        block = nil
        blockIndex += 1
    }

    private func ensureRing() throws -> UnsafeMutableRawBufferPointer {
        if let ring { return ring }
        let allocated = UnsafeMutableRawBufferPointer.allocate(
            byteCount: Self.ringCapacity, alignment: MemoryLayout<UInt64>.alignment)
        ring = allocated
        return allocated
    }

    private func releaseRing() {
        ring?.deallocate()
        ring = nil
    }

    private func copyFromRing(to destination: UnsafeMutableRawPointer, count: Int) {
        guard let ring, count > 0 else { return }
        let start = Int(delivered % UInt64(Self.ringCapacity))
        let first = min(count, Self.ringCapacity - start)
        destination.copyMemory(from: ring.baseAddress!.advanced(by: start), byteCount: first)
        if first < count {
            destination.advanced(by: first).copyMemory(from: ring.baseAddress!, byteCount: count - first)
        }
    }

    // MARK: - Compression 経路の再生

    private func beginReplay() throws {
        releaseRing()
        block = nil
        replaySkip = delivered
        diagnostics?.replayedWithCompression()
        replay = try XZDecompressor(source: source, limits: limits)
    }

    private func serveReplay(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard let replay else { return 0 }
        while replayQueueOffset == replayQueue.count {
            guard !replayFinished else { return 0 }
            // 呼出元と同じ大きさで Compression 経路を進める。返る byte 数の区切りがそろい、
            // 失敗する read で捨てられる byte も同じになる。
            if replayQueue.count < buffer.count {
                replayQueue = [UInt8](repeating: 0, count: buffer.count)
            }
            replayQueueOffset = 0
            let count = try replayQueue.withUnsafeMutableBytes { storage in
                try replay.read(into: UnsafeMutableRawBufferPointer(rebasing: storage[..<buffer.count]))
            }
            guard count >= 0, count <= buffer.count else {
                throw KaitoError.malformed("Compression returned an invalid XZ byte count")
            }
            if count == 0 {
                replayFinished = true
                replayQueue.removeAll()
                return 0
            }
            if replay.isFinished { replayFinished = true }
            let skip = Int(min(replaySkip, UInt64(count)))
            replaySkip -= UInt64(skip)
            replayQueueOffset = skip
            replayQueue.removeSubrange(count...)
        }
        let available = replayQueue.count - replayQueueOffset
        let count = min(buffer.count, available)
        replayQueue.withUnsafeBytes { bytes in
            buffer.baseAddress!.copyMemory(from: bytes.baseAddress!.advanced(by: replayQueueOffset), byteCount: count)
        }
        replayQueueOffset += count
        return count
    }

    // MARK: - block 単位の補助（並列 job も使う）

    static func makeBlockDecoder(_ block: XZStreamLayout.Block, source: any ByteSource,
                                 limits: ReadLimits) throws -> LZMA2Decoder {
        try LZMA2Decoder(
            source: source,
            offset: block.payloadOffset,
            compressedSize: block.payloadSize,
            properties: [block.dictionaryProperty],
            expectedSize: block.outputSize,
            dictionarySizeLimit: limits.maxDictionarySize
        )
    }

    static func verifyCheck(_ check: XZBlockCheck, block: XZStreamLayout.Block,
                            stream: XZStreamLayout.Stream, source: any ByteSource) throws {
        let checkOffset = try Checked.sub(block.compressedRange.upperBound, stream.checkSize)
        let stored = try readByteRange(source: source, offset: checkOffset, count: Checked.toInt(stream.checkSize))
        guard check.matches(stored) else {
            throw KaitoError.malformed("XZ block check mismatch")
        }
    }

    static func verifyIndex(source: any ByteSource, range: Range<UInt64>, isAbandoned: () -> Bool = { false }) throws {
        let end = try Checked.sub(range.upperBound, 4)
        var offset = range.lowerBound, crc = CRC32()
        while offset < end {
            if isAbandoned() { throw CancellationError() }
            let count = try Checked.toInt(min(UInt64(pieceSize), end - offset))
            crc.update(try readByteRange(source: source, offset: offset, count: count))
            offset = try Checked.add(offset, UInt64(count))
        }
        let bytes = try readByteRange(source: source, offset: end, count: 4)
        guard crc.value == LittleEndian.uint32(bytes, at: 0) else {
            throw KaitoError.malformed("XZ Index checksum mismatch")
        }
    }

    static func record(_ block: XZStreamLayout.Block, source: any ByteSource,
                       recorder: CompressedTarMapRecorder) throws {
        let range = block.compressedRange
        var offset = range.lowerBound
        while offset < range.upperBound {
            let count = try Checked.toInt(min(UInt64(pieceSize), range.upperBound - offset))
            let bytes = try readByteRange(source: source, offset: offset, count: count)
            bytes.withUnsafeBytes { recorder.consumeXZ($0, at: offset) }
            offset += UInt64(count)
        }
    }

    /// 連続する block を一つの buffer に復号し、block ごとの check を検める。並列 job が使う。
    /// 出力が `destination` に収まらない、または足りないときは malformed。
    static func decodeBlocks(_ blocks: ArraySlice<XZStreamLayout.Block>, stream: XZStreamLayout.Stream,
                             source: any ByteSource, limits: ReadLimits,
                             into destination: UnsafeMutableRawBufferPointer,
                             pieceSize: Int = pieceSize, isAbandoned: () -> Bool) throws {
        var total = 0
        // 出力が destination を満たした後も end control を読むため、1 byte の余白へ読む。
        var spare: UInt8 = 0
        for block in blocks {
            guard var check = XZBlockCheck(type: stream.checkType) else {
                throw KaitoError.unsupportedMethod("XZ check type \(stream.checkType)")
            }
            let decoder = try makeBlockDecoder(block, source: source, limits: limits)
            while !decoder.isFinished {
                if isAbandoned() { throw CancellationError() }
                guard total < destination.count else {
                    let produced = try withUnsafeMutableBytes(of: &spare) { try decoder.read(into: $0) }
                    guard produced == 0, decoder.isFinished else {
                        throw KaitoError.malformed("XZ job output size mismatch")
                    }
                    break
                }
                let count = min(pieceSize, destination.count - total)
                let piece = UnsafeMutableRawBufferPointer(rebasing: destination[total..<(total + count)])
                let produced = try decoder.read(into: piece)
                guard produced >= 0, produced <= count else {
                    throw KaitoError.malformed("LZMA2 decoder returned an invalid byte count")
                }
                guard produced > 0 || decoder.isFinished else {
                    throw KaitoError.malformed("XZ block made no progress")
                }
                check.update(UnsafeRawBufferPointer(rebasing: piece[..<produced]))
                total += produced
            }
            try verifyCheck(check, block: block, stream: stream, source: source)
        }
        guard total == destination.count else {
            throw KaitoError.malformed("XZ job output size mismatch")
        }
    }
}
