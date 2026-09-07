import Foundation

struct SevenZipPackRange: Sendable, Equatable {
    let offset: UInt64
    let size: UInt64
    let digest: SevenZipDigest
}

private struct SevenZipVerifiedPackKey: Hashable {
    let offset: UInt64
    let size: UInt64
    let crc32: UInt32
}

// PackInfo CRC は entry を初めて読む時に固定長 buffer で検証し、reader 内で共有する。
// 巨大 packed stream を open 時に走査せず、同じ range の再検証も避ける。
final class SevenZipPackedStreamVerifier {
    private static let bufferSize = 256 * 1_024

    private let source: any ByteSource
    private var verified = Set<SevenZipVerifiedPackKey>()

    init(source: any ByteSource) {
        self.source = source
    }

    func verify(_ ranges: [Int: SevenZipPackRange]) throws {
        for range in ranges.values {
            guard let expected = range.digest.value else { continue }
            let key = SevenZipVerifiedPackKey(
                offset: range.offset,
                size: range.size,
                crc32: expected
            )
            if verified.contains(key) { continue }

            var checksum = CRC32()
            var position: UInt64 = 0
            var buffer = [UInt8](repeating: 0, count: Self.bufferSize)
            while position < range.size {
                let requested = try Checked.toInt(min(
                    UInt64(buffer.count),
                    try Checked.sub(range.size, position)
                ))
                let absoluteOffset = try Checked.add(range.offset, position)
                let count = try buffer.withUnsafeMutableBytes { storage in
                    // requested は固定 buffer と packed range 残量の双方以下。
                    try source.read(
                        into: UnsafeMutableRawBufferPointer(rebasing: storage[..<requested]),
                        at: absoluteOffset
                    )
                }
                guard count > 0, count <= requested else { throw KaitoError.truncated }
                buffer.withUnsafeBytes { storage in
                    // count は直前の read で初期化された storage 範囲内。
                    checksum.update(UnsafeRawBufferPointer(rebasing: storage[..<count]))
                }
                position = try Checked.add(position, UInt64(count))
            }
            guard checksum.value == expected else {
                throw KaitoError.checksumMismatch(entry: -1)
            }
            verified.insert(key)
        }
    }
}

enum SevenZipFolderLayout {
    static func ranges(
        for streams: SevenZipStreamsInfo,
        sourceLength: UInt64,
        packedDataEnd: UInt64
    ) throws -> [[Int: SevenZipPackRange]] {
        var absoluteOffset = try Checked.add(32, streams.packInfo.position)
        var packIndex = 0
        var result: [[Int: SevenZipPackRange]] = []
        result.reserveCapacity(streams.folders.count)

        for folder in streams.folders {
            var folderRanges: [Int: SevenZipPackRange] = [:]
            for inputIndex in folder.packedIndices {
                guard packIndex < streams.packInfo.sizes.count else {
                    throw KaitoError.malformed("missing 7z packed stream")
                }
                let size = streams.packInfo.sizes[packIndex]
                let end = try Checked.add(absoluteOffset, size)
                guard end <= sourceLength else { throw KaitoError.truncated }
                guard absoluteOffset <= packedDataEnd, end <= packedDataEnd else {
                    throw KaitoError.malformed("7z packed stream overlaps the next header")
                }
                let digest = packIndex < streams.packInfo.digests.count
                    ? streams.packInfo.digests[packIndex]
                    : SevenZipDigest(value: nil)
                folderRanges[inputIndex] = SevenZipPackRange(
                    offset: absoluteOffset,
                    size: size,
                    digest: digest
                )
                absoluteOffset = end
                packIndex += 1
            }
            result.append(folderRanges)
        }
        guard packIndex == streams.packInfo.sizes.count else {
            throw KaitoError.malformed("unused 7z packed streams")
        }
        return result
    }
}

private struct SevenZipByteInput {
    let source: any ByteSource
    let offset: UInt64
    let length: UInt64
}

private enum SevenZipPipelineValue {
    case bytes(SevenZipByteInput)
    case stream(any Decompressor)

    func asStream() throws -> any Decompressor {
        switch self {
        case let .bytes(input):
            return try CopyDecompressor(
                source: input.source,
                offset: input.offset,
                compressedSize: input.length
            )
        case let .stream(stream):
            return stream
        }
    }

    func asBytes(method: String) throws -> SevenZipByteInput {
        guard case let .bytes(input) = self else {
            throw KaitoError.unsupportedMethod("7z \(method) after a streaming coder")
        }
        return input
    }
}

