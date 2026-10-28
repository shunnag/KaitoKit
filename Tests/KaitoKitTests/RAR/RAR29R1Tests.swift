import Foundation
@testable import KaitoKit
import XCTest

// Provenance:
// - KaitoKit's own pre-R1 RARStandardFilters and RAR29Decoder produced the
//   pinned SHA-256s.
// - RAR29 bit grammar and published filter fingerprints are from KaitoKit's
//   existing clean-room RAR29Decoder / RAR3FilterToken implementation.
// No unrar, 7-Zip, XADMaster, or The Unarchiver source was used.

final class RAR29R1Tests: XCTestCase {
    private let seed = (0..<1027).map { UInt8(truncatingIfNeeded: $0 * 73 + $0 / 7) }

    func testRGBReusedDirtyWorkAreaPreservesZeroDependentWidths() throws {
        let cases: [(Int, String)] = [
            (1, "ee1c0ccddc9f5e814f5c32e676bc3f48496cb0a83c0bfaeb63c6519231c1d4c8"),
            (2, "378bc1d942d909cb80d6bd53632614d50c95fe1c39c56e4b1c472400bf990f6d"),
            (3, "38d512883752a9dc529e9a35b62c052e08cda4dd07197be750c846de05752602"),
            (4, "11979dfb98a6f63a44514c2ecb9a5f0b7ab827296ac6e34ade9b184fb5a8b761"),
            (5, "8ba8af0596363247992a657500477ff84bd452098acf7a6fb2461edf2731c4ce"),
            (6, "06fc6bd6f706d68adc9acd2a5636d61e68a4863f38c368c15d401e41471c19af"),
            (7, "e8aeddc8f7805f9d31c7d003f520ebc3b84aed86e305bb8e31c20d952a59a9e9"),
            (9, "320741dd22ab3ddb201c1a6e2d1d158f2f8f73290c699553e6f0c743602b3aff"),
            (1027, "06fc6bd6f706d68adc9acd2a5636d61e68a4863f38c368c15d401e41471c19af"),
        ]
        // Only the middle seed.count bytes are exposed; both canaries remain
        // outside the transform's raw extent and must survive buffer reuse.
        let output = UnsafeMutableRawBufferPointer.allocate(byteCount: seed.count + 2, alignment: 1)
        defer { output.deallocate() }
        for (width, expected) in cases {
            output.initializeMemory(as: UInt8.self, repeating: 0xA5)
            try seed.withUnsafeBytes {
                try RARStandardFilters.decodeRGB(
                    input: $0, output: UnsafeMutableRawBufferPointer(rebasing: output[1...seed.count]),
                    width: width, positionR: 1
                )
            }
            XCTAssertEqual(Data(output[1...seed.count]).sha256Hex, expected, "width \(width)")
            XCTAssertEqual(output[0], 0xA5)
            XCTAssertEqual(output[seed.count + 1], 0xA5)
        }
    }

    func testAudioReusedWorkAreaAcrossPredictorUpdatesAndChannels() throws {
        let cases: [(Int, String)] = [
            (1, "51423436730c49fd54640cf295051f7d1b8b584e71b17937696886605e52d61c"),
            (2, "dc945253499de976222f7d4e5b77c5b3da8e49ea557644b360f00f3b08f3ba32"),
            (3, "7ab4931cb3e3395b84d5d133e1dcc01e290c797db1c9c99de5649442cf6558ae"),
            (128, "8f1353ac158dcf956cb872aed2cbc58f22a037a24630754131f45c55d281c0c2"),
        ]
        // As in the RGB check, the raw extent excludes the two canary bytes.
        let output = UnsafeMutableRawBufferPointer.allocate(byteCount: seed.count + 2, alignment: 1)
        defer { output.deallocate() }
        for (channels, expected) in cases {
            output.initializeMemory(as: UInt8.self, repeating: 0xA5)
            try seed.withUnsafeBytes {
                try RARStandardFilters.decodeAudio(
                    input: $0, output: UnsafeMutableRawBufferPointer(rebasing: output[1...seed.count]),
                    channels: channels
                )
            }
            XCTAssertEqual(Data(output[1...seed.count]).sha256Hex, expected, "channels \(channels)")
            XCTAssertEqual(output[0], 0xA5)
            XCTAssertEqual(output[seed.count + 1], 0xA5)
        }
    }

