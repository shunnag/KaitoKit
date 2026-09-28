import KaitoKit
import XCTest

/// `operation` が `KaitoError` を投げ、それが `match` に合うことを確かめる。
///
/// 失敗はすべて呼び出し元の `file` / `line` に報告する。`expectation` は失敗の文言に使う。
func XCTAssertThrowsKaitoError<T>(
    _ operation: () throws -> T,
    _ expectation: String,
    file: StaticString = #filePath,
    line: UInt = #line,
    matching match: (KaitoError) -> Bool
) {
    XCTAssertThrowsError(try operation(), file: file, line: line) { error in
        guard let kaitoError = error as? KaitoError, match(kaitoError) else {
            return XCTFail("expected \(expectation), got \(error)", file: file, line: line)
        }
    }
}

/// `operation` が `KaitoError.malformed` を投げることを確かめる。
func assertMalformed<T>(
    _ operation: () throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertThrowsKaitoError(operation, "malformed", file: file, line: line) {
        if case .malformed = $0 { true } else { false }
    }
}

/// `operation` が `KaitoError.limitExceeded` を投げることを確かめる。
func assertLimitExceeded<T>(
    _ operation: () throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertThrowsKaitoError(operation, "limitExceeded", file: file, line: line) {
        if case .limitExceeded = $0 { true } else { false }
    }
}

/// `operation` が壊れた圧縮データとして `malformed`・`truncated`・`checksumMismatch` のどれかを投げることを確かめる。
func assertCorrupt<T>(
    _ operation: () throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertThrowsKaitoError(operation, "malformed, truncated or checksumMismatch", file: file, line: line) {
        switch $0 {
        case .malformed, .truncated, .checksumMismatch: true
        default: false
        }
    }
}
