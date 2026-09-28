import Foundation

// 一つの folder の decoder を、同じ folder の substream の間で共有する。前方の substream へは
// 読み捨てて進み、後方へは LZMA2 の辞書 reset 点か folder の先頭から作り直す。folder の CRC は
// 展開結果を最後まで読んだ時点で確かめる。

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
            self.decoder = nil
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
            self.decoder = nil
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
            self.decoder = nil
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
                self.decoder = nil
                throw factory.translateEncryptedError(error)
            }
        }
    }

    private func verifyCompletion() throws {
        guard !completionVerified else { return }
        // 完了でも失敗でも decoder を手放す。次の要求は途中まで読んだ入力を再利用せず、
        // factory から作り直す。
        defer { self.decoder = nil }
        guard position == factory.finalSize,
              let decoder else {
            throw KaitoError.malformed("7z folder ended at the wrong size")
        }
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
            self.decoder = nil
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
