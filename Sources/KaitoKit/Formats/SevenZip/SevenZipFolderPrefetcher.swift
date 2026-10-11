import Foundation

// 非 solid 7z（folder ごとに一つの substream）を順方向に読んでいる間、先の folder を
// LeafDecodePool で先行復号する。結果は folder 単位で受け取り、復号・終端・CRC の検査を
// すべて通った folder だけを呼出元へ渡す。失敗した folder は従来の直列経路が復号し直すので、
// 呼出元に届く部分出力とエラーは直列経路と同じになる。葉は他の葉を待たず、消費側だけが待つ。
// 可変状態はすべて condition の lock 内で触る。
final class SevenZipFolderPrefetcher: @unchecked Sendable {
    /// 一つの folder の先行復号の指示。capture は不変の入力範囲だけで、reader の可変状態を渡さない。
    struct Unit: Sendable {
        let folderIndex: Int
        let entryIndex: Int
        let outputSize: Int
        /// substream（entry）の CRC。worker が検査し、不一致なら結果を渡さない。
        let expectedCRC32: UInt32?
        /// folder の CRC。単一 substream なので entry CRC と同じ範囲を検査する。
        let folderCRC32: UInt32?
        /// 復号器が出力以外に保持する見積り（辞書・確率表・入力 buffer）。
        let scratchBytes: Int
        let makeDecoder: @Sendable () throws -> any Decompressor
    }

    /// まとめて一つの葉で復号する連続した folder 群。小さな folder を一つずつ投入する往復を省く。
    struct Batch {
        let units: [Unit]
        let firstEntryIndex: Int
        let lastEntryIndex: Int
        /// 出力（終端検査の 1 byte を含む）と、直列に走る復号器の最大 scratch の和。
        let heldBytes: Int

        init(units: [Unit]) throws {
            precondition(!units.isEmpty)
            self.units = units
            firstEntryIndex = units.first!.entryIndex
            lastEntryIndex = units.last!.entryIndex
            var held: UInt64 = 0
            for unit in units { held = try Checked.add(held, UInt64(unit.outputSize) + 1) }
            heldBytes = try Checked.toInt(Checked.add(held, UInt64(units.map(\.scratchBytes).max() ?? 0)))
        }
    }

    /// 一つの batch の結果。検査を通った folder の出力範囲だけを載せる。
    final class Decoded: @unchecked Sendable {
        let bytes: Data
        let ranges: [Int: Range<Int>]
        init(bytes: Data, ranges: [Int: Range<Int>]) { self.bytes = bytes; self.ranges = ranges }
    }

    /// 検査済みの folder 出力。EntryStream は従来どおり長さと CRC を確かめる。
    final class FolderDecompressor: Decompressor {
        private let bytes: Data
        private var position: Int
        private let end: Int

        init(bytes: Data, range: Range<Int>) {
            self.bytes = bytes; position = range.lowerBound; end = range.upperBound
        }

        var isFinished: Bool { position == end }

