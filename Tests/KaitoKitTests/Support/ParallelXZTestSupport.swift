internal import Foundation
@testable internal import KaitoKit
internal import XCTest

enum ParallelXZTestSupport {
    static let blockSize = 65_536
    static let fixture = "tar-golden/inputs/gyoshuku-header-blocks.tar.xz"

    static func requireXZ() throws {
        try ZipTestSupport.requireExecutable(ZipTestSupport.xzPath)
    }

    static func random(_ count: Int) -> Data {
        var state: UInt64 = 0x189c82f0
        return Data((0..<count).map { _ -> UInt8 in
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        })
    }

    static func compress(_ bytes: Data, threads: Int = 0, blockSize: Int? = blockSize,
                         filters: [String] = []) throws -> Data {
        let tool = ZipTestSupport.xzPath
        var arguments = ["-c", "-1", "-T\(threads)"]
        if let blockSize { arguments.append("--block-size=\(blockSize)") }
        arguments.append(contentsOf: filters)
        return try ZipTestSupport.checkedRun(tool, arguments: arguments, standardInput: bytes).standardOutput
    }

    static func layout(_ bytes: Data) throws -> XZStreamLayout {
        try XZResourceValidator.validate(source: DataByteSource(bytes), dictionaryLimit: ReadLimits().maxDictionarySize)
    }

    static func compare(_ bytes: Data, workers: Int = 8, target: Int = blockSize,
                        file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let source = DataByteSource(bytes)
        let serial = try XZDecompressor(source: source, limits: ReadLimits())
        let parallel = try ParallelXZDecompressor(source: source, limits: ReadLimits(), workers: workers, targetJobOutput: target)
        XCTAssertEqual(serial.isFinished, parallel.isFinished, file: file, line: line)
        let expected = try drain(serial, bufferSize: 131_071)
        var output: [UInt8] = [], buffer = [UInt8](repeating: 0, count: 300_000)
        XCTAssertEqual(try parallel.read(into: UnsafeMutableRawBufferPointer(start: nil, count: 0)), 0, file: file, line: line)
        while !parallel.isFinished {
            let count = try buffer.withUnsafeMutableBytes { try parallel.read(into: $0) }
            XCTAssertLessThanOrEqual(count, 256 * 1_024, file: file, line: line)
            guard count > 0 || parallel.isFinished else { throw KaitoError.malformed("XZ test made no progress") }
            output.append(contentsOf: buffer.prefix(count))
        }
        XCTAssertEqual(try buffer.withUnsafeMutableBytes { try parallel.read(into: $0) }, 0, file: file, line: line)
        XCTAssertEqual(serial.isFinished, parallel.isFinished, file: file, line: line)
        XCTAssertEqual(Data(output), expected, file: file, line: line)
        return expected
    }

    static func waitForAbandonment(_ diagnostics: ParallelXZDecompressor.Diagnostics,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date(timeIntervalSinceNow: 2)
        while diagnostics.liveWorkers > 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertEqual(diagnostics.liveWorkers, 0, file: file, line: line)
    }
}
