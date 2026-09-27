struct ZipLocalReadAheadPolicy: Sendable, Equatable {
    var initialCapacity: Int
    var maximumCapacity: Int
    var maximumRecordSpan: UInt64

    static let standard = Self(initialCapacity: 32 * 1024, maximumCapacity: 256 * 1024, maximumRecordSpan: 4 * 1024)
    static let disabled = Self(initialCapacity: 0, maximumCapacity: 0, maximumRecordSpan: 0)
}

struct ZipLocalReadAhead {
    let policy: ZipLocalReadAheadPolicy
    private var capacity: Int
    private var bytes: [UInt8] = []
    private var start: UInt64 = 0
    private var highWater: UInt64 = 0
    private var failed = false

    init(policy: ZipLocalReadAheadPolicy) {
        self.policy = policy
        capacity = max(0, min(policy.initialCapacity, policy.maximumCapacity))
    }

    mutating func read(
        source: any ByteSource, offset: UInt64, count: Int,
        position: Int, recordCount: Int, sequential: Bool,
        limits: ReadLimits, bound: UInt64, headerOffset: (Int) -> UInt64
    ) -> [UInt8]? {
        if let cached = cached(offset: offset, count: count) { return cached }
        let effectiveCapacity = min(capacity, Int(clamping: limits.maxMetadataSize))
        guard sequential, !failed, effectiveCapacity > 0,
              offset == headerOffset(position), offset >= highWater else { return nil }
        let maximumSpan = min(policy.maximumRecordSpan, UInt64(effectiveCapacity))
        var end = offset
        for next in position..<recordCount {
            let lower = headerOffset(next)
            let upper = next + 1 < recordCount ? min(headerOffset(next + 1), bound) : bound
            let span = upper >= lower ? upper - lower : 0
            guard span <= maximumSpan, upper >= offset,
                  upper - offset <= UInt64(effectiveCapacity) else { break }
            end = upper
        }
        guard end > offset else { return nil }
        // 後戻りして同じ本文を再読しない。失敗後も exact read のエラーを正とする。
        bytes = []
        do {
            bytes = try readByteRange(source: source, offset: offset, count: Int(end - offset))
            start = offset
            highWater = end
            capacity = capacity > policy.maximumCapacity / 2 ? policy.maximumCapacity : capacity * 2
        } catch {
            bytes = []
            failed = true
            return nil
        }
        return cached(offset: offset, count: count)
    }

    mutating func finish(position: Int, recordCount: Int) {
        // 最終 record の extra / descriptor も返し終えてから解放する。
        if position == recordCount - 1 { bytes = [] }
    }

    private func cached(offset: UInt64, count: Int) -> [UInt8]? {
        guard offset >= start, offset - start <= UInt64(bytes.count),
              UInt64(count) <= UInt64(bytes.count) - (offset - start) else { return nil }
        let lower = Int(offset - start)
        // descriptor の署名判定には要求された byte 数だけを渡す。
        return Array(bytes[lower..<(lower + count)])
    }
}
