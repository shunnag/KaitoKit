import Foundation
import KaitoKit
import XCTest

enum ZipTestSupportError: Error, CustomStringConvertible {
    case commandFailed(String)
    case fixture(String)

    var description: String {
        switch self {
        case let .commandFailed(message), let .fixture(message):
            message
        }
    }
}

struct HandZipEntry {
    var rawName: [UInt8]
    var uncompressedData: Data
    var compressedData: Data
    var method: UInt16
    var flags: UInt16
    var localExtra: Data
    var centralExtra: Data
    var versionMadeBy: UInt16
    var externalAttributes: UInt32
    var centralCRC32: UInt32?
    var centralCompressedSize: UInt32?
    var centralUncompressedSize: UInt32?
    var centralLocalHeaderOffset: UInt32?
    var localCRC32: UInt32?
    var localCompressedSize: UInt32?
    var localUncompressedSize: UInt32?
    var hasDataDescriptor: Bool
    // 公開 APPNOTE の byte 表から組み立てる descriptor の 4 形態。
    var dataDescriptorHasSignature = true
    var dataDescriptorUsesZIP64 = false

    init(
        name: String,
        uncompressedData: Data = Data(),
        compressedData: Data? = nil,
        method: UInt16 = 0,
        flags: UInt16 = 0x0800,
        localExtra: Data = Data(),
        centralExtra: Data = Data(),
        versionMadeBy: UInt16 = 0x0314,
        externalAttributes: UInt32 = 0,
        centralCRC32: UInt32? = nil,
        centralCompressedSize: UInt32? = nil,
        centralUncompressedSize: UInt32? = nil,
        centralLocalHeaderOffset: UInt32? = nil,
        localCRC32: UInt32? = nil,
        localCompressedSize: UInt32? = nil,
        localUncompressedSize: UInt32? = nil,
        hasDataDescriptor: Bool = false
    ) {
        self.init(
            rawName: Array(name.utf8),
            uncompressedData: uncompressedData,
            compressedData: compressedData,
            method: method,
            flags: flags,
            localExtra: localExtra,
            centralExtra: centralExtra,
            versionMadeBy: versionMadeBy,
            externalAttributes: externalAttributes,
            centralCRC32: centralCRC32,
            centralCompressedSize: centralCompressedSize,
            centralUncompressedSize: centralUncompressedSize,
            centralLocalHeaderOffset: centralLocalHeaderOffset,
            localCRC32: localCRC32,
            localCompressedSize: localCompressedSize,
            localUncompressedSize: localUncompressedSize,
            hasDataDescriptor: hasDataDescriptor
        )
    }

    init(
        rawName: [UInt8],
        uncompressedData: Data = Data(),
        compressedData: Data? = nil,
        method: UInt16 = 0,
        flags: UInt16 = 0,
        localExtra: Data = Data(),
        centralExtra: Data = Data(),
        versionMadeBy: UInt16 = 0x0014,
        externalAttributes: UInt32 = 0,
        centralCRC32: UInt32? = nil,
        centralCompressedSize: UInt32? = nil,
        centralUncompressedSize: UInt32? = nil,
        centralLocalHeaderOffset: UInt32? = nil,
        localCRC32: UInt32? = nil,
        localCompressedSize: UInt32? = nil,
        localUncompressedSize: UInt32? = nil,
        hasDataDescriptor: Bool = false
    ) {
        self.rawName = rawName
        self.uncompressedData = uncompressedData
        self.compressedData = compressedData ?? uncompressedData
        self.method = method
        self.flags = flags
        self.localExtra = localExtra
        self.centralExtra = centralExtra
        self.versionMadeBy = versionMadeBy
        self.externalAttributes = externalAttributes
        self.centralCRC32 = centralCRC32
        self.centralCompressedSize = centralCompressedSize
        self.centralUncompressedSize = centralUncompressedSize
        self.centralLocalHeaderOffset = centralLocalHeaderOffset
        self.localCRC32 = localCRC32
        self.localCompressedSize = localCompressedSize
        self.localUncompressedSize = localUncompressedSize
        self.hasDataDescriptor = hasDataDescriptor
    }
}

struct ZipFixtureLayout {
    let archiveBase: Int
    let centralDirectoryOffset: Int
    let centralDirectorySize: Int
    let centralEntryOffsets: [Int]
    let localHeaderOffsets: [Int]
    let endRecordOffset: Int
    let zip64EndRecordOffset: Int?
    let zip64LocatorOffset: Int?
}

