import CommonCrypto
import Foundation
import Synchronization
@testable import KaitoKit
import XCTest

final class HotLoopRegressionTests: XCTestCase {
    // BLAKE2 vectors generated independently with Python hashlib's tree API;
    // XXH32 follows the public xxhash_spec.md, anchored by the existing CLI vectors.
    func testXXH32AndBlake2BoundaryVectorsAndRandomStreaming() throws {
        let vectors: [(Int, UInt32, String, String)] = [
            (0, 0x02cc5d05, "69217a3079908094e11121d042354a7c1f55b6482ca1a51e1b250dfd1ed0eef9", "dd0e891776933f43c7d032b08a917e25741f8aa9a12c12e1cac8801500f2ca4f"),
            (1, 0xcf65b03e, "e34d74dbaf4ff4c6abd871cc220451d2ea2648846c7757fbaac82fe51ad64bea", "a6b9eecc25227ad788c99d3f236debc8da408849e9a5178978727a81457f7239"),
            (63, 0x4c80747b, "e57cb79487dd57902432b250733813bd96a84efce59f650fac26e6696aefafc3", "1024c940be7341449b5010522b509f65bbdc1287b455c2bb7f72b2c92fd0d189"),
            (64, 0x31120435, "56f34e8b96557e90c1f24b52d0c89d51086acf1b00f634cf1dde9233b8eaaa3e", "52603b6cbfad4966cb044cb267568385cf35f21e6c45cf30aed19832cb51e9f5"),
            (65, 0xa4da78a4, "1b53ee94aaf34e4b159d48de352c7f0661d0a40edff95a0b1639b4090e974472", "fff24d3cc729d395daf978b0157306cb495797e6c8dca1731d2f6f81b849baae"),
            (127, 0xf07a1b8b, "f18417b39d617ab1c18fdf91ebd0fc6d5516bb34cf39364037bce81fa04cecb1", "a626543c271fccc3e4450b48d66bc9cbdeb25e5d077a6213cd90cbbd0fd22076"),
            (128, 0x6d6194b7, "1fa877de67259d19863a2a34bcc6962a2b25fcbf5cbecd7ede8f1fa36688a796", "05cf3a90049116dc60efc31536aaa3d167762994892876dcb7ef3fbecd7449c0"),
            (129, 0x6572cb97, "5bd169e67c82c2c2e98ef7008bdf261f2ddf30b1c00f9e7f275bb3e8a28dc9a2", "ccd61c926cc1e5e9128c021c0c6e92aefc4ffbde394dd6f3b7d87a8ced896014"),
        ]
        for (count, xxh, s, sp) in vectors {
            let bytes = (0..<count).map { UInt8(truncatingIfNeeded: $0) }
            XCTAssertEqual(XXH32.digest(bytes), xxh)
            XCTAssertEqual(Blake2s.checksum(Data(bytes)), try Hex.data(s))
            XCTAssertEqual(Blake2sp.checksum(Data(bytes)), try Hex.data(sp))
        }
        var random = HotLoopRandom()
        for iteration in 0..<160 {
            let count = iteration < vectors.count ? vectors[iteration].0 : random.int(16_385)
            let bytes = (0..<count).map { _ in UInt8(truncatingIfNeeded: random.next()) }
            let expectedS = Blake2s.checksum(Data(bytes))
            let expectedSP = Blake2sp.checksum(Data(bytes))
            let expectedXXH = XXH32.digest(bytes)
            var s = Blake2s(), sp = Blake2sp(), xxh = XXH32()
            var offset = 0
            while offset < count {
                let end = min(count, offset + 1 + random.int(1_025))
                // Nonzero-start slices exercise unaligned pointer views.
                let view = bytes[offset..<end]
                view.withUnsafeBytes { s.update($0); sp.update($0) }
                xxh.update(view)
                s.update([]); sp.update([]); xxh.update(bytes[0..<0])
                offset = end
            }
            XCTAssertEqual(s.finalize(), expectedS, "length \(count)")
            XCTAssertEqual(sp.finalize(), expectedSP, "length \(count)")
            XCTAssertEqual(xxh.value, expectedXXH, "length \(count)")
            XCTAssertEqual(s.finalize(), expectedS)
            XCTAssertEqual(sp.finalize(), expectedSP)
        }
        // Hash values remain independent when copied, including buffered data.
        var s = Blake2s(), sp = Blake2sp()
        s.update([1]); sp.update([1])
        var sCopy = s, spCopy = sp
        s.update([2]); sp.update([2]); sCopy.update([3]); spCopy.update([3])
        XCTAssertEqual(s.finalize(), Blake2s.checksum(Data([1, 2])))
        XCTAssertEqual(sCopy.finalize(), Blake2s.checksum(Data([1, 3])))
        XCTAssertEqual(sp.finalize(), Blake2sp.checksum(Data([1, 2])))
        XCTAssertEqual(spCopy.finalize(), Blake2sp.checksum(Data([1, 3])))
    }

