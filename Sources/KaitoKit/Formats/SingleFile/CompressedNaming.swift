// 圧縮された単一 file の接尾辞の表。fallback 名から除く接尾辞と、展開結果を渡す container の判定が同じ表を読む。
enum CompressedNaming {
    struct Row: Sendable {
        let suffix: String
        let formats: Set<ArchiveFormat>
        let impliesTar: Bool
        let isContainerAlias: Bool
    }

    enum Container: Equatable {
        case tar
        case cpio
        /// 展開結果が cpio ならその entry を公開し、それ以外は単一 stream。
        case pbzxAuto
    }

    // container は tar、cpio、tar 別名、cpgz の順で判定する。
    // strip は形式ごとに具体的な suffix を先に採る。
    private static let rows: [Row] = [
        .init(suffix: ".tar.gz", formats: [.gzip], impliesTar: true, isContainerAlias: true),
        .init(suffix: ".tar.bz2", formats: [.bzip2], impliesTar: true, isContainerAlias: true),
        .init(suffix: ".tar.xz", formats: [.xz], impliesTar: true, isContainerAlias: true),
        .init(suffix: ".tar.zst", formats: [.zstd], impliesTar: true, isContainerAlias: true),
        .init(suffix: ".tar.lz4", formats: [.lz4], impliesTar: true, isContainerAlias: true),
        .init(suffix: ".tar.lzma", formats: [.lzma], impliesTar: true, isContainerAlias: true),
        .init(suffix: ".tar.lz", formats: [.lzip], impliesTar: true, isContainerAlias: true),
        .init(suffix: ".tar.br", formats: [.brotli], impliesTar: true, isContainerAlias: true),
        .init(suffix: ".tar.z", formats: [.compress], impliesTar: true, isContainerAlias: true),

        .init(suffix: ".cpio.gz", formats: [.gzip], impliesTar: false, isContainerAlias: true),
        .init(suffix: ".cpio.bz2", formats: [.bzip2], impliesTar: false, isContainerAlias: true),
        .init(suffix: ".cpio.xz", formats: [.xz], impliesTar: false, isContainerAlias: true),
        .init(suffix: ".cpio.zst", formats: [.zstd], impliesTar: false, isContainerAlias: true),
        .init(suffix: ".cpio.lz4", formats: [.lz4], impliesTar: false, isContainerAlias: true),
        .init(suffix: ".cpio.lzma", formats: [.lzma], impliesTar: false, isContainerAlias: true),
        .init(suffix: ".cpio.lz", formats: [.lzip], impliesTar: false, isContainerAlias: true),
        .init(suffix: ".cpio.br", formats: [.brotli], impliesTar: false, isContainerAlias: true),
        .init(suffix: ".cpio.z", formats: [.compress], impliesTar: false, isContainerAlias: true),

        .init(suffix: ".tgz", formats: [.gzip], impliesTar: true, isContainerAlias: true),
        .init(suffix: ".tbz2", formats: [.bzip2], impliesTar: true, isContainerAlias: true),
        .init(suffix: ".tbz", formats: [.bzip2], impliesTar: true, isContainerAlias: true),
        .init(suffix: ".txz", formats: [.xz], impliesTar: true, isContainerAlias: true),
        .init(suffix: ".tzst", formats: [.zstd], impliesTar: true, isContainerAlias: true),
        // .tlz は署名で LZMA_Alone と lzip を区別する。
        .init(suffix: ".tlz", formats: [.lzma, .lzip], impliesTar: true, isContainerAlias: true),
        .init(suffix: ".tbr", formats: [.brotli], impliesTar: true, isContainerAlias: true),
        .init(suffix: ".tz", formats: [.compress], impliesTar: true, isContainerAlias: true),
        .init(suffix: ".taz", formats: [.compress], impliesTar: true, isContainerAlias: true),
        .init(suffix: ".cpgz", formats: [.gzip], impliesTar: false, isContainerAlias: true),

        .init(suffix: ".gz", formats: [.gzip], impliesTar: false, isContainerAlias: false),
        .init(suffix: ".bz2", formats: [.bzip2], impliesTar: false, isContainerAlias: false),
        .init(suffix: ".bz", formats: [.bzip2], impliesTar: false, isContainerAlias: false),
        .init(suffix: ".xz", formats: [.xz], impliesTar: false, isContainerAlias: false),
        .init(suffix: ".zst", formats: [.zstd], impliesTar: false, isContainerAlias: false),
        .init(suffix: ".lz4", formats: [.lz4], impliesTar: false, isContainerAlias: false),
        .init(suffix: ".lzma", formats: [.lzma], impliesTar: false, isContainerAlias: false),
        .init(suffix: ".lz", formats: [.lzip], impliesTar: false, isContainerAlias: false),
        .init(suffix: ".br", formats: [.brotli], impliesTar: false, isContainerAlias: false),
        .init(suffix: ".z", formats: [.compress], impliesTar: false, isContainerAlias: false),
        .init(suffix: ".pbzx", formats: [.pbzx], impliesTar: false, isContainerAlias: false),
    ]

    static func stripRows(for format: ArchiveFormat) -> [Row] {
        // cpio の別名は全体を除かず、通常の codec suffix だけを除く。
        rows.filter { $0.formats.contains(format) && ($0.impliesTar || !$0.isContainerAlias) }
    }

    static func compressedContainer(name: String?, detected: ArchiveFormat) -> Container? {
        if detected == .pbzx { return .pbzxAuto }
        guard let name = name?.lowercased(),
              let row = rows.first(where: { $0.isContainerAlias && name.hasSuffix($0.suffix) }),
              row.formats.contains(detected) else {
            return nil
        }
        return row.impliesTar ? .tar : .cpio
    }
}
