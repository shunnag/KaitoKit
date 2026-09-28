import Foundation
@testable import KaitoKit

enum PayloadMutationBatchOutcome: Sendable {
    case completed(Int)
    case unexpected(String)
}

enum PayloadMutationTestError: Error, Sendable {
    case entryStreamMadeNoProgress
    case entryStreamExceededIterationBound
    case decoderMadeNoProgress
    case decoderExceededIterationBound
}

final class BoundedPayloadMutationBatch: @unchecked Sendable {
    private let operation: @Sendable () -> PayloadMutationBatchOutcome
    private let completion = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var outcome: PayloadMutationBatchOutcome?

    init(operation: @escaping @Sendable () -> PayloadMutationBatchOutcome) {
        self.operation = operation
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = operation()
            lock.lock()
            outcome = result
            lock.unlock()
            completion.signal()
        }
    }

    func wait(timeout: DispatchTime) -> PayloadMutationBatchOutcome? {
        guard completion.wait(timeout: timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }
}

enum PayloadMutationTestSupport {
    static func drain(
        _ stream: EntryStream,
        bufferSize: Int = 1_021,
        maximumIterations: Int = 1_000_000
    ) throws {
        precondition(bufferSize > 0 && maximumIterations > 0)
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var iterations = 0
        while stream.remaining > 0 {
            let count = try buffer.withUnsafeMutableBytes {
                try stream.read(into: $0)
            }
            guard count > 0 else {
                throw PayloadMutationTestError.entryStreamMadeNoProgress
            }
            iterations += 1
            guard iterations <= maximumIterations else {
                throw PayloadMutationTestError.entryStreamExceededIterationBound
            }
        }
    }

    static func drain(
        _ decoder: any Decompressor,
        bufferSize: Int = 1_021,
        maximumIterations: Int = 1_000_000
    ) throws {
        precondition(bufferSize > 0 && maximumIterations > 0)
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var iterations = 0
        while !decoder.isFinished {
            let count = try buffer.withUnsafeMutableBytes {
                try decoder.read(into: $0)
            }
            guard count > 0 || decoder.isFinished else {
                throw PayloadMutationTestError.decoderMadeNoProgress
            }
            iterations += 1
            guard iterations <= maximumIterations else {
                throw PayloadMutationTestError.decoderExceededIterationBound
            }
        }
    }
}