        func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
            let count = min(buffer.count, end - position)
            guard count > 0, let destination = buffer.baseAddress else { return 0 }
            bytes.withUnsafeBytes { source in
                destination.copyMemory(from: source.baseAddress!.advanced(by: position), byteCount: count)
            }
            position += count
            return count
        }
    }

    private final class BatchState {
        let batch: Batch
        var remainingFolders: Set<Int>
        var ticket: LeafDecodePool.Ticket?
        var result: Decoded?
        init(batch: Batch) {
            self.batch = batch
            remainingFolders = Set(batch.units.map(\.folderIndex))
        }
    }

    private let condition = NSCondition()
    private var group = LeafDecodePool.Group()
    private var batches: [Int: BatchState] = [:]
    private var folderToBatch: [Int: Int] = [:]
    private var nextBatchID = 0
    private var held = 0
    private var served = 0
    private var inFlight = 0
    /// 保持中の batch の lastEntryIndex の最小値。それより後ろの entry を読むまで drop の走査を省く。
    private var lowestLastEntryIndex = Int.max

    let workerCount: Int
    let memoryBudget: Int

    // Test hook: 投入した batch 数と、検査を通って呼出元へ渡した folder 数。
    var submittedBatchCount: Int { condition.withLock { nextBatchID } }
    var servedFolderCount: Int { condition.withLock { served } }

    init(workers: Int, memoryBudget: Int) {
        workerCount = min(max(1, workers), LeafDecodePool.shared.capacity)
        self.memoryBudget = memoryBudget
    }

    deinit { reset() }

    /// 投入済みで復号がまだ終わっていない batch の数。
    var inFlightBatchCount: Int { condition.withLock { inFlight } }
    var heldBytes: Int { condition.withLock { held } }
    /// 復号中の batch は worker 数まで、保持中（復号済みで未受領を含む）の batch はその 2 倍まで。
    /// 消費側が遅いときに復号済みの出力が予算いっぱいまで溜まらないようにする。
    var canSubmitMore: Bool { condition.withLock { hasWindowRoom } }
    private var hasWindowRoom: Bool { inFlight < workerCount && batches.count < 2 * workerCount }

    /// 予算内に収まるなら投入する。収まらなければ false（folder は直列経路に残る）。
    @discardableResult
    func submit(_ batch: Batch) -> Bool {
        condition.lock()
        guard held + batch.heldBytes <= memoryBudget, hasWindowRoom else {
            condition.unlock(); return false
        }
        let id = nextBatchID
        nextBatchID += 1
        let state = BatchState(batch: batch)
        batches[id] = state
        for unit in batch.units { folderToBatch[unit.folderIndex] = id }
        held += batch.heldBytes
        inFlight += 1
        lowestLastEntryIndex = min(lowestLastEntryIndex, batch.lastEntryIndex)
        let group = self.group
        condition.unlock()

        let ticket = LeafDecodePool.shared.submit(group: group) { [self] in
            guard !isDropped(id) else { return }
            let decoded = Self.decode(batch, isDropped: { [self] in isDropped(id) })
            condition.lock()
            if let state = batches[id] {
                if state.remainingFolders.isEmpty || decoded == nil {
                    remove(id)
                } else {
                    state.result = decoded
                    state.ticket = nil
                    inFlight -= 1
                }
            }
            condition.broadcast()
            condition.unlock()
        }
        condition.withLock { batches[id]?.ticket = ticket }
        return true
    }

    /// folder の先行復号の結果。投入されていなければ nil、検査に失敗していれば nil、
    /// 復号中なら完了を待つ（1 poll の後、未開始なら自分で実行する）。
    func take(folder: Int) throws -> FolderDecompressor? {
        condition.lock()
        guard let id = folderToBatch[folder] else { condition.unlock(); return nil }
        condition.unlock()
        var hasWaited = false
        while true {
            try Task.checkCancellation()
            condition.lock()
            guard let state = batches[id] else { condition.unlock(); return nil }
            if let decoded = state.result {
                state.remainingFolders.remove(folder)
                folderToBatch.removeValue(forKey: folder)
                if state.remainingFolders.isEmpty { remove(id) }
                let range = decoded.ranges[folder]
                if range != nil { served += 1 }
                condition.unlock()
                guard let range else { return nil }
                return FolderDecompressor(bytes: decoded.bytes, range: range)
            }
            let ticket = state.ticket
            condition.unlock()
            // まず Dispatch に譲り、1 poll 待っても未開始の葉だけを lock の外で実行する。
            if hasWaited, let ticket, LeafDecodePool.shared.runInline(ticket) { continue }
            condition.lock()
            if batches[id]?.result != nil || batches[id] == nil { condition.unlock(); continue }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
            condition.unlock()
            hasWaited = true
        }
    }

    /// `entryIndex` より前で終わる batch は順方向の読みでは使われない。結果を捨て、
    /// 未開始なら実行もしない。
    func dropBatches(endingBefore entryIndex: Int) {
        condition.lock()
        guard lowestLastEntryIndex < entryIndex else { condition.unlock(); return }
        let stale = batches.filter { $0.value.batch.lastEntryIndex < entryIndex }
        for (id, state) in stale {
            if let ticket = state.ticket { LeafDecodePool.shared.discard(ticket) }
            remove(id)
        }
        condition.unlock()
    }

    /// すべての先行復号を捨てる（後方 seek・解放）。実行中の葉は放棄を観測して止まる。
    func reset() {
        condition.lock()
        for id in Array(batches.keys) { remove(id) }
        let group = self.group
        self.group = LeafDecodePool.Group()
        condition.broadcast()
        condition.unlock()
        LeafDecodePool.shared.cancel(group: group)
    }

    // lock 内だけで呼ぶ。
    private func remove(_ id: Int) {
        guard let state = batches.removeValue(forKey: id) else { return }
        for folder in state.remainingFolders where folderToBatch[folder] == id {
            folderToBatch.removeValue(forKey: folder)
        }
        held -= state.batch.heldBytes
        if state.result == nil { inFlight -= 1 }
        lowestLastEntryIndex = batches.values.map(\.batch.lastEntryIndex).min() ?? Int.max
    }

    private func isDropped(_ id: Int) -> Bool { condition.withLock { batches[id] == nil } }

    /// batch を直列に復号する。folder ごとに独立なので、失敗した folder は飛ばして次へ進む。
    /// 放棄を観測したら nil。
    private static func decode(_ batch: Batch, isDropped: () -> Bool) -> Decoded? {
        var total = 0
        for unit in batch.units { total += unit.outputSize }
        var output = Data(count: total)
        var ranges: [Int: Range<Int>] = [:]
        ranges.reserveCapacity(batch.units.count)
        var dropped = false
        output.withUnsafeMutableBytes { destination in
            var offset = 0
            for (index, unit) in batch.units.enumerated() {
                defer { offset += unit.outputSize }
                // 放棄の確認は lock を取るので、小さな folder では数個おきに見る。
                if index & 15 == 0, isDropped() { dropped = true; return }
                let range = offset..<(offset + unit.outputSize)
                let region = UnsafeMutableRawBufferPointer(rebasing: destination[range])
                guard Self.decodeUnit(unit, into: region, isDropped: isDropped) else { continue }
                ranges[unit.folderIndex] = range
            }
        }
        return dropped ? nil : Decoded(bytes: output, ranges: ranges)
    }

    /// 直列経路が最終 chunk を返す前に確かめる条件（宣言長・終端・folder CRC）に entry CRC を加えて
    /// 検査する。どれかに失敗した folder は結果に載せない。
    private static func decodeUnit(
        _ unit: Unit, into destination: UnsafeMutableRawBufferPointer, isDropped: () -> Bool
    ) -> Bool {
        do {
            let decoder = try unit.makeDecoder()
            var written = 0
            while written < unit.outputSize {
                if written > 0, isDropped() { return false }
                let count = try decoder.read(into: UnsafeMutableRawBufferPointer(rebasing: destination[written...]))
                guard count > 0, count <= unit.outputSize - written else { return false }
                written += count
            }
            if !decoder.isFinished {
                var extra: UInt8 = 0
                let count = try withUnsafeMutableBytes(of: &extra) { try decoder.read(into: $0) }
                guard count == 0, decoder.isFinished else { return false }
            }
            if unit.folderCRC32 != nil || unit.expectedCRC32 != nil {
                var checksum = CRC32()
                checksum.update(UnsafeRawBufferPointer(destination))
                if let expected = unit.folderCRC32, checksum.value != expected { return false }
                if let expected = unit.expectedCRC32, checksum.value != expected { return false }
            }
            return true
        } catch {
            return false
        }
    }
}
