import Foundation

struct TarSpliceStoragePolicy {
    var maximumFragments = 1_024
    var maximumLeaves = 8
}

// 過去の合成を保持せず、staging の葉だけを共有する。
final class SplicedTarImage: ByteSource {
    let fragments: [SourceSegment]
    private let joined: ConcatenatedByteSource
    var length: UInt64 { joined.length }
    var leafCount: Int { Self.leaves(fragments).count }
    var inMemorySize: UInt64 { Self.memorySize(fragments) }

    init(fragments: [SourceSegment], maximumLength: UInt64) throws {
        self.fragments = fragments
        joined = try ConcatenatedByteSource(segments: fragments, maximumLength: maximumLength,
                                           maximumSegmentCount: 4_096, label: "spliced tar image")
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        try joined.read(into: buffer, at: offset)
    }

    static func slices(of source: any ByteSource, range: Range<UInt64>) -> [SourceSegment] {
        guard !range.isEmpty else { return [] }
        guard let image = source as? SplicedTarImage else {
            return [.init(source: source, offset: range.lowerBound, length: range.upperBound - range.lowerBound)]
        }
        var offset: UInt64 = 0
        var result: [SourceSegment] = []
        for fragment in image.fragments {
            let lower = max(offset, range.lowerBound), upper = min(offset + fragment.length, range.upperBound)
            if lower < upper {
                result.append(.init(source: fragment.source, offset: fragment.offset + lower - offset, length: upper - lower))
            }
            offset += fragment.length
            if offset >= range.upperBound { break }
        }
        return result
    }

    static func leaves(_ fragments: [SourceSegment]) -> [ObjectIdentifier: any ByteSource] {
        var result: [ObjectIdentifier: any ByteSource] = [:]
        for fragment in fragments where fragment.length > 0 {
            result[ObjectIdentifier(fragment.source as AnyObject)] = fragment.source
        }
        return result
    }

    static func memorySize(_ fragments: [SourceSegment]) -> UInt64 {
        // 小さな slice でも Data 全体を保持するので、葉の全長を一度ずつ数える。
        leaves(fragments).values.reduce(0) { $0 + ($1 is FileByteSource ? 0 : $1.length) }
    }

    static func assemble(_ fragments: [SourceSegment], limits: ReadLimits,
                         policy: TarSpliceStoragePolicy) throws -> any ByteSource {
        guard !fragments.isEmpty else { return DataByteSource(Data()) }
        if fragments.count > min(1_024, policy.maximumFragments)
            || leaves(fragments).count > min(8, policy.maximumLeaves)
            || memorySize(fragments) > limits.inMemorySingleFileLimit {
            let stream = try EntryStream(decompressor: FragmentCopyDecoder(fragments), length: nil,
                                         expectedCRC32: nil, entryIndex: -1, limits: limits)
            return try SingleFileMaterializer.materialize(stream, limits: limits)
        }
        return try SplicedTarImage(fragments: fragments, maximumLength: limits.maxEntrySize)
    }
}

private final class FragmentCopyDecoder: Decompressor {
    private let fragments: [SourceSegment]
    private var index = 0
    private var offset: UInt64 = 0
    var isFinished: Bool { index == fragments.count }

    init(_ fragments: [SourceSegment]) { self.fragments = fragments }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        while index < fragments.count {
            let fragment = fragments[index]
            if offset == fragment.length { index += 1; offset = 0; continue }
            let count = Int(min(UInt64(buffer.count), fragment.length - offset))
            guard count > 0 else { return 0 }
            let actual = try fragment.source.read(into: .init(rebasing: buffer[..<count]), at: fragment.offset + offset)
            guard actual > 0, actual <= count else { throw KaitoError.truncated }
            offset += UInt64(actual)
            return actual
        }
        return 0
    }
}
