import Foundation

// Provenance:
// - RAR 1.5-4.x unofficial format notes:
//   https://github.com/bitplane/rar-research/blob/master/doc/RAR15_40_FORMAT_SPECIFICATION.md
// - libarchive's BSD-2-licensed archive_read_support_format_rar.c was consulted
//   for format behaviour, not for code or structure.
// No 7-Zip Rar29, unrar source, XADMaster, or The Unarchiver source was used.

/// Advances one RAR3 solid group in archive order.  Each caller receives
/// a generation-checked view of the coordinator's retained, CRC-verifying
/// entry stream.  Forward seeks drain predecessors; backward seeks replace
/// the shared compression state and restart at the group leader.
final class RAR4SolidCoordinator {
    typealias StreamFactory = (
        Int,
        RAR29Decoder.SolidState
    ) throws -> EntryStream

    private let entryIndices: [Int]
    private let entryPositions: [Int: Int]
    private let dictionarySize: UInt64
    private let limits: ReadLimits
    private let factory: StreamFactory

    private var state: RAR29Decoder.SolidState?
    private var nextPosition = 0
    private var activePosition: Int?
    private var activeStream: EntryStream?
    private var generation: UInt64 = 0

    init(
        entryIndices: [Int],
        dictionarySize: UInt64,
        limits: ReadLimits,
        factory: @escaping StreamFactory
    ) {
        self.entryIndices = entryIndices
        self.entryPositions = Dictionary(uniqueKeysWithValues:
            entryIndices.enumerated().map { ($0.element, $0.offset) }
        )
        self.dictionarySize = dictionarySize
        self.limits = limits
        self.factory = factory
    }

    func stream(entryIndex: Int, unpackedSize: UInt64) throws -> any Decompressor {
        guard let requestedPosition = entryPositions[entryIndex] else {
            throw KaitoError.malformed(
                "RAR4 solid entry is not in its published group"
            )
        }
        generation = try Checked.add(generation, 1)

        do {
            if state == nil || requestedPosition < nextPosition
                || activePosition.map({ requestedPosition <= $0 }) == true {
                try restart()
            }
            if activeStream != nil { try drainActiveStream() }
            while nextPosition < requestedPosition {
                try openNextStream()
                try drainActiveStream()
            }
            guard nextPosition == requestedPosition else {
                throw KaitoError.malformed(
                    "RAR4 solid coordinator passed its requested entry"
                )
            }
            try openNextStream()
            let initiallyFinished = activeStream?.remaining == 0
            if initiallyFinished { completeActiveStream(preserveState: true) }
            return RAR4SolidRangeDecompressor(
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
        remaining: inout UInt64,
        finished: inout Bool,
        into buffer: UnsafeMutableRawBufferPointer
    ) throws -> Int {
        guard expectedGeneration == generation else {
            throw KaitoError.malformed(
                "a newer RAR4 solid stream invalidated this stream"
            )
        }
        guard !finished, !buffer.isEmpty else { return 0 }
        guard let activePosition,
              entryIndices[activePosition] == entryIndex,
              let activeStream else {
            throw KaitoError.malformed(
                "RAR4 solid coordinator has no active entry stream"
            )
        }

        do {
            let actual = try activeStream.read(into: buffer)
            remaining = try Checked.sub(remaining, UInt64(actual))
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
        state = try RAR29Decoder.SolidState(dictionarySize: dictionarySize)
        nextPosition = 0
        activePosition = nil
        activeStream = nil
    }

    private func openNextStream() throws {
        guard activeStream == nil,
              entryIndices.indices.contains(nextPosition),
              let state else {
            throw KaitoError.malformed(
                "RAR4 solid coordinator cannot open its next entry"
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

    func invalidateAndRelease() {
        generation &+= 1
        abandonState()
    }

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

private final class RAR4SolidRangeDecompressor: Decompressor {
    private let coordinator: RAR4SolidCoordinator
    private let generation: UInt64
    private let entryIndex: Int
    private var remaining: UInt64
    private var finished: Bool

    init(
        coordinator: RAR4SolidCoordinator,
        generation: UInt64,
        entryIndex: Int,
        unpackedSize: UInt64,
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
