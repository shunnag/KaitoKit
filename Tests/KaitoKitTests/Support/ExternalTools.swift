import Foundation
import XCTest

/// 差分試験の相手（oracle）や fixture の生成に使う外部コマンド。
///
/// 場所は環境変数 → `PATH` → Homebrew の既定の場所の順に探し、プロセスの中で一度だけ決める。
/// `requireVariable` がある道具は、その環境変数が `1` のとき見つからなければ skip せず失敗にする
/// （CI は `KAITO_REQUIRE_7ZZ` / `_XZ` / `_BROTLI` / `_ZSTD` を立てる）。
enum ExternalTool: CaseIterable {
    case sevenZip, xz, brotli, zstd, rar, lha

    /// 実行ファイルの名前。
    var executableName: String {
        switch self {
        case .sevenZip: "7zz"
        case .xz: "xz"
        case .brotli: "brotli"
        case .zstd: "zstd"
        case .rar: "rar"
        case .lha: "lha"
        }
    }

    /// 場所を直接指定する環境変数。
    var environmentVariable: String {
        switch self {
        case .sevenZip: "KAITO_7ZZ"
        case .xz: "KAITO_XZ"
        case .brotli: "KAITO_BROTLI"
        case .zstd: "KAITO_ZSTD"
        case .rar: "KAITOKIT_RAR_EXECUTABLE"
        case .lha: "KAITOKIT_LHA_EXECUTABLE"
        }
    }

    /// `1` のとき、見つからない道具を skip ではなく失敗にする環境変数。
    var requireVariable: String? {
        switch self {
        case .sevenZip: "KAITO_REQUIRE_7ZZ"
        case .xz: "KAITO_REQUIRE_XZ"
        case .brotli: "KAITO_REQUIRE_BROTLI"
        case .zstd: "KAITO_REQUIRE_ZSTD"
        case .rar, .lha: nil
        }
    }

    /// `PATH` に無いときに見る場所。
    var fallbackPaths: [String] {
        ["/opt/homebrew/bin/\(executableName)", "/usr/local/bin/\(executableName)"]
    }

    /// 見つかった場所。環境変数で指定された path は、実行できるかどうかを確かめずにそのまま返す。
    var resolvedPath: String? {
        Self.resolvedPaths[self] ?? nil
    }

    /// 見つからなければ最初の既定の場所（存在しない path）を返す。`requireExecutable` で skip か失敗になる。
    var path: String {
        resolvedPath ?? fallbackPaths[0]
    }

    /// 見つからない場合、`requireVariable` が立っていれば失敗、そうでなければ skip にする。
    func require(reason: String? = nil) throws {
        try Self.requireExecutable(path, requireVariable: requireVariable, reason: reason)
    }

    static func requireExecutable(_ path: String, requireVariable: String?, reason: String?) throws {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            let message = reason ?? "required fixture tool is unavailable: \(path)"
            if let requireVariable,
               ZipTestSupport.environmentFlagIsEnabled(requireVariable)
            {
                throw ZipTestSupportError.fixture(
                    "required external oracle is unavailable at \(path) "
                        + "(\(requireVariable)=1)"
                )
            }
            throw XCTSkip(message)
        }
    }

    private static let resolvedPaths: [ExternalTool: String?] = Dictionary(
        uniqueKeysWithValues: allCases.map { ($0, $0.resolve()) }
    )

    private func resolve() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment[environmentVariable], !configured.isEmpty {
            return configured
        }
        if let path = environment["PATH"] {
            for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
                let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                    .appendingPathComponent(executableName)
                    .path
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return fallbackPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
