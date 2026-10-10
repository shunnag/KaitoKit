import Foundation
import Darwin

/// perflevel は番号順（0 が最高性能）。名称や特定の製品のコア構成には依存しない。
@_spi(Parallelism) public struct CPUTopology: Sendable, Equatable {
    public struct PerformanceLevel: Sendable, Equatable {
        public let logicalCPUs: Int
        public let physicalCPUs: Int

        public init(logicalCPUs: Int, physicalCPUs: Int) {
            self.logicalCPUs = logicalCPUs
            self.physicalCPUs = physicalCPUs
        }
    }

    public let activeLogicalCPUs: Int
    public let performanceLevels: [PerformanceLevel]

    public init(activeLogicalCPUs: Int, performanceLevels: [PerformanceLevel] = []) {
        let active = max(1, activeLogicalCPUs)
        self.activeLogicalCPUs = active
        self.performanceLevels = performanceLevels.isEmpty || performanceLevels.contains { $0.logicalCPUs <= 0 || $0.physicalCPUs <= 0 }
            ? [.init(logicalCPUs: active, physicalCPUs: active)] : performanceLevels
    }

    public static var current: Self {
        read(integer: systemInteger, fallbackActiveCPUs: ProcessInfo.processInfo.activeProcessorCount)
    }

    /// sysctl の欠落も純粋な入力で検証できる。途中の level が欠けた場合は単一 level に戻す。
    public static func read(integer: (String) -> Int?, fallbackActiveCPUs: Int) -> Self {
        let active = integer("hw.activecpu").flatMap { $0 > 0 ? $0 : nil } ?? fallbackActiveCPUs
        guard let count = integer("hw.nperflevels"), count > 0 else { return .init(activeLogicalCPUs: active) }
        var levels: [PerformanceLevel] = []
        for index in 0..<count {
            guard let logical = integer("hw.perflevel\(index).logicalcpu"), logical > 0,
                  let physical = integer("hw.perflevel\(index).physicalcpu"), physical > 0 else {
                return .init(activeLogicalCPUs: active)
            }
            levels.append(.init(logicalCPUs: logical, physicalCPUs: physical))
        }
        return .init(activeLogicalCPUs: active, performanceLevels: levels)
    }

    private static func systemInteger(_ name: String) -> Int? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        let status = withUnsafeMutableBytes(of: &value) { bytes in
            sysctlbyname(name, bytes.baseAddress, &size, nil, 0)
        }
        guard status == 0, size == 4 || size == 8, value <= UInt64(Int.max) else { return nil }
        return Int(value)
    }
}