struct ZipCommandResult {
    let terminationStatus: Int32
    let standardOutput: Data
    let standardError: Data

    var succeeded: Bool { terminationStatus == 0 }

    var diagnostics: String {
        let output = String(decoding: standardOutput, as: UTF8.self)
        let error = String(decoding: standardError, as: UTF8.self)
        return [output, error].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

enum ZipTestSupport {
    static func checkedInFixture(_ relativePath: String) throws -> Data {
        let url = repositoryRoot.appendingPathComponent("Tests/Fixtures/\(relativePath).b64")
        let encoded = try String(contentsOf: url, encoding: .utf8)
        return try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
    }

    static let infoZipPath = "/usr/bin/zip"
    static let unzipPath = "/usr/bin/unzip"
    static let bsdTarPath = "/usr/bin/bsdtar"
    static let sevenZipPath = resolveExecutablePath(
        environmentVariable: "KAITO_7ZZ",
        executableName: "7zz",
        fallbackPaths: ["/opt/homebrew/bin/7zz", "/usr/local/bin/7zz"]
    )
    static let xzPath = resolveExecutablePath(
        environmentVariable: "KAITO_XZ",
        executableName: "xz",
        fallbackPaths: ["/opt/homebrew/bin/xz", "/usr/local/bin/xz"]
    )
    static let pythonPath = "/usr/bin/python3"

    static func makePEPrefix(count: Int, fill: UInt8 = 0x90) -> Data {
        precondition(count >= 68)
        var bytes = [UInt8](repeating: fill, count: count)
        bytes[0] = 0x4D
        bytes[1] = 0x5A
        bytes[0x3C] = 0x40
        bytes[0x3D] = 0
        bytes[0x3E] = 0
        bytes[0x3F] = 0
        bytes.replaceSubrange(0x40..<0x44, with: [0x50, 0x45, 0, 0])
        return Data(bytes)
    }

    private static func resolveExecutablePath(
        environmentVariable: String,
        executableName: String,
        fallbackPaths: [String]
    ) -> String {
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
        for fallbackPath in fallbackPaths
            where FileManager.default.isExecutableFile(atPath: fallbackPath)
        {
            return fallbackPath
        }
        return fallbackPaths[0]
    }

    private static func environmentFlagIsEnabled(_ name: String) -> Bool {
        guard let value = ProcessInfo.processInfo.environment[name]?.lowercased() else {
            return false
        }
        switch value {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static var cp932FixtureScript: URL {
        repositoryRoot.appendingPathComponent("Scripts/fixtures/make-cp932-zip.py")
    }

    static func temporaryDirectory(label: String = "zip") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KaitoKitTests-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }

    @discardableResult
    static func write(
        _ data: Data,
        relativePath: String,
        below directory: URL
    ) throws -> URL {
        let destination = directory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination)
        return destination
    }

    static func requireExecutable(_ path: String, reason: String? = nil) throws {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            let requiredEnvironmentVariable: String?
            if path == sevenZipPath {
                requiredEnvironmentVariable = "KAITO_REQUIRE_7ZZ"
            } else if path == xzPath {
                requiredEnvironmentVariable = "KAITO_REQUIRE_XZ"
            } else {
                requiredEnvironmentVariable = nil
            }
            let message = reason ?? "required fixture tool is unavailable: \(path)"
            if let requiredEnvironmentVariable,
               environmentFlagIsEnabled(requiredEnvironmentVariable)
            {
                throw ZipTestSupportError.fixture(
                    "required external oracle is unavailable at \(path) "
                        + "(\(requiredEnvironmentVariable)=1)"
                )
            }
            throw XCTSkip(message)
        }
    }

    @discardableResult
    static func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        standardInput: Data? = nil
    ) throws -> ZipCommandResult {
        let capture = try temporaryDirectory(label: "command-output")
        defer { try? FileManager.default.removeItem(at: capture) }
        let outputURL = capture.appendingPathComponent("stdout")
        let errorURL = capture.appendingPathComponent("stderr")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              FileManager.default.createFile(atPath: errorURL.path, contents: nil) else {
            throw ZipTestSupportError.fixture("could not create command capture files")
        }
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        var inputHandle: FileHandle?
        if let standardInput {
            let inputURL = capture.appendingPathComponent("stdin")
            try standardInput.write(to: inputURL)
            let handle = try FileHandle(forReadingFrom: inputURL)
            inputHandle = handle
            process.standardInput = handle
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        try process.run()
        process.waitUntilExit()
        try inputHandle?.close()
        try outputHandle.synchronize()
        try errorHandle.synchronize()

        return ZipCommandResult(
            terminationStatus: process.terminationStatus,
            standardOutput: try Data(contentsOf: outputURL),
            standardError: try Data(contentsOf: errorURL)
        )
    }

    @discardableResult
    static func checkedRun(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        standardInput: Data? = nil
    ) throws -> ZipCommandResult {
        let result = try run(
            executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            standardInput: standardInput
        )
        guard result.succeeded else {
            throw ZipTestSupportError.commandFailed(
                "\(executable) exited with \(result.terminationStatus): \(result.diagnostics)"
            )
        }
        return result
    }

    static func makeInfoZip(
        sourceDirectory: URL,
        paths: [String],
        archiveURL: URL,
        options: [String] = []
    ) throws {
        try requireExecutable(infoZipPath)
        _ = try checkedRun(
            infoZipPath,
            arguments: ["-q"] + options + [archiveURL.path] + paths,
            currentDirectory: sourceDirectory
        )
    }

    static func makeBSDTarZip(
        sourceDirectory: URL,
        paths: [String],
        archiveURL: URL
    ) throws {
        try requireExecutable(bsdTarPath)
        _ = try checkedRun(
            bsdTarPath,
            arguments: ["-a", "-cf", archiveURL.path, "-C", sourceDirectory.path] + paths
        )
    }

    static func makeSevenZip(
        sourceDirectory: URL,
        paths: [String],
        archiveURL: URL,
        method: String,
        password: String? = nil
    ) throws {
        try requireExecutable(
            sevenZipPath,
            reason: "7zz is unavailable at \(sevenZipPath); optional ZIP fixtures skipped"
        )
        var arguments = ["a", "-bd", "-bb0", "-y", "-tzip", "-mm=\(method)"]
        if let password {
            arguments.append("-mem=AES256")
            arguments.append("-p\(password)")
        }
        arguments.append(archiveURL.path)
        arguments.append(contentsOf: paths)
        _ = try checkedRun(
            sevenZipPath,
            arguments: arguments,
            currentDirectory: sourceDirectory
        )
    }

    static func makePythonZIP64EmptyArchive(
        archiveURL: URL,
        entryCount: Int = 65_536
    ) throws {
        try requireExecutable(pythonPath)
        guard entryCount > Int(UInt16.max) else {
            throw ZipTestSupportError.fixture(
                "Python ZIP64 count fixture must exceed the ZIP32 entry limit"
            )
        }
        let script = """
        import sys
        import zipfile

        path = sys.argv[1]
        count = int(sys.argv[2])
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED, allowZip64=True) as archive:
            for index in range(count):
                archive.writestr(f"empty-{index:05d}", b"")
        with zipfile.ZipFile(path, "r") as archive:
            if len(archive.infolist()) != count:
                raise SystemExit("ZIP64 fixture entry count did not round-trip")
        """
        _ = try checkedRun(
            pythonPath,
            arguments: ["-c", script, archiveURL.path, String(entryCount)]
        )
    }

    static func unzipData(
        archiveURL: URL,
        entryName: String,
        password: String? = nil
    ) throws -> Data {
        try requireExecutable(unzipPath)
        var arguments: [String] = []
        if let password {
            arguments.append(contentsOf: ["-P", password])
        }
        arguments.append(contentsOf: ["-p", archiveURL.path, entryName])
        return try checkedRun(
            unzipPath,
            arguments: arguments
        ).standardOutput
    }

    static func sevenZipData(
        archiveURL: URL,
        entryName: String,
        password: String? = nil
    ) throws -> Data {
        try requireExecutable(
            sevenZipPath,
            reason: "7zz is unavailable at \(sevenZipPath); optional ZIP fixtures skipped"
        )
        var arguments = ["x", "-so", "-bd", "-bb0", "-y"]
        if let password {
            arguments.append("-p\(password)")
        }
        arguments.append(archiveURL.path)
        arguments.append(entryName)
        return try checkedRun(
            sevenZipPath,
            arguments: arguments
        ).standardOutput
    }

    static func makeArchive(
        entries: [HandZipEntry],
        prefix: Data = Data(),
        comment: Data = Data(),
        forceZIP64End: Bool = false
    ) throws -> Data {
        guard entries.count <= Int(UInt16.max), comment.count <= Int(UInt16.max) else {
            throw ZipTestSupportError.fixture("hand-built ZIP32 fixture is too large")
        }
        var body = Data()
        var records: [(entry: HandZipEntry, localOffset: UInt32, crc32: UInt32)] = []
        records.reserveCapacity(entries.count)

        for entry in entries {
            guard body.count <= Int(UInt32.max),
                  entry.rawName.count <= Int(UInt16.max),
                  entry.localExtra.count <= Int(UInt16.max),
                  entry.compressedData.count <= Int(UInt32.max),
                  entry.uncompressedData.count <= Int(UInt32.max) else {
                throw ZipTestSupportError.fixture("hand-built ZIP entry exceeds ZIP32 fields")
            }
            let localOffset = UInt32(body.count)
            let crc32 = CRC32.checksum(entry.uncompressedData)
            let flags = entry.hasDataDescriptor ? entry.flags | 0x0008 : entry.flags
            appendUInt32(0x0403_4B50, to: &body)
            appendUInt16(entry.dataDescriptorUsesZIP64 ? 45 : 20, to: &body)
            appendUInt16(flags, to: &body)
            appendUInt16(entry.method, to: &body)
            appendUInt16(0x1883, to: &body) // 03:04:06
            appendUInt16(0x5022, to: &body) // 2020-01-02
            appendUInt32(
                entry.hasDataDescriptor ? 0 : entry.localCRC32 ?? crc32,
                to: &body
            )
            appendUInt32(
                entry.localCompressedSize
                    ?? (entry.hasDataDescriptor ? 0 : UInt32(entry.compressedData.count)),
                to: &body
            )
            appendUInt32(
                entry.localUncompressedSize
                    ?? (entry.hasDataDescriptor ? 0 : UInt32(entry.uncompressedData.count)),
                to: &body
            )
            appendUInt16(UInt16(entry.rawName.count), to: &body)
            appendUInt16(UInt16(entry.localExtra.count), to: &body)
            body.append(contentsOf: entry.rawName)
            body.append(entry.localExtra)
            body.append(entry.compressedData)
            if entry.hasDataDescriptor {
                if entry.dataDescriptorHasSignature {
                    appendUInt32(0x0807_4B50, to: &body)
                }
                appendUInt32(crc32, to: &body)
                if entry.dataDescriptorUsesZIP64 {
                    appendUInt64(UInt64(entry.compressedData.count), to: &body)
                    appendUInt64(UInt64(entry.uncompressedData.count), to: &body)
                } else {
                    appendUInt32(UInt32(entry.compressedData.count), to: &body)
                    appendUInt32(UInt32(entry.uncompressedData.count), to: &body)
                }
            }
            records.append((entry, localOffset, crc32))
        }

        guard body.count <= Int(UInt32.max) else {
            throw ZipTestSupportError.fixture("central-directory offset does not fit ZIP32")
        }
        let centralOffset = UInt32(body.count)
        for record in records {
            let entry = record.entry
            guard entry.centralExtra.count <= Int(UInt16.max) else {
                throw ZipTestSupportError.fixture("central extra field is too large")
            }
            let flags = entry.hasDataDescriptor ? entry.flags | 0x0008 : entry.flags
            appendUInt32(0x0201_4B50, to: &body)
            appendUInt16(entry.versionMadeBy, to: &body)
            appendUInt16(entry.dataDescriptorUsesZIP64 ? 45 : 20, to: &body)
            appendUInt16(flags, to: &body)
            appendUInt16(entry.method, to: &body)
            appendUInt16(0x1883, to: &body)
            appendUInt16(0x5022, to: &body)
            appendUInt32(entry.centralCRC32 ?? record.crc32, to: &body)
            appendUInt32(
                entry.centralCompressedSize ?? UInt32(entry.compressedData.count),
                to: &body
            )
            appendUInt32(
                entry.centralUncompressedSize ?? UInt32(entry.uncompressedData.count),
                to: &body
            )
            appendUInt16(UInt16(entry.rawName.count), to: &body)
            appendUInt16(UInt16(entry.centralExtra.count), to: &body)
            appendUInt16(0, to: &body) // コメント長
            appendUInt16(0, to: &body) // 開始ディスク
            appendUInt16(0, to: &body) // 内部属性
            appendUInt32(entry.externalAttributes, to: &body)
            appendUInt32(entry.centralLocalHeaderOffset ?? record.localOffset, to: &body)
            body.append(contentsOf: entry.rawName)
            body.append(entry.centralExtra)
        }

        let centralSize = UInt64(body.count) - UInt64(centralOffset)
        guard centralSize <= UInt64(UInt32.max) else {
            throw ZipTestSupportError.fixture("central-directory size does not fit ZIP32")
        }
        if forceZIP64End {
            appendZIP64End(
                entryCount: UInt64(entries.count),
                centralOffset: UInt64(centralOffset),
                centralSize: centralSize,
                to: &body
            )
        } else {
            appendEndRecord(
                entryCount: UInt16(entries.count),
                centralOffset: centralOffset,
                centralSize: UInt32(centralSize),
                comment: comment,
                to: &body
            )
        }
        var result = prefix
        result.append(body)
        return result
    }

    static func makeZIP64ManyEmptyArchive(entryCount: Int = 65_536) throws -> Data {
        guard entryCount > Int(UInt16.max), entryCount <= 1_000_000 else {
            throw ZipTestSupportError.fixture("ZIP64 entry-count fixture needs 65,536...1,000,000 entries")
        }
        var body = Data()
        body.reserveCapacity(entryCount * 96 + 98)
        var localOffsets: [UInt32] = []
        localOffsets.reserveCapacity(entryCount)

        for index in 0..<entryCount {
            guard body.count <= Int(UInt32.max) else {
                throw ZipTestSupportError.fixture("ZIP64 fixture offset exceeds UInt32")
            }
            let name = Array(String(format: "empty-%05d", index).utf8)
            localOffsets.append(UInt32(body.count))
            appendUInt32(0x0403_4B50, to: &body)
            appendUInt16(20, to: &body)
            appendUInt16(0x0800, to: &body)
            appendUInt16(0, to: &body)
            appendUInt16(0x1883, to: &body)
            appendUInt16(0x5022, to: &body)
            appendUInt32(0, to: &body)
            appendUInt32(0, to: &body)
            appendUInt32(0, to: &body)
            appendUInt16(UInt16(name.count), to: &body)
            appendUInt16(0, to: &body)
            body.append(contentsOf: name)
        }

        let centralOffset = UInt64(body.count)
        for index in 0..<entryCount {
            let name = Array(String(format: "empty-%05d", index).utf8)
            appendUInt32(0x0201_4B50, to: &body)
            appendUInt16(0x0314, to: &body)
            appendUInt16(20, to: &body)
            appendUInt16(0x0800, to: &body)
            appendUInt16(0, to: &body)
            appendUInt16(0x1883, to: &body)
            appendUInt16(0x5022, to: &body)
            appendUInt32(0, to: &body)
            appendUInt32(0, to: &body)
            appendUInt32(0, to: &body)
            appendUInt16(UInt16(name.count), to: &body)
            appendUInt16(0, to: &body)
            appendUInt16(0, to: &body)
            appendUInt16(0, to: &body)
            appendUInt16(0, to: &body)
            appendUInt32(0, to: &body)
            appendUInt32(localOffsets[index], to: &body)
            body.append(contentsOf: name)
        }
        let centralSize = UInt64(body.count) - centralOffset
        appendZIP64End(
            entryCount: UInt64(entryCount),
            centralOffset: centralOffset,
            centralSize: centralSize,
            to: &body
        )
        return body
    }

    static func extraField(identifier: UInt16, payload: Data) throws -> Data {
        guard payload.count <= Int(UInt16.max) else {
            throw ZipTestSupportError.fixture("extra-field payload is too large")
        }
        var result = Data()
        appendUInt16(identifier, to: &result)
        appendUInt16(UInt16(payload.count), to: &result)
        result.append(payload)
        return result
    }

    static func unicodePathExtra(
        rawName: [UInt8],
        unicodeName: String,
        validCRC: Bool = true
    ) throws -> Data {
        var payload = Data([1])
        let crc = CRC32.checksum(rawName) ^ (validCRC ? 0 : 0xFFFF_FFFF)
        appendUInt32(crc, to: &payload)
        payload.append(contentsOf: unicodeName.utf8)
        return try extraField(identifier: 0x7075, payload: payload)
    }

    static func extendedTimestampExtra(seconds: UInt32) throws -> Data {
        var payload = Data([1])
        appendUInt32(seconds, to: &payload)
        return try extraField(identifier: 0x5455, payload: payload)
    }

    static func ntfsTimestampExtra(secondsSince1970: UInt64) throws -> Data {
        let windowsEpochOffset: UInt64 = 11_644_473_600
        let ticks = (secondsSince1970 + windowsEpochOffset) * 10_000_000
        var payload = Data(repeating: 0, count: 4)
        appendUInt16(1, to: &payload)
        appendUInt16(24, to: &payload)
        appendUInt64(ticks, to: &payload)
        appendUInt64(0, to: &payload)
        appendUInt64(0, to: &payload)
        return try extraField(identifier: 0x000A, payload: payload)
    }

    static func zip64Extra(values: [UInt64]) throws -> Data {
        var payload = Data()
        for value in values {
            appendUInt64(value, to: &payload)
        }
        return try extraField(identifier: 0x0001, payload: payload)
    }

    static func layout(of archive: Data) throws -> ZipFixtureLayout {
        let endSignature = Data([0x50, 0x4B, 0x05, 0x06])
        guard let endRange = archive.range(of: endSignature, options: .backwards),
              archive.count - endRange.lowerBound >= 22 else {
            throw ZipTestSupportError.fixture("ZIP end record is missing")
        }
        let endOffset = endRange.lowerBound
        let entryCount16 = try readUInt16(archive, at: endOffset + 10)
        let size32 = try readUInt32(archive, at: endOffset + 12)
        let offset32 = try readUInt32(archive, at: endOffset + 16)

        let archiveBase: Int
        let centralOffset: Int
        let centralSize: Int
        let entryCount: Int
        var zip64EndOffset: Int?
        var locatorOffset: Int?
        if entryCount16 == UInt16.max || size32 == UInt32.max || offset32 == UInt32.max {
            let locator = endOffset - 20
            guard locator >= 0, try readUInt32(archive, at: locator) == 0x0706_4B50 else {
                throw ZipTestSupportError.fixture("ZIP64 locator is missing")
            }
            let relativeRecord = try readUInt64(archive, at: locator + 8)
            let recordSignature = Data([0x50, 0x4B, 0x06, 0x06])
            guard let recordRange = archive.range(
                of: recordSignature,
                options: .backwards,
                in: archive.startIndex..<locator
            ) else {
                throw ZipTestSupportError.fixture("ZIP64 end record is missing")
            }
            let record = recordRange.lowerBound
            guard relativeRecord <= UInt64(record) else {
                throw ZipTestSupportError.fixture("ZIP64 archive base underflows")
            }
            archiveBase = record - Int(relativeRecord)
            let count64 = try readUInt64(archive, at: record + 32)
            let size64 = try readUInt64(archive, at: record + 40)
            let offset64 = try readUInt64(archive, at: record + 48)
            guard count64 <= UInt64(Int.max), size64 <= UInt64(Int.max),
                  offset64 <= UInt64(Int.max) else {
                throw ZipTestSupportError.fixture("ZIP64 layout value does not fit Int")
            }
            entryCount = Int(count64)
            centralSize = Int(size64)
            centralOffset = archiveBase + Int(offset64)
            zip64EndOffset = record
            locatorOffset = locator
        } else {
            let relativeOffset = Int(offset32)
            centralSize = Int(size32)
            archiveBase = endOffset - centralSize - relativeOffset
            centralOffset = archiveBase + relativeOffset
            entryCount = Int(entryCount16)
        }

        guard archiveBase >= 0, centralOffset >= 0, centralSize >= 0,
              centralOffset <= archive.count,
              centralSize <= archive.count - centralOffset else {
            throw ZipTestSupportError.fixture("central-directory layout is outside the archive")
        }
        var centralEntries: [Int] = []
        var localHeaders: [Int] = []
        centralEntries.reserveCapacity(entryCount)
        localHeaders.reserveCapacity(entryCount)
        var cursor = centralOffset
        for _ in 0..<entryCount {
            guard try readUInt32(archive, at: cursor) == 0x0201_4B50 else {
                throw ZipTestSupportError.fixture("central entry signature is invalid")
            }
            centralEntries.append(cursor)
            let nameLength = Int(try readUInt16(archive, at: cursor + 28))
            let extraLength = Int(try readUInt16(archive, at: cursor + 30))
            let commentLength = Int(try readUInt16(archive, at: cursor + 32))
            let localOffset = try readUInt32(archive, at: cursor + 42)
            if localOffset == UInt32.max {
                localHeaders.append(-1)
            } else {
                localHeaders.append(archiveBase + Int(localOffset))
            }
            cursor += 46 + nameLength + extraLength + commentLength
            guard cursor <= centralOffset + centralSize else {
                throw ZipTestSupportError.fixture("central entry overruns the directory")
            }
        }
        return ZipFixtureLayout(
            archiveBase: archiveBase,
            centralDirectoryOffset: centralOffset,
            centralDirectorySize: centralSize,
            centralEntryOffsets: centralEntries,
            localHeaderOffsets: localHeaders,
            endRecordOffset: endOffset,
            zip64EndRecordOffset: zip64EndOffset,
            zip64LocatorOffset: locatorOffset
        )
    }

    static func readUInt16(_ data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset <= data.count, data.count - offset >= 2 else {
            throw ZipTestSupportError.fixture("UInt16 read is outside fixture data")
        }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    static func readUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= data.count, data.count - offset >= 4 else {
            throw ZipTestSupportError.fixture("UInt32 read is outside fixture data")
        }
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    static func readUInt64(_ data: Data, at offset: Int) throws -> UInt64 {
        UInt64(try readUInt32(data, at: offset))
            | UInt64(try readUInt32(data, at: offset + 4)) << 32
    }

    static func writeUInt16(_ value: UInt16, to data: inout Data, at offset: Int) throws {
        try replace(
            [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)],
            in: &data,
            at: offset
        )
    }

    static func writeUInt32(_ value: UInt32, to data: inout Data, at offset: Int) throws {
        try replace(
            (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32($0 * 8)) },
            in: &data,
            at: offset
        )
    }

