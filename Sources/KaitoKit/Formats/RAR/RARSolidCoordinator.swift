// 形式の参照資料:
// - RAR 1.5-4.x の非公式形式ノート:
//   https://github.com/bitplane/rar-research/blob/master/doc/RAR15_40_FORMAT_SPECIFICATION.md
// - libarchive の BSD-2 ライセンスの archive_read_support_format_rar.c は、
//   形式の挙動の確認にのみ参照し、コードや構造は使用していない。
// - RARLab「RAR 5.0 archive format」:
//   https://www.rarlab.com/technote.htm（2026-09-06 参照）。
//   RAR5 は公開された形式記述に基づくクリーンルーム実装。
// RARLab/UnRAR、7-Zip（Rar29 を含む）、XADMaster、The Unarchiver のソースは使用していない。
// RAR4Reader は RAR29Decoder.SolidState と既知のサイズ（UInt64）を渡し、
// RAR5Reader は RAR5Decoder.SolidState と省略可能なサイズ（UInt64?）を渡す。

protocol RARSolidState: AnyObject {
    init(dictionarySize: UInt64) throws
}

extension RAR29Decoder.SolidState: RARSolidState {}
extension RAR5Decoder.SolidState: RARSolidState {}

/// ソリッドグループをアーカイブ順に進め、世代で検証する範囲を公開する。
/// 前方への移動は先行エントリを読み切って検証し、圧縮状態を再利用する。
/// 後方への移動は圧縮状態を作り直し、グループの先頭から再開する。
final class RARSolidCoordinator<State: RARSolidState> {
    typealias StreamFactory = (
        Int,
        State
    ) throws -> EntryStream

    private let formatLabel: String
    private let entryIndices: [Int]
    private let entryPositions: [Int: Int]
    private let dictionarySize: UInt64
    private let limits: ReadLimits
    private let factory: StreamFactory

    private var state: State?
    private var nextPosition = 0
    private var activePosition: Int?
    private var activeStream: EntryStream?
    private var generation: UInt64 = 0

    init(
        formatLabel: String,
        entryIndices: [Int],
        dictionarySize: UInt64,
        limits: ReadLimits,
        factory: @escaping StreamFactory
    ) {
        self.formatLabel = formatLabel
        self.entryIndices = entryIndices
        self.entryPositions = Dictionary(uniqueKeysWithValues:
            entryIndices.enumerated().map { ($0.element, $0.offset) }
        )
        self.dictionarySize = dictionarySize
        self.limits = limits
        self.factory = factory
    }

    func stream(entryIndex: Int, unpackedSize: UInt64?) throws -> any Decompressor {
        guard let requestedPosition = entryPositions[entryIndex] else {
            throw KaitoError.malformed(
                "\(formatLabel) solid entry is not in its published group"
            )
        }
        generation = try Checked.add(generation, 1)

        do {
            if state == nil || requestedPosition < nextPosition
                || activePosition.map({ requestedPosition <= $0 }) == true {
                try restart()
            }

            if activeStream != nil {
                try drainActiveStream()
            }
            while nextPosition < requestedPosition {
                try openNextStream()
                try drainActiveStream()
            }
            guard nextPosition == requestedPosition else {
                throw KaitoError.malformed(
                    "\(formatLabel) solid coordinator passed its requested entry"
                )
            }
            try openNextStream()
            let initiallyFinished = activeStream?.remaining == 0
            if initiallyFinished { completeActiveStream(preserveState: true) }
            return RARSolidRangeDecompressor<State>(
                coordinator: self,
                generation: generation,
                entryIndex: entryIndex,
                unpackedSize: unpackedSize,
                initiallyFinished: initiallyFinished
            )
        } catch {
            abandonState()
            throw error
        }
    }

    fileprivate func read(
        generation expectedGeneration: UInt64,
        entryIndex: Int,
        remaining: inout UInt64?,
        finished: inout Bool,
        into buffer: UnsafeMutableRawBufferPointer
    ) throws -> Int {
        guard expectedGeneration == generation else {
            throw KaitoError.malformed(
                "a newer \(formatLabel) solid stream invalidated this stream"
            )
        }
        guard !finished, !buffer.isEmpty else { return 0 }
        guard let activePosition,
              entryIndices[activePosition] == entryIndex,
              let activeStream else {
            throw KaitoError.malformed(
                "\(formatLabel) solid coordinator has no active entry stream"
            )
        }

        do {
            let actual = try activeStream.read(into: buffer)
            if let current = remaining {
                remaining = try Checked.sub(current, UInt64(actual))
            }
            if activeStream.remaining == 0 {
                finished = true
                remaining = 0
                completeActiveStream(preserveState: true)
            } else if actual == 0 {
                throw KaitoError.truncated
            }
            return actual
        } catch {
            abandonState()
            throw error
        }
    }

