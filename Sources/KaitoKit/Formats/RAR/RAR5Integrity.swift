import Foundation

// Provenance / algorithm references:
// - RARLab, "RAR 5.0 archive format" technote (file hash records and
//   password-dependent checksum transformation), https://www.rarlab.com/technote.htm
// - RFC 7693 and the BLAKE2 specification for the underlying BLAKE2sp digest.
// No archive decoder source was consulted.

/// Adds incremental BLAKE2sp verification to any RAR5 decompressor without
/// forcing stored entries off their direct-copy path unless they actually have
/// a BLAKE2sp extra record.
final class RAR5Blake2spDecompressor: Decompressor {
    private let base: any Decompressor
    private let expected: Data
    private let hashKey: Data?
    private let entryIndex: Int
    private let mismatchIsWrongPassword: Bool
    private var hash = Blake2sp()
    private var verificationFinished = false

    var isFinished: Bool { base.isFinished }

    init(
        base: any Decompressor,
        expected: [UInt8],
        hashKey: Data?,
        entryIndex: Int,
        mismatchIsWrongPassword: Bool
    ) throws {
        guard expected.count == 32 else {
            throw KaitoError.malformed("RAR5 BLAKE2sp digest is not 32 bytes")
        }
        self.base = base
        self.expected = Data(expected)
        self.hashKey = hashKey
        self.entryIndex = entryIndex
        self.mismatchIsWrongPassword = mismatchIsWrongPassword
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let count = try base.read(into: buffer)
        guard count >= 0, count <= buffer.count else {
            throw KaitoError.malformed("RAR5 hash wrapper received an invalid byte count")
        }
        if count > 0 {
            hash.update(UnsafeRawBufferPointer(rebasing: buffer[..<count]))
        }
        return count
    }

    func verify() throws {
        guard !verificationFinished else { return }
        guard base.isFinished else { throw KaitoError.truncated }
        var actual = hash.finalize()
        if let hashKey {
            actual = try RAR5ChecksumMAC.blake2sp(actual, hashKey: hashKey)
        }
        guard RARConstantTime.equals(actual, expected) else {
            if mismatchIsWrongPassword { throw KaitoError.wrongPassword }
            throw KaitoError.checksumMismatch(entry: entryIndex)
        }
        verificationFinished = true
    }
}
