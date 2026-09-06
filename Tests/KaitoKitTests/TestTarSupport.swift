import Foundation

enum TarTestSupportError: Error {
    case fieldTooLong(String)
    case commandFailed(String)
}

struct HandTarEntry {
    let name: String
    let contents: Data
    let type: UInt8
    let linkName: String
    let mode: UInt64
    let modificationTime: UInt64

    init(
        name: String,
        contents: Data = Data(),
        type: UInt8 = Character("0").asciiValue ?? 0,
        linkName: String = "",
        mode: UInt64 = 0o644,
        modificationTime: UInt64 = 1_700_000_000
    ) {
        self.name = name
        self.contents = contents
        self.type = type
        self.linkName = linkName
        self.mode = mode
        self.modificationTime = modificationTime
    }
}

enum TarTestSupport {
    static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KaitoKitTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }

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

    static func createBSDTar(
        format: String,
        sourceDirectory: URL,
        paths: [String],
        archiveURL: URL
    ) throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments = [
            "-cf", archiveURL.path,
            "--format", format,
            "-C", sourceDirectory.path,
        ] + paths
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let errorText = String(
            decoding: errors.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw TarTestSupportError.commandFailed(errorText)
        }
    }

    static func makeTar(entries: [HandTarEntry], terminated: Bool = true) throws -> Data {
        var archive = Data()
        for entry in entries {
            let header = try makeHeader(for: entry)
            archive.append(contentsOf: header)
            archive.append(entry.contents)
            let remainder = entry.contents.count % 512
            if remainder != 0 {
                archive.append(Data(repeating: 0, count: 512 - remainder))
            }
        }
        if terminated {
            archive.append(Data(repeating: 0, count: 1_024))
        }
        return archive
    }

    private static func makeHeader(for entry: HandTarEntry) throws -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 512)
        try put(Array(entry.name.utf8), into: &header, offset: 0, width: 100)
        try put(octal(entry.mode, width: 8), into: &header, offset: 100, width: 8)
        try put(octal(0, width: 8), into: &header, offset: 108, width: 8)
        try put(octal(0, width: 8), into: &header, offset: 116, width: 8)
        try put(
            octal(UInt64(entry.contents.count), width: 12),
            into: &header,
            offset: 124,
            width: 12
        )
        try put(
            octal(entry.modificationTime, width: 12),
            into: &header,
            offset: 136,
            width: 12
        )
        for index in 148..<156 {
            header[index] = 0x20
        }
        header[156] = entry.type
        try put(Array(entry.linkName.utf8), into: &header, offset: 157, width: 100)
        try put(Array("ustar\0".utf8), into: &header, offset: 257, width: 6)
        try put(Array("00".utf8), into: &header, offset: 263, width: 2)

        let checksum = header.reduce(UInt64(0)) { $0 + UInt64($1) }
        let digits = Array(String(checksum, radix: 8).utf8)
        guard digits.count <= 6 else {
            throw TarTestSupportError.fieldTooLong("checksum")
        }
        let checksumField = [UInt8](repeating: 0x30, count: 6 - digits.count)
            + digits + [0, 0x20]
        try put(checksumField, into: &header, offset: 148, width: 8)
        return header
    }

    private static func octal(_ value: UInt64, width: Int) throws -> [UInt8] {
        let digits = Array(String(value, radix: 8).utf8)
        guard digits.count < width else {
            throw TarTestSupportError.fieldTooLong("octal field")
        }
        return [UInt8](repeating: 0x30, count: width - digits.count - 1) + digits + [0]
    }

    private static func put(
        _ bytes: [UInt8],
        into destination: inout [UInt8],
        offset: Int,
        width: Int
    ) throws {
        guard bytes.count <= width else {
            throw TarTestSupportError.fieldTooLong("tar header field")
        }
        destination.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
}
