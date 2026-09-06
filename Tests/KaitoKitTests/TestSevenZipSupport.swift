import Foundation
import XCTest

enum SevenZipTestSupport {
    static let executablePath = "/opt/homebrew/bin/7zz"
    static let cooViewerFixtureDirectory = URL(
        fileURLWithPath: "/Users/nagash/cooViewer/CooViewerTests/Fixtures",
        isDirectory: true
    )

    static func requireSevenZip() throws {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw XCTSkip(
                "7zz is unavailable at \(executablePath); 7z integration fixture skipped"
            )
        }
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

    static func copyCooViewerFixture(
        named fixtureName: String,
        into directory: URL
    ) throws -> URL {
        let allowedNames = ["nonsolid.7z", "solid.7z", "blocks.7z"]
        guard allowedNames.contains(fixtureName) else {
            throw ZipTestSupportError.fixture(
                "unknown cooViewer 7z fixture: \(fixtureName)"
            )
        }
        let source = cooViewerFixtureDirectory.appendingPathComponent(fixtureName)
        guard FileManager.default.isReadableFile(atPath: source.path) else {
            throw XCTSkip(
                "cooViewer 7z fixture is unavailable at \(source.path); fixture test skipped"
            )
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let destination = directory.appendingPathComponent(fixtureName)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}
