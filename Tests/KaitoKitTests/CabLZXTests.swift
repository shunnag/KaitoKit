// Microsoft [MS-PATCH]、[MS-CAB] と自作標本に基づく。cabextract は展開オラクルとしてのみ使用する。
import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

final class CabLZXTests: XCTestCase {
    private struct Manifest: Decodable {
        let fixtures: [Fixture]
    }
    private struct Fixture: Decodable {
        let name, archive: String
        let cab_sha256: String
        let files: [File]
    }
    private struct File: Decodable {
        let name, sha256: String
        let size: UInt64
        let folder: Int
    }
    private struct Frame {
        let header, start, count, size, folder: Int
    }
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private var fixtures: URL { root.appendingPathComponent("Tests/Fixtures/cab-lzx") }

    private func manifest(at directory: URL) throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
    }
    private func archive(_ fixture: Fixture, at directory: URL) throws -> Data {
        let bytes = try Data(contentsOf: directory.appendingPathComponent(fixture.archive))
        let data = fixture.archive.hasSuffix(".b64")
            ? try XCTUnwrap(Data(base64Encoded: bytes, options: .ignoreUnknownCharacters)) : bytes
        XCTAssertEqual(sha(data), fixture.cab_sha256, fixture.name)
        return data
    }
    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func assertFiles(_ reader: ArchiveReader, _ fixture: Fixture, tiny: Bool = false) throws {
        XCTAssertEqual(reader.entries.map(\.name), fixture.files.map(\.name), fixture.name)
        XCTAssertEqual(reader.entries.map(\.uncompressedSize), fixture.files.map { Optional($0.size) }, fixture.name)
        for (entry, file) in zip(reader.entries, fixture.files) {
            XCTAssertEqual(entry.methodDescription, "cab (LZX)")
            XCTAssertEqual(entry.solidGroup, file.folder)
            let result: Data
            if tiny {
                let stream = try reader.stream(entry)
                var data = Data(), buffer = [UInt8](repeating: 0, count: 7)
                while true {
                    let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
                    if count == 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                result = data
            } else {
                result = try reader.read(entry)
            }
            XCTAssertEqual(UInt64(result.count), file.size, "\(fixture.name)/\(file.name)")
            XCTAssertEqual(sha(result), file.sha256, "\(fixture.name)/\(file.name)")
        }
    }

    func testFixedFixturesAndReopen() throws {
        for fixture in try manifest(at: fixtures).fixtures {
            let reader = try ArchiveReader.open(data: archive(fixture, at: fixtures))
            try assertFiles(reader, fixture)
            try assertFiles(reader.reopen(), fixture)
        }
    }

    func testTinyStreamsAndBackwardFilesFirst() throws {
        for fixture in try manifest(at: fixtures).fixtures {
            let reader = try ArchiveReader.open(data: archive(fixture, at: fixtures))
            for (entry, file) in zip(reader.entries, fixture.files).reversed() {
                XCTAssertEqual(sha(try reader.read(entry)), file.sha256, fixture.name)
            }
            try assertFiles(reader, fixture, tiny: true)
        }
    }

    private func executable(_ name: String) throws -> URL {
        let directories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in directories {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw XCTSkip("\(name) is unavailable")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kaito-lzx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func run(_ executable: URL, _ arguments: [String], log: URL) throws {
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = try String(contentsOf: log, encoding: .utf8)
            XCTFail("\(executable.lastPathComponent) exit \(process.terminationStatus): \(output)")
            throw KaitoError.malformed("CAB test subprocess failed")
        }
    }

    private func compareOracle(_ cab: URL, oracle: URL, directory: URL) throws -> Int {
        let output = directory.appendingPathComponent(UUID().uuidString)
        try run(oracle, ["-q", "-d", output.path, cab.path], log: directory.appendingPathComponent("oracle.log"))
        let reader = try ArchiveReader.open(url: cab)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: output, includingPropertiesForKeys: [.isRegularFileKey]))
        var extracted = Set<String>()
        for case let url as URL in files {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                extracted.insert(String(url.resolvingSymlinksInPath().path.dropFirst(output.resolvingSymlinksInPath().path.count + 1)))
            }
        }
        XCTAssertEqual(extracted, Set(reader.entries.map(\.name)), cab.lastPathComponent)
        for entry in reader.entries {
            let expected = try Data(contentsOf: output.appendingPathComponent(entry.name))
            let actual = try reader.read(entry)
            XCTAssertEqual(actual.count, expected.count, entry.name)
            XCTAssertEqual(sha(actual), sha(expected), "\(cab.lastPathComponent)/\(entry.name)")
        }
        return reader.entries.count
    }

    func testTwentyGeneratedArchivesAgainstCabextract() throws {
        let python = try executable("python3"), oracle = try executable("cabextract")
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("generator.log")
        try run(python, [root.appendingPathComponent("Scripts/fixtures/make-cab-lzx.py").path,
            "--output", directory.path, "--random", "20", "--seed", "20260912", "--cabextract", oracle.path], log: log)
        print(try String(contentsOf: log, encoding: .utf8))
        let generated = try manifest(at: directory)
        XCTAssertEqual(generated.fixtures.count, 20)
        for fixture in generated.fixtures {
            let cab = directory.appendingPathComponent(fixture.archive)
            XCTAssertEqual(try compareOracle(cab, oracle: oracle, directory: directory), fixture.files.count)
            try assertFiles(ArchiveReader.open(data: archive(fixture, at: directory)), fixture)
        }
    }

    func testExternalCorpusAgainstCabextract() throws {
        guard let path = ProcessInfo.processInfo.environment["KAITOKIT_CAB_CORPUS"], !path.isEmpty else {
            throw XCTSkip("KAITOKIT_CAB_CORPUS is not configured")
        }
        let oracle = try executable("cabextract")
        let corpus = URL(fileURLWithPath: path, isDirectory: true)
        let contents = try XCTUnwrap(FileManager.default.enumerator(at: corpus, includingPropertiesForKeys: nil))
        let archives = contents.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "cab" }
            .sorted { $0.path < $1.path }
        guard !archives.isEmpty else { throw XCTSkip("No CAB archives in KAITOKIT_CAB_CORPUS") }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for cab in archives {
            let count = try compareOracle(cab, oracle: oracle, directory: directory)
            print("CAB corpus OK \(cab.lastPathComponent): \(count) files")
        }
    }

    private func continuedCabinet1(source: Data? = nil, nextCabinet: Bool = true,
                                   splitBlock: Bool = true) throws -> (Data, Fixture) {
        let fixture = try XCTUnwrap(manifest(at: fixtures).fixtures.first { $0.name == "verbatim-w15" })
        var bytes = try source ?? archive(fixture, at: fixtures)
        let last = try XCTUnwrap(frames(bytes).last)
        XCTAssertEqual(last.start + last.count, bytes.count)
        if splitBlock {
            // 最終 CFDATA の前半だけを残し、次巻で完成する分割ブロックの検査値へ更新する。
            let count = last.count / 2
            bytes.removeSubrange((last.start + count)..<bytes.count)
            write(count, &bytes, last.header + 4, 2)
            write(0, &bytes, last.header + 6, 2)
            let block = try CabDataBlock(Array(bytes[last.header..<last.start]), dataOffset: UInt64(last.start))
            write(Int(block.computedChecksum(Array(bytes[last.start...]))), &bytes, last.header)
        } else {
            // 分割 CFDATA がなくても NEXT_CABINET があれば最後の folder は継続する。
            bytes.removeSubrange(last.header..<bytes.count)
            write(le(bytes, 40, 2) - 1, &bytes, 40, 2)
        }
        var fileOffset = le(bytes, 16)
        for index in fixture.files.indices {
            if index == fixture.files.count - 1 { write(0xfffe, &bytes, fileOffset + 8, 2) }
            fileOffset += 16
            while bytes[fileOffset] != 0 { fileOffset += 1 }
            fileOffset += 1
        }
        if nextCabinet {
            let names = Data("next.cab\0next disk\0".utf8)
            let dataOffset = le(bytes, 36), filesOffset = le(bytes, 16)
            bytes.insert(contentsOf: names, at: 36)
            write(2, &bytes, 30, 2)
            write(filesOffset + names.count, &bytes, 16)
            write(dataOffset + names.count, &bytes, 36 + names.count)
        }
        write(bytes.count, &bytes, 8)
        return (bytes, fixture)
    }

    func testContinuedFolderReadsContainedFiles() throws {
        for (nextCabinet, splitBlock) in [(true, true), (true, false), (false, true)] {
            let (bytes, fixture) = try continuedCabinet1(nextCabinet: nextCabinet, splitBlock: splitBlock)
            let reader = try ArchiveReader.open(data: bytes)
            XCTAssertEqual(reader.entries.map(\.name), fixture.files.map(\.name))
            for index in [2, 0, 1, 2] {
                let data = try reader.read(reader.entries[index])
                XCTAssertEqual(UInt64(data.count), fixture.files[index].size)
                XCTAssertEqual(sha(data), fixture.files[index].sha256)
            }
            XCTAssertThrowsError(try reader.stream(reader.entries[3])) { error in
                guard case KaitoError.unsupportedMethod("cab multi-cabinet set") = error else {
                    return XCTFail("\(error)")
                }
            }
        }
        // 次巻へ続く folder では、この cabinet の最後も短い frame にしてはならない。
        let decoder = try LZXDecoder(windowBits: 15, outputSize: 1, dictionarySizeLimit: 32768, folderContinues: true)
        assertDamage { _ = try decoder.decodeFrame(input: [0, 0], outputSize: 1) }
    }

    func testContinuedFolderContainedFilesAgainstCabextract() throws {
        let oracle = try executable("cabextract"), python = try executable("python3")
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 小型標本では cabextract 1.11 が末尾 split の次巻不足で先頭側も失敗する。
        // 元の先頭三ファイルを保ち、continued file に一 frame を足した literal 版も照合する。
        let full = directory.appendingPathComponent("full.cab")
        let generate = """
        import runpy, sys
        from pathlib import Path
        api = runpy.run_path(sys.argv[1])
        _, folders = next(case for case in api['fixed_cases']() if case[0] == 'verbatim-w15')
        original = folders[0]
        files = list(original['files'])
        name, payload = files[-1]
        files[-1] = (name, payload + bytes(range(256)) * 128)
        blocks = [dict(block, literal_only=True) for block in original['blocks']]
        blocks[-1]['size'] += 32768
        folder = api['folder'](15, b''.join(payload for _, payload in files), blocks, files)
        path = Path(sys.argv[2])
        path.write_bytes(api['cabinet']([folder]))
        api['verify'](path, [folder], sys.argv[3])
        """
        try run(python, ["-c", generate, root.appendingPathComponent("Scripts/fixtures/make-cab-lzx.py").path,
            full.path, oracle.path], log: directory.appendingPathComponent("generator.log"))
        let (bytes, fixture) = try continuedCabinet1(source: Data(contentsOf: full))
        let cab = directory.appendingPathComponent("cabinet-1.cab")
        let output = directory.appendingPathComponent("extracted")
        try bytes.write(to: cab)
        let reader = try ArchiveReader.open(data: bytes)
        for (entry, file) in zip(reader.entries, fixture.files).dropLast() {
            try run(oracle, ["-q", "-s", "-F", file.name, "-d", output.path, cab.path],
                log: directory.appendingPathComponent("oracle.log"))
            let actual = try Data(contentsOf: output.appendingPathComponent(file.name))
            XCTAssertEqual(UInt64(actual.count), file.size)
            XCTAssertEqual(sha(actual), file.sha256)
            XCTAssertEqual(try reader.read(entry), actual)
        }
    }

    private func le(_ data: Data, _ offset: Int, _ count: Int = 4) -> Int {
        (0..<count).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
    }
    private func write(_ value: Int, _ data: inout Data, _ offset: Int, _ count: Int = 4) {
        for i in 0..<count { data[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
    }
    private func frames(_ data: Data) -> [Frame] {
        var result: [Frame] = []
        for folder in 0..<le(data, 26, 2) {
            var offset = le(data, 36 + folder * 8)
            for _ in 0..<le(data, 40 + folder * 8, 2) {
                let count = le(data, offset + 4, 2), size = le(data, offset + 6, 2)
                result.append(Frame(header: offset, start: offset + 8, count: count, size: size, folder: folder))
                offset += 8 + count
            }
        }
        return result
    }
    private func assertDamage(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            switch error {
            case KaitoError.truncated, KaitoError.malformed, KaitoError.checksumMismatch: break
            default: XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
        }
    }
    private func readAll(_ data: Data) throws {
        let reader = try ArchiveReader.open(data: data)
        for entry in reader.entries { _ = try reader.read(entry) }
    }

    func testTruncatedCFDATAAndTwentyFourBitFlipsPerFixture() throws {
        for fixture in try manifest(at: fixtures).fixtures {
            let original = try archive(fixture, at: fixtures)
            let frames = frames(original), first = try XCTUnwrap(frames.first)
            for cut in [(original.count - first.start) / 4, (original.count - first.start) / 2,
                        (original.count - first.start) * 9 / 10, original.count - first.start - 1] {
                assertDamage { try readAll(Data(original.prefix(first.start + cut))) }
            }
            let positions = frames.flatMap { Array($0.start..<($0.start + $0.count)) }
            for index in 0..<24 {
                var damaged = original
                damaged[positions[index * positions.count / 24]] ^= 1 << (index % 8)
                assertDamage { try readAll(damaged) }
            }
            // CFDATA のメタデータ検査を通さず、各フォルダーの末尾フレームの切断も直接検査する。
            for folder in Set(frames.map(\.folder)).sorted() {
                let group = frames.filter { $0.folder == folder }
                let last = try XCTUnwrap(group.last)
                for cut in [last.count / 4, last.count / 2, last.count * 9 / 10, last.count - 1] {
                    let decoder = try LZXDecoder(windowBits: le(original, 42 + folder * 8, 2) >> 8,
                        outputSize: UInt64(group.reduce(0) { $0 + $1.size }), dictionarySizeLimit: 1 << 21)
                    for frame in group.dropLast() {
                        _ = try decoder.decodeFrame(input: Array(original[frame.start..<(frame.start + frame.count)]), outputSize: frame.size)
                    }
                    assertDamage {
                        _ = try decoder.decodeFrame(input: Array(original[last.start..<(last.start + cut)]), outputSize: last.size)
                    }
                }
            }
        }
    }

    func testWindowBitsAndDictionaryLimit() throws {
        let fixture = try XCTUnwrap(manifest(at: fixtures).fixtures.first)
        let original = try archive(fixture, at: fixtures)
        for bits in [0, 14, 22, 31] {
            var damaged = original
            write((bits << 8) | 3, &damaged, 42, 2)
            assertDamage { try readAll(damaged) }
        }
        let reader = try ArchiveReader.open(data: original, options: ReaderOptions(limits: ReadLimits(maxDictionarySize: 32767)))
        XCTAssertThrowsError(try reader.stream(reader.entries[0])) { error in
            guard case KaitoError.limitExceeded = error else { return XCTFail("\(error)") }
        }
    }

    func testOnlyConsumedFramesAreChecksummedAndEmptyEntriesConsumeNothing() throws {
        let fixture = try XCTUnwrap(manifest(at: fixtures).fixtures.first { $0.name == "verbatim-w15" })
        var bytes = try archive(fixture, at: fixtures)
        let frames = frames(bytes)
        for frame in frames.prefix(2) { bytes[frame.header] ^= 1 }
        let reader = try ArchiveReader.open(data: bytes)
        XCTAssertEqual(sha(try reader.read(reader.entries[3])), fixture.files[3].sha256)
        XCTAssertEqual(try reader.read(reader.entries[1]), Data())
        assertDamage { _ = try reader.read(reader.entries[0]) }
        // 検査値ゼロは既存の None/MSZIP と同様に検査対象外。
        for frame in frames { write(0, &bytes, frame.header) }
        try assertFiles(ArchiveReader.open(data: bytes), fixture)
    }

    func testLastFrameDamageDoesNotAffectEarlierFiles() throws {
        let fixture = try XCTUnwrap(manifest(at: fixtures).fixtures.first { $0.name == "verbatim-w15" })
        var bytes = try archive(fixture, at: fixtures)
        let last = try XCTUnwrap(frames(bytes).last)
        bytes[last.start] ^= 1
        let reader = try ArchiveReader.open(data: bytes)
        XCTAssertEqual(sha(try reader.read(reader.entries[0])), fixture.files[0].sha256)
        XCTAssertEqual(try reader.read(reader.entries[1]), Data())
        assertDamage { _ = try reader.read(reader.entries[3]) }
        XCTAssertEqual(sha(try reader.read(reader.entries[0])), fixture.files[0].sha256)
    }

    private struct Bits {
        var bytes: [UInt8] = []
        private var word = 0, used = 0

        mutating func put(_ value: Int, _ width: Int) {
            for shift in stride(from: width - 1, through: 0, by: -1) {
                word = word << 1 | ((value >> shift) & 1)
                used += 1
                if used == 16 {
                    bytes.append(UInt8(truncatingIfNeeded: word))
                    bytes.append(UInt8(truncatingIfNeeded: word >> 8))
                    word = 0; used = 0
                }
            }
        }
        mutating func finish() -> [UInt8] {
            if used != 0 { put(0, 16 - used) }
            return bytes
        }
        mutating func preSymbol(_ symbol: Int) {
            if symbol < 12 { put(symbol, 4) } else { put(symbol + 12, 5) }
        }
        mutating func pretree() {
            for symbol in 0..<20 { put(symbol < 12 ? 4 : 5, 4) }
        }
        mutating func tree(_ lengths: [Int]) {
            pretree()
            for length in lengths { preSymbol((17 - length) % 17) }
        }
    }

    private func header(type: Int = 1, size: Int, e8: Bool = false) -> Bits {
        var bits = Bits()
        bits.put(e8 ? 1 : 0, 1)
        if e8 { bits.put(0, 16); bits.put(0, 16) }
        bits.put(type, 3)
        bits.put(size, 24)
        return bits
    }
    private func tokenFrame(size: Int, slot: Int, length: Int, literals: Int, matches: Int) -> [UInt8] {
        var bits = header(size: size)
        var main = [Int](repeating: 0, count: 496)
        main[65] = 1
        main[256 + slot * 8 + min(length - 2, 7)] = 1
        var lengths = [Int](repeating: 0, count: 249)
        lengths[0] = 1; lengths[248] = 1
        bits.tree(Array(main[..<256])); bits.tree(Array(main[256...])); bits.tree(lengths)
        for _ in 0..<literals { bits.put(0, 1) }
        for _ in 0..<matches {
            bits.put(1, 1)
            if length >= 9 { bits.put(length == 257 ? 1 : 0, 1) }
        }
        return bits.finish()
    }
    private func decode(_ input: [UInt8], frameSize: Int, total: UInt64? = nil) throws -> [UInt8] {
        let decoder = try LZXDecoder(windowBits: 15, outputSize: total ?? UInt64(frameSize), dictionarySizeLimit: 32768)
        return try decoder.decodeFrame(input: input, outputSize: frameSize)
    }

    func testInvalidBlockTypesSizesAndMissingBlocks() throws {
        for type in [0, 4, 5, 6, 7] {
            var bits = header(type: type, size: 1)
            assertDamage { _ = try decode(bits.finish(), frameSize: 1) }
        }
        for size in [0, 2, 0xFFFFFF] {
            var bits = header(size: size)
            assertDamage { _ = try decode(bits.finish(), frameSize: 1) }
        }
        let smallBlock = tokenFrame(size: 1, slot: 0, length: 2, literals: 1, matches: 0)
        assertDamage { _ = try decode(smallBlock, frameSize: 2) }
        assertDamage { _ = try decode(smallBlock, frameSize: 1, total: 40000) }
        assertDamage { _ = try decode([], frameSize: 0) }
        assertDamage { _ = try decode([], frameSize: 32769) }
        assertDamage { _ = try decode([0], frameSize: 1) }
        var extra = smallBlock
        extra.append(contentsOf: [0, 0])
        assertDamage { _ = try decode(extra, frameSize: 1) }
    }

    func testMatchesCannotExceedHistoryBlockOrFrame() throws {
        for slot in 0...3 {
            let bytes = tokenFrame(size: 2, slot: slot, length: 2, literals: 0, matches: 1)
            assertDamage { _ = try decode(bytes, frameSize: 2) }
        }
        let shortBlock = tokenFrame(size: 4, slot: 0, length: 257, literals: 1, matches: 1)
        assertDamage { _ = try decode(shortBlock, frameSize: 4) }
        // ブロックには余地があっても、最後の一致がフレーム境界を跨ぐ場合は拒否する。
        let crossesFrame = tokenFrame(size: 33000, slot: 0, length: 257, literals: 1, matches: 128)
        assertDamage { _ = try decode(crossesFrame, frameSize: 32768, total: 33000) }
        let maximumMatch = tokenFrame(size: 258, slot: 0, length: 257, literals: 1, matches: 1)
        XCTAssertEqual(try decode(maximumMatch, frameSize: 258), [UInt8](repeating: 65, count: 258))
    }

    func testHuffmanKraftViolationsAndSixteenBitFallback() throws {
        for lengths in [[1], [1, 1, 1], [2, 2], [0, 0], [17, 1], [-1, 1]] {
            assertDamage { _ = try LZXHuffmanTable(lengths: lengths) }
        }
        let empty = try LZXHuffmanTable(lengths: [0, 0], allowEmpty: true)
        var emptyBits = LZXBitReader([0, 0])
        assertDamage { _ = try empty.decode(&emptyBits) }
        let table = try LZXHuffmanTable(lengths: Array(1...15) + [16, 16])
        var longBits = LZXBitReader([255, 255])
        XCTAssertEqual(try table.decode(&longBits), 16)
        try longBits.finishFrame()
        var shortBits = LZXBitReader([0, 0])
        XCTAssertEqual(try table.decode(&shortBits), 0)
        // 不正な木を実際のブロックヘッダーから読み込ませる。
        for width in [0, 1, 15] {
            var bits = header(size: 1)
            for _ in 0..<20 { bits.put(width, 4) }
            assertDamage { _ = try decode(bits.finish(), frameSize: 1) }
        }
        for width in [0, 1, 7] {
            var bits = header(type: 2, size: 1)
            for _ in 0..<8 { bits.put(width, 3) }
            assertDamage { _ = try decode(bits.finish(), frameSize: 1) }
        }
    }

    func testPretreeRunsCannotOverflowAndCodeNineteenRequiresDelta() throws {
        var bits = header(size: 1)
        bits.pretree()
        for _ in 0..<6 { bits.preSymbol(18); bits.put(31, 5) }
        assertDamage { _ = try decode(bits.finish(), frameSize: 1) }
        bits = header(size: 1)
        bits.pretree()
        bits.preSymbol(19); bits.put(0, 1); bits.preSymbol(17)
        assertDamage { _ = try decode(bits.finish(), frameSize: 1) }
        // 17 と 19 の短い反復も半分の主木を越えて書き込めない。
        for symbol in [17, 19] {
            bits = header(size: 1)
            bits.pretree()
            for _ in 0..<254 { bits.preSymbol(0) }
            bits.preSymbol(symbol)
            bits.put(0, symbol == 17 ? 4 : 1)
            if symbol == 19 { bits.preSymbol(0) }
            assertDamage { _ = try decode(bits.finish(), frameSize: 1) }
        }
    }

    func testBitReaderWordOrderAlignmentAndTruncation() throws {
        var bits = LZXBitReader([0x34, 0x12, 0xcd, 0xab])
        XCTAssertEqual(try bits.read(4), 1)
        XCTAssertEqual(try bits.read(12), 0x234)
        XCTAssertEqual(try bits.read(16), 0xabcd)
        try bits.finishFrame()
        assertDamage { _ = try bits.read(1) }
        bits = LZXBitReader([0, 0, 0x78, 0x56, 0x34, 0x12])
        try bits.beginRaw()
        XCTAssertEqual(try bits.readRawOffset(), 0x12345678)
        try bits.finishFrame()
        bits = LZXBitReader([0])
        assertDamage { _ = try bits.read(1) }
        bits = LZXBitReader([1, 0])
        assertDamage { try bits.beginRaw() }
    }

    func testUncompressedOffsetsAndPaddingMustBeValid() throws {
        // 生データ用のヘッダーは先頭ビットを含めて二ワードに収まる。
        func raw(offset: UInt32 = 1, pad: UInt8 = 0) -> [UInt8] {
            var bits = header(type: 3, size: 1)
            var data = bits.finish()
            for value in [offset, 1, 1] as [UInt32] {
                for shift in stride(from: 0, to: 32, by: 8) {
                    data.append(UInt8(truncatingIfNeeded: value >> shift))
                }
            }
            return data + [65, pad]
        }
        XCTAssertEqual(try decode(raw(), frameSize: 1), [65])
        for offset: UInt32 in [0, 32768, UInt32.max] {
            assertDamage { _ = try decode(raw(offset: offset), frameSize: 1) }
        }
        assertDamage { _ = try decode(raw(pad: 1), frameSize: 1) }
        assertDamage { _ = try decode(Array(raw().dropLast()), frameSize: 1) }
    }

    func testNewStreamsInvalidateOlderStreamsAcrossFolders() throws {
        let fixture = try XCTUnwrap(manifest(at: fixtures).fixtures.first { $0.name == "multi-folder" })
        let reader = try ArchiveReader.open(data: archive(fixture, at: fixtures))
        let first = try reader.stream(reader.entries[0])
        var byte: UInt8 = 0
        XCTAssertEqual(try withUnsafeMutableBytes(of: &byte) { try first.read(into: $0) }, 1)
        let second = try reader.stream(reader.entries[1])
        assertDamage { _ = try withUnsafeMutableBytes(of: &byte) { try first.read(into: $0) } }
        XCTAssertEqual(sha(try second.readAll()), fixture.files[1].sha256)
        try assertFiles(reader, fixture)
    }
}