    static func writeUInt64(_ value: UInt64, to data: inout Data, at offset: Int) throws {
        try replace(
            (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) },
            in: &data,
            at: offset
        )
    }

    private static func appendZIP64End(
        entryCount: UInt64,
        centralOffset: UInt64,
        centralSize: UInt64,
        to data: inout Data
    ) {
        let recordOffset = UInt64(data.count)
        appendUInt32(0x0606_4B50, to: &data)
        appendUInt64(44, to: &data)
        appendUInt16(45, to: &data)
        appendUInt16(45, to: &data)
        appendUInt32(0, to: &data)
        appendUInt32(0, to: &data)
        appendUInt64(entryCount, to: &data)
        appendUInt64(entryCount, to: &data)
        appendUInt64(centralSize, to: &data)
        appendUInt64(centralOffset, to: &data)

        appendUInt32(0x0706_4B50, to: &data)
        appendUInt32(0, to: &data)
        appendUInt64(recordOffset, to: &data)
        appendUInt32(1, to: &data)

        appendUInt32(0x0605_4B50, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(UInt16.max, to: &data)
        appendUInt16(UInt16.max, to: &data)
        appendUInt32(UInt32.max, to: &data)
        appendUInt32(UInt32.max, to: &data)
        appendUInt16(0, to: &data)
    }

    private static func appendEndRecord(
        entryCount: UInt16,
        centralOffset: UInt32,
        centralSize: UInt32,
        comment: Data,
        to data: inout Data
    ) {
        appendUInt32(0x0605_4B50, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(entryCount, to: &data)
        appendUInt16(entryCount, to: &data)
        appendUInt32(centralSize, to: &data)
        appendUInt32(centralOffset, to: &data)
        appendUInt16(UInt16(comment.count), to: &data)
        data.append(comment)
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 0, to: 64, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    private static func replace(_ bytes: [UInt8], in data: inout Data, at offset: Int) throws {
        guard offset >= 0, offset <= data.count, bytes.count <= data.count - offset else {
            throw ZipTestSupportError.fixture("fixture write is outside data")
        }
        data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
}
