import Foundation

// Compile alongside Core/CRC16.swift, with -O -I Sources/CBzip2.
// Cumulative updates and a printed checksum keep every measured pass observable.
@main
struct CRC16Bench {
    @inline(never)
    static func run(_ input: UnsafeRawBufferPointer, repetitions: Int) -> UInt16 {
        var crc = CRC16()
        for _ in 0..<repetitions { crc.update(input) }
        return crc.value
    }

    static func main() {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var source: Data?
        if arguments.first == "--file", arguments.count >= 2 {
            source = try! Data(contentsOf: URL(fileURLWithPath: arguments[1]), options: .mappedIfSafe)
            arguments.removeFirst(2)
        }
        let lengths = arguments.compactMap(Int.init)
        for count in lengths.isEmpty ? [64, 128, 256, 512, 1024, 4096, 65536, 1048576, 16777216] : lengths {
            var random: UInt64 = 0xC16A001
            precondition(count > 0 && (source == nil || count <= source!.count))
            let bytes = source.map { Array($0.prefix(count)) } ?? (0..<count).map { _ -> UInt8 in
                random = random &* 6364136223846793005 &+ 1
                return UInt8(truncatingIfNeeded: random >> 32)
            }
            let reps = max(8, min(1000000, 268435456 / max(1, count)))
            bytes.withUnsafeBytes { input in
                let warmup = run(input, repetitions: 1)
                var times = [Double]()
                var result: UInt16 = 0
                for _ in 0..<7 {
                    let start = DispatchTime.now().uptimeNanoseconds
                    result ^= run(input, repetitions: reps)
                    times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
                }
                let seconds = times.sorted()[times.count / 2]
                print("bytes=\(count) reps=\(reps) median_s=\(seconds) GB/s=\(Double(count) * Double(reps) / seconds / 1e9) crc=\(result) warmup=\(warmup)")
            }
        }
    }
}
