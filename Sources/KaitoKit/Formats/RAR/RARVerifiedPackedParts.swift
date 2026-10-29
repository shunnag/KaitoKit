import Foundation

/// Retains the bytes consumed by the historical pre-decode split-part integrity
/// pass. Decode replays those bytes locally; unchecked (normally final) parts
/// remain on their original source, with their original read/error timing.
enum RARVerifiedPackedParts {
    struct Check {
        let expectedCRC32: UInt32?
        let expectedBlake2sp: [UInt8]?
        let hashKey: Data?
        let mismatchIsWrongPassword: Bool
        let entryIndex: Int
        private var crc = CRC32()
        private var hash: Blake2sp?

        init(crc32: UInt32?, blake2sp: [UInt8]? = nil, hashKey: Data? = nil,
             mismatchIsWrongPassword: Bool = false, entryIndex: Int) {
            self.expectedCRC32 = crc32
            self.expectedBlake2sp = blake2sp
            self.hashKey = hashKey
            self.mismatchIsWrongPassword = mismatchIsWrongPassword
            self.entryIndex = entryIndex
            self.hash = blake2sp == nil ? nil : Blake2sp()
        }

        mutating func update(_ bytes: UnsafeRawBufferPointer) {
            if expectedCRC32 != nil { crc.update(bytes) }
            hash?.update(bytes)
        }

        mutating func finish() throws {
            if let expectedCRC32 {
                let actual = hashKey.map { RAR5ChecksumMAC.crc32(crc.value, hashKey: $0) } ?? crc.value
                guard actual == expectedCRC32 else { try mismatch() }
            }
            if let expectedBlake2sp {
                guard expectedBlake2sp.count == 32 else {
                    throw KaitoError.malformed("RAR5 BLAKE2sp digest is not 32 bytes")
                }
                guard var actual = hash?.finalize() else {
                    throw KaitoError.malformed("RAR5 packed hash state is missing")
                }
                if let hashKey { actual = try RAR5ChecksumMAC.blake2sp(actual, hashKey: hashKey) }
                guard ConstantTime.equals(actual, Data(expectedBlake2sp)) else { try mismatch() }
            }
        }

        private func mismatch() throws -> Never {
            if mismatchIsWrongPassword, hashKey != nil { throw KaitoError.wrongPassword }
            throw KaitoError.checksumMismatch(entry: entryIndex)
        }
    }

    static func prepare(
        segments: [SourceSegment],
        checked: [Bool],
        limits: ReadLimits,
        makeCheck: @escaping (Int) throws -> Check?
    ) throws -> [SourceSegment] {
        var size: UInt64 = 0
        for (segment, needsCheck) in zip(segments, checked) where needsCheck {
            size = try Checked.add(size, segment.length)
        }
        let scanner = Scanner(segments: segments, makeCheck: makeCheck)
        let stream = try EntryStream(decompressor: scanner, length: size,
                                     expectedCRC32: nil, entryIndex: -1, limits: limits)
        let staged: any ByteSource
        do {
            // One cap for the whole logical file, rather than one per volume.
            staged = try SingleFileMaterializer.materialize(
                stream, limits: limits, inMemoryLimit: 4 << 20)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Cache IO/space failures must not introduce a new archive error or
            // mask a later checksum/password failure. Finish the original pass
            // without caching, then retain the old two-read behavior in this mode.
            if let failure = scanner.failure { throw failure }
            var scratch = [UInt8](repeating: 0, count: 256 << 10)
            while !scanner.isFinished {
                try Task.checkCancellation()
                _ = try scratch.withUnsafeMutableBytes { try scanner.read(into: $0) }
            }
            return segments
        }
        var offset: UInt64 = 0
        return zip(segments, checked).map { segment, needsCheck in
            guard needsCheck else { return segment }
            defer { offset += segment.length } // The sum was checked above.
            return SourceSegment(source: staged, offset: offset, length: segment.length)
        }
    }

    /// Visits parts in the same order as the former verification loops, including
    /// metadata checks and zero-byte parts. A failure makes the scanner unusable.
    private final class Scanner: Decompressor {
        private let segments: [SourceSegment]
        private let makeCheck: (Int) throws -> Check?
        private var index = 0
        private var consumed: UInt64 = 0
        private var didBegin = false
        private var check: Check?
        private(set) var failure: Error?
        var isFinished: Bool { index == segments.count }

        init(segments: [SourceSegment], makeCheck: @escaping (Int) throws -> Check?) {
            self.segments = segments
            self.makeCheck = makeCheck
        }

        func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
            if let failure { throw failure }
            guard !buffer.isEmpty else { return 0 }
            do {
                while index < segments.count {
                    let segment = segments[index]
                    if !didBegin {
                        check = try makeCheck(index)
                        didBegin = true
                        if check != nil {
                            let end = try Checked.add(segment.offset, segment.length)
                            guard end <= segment.source.length else { throw KaitoError.truncated }
                        }
                    }
                    if check == nil || consumed == segment.length {
                        try check?.finish()
                        advance()
                        continue
                    }
                    let wanted = Int(min(UInt64(min(buffer.count, 256 << 10)), segment.length - consumed))
                    let count = try segment.source.read(
                        into: UnsafeMutableRawBufferPointer(rebasing: buffer[..<wanted]),
                        at: try Checked.add(segment.offset, consumed))
                    guard count > 0, count <= wanted else { throw KaitoError.truncated }
                    check?.update(UnsafeRawBufferPointer(rebasing: buffer[..<count]))
                    consumed += UInt64(count)
                    if consumed == segment.length {
                        try check?.finish()
                        advance()
                    }
                    return count
                }
                return 0
            } catch {
                failure = error
                throw error
            }
        }

        private func advance() {
            index += 1
            consumed = 0
            didBegin = false
            check = nil
        }
    }
}