    func testLZ4OverlappingMatchesAndExactReferenceErrors() throws {
        for distance in 1...20 {
            let seed = (0..<distance).map { UInt8($0 + 65) }
            for count in [4, 7, 8, 9, 15, 16, 17, 31, 32, 33, 255, 1_024] {
                for prefixCount in [0, distance / 2, distance] {
                    let history = Array(seed.prefix(distance - prefixCount))
                    let block = matchBlock(literals: Array(seed.suffix(prefixCount)), distance: distance, count: count)
                    assertLZ4(block, history: history, maximum: count + prefixCount + 5)
                    assertLZ4(block, history: history, maximum: count + prefixCount + 4)
                    for end in 0..<block.count { assertLZ4(Array(block.prefix(end)), history: history, maximum: 2_048) }
                }
            }
        }
        var random = HotLoopRandom()
        for _ in 0..<3_000 {
            let bytes = (0..<random.int(80)).map { _ in UInt8(truncatingIfNeeded: random.next()) }
            let history = (0..<random.int(24)).map { _ in UInt8(truncatingIfNeeded: random.next()) }
            assertLZ4(bytes, history: history, maximum: random.int(200))
        }
        assertLZ4([0], history: [], maximum: -1)
        assertLZ4([0], history: Array(repeating: 0, count: 65_537), maximum: 0)
    }

    func testLZ4LinkedLargeMatchesAcross64KiBHistoryAndBufferGrowth() throws {
        let history = (0..<65_536).map { UInt8(truncatingIfNeeded: $0 * 73 + 19) }
        let blocks = [matchBlock(literals: [], distance: 65_535, count: 200_003),
                      matchBlock(literals: [1, 2, 3], distance: 17, count: 73),
                      matchBlock(literals: [], distance: 65_535, count: 210_009)]
        var expected = history, retained = history
        var frame: [UInt8] = [4, 34, 77, 24, 0x40, 0x60]
        frame.append(UInt8(truncatingIfNeeded: XXH32.digest([0x40, 0x60]) >> 8))
        frame += leWord(UInt32(history.count) | 0x8000_0000) + history
        for block in blocks {
            let output = try LZ4Reference.decode(block, history: retained, maximumSize: 1_048_576)
            expected += output
            retained = Array((retained + output).suffix(65_536))
            frame += leWord(UInt32(block.count)) + block
        }
        frame += [0, 0, 0, 0]
        let decoder = try LZ4FrameDecompressor(source: DataByteSource(Data(frame)))
        var result: [UInt8] = [], scratch = [UInt8](repeating: 0, count: 997)
        while true {
            let count = try scratch.withUnsafeMutableBytes { try decoder.read(into: $0) }
            if count == 0 { break }
            result += scratch.prefix(count)
        }
        XCTAssertEqual(result, expected)
    }

    func testAESCBCSingleRangeRandomReadsAndConcurrentReads() async throws {
        var random = HotLoopRandom()
        for keySize in [16, 32] {
            let key = Data((0..<keySize).map { UInt8($0 * 3) })
            let iv = Data((0..<16).map { UInt8($0 * 7) })
            let plain = Data((0..<300_016).map { UInt8(truncatingIfNeeded: $0 * 29) })
            let ciphertext = try cbc(plain, key: key, iv: iv, operation: CCOperation(kCCEncrypt))
            let full = try cbc(ciphertext, key: key, iv: iv, operation: CCOperation(kCCDecrypt))
            XCTAssertEqual(full, plain)
            let source = HotLoopCountingSource(data: Data(repeating: 71, count: 7) + ciphertext)
            let reader = AESCBCRandomAccess(source: source, ciphertextOffset: 7, length: UInt64(plain.count - 3),
                key: key, iv: Array(iv), invalidRangeMessage: "test AES range", decryptECB: { blocks, key in
                    try CommonCryptoPrimitives.aesECBDecrypt(blocks: blocks, key: key)
                })
            for iteration in 0..<100 {
                let offset = iteration < 33 ? iteration : random.int(plain.count - 3)
                let length = iteration == 0 ? 300_000 : 1 + random.int(4_097)
                var output = [UInt8](repeating: 0, count: length)
                let before = source.calls.withLock { $0 }
                let count = try output.withUnsafeMutableBytes { try reader.read(into: $0, at: UInt64(offset)) }
                XCTAssertEqual(source.calls.withLock { $0 }, before + 1)
                XCTAssertEqual(count, min(length, 256 * 1_024, plain.count - 3 - offset))
                XCTAssertEqual(Data(output.prefix(count)), full.subdata(in: offset..<(offset + count)))
            }
            let results = try await withThrowingTaskGroup(of: Bool.self) { group in
                for index in 0..<32 {
                    group.addTask {
                        let offset = index * 127
                        var bytes = [UInt8](repeating: 0, count: 1_031)
                        let count = try bytes.withUnsafeMutableBytes { try reader.read(into: $0, at: UInt64(offset)) }
                        return Data(bytes.prefix(count)) == full.subdata(in: offset..<(offset + count))
                    }
                }
                var valid = true
                for try await result in group { valid = valid && result }
                return valid
            }
            XCTAssertTrue(results)
        }
    }

