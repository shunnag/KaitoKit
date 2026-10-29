import CryptoKit
import Foundation
@testable import KaitoKit

/// Standalone measurements over the black-box corpus; excluded from the test targets.
@main struct UDIFR2Measurement {
    private static func archives() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["KAITO_UDIF_R2_CORPUS"] else {
            throw KaitoError.malformed("Set KAITO_UDIF_R2_CORPUS to the R2 corpus archives directory")
        }
        return URL(fileURLWithPath: path)
    }

    static func counts() throws {
        let root = try archives()
        for name in ["mixed-ULMO.dmg", "pages-ULMO.dmg", "mixed-ULFO.dmg"] {
            for threads in [1, ReaderOptions.automaticDecodeThreads()] {
                let diagnostics = UDIFChunkCache.Diagnostics()
                let file = try FileByteSource(url: root.appendingPathComponent(name))
                let disk = try UDIFDiskByteSource(file: file, trailer: unwrap(UDIFTrailer.read(source: file)),
                                                limits: ReadLimits(), decodeThreads: threads, diagnostics: diagnostics)
                let offset = try unwrap(DMGReader.volumeCandidates(disk: disk).first {
                    try DMGReader.hasHFSPlusVolume(disk: disk, at: $0)
                })
                let listing = try HFSVolumeListing(volume: HFSPlusVolume(source: disk, baseOffset: offset),
                                                   options: ReaderOptions(decodeThreads: threads))
                var buffer = [UInt8](repeating: 0, count: 4 << 20), bytes = 0
                for entry in listing.entries where entry.kind != .directory {
                    let stream = try listing.stream(for: entry, limits: ReadLimits())
                    while true {
                        let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
                        if count == 0 { break }
                        bytes += count
                    }
                }
                let counts = disk.chunks.indices.map { diagnostics.decodeCount($0) }
                print("R2_COUNTS \(name) t=\(threads) chunks=\(counts.filter { $0 > 0 }.count) decodes=\(counts.reduce(0, +)) max=\(counts.max() ?? 0) peakWorkers=\(diagnostics.peakWorkers) held=\(diagnostics.peakHeldBytes) bytes=\(bytes)")
            }
        }
    }

    static func codec() throws {
        let root = try archives()
        for name in ["mixed-ULMO.dmg", "pages-ULMO.dmg"] {
            let file = try FileByteSource(url: root.appendingPathComponent(name))
            let disk = try UDIFDiskByteSource(file: file, trailer: unwrap(UDIFTrailer.read(source: file)),
                                            limits: ReadLimits(), decodeThreads: 1)
            let chunks = disk.chunks.filter { if case .xz = $0.kind { return true }; return false }
            var reference: SHA256.Digest?
            for round in 0..<5 {
                for native in (round.isMultiple(of: 2) ? [false, true] : [true, false]) {
                    let start = Date()
                    var hash = SHA256(), total = 0
                    for chunk in chunks {
                        let source = try BoundedByteSource(source: file, baseOffset: chunk.dataOffset, length: chunk.dataLength)
                        let decoder: any Decompressor
                        if native {
                            decoder = try ParallelXZDecompressor(source: source, limits: ReadLimits(), workers: 1,
                                                                 expectedSize: chunk.byteCount)
                        } else {
                            decoder = try XZDecompressor(source: source, limits: ReadLimits())
                        }
                        let output = try drain(decoder, bufferSize: 1 << 20)
                        precondition(output.count == Int(chunk.byteCount))
                        hash.update(data: output); total += output.count
                    }
                    let digest = hash.finalize()
                    if let reference { precondition(digest == reference) } else { reference = digest }
                    print("R2_CODEC \(name) native=\(native) round=\(round) seconds=\(Date().timeIntervalSince(start)) bytes=\(total) sha256=\(digest)")
                }
            }
        }
    }

    private static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw KaitoError.malformed("missing measurement value") }
        return value
    }
    private static func drain(_ decoder: any Decompressor, bufferSize: Int) throws -> Data {
        var result = Data(), buffer = [UInt8](repeating: 0, count: bufferSize)
        while !decoder.isFinished {
            let count = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
            guard count > 0 || decoder.isFinished else { throw KaitoError.truncated }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
    static func main() throws {
        if CommandLine.arguments.dropFirst().first == "codec" { try codec() }
        else { try counts() }
    }
}
