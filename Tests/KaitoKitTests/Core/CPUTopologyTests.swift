import Foundation
@_spi(Parallelism) @testable import KaitoKit
import XCTest

final class CPUTopologyTests: XCTestCase {
    func testSysctlsUsePerformanceLevelOrdinalsIncludingThreeLevels() {
        let values = ["hw.activecpu": 36, "hw.nperflevels": 3,
            "hw.perflevel0.logicalcpu": 20, "hw.perflevel0.physicalcpu": 10,
            "hw.perflevel1.logicalcpu": 12, "hw.perflevel1.physicalcpu": 6,
            "hw.perflevel2.logicalcpu": 4, "hw.perflevel2.physicalcpu": 4]
        let topology = CPUTopology.read(integer: { values[$0] }, fallbackActiveCPUs: 1)
        XCTAssertEqual(topology.activeLogicalCPUs, 36)
        XCTAssertEqual(topology.performanceLevels.map(\.logicalCPUs), [20, 12, 4])
        XCTAssertEqual(topology.performanceLevels.map(\.physicalCPUs), [10, 6, 4])
    }

    func testMissingOrInvalidSysctlsFallBackToSingleLevel() {
        for values in [[:], ["hw.activecpu": 0], ["hw.nperflevels": -1],
            ["hw.activecpu": 16, "hw.nperflevels": 2, "hw.perflevel0.logicalcpu": 12,
             "hw.perflevel0.physicalcpu": 12, "hw.perflevel1.logicalcpu": 4]] {
            let topology = CPUTopology.read(integer: { values[$0] }, fallbackActiveCPUs: 16)
            XCTAssertEqual(topology, .init(activeLogicalCPUs: 16))
        }
        XCTAssertEqual(CPUTopology.read(integer: { _ in nil }, fallbackActiveCPUs: 0).activeLogicalCPUs, 1)
        XCTAssertEqual(CPUTopology(activeLogicalCPUs: 5,
            performanceLevels: [.init(logicalCPUs: 0, physicalCPUs: 1)]).performanceLevels,
            [.init(logicalCPUs: 5, physicalCPUs: 5)])
    }

    func testOneTwoAndThreeLevelsWithPowerAndThermalPolicies() {
        for (n, counts, reduced) in [(1, [1], 1), (9, [9], 5), (16, [12, 4], 4),
                                      (36, [20, 12, 4], 4), (9, [3, 6], 5)] {
            let topology = CPUTopology(activeLogicalCPUs: n,
                performanceLevels: counts.map { .init(logicalCPUs: $0, physicalCPUs: $0) })
            for policy in [DecodePowerPolicy.reduceInLowPowerMode, .reduceInLowPowerModeOrThermalPressure, .alwaysUseAllCores] {
                for thermal in [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical] {
                    for lowPower in [false, true] {
                        let shouldReduce = policy != .alwaysUseAllCores && (lowPower ||
                            (policy == .reduceInLowPowerModeOrThermalPressure && (thermal == .serious || thermal == .critical)))
                        XCTAssertEqual(ReaderOptions.automaticDecodeThreads(topology: topology, physicalMemory: 128 << 30,
                            lowPowerMode: lowPower, thermalState: thermal, policy: policy), shouldReduce ? reduced : n)
                    }
                }
            }
        }
    }

    func testMemoryGiBClampAndAutomaticCountsHaveNoFixedCap() {
        for (memory, expected) in [(UInt64(0), 1), ((1 << 30) - 1, 1), (3 << 30, 3),
                                   ((4 << 30) - 1, 3), (64 << 30, 64), (2048 << 30, 1536)] {
            XCTAssertEqual(ReaderOptions.automaticDecodeThreads(topology: .init(activeLogicalCPUs: 1536),
                physicalMemory: memory, lowPowerMode: false, thermalState: .nominal, policy: .reduceInLowPowerMode), expected)
        }
    }

    func testCurrentTopologyAndAutomaticRequest() {
        let topology = CPUTopology.current
        XCTAssertGreaterThan(topology.activeLogicalCPUs, 0)
        XCTAssertEqual(LeafDecodePool.shared.capacity, topology.activeLogicalCPUs)
        let process = ProcessInfo.processInfo
        let expected = ReaderOptions.automaticDecodeThreads(topology: topology, physicalMemory: process.physicalMemory,
            lowPowerMode: process.isLowPowerModeEnabled, thermalState: process.thermalState, policy: .reduceInLowPowerMode)
        XCTAssertEqual(ReaderOptions.automaticDecodeThreads(), expected)
        print("DecodeParallel current: active=\(topology.activeLogicalCPUs), levels=\(topology.performanceLevels.map(\.logicalCPUs)), automatic=\(expected)")
    }
}
