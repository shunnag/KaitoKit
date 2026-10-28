import Darwin

// Provenance:
// - bitplane/rar-research's unofficial RAR 1.5-4.x format notes.
// - libarchive archive_read_support_format_rar.c (BSD-2-Clause), consulted
//   for solid-stream behavior only, not for code or structure.
// - RARLab, "RAR 5.0 archive format": https://www.rarlab.com/technote.htm
// - KaitoKit's own RAR5 raw-buffer reuse pattern for drain scratch.
// No unrar, 7-Zip, XADMaster, or The Unarchiver source was used.
// RAR4Reader supplies RAR29Decoder.SolidState and a known UInt64 size;
// RAR5Reader supplies RAR5Decoder.SolidState and an optional UInt64 size.

protocol RARSolidState: AnyObject {
    init(dictionarySize: UInt64) throws
}

extension RAR29Decoder.SolidState: RARSolidState {}
extension RAR5Decoder.SolidState: RARSolidState {}

/// Advances a solid group in archive order and publishes generation-checked
/// ranges. Forward seeks drain and verify predecessors while retaining state;
/// backward seeks reconstruct state from the beginning of the group.
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

    private let drainCapacity = 256 * 1_024
    private var drainScratch: UnsafeMutableRawPointer?
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

    deinit {
        if let drainScratch { free(drainScratch) }
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
        if drainScratch == nil {
            guard let scratch = malloc(drainCapacity) else {
                throw KaitoError.limitExceeded("unable to allocate solid drain scratch")
            }
            drainScratch = scratch
        }
        // EntryStream receives exactly the allocated extent and validates its
        // returned count. It writes bytes before CRC/limit checks read them;
        // scratch contents are never consumed here, so no zero fill is needed.
        let scratch = UnsafeMutableRawBufferPointer(start: drainScratch!, count: drainCapacity)
        while activeStream.remaining != 0 {
            let count = try activeStream.read(into: scratch)
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

    /// Drops published ranges and the dictionary on a group switch, keeping
    /// the non-thread-safe parent reader's retained dictionary count at one.
    func invalidateAndRelease() {
        generation &+= 1
        abandonState()
    }

    /// Checks the abandoned range's generation and releases its stream/state.
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

/// Without independent password verification, structural errors from damaged
/// ciphertext and from incorrect keys have the same password-error semantics.
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
