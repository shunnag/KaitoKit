# 分割巻の公開 API `ArchiveVolumeSet`（2026-09-23）

環境: macOS 27.2 / Apple Silicon / Swift 6（`swift test`）。利用側の設計は KaitoFinder の
`Documentation/pending/2026-09-23-split-archive-deferred-save.md`（§3 検出 API、§6 KaitoKit）。

## 実装と範囲

- `ArchiveReader.volumeSet: ArchiveVolumeSet?`。URL から 2 巻以上を連結した `.001` 系（`SplitVolumeSet`）と
  native ZIP（`ZipSplitVolumeSet`）だけが non-nil。単一ファイル、兄弟のない `.001`、明示した巻が symlink、
  `open(data:)` / `open(source:)`、StuffIt 固有の分割、RAR の多巻、`.cue` の参照先は nil。
- 巻ごとの同一性（length、device、inode、mode、mtime）は、組み立てに使って保持している `FileByteSource` の fd を
  `fstat` した値（`FileByteSource.volume(at:)`）。URL の再 open やディレクトリの再走査はしない。
- `reopen()` はすべての分岐で既存の source を共有し、同じスナップショットを引き継ぐ。
- 巻名の生成は reader と同じ規則（`SplitVolumeSet.volumeName` / `ZipSplitVolumeSet.volumeName`）。
  ZIP は `fileName(forVolumeAt:count:)` の `index == count - 1` が最終巻名。`parse(fileName:)` は I/O をせず、
  `.zip` / `.zipx` の位置は不明として index −1 を返す。
- 検出・読み取りの挙動、既定の巻数上限 128 は変更しない。

## 自動検証

`swift build` と `swift test`（全体）を実行した。

- KaitoKitTests: 1412 件実行、skip 45、失敗 0。
- KaitoKitCompatTests: 34 件実行、失敗 0。
- 追加した `ArchiveVolumeSetTests` 9 件: 命名（桁あふれ .999 → .1000、ZIP の巻数変更）、`lstat` と一致する同一性、
  nil になる各条件、ZIP の `.zip` / `.z01` / 途中の巻からの open、差し替えの競合、reopen の引き継ぎ。