final class SevenZipFolderDecoderFactory {
    let folder: SevenZipFolder
    let isEncrypted: Bool
    let finalSize: UInt64

    private let source: any ByteSource
    private let packedRanges: [Int: SevenZipPackRange]
    private let limits: ReadLimits
    private let password: String?
    private let keyCache: SevenZipAESKeyCache
    private let packedStreamVerifier: SevenZipPackedStreamVerifier
    private let maximumAESCyclesPower: UInt8

    init(
        source: any ByteSource,
        folder: SevenZipFolder,
        packedRanges: [Int: SevenZipPackRange],
        limits: ReadLimits,
        password: String?,
        keyCache: SevenZipAESKeyCache,
        maximumAESCyclesPower: UInt8,
        packedStreamVerifier: SevenZipPackedStreamVerifier? = nil
    ) throws {
        guard folder.unpackSizes.count == folder.outputCount,
              folder.finalOutputIndex >= 0,
              folder.finalOutputIndex < folder.unpackSizes.count else {
            throw KaitoError.malformed("7z folder output sizes are incomplete")
        }
        self.source = source
        self.folder = folder
        self.packedRanges = packedRanges
        self.limits = limits
        self.password = password
        self.keyCache = keyCache
        self.packedStreamVerifier = packedStreamVerifier
            ?? SevenZipPackedStreamVerifier(source: source)
        self.maximumAESCyclesPower = maximumAESCyclesPower
        self.finalSize = folder.unpackSizes[folder.finalOutputIndex]
        self.isEncrypted = folder.coders.contains { SevenZipMethod.kind(for: $0.methodID) == .aes }
    }

