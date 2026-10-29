import Foundation
@testable import KaitoKit
import XCTest

// Oracle: frozen KaitoKit HEAD 078ca2b, never an external implementation.
final class RAR29R3Tests: XCTestCase {
    private struct Outcome: Equatable {
        var bytes = Data()
        var error: String?
        var finished = false
        var cursor: [String] = []
    }

    private func drain(_ decoder: any Decompressor, size: Int) -> Outcome {
        var result = Outcome()
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: size, alignment: 1)
        defer { buffer.deallocate() }
        do {
            while !decoder.isFinished {
                let count = try decoder.read(into: buffer)
                result.bytes.append(buffer.bindMemory(to: UInt8.self).baseAddress!, count: count)
                if count == 0 && !decoder.isFinished { XCTFail("decoder stalled"); break }
                if result.bytes.count > 2 * 1024 * 1024 { XCTFail("mutation exceeded fixture bound"); break }
            }
        } catch {
            result.error = String(describing: error)
            XCTAssertFalse(decoder.isFinished)
            XCTAssertThrowsError(try decoder.read(into: buffer)) {
                XCTAssertEqual(String(describing: $0), result.error)
            }
        }
        result.finished = decoder.isFinished
        let fields = Mirror(reflecting: decoder).children
        for name in ["bitOffset", "produced", "emitted", "pendingDistance", "pendingLength"] {
            result.cursor.append(String(describing: fields.first { $0.label == name }!.value))
        }
        if let range = fields.first(where: { $0.label == "ppmdRangeDecoder" }),
           let value = Mirror(reflecting: range.value).children.first?.value {
            if let range = value as? RARPPMdRangeDecoder {
                result.cursor.append(String(range.byteOffset))
            } else if let range = value as? R3BaselineRARPPMdRangeDecoder {
                result.cursor.append(String(range.byteOffset))
            }

        }
        return result
    }

    func testRingOnlyMatchesAgainstForwardCopyAtEverySmallRingBoundary() {
        let size = 32
        let ring = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { ring.deallocate() }
        for position in 0..<size {
            for distance in 1...size {
                for count in 1...(size - position) {
                    var expected = (0..<size).map { UInt8($0 * 7) }
                    ring.initialize(from: expected, count: size)
                    for index in 0..<count {
                        expected[position + index] = expected[(position + index - distance) & (size - 1)]
                    }
                    RAR29Decoder.copyMatchIntoRing(window: ring, mask: size - 1, position: position,
                                                  distance: distance, count: count)
                    XCTAssertEqual(Array(UnsafeBufferPointer(start: ring, count: size)), expected,
                                   "position \(position) distance \(distance) count \(count)")
                }
            }
        }
    }

    func testFrozenHEADMutationEquivalenceAtReadAndSolidBoundaries() throws {
        var comparisons = 0
        for fixture in ["r0-rgb.rar", "r0-delta.rar", "r0-audio.rar", "r0-e8.rar",
                        "r0-ppmd-solid.rar", "solid_lz_rar300.rar", "ppmd_lorem_rar300.rar"] {
            let archive = try TestFixtures.base64("rar4/" + fixture)
            let source = DataByteSource(data: archive)
            var password: String?
            let volume = try RAR4VolumeParser.parseVolume(
                source: source, limits: ReadLimits(), password: &password,
                passwordProvider: nil, headerKeyCache: RAR3KeyCache(),
                passwordEncodings: RAR4Reader.PasswordEncodingSelection(), signatureOffset: 0
            )
            let records = volume.records.filter { $0.unpackVersion == 29 && $0.method != 0x30 }
            for (member, record) in records.enumerated() {
                let segment = try XCTUnwrap(record.packedSegments.first)
                let packed = Data(archive[Int(segment.offset)..<Int(segment.offset + record.packedSize)])
                var mutations: [(String, Data)] = [("original", packed)]
                for offset in Set([0, 1, 2, 3, 4, 7, 15, packed.count / 4, packed.count / 2, packed.count - 2, packed.count - 1]).sorted() where offset >= 0 && offset < packed.count {
                    mutations.append(("truncate-\(offset)", Data(packed.prefix(offset))))
                    for bit in [0, 3, 7] {
                        var changed = packed
                        changed[offset] ^= 1 << bit
                        mutations.append(("flip-\(offset)-\(bit)", changed))
                    }
                }
                for size in [1, 4099, 262144] {
                    for (mutation, bytes) in mutations {
                        let state = try RAR29Decoder.SolidState(dictionarySize: record.dictionarySize)
                        let baselineState = try R3BaselineRAR29Decoder.SolidState(dictionarySize: record.dictionarySize)
                        // Establish solid history and persistent PPMd state by
                        // decoding earlier members with each implementation.
                        for prior in records.prefix(member) {
                            let priorSegment = try XCTUnwrap(prior.packedSegments.first)
                            let a = try RAR29Decoder(source: source, offset: priorSegment.offset, compressedSize: prior.packedSize,
                                expectedSize: prior.unpackedSize, unpackVersion: prior.unpackVersion, method: prior.method,
                                dictionarySize: prior.dictionarySize, isSolid: prior.firstFlags & RAR4FileFlag.solid != 0,
                                limits: ReadLimits(), solidState: state)
                            let b = try R3BaselineRAR29Decoder(source: source, offset: priorSegment.offset, compressedSize: prior.packedSize,
                                expectedSize: prior.unpackedSize, unpackVersion: prior.unpackVersion, method: prior.method,
                                dictionarySize: prior.dictionarySize, isSolid: prior.firstFlags & RAR4FileFlag.solid != 0,
                                limits: ReadLimits(), solidState: baselineState)
                            XCTAssertEqual(drain(a, size: size), drain(b, size: size))
                        }
                        let mutatedSource = DataByteSource(data: bytes)
                        let a = try RAR29Decoder(source: mutatedSource, offset: 0, compressedSize: UInt64(bytes.count),
                            expectedSize: record.unpackedSize, unpackVersion: record.unpackVersion, method: record.method,
                            dictionarySize: record.dictionarySize, isSolid: record.firstFlags & RAR4FileFlag.solid != 0,
                            limits: ReadLimits(), solidState: state)
                        let b = try R3BaselineRAR29Decoder(source: mutatedSource, offset: 0, compressedSize: UInt64(bytes.count),
                            expectedSize: record.unpackedSize, unpackVersion: record.unpackVersion, method: record.method,
                            dictionarySize: record.dictionarySize, isSolid: record.firstFlags & RAR4FileFlag.solid != 0,
                            limits: ReadLimits(), solidState: baselineState)
                        XCTAssertEqual(drain(a, size: size), drain(b, size: size), "\(fixture) member \(member) \(mutation) buffer \(size)")
                        comparisons += 1
                    }
                }
            }
        }
        print("RAR29 R3 frozen HEAD comparisons: \(comparisons)")
    }
}
