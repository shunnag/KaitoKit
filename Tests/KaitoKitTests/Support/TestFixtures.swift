import Foundation
import KaitoKit
import XCTest

/// checked-in fixture（Tests/Fixtures）とリポジトリの root の場所を一か所で決める。
///
/// `#filePath` からディレクトリの深さを数えるのはこのファイルだけにする。テストのファイルを
/// どのディレクトリへ動かしても、fixture の場所の求め方は変わらない。
enum TestFixtures {
    /// リポジトリの root（Package.swift のあるディレクトリ）。
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/KaitoKitTests/Support
        .deletingLastPathComponent() // Tests/KaitoKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // リポジトリの root

    /// checked-in fixture の root（Tests/Fixtures）。
    static let root = repositoryRoot.appendingPathComponent("Tests/Fixtures", isDirectory: true)

    /// Tests/Fixtures からの相対 path をそのまま URL にする。
    static func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    /// `<relativePath>.b64` を読み、base64 を解いたバイト列を返す。改行など base64 以外の文字は無視する。
    static func base64(_ relativePath: String) throws -> Data {
        let encoded = try Data(contentsOf: url(relativePath + ".b64"))
        return try XCTUnwrap(
            Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
            "invalid base64 fixture: \(relativePath).b64"
        )
    }

    /// `<relativePath>.gz.b64` を読み、base64 と gzip を解いた中身を返す。
    static func gzipBase64(_ relativePath: String) throws -> Data {
        let gzip = try ArchiveReader.open(data: base64(relativePath + ".gz"))
        return try gzip.read(gzip.entries[0])
    }

    /// Tests/Fixtures からの相対 path の UTF-8 テキスト。
    static func text(_ relativePath: String) throws -> String {
        try String(contentsOf: url(relativePath), encoding: .utf8)
    }
}