    func testStackedFiltersBulkMatchesAndReusedBuffersResume() throws {
        var bits = R1BitWriter()
        bits.table(main: [UInt8](repeating: 9, count: 299), matchTables: true)
        // Fingerprint-only synthetic bytes solve CRC32 and XOR constraints;
        // these are test data, never interpreted as a custom VM program.
        let delta = [UInt8](repeating: 0, count: 23) + [0xE0, 0xD4, 0x13, 0x7F, 0x58, 0]
        let e8e9 = [UInt8](repeating: 0, count: 51) + [0x74, 0x9A, 0x98, 0x1D, 0x6B, 0]
        bits.filter(program: 0, channels: 2, bytecode: delta)
        bits.filter(program: 1, channels: 3)
        bits.filter(program: 2, channels: nil, bytecode: e8e9)
        let literal: [UInt8] = [0x90, 0xE8, 0x20, 0, 0, 0, 0xE9, 7]
        func appendRaw(_ bits: inout R1BitWriter) {
            for byte in literal { bits.append(Int(byte), count: 9) }
            bits.append(278, count: 9) // ten-byte match, distance one
            bits.append(0, count: 6)
        }
        appendRaw(&bits)
        bits.filter(program: 1, channels: 2)
        appendRaw(&bits)
        // History retains raw, unfiltered bytes even after two ping-pong
        // transforms and a later capture reuse. This match crosses the ring.
        bits.append(282, count: 9) // length 18 (17 + one extra bit)
        bits.append(1, count: 1)
        bits.append(8, count: 6) // distance 18 (17 + three extra bits)
        bits.append(1, count: 3)
        bits.append(256, count: 9)
        bits.append(0, count: 2)
        for dictionary in [32, 65_536] {
            for chunk in [1, 7, 64] {
                let output = try decode(bits.bytes, size: 54, dictionary: dictionary, chunk: chunk)
                XCTAssertEqual(output.sha256Hex,
                               "2cc9810bfd098152df67c1efb1dc56948c282468c7f16cacd17431f787b9492e")
            }
        }
    }

    func testMatchStraddlingFilterCaptureEndPreservesRawSuffixAndHistory() throws {
        var bits = R1BitWriter()
        bits.table(main: [UInt8](repeating: 9, count: 299), matchTables: true)
        let delta = [UInt8](repeating: 0, count: 23) + [0xE0, 0xD4, 0x13, 0x7F, 0x58, 0]
        bits.filter(program: 0, channels: 2, bytecode: delta)
        for byte in [1, 9, 3, 200, 5, 77, 7, 8, 9, 100] {
            bits.append(byte, count: 9)
        }
        // Eight bytes finish the 18-byte capture; the last two match bytes
        // bypass the filter. The next match must still see raw history.
        bits.append(278, count: 9)
        bits.append(0, count: 6) // ten-byte match, distance one
        bits.append(278, count: 9)
        bits.append(1, count: 6) // ten-byte match, distance two
        bits.append(256, count: 9)
        bits.append(0, count: 2)
        for dictionary in [32, 65_536] {
            for chunk in [1, 5, 64] {
                // Confirmed with KaitoKit's own pre-R1 decoder at HEAD.
                XCTAssertEqual(
                    try decode(bits.bytes, size: 30, dictionary: dictionary, chunk: chunk).sha256Hex,
                    "0c966ced8f022066b0b344bd8a32b62090f8052b1ac1cbd7b48b13f401779130",
                    "dictionary \(dictionary), chunk \(chunk)"
                )
            }
        }
    }

    func testHuffmanRebuildClearsFallbackWidthForShortOnlyTree() throws {
        var bits = R1BitWriter()
        var main = [UInt8](repeating: 0, count: 299)
        main[65] = 1
        main[66] = 11
        main[256] = 11
        bits.table(main: main)
        bits.append(0, count: 1) // A
        bits.append(1025, count: 11) // end block
        bits.append(1, count: 1) // new table
        main = [UInt8](repeating: 0, count: 299)
        main[256] = 1
        bits.table(main: main)
        // This prefix is invalid in the new one-bit tree. An old 11-bit
        // fallback would silently decode B before reporting truncation.
        bits.append(1, count: 1)
        bits.append(0, count: 15)
        XCTAssertThrowsError(try decode(bits.bytes, size: 3)) {
            XCTAssertEqual($0 as? KaitoError, .malformed("invalid RAR4 main Huffman code"))
        }
    }

    func testHuffmanRebuildShrinksFallbackAndClearsInvalidPrefixes() throws {
        var mixed = R1BitWriter()
        var lengths = [UInt8](repeating: 0, count: 299)
        lengths[65] = 1
        lengths[66] = 11
        lengths[67] = 15
        lengths[256] = 15
        mixed.table(main: lengths)
        mixed.append(0, count: 1)
        mixed.append(1024, count: 11)
        mixed.append(16400, count: 15)
        mixed.append(16401, count: 15)
        mixed.append(0, count: 2)
        XCTAssertEqual(try decode(mixed.bytes, size: 3), Data("ABC".utf8))

        var stale = R1BitWriter()
        stale.table(main: [UInt8](repeating: 15, count: 299))
        stale.append(256, count: 15)
        stale.append(1, count: 1) // rebuild a populated fallback
        var sparse = [UInt8](repeating: 0, count: 299)
        sparse[65] = 11
        sparse[256] = 11
        stale.table(main: sparse)
        stale.append(2, count: 11) // used by the old tree, invalid in this tree
        XCTAssertThrowsError(try decode(stale.bytes, size: 0)) {
            XCTAssertEqual($0 as? KaitoError, .malformed("invalid RAR4 main Huffman code"))
        }

        func stream(invalid: Bool) -> [UInt8] {
            var bits = R1BitWriter()
            for (index, width) in [15, 11, 1].enumerated() {
                var main = [UInt8](repeating: 0, count: 299)
                main[65 + index] = UInt8(width)
                main[256] = UInt8(width)
                bits.table(main: main)
                bits.append(0, count: width) // literal A/B/C
                if invalid && index == 2 {
                    // Width one is complete, so rebuild once more to an
                    // incomplete tree whose upper half must reject old codes.
                    bits.append(1, count: width)
                    bits.append(1, count: 1)
                    main[67] = 0
                    bits.table(main: main)
                    bits.append(1, count: 1)
                } else {
                    bits.append(1, count: width) // end-block/file symbol
                    bits.append(index == 2 ? 0 : 1, count: index == 2 ? 2 : 1)
                }
            }
            return bits.bytes
        }
        XCTAssertEqual(try decode(stream(invalid: false), size: 3), Data("ABC".utf8))
        XCTAssertThrowsError(try decode(stream(invalid: true), size: 3)) {
            XCTAssertEqual($0 as? KaitoError, .malformed("invalid RAR4 main Huffman code"))
        }
    }

