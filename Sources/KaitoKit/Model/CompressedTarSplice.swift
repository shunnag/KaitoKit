import Foundation

/// ``ArchiveReader/openSplicedCompressedTar(output:sourceURL:base:splice:options:)`` に渡す、出力の圧縮 byte の組み立て。
/// segments は出力の圧縮 payload（gzip は header と trailer の間、xz は stream header と Index の間、bzip2 は全体）を
/// 先頭から隙間なく覆う。
@_spi(TarEditLayout)
public struct CompressedTarSplice: Sendable, Equatable {
    /// reused は base の圧縮 byte を同じ長さのまま写した区間（base 側は base の地図の区切りに揃う）、
    /// encoded は新たに符号化した区間。
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

/// 継ぎの検証の失敗。取消し・I/O・資源・tar 解析のエラーはこの型にせず、そのまま投げる。
@_spi(TarEditLayout)
public struct TarSpliceVerificationError: Error, Sendable {
    /// baseNotSpliceable は base に地図がない、outputChanged は検証中の出力の同一性の変化、invalidSegments は
    /// 被覆・区切りの誤り、reusedBytesDiffer は写した圧縮 byte の CRC-32 の相違、inconsistentBaseMap は base の
    /// 地図と image の不一致、dictionaryMismatch は gzip の再利用直前の窓の相違、encodedSegmentInvalid は新しい区間の
    /// 復号の失敗、framingMismatch は枠（header・block の大きさ・stream flags）の不一致、checksumMismatch は
    /// gzip trailer や xz Index の検査値の不一致。
    public enum Reason: Sendable, Equatable {
        case baseNotSpliceable, outputChanged, invalidSegments, reusedBytesDiffer,
             inconsistentBaseMap, dictionaryMismatch, encodedSegmentInvalid,
             framingMismatch, checksumMismatch
    }
    /// 失敗の種類と、特定できる場合は失敗した segments の位置、原因の KaitoError。
    public let reason: Reason
    public let segmentIndex: Int?
    public let underlying: KaitoError?

    init(_ reason: Reason, segmentIndex: Int? = nil, underlying: KaitoError? = nil) {
        self.reason = reason
        self.segmentIndex = segmentIndex
        self.underlying = underlying
    }
}
