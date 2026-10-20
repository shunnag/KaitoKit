import Darwin
import Foundation

/// ファイル由来の書庫が、未使用の入力ハンドルを保持する方針。
///
/// Controls retention of idle input handles for file-backed archives.
public enum FileAccessPolicy: Sendable, Equatable {
    /// reader の寿命まで保持する。rename・unlink 後も、既に開いた実体を読む従来の契約。
    ///
    /// Retains handles for the reader's lifetime, including after rename or unlink.
    case persistent
    /// プロセス共通の小さな LRU に保持する。再開時に device・inode・サイズ・更新時刻を
    /// 検証し、元のファイルが失われた／変化した場合は別の内容を読まずエラーにする。
    /// 解析結果と decoder の状態は維持し、ハンドルが必要になるまで再 open しない。
    ///
    /// Uses a small process-wide LRU. Reopening verifies file identity, size, and modification
    /// time, and fails if the original file changed or disappeared. Parsed and decoder state remain intact.
    case bounded

    /// 未使用の bounded ハンドルを解放する。進行中の I/O は中断しない。
    ///
    /// Releases idle bounded handles without interrupting I/O in progress.
    @discardableResult
    public static func releaseIdleCachedHandles() -> Int {
        FileDescriptorCache.shared.releaseIdleHandles()
    }
}

/// キャッシュには所有者を保持しない。最後の所有者の解放で FD も確実に閉じる。
/// open / fstat / pread / close は全体ロックの外で行い、NAS 1冊が他の reader を塞がない。
final class FileDescriptorCache: @unchecked Sendable {
    static let shared = FileDescriptorCache(capacity: defaultCapacity)

    private static var defaultCapacity: Int {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return 32 }
        return max(1, min(64, Int(clamping: limit.rlim_cur) / 4))
    }

    private struct Entry {
        var descriptor: Int32?
        var users: Int
        var stamp: UInt64
        var retired = false
    }
    private let condition = NSCondition()
    private let capacity: Int
    private let closeDescriptor: @Sendable (Int32) -> Void
    private var clock: UInt64 = 0
    private var entries: [UUID: Entry] = [:]

    init(capacity: Int, close: @escaping @Sendable (Int32) -> Void = { _ = Darwin.close($0) }) {
        self.capacity = max(1, capacity)
        closeDescriptor = close
    }

    /// 初回 open の一時 FD にも空きを残す。使用中の FD は閉じない。
    func prepareForOpen() {
        condition.lock()
        let evicted = entries.count >= capacity ? evictOldestIdle() : nil
        condition.unlock()
        if let descriptor = evicted?.descriptor { closeDescriptor(descriptor) }
    }

    /// 受け取った FD の所有権は成功・失敗にかかわらずこのメソッドが引き受ける。
    func adopt(_ descriptor: Int32, key: UUID) throws {
        condition.lock()
        let evicted: Entry?
        if entries.count >= capacity {
            guard let idle = evictOldestIdle() else {
                condition.unlock()
                closeDescriptor(descriptor)
                // 入れ子の dirfd→file 取得で全枠が使用中でも待ち合わせて deadlock しない。
                throw KaitoError.io(EMFILE)
            }
            evicted = idle
        } else { evicted = nil }
        clock &+= 1
        entries[key] = Entry(descriptor: descriptor, users: 0, stamp: clock)
        condition.unlock()
        if let descriptor = evicted?.descriptor { closeDescriptor(descriptor) }
    }

    func acquire(key: UUID, reopen: () throws -> Int32) throws -> Int32 {
        condition.lock()
        while let existing = entries[key] {
            if let descriptor = existing.descriptor {
                var active = existing
                active.users += 1
                clock &+= 1
                active.stamp = clock
                entries[key] = active
                condition.unlock()
                return descriptor
            }
            // 同じハンドルの open 中だけ待つ。全体の枠待ちは親子の取得を deadlock させる。
            condition.wait()
        }
        let evicted: Entry?
        if entries.count >= capacity {
            guard let idle = evictOldestIdle() else {
                condition.unlock()
                throw KaitoError.io(EMFILE)
            }
            evicted = idle
        } else { evicted = nil }
        clock &+= 1
        entries[key] = Entry(descriptor: nil, users: 1, stamp: clock)
        condition.unlock()
        if let descriptor = evicted?.descriptor { closeDescriptor(descriptor) }
        do {
            let descriptor = try reopen()
            condition.lock()
            entries[key]?.descriptor = descriptor
            condition.broadcast()
            condition.unlock()
            return descriptor
        } catch {
            condition.lock()
            entries.removeValue(forKey: key)
            condition.broadcast()
            condition.unlock()
            throw error
        }
    }

    func release(key: UUID) {
        var retiredDescriptor: Int32?
        condition.lock()
        if var entry = entries[key] {
            entry.users -= 1
            if entry.users == 0, entry.retired {
                retiredDescriptor = entry.descriptor
                entries.removeValue(forKey: key)
            } else { entries[key] = entry }
        }
        condition.broadcast()
        condition.unlock()
        if let descriptor = retiredDescriptor { closeDescriptor(descriptor) }
    }

    func remove(key: UUID) {
        var retiredDescriptor: Int32?
        condition.lock()
        if var entry = entries[key] {
            if entry.users == 0 {
                retiredDescriptor = entry.descriptor
                entries.removeValue(forKey: key)
            } else {
                entry.retired = true
                entries[key] = entry
            }
        }
        condition.unlock()
        if let descriptor = retiredDescriptor { closeDescriptor(descriptor) }
    }

    @discardableResult
    func releaseIdleHandles() -> Int {
        condition.lock()
        let keys = entries.compactMap { $0.value.users == 0 ? $0.key : nil }
        let descriptors = keys.compactMap { entries.removeValue(forKey: $0)?.descriptor }
        condition.unlock()
        // NAS の close が遅れても、別 reader の acquire / release を塞がない。
        for descriptor in descriptors { closeDescriptor(descriptor) }
        return keys.count
    }

    /// ロック内では帳簿だけを更新し、close は必ずロックの外へ持ち出す。
    private func evictOldestIdle() -> Entry? {
        var oldest: (key: UUID, stamp: UInt64)?
        // 毎回 Dictionary.filter のコピーを作らず、64 枠を一度だけ走査する。
        for (key, entry) in entries where entry.users == 0 {
            if let current = oldest, current.stamp <= entry.stamp { continue }
            oldest = (key, entry.stamp)
        }
        guard let oldest else { return nil }
        return entries.removeValue(forKey: oldest.key)
    }

}

