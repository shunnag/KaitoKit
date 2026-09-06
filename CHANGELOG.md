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
- ZIP / tar の書庫単位文字コード判定と `ArchiveReader.nameEncoding`。
- 既知長の大きな stored entry を最終 `Data` へ直接読み込む高速経路。
- raw LZMA2 の chunk / reset state を逐次復号し、辞書サイズと chunk サイズを検証する
  `LZMA2Decoder`、および後方 seek 用の dictionary-reset index。
- plain / encoded header、UTF-16LE 名、日時・属性、empty / anti item、packed / folder /
  substream CRC を扱う 7z reader。
- 7z の Copy、LZMA1、LZMA2、PPMd7、Deflate、BZip2 と、Delta、x86 / ARM / ARMT /
  ARM64 / PPC BCJ、4-stream BCJ2 filter。PPMd7 は単一の上限付き arena と検証済み offset
  で context / suballocator を保持する。IA64 / SPARC filter は明示的に非対応。
- solid / block-split folder の継続読み取り、`solidGroup`、pure LZMA2 folder の
  dictionary reset からの後方再開。
- 7zAES の AES-256-CBC / SHA-256 KDF、header encryption、派生鍵 cache、KDF 計算量上限。
  独立した認証 tag がないため、最初の CRC 不一致または coder 構造不正を誤 password と判定。
- M3 の RAR4 reader。main / file / end header と header CRC、64-bit size、RAR Unicode 名、
  legacy 名判定、`EXT_TIME`、stored、展開後 CRC32 を実装。独立した unpack version 29 の
  RAR 2.9/3.x LZ は部分対応で、実 sample 19 file 中 3 file が一致。PPMd / filter descriptor と
  standard filter の decoder 接続 / custom VM / solid 辞書継続、unpack version 29 以外
  (15 / 20 / 26 を含む)、
  multi-volume continuation、encrypted header は明示的に非対応。
- M3 の RAR5 reader。CRC 付き header / vint / extra record、サイズ不明 entry の streaming、
  stored と圧縮アルゴリズム version 0 の独立 LZ、`solidGroup` の列挙、URL-backed RAR5
  multi-volume の検証・列挙・分割 stream 結合を実装。非最終 part に存在する packed CRC32 / BLAKE2sp、
  race-free な sibling open、既定 128 volume 上限、path を再解決しない `reopen()` を含む。
  Delta filter は TIFF 実コーパスで検証し、E8 / E8E9 / ARM は復号コードを実装して実コーパス検証待ち。
- RAR5 per-file AES-256-CBC / PBKDF2-HMAC-SHA256、password check、暗号化 CRC と
  BLAKE2sp HashMAC。rar 7.23 の stored / method 5 と誤 password を end-to-end 検証。
  RAR4 per-file AES-128-CBC は primitive test 済みだが、実暗号化 RAR4 oracle は未検証。
- RAR5 の圧縮アルゴリズム version 1、圧縮 solid continuation、header encryption、
  Data / 任意 `ByteSource` からの volume 継続、暗号化 entry の volume 継続、サイズ不明の
  暗号化 stored entry は明示的に非対応。codec 辞書の既定上限は 1 GiB。
- RAR5 実書庫 5 本、431 file stream、915,433,332 bytes を black-box `rar` と SHA-256
  差分確認。RAR4 実書庫は 19 file 中 3 file が一致し、残りは明示的な非対応 / malformed。
  RAR4 / RAR5 の決定的 mutant を合計 544 件実行。
- test 時に 7zz で生成する各 7z method / AES / solid fixture、10 MiB streaming、cooViewer
  fixture の SHA-256 差分テスト (`/opt/homebrew/bin/7zz` がない環境では明示的に skip)。
- 検出、一覧、展開、SHA-256 差分 oracle、ベンチマークを提供する `kaito` CLI。
- memory-mapped `Data` 経路を計測する `kaito bench --data`。
- 最大 20 エントリの再現可能なランダムアクセスを計測する `kaito bench --random`。
- 圧縮方式と暗号化状態を表示する `kaito list`。
- XADArchive の cooViewer 利用面と ZIP 遅延ローカルヘッダ既定値 API を覆う薄い
  `KaitoKitCompat` 層。
- archive member に結び付けた hard link、安全な dirfd ベースのパス展開、単体・CLI テスト。
- エントリ・PAX・パス・総メタデータの上限と、ASan/UBSan ミュータント実行スクリプト。
- ユニバーサル `KaitoKit.framework` を組み立てるスクリプトと移行ガイド。
- 設計書: 要件、安全規則、実装方式、API 層、検証方針、マイルストーン。
