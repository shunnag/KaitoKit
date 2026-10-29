import Foundation

struct HeaderReadPlanner {
    enum Mode { case fixed(Int), adaptive }
    enum SpacingEstimate { case median, maximum }
    private let mode: Mode
    private let minimumWindowSize: Int
    private let spacingEstimate: SpacingEstimate
    private var spacings: [UInt64] = []
    private var hasMiss = false
    private var observedBlocks = 0

    init(_ mode: Mode, minimumWindowSize: Int = 16 << 10, spacingEstimate: SpacingEstimate = .median) {
        self.mode = mode
        self.minimumWindowSize = minimumWindowSize
        self.spacingEstimate = spacingEstimate
    }

    mutating func noteBlock(offset: UInt64, nextOffset: UInt64) {
        guard nextOffset >= offset else { return }
        if spacingEstimate == .maximum, observedBlocks < 8 { observedBlocks += 1 }
        spacings.append(nextOffset - offset)
        if spacings.count > 4 { spacings.removeFirst() }
    }

    mutating func windowSize(offset: UInt64, request: Int, length: UInt64) -> Int {
        guard offset < length, request > 0 else { return 0 }
        let maximum = 1 << 20
        var size = minimumWindowSize
        switch mode {
        case .fixed(let fixed): size = fixed
        case .adaptive:
            if !hasMiss { size = length <= UInt64(maximum) ? maximum : minimumWindowSize }
            else if !spacings.isEmpty {
                let spacing: UInt64?
                switch spacingEstimate {
                case .median:
                    let sorted = spacings.sorted()
                    let middle = sorted.count / 2
                    spacing = sorted.count % 2 == 0
                        ? sorted[middle - 1] + (sorted[middle] - sorted[middle - 1]) / 2
                        : sorted[middle]
                case .maximum:
                    // Tar may put several small PAX/sidecar records before each
                    // large body. Observe eight headers before expanding so an
                    // initial directory/PAX prelude cannot look like dense files.
                    // Thereafter keep any large skip in the last four spacings.
                    spacing = observedBlocks == 8 ? spacings.max() : nil
                }
                // 1 要求は約 9 ms + bytes/(30〜60 MB/s)。間隔 270〜540 KiB 未満なら
                // ストリームが有利で、64 KiB は遅い Wi-Fi にも 4〜8 倍の余裕を持つ。
                // 直近 4 個の中央値なら JPEG 列中の大きな TIFF 1 枚で揺れない。
                // 実測では 6 MB/395 件が 3.9→1.08 秒、110 MB/124 件は窓拡大で
                // 2.13→2.64 秒・転送量 4→36 MB となったため疎な列は小窓を保つ。
                if let spacing, spacing <= 64 << 10 { size = Int(min(UInt64(maximum), max(256 << 10, spacing * 64))) }
            }
        }
        hasMiss = true
        return Int(min(length - offset, UInt64(max(request, min(maximum, size)))))
    }
}

// 解析中の窓と seed だけを保持する。可変領域へのアクセスは lock で直列化する。
final class HeaderWindowByteSource: ByteSource, @unchecked Sendable {
    @TaskLocal static var testingDidCreate: (@Sendable (HeaderWindowByteSource) -> Void)?
    private struct Region {
        let offset: UInt64
        let bytes: [UInt8]
        func contains(_ position: UInt64) -> Bool {
            position >= offset && position - offset < UInt64(bytes.count)
        }
    }
    private let base: any ByteSource
    private let lock = NSLock()
    private let maximumReadSize: Int
    private var planner: HeaderReadPlanner
    private var window = Region(offset: 0, bytes: [])
    private var seeds: [Region] = []
    let length: UInt64

    init(base: any ByteSource, planner: HeaderReadPlanner, maximumReadSize: Int = Int.max) {
        self.maximumReadSize = max(1, maximumReadSize)
        self.base = base
        self.length = base.length
        self.planner = planner
        Self.testingDidCreate?(self)
    }

    func seed(offset: UInt64, bytes: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        guard offset < length else { return }
        seeds.append(Region(offset: offset, bytes: Array(bytes.prefix(Int(min(UInt64(bytes.count), length - offset))))))
        if seeds.count > 2 { seeds.removeFirst() }
    }

    func noteBlock(offset: UInt64, nextOffset: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        planner.noteBlock(offset: offset, nextOffset: nextOffset)
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard !buffer.isEmpty, offset < length else { return 0 }
        let region: Region
        if let seed = seeds.last(where: { $0.contains(offset) }) { region = seed }
        else {
            if !window.contains(offset) {
                let planned = planner.windowSize(offset: offset, request: buffer.count, length: length)
                // 呼出側の小さな metadata 予算では、投機的な窓自体もその予算に収める。
                let count = min(planned, max(buffer.count, maximumReadSize))
                let bytes = try [UInt8](unsafeUninitializedCapacity: count) { storage, initialized in
                    while initialized < count {
                        // 大きな明示要求でも、base への各要求は呼出側の上限を守る。
                        let request = min(count - initialized, maximumReadSize)
                        let target = UnsafeMutableRawBufferPointer(rebasing: UnsafeMutableRawBufferPointer(storage)[initialized..<initialized + request])
                        let actual = try base.read(into: target, at: offset + UInt64(initialized))
                        guard actual >= 0, actual <= request else { throw KaitoError.truncated }
                        if actual == 0 { break }
                        initialized += actual
                    }
                }
                window = Region(offset: offset, bytes: bytes)
            }
            region = window
        }
        let start = Int(offset - region.offset)
        let count = min(buffer.count, region.bytes.count - start)
        if count > 0 { region.bytes.withUnsafeBytes { buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0[start..<start + count])) } }
        return count
    }
}
