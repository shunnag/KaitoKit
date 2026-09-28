@testable import KaitoKit
import XCTest

final class LanguageExemplarsTests: XCTestCase {
    func testAdditionalLanguagesAreAvailableWithoutChangingDetectorTable() {
        let samples = [
            ("he", "אכךם"), ("ar", "ابتة"), ("fa", "پچژگکی"),
            ("lt", "ąČė"), ("lv", "ģĶā"), ("et", "õŠä"), ("ro", "ăȘț"),
            ("hr", "čĆđ"), ("sl", "čŠž"), ("sk", "äĹô"), ("sr", "ђЉџ"),
            ("sr-Latn", "čĆđ"), ("bg", "ъЩя"), ("mk", "ѓЌѕ"), ("be", "ўІы"),
            ("da", "æØå"), ("nb", "æØå"), ("sv", "åÄö"), ("fi", "äÖš"),
            ("nl", "éËï"), ("is", "ðÞæ"),
        ]
        XCTAssertEqual(LanguageExemplars.table.count, 19)
        XCTAssertEqual(LanguageExemplars.additionalTable.count, samples.count)
        XCTAssertEqual(LanguageExemplars.allTable.count, 40)
        XCTAssertEqual(Set(LanguageExemplars.allTable.map(\.language)).count, 40)
        for (language, text) in samples {
            XCTAssertFalse(LanguageExemplars.table.contains { $0.language == language })
            for scalar in text.unicodeScalars {
                XCTAssertTrue(LanguageExemplars.contains(scalar.value, language: language, kind: .main),
                              "\(language): \(scalar)")
            }
        }
        XCTAssertFalse(LanguageExemplars.contains(0x3042, language: "he", kind: .main))
        XCTAssertFalse(LanguageExemplars.contains(0x0430, language: "sr-Latn", kind: .main))
        XCTAssertTrue(LanguageExemplars.contains(0x05B0, language: "he", kind: .auxiliary))
        for entry in LanguageExemplars.additionalTable {
            for (kind, ranges) in [(LanguageExemplars.Kind.main, entry.main), (.auxiliary, entry.auxiliary)] {
                XCTAssertTrue(ranges.count.isMultiple(of: 2))
                for offset in stride(from: 0, to: ranges.count, by: 2) {
                    let lower = ranges[offset], upper = ranges[offset + 1]
                    XCTAssertLessThanOrEqual(lower, upper)
                    for scalar in lower...upper {
                        XCTAssertTrue(LanguageExemplars.contains(scalar, language: entry.language, kind: kind))
                    }
                    if offset > 0 { XCTAssertGreaterThan(lower, ranges[offset - 1] + 1) }
                    if lower > 0 { XCTAssertFalse(LanguageExemplars.contains(lower - 1, language: entry.language, kind: kind)) }
                    XCTAssertFalse(LanguageExemplars.contains(upper + 1, language: entry.language, kind: kind))
                }
            }
        }
    }

    func testMainCharactersAndCaseVariantsForEveryLanguage() {
        let samples = [
            ("ja", "あ漢"), ("zh", "汉语"), ("zh-Hant", "漢語"), ("ko", "가힣"),
            ("vi", "ếỆđ"), ("th", "กข"), ("uk", "їЄґ"), ("ru", "ёЫя"),
            ("es", "ñÑá"), ("pt", "ãÕç"), ("fr", "œÉç"), ("de", "ßÄü"),
            ("it", "àÈù"), ("pl", "łŁą"), ("cs", "čŘů"), ("hu", "őŰá"),
            ("el", "ωΩά"), ("tr", "ğİş"), ("en", "aZq"),
        ]
        XCTAssertEqual(samples.count, LanguageExemplars.table.count)
        for (language, text) in samples {
            for scalar in text.unicodeScalars {
                XCTAssertTrue(LanguageExemplars.contains(scalar.value, language: language, kind: .main),
                              "\(language): \(scalar)")
            }
        }
        XCTAssertFalse(LanguageExemplars.contains(0x6C49, language: "ja", kind: .main))
        XCTAssertFalse(LanguageExemplars.contains(0x0457, language: "es", kind: .main))
        XCTAssertFalse(LanguageExemplars.contains(0x3042, language: "unknown", kind: .main))
        XCTAssertFalse(LanguageExemplars.contains(0x0041, language: "unknown", kind: .auxiliary))
    }

    func testAuxiliaryCharactersAndHangulBoundaries() {
        XCTAssertTrue(LanguageExemplars.contains(0x0301, language: "ru", kind: .auxiliary))
        XCTAssertFalse(LanguageExemplars.contains(0x0301, language: "ru", kind: .main))
        XCTAssertTrue(LanguageExemplars.contains(0x200B, language: "th", kind: .auxiliary))
        XCTAssertTrue(LanguageExemplars.contains(0x00E9, language: "en", kind: .auxiliary))
        XCTAssertTrue(LanguageExemplars.contains(0x00C9, language: "en", kind: .auxiliary))
        let korean = LanguageExemplars.table.first { $0.language == "ko" }
        XCTAssertEqual(korean?.main, [0xAC00, 0xD7A3])
        for scalar: UInt32 in [0xAC00, 0xAC01, 0xD7A2, 0xD7A3] {
            XCTAssertTrue(LanguageExemplars.contains(scalar, language: "ko", kind: .main))
        }
        for scalar: UInt32 in [0, 0xABFF, 0xD7A4, 0x10FFFF, UInt32.max] {
            XCTAssertFalse(LanguageExemplars.contains(scalar, language: "ko", kind: .main))
        }
    }

    func testAllRangeBoundariesAndGaps() {
        for entry in LanguageExemplars.table {
            for (kind, ranges) in [(LanguageExemplars.Kind.main, entry.main), (.auxiliary, entry.auxiliary)] {
                XCTAssertTrue(ranges.count.isMultiple(of: 2))
                for offset in stride(from: 0, to: ranges.count, by: 2) {
                    let lower = ranges[offset]
                    let upper = ranges[offset + 1]
                    XCTAssertLessThanOrEqual(lower, upper)
                    XCTAssertTrue(LanguageExemplars.contains(lower, language: entry.language, kind: kind))
                    XCTAssertTrue(LanguageExemplars.contains(upper, language: entry.language, kind: kind))
                    if offset > 0 { XCTAssertGreaterThan(lower, ranges[offset - 1] + 1) }
                    if lower > 0 {
                        XCTAssertFalse(LanguageExemplars.contains(lower - 1, language: entry.language, kind: kind))
                    }
                    if upper < UInt32.max {
                        XCTAssertFalse(LanguageExemplars.contains(upper + 1, language: entry.language, kind: kind))
                    }
                }
            }
        }
    }
}
