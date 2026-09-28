import Foundation
import XCTest

private final class KaitoCLIBundleMarker: NSObject {}

/// ビルド済みの `kaito` コマンドを探して動かす。CLI を別プロセスで検査するテストが共有する。
enum KaitoCLI {
    /// ビルド済みの `kaito` の場所。
    ///
    /// 探す順: 環境変数 `KAITO_EXECUTABLE` → テスト bundle の隣 → main bundle の隣 →
    /// `argv[0]` から 8 階層までの祖先 → `.build/debug` と `.build/out/Products/Debug` →
    /// `.build` 以下の走査。どこにも無ければ throw する（skip はしない）。
    static func executableURL() throws -> URL {
        let fileManager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["KAITO_EXECUTABLE"] {
            let candidate = URL(fileURLWithPath: override)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        var candidates: [URL] = [
            Bundle(for: KaitoCLIBundleMarker.self).bundleURL.deletingLastPathComponent()
                .appendingPathComponent("kaito"),
            Bundle.main.bundleURL.deletingLastPathComponent()
                .appendingPathComponent("kaito"),
        ]
        var ancestor = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        for _ in 0..<8 {
            candidates.append(ancestor.appendingPathComponent("kaito"))
            ancestor.deleteLastPathComponent()
        }

        let repository = TestFixtures.repositoryRoot
        candidates.append(repository.appendingPathComponent(".build/debug/kaito"))
        candidates.append(repository.appendingPathComponent(".build/out/Products/Debug/kaito"))
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        let buildDirectory = repository.appendingPathComponent(".build", isDirectory: true)
        if let enumerator = fileManager.enumerator(
            at: buildDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey]
        ) {
            for case let candidate as URL in enumerator
                where candidate.lastPathComponent == "kaito" {
                if fileManager.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        throw ZipTestSupportError.fixture("built kaito executable was not found")
    }

    /// `kaito <arguments>` を実行し、標準出力を返す。終了状態が 0 以外なら標準エラーを載せて throw する。
    @discardableResult
    static func run(_ arguments: [String], currentDirectory: URL? = nil) throws -> String {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = try executableURL()
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errors = standardError.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw ZipTestSupportError.commandFailed(
                String(decoding: errors, as: UTF8.self)
            )
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// `kaito <arguments>` を実行し、標準出力と子プロセスの最大常駐サイズ（ru_maxrss）を返す。
    static func runWithPeakResidentSize(
        _ arguments: [String]
    ) throws -> (standardOutput: Data, peakResidentSize: UInt64) {
        let kaito = try executableURL()
        let timed = try ZipTestSupport.run(
            "/usr/bin/time",
            arguments: ["-l", kaito.path] + arguments
        )
        if timed.succeeded,
           let peakResidentSize = parseTimePeakResidentSize(timed.standardError)
        {
            return (timed.standardOutput, peakResidentSize)
        }

        let timeDiagnostics = String(decoding: timed.standardError, as: UTF8.self)
        guard timeDiagnostics.contains("sysctl kern.clockrate") else {
            throw ZipTestSupportError.commandFailed(
                "/usr/bin/time -l failed: \(timeDiagnostics)"
            )
        }

        // Some restricted local runners deny the sysctl used by macOS time(1).
        // Keep the CLI in a separate process and obtain the same per-child
        // ru_maxrss value through Python's getrusage wrapper in that environment.
        let script = """
        import resource
        import subprocess
        import sys

        completed = subprocess.run(
            sys.argv[1:], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False
        )
        sys.stdout.buffer.write(completed.stdout)
        sys.stderr.buffer.write(completed.stderr)
        usage = resource.getrusage(resource.RUSAGE_CHILDREN)
        print(f"KAITO_MAX_RSS={usage.ru_maxrss}", file=sys.stderr)
        raise SystemExit(completed.returncode)
        """
        let fallback = try ZipTestSupport.checkedRun(
            ZipTestSupport.pythonPath,
            arguments: ["-c", script, kaito.path] + arguments
        )
        guard let peakResidentSize = parsePythonPeakResidentSize(fallback.standardError) else {
            throw ZipTestSupportError.fixture(
                "getrusage wrapper did not report the kaito peak resident size"
            )
        }
        return (fallback.standardOutput, peakResidentSize)
    }

    private static func parseTimePeakResidentSize(_ diagnostics: Data) -> UInt64? {
        let text = String(decoding: diagnostics, as: UTF8.self)
        for line in text.split(separator: "\n")
            where line.contains("maximum resident set size")
        {
            if let value = line.split(whereSeparator: { $0.isWhitespace }).first,
               let peakResidentSize = UInt64(value)
            {
                return peakResidentSize
            }
        }
        return nil
    }

    private static func parsePythonPeakResidentSize(_ diagnostics: Data) -> UInt64? {
        let marker = "KAITO_MAX_RSS="
        let text = String(decoding: diagnostics, as: UTF8.self)
        for line in text.split(separator: "\n") where line.hasPrefix(marker) {
            return UInt64(line.dropFirst(marker.count))
        }
        return nil
    }
}
