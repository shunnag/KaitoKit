# 変更履歴

すべての注目すべき変更をこのファイルに記録する。書式は
[Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に、
バージョニングは [Semantic Versioning](https://semver.org/lang/ja/) に従う。

## [0.1.0] - Unreleased

### 追加

- Swift 6 strict-concurrency 対応の SwiftPM パッケージと、静的・動的ライブラリ製品。
- 境界検査付き `ByteSource` / `ByteReader` / `BitReader`、checked 算術、CRC32、読み取り上限。
- 生の名前を保持する文字コード判定と、書庫・エントリの公開モデル。
- copy、raw deflate、bzip2 のストリーミング復号基盤。
- ustar、pax (`x` / Solaris `X`)、GNU long name/link を扱う tar reader。
- 中央ディレクトリ駆動、ZIP64、SFX prefix、遅延ローカルヘッダ検証に対応した ZIP reader。
- ZIP の stored、deflate、Deflate64、bzip2、raw LZMA1 圧縮方式と UNIX symlink。
- Traditional PKWARE (ZipCrypto) と WinZip AES-128/192/256 (AE-1/AE-2) の復号・認証。
- UTF-8 / Info-ZIP Unicode Path / 日本語文字コードの名前復元、ZIP timestamp、CRC32 検証。
- 検出、一覧、展開、SHA-256 差分 oracle、ベンチマークを提供する `kaito` CLI。
- 圧縮方式と暗号化状態を表示する `kaito list`。
- XADArchive の cooViewer 利用面と ZIP 遅延ローカルヘッダ既定値 API を覆う薄い
  `KaitoKitCompat` 層。
- archive member に結び付けた hard link、安全な dirfd ベースのパス展開、単体・CLI テスト。
- エントリ・PAX・パス・総メタデータの上限と、ASan/UBSan ミュータント実行スクリプト。
- ユニバーサル `KaitoKit.framework` を組み立てるスクリプトと移行ガイド。
- 設計書: 要件、安全規則、実装方式、API 層、検証方針、マイルストーン。
