import Foundation

// 出自・形式の根拠:
// - 7-Zip の -v スイッチ文書は公開ユーザーマニュアルとして参照（ソース不参照）。
// - バイト連結の一致、巻名の .999 → .1000、欠番停止、stale な末尾巻の許容は
//   7zz 26.03 のブラックボックス観察に基づく。
// - LZMA SDK の公開仕様 7zFormat.txt は 32 byte の start header の根拠。
// - 連結と兄弟ファイルの検証には KaitoKit 自身の既存 RAR 用処理を共有する。
// XADMaster / 7-Zip のソースコードは参照・移植していない。

/// 形式検出の前に、連番でバイト分割されたファイルを連結する。
enum SplitVolumeSet {
    struct Naming: Equatable, Sendable {
        let stem: String
        let width: Int
    }

    struct Assembled: Sendable {
        let source: any ByteSource
        let volumeCount: Int
    }

    /// 空でない stem と、3 桁以上の ASCII 数字で値 1 の拡張子だけを受理する。
    static func naming(forFirstVolumeName name: String) -> Naming? {
        guard let separator = name.lastIndex(of: "."), separator != name.startIndex else {
            return nil
        }
        let digits = name[name.index(after: separator)...].utf8
        guard digits.count >= 3,
              digits.last == UInt8(ascii: "1"),
              digits.dropLast().allSatisfy({ $0 == UInt8(ascii: "0") }) else {
            return nil
        }
        return Naming(stem: String(name[..<separator]), width: digits.count)
    }

    /// number は 0 始まり。元の桁幅を保ち、超過した桁はそのまま使う。
    static func volumeName(_ naming: Naming, number: UInt64) -> String {
        // assemble の巻番号は Int の巻数上限以下で、UInt64.max には達しない。
        let digits = String(number + 1)
        return naming.stem + "."
            + String(repeating: "0", count: max(0, naming.width - digits.count))
            + digits
    }

    /// 規則外・空の先頭巻・anchor なし・identity 不一致・兄弟なしは単独扱い。
    /// 探索できる先頭巻では上限 0 以下を拒否し、1 以上は実在する巻数を制限する。
    static func assemble(
        firstVolumeURL: URL,
        firstVolumeSource: FileByteSource,
        directory: FileByteSource.DirectoryAnchor?,
        limits: ReadLimits
    ) throws -> Assembled? {
        guard let naming = naming(forFirstVolumeName: firstVolumeURL.lastPathComponent),
              firstVolumeSource.length > 0,
              let directory else { return nil }

        do {
            try directory.verifyFirstVolumeIdentity(
                of: firstVolumeSource,
                named: firstVolumeURL.lastPathComponent,
                label: "split"
            )
        } catch {
            // 明示的に開いた symlink は単独ファイルとして保持し、兄弟を一切開かない。
            return nil
        }

        guard limits.maxVolumeCount > 0 else {
            throw KaitoError.limitExceeded("split volume count")
        }
        var segments = [SourceSegment(
            source: firstVolumeSource,
            offset: 0,
            length: firstVolumeSource.length
        )]
        while let source = try directory.openRegularFile(
            named: volumeName(naming, number: UInt64(segments.count)),
            label: "split"
        ) {
            // 上限の次の巻が存在するときだけ拒否する。この source の fd は解放される。
            guard segments.count < limits.maxVolumeCount else {
                throw KaitoError.limitExceeded("split volume count")
            }
            segments.append(SourceSegment(source: source, offset: 0, length: source.length))
        }
        guard segments.count > 1 else { return nil }
        return Assembled(
            source: try ConcatenatedByteSource(
                segments: segments,
                maximumLength: .max,
                maximumSegmentCount: limits.maxVolumeCount,
                label: "split volume set"
            ),
            volumeCount: segments.count
        )
    }
}
