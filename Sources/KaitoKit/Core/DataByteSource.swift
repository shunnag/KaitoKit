import Darwin
import Foundation

/// A byte source that retains a `Data` value without copying its storage.
public final class DataByteSource: ByteSource, ByteSourceReadAhead {
    // internal にして、テストでは COW ストレージの同一性を直接確認できるようにする。
    let data: Data
    private let readAhead: MappedReadAhead?
    @TaskLocal static var testingWillAdvise: (@Sendable (Range<UInt>) -> Void)?
    @TaskLocal static var testingDidAdvise: (@Sendable (Range<UInt>) -> Void)?

    /// Total number of bytes in the retained data.
    public var length: UInt64 {
        UInt64(data.count)
    }

    /// Retains a data value using `Data` copy-on-write semantics.
    public init(data: Data) {
        self.data = data
        self.readAhead = data.count >= MappedReadAhead.minimumSize
            ? data.withUnsafeBytes {
                MappedReadAhead(bytes: $0, willAdvise: Self.testingWillAdvise, didAdvise: Self.testingDidAdvise)
            }
            : nil
    }

    /// Retains a data value using `Data` copy-on-write semantics.
    public convenience init(_ data: Data) {
        self.init(data: data)
    }

    func hintReadAhead(offset: UInt64, count: UInt64) {
        guard let readAhead, offset < length,
              count >= UInt64(MappedReadAhead.minimumSize) else { return }
        let count = Int(min(count, length - offset))
        guard count >= MappedReadAhead.minimumSize else { return }
        data.withUnsafeBytes { bytes in
            readAhead.hint(base: bytes.baseAddress!, start: Int(offset), count: count)
        }
    }

    /// Copies a requested range into the caller-provided buffer.
    public func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        guard !buffer.isEmpty, offset < length else {
            return 0
        }

        let available = try Checked.sub(length, offset)
        let count = try Checked.toInt(min(UInt64(buffer.count), available))
        let start = try Checked.toInt(offset)
        guard count > 0, let destination = buffer.baseAddress else {
            return 0
        }

        return data.withUnsafeBytes { sourceBuffer in
            guard let source = sourceBuffer.baseAddress else {
                return 0
            }
            if count >= MappedReadAhead.minimumSize {
                readAhead?.hint(base: source, start: start, count: count)
            }
            // start + count は上の length 検証済みで、両ポインタの有効領域は count バイト以上。
            destination.copyMemory(from: source.advanced(by: start), byteCount: count)
            return count
        }
    }
}

// Data(contentsOf:options:.mappedIfSafe) は heap にも fallback する。外部 pager を
// 持つ VM region だけを対象とし、malloc の隣接 allocation に助言を出さない。
private final class MappedReadAhead: @unchecked Sendable {
    static let minimumSize = 64 << 10
    private let pageSize = UInt(getpagesize())
    private let lock = NSLock()
    private var hinted: [Range<UInt>] = []
    private let willAdvise: (@Sendable (Range<UInt>) -> Void)?
    private let didAdvise: (@Sendable (Range<UInt>) -> Void)?

    init?(bytes: UnsafeRawBufferPointer, willAdvise: (@Sendable (Range<UInt>) -> Void)?,
          didAdvise: (@Sendable (Range<UInt>) -> Void)?) {
        guard let base = bytes.baseAddress else { return nil }
        let start = UInt64(UInt(bitPattern: base))
        var address = mach_vm_address_t(start)
        var size: mach_vm_size_t = 0
        var info = vm_region_submap_short_info_64()
        var depth: natural_t = 0
        // short info は page ごとの集計を行わない。submap 内も元の start を問い合わせる。
        while true {
            // VM_REGION_SUBMAP_SHORT_INFO_COUNT_64 と同じ short struct の word 数。
            var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    mach_vm_region_recurse(mach_task_self_, &address, &size, &depth, $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return nil }
            if info.is_submap == 0 { break }
            guard depth < natural_t.max else { return nil }
            depth += 1
            address = mach_vm_address_t(start)
        }
        guard info.external_pager != 0,
              address <= start, start - address <= size,
              UInt64(bytes.count) <= size - (start - address) else { return nil }
        self.willAdvise = willAdvise
        self.didAdvise = didAdvise
    }

    func hint(base: UnsafeRawPointer, start: Int, count: Int) {
        let lower = UInt(bitPattern: base) + UInt(start)
        let upper = lower + UInt(count)
        let range = (lower - lower % pageSize)..<(((upper - 1) / pageSize + 1) * pageSize)
        let gaps = lock.withLock { () -> [Range<UInt>] in
            // page 単位の区間を併合し、重複 stream や warm map の再読でも再通知しない。
            var gaps: [Range<UInt>] = []
            var cursor = range.lowerBound
            for previous in hinted {
                if previous.lowerBound <= range.lowerBound, previous.upperBound >= range.upperBound { return [] }
                if previous.upperBound <= cursor { continue }
                if previous.lowerBound >= range.upperBound { break }
                if cursor < previous.lowerBound { gaps.append(cursor..<previous.lowerBound) }
                cursor = max(cursor, previous.upperBound)
            }
            if cursor < range.upperBound { gaps.append(cursor..<range.upperBound) }
            var merged = range
            var first = 0
            while first < hinted.count, hinted[first].upperBound < merged.lowerBound { first += 1 }
            var last = first
            while last < hinted.count, hinted[last].lowerBound <= merged.upperBound {
                merged = min(merged.lowerBound, hinted[last].lowerBound)..<max(merged.upperBound, hinted[last].upperBound)
                last += 1
            }
            hinted.replaceSubrange(first..<last, with: [merged])
            return gaps
        }
        // 予約を公開してから lock を離す。cold な WILLNEED を他の stream に待たせない。
        for gap in gaps { advise(gap) }
    }

    private func advise(_ range: Range<UInt>) {
        willAdvise?(range)
        // WILLNEED は読み順を変えない。失敗も読み取り結果・エラーには影響させない。
        _ = madvise(UnsafeMutableRawPointer(bitPattern: range.lowerBound), range.count, MADV_WILLNEED)
        didAdvise?(range)
    }
}
