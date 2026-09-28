import Foundation
import XCTest

enum SevenZipTestSupport {
    static let executablePath = ZipTestSupport.sevenZipPath

    static func requireSevenZip() throws {
        try ZipTestSupport.requireExecutable(
            executablePath,
            reason: "7zz is unavailable at \(executablePath); 7z integration fixture skipped"
        )
    }

    static func temporaryDirectory(label: String = "sevenzip") throws -> URL {
        try TestFixtures.makeTemporaryDirectory(label: label)
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
}