/// persistent はロックを通さず、bounded だけが I/O の間 FD を pin する。
final class InputFileDescriptor: @unchecked Sendable {
    private let descriptor: Int32?
    private let cache: FileDescriptorCache?
    private let key = UUID()
    private let reopen: (@Sendable () throws -> Int32)?

    init(takingOwnershipOf descriptor: Int32) {
        self.descriptor = descriptor
        cache = nil
        reopen = nil
    }

    init(takingOwnershipOf descriptor: Int32, cache: FileDescriptorCache = .shared,
         reopen: @escaping @Sendable () throws -> Int32) throws {
        self.descriptor = nil
        self.cache = cache
        self.reopen = reopen
        try cache.adopt(descriptor, key: key)
    }

    deinit {
        if let descriptor { Darwin.close(descriptor) }
        cache?.remove(key: key)
    }

    func withDescriptor<T>(_ body: (Int32) throws -> T) throws -> T {
        // 生 FD を渡した直後に ARC が最後の所有者を解放しないよう I/O 終端まで保持する。
        try withExtendedLifetime(self) {
            if let descriptor { return try body(descriptor) }
            guard let cache, let reopen else { throw KaitoError.io(EBADF) }
            let descriptor = try cache.acquire(key: key, reopen: reopen)
            defer { cache.release(key: key) }
            return try body(descriptor)
        }
    }
}

/// directory の内容変更は許す。ファイルは inode だけでなく元の byte 列の属性も照合する。
struct InputFileIdentity: Sendable {
    private let device: dev_t
    private let inode: ino_t
    private let kind: mode_t
    private let size: off_t
    private let seconds: Int
    private let nanoseconds: Int

    init(descriptor: Int32) throws {
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else { throw KaitoError.io(errno) }
        device = info.st_dev
        inode = info.st_ino
        kind = info.st_mode & S_IFMT
        size = info.st_size
        seconds = info.st_mtimespec.tv_sec
        nanoseconds = info.st_mtimespec.tv_nsec
    }

    func validate(_ descriptor: Int32) throws {
        let current = try Self(descriptor: descriptor)
        guard current.device == device, current.inode == inode, current.kind == kind,
              kind == S_IFDIR || (current.size == size && current.seconds == seconds
                                  && current.nanoseconds == nanoseconds) else {
            throw KaitoError.io(ESTALE)
        }
    }
}