    func testWinZipAESCTRCarriesAndCopiesMatchByteReference() throws {
        for keySize in [16, 24, 32] {
            let key = Data((0..<keySize).map { UInt8($0 * 5) })
            let input = Data((0..<97).map { UInt8(truncatingIfNeeded: $0 * 29) })
            for (low, high) in [(UInt64(0), UInt64(0)), (0xffff_fffd, 0), (UInt64.max - 2, 0),
                                (UInt64.max - 2, 0xffff_ffff), (UInt64.max - 10, UInt64.max)] {
                var ctr = try WinZipAESCTR(encryptionKey: key, counterLow: low, counterHigh: high)
                let expected = try ctrReference(input, key: key, low: low, high: high)
                var split = Data()
                for range in [0..<3, 3..<16, 16..<33, 33..<97] {
                    split += try ctr.transform(input.subdata(in: range))
                }
                XCTAssertEqual(split, expected)
                var original = try WinZipAESCTR(encryptionKey: key, counterLow: low, counterHigh: high)
                _ = try original.transform(input.prefix(3))
                var copy = original
                XCTAssertEqual(try original.transform(input.dropFirst(3)), Data(expected.dropFirst(3)))
                XCTAssertEqual(try copy.transform(input.dropFirst(3)), Data(expected.dropFirst(3)))
            }
            var exhausted = try WinZipAESCTR(encryptionKey: key, counterLow: UInt64.max, counterHigh: UInt64.max)
            XCTAssertThrowsError(try exhausted.transform(Data([0]))) {
                XCTAssertEqual($0 as? KaitoError, .limitExceeded("WinZip AES-CTR counter exhausted"))
            }
            let large = Data(repeating: 19, count: 256 * 1_024 + 33)
            var ctr = try WinZipAESCTR(encryptionKey: key)
            XCTAssertEqual(try ctr.transform(large), try ctrReference(large, key: key, low: 0, high: 0))
        }
    }

    private func cbc(_ input: Data, key: Data, iv: Data, operation: CCOperation) throws -> Data {
        var output = Data(count: input.count), written = 0
        let status = key.withUnsafeBytes { k in iv.withUnsafeBytes { v in input.withUnsafeBytes { i in
            output.withUnsafeMutableBytes { o in
                CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(0), k.baseAddress, key.count,
                        v.baseAddress, i.baseAddress, input.count, o.baseAddress, o.count, &written)
            }
        } } }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        XCTAssertEqual(written, input.count)
        return output
    }

    private func ctrReference(_ input: Data, key: Data, low: UInt64, high: UInt64) throws -> Data {
        var counter = (0..<8).map { UInt8(truncatingIfNeeded: low >> ($0 * 8)) }
        counter += (0..<8).map { UInt8(truncatingIfNeeded: high >> ($0 * 8)) }
        var blocks: [UInt8] = []
        for _ in stride(from: 0, to: input.count, by: 16) {
            for byte in 0..<16 {
                counter[byte] &+= 1
                if counter[byte] != 0 { break }
            }
            blocks += counter
        }
        let stream = try CommonCryptoPrimitives.aesECBEncrypt(blocks: blocks, key: key)
        return Data(zip(input, stream).map { $0 ^ $1 })
    }

    private func leWord(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
    private func matchBlock(literals: [UInt8], distance: Int, count: Int) -> [UInt8] {
        var bytes = [UInt8(min(15, literals.count) << 4 | min(15, count - 4))]
        func extensionBytes(_ length: Int) -> [UInt8] {
            var result: [UInt8] = [], extra = length - 15
            while extra >= 255 { result.append(255); extra -= 255 }
            result.append(UInt8(extra))
            return result
        }
        if literals.count >= 15 { bytes += extensionBytes(literals.count) }
        bytes += literals + [UInt8(truncatingIfNeeded: distance), UInt8(truncatingIfNeeded: distance >> 8)]
        if count - 4 >= 15 { bytes += extensionBytes(count - 4) }
        return bytes + [0x50, 91, 92, 93, 94, 95]
    }
    private func assertLZ4(_ input: [UInt8], history: [UInt8], maximum: Int,
                           file: StaticString = #filePath, line: UInt = #line) {
        func run(_ decoder: () throws -> [UInt8]) -> Result<[UInt8], KaitoError> {
            do { return .success(try decoder()) }
            catch { return .failure(error as! KaitoError) }
        }
        XCTAssertEqual(run { try LZ4BlockDecoder.decode(input, history: history, maximumSize: maximum) },
                       run { try LZ4Reference.decode(input, history: history, maximumSize: maximum) },
                       "input \(input), history \(history.count), max \(maximum)", file: file, line: line)
    }
}

