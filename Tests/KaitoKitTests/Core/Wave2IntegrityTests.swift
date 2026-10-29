import CBzip2
import Darwin
import Foundation
@testable import KaitoKit
import XCTest

final class Wave2IntegrityTests: XCTestCase {
    private func data(_ count: Int) -> [UInt8] {
        var random: UInt64 = 0xCA170002
        return (0..<count).map { _ in
            random = random &* 6364136223846793005 &+ 1
            return UInt8(truncatingIfNeeded: random >> 32)
        }
    }

    func testBlake2spEveryLengthAndChunkSizeAgainstScalar() {
        let bytes = data(8192 + 131)
        for count in 0...1100 {
            let input = Data(bytes.prefix(count))
            XCTAssertEqual(Blake2sp.checksum(input), ScalarBlake2sp.checksum(input), "length=\(count)")
        }
        let expected = ScalarBlake2sp.checksum(Data(bytes))
        for chunk in 1...130 {
            var hash = Blake2sp()
            bytes.withUnsafeBytes { input in
                for start in stride(from: 0, to: input.count, by: chunk) {
                    hash.update(UnsafeRawBufferPointer(rebasing: input[start..<min(start + chunk, input.count)]))
                    hash.update(UnsafeRawBufferPointer(start: nil, count: 0))
                }
            }
            XCTAssertEqual(hash.finalize(), expected, "chunk=\(chunk)")
            XCTAssertEqual(hash.finalize(), expected)
        }
        // Split at every offset around both stripes, covering unequal final
        // leaf sizes and the buffered-to-direct transition on the next call.
        for count in [511, 512, 513, 1023, 1024, 1025, 1536, 2049] {
            let expected = ScalarBlake2sp.checksum(Data(bytes.prefix(count)))
            for cut in 0...min(count, 1100) {
                var hash = Blake2sp()
                bytes.withUnsafeBytes { input in
                    hash.update(UnsafeRawBufferPointer(rebasing: input[..<cut]))
                    hash.update(UnsafeRawBufferPointer(rebasing: input[cut..<count]))
                }
                XCTAssertEqual(hash.finalize(), expected, "length=\(count) cut=\(cut)")
            }
        }
    }

    func testBlake2spLargeUnalignedBuffersAndValueCopies() {
        let bytes = data(4_194_433 + 31)
        for count in [65_536, 1_048_576, 4_194_433] {
            for offset in [0, 1, 7, 31] {
                bytes.withUnsafeBytes { raw in
                    let input = UnsafeRawBufferPointer(rebasing: raw[offset..<(offset + count)])
                    var scalar = ScalarBlake2sp()
                    scalar.update(input)
                    let expected = scalar.finalize()
                    var hash = Blake2sp()
                    hash.update(input)
                    XCTAssertEqual(hash.finalize(), expected)
                    var streaming = Blake2sp()
                    var position = 0
                    for chunk in [1, 63, 64, 65, 511, 512, 513, 1023, 1024, 1025, 4093, count] {
                        let end = min(count, position + chunk)
                        streaming.update(UnsafeRawBufferPointer(rebasing: input[position..<end]))
                        position = end
                    }
                    XCTAssertEqual(streaming.finalize(), expected)
                }
            }
        }
        for prefix in [0, 1, 511, 512, 513, 1023, 1024, 1025, 2048] {
            var original = Blake2sp()
            original.update(Array(bytes.prefix(prefix)))
            var copy = original
            original.update([1, 2])
            copy.update([3, 4, 5])
            XCTAssertEqual(original.finalize(), ScalarBlake2sp.checksum(Data(bytes.prefix(prefix)) + Data([1, 2])))
            XCTAssertEqual(copy.finalize(), ScalarBlake2sp.checksum(Data(bytes.prefix(prefix)) + Data([3, 4, 5])))
        }
    }

    private func crc(_ input: UnsafeRawBufferPointer, seed: UInt64, chunks: [Int]) -> UInt64 {
        var state = seed, position = 0, index = 0
        while position < input.count {
            let end = position + min(chunks[index % chunks.count], input.count - position)
            state = CRC64.update(UnsafeRawBufferPointer(rebasing: input[position..<end]), initial: state, folding: true)
            position = end
            index += 1
        }
        return state
    }

    func testCRC64LengthsSeedsAlignmentsAndIncrementalUpdates() {
        XCTAssertEqual(CRC64.checksum(Data("123456789".utf8)), 0x995D_C9BB_DF19_39FA)
        XCTAssertEqual(CRC64.checksum(Data()), 0)
        let bytes = data(301 + 63)
        bytes.withUnsafeBytes { raw in
            for count in 0...300 {
                for offset in 0..<64 {
                    let input = UnsafeRawBufferPointer(rebasing: raw[offset..<(offset + count)])
                    for seed: UInt64 in [0, .max, 0x1234_5678_9ABC_DEF0] {
                        let expected = CRC64.update(input, initial: seed, folding: false)
                        XCTAssertEqual(CRC64.update(input, initial: seed, folding: true), expected,
                                       "length=\(count) offset=\(offset)")
                        XCTAssertEqual(crc(input, seed: seed, chunks: [1, 7, 8, 15, 16, 17, 63, 64, 65]), expected)
                    }
                }
            }
        }
        let empty = UnsafeRawBufferPointer(start: nil, count: 0)
        XCTAssertEqual(CRC64.update(empty, initial: 42, folding: true), 42)
    }

