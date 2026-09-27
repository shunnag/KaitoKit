import Foundation
@_spi(LHARawLayout) @testable import KaitoKit
import Synchronization
import XCTest

final class LHARawLayoutTests: XCTestCase {
    func testFrozenLayoutsMatchPublicEntriesAndReopen() throws {
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var opened = 0
        for fixture in try LHAFrozenFixtures.all() {
            let url = try LHAFrozenFixtures.materialize(fixture, in: directory)
            if fixture.name == "tl-S8b" {
                XCTAssertThrowsError(try ArchiveReader.open(url: url)) {
                    XCTAssertEqual($0 as? KaitoError, .malformed("LHA header CRC mismatch"))
                }
                continue
            }
            let reader = try ArchiveReader.open(url: url)
            let layout = try XCTUnwrap(reader.lhaRawLayout(), fixture.name)
            XCTAssertEqual(layout.archiveLength, fixture.logicalSize, fixture.name)
            try assertEntries(reader, layout: layout, context: fixture.name)
            try assertEqual(layout, XCTUnwrap(reader.reopen().lhaRawLayout()))
            try assertFrozenShape(fixture, layout: layout)
            opened += 1
        }
        XCTAssertEqual(opened, 30)
    }

    func testEmptyArchiveAndEmptyDirectoryTerminator() throws {
        let empty = try ArchiveReader.open(source: DataByteSource(data: Data([0])),
                                           sourceURL: URL(fileURLWithPath: "/empty.lzh"))
        let layout = try XCTUnwrap(empty.lhaRawLayout())
        XCTAssertEqual(layout.archiveLength, 1)
        XCTAssertEqual(layout.firstHeaderOffset, 0)
        XCTAssertEqual(layout.endOfMembersOffset, 0)
        XCTAssertEqual(layout.memberCount, 0)
        XCTAssertEqual(layout.unpublishedMemberCount, 0)
        XCTAssertEqual(layout.terminator, .zeroByte(offset: 0))
        XCTAssertEqual(layout.trailingBytes, .none)
        try assertEqual(layout, XCTUnwrap(empty.reopen().lhaRawLayout()))

        let terminator = try LHATestSupport.makeMember(HandLHAEntry(name: "", method: "-lhd-", headerLevel: 2))
        let bytes = terminator + Data([1, 2, 3])
        let source = CountingByteSource(DataByteSource(data: bytes))
        let reader = try ArchiveReader.open(source: source)
        source.reset()
        let directoryLayout = try XCTUnwrap(reader.lhaRawLayout())
        XCTAssertEqual(directoryLayout.memberCount, 0)
        XCTAssertEqual(directoryLayout.endOfMembersOffset, 0)
        XCTAssertEqual(directoryLayout.firstHeaderOffset, 0)
        XCTAssertEqual(directoryLayout.terminator, .emptyNameDirectoryMember(0..<UInt64(terminator.count)))
        XCTAssertEqual(directoryLayout.trailingBytes, .notApplicable)
        XCTAssertEqual(source.bytesRead, 0)
    }

    func testAnonymousMembersAtEveryPositionAndEOF() throws {
        let names = ["", "first", "", "", "last", ""]
        var data = Data()
        var expected: [Range<UInt64>] = []
        for (position, name) in names.enumerated() {
            let bytes = try LHATestSupport.makeMember(HandLHAEntry(
                name: name, contents: Data([UInt8(position)]), headerLevel: UInt8(position % 4)))
            expected.append(UInt64(data.count)..<UInt64(data.count + bytes.count))
            data.append(bytes)
        }
        for terminated in [false, true] {
            let reader = try ArchiveReader.open(data: data + (terminated ? Data([0]) : Data()))
            let layout = try XCTUnwrap(reader.lhaRawLayout())
            XCTAssertEqual(layout.memberCount, 6)
            XCTAssertEqual(layout.unpublishedMemberCount, 4)
            XCTAssertEqual(layout.terminator, terminated ? .zeroByte(offset: UInt64(data.count)) : .endOfFile)
            XCTAssertEqual(layout.trailingBytes, terminated ? .none : .notApplicable)
            XCTAssertEqual(layout.endOfMembersOffset, UInt64(data.count))
            // 逆順・繰り返しの参照でも公開 index への対応は変わらない。
            for position in names.indices.reversed() {
                let member = try layout.member(at: position)
                XCTAssertEqual(member.headerRange.lowerBound, expected[position].lowerBound)
                XCTAssertEqual(member.dataRange.upperBound, expected[position].upperBound)
                XCTAssertEqual(member.dataRange.count, 1)
                XCTAssertEqual(member.entryIndex, position == 1 ? 0 : position == 4 ? 1 : nil)
                XCTAssertEqual(member.headerLevel, UInt8(position % 4))
            }
            try assertEntries(reader, layout: layout, context: "anonymous")
        }
    }

