# KaitoKit(解凍Kit)

macOS 向けの書庫読み取りフレームワークです。ZIP / RAR / 7z / LHA / tar 系の書庫を、
純 Swift の実装と macOS 同梱のライブラリ(zlib・libbz2・Compression・CommonCrypto)だけで
開き、[XADMaster](https://github.com/MacPaw/XADMaster) を使っているアプリが低い移行コストで
移れる API を提供します。

- 対象: macOS 26 以上、Apple Silicon / Intel(ユニバーサル)
- 依存: なし(SwiftPM パッケージ。システムライブラリのみ)
- ライセンス: MIT。XADMaster のコードは参照も流用もしていません(設計書 §10)

現在は設計と骨格の段階です。設計の経緯・比較・方針は
[Documentation/design.md](Documentation/design.md) を参照してください。

## 開発体制

XADMaster 本家への貢献は今後も続けます。KaitoKit は XADMaster の代替ではなく、
Swift のメモリ安全性と macOS の同梱ライブラリを前提に設計し直した別の実装で、
XADMaster 利用者が移行できる API 形状を目標にしています。