private struct HotLoopRandom {
    private var state: UInt64 = 0x2f1d_c357_911a_082b
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state ^ (state >> 32)
    }
    mutating func int(_ upper: Int) -> Int { Int(next() % UInt64(upper)) }
}
private final class HotLoopCountingSource: ByteSource {
    let data: Data
    let calls = Mutex(0)
    var length: UInt64 { UInt64(data.count) }
    init(data: Data) { self.data = data }
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        calls.withLock { $0 += 1 }
        return try DataByteSource(data).read(into: buffer, at: offset)
    }
}

// The pre-optimization byte decoder models both byte output and error order.
// Public LZ4 Block Format Description, revised 2022-07-31.
// The enclosing frame supplies the maximum decoded size and up to 64 KiB of
// preceding decoded bytes. External dictionaries are not accepted by the frame.
private enum LZ4Reference {
    static func decode(_ input: [UInt8], history: [UInt8], maximumSize: Int) throws -> [UInt8] {
        guard maximumSize >= 0, history.count <= 65_536 else {
            throw KaitoError.malformed("LZ4 block bounds")
        }
        var cursor = 0
        var output: [UInt8] = []
        // Small malformed blocks must not cause a maximum-size allocation.
        output.reserveCapacity(min(maximumSize, input.count))
        var lastMatchStart: Int?

        func length(_ nibble: Int, minimum: Int = 0) throws -> Int {
            var result = nibble + minimum
            if nibble == 15 {
                while true {
                    guard cursor < input.count else { throw KaitoError.truncated }
                    let extra = Int(input[cursor])
                    cursor += 1
                    guard result <= maximumSize, extra <= maximumSize - result else {
                        throw KaitoError.limitExceeded("LZ4 block output")
                    }
                    result += extra
                    if extra != 255 { break }
                }
            }
            return result
        }

        while cursor < input.count {
            let token = input[cursor]
            cursor += 1
            let literals = try length(Int(token >> 4))
            guard literals <= input.count - cursor else { throw KaitoError.truncated }
            guard literals <= maximumSize - output.count else {
                throw KaitoError.limitExceeded("LZ4 block output")
            }
            output.append(contentsOf: input[cursor..<(cursor + literals)])
            cursor += literals
            if cursor == input.count {
                // Spec's final literal-only sequence and historical decoder
                // safety restrictions. A wholly literal block may be empty.
                if let lastMatchStart {
                    guard literals >= 5, output.count - lastMatchStart >= 12 else {
                        throw KaitoError.malformed("LZ4 block end conditions")
                    }
                }
                return output
            }
            guard input.count - cursor >= 2 else { throw KaitoError.truncated }
            let distance = Int(input[cursor]) | Int(input[cursor + 1]) << 8
            cursor += 2
            guard distance > 0, distance <= history.count + output.count else {
                throw KaitoError.malformed("LZ4 match distance")
            }
            let count = try length(Int(token & 15), minimum: 4)
            guard count <= maximumSize - output.count else {
                throw KaitoError.limitExceeded("LZ4 block output")
            }
            lastMatchStart = output.count
            // Resolve each byte against output as it grows, so overlapping
            // matches and matches crossing the history boundary are defined.
            for _ in 0..<count {
                let index = output.count - distance
                output.append(index >= 0 ? output[index] : history[history.count + index])
            }
        }
        throw KaitoError.malformed("LZ4 block has no final literal sequence")
    }
}
