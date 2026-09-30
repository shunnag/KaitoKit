import Foundation

/// 形式検出に渡す書庫の入力。byte source・名前ヒント・実際に開いた巻の identity を別々に持つ。
/// URL 入口だけが兄弟巻と参照先を組み立て、名前ヒントのない Data / ByteSource 入口は与えた byte のみを使う。
struct OpenedArchiveInput {
    /// 組み立て後の source。分割セットは連結、`.cue` は data track の image、それ以外は開いた file 自身。
    let source: any ByteSource
    /// 拡張子・単一 stream の名前・SFX 検出のヒント。`.001` セットでは `.001` を除く。
    let sourceURL: URL?
    /// 開いた file の親 directory。`.001` の連結セットでは nil。
    let directoryAnchor: FileByteSource.DirectoryAnchor?
    /// 実際に開いた巻の URL。`.001` の連結セットでは nil。
    let volumeURL: URL?
    /// `.z01` / `.zx01` ZIP 分割セットの巻の配置。
    let zipDiskLayout: ZipDiskLayout?
    /// 2 巻以上連結した numbered / native ZIP セット。
    let volumeSet: ArchiveVolumeSet?

    init(source: any ByteSource, sourceURL: URL? = nil,
         directoryAnchor: FileByteSource.DirectoryAnchor? = nil, volumeURL: URL? = nil,
         zipDiskLayout: ZipDiskLayout? = nil, volumeSet: ArchiveVolumeSet? = nil) {
        self.source = source
        self.sourceURL = sourceURL
        self.directoryAnchor = directoryAnchor
        self.volumeURL = volumeURL
        self.zipDiskLayout = zipDiskLayout
        self.volumeSet = volumeSet
    }

    /// `.001` から始まるバイト分割巻は、形式検出の前に同じ親の兄弟巻を連結する。
    static func assemble(url: URL, limits: ReadLimits) throws -> OpenedArchiveInput {
        let standardized = url.standardizedFileURL
        let opened = try FileByteSource.openAnchored(url: standardized)
        let split = try SplitVolumeSet.assemble(
            firstVolumeURL: standardized,
            firstVolumeSource: opened.source,
            directory: opened.directory,
            limits: limits
        )
        let zipSplit = try split == nil ? ZipSplitVolumeSet.assemble(
            url: standardized, source: opened.source, directory: opened.directory, limits: limits
        ) : nil
        // classic StuffIt の分割セット（100 byte header の part）は兄弟を集めて data / resource fork に組む。
        let stuffItSplit = try split == nil && zipSplit == nil ? StuffItSplitSet.assemble(
            firstVolumeURL: standardized, source: opened.source, directory: opened.directory, limits: limits
        ) : nil
        // `.cue` は data track の image file（同じ directory）を開く。
        let cue = try split == nil && zipSplit == nil && stuffItSplit == nil ? CueSheet.assemble(
            url: standardized, source: opened.source, directory: opened.directory, limits: limits
        ) : nil
        // 兄弟のない .001 でも .tar.gz などのヒントを保持する。
        let sourceURL = SplitVolumeSet.naming(forFirstVolumeName: standardized.lastPathComponent) != nil
            ? standardized.deletingPathExtension()
            : standardized
        return OpenedArchiveInput(
            source: split?.source ?? zipSplit?.source ?? stuffItSplit.map { $0 as any ByteSource } ?? cue ?? opened.source,
            sourceURL: sourceURL,
            directoryAnchor: split == nil ? opened.directory : nil,
            volumeURL: split == nil ? standardized : nil,
            zipDiskLayout: zipSplit?.layout,
            volumeSet: split?.volumeSet ?? zipSplit?.volumeSet
        )
    }
}
