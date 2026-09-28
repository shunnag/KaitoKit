import Foundation
@_spi(TarEditLayout) internal import KaitoKit
import XCTest

final class ThirdPartyFixtureMapTests: XCTestCase {
    func testFrozenThirdPartyChunks() throws {
        for (name, suffix, checkSize) in [("third-gzip.tar.gz", "tgz", 0), ("third-bzip2.tar.bz2", "tbz", 0),
                                          ("third-bsdtar.tar.xz", "txz", 0), ("third-xz-crc32.tar.xz", "txz", 4), ("third-xz-crc64.tar.xz", "txz", 8)] {
            let snapshot = try TarEditTestSupport.snapshot(TarEditTestSupport.fixture(name), suffix: suffix)
            let map = try XCTUnwrap(snapshot.chunkMap, name)
            XCTAssertEqual(map.hasInteriorBoundaries, checkSize > 0, name)
            if checkSize > 0, case .xz(let xz) = map { XCTAssertEqual(xz.checkSize, UInt64(checkSize)) }
            try TarEditTestSupport.verify(snapshot)
        }
    }
}