    func testLongLevelOneHeaderAndOSIdentifiers() throws {
        let entries = [
            HandLHAEntry(name: "no-os", contents: Data([1]), headerLevel: 0),
            HandLHAEntry(name: "binary-os", contents: Data([2]), headerLevel: 0, creatorOS: 0x01),
            HandLHAEntry(name: "extensions", contents: Data([3]), headerLevel: 1, creatorOS: 0xFE,
                         extraHeaders: [HandLHAExtendedHeader(0x3F, [UInt8](repeating: 7, count: 5_000))]),
        ]
        let reader = try ArchiveReader.open(data: LHATestSupport.makeArchive(entries: entries))
        let layout = try XCTUnwrap(reader.lhaRawLayout())
        XCTAssertNil(try layout.member(at: 0).osID)
        XCTAssertEqual(try layout.member(at: 1).osID, 0x01)
        XCTAssertEqual(try layout.member(at: 2).osID, 0xFE)
        XCTAssertGreaterThan(try layout.member(at: 2).headerRange.count, 4_096)
        XCTAssertEqual(try layout.member(at: 2).dataRange.count, 1)
        try assertEntries(reader, layout: layout, context: "extended header")
    }

    func testTrailingReadBoundariesAndNoReadForUncheckedTail() throws {
        let archive = try LHATestSupport.makeArchive(entries: [HandLHAEntry(name: "entry", headerLevel: 0)])
        for count in [0, 1, 65_536, 65_537] {
            for nonZero in [false, true] {
                var tail = Data(repeating: 0, count: count)
                if nonZero, count > 0 { tail[count - 1] = 1 }
                let controlled = LayoutReadSource(archive + tail)
                let source = CountingByteSource(controlled)
                let reader = try ArchiveReader.open(source: source)
                source.reset()
                controlled.reset()
                let layout = try XCTUnwrap(reader.lhaRawLayout())
                let expected: LHATrailingBytes = count == 0 ? .none : count > 65_536
                    ? .unchecked(count: UInt64(count)) : nonZero
                    ? .nonZero(count: UInt64(count)) : .zeros(count: UInt64(count))
                XCTAssertEqual(layout.trailingBytes, expected)
                XCTAssertEqual(source.bytesRead, count <= 65_536 ? UInt64(count) : 0)
                XCTAssertEqual(controlled.readCount, (1...65_536).contains(count) ? 1 : 0)
                XCTAssertEqual(controlled.lastOffset, (1...65_536).contains(count) ? UInt64(archive.count) : nil)
            }
        }
    }

    func testTailShortReadsAndReadFailures() throws {
        let archive = try LHATestSupport.makeArchive(entries: [HandLHAEntry(name: "entry", headerLevel: 0)])
        let source = LayoutReadSource(archive + Data([0, 0, 1]))
        let reader = try ArchiveReader.open(source: source)
        source.reset(.short)
        XCTAssertEqual(try reader.lhaRawLayout()?.trailingBytes, .nonZero(count: 3))
        XCTAssertEqual(source.readCount, 3)
        for (mode, expected): (LayoutReadSource.Mode, KaitoError) in [
            (.eof, .truncated), (.io, .io(EIO)), (.foreignError, .io(EIO)),
        ] {
            source.reset(mode)
            XCTAssertThrowsError(try reader.lhaRawLayout()) {
                XCTAssertEqual($0 as? KaitoError, expected)
            }
        }
    }