    func testRetainedWindowSizesAndDeclaredDictionaryLimit() throws {
        for (size, expected) in [(0, 1), (1, 1), (3, 4), (65_535, 65_536),
                                 (65_536, 65_536), (65_537, 65_536)] {
            XCTAssertEqual(RAR29Decoder.retainedWindowSize(
                expectedSize: UInt64(size), dictionarySize: 65_536
            ), expected)
        }
        var limits = ReadLimits()
        limits.maxDictionarySize = 32
        XCTAssertThrowsError(try RAR29Decoder(
            source: DataByteSource(data: Data()), offset: 0, compressedSize: 0,
            expectedSize: 1, unpackVersion: 29, method: 0x31,
            dictionarySize: 65_536, isSolid: false, limits: limits
        )) {
            guard case .limitExceeded = $0 as? KaitoError else {
                return XCTFail("declared dictionary limit must precede shrinking: \($0)")
            }
        }
    }

    private func decode(_ bytes: [UInt8], size: UInt64, dictionary: Int = 65_536,
                        chunk: Int = 7) throws -> Data {
        let decoder = try RAR29Decoder(
            source: DataByteSource(data: Data(bytes)), offset: 0, compressedSize: UInt64(bytes.count),
            expectedSize: size, unpackVersion: 29, method: 0x31,
            dictionarySize: UInt64(dictionary), isSolid: false, limits: ReadLimits()
        )
        var output = Data()
        var buffer = [UInt8](repeating: 0xA5, count: chunk)
        while !decoder.isFinished {
            let count = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
            output.append(contentsOf: buffer.prefix(count))
        }
        return output
    }
}

private struct R1BitWriter {
    var bytes: [UInt8] = []
    var bitCount = 0

    mutating func append(_ value: Int, count: Int) {
        for shift in stride(from: count - 1, through: 0, by: -1) {
            if bitCount % 8 == 0 { bytes.append(0) }
            bytes[bytes.count - 1] |= UInt8((value >> shift & 1) << (7 - bitCount % 8))
            bitCount += 1
        }
    }

    mutating func table(main: [UInt8], matchTables: Bool = false) {
        while bitCount % 8 != 0 { append(0, count: 1) }
        append(0, count: 2) // LZ, clear previous lengths
        for symbol in 0..<20 { append(symbol < 16 ? 4 : 0, count: 4) }
        var lengths = main + [UInt8](repeating: 0, count: 105)
        if matchTables {
            lengths = main + [UInt8](repeating: 6, count: 60)
                + [UInt8](repeating: 5, count: 17 + 28)
        }
        // The level tree gives each length 0...15 its own four-bit code.
        for length in lengths { append(Int(length), count: 4) }
    }

    mutating func number(_ value: Int) {
        if value < 16 { append(0, count: 2); append(value, count: 4) }
        else if value < 256 { append(1, count: 2); append(value, count: 8) }
        else { append(2, count: 2); append(value, count: 16) }
    }

    mutating func filter(program: Int, channels: Int?, bytecode: [UInt8] = []) {
        var payload = R1BitWriter()
        payload.number(program)
        payload.number(0) // starts at current raw output position
        payload.number(18)
        if let channels {
            payload.append(1, count: 7) // R0 only
            payload.number(channels)
        }
        if !bytecode.isEmpty {
            payload.number(bytecode.count)
            for byte in bytecode { payload.append(Int(byte), count: 8) }
        }
        append(257, count: 9)
        let flags = 0xA0 | (channels == nil ? 0 : 0x10)
        if payload.bytes.count <= 6 {
            append(flags | (payload.bytes.count - 1), count: 8)
        } else {
            precondition(payload.bytes.count <= 262)
            append(flags | 6, count: 8)
            append(payload.bytes.count - 7, count: 8)
        }
        for byte in payload.bytes { append(Int(byte), count: 8) }
    }
}