    func makeDecoder() throws -> any Decompressor {
        var activeOutputs = Set<Int>()

        func inputSize(_ inputIndex: Int) throws -> UInt64 {
            if let bound = folder.boundOutput(forInput: inputIndex) {
                guard folder.unpackSizes.indices.contains(bound) else {
                    throw KaitoError.malformed("7z bound output size is missing")
                }
                return folder.unpackSizes[bound]
            }
            guard let range = packedRanges[inputIndex] else {
                throw KaitoError.malformed("7z packed input size is missing")
            }
            return range.size
        }

        func inputValue(_ inputIndex: Int) throws -> SevenZipPipelineValue {
            if let bound = folder.boundOutput(forInput: inputIndex) {
                return try outputValue(bound)
            }
            guard let range = packedRanges[inputIndex] else {
                throw KaitoError.malformed("7z coder input is neither bound nor packed")
            }
            return .bytes(SevenZipByteInput(
                source: source,
                offset: range.offset,
                length: range.size
            ))
        }

        func outputValue(_ outputIndex: Int) throws -> SevenZipPipelineValue {
            guard activeOutputs.insert(outputIndex).inserted else {
                throw KaitoError.malformed("cyclic 7z coder graph")
            }
            defer { activeOutputs.remove(outputIndex) }
            guard let coderIndex = folder.coderIndex(containingOutput: outputIndex) else {
                throw KaitoError.malformed("7z output does not belong to a coder")
            }
            let coder = folder.coders[coderIndex]
            guard coder.outputCount == 1, outputIndex == coder.firstOutput else {
                throw KaitoError.unsupportedMethod("multi-output 7z coder")
            }
            let expectedSize = folder.unpackSizes[outputIndex]
            let kind = SevenZipMethod.kind(for: coder.methodID)

            switch kind {
            case .copy:
                try requireArity(coder, inputs: 1)
                guard try inputSize(coder.firstInput) == expectedSize else {
                    throw KaitoError.malformed("7z Copy input and output sizes differ")
                }
                return .stream(try inputValue(coder.firstInput).asStream())

            case .lzma:
                try requireArity(coder, inputs: 1)
                let input = try inputValue(coder.firstInput).asBytes(method: "LZMA")
                return .stream(try LZMADecoder(
                    source: input.source,
                    offset: input.offset,
                    compressedSize: input.length,
                    properties: coder.properties,
                    expectedSize: expectedSize,
                    dictionarySizeLimit: limits.maxDictionarySize
                ))

            case .lzma2:
                try requireArity(coder, inputs: 1)
                let input = try inputValue(coder.firstInput).asBytes(method: "LZMA2")
                return .stream(try LZMA2Decoder(
                    source: input.source,
                    offset: input.offset,
                    compressedSize: input.length,
                    properties: coder.properties,
                    expectedSize: expectedSize,
                    dictionarySizeLimit: limits.maxDictionarySize
                ))

            case .ppmd7:
                try requireArity(coder, inputs: 1)
                let input = try inputValue(coder.firstInput).asBytes(method: "PPMd7")
                return .stream(try PPMd7Decoder(
                    source: input.source,
                    offset: input.offset,
                    compressedSize: input.length,
                    properties: coder.properties,
                    expectedSize: expectedSize,
                    memorySizeLimit: limits.maxDictionarySize
                ))

            case .deflate:
                try requireArity(coder, inputs: 1)
                guard coder.properties.isEmpty else {
                    throw KaitoError.malformed("7z Deflate has unexpected properties")
                }
                let input = try inputValue(coder.firstInput).asBytes(method: "Deflate")
                return .stream(try DeflateDecompressor(
                    source: input.source,
                    offset: input.offset,
                    compressedSize: input.length
                ))

            case .bzip2:
                try requireArity(coder, inputs: 1)
                guard coder.properties.isEmpty else {
                    throw KaitoError.malformed("7z BZip2 has unexpected properties")
                }
                let input = try inputValue(coder.firstInput).asBytes(method: "BZip2")
                return .stream(try Bzip2Decompressor(
                    source: input.source,
                    offset: input.offset,
                    compressedSize: input.length
                ))

            case .aes:
                try requireArity(coder, inputs: 1)
                let input = try inputValue(coder.firstInput).asBytes(method: "AES")
                guard let password else { throw KaitoError.passwordRequired }
                let properties = try SevenZipAESProperties(
                    bytes: coder.properties,
                    maximumCyclesPower: maximumAESCyclesPower
                )
                let key = try keyCache.key(password: password, properties: properties)
                let decrypted = try SevenZipAESByteSource(
                    source: input.source,
                    ciphertextOffset: input.offset,
                    ciphertextSize: input.length,
                    plaintextSize: expectedSize,
                    key: key,
                    initializationVector: properties.initializationVector
                )
                return .bytes(SevenZipByteInput(
                    source: decrypted,
                    offset: 0,
                    length: decrypted.length
                ))

            case .delta:
                try requireArity(coder, inputs: 1)
                guard coder.properties.count == 1 else {
                    throw KaitoError.malformed("7z Delta properties must contain one byte")
                }
                guard try inputSize(coder.firstInput) == expectedSize else {
                    throw KaitoError.malformed("7z Delta input and output sizes differ")
                }
                let distance = Int(coder.properties[0]) + 1
                return .stream(try DeltaFilterDecompressor(
                    input: inputValue(coder.firstInput).asStream(),
                    distance: distance,
                    expectedSize: expectedSize
                ))

            case let .branch(filter):
                try requireArity(coder, inputs: 1)
                guard try inputSize(coder.firstInput) == expectedSize else {
                    throw KaitoError.malformed("7z BCJ input and output sizes differ")
                }
                let startOffset = try branchStartOffset(coder.properties)
                return .stream(try BCJFilterDecompressor(
                    input: inputValue(coder.firstInput).asStream(),
                    filter: filter,
                    startOffset: startOffset,
                    expectedSize: expectedSize
                ))

            case .bcj2:
                guard coder.inputCount == 4, coder.outputCount == 1,
                      coder.properties.isEmpty else {
                    throw KaitoError.malformed("invalid 7z BCJ2 coder structure")
                }
                return .stream(try BCJ2Decompressor(
                    main: inputValue(coder.firstInput).asStream(),
                    call: inputValue(coder.firstInput + 1).asStream(),
                    jump: inputValue(coder.firstInput + 2).asStream(),
                    range: inputValue(coder.firstInput + 3).asStream(),
                    expectedSize: expectedSize
                ))

            case let .unsupported(name):
                throw KaitoError.unsupportedMethod(name)
            }
        }

        // PackInfo CRC は暗号化前の packed byte を対象とし、password と無関係。
        // ここで検証してから、復号・coder 由来の失敗だけを password error に変換する。
        try packedStreamVerifier.verify(packedRanges)
        do {
            return try outputValue(folder.finalOutputIndex).asStream()
        } catch {
            throw translateEncryptedError(error)
        }
    }

