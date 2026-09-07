import Foundation
import XCTest

private final class SevenZipTestBundleMarker: NSObject {}

enum SevenZipTestSupport {
    static let executablePath = ZipTestSupport.sevenZipPath

    static func requireSevenZip() throws {
        try ZipTestSupport.requireExecutable(
            executablePath,
            reason: "7zz is unavailable at \(executablePath); 7z integration fixture skipped"
        )
    }

    static func temporaryDirectory(label: String = "sevenzip") throws -> URL {
        try ZipTestSupport.temporaryDirectory(label: label)
    }

    @discardableResult
    static func write(
        _ data: Data,
        relativePath: String,
        below directory: URL
    ) throws -> URL {
        try ZipTestSupport.write(data, relativePath: relativePath, below: directory)
    }

    @discardableResult
    static func run(
        arguments: [String],
        currentDirectory: URL? = nil
    ) throws -> ZipCommandResult {
        try requireSevenZip()
        return try ZipTestSupport.run(
            executablePath,
            arguments: arguments,
            currentDirectory: currentDirectory
        )
    }

    @discardableResult
    static func checkedRun(
        arguments: [String],
        currentDirectory: URL? = nil
    ) throws -> ZipCommandResult {
        try requireSevenZip()
        return try ZipTestSupport.checkedRun(
            executablePath,
            arguments: arguments,
            currentDirectory: currentDirectory
        )
    }

    static func makeArchive(
        sourceDirectory: URL,
        paths: [String],
        archiveURL: URL,
        options: [String] = []
    ) throws {
        guard !paths.isEmpty else {
            throw ZipTestSupportError.fixture("7z fixture needs at least one input path")
        }
        _ = try checkedRun(
            arguments: ["a", "-bd", "-bb0", "-y", "-t7z"]
                + options
                + [archiveURL.path]
                + paths,
            currentDirectory: sourceDirectory
        )
    }

    static func extractedData(
        archiveURL: URL,
        entryName: String,
        password: String? = nil
    ) throws -> Data {
        var arguments = ["x", "-so", "-bd", "-bb0", "-y"]
        if let password {
            arguments.append("-p\(password)")
        }
        arguments.append(archiveURL.path)
        arguments.append(entryName)
        return try checkedRun(arguments: arguments).standardOutput
    }

    static func runKaitoWithPeakResidentSize(
        arguments: [String]
    ) throws -> (standardOutput: Data, peakResidentSize: UInt64) {
        let kaito = try findKaitoExecutable()
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

    private static func findKaitoExecutable() throws -> URL {
        let fileManager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["KAITO_EXECUTABLE"] {
            let candidate = URL(fileURLWithPath: override)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        let testBundle = Bundle(for: SevenZipTestBundleMarker.self)
        var candidates: [URL] = [
            testBundle.bundleURL.deletingLastPathComponent()
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
        for candidate in candidates
            where fileManager.isExecutableFile(atPath: candidate.path)
        {
            return candidate
        }

        throw ZipTestSupportError.fixture("could not locate the built kaito executable")
    }
}
