// KaitoKit の RAR 巻連結処理を形式非依存の ByteSource として移設した。

struct SourceSegment: Sendable {
    let source: any ByteSource
    let offset: UInt64
    let length: UInt64

    init(source: any ByteSource, offset: UInt64, length: UInt64) {
        self.source = source
        self.offset = offset
        self.length = length
    }
}

/// 検証済みの source 範囲を連結し、一つの論理ストリームとして読み出す。
final class ConcatenatedByteSource: ByteSource {
    private struct Segment: Sendable {
        let source: any ByteSource
        let sourceOffset: UInt64
        let length: UInt64
        let logicalStart: UInt64
    }

    private let segments: [Segment]
    let length: UInt64

    init(
        segments sourceSegments: [SourceSegment],
        maximumLength: UInt64,
        maximumSegmentCount: Int = 128,
        label: String
    ) throws {
        guard !sourceSegments.isEmpty else {
            throw KaitoError.malformed("\(label) has no segments")
        }
        guard maximumSegmentCount > 0,
              sourceSegments.count <= maximumSegmentCount else {
            throw KaitoError.limitExceeded("\(label) has too many segments")
        }

        var logicalOffset: UInt64 = 0
        var validated: [Segment] = []
        validated.reserveCapacity(sourceSegments.count)
        for segment in sourceSegments where segment.length > 0 {
            let sourceEnd = try Checked.add(segment.offset, segment.length)
            guard sourceEnd <= segment.source.length else { throw KaitoError.truncated }
            let logicalEnd = try Checked.add(logicalOffset, segment.length)
            guard logicalEnd <= maximumLength else {
                throw KaitoError.limitExceeded("\(label) exceeds configured maximum")
            }
            validated.append(Segment(
                source: segment.source,
                sourceOffset: segment.offset,
                length: segment.length,
                logicalStart: logicalOffset
            ))
            logicalOffset = logicalEnd
        }
        guard !validated.isEmpty else {
            throw KaitoError.malformed("\(label) contains only empty segments")
        }
        self.segments = validated
        self.length = logicalOffset
    }

    func read(
        into buffer: UnsafeMutableRawBufferPointer,
        at offset: UInt64
    ) throws -> Int {
        guard !buffer.isEmpty, offset < length else { return 0 }
        guard let destination = buffer.baseAddress else { return 0 }

        let wanted = try Checked.toInt(min(UInt64(buffer.count), length - offset))
        var logicalOffset = offset
        var written = 0
        var segmentIndex = findSegment(containing: offset)

        while written < wanted {
            guard segmentIndex < segments.count else { throw KaitoError.truncated }
            let segment = segments[segmentIndex]
            let withinSegment = try Checked.sub(logicalOffset, segment.logicalStart)
            guard withinSegment < segment.length else {
                segmentIndex += 1
                continue
            }
            let request = try Checked.toInt(min(
                UInt64(wanted - written),
                segment.length - withinSegment
            ))
            let target = UnsafeMutableRawBufferPointer(
                start: destination.advanced(by: written),
                count: request
            )
            let actual = try segment.source.read(
                into: target,
                at: try Checked.add(segment.sourceOffset, withinSegment)
            )
            guard actual > 0, actual <= request else { throw KaitoError.truncated }
            written += actual
            logicalOffset = try Checked.add(logicalOffset, UInt64(actual))
            if withinSegment + UInt64(actual) == segment.length {
                segmentIndex += 1
            }
        }
        return written
    }

    private func findSegment(containing offset: UInt64) -> Int {
        var lower = 0
        var upper = segments.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if segments[middle].logicalStart <= offset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return max(0, lower - 1)
    }
}