    func testRecoveryZIPAndSplitSourcesReturnNil() throws {
        let bytes = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(name: "entry", contents: Data([1, 2, 3]), headerLevel: 1),
        ])
        var options = ReaderOptions()
        options.recoverDamagedArchives = true
        for data in [bytes, Data(bytes.dropLast(2))] {
            let source = CountingByteSource(DataByteSource(data: data))
            let reader = try ArchiveReader.open(source: source, options: options)
            source.reset()
            XCTAssertNil(try reader.lhaRawLayout())
            XCTAssertNil(try reader.reopen().lhaRawLayout())
            XCTAssertEqual(source.bytesRead, 0)
        }
        let anonymous = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(name: "entry", headerLevel: 0), HandLHAEntry(name: "", headerLevel: 1),
        ])
        let recovered = try LHAHeaderParser.parse(source: DataByteSource(data: anonymous),
                                                  policy: options.encodingPolicy, limits: options.limits,
                                                  recoverDamagedArchives: true)
        XCTAssertNil(recovered.terminator)
        XCTAssertTrue(recovered.unpublishedMembers.isEmpty)

        let zip = try ArchiveReader.open(data: ZipTestSupport.makeArchive(entries: [HandZipEntry(name: "entry")]))
        XCTAssertNil(try zip.lhaRawLayout())

        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("split.lzh.001")
        try bytes.prefix(16).write(to: first)
        try bytes.dropFirst(16).write(to: directory.appendingPathComponent("split.lzh.002"))
        let split = try ArchiveReader.open(url: first)
        XCTAssertNotNil(split.volumeSet)
        XCTAssertEqual(split.format, .lha)
        XCTAssertNil(try split.lhaRawLayout())
        XCTAssertNil(try split.reopen().lhaRawLayout())

        let concatenated = try ConcatenatedByteSource(
            segments: [SourceSegment(source: DataByteSource(data: bytes), offset: 0, length: UInt64(bytes.count))],
            maximumLength: UInt64(bytes.count), label: "LHA test")
        let direct = try ArchiveReader.open(source: concatenated)
        XCTAssertNil(direct.volumeSet)
        XCTAssertNil(try direct.lhaRawLayout())
        XCTAssertNil(try direct.reopen().lhaRawLayout())
    }

    func testReopenAndDetachedLayoutDoNotReadSource() throws {
        let source = CountingByteSource(DataByteSource(data: try LHAFrozenFixtures.bytes(
            LHAFrozenFixtures.named("anonymous-middle"))))
        var reader: ArchiveReader? = try ArchiveReader.open(source: source)
        let layout = try XCTUnwrap(reader?.lhaRawLayout())
        source.reset()
        var reopened: ArchiveReader? = try reader?.reopen()
        XCTAssertEqual(source.bytesRead, 0)
        try assertEqual(layout, XCTUnwrap(reopened?.lhaRawLayout()))
        reader = nil
        reopened = nil
        XCTAssertEqual(try layout.member(at: 1).entryIndex, nil)
        XCTAssertEqual(try layout.member(at: 2).entryIndex, 1)
        XCTAssertEqual(source.bytesRead, 0)
    }

    func testInvalidPositions() throws {
        let reader = try ArchiveReader.open(data: LHATestSupport.makeArchive(entries: [HandLHAEntry(name: "entry", headerLevel: 0)]))
        let layout = try XCTUnwrap(reader.lhaRawLayout())
        for position in [Int.min, -1, layout.memberCount, Int.max] {
            XCTAssertThrowsError(try layout.member(at: position)) {
                XCTAssertEqual($0 as? KaitoError, .notFound("LHA member position \(position)"))
            }
        }
    }

    func testLayoutIgnoresCancellationAndIsSendable() async throws {
        let data = try LHATestSupport.makeArchive(entries: [HandLHAEntry(name: "entry", headerLevel: 1)]) + Data([0, 0])
        let task = Task.detached {
            let reader = try ArchiveReader.open(data: data)
            withUnsafeCurrentTask { $0?.cancel() }
            return try reader.lhaRawLayout()
        }
        let result = try await task.value
        let layout = try XCTUnwrap(result)
        XCTAssertEqual(layout.trailingBytes, .zeros(count: 2))
        XCTAssertEqual(try layout.member(at: 0).entryIndex, 0)
    }

    func testRecordStorageFitsExistingPadding() {
        XCTAssertLessThanOrEqual(MemoryLayout<LHAEntryRecord>.stride, 48 + 16)
    }

    private func assertFrozenShape(_ fixture: LHAFrozenFixtures.Fixture, layout: LHAArchiveLayout) throws {
        switch fixture.name {
        case "empty-name-directory-tail":
            guard case let .emptyNameDirectoryMember(range) = layout.terminator else {
                return XCTFail("expected empty-name directory terminator")
            }
            XCTAssertEqual(range.lowerBound, layout.endOfMembersOffset)
            let bytes = try LHAFrozenFixtures.bytes(fixture)
            let start = Int(range.lowerBound)
            let headerSize = UInt64(bytes[start]) | UInt64(bytes[start + 1]) << 8
            XCTAssertEqual(range.upperBound - range.lowerBound, headerSize)
            XCTAssertLessThan(range.upperBound, layout.archiveLength)
            XCTAssertEqual(layout.trailingBytes, .notApplicable)
        case "larc-lzs-eof":
            XCTAssertEqual(layout.terminator, .endOfFile)
            XCTAssertEqual(layout.endOfMembersOffset, layout.archiveLength)
            XCTAssertEqual(layout.trailingBytes, .notApplicable)
        default:
            XCTAssertEqual(layout.terminator, .zeroByte(offset: layout.endOfMembersOffset), fixture.name)
            let tailCount = layout.archiveLength - layout.endOfMembersOffset - 1
            switch fixture.name {
            case "tl-S5", "tl-S11":
                XCTAssertGreaterThan(tailCount, 0)
                XCTAssertEqual(layout.trailingBytes, .nonZero(count: tailCount))
                if fixture.name == "tl-S11" { XCTAssertEqual(layout.memberCount, 4) }
            case "tl-S5b":
                XCTAssertGreaterThan(tailCount, 0)
                XCTAssertEqual(layout.trailingBytes, .zeros(count: tailCount))
            default:
                XCTAssertEqual(layout.trailingBytes, .none, fixture.name)
            }
        }
        XCTAssertEqual(layout.unpublishedMemberCount, fixture.name == "anonymous-middle" ? 1 : 0, fixture.name)
        switch fixture.name {
        case "anonymous-middle":
            XCTAssertEqual(layout.memberCount, 3)
            XCTAssertNil(try layout.member(at: 1).entryIndex)
        case "sfx":
            XCTAssertGreaterThan(layout.firstHeaderOffset, 0)
        case "level3":
            XCTAssertEqual(try layout.member(at: 0).headerLevel, 3)
        case "os9-k-short-level2":
            let bytes = try LHAFrozenFixtures.bytes(fixture)
            let declared = Int(bytes[0]) | Int(bytes[1]) << 8
            XCTAssertEqual(try layout.member(at: 0).headerRange.count, declared + 2)
            XCTAssertEqual(try layout.member(at: 0).osID, 0x4B)
        case "lhark-lh7":
            XCTAssertEqual(try layout.member(at: 0).osID, 0x20)
        case "level1-large-packed":
            let member = try layout.member(at: 0)
            XCTAssertEqual(member.headerRange, 0..<62)
            XCTAssertEqual(member.dataRange.upperBound - member.dataRange.lowerBound, UInt64(UInt32.max) + 1)
        default: break
        }
    }

    private func assertEntries(_ reader: ArchiveReader, layout: LHAArchiveLayout, context: String) throws {
        var nextHeader = layout.firstHeaderOffset
        var entryIndices: [Int] = []
        for position in 0..<layout.memberCount {
            let member = try layout.member(at: position)
            XCTAssertEqual(member.headerRange.lowerBound, nextHeader, context)
            XCTAssertEqual(member.headerRange.upperBound, member.dataRange.lowerBound, context)
            nextHeader = member.dataRange.upperBound
            guard let index = member.entryIndex else { continue }
            entryIndices.append(index)
            let entry = reader.entries[index]
            XCTAssertEqual(member.headerRange.lowerBound, entry.formatSpecific["headerOffset"].flatMap(UInt64.init), context)
            XCTAssertEqual(member.dataRange.lowerBound, entry.formatSpecific["dataOffset"].flatMap(UInt64.init), context)
            XCTAssertEqual(member.dataRange.upperBound - member.dataRange.lowerBound, entry.compressedSize, context)
            XCTAssertEqual(member.headerLevel, entry.formatSpecific["headerLevel"].flatMap(UInt8.init), context)
            XCTAssertEqual(member.method, entry.methodDescription, context)
            XCTAssertEqual(member.crc16, entry.formatSpecific["dataCRC16"].flatMap { UInt16($0, radix: 16) }, context)
            let os = member.osID.map {
                (0x20...0x7E).contains($0) ? String(UnicodeScalar($0)) : String(format: "0x%02x", $0)
            }
            XCTAssertEqual(os, entry.formatSpecific["osID"], context)
            XCTAssertNil(try reader.rawRecord(of: entry), context)
        }
        XCTAssertEqual(entryIndices, Array(reader.entries.indices), context)
        XCTAssertEqual(layout.memberCount - layout.unpublishedMemberCount, reader.entries.count, context)
        XCTAssertEqual(nextHeader, layout.endOfMembersOffset, context)
    }

    private func assertEqual(_ left: LHAArchiveLayout, _ right: LHAArchiveLayout) throws {
        XCTAssertEqual(left.archiveLength, right.archiveLength)
        XCTAssertEqual(left.firstHeaderOffset, right.firstHeaderOffset)
        XCTAssertEqual(left.endOfMembersOffset, right.endOfMembersOffset)
        XCTAssertEqual(left.terminator, right.terminator)
        XCTAssertEqual(left.trailingBytes, right.trailingBytes)
        XCTAssertEqual(left.memberCount, right.memberCount)
        XCTAssertEqual(left.unpublishedMemberCount, right.unpublishedMemberCount)
        for position in 0..<left.memberCount {
            XCTAssertEqual(try left.member(at: position), try right.member(at: position))
        }
    }
}

private final class LayoutReadSource: ByteSource {
    enum Mode: Sendable { case normal, short, eof, io, foreignError }
    private struct State: Sendable {
        var mode: Mode = .normal
        var reads = 0
        var lastOffset: UInt64?
    }
    private struct ReadFailure: Error {}
    private let source: DataByteSource
    private let state = Mutex(State())
    var length: UInt64 { source.length }
    var readCount: Int { state.withLock { $0.reads } }
    var lastOffset: UInt64? { state.withLock { $0.lastOffset } }

    init(_ data: Data) { source = DataByteSource(data: data) }
    func reset(_ mode: Mode = .normal) { state.withLock { $0 = State(mode: mode) } }
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        let mode = state.withLock { state in
            state.reads += 1
            state.lastOffset = offset
            return state.mode
        }
        switch mode {
        case .normal: return try source.read(into: buffer, at: offset)
        case .short: return try source.read(into: UnsafeMutableRawBufferPointer(rebasing: buffer.prefix(1)), at: offset)
        case .eof: return 0
        case .io: throw KaitoError.io(EIO)
        case .foreignError: throw ReadFailure()
        }
    }
}
