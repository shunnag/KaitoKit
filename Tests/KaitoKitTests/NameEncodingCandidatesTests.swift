import CoreFoundation
import Foundation
@testable import KaitoKit
import XCTest

final class NameEncodingCandidatesTests: XCTestCase {
    func testSingleByteTablesMatchStrictCFIncludingUndefinedBytes() {
        for candidate in NameEncodingCandidates.all where candidate.form == .single {
            for value in 0...255 {
                let bytes = [UInt8(value)]
                if candidate.name.hasPrefix("iso-"), (0x80...0x9F).contains(value) {
                    XCTAssertNil(candidate.decode(bytes))
                } else {
                    XCTAssertEqual(candidate.decode(bytes)?.unicodeScalars.map(\.value),
                                   EncodingDetector.decode(bytes: bytes, as: candidate.encoding)?.unicodeScalars.map(\.value),
                                   "\(candidate.name): \(value)")
                }
            }
        }
    }

    func testMultibyteStructureRejectsIncompleteAndInvalidSequences() throws {
        func candidate(_ name: String) throws -> NameEncodingCandidates.Candidate {
            try XCTUnwrap(NameEncodingCandidates.all.first { $0.name == name })
        }
        let gb = try candidate("gb18030")
        XCTAssertTrue(gb.structurallyValid([0x81, 0x30, 0x81, 0x30]))
        XCTAssertFalse(gb.structurallyValid([0x81, 0x30, 0x81]))
        XCTAssertFalse(gb.structurallyValid([0x81, 0x30, 0x80, 0x30]))
        XCTAssertFalse(gb.structurallyValid([0x81, 0x7F]))
        XCTAssertTrue(try candidate("cp950").structurallyValid([0xA4, 0x40]))
        XCTAssertFalse(try candidate("cp950").structurallyValid([0xA4, 0x80]))
        XCTAssertTrue(try candidate("cp949").structurallyValid([0x81, 0x41]))
        XCTAssertFalse(try candidate("cp949").structurallyValid([0x81, 0x5B]))
        for c in NameEncodingCandidates.all where c.isCJK {
            XCTAssertFalse(c.structurallyValid([0x81]))
            XCTAssertNil(c.decode([0x81]))
        }
    }
}
