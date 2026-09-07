import Darwin

/// Exactly bounded packed-member bytes with optional zero lookahead storage.
/// The allocation is fallible and owned for the full decoder lifetime, which
/// lets MSBFirstBitReader borrow a stable raw pointer without Array/COW work.
final class LHAPackedInputStorage {
    let bytes: UnsafeMutablePointer<UInt8>
    let logicalCount: Int
    let physicalCount: Int
    private let allocationCount: Int

    init(
        source: any ByteSource,
        offset: UInt64,
        count logicalCount: Int,
        sentinelCount: Int = 0
    ) throws {
        guard logicalCount >= 0,
              sentinelCount >= 0,
              logicalCount <= Int.max - sentinelCount else {
            throw KaitoError.limitExceeded("LHA compressed input size")
        }
        let physicalCount = logicalCount + sentinelCount
        let allocationCount = max(1, physicalCount)
        guard let raw = malloc(allocationCount) else {
            throw KaitoError.limitExceeded("unable to allocate LHA compressed input")
        }
        let bytes = raw.bindMemory(to: UInt8.self, capacity: allocationCount)
        bytes.initialize(repeating: 0, count: allocationCount)

        do {
            var filled = 0
            while filled < logicalCount {
                let requested = logicalCount - filled
                let actual = try source.read(
                    into: UnsafeMutableRawBufferPointer(
                        start: bytes.advanced(by: filled),
                        count: requested
                    ),
                    at: try Checked.add(offset, UInt64(filled))
                )
                guard actual > 0 else { throw KaitoError.truncated }
                guard actual <= requested else {
                    throw KaitoError.malformed(
                        "ByteSource returned an invalid byte count"
                    )
                }
                filled += actual
            }
        } catch {
            bytes.deinitialize(count: allocationCount)
            free(raw)
            throw error
        }

        self.bytes = bytes
        self.logicalCount = logicalCount
        self.physicalCount = physicalCount
        self.allocationCount = allocationCount
    }

    deinit {
        bytes.deinitialize(count: allocationCount)
        free(UnsafeMutableRawPointer(bytes))
    }
}