    // filter/AES を挟まない単一 LZMA2 folder だけは、chunk の辞書 reset から
    // 安全に再開できる。複合 graph は filter state も必要なので先頭へ戻す。
    func makeDictionaryResetIndex() throws -> [LZMA2ResetPoint]? {
        guard folder.coders.count == 1,
              let coder = folder.coders.first,
              SevenZipMethod.kind(for: coder.methodID) == .lzma2,
              coder.inputCount == 1,
              coder.outputCount == 1,
              coder.properties.count == 1,
              let range = packedRanges[coder.firstInput] else {
            return nil
        }
        return try LZMA2Decoder.makeDictionaryResetIndex(
            source: source,
            offset: range.offset,
            compressedSize: range.size,
            expectedSize: finalSize,
            maximumPointCount: min(
                limits.maxMetadataRecordCount,
                try Checked.toInt(min(
                    limits.maxTotalMetadataSize
                        / UInt64(MemoryLayout<LZMA2ResetPoint>.stride),
                    UInt64(Int.max)
                ))
            )
        )
    }

    func makeDecoder(restartingAt point: LZMA2ResetPoint) throws -> (any Decompressor)? {
        guard folder.coders.count == 1,
              let coder = folder.coders.first,
              SevenZipMethod.kind(for: coder.methodID) == .lzma2,
              coder.inputCount == 1,
              coder.outputCount == 1,
              coder.properties.count == 1,
              let range = packedRanges[coder.firstInput],
              point.uncompressedOffset <= finalSize else {
            return nil
        }
        let remaining = try Checked.sub(finalSize, point.uncompressedOffset)
        return try LZMA2Decoder(
            source: source,
            originalOffset: range.offset,
            originalCompressedSize: range.size,
            properties: coder.properties,
            restartingAt: point,
            expectedSize: remaining,
            dictionarySizeLimit: limits.maxDictionarySize
        )
    }

    func decodeAll(limit: UInt64) throws -> Data {
        try Checked.size(finalSize, limit: limit)
        let count = try Checked.toInt(finalSize)
        var result = Data(count: count)
        let decoder: any Decompressor
        do {
            decoder = try makeDecoder()
        } catch {
            throw translateEncryptedError(error)
        }
        var written = 0
        do {
            try result.withUnsafeMutableBytes { storage in
                while written < count {
                    let destination = UnsafeMutableRawBufferPointer(
                        rebasing: storage[written..<count]
                    )
                    let actual = try decoder.read(into: destination)
                    guard actual > 0, actual <= destination.count else {
                        throw KaitoError.truncated
                    }
                    written += actual
                }
            }
            if !decoder.isFinished {
                var extra: UInt8 = 0
                let count = try withUnsafeMutableBytes(of: &extra) {
                    try decoder.read(into: $0)
                }
                guard count == 0, decoder.isFinished else {
                    throw KaitoError.malformed("7z folder output exceeds its declared size")
                }
            }
            if let expected = folder.digest.value,
               CRC32.checksum(result) != expected {
                throw KaitoError.checksumMismatch(entry: -1)
            }
            return result
        } catch {
            throw translateEncryptedError(error)
        }
    }

    func translateEncryptedError(_ error: Error) -> Error {
        guard isEncrypted else { return error }
        if let kaito = error as? KaitoError {
            switch kaito {
            case .passwordRequired, .wrongPassword, .limitExceeded, .unsupportedMethod:
                return kaito
            case .malformed, .truncated, .checksumMismatch:
                return KaitoError.wrongPassword
            default:
                return kaito
            }
        }
        return error
    }

    private func requireArity(
        _ coder: SevenZipCoder,
        inputs: Int
    ) throws {
        guard coder.inputCount == inputs, coder.outputCount == 1 else {
            throw KaitoError.malformed("invalid 7z coder stream arity")
        }
    }

    private func branchStartOffset(_ properties: [UInt8]) throws -> UInt64 {
        if properties.isEmpty { return 0 }
        guard properties.count == 4 else {
            throw KaitoError.malformed("7z BCJ properties must be empty or four bytes")
        }
        return UInt64(properties[0])
            | UInt64(properties[1]) << 8
            | UInt64(properties[2]) << 16
            | UInt64(properties[3]) << 24
    }
}

enum SevenZipMethodKind: Equatable {
    case copy
    case lzma
    case lzma2
    case ppmd7
    case deflate
    case bzip2
    case aes
    case delta
    case branch(SevenZipBranchFilter)
    case bcj2
    case unsupported(String)
}

