import Foundation
@_spi(TarEditLayout) internal import KaitoKit
import XCTest

final class TarSpliceSPIImportTests: XCTestCase {
    func testSpliceContractWithoutTestableImport() throws {
        let image = try TarTestSupport.makeTar(entries: [HandTarEntry(name: "spi", contents: Data([1]))])
        let bytes = try CompressedTarFramingTestSupport.gzip(image).data
        var options = ReaderOptions(); options.recordsTarEditLayout = true
        let source = DataByteSource(bytes), hint = URL(fileURLWithPath: "/spi.tgz")
        let base = try XCTUnwrap(ArchiveReader.open(source: source, sourceURL: hint, options: options).tarEditingSnapshot())
        let range = UInt64(10)..<UInt64(bytes.count - 8)
        let segment: CompressedTarSplice.Segment = .reused(output: range, base: range)
        let splice = CompressedTarSplice(segments: [segment])
        XCTAssertEqual(splice.segments, [segment])
        options.recordsTarEditLayout = false
        let reader = try ArchiveReader.openSplicedCompressedTar(output: source, sourceURL: hint, base: base, splice: splice, options: options)
        XCTAssertEqual(reader.format, .tar)
        XCTAssertEqual(reader.tarEditingSnapshot()?.chunkMap, base.chunkMap)
        do {
            _ = try ArchiveReader.openSplicedCompressedTar(output: source, sourceURL: hint, base: base,
                splice: CompressedTarSplice(segments: []), options: options)
            XCTFail("empty segments")
        } catch let error as TarSpliceVerificationError {
            let reason: TarSpliceVerificationError.Reason = .invalidSegments
            XCTAssertEqual(error.reason, reason)
            XCTAssertNil(error.segmentIndex); XCTAssertNil(error.underlying)
        }
    }
}
