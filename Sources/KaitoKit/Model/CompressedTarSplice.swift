import Foundation

@_spi(TarEditLayout)
public struct CompressedTarSplice: Sendable, Equatable {
    public enum Segment: Sendable, Equatable {
        case reused(output: Range<UInt64>, base: Range<UInt64>)
        case encoded(output: Range<UInt64>)

        var outputRange: Range<UInt64> {
            switch self {
            case .reused(let output, _), .encoded(let output): output
            }
        }
    }
    public let segments: [Segment]
    public init(segments: [Segment]) { self.segments = segments }
}

@_spi(TarEditLayout)
public struct TarSpliceVerificationError: Error, Sendable {
    public enum Reason: Sendable, Equatable {
        case baseNotSpliceable, outputChanged, invalidSegments, reusedBytesDiffer,
             inconsistentBaseMap, dictionaryMismatch, encodedSegmentInvalid,
             framingMismatch, checksumMismatch
    }
    public let reason: Reason
    public let segmentIndex: Int?
    public let underlying: KaitoError?

    init(_ reason: Reason, segmentIndex: Int? = nil, underlying: KaitoError? = nil) {
        self.reason = reason
        self.segmentIndex = segmentIndex
        self.underlying = underlying
    }
}

func tarSpliceVerification<T>(_ reason: TarSpliceVerificationError.Reason, segmentIndex: Int? = nil,
                              _ body: () throws -> T) throws -> T {
    do { return try body() }
    catch let error as KaitoError {
        switch error {
        case .limitExceeded, .io: throw error
        default: throw TarSpliceVerificationError(reason, segmentIndex: segmentIndex, underlying: error)
        }
    }
}