enum SevenZipMethod {
    static func kind(for id: [UInt8]) -> SevenZipMethodKind {
        switch id {
        case [0x00]: return .copy
        case [0x21]: return .lzma2
        case [0x03, 0x01, 0x01]: return .lzma
        case [0x03, 0x04, 0x01]: return .ppmd7
        case [0x04, 0x01, 0x08]: return .deflate
        case [0x04, 0x02, 0x02]: return .bzip2
        case [0x06, 0xF1, 0x07, 0x01]: return .aes
        case [0x03]: return .delta
        case [0x04], [0x03, 0x03, 0x01, 0x03]: return .branch(.x86)
        case [0x05], [0x03, 0x03, 0x02, 0x05]: return .branch(.powerPC)
        case [0x07], [0x03, 0x03, 0x05, 0x01]: return .branch(.arm)
        case [0x08], [0x03, 0x03, 0x07, 0x01]: return .branch(.armThumb)
        case [0x0A]: return .branch(.arm64)
        case [0x03, 0x03, 0x01, 0x1B]: return .bcj2
        case [0x06], [0x03, 0x03, 0x04, 0x01]:
            return .unsupported("7z IA64 filter")
        case [0x09], [0x03, 0x03, 0x08, 0x05]:
            return .unsupported("7z SPARC filter")
        default:
            let text = id.map { String(format: "%02X", $0) }.joined()
            return .unsupported("7z method 0x\(text)")
        }
    }

    static func description(for coder: SevenZipCoder) -> String {
        switch kind(for: coder.methodID) {
        case .copy: return "Copy"
        case .lzma: return "LZMA"
        case .lzma2: return "LZMA2"
        case .ppmd7: return "PPMd7"
        case .deflate: return "Deflate"
        case .bzip2: return "BZip2"
        case .aes: return "7zAES-256"
        case .delta:
            return coder.properties.count == 1
                ? "Delta:\(Int(coder.properties[0]) + 1)"
                : "Delta"
        case let .branch(filter):
            switch filter {
            case .x86: return "BCJ"
            case .arm: return "ARM"
            case .armThumb: return "ARMT"
            case .arm64: return "ARM64"
            case .powerPC: return "PPC"
            }
        case .bcj2: return "BCJ2"
        case let .unsupported(name): return name
        }
    }
}

final class SevenZipFolderCoordinator {
    private let factory: SevenZipFolderDecoderFactory
    private var decoder: (any Decompressor)?
    private var position: UInt64 = 0
    private var generation: UInt64 = 0
    private var checksum = CRC32()
    private var completionVerified = false
    private var resetIndex: [LZMA2ResetPoint]?
    private var resetIndexWasBuilt = false
    private var checksumCoversWholeFolder = true

    init(factory: SevenZipFolderDecoderFactory) {
        self.factory = factory
    }

    var hasRetainedDecoderState: Bool { decoder != nil }

    func stream(offset: UInt64, length: UInt64) throws -> any Decompressor {
        let end = try Checked.add(offset, length)
        guard end <= factory.finalSize else {
            throw KaitoError.malformed("7z substream exceeds its folder")
        }
        generation = try Checked.add(generation, 1)
        if decoder == nil {
            if completionVerified, offset < position {
                try restartForBackwardSeek(target: offset)
            } else if !completionVerified {
                try restart()
            }
        } else if offset < position {
            try restartForBackwardSeek(target: offset)
        }
        if position < offset {
            try discard(until: offset)
        }
        if length == 0, end == factory.finalSize {
            // 末尾の空 substream は EntryStream から read が呼ばれないため、
            // ここで folder の終端と CRC を確定する。
            try verifyCompletion()
        }
        return SevenZipFolderRangeDecompressor(
            coordinator: self,
            generation: generation,
            length: length,
            endsFolder: end == factory.finalSize
        )
    }

    fileprivate func read(
        generation expectedGeneration: UInt64,
        remaining: inout UInt64,
        endsFolder: Bool,
        into buffer: UnsafeMutableRawBufferPointer
    ) throws -> Int {
        guard expectedGeneration == generation else {
            throw KaitoError.malformed("a newer 7z folder stream invalidated this stream")
        }
        guard remaining > 0, !buffer.isEmpty else {
            if remaining == 0, endsFolder { try verifyCompletion() }
            return 0
        }
        let requested = try Checked.toInt(min(UInt64(buffer.count), remaining))
        guard let decoder else { throw KaitoError.malformed("7z folder decoder is unavailable") }
        do {
            let destination = UnsafeMutableRawBufferPointer(rebasing: buffer[..<requested])
            let actual = try decoder.read(into: destination)
            guard actual > 0, actual <= requested else { throw KaitoError.truncated }
            position = try Checked.add(position, UInt64(actual))
            remaining = try Checked.sub(remaining, UInt64(actual))
            checksum.update(UnsafeRawBufferPointer(rebasing: destination[..<actual]))
            if remaining == 0, endsFolder { try verifyCompletion() }
            return actual
        } catch {
            throw factory.translateEncryptedError(error)
        }
    }

