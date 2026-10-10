import Foundation
import Synchronization
@testable import KaitoKit
import XCTest

final class ReaderOptionsTests: XCTestCase {
    func testDecodeThreadDefaultsAndClampingOnInitAndAssignment() {
        XCTAssertNil(ReaderOptions().decodeThreads)
        XCTAssertEqual(ReaderOptions().decodePowerPolicy, .reduceInLowPowerMode)
        XCTAssertEqual(ReaderOptions.decodeThreadsRange, 1...1024)
        for (value, expected) in [(Int.min, 1), (0, 1), (1, 1), (36, 36), (1024, 1024), (Int.max, 1024)] {
            var options = ReaderOptions(decodeThreads: value)
            XCTAssertEqual(options.decodeThreads, expected)
            options.decodeThreads = value
            XCTAssertEqual(options.decodeThreads, expected)
            options.decodeThreads = nil
            XCTAssertNil(options.decodeThreads)
        }
    }

    func testExplicitThreadCountDoesNotResolvePowerPolicy() {
        ReaderOptions.$testingAutomaticThreads.withValue({ _ in XCTFail("explicit threads must bypass automatic resolution"); return 1 }) {
            let options = ReaderOptions(decodeThreads: 36, decodePowerPolicy: .reduceInLowPowerModeOrThermalPressure).resolvingDecodeThreads()
            XCTAssertEqual(options.resolvedDecodeThreads, 36)
        }
    }

    func testAutomaticSnapshotIsResolvedOnceAtOpenAndPreservedByReopen() throws {
        let calls = Mutex(0)
        let bytes = try CompressedTarFramingTestSupport.bzip2(Data("snapshot".utf8)).data
        let reader = try ReaderOptions.$testingAutomaticThreads.withValue({ policy in
            XCTAssertEqual(policy, .reduceInLowPowerMode)
            return calls.withLock { $0 += 1; return 2 }
        }) {
            try ArchiveReader.open(data: bytes)
        }
        XCTAssertEqual(calls.withLock { $0 }, 1)
        try ReaderOptions.$testingAutomaticThreads.withValue({ _ in XCTFail("open snapshot must survive reads and reopen"); return 64 }) {
            XCTAssertEqual(try reader.read(reader.entries[0]), Data("snapshot".utf8))
            let second = try reader.reopen()
            XCTAssertEqual(try second.read(second.entries[0]), Data("snapshot".utf8))
            let third = try second.reopen()
            XCTAssertEqual(try third.read(third.entries[0]), Data("snapshot".utf8))
        }
    }

    func testReadLimitsParallelMemoryUsesHalfPhysicalMemoryOrOverride() {
        XCTAssertNil(ReadLimits().parallelDecodeMemory)
        XCTAssertEqual(ReadLimits().resolvedParallelDecodeMemory(physicalMemory: 64 << 30), 32 << 30)
        XCTAssertEqual(ReadLimits(parallelDecodeMemory: 123).resolvedParallelDecodeMemory(physicalMemory: 64 << 30), 123)
        XCTAssertEqual(ReadLimits(parallelDecodeMemory: 0).resolvedParallelDecodeMemory(), 0)
        XCTAssertEqual(ReadLimits(parallelDecodeMemory: .max).resolvedParallelDecodeMemory(), Int.max)
    }
}
