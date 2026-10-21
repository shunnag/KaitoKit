import Foundation
import XCTest
@testable import KaitoKit

class RAR4BuilderTestCase: XCTestCase {
    struct FileFixture {
        let name: [UInt8]
        let contents: Data
        let flags: UInt16
        let method: UInt8

        init(name: [UInt8], contents: Data, flags: UInt16 = 0, method: UInt8 = 0x30) {
            self.name = name
            self.contents = contents
            self.flags = flags
            self.method = method
        }
    }

    func makeArchive(
        files: [FileFixture],
        mainFlags: UInt16 = 0
    ) -> Data {
        var archive = Data(RAR4Reader.signature)
        archive.append(contentsOf: makeMainHeader(flags: mainFlags))
        for file in files {
            archive.append(contentsOf: makeFileHeader(file))
            archive.append(file.contents)
        }
        archive.append(contentsOf: makeHeader(type: 0x7b, flags: 0, fields: []))
        return archive
    }

    func makeMainHeader(flags: UInt16 = 0) -> [UInt8] {
        makeHeader(type: 0x73, flags: flags, fields: [0, 0, 0, 0, 0, 0])
    }

    func makeFileHeader(_ file: FileFixture) -> [UInt8] {
        let crc = CRC32.checksum(file.contents)
        var fields: [UInt8] = []
        fields.appendLittleEndian(UInt32(file.contents.count))
        fields.appendLittleEndian(UInt32(file.contents.count))
        fields.append(2) // Windows 形式
        fields.appendLittleEndian(crc)
        fields.appendLittleEndian(UInt32(0)) // DOS 時刻なし
        fields.append(29)
        fields.append(file.method)
        fields.appendLittleEndian(UInt16(file.name.count))
        fields.appendLittleEndian(UInt32(0x20))
        fields.append(contentsOf: file.name)
        return makeHeader(
            type: 0x74,
            flags: file.flags | 0x8000,
            fields: fields
        )
    }

    func makeHeader(
        type: UInt8,
        flags: UInt16,
        fields: [UInt8]
    ) -> [UInt8] {
        var body: [UInt8] = [type]
        body.appendLittleEndian(flags)
        body.appendLittleEndian(UInt16(7 + fields.count))
        body.append(contentsOf: fields)
        var result: [UInt8] = []
        result.appendLittleEndian(UInt16(truncatingIfNeeded: CRC32.checksum(body)))
        result.append(contentsOf: body)
        return result
    }


}

class RAR4VolumeTestSupport: XCTestCase {
    func makeStoredVolume(
        payload: Data,
        unpackedSize: Int,
        fileCRC: UInt32,
        mainFlags: UInt16,
        fileFlags: UInt16,
        requestsNextVolume: Bool
    ) -> Data {
        makeStoredVolume(
            files: [("joined.txt", payload, unpackedSize, fileCRC, fileFlags)],
            mainFlags: mainFlags,
            requestsNextVolume: requestsNextVolume
        )
    }

    func makeStoredVolume(
        files: [(String, Data, Int, UInt32, UInt16)],
        mainFlags: UInt16,
        requestsNextVolume: Bool
    ) -> Data {
        var archive = Data(RAR4Reader.signature)
        archive.append(contentsOf: makeHeader(
            type: 0x73,
            flags: mainFlags,
            fields: [0, 0, 0, 0, 0, 0]
        ))
        for (name, payload, unpackedSize, fileCRC, fileFlags) in files {
            var fields: [UInt8] = []
            fields.appendLittleEndian(UInt32(payload.count))
            fields.appendLittleEndian(UInt32(unpackedSize))
            fields.append(2)
            fields.appendLittleEndian(fileCRC)
            fields.appendLittleEndian(UInt32(0))
            fields.append(29)
            fields.append(0x30)
            fields.appendLittleEndian(UInt16(name.utf8.count))
            fields.appendLittleEndian(UInt32(0x20))
            fields.append(contentsOf: name.utf8)
            archive.append(contentsOf: makeHeader(
                type: 0x74,
                flags: fileFlags | 0x8000,
                fields: fields
            ))
            archive.append(payload)
        }
        archive.append(contentsOf: makeHeader(
            type: 0x7b,
            flags: requestsNextVolume ? 0x0001 : 0,
            fields: []
        ))
        return archive
    }

    func makeHeader(type: UInt8, flags: UInt16, fields: [UInt8]) -> [UInt8] {
        var body = [type]
        body.appendLittleEndian(flags)
        body.appendLittleEndian(UInt16(7 + fields.count))
        body.append(contentsOf: fields)
        var header: [UInt8] = []
        header.appendLittleEndian(UInt16(truncatingIfNeeded: CRC32.checksum(body)))
        header.append(contentsOf: body)
        return header
    }
}


enum RAR4TestSupport {
    static var corpusDirectory: URL? {
        environmentURL("KAITOKIT_RAR4_CORPUS", isDirectory: true)
    }

    static var ppmdSolidArchive: URL? {
        environmentURL("KAITOKIT_RAR4_PPMD_SOLID_ARCHIVE", isDirectory: false)
            ?? corpusDirectory?.appendingPathComponent("ppmd_solid_rar300.rar")
    }

    static var filterArchive: URL? {
        environmentURL("KAITOKIT_RAR4_FILTER_ARCHIVE", isDirectory: false)
            ?? corpusDirectory?.appendingPathComponent("st1200-pts.rar")
    }

    private static func environmentURL(
        _ name: String,
        isDirectory: Bool
    ) -> URL? {
        guard let path = ProcessInfo.processInfo.environment[name], !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: isDirectory)
    }
}
