import Foundation

struct ISOSection {
    let offset: UInt64
    let length: UInt64
}

// ECMA-119 §6.5: section の実 byte 長だけを順に返し、block padding を混ぜない。
final class ISOSectionDecompressor: Decompressor {
    private let source: any ByteSource
    private let sections: [ISOSection]
    private var index = 0
    private var current: CopyDecompressor?

    init(source: any ByteSource, sections: [ISOSection]) {
        self.source = source
        self.sections = sections.filter { $0.length > 0 }
    }

    var isFinished: Bool { index == sections.count }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !isFinished else { return 0 }
        if current == nil {
            let section = sections[index]
            current = try CopyDecompressor(source: source, offset: section.offset, compressedSize: section.length)
        }
        let count = try current!.read(into: buffer)
        if current!.isFinished { current = nil; index += 1 }
        return count
    }
}
