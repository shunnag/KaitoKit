import Foundation

// Compile with -O alongside the actual Core/Blake2.swift, Core/CRC64.swift and
// the ZipCryptoKeys portion of Formats/Zip/ZipCrypto.swift (see run.py).
// Repeated updates, a fresh cipher per pass and printed results prevent elision.
@main
struct HotLoopBench {
    @inline(never)
    static func blake(_ input: UnsafeRawBufferPointer, _ repetitions: Int) -> Data {
        var hash = Blake2sp()
        for _ in 0..<repetitions { hash.update(input) }
        return hash.finalize()
    }

    @inline(never)
    static func crc(_ input: UnsafeRawBufferPointer, _ repetitions: Int) -> UInt64 {
        var hash = CRC64()
        for _ in 0..<repetitions { hash.update(input) }
        return hash.value
    }

    @inline(never)
    static func zip(_ input: UnsafeMutableRawBufferPointer, _ repetitions: Int) -> UInt64 {
        var result: UInt64 = 0
        for _ in 0..<repetitions {
            var keys = ZipCryptoKeys(password: "wave2 benchmark")
            keys.decryptInPlace(input)
            result &+= UInt64(input[0]) &+ UInt64(input[input.count - 1])
        }
        return result
    }

    static func main() {
        let count = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 16_777_216
        let repetitions = max(1, 134_217_728 / count)
        var random: UInt64 = 0xCA170002
        var bytes = (0..<count).map { _ -> UInt8 in
            random = random &* 6364136223846793005 &+ 1
            return UInt8(truncatingIfNeeded: random >> 32)
        }
        for name in ["BLAKE2sp", "CRC64", "ZipCrypto"] {
            var times = [Double]()
            var result = ""
            for sample in 0..<8 {
                let start = DispatchTime.now().uptimeNanoseconds
                bytes.withUnsafeMutableBytes { input in
                    switch name {
                    case "BLAKE2sp": result = blake(UnsafeRawBufferPointer(input), repetitions).base64EncodedString()
                    case "CRC64": result = String(crc(UnsafeRawBufferPointer(input), repetitions))
                    default: result = String(zip(input, repetitions))
                    }
                }
                let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
                if sample > 0 { times.append(seconds) }
            }
            let median = times.sorted()[times.count / 2]
            print("\(name) bytes=\(count) reps=\(repetitions) median_s=\(median) GB/s=\(Double(count * repetitions) / median / 1e9) result=\(result)")
        }
    }
}
