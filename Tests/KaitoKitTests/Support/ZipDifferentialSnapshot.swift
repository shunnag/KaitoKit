import Foundation
@_spi(ZipRawLayout) @testable import KaitoKit

/// 一つの ZIP を開き、全 entry について公開の raw record・SPI の `zipRawRecordLayout`・stream の結果を集めたもの。
/// 読む順（逆順・SPI を先に引くか）や local header の先読みの方針を変えても等しくなることを比べる。
struct ZipDifferentialSnapshot: Equatable {
    var openError: String?
    var entries: [ArchiveEntry] = []
    var encoding: String.Encoding?
    var raw: [ZipTestOutcome<ZipRawSnapshot?>] = []
    var spi: [ZipTestOutcome<ZipRawRecordLayout?>] = []
    var stream: [ZipTestOutcome<Data>] = []
    init(_ bytes: Data, reverse: Bool, spiFirst: Bool) {
        let limits = ReadLimits(maxEntrySize: 1 << 20, maxInMemorySize: 1 << 20,
                                maxEntryCount: 4096, maxTotalMetadataSize: 4 << 20, maxDictionarySize: 1 << 20)
        let options = ReaderOptions(limits: limits, password: "raw-password", scanForSFXInData: true, appleDoublePolicy: .expose)
        self.init(source: DataByteSource(bytes), options: options,
                  policy: spiFirst ? .standard : .disabled, reverse: reverse, spiFirst: spiFirst)
    }
    init(source: any ByteSource, options: ReaderOptions, policy: ZipLocalReadAheadPolicy,
         diskLayout: ZipDiskLayout? = nil, reverse: Bool = false, spiFirst: Bool = false) {
        let limits = options.limits
        do {
            let reader = try AppleDoubleReader.wrap(ZipReader(source: source, options: options,
                                       diskLayout: diskLayout, readAhead: policy), options: options)
            entries = reader.entries
            encoding = reader.nameEncoding
            let indices = reverse ? Array(entries.indices.reversed()) : Array(entries.indices)
            for index in indices {
                if spiFirst { spi.append(ZipTestOutcome { try reader.zipRawRecordLayout(at: index, limits: limits) }) }
                raw.append(ZipTestOutcome { try reader.rawRecord(for: entries[index], limits: limits).map(ZipRawSnapshot.init) })
                if !spiFirst { spi.append(ZipTestOutcome { try reader.zipRawRecordLayout(at: index, limits: limits) }) }
                stream.append(ZipTestOutcome { try reader.stream(for: entries[index], limits: limits).readAll() })
            }
        } catch { openError = String(describing: error) }
    }
}
