import Dispatch
import Foundation
import KaitoKit

private func entryData(_ entry: ArchiveEntry, reader: ArchiveReader) throws -> Data {
    if entry.kind == .directory {
        return Data()
    }
    return try reader.read(entry)
}

private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
}

private func elapsedMilliseconds(since start: UInt64, until end: UInt64) -> Double {
    let nanoseconds = end >= start ? end - start : 0
    return Double(nanoseconds) / 1_000_000
}

private struct BenchArguments {
    let archive: String
    let repetitions: Int
    let useMappedData: Bool
    let useRandomAccess: Bool
    let password: String?
}

private func parseBench(_ arguments: [String]) throws -> BenchArguments {
    var positionals: [String] = []
    var useMappedData = false
    var useRandomAccess = false
    var password: String?
    var cursor = ArgumentCursor(arguments)
    while let argument = cursor.next() {
        if argument == "--data" {
            guard !useMappedData else { throw CLIError.usage(usage) }
            useMappedData = true
        } else if argument == "--random" {
            guard !useRandomAccess else { throw CLIError.usage(usage) }
            useRandomAccess = true
        } else if argument == "-p" {
            password = try cursor.value(unlessSet: password)
        } else {
            guard !argument.hasPrefix("-") else { throw CLIError.usage(usage) }
            positionals.append(argument)
        }
    }

    guard (1...2).contains(positionals.count) else {
        throw CLIError.usage(usage)
    }
    let repetitions: Int
    if positionals.count == 2 {
        guard let parsed = Int(positionals[1]), (1...10_000).contains(parsed) else {
            throw CLIError.usage("reps must be between 1 and 10000\n\(usage)")
        }
        repetitions = parsed
    } else {
        repetitions = 5
    }
    return BenchArguments(
        archive: positionals[0],
        repetitions: repetitions,
        useMappedData: useMappedData,
        useRandomAccess: useRandomAccess,
        password: password
    )
}

private struct BenchmarkRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64 = 0x4B61_6974_6F4B_6974

    mutating func next() -> UInt64 {
        // SplitMix64 の合同算術は擬似乱数生成のため意図的に 64 bit で折り返す。
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private func randomBenchmarkEntries(_ entries: [ArchiveEntry]) -> [ArchiveEntry] {
    let sampleLimit = 20
    var generator = BenchmarkRandomNumberGenerator()
    var sample: [ArchiveEntry] = []
    sample.reserveCapacity(min(sampleLimit, entries.count))
    var eligibleCount = 0

    // 全エントリ配列を複製せず、最大 20 件の一様な reservoir sample を作る。
    for entry in entries where entry.kind != .directory {
        eligibleCount += 1 // `entries.count` 以下なので Int の範囲内。
        if sample.count < sampleLimit {
            sample.append(entry)
        } else {
            let replacement = Int.random(in: 0..<eligibleCount, using: &generator)
            if replacement < sampleLimit {
                sample[replacement] = entry
            }
        }
    }
    sample.shuffle(using: &generator)
    return sample
}

func runBench(_ arguments: [String]) throws {
    let parsed = try parseBench(arguments)

    var openTimes: [Double] = []
    var extractTimes: [Double] = []
    openTimes.reserveCapacity(parsed.repetitions)
    extractTimes.reserveCapacity(parsed.repetitions)
    var lastByteCount = 0

    for _ in 0..<parsed.repetitions {
        let openStart = DispatchTime.now().uptimeNanoseconds
        let reader: ArchiveReader
        if parsed.useMappedData {
            // cooViewer の初回 open と同じく、map 作成も Data 経路の時間に含める。
            let mappedData = try Data(
                contentsOf: URL(fileURLWithPath: parsed.archive),
                options: .mappedIfSafe
            )
            reader = try ArchiveReader.open(
                data: mappedData,
                options: ReaderOptions(password: parsed.password)
            )
        } else {
            reader = try openArchive(parsed.archive, password: parsed.password)
        }
        let openEnd = DispatchTime.now().uptimeNanoseconds
        openTimes.append(elapsedMilliseconds(since: openStart, until: openEnd))

        let benchmarkEntries = parsed.useRandomAccess
            ? randomBenchmarkEntries(reader.entries)
            : reader.entries
        var extracted: [Data] = []
        extracted.reserveCapacity(benchmarkEntries.count)
        var byteCount = 0
        let extractStart = DispatchTime.now().uptimeNanoseconds
        for entry in benchmarkEntries {
            let data = try entryData(entry, reader: reader)
            let sum = byteCount.addingReportingOverflow(data.count)
            guard !sum.overflow else {
                throw KaitoError.limitExceeded("benchmark byte count")
            }
            byteCount = sum.partialValue
            extracted.append(data)
        }
        let extractEnd = DispatchTime.now().uptimeNanoseconds
        extractTimes.append(elapsedMilliseconds(since: extractStart, until: extractEnd))
        lastByteCount = byteCount
        withExtendedLifetime(extracted) {}
    }

    print("reps\t\(parsed.repetitions)")
    print(String(format: "open-median-ms\t%.3f", median(openTimes)))
    print(String(format: "extract-median-ms\t%.3f", median(extractTimes)))
    print("bytes\t\(lastByteCount)")
}