    func testCRC64LargeRandomBuffersAndEveryChunkSize() {
        for count in [65_537, 1_048_583, 16_777_217] {
            data(count + 7).withUnsafeBytes { raw in
                let input = UnsafeRawBufferPointer(rebasing: raw[7...])
                for seed: UInt64 in [0, .max, 0x93D7_77A6_1234_5678] {
                    let expected = CRC64.update(input, initial: seed, folding: false)
                    XCTAssertEqual(CRC64.update(input, initial: seed, folding: true), expected)
                    XCTAssertEqual(crc(input, seed: seed, chunks: [4093, 65535, 65536, 65537]), expected)
                }
                var value = CRC64()
                for start in stride(from: 0, to: input.count, by: 4093) {
                    value.update(UnsafeRawBufferPointer(rebasing: input[start..<min(start + 4093, input.count)]))
                }
                XCTAssertEqual(value.value, ~CRC64.update(input, initial: .max, folding: false))
                if count == 65_537 {
                    let expected = CRC64.update(input, initial: .max, folding: false)
                    for chunk in 1...130 {
                        XCTAssertEqual(crc(input, seed: .max, chunks: [chunk]), expected, "chunk=\(chunk)")
                    }
                }
            }
        }
    }

    func testCRC64AndBlake2spGuardPageBoundaries() throws {
        let page = Int(getpagesize())
        let mapping = try XCTUnwrap(mmap(nil, page * 3, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0))
        guard mapping != MAP_FAILED else { XCTFail("mmap failed"); return }
        defer { munmap(mapping, page * 3) }
        XCTAssertEqual(mprotect(mapping, page, PROT_NONE), 0)
        XCTAssertEqual(mprotect(mapping + page * 2, page, PROT_NONE), 0)
        let start = mapping + page
        data(page).withUnsafeBytes { start.copyMemory(from: $0.baseAddress!, byteCount: page) }
        for count in Array(0...300) + [511, 512, 513, 1023, 1024, 1025, page] {
            for base in [start, start + page - count] {
                let input = UnsafeRawBufferPointer(start: base, count: count)
                XCTAssertEqual(CRC64.update(input, initial: .max, folding: true),
                               CRC64.update(input, initial: .max, folding: false))
                var hash = Blake2sp(), scalar = ScalarBlake2sp()
                hash.update(input); scalar.update(input)
                XCTAssertEqual(hash.finalize(), scalar.finalize())
            }
        }
    }

    func testZipCryptoHardwareAndTableRoundTripsAndStreaming() {
        // Independent test cipher uses the published bit recurrence rather than
        // the production lookup table or Arm instructions.
        for password in [Data(), Data("wave2 日本語".utf8), Data(0...255)] {
            let plaintext = data(262_147)
            var reference = ZipReference(password: password)
            let ciphertext = plaintext.map { reference.encrypt($0) }
            for hardware in [false, true] {
                var whole = ciphertext
                var keys = ZipCryptoKeys(passwordBytes: password)
                whole.withUnsafeMutableBytes { keys.decryptInPlace($0, hardwareCRC: hardware) }
                XCTAssertEqual(whole, plaintext)
                for chunk in [1, 7, 63, 64, 65, 4093, 65536] {
                    var result = ciphertext
                    var keys = ZipCryptoKeys(passwordBytes: password)
                    result.withUnsafeMutableBytes { input in
                        keys.decryptInPlace(UnsafeMutableRawBufferPointer(start: nil, count: 0), hardwareCRC: hardware)
                        for start in stride(from: 0, to: input.count, by: chunk) {
                            keys.decryptInPlace(UnsafeMutableRawBufferPointer(rebasing: input[start..<min(start + chunk, input.count)]), hardwareCRC: hardware)
                        }
                    }
                    XCTAssertEqual(result, plaintext, "hardware=\(hardware) chunk=\(chunk)")
                }
            }
        }
        #if arch(x86_64)
        XCTAssertFalse(CRC64.foldingAvailable)
        XCTAssertFalse(ZipCryptoKeys.hardwareCRCAvailable)
        #endif
        print("WAVE2 features PMULL=\(CRC64.foldingAvailable) CRC32=\(ZipCryptoKeys.hardwareCRCAvailable)")
    }
}

private struct ZipReference {
    private var a: UInt32 = 0x12345678, b: UInt32 = 0x23456789, c: UInt32 = 0x34567890

    init(password: Data) {
        for byte in password { update(byte) }
    }

    mutating func encrypt(_ byte: UInt8) -> UInt8 {
        let temporary = c | 2
        let result = byte ^ UInt8(truncatingIfNeeded: (temporary &* (temporary ^ 1)) >> 8)
        update(byte)
        return result
    }

    private mutating func update(_ byte: UInt8) {
        a = crc(a, byte)
        b = (b &+ (a & 255)) &* 134775813 &+ 1
        c = crc(c, UInt8(truncatingIfNeeded: b >> 24))
    }

    private func crc(_ value: UInt32, _ byte: UInt8) -> UInt32 {
        var value = value ^ UInt32(byte)
        for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xEDB88320) }
        return value
    }
}