    private func restart() throws {
        try Checked.size(dictionarySize, limit: limits.maxDictionarySize)
        state = try State(dictionarySize: dictionarySize)
        nextPosition = 0
        activePosition = nil
        activeStream = nil
    }

    private func openNextStream() throws {
        guard activeStream == nil,
              entryIndices.indices.contains(nextPosition),
              let state else {
            throw KaitoError.malformed(
                "\(formatLabel) solid coordinator cannot open its next entry"
            )
        }
        let position = nextPosition
        activeStream = try factory(entryIndices[position], state)
        activePosition = position
    }

    private func drainActiveStream() throws {
        guard let activeStream else { return }
        var scratch = [UInt8](repeating: 0, count: 256 * 1_024)
        while activeStream.remaining != 0 {
            let count = try scratch.withUnsafeMutableBytes {
                try activeStream.read(into: $0)
            }
            guard count > 0 || activeStream.remaining == 0 else {
                throw KaitoError.truncated
            }
        }
        completeActiveStream(preserveState: true)
    }

    private func completeActiveStream(preserveState: Bool) {
        guard let position = activePosition else { return }
        nextPosition = position + 1
        activePosition = nil
        activeStream = nil
        if !preserveState || nextPosition == entryIndices.count {
            state = nil
        }
    }

    /// 別グループへの切り替え時に公開済みの範囲と辞書を破棄し、
    /// 非スレッドセーフな親リーダーが保持する辞書を一つに制限する。
    func invalidateAndRelease() {
        generation &+= 1
        abandonState()
    }

    /// EOF 前に破棄された範囲の世代を確認し、保持中の検証ストリームと辞書を解放する。
    fileprivate func releaseAbandonedRange(
        generation expectedGeneration: UInt64,
        entryIndex: Int
    ) {
        guard expectedGeneration == generation,
              let activePosition,
              entryIndices[activePosition] == entryIndex else { return }
        invalidateAndRelease()
    }

    private func abandonState() {
        state = nil
        nextPosition = 0
        activePosition = nil
        activeStream = nil
    }
}

private final class RARSolidRangeDecompressor<State: RARSolidState>: Decompressor {
    private let coordinator: RARSolidCoordinator<State>
    private let generation: UInt64
    private let entryIndex: Int
    private var remaining: UInt64?
    private var finished: Bool

    init(
        coordinator: RARSolidCoordinator<State>,
        generation: UInt64,
        entryIndex: Int,
        unpackedSize: UInt64?,
        initiallyFinished: Bool
    ) {
        self.coordinator = coordinator
        self.generation = generation
        self.entryIndex = entryIndex
        self.remaining = unpackedSize
        self.finished = initiallyFinished
    }

    var isFinished: Bool { finished }

    deinit {
        coordinator.releaseAbandonedRange(
            generation: generation,
            entryIndex: entryIndex
        )
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        try coordinator.read(
            generation: generation,
            entryIndex: entryIndex,
            remaining: &remaining,
            finished: &finished,
            into: buffer
        )
    }
}

/// 独立したパスワード検証がない場合、破損した暗号文と誤った鍵による構造エラーを区別しない。
final class RARPasswordAmbiguousDecompressor: Decompressor {
    private let base: any Decompressor
    private let expectedSize: UInt64?
    private var produced: UInt64 = 0

    init(base: any Decompressor, expectedSize: UInt64?) {
        self.base = base
        self.expectedSize = expectedSize
    }

    var isFinished: Bool {
        guard base.isFinished else { return false }
        return expectedSize.map { produced == $0 } ?? true
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        do {
            let count = try base.read(into: buffer)
            guard count >= 0, count <= buffer.count else { return count }
            if count == 0, let expectedSize, produced < expectedSize {
                throw KaitoError.wrongPassword
            }
            let (total, overflow) = produced.addingReportingOverflow(UInt64(count))
            if overflow || expectedSize.map({ total > $0 }) == true {
                throw KaitoError.wrongPassword
            }
            produced = total
            return count
        } catch {
            try Self.rethrowNormalized(error)
        }
    }

    static func rethrowNormalized(_ error: Error) throws -> Never {
        if let kaitoError = error as? KaitoError {
            switch kaitoError {
            case .malformed, .truncated:
                throw KaitoError.wrongPassword
            default:
                break
            }
        }
        throw error
    }
}