    private func restart() throws {
        do {
            decoder = try factory.makeDecoder()
            position = 0
            checksum = CRC32()
            completionVerified = false
            checksumCoversWholeFolder = true
        } catch {
            throw factory.translateEncryptedError(error)
        }
    }

    private func restartForBackwardSeek(target: UInt64) throws {
        do {
            if !resetIndexWasBuilt {
                do {
                    resetIndex = try factory.makeDictionaryResetIndex()
                } catch KaitoError.limitExceeded {
                    // index は seek 最適化なので、上限超過時は安全な先頭再開へ退避する。
                    resetIndex = nil
                }
                resetIndexWasBuilt = true
            }
            if let point = resetIndex?.last(where: {
                $0.isRestartable && $0.uncompressedOffset <= target
            }),
               point.uncompressedOffset > 0,
               factory.folder.digest.value == nil,
               let restarted = try factory.makeDecoder(restartingAt: point) {
                decoder = restarted
                position = point.uncompressedOffset
                checksum = CRC32()
                completionVerified = false
                checksumCoversWholeFolder = false
                return
            }
            try restart()
        } catch {
            throw factory.translateEncryptedError(error)
        }
    }

    private func discard(until target: UInt64) throws {
        guard target <= factory.finalSize else {
            throw KaitoError.malformed("7z folder seek exceeds output")
        }
        var scratch = [UInt8](repeating: 0, count: 256 * 1_024)
        while position < target {
            let requested = try Checked.toInt(min(UInt64(scratch.count), target - position))
            guard let decoder else { throw KaitoError.malformed("7z folder decoder is unavailable") }
            do {
                let actual = try scratch.withUnsafeMutableBytes { bytes in
                    try decoder.read(into: UnsafeMutableRawBufferPointer(rebasing: bytes[..<requested]))
                }
                guard actual > 0, actual <= requested else { throw KaitoError.truncated }
                scratch.withUnsafeBytes { bytes in
                    checksum.update(UnsafeRawBufferPointer(rebasing: bytes[..<actual]))
                }
                position = try Checked.add(position, UInt64(actual))
            } catch {
                throw factory.translateEncryptedError(error)
            }
        }
    }

    private func verifyCompletion() throws {
        guard !completionVerified else { return }
        guard position == factory.finalSize,
              let decoder else {
            throw KaitoError.malformed("7z folder ended at the wrong size")
        }
        // 完了後の decoder は後方 seek で再利用しない。必要な場合は
        // factory から再構築できるため、辞書や PPMd arena をここで解放する。
        defer { self.decoder = nil }
        do {
            if !decoder.isFinished {
                var extra: UInt8 = 0
                let actual = try withUnsafeMutableBytes(of: &extra) {
                    try decoder.read(into: $0)
                }
                guard actual == 0, decoder.isFinished else {
                    throw KaitoError.malformed("7z folder output exceeds its declared size")
                }
            }
            if checksumCoversWholeFolder,
               let expected = factory.folder.digest.value,
               checksum.value != expected {
                throw KaitoError.checksumMismatch(entry: -1)
            }
            completionVerified = true
        } catch {
            throw factory.translateEncryptedError(error)
        }
    }
}

private final class SevenZipFolderRangeDecompressor: Decompressor {
    private let coordinator: SevenZipFolderCoordinator
    private let generation: UInt64
    private let endsFolder: Bool
    private var remaining: UInt64

    init(
        coordinator: SevenZipFolderCoordinator,
        generation: UInt64,
        length: UInt64,
        endsFolder: Bool
    ) {
        self.coordinator = coordinator
        self.generation = generation
        self.remaining = length
        self.endsFolder = endsFolder
    }

    var isFinished: Bool { remaining == 0 }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        try coordinator.read(
            generation: generation,
            remaining: &remaining,
            endsFolder: endsFolder,
            into: buffer
        )
    }
}
