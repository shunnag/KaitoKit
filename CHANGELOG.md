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
- M4 の LHA / LZH reader。header level 0 / 1 / 2 / 3、level 0 / 1 の byte sum、level 2 / 3 の
  optional 0x00 header CRC16、拡張 header 0x00 / 0x01 / 0x02 / 0x3f / 0x40〜0x42 / 0x46 /
  0x50〜0x54、32 / 64-bit size、DOS / Unix / Windows 日時、directory を扱う。認証済み
  member header を最大 1 MiB まで探す bounded SFX prefix にも対応する。
- LHA の `-lh0-` / `-lz4-` / `-pm0-` stored、`-lh1-` adaptive Huffman、
  `-lh4-`〜`-lh7-` static Huffman、1 MiB 辞書の `-lhx-`、OS marker 付き `-lh7-` の
  LHArk dialect、`-lz5-` / `-lzs-` LArc を実装し、member ごとの CRC16 を検証する。
  `-pm1-` / `-pm2-` / `-lh2-` / `-lh3-` は明示的に非対応。
- LHA legacy 名を書庫単位で判定し、0x46 codepage の 932 / 65001 / 936 は宣言済み
  encoding として扱う。末尾 separator の directory 判定、先頭 slash / drive prefix の相対化、
  filename field の NUL 終端、空名 member、OS/2 extended-attribute subdirectory を通常の
  安全な entry traversal と両立させる。各 member は独立しており `solidGroup == -1`。
- OS-9 LHA 2.01 が raw creator ID に 0x4B (既存 mapping では OS/68K marker) を記録し、2 bytes
  少なく宣言する level-2 header と、無効な DOS timestamp (`nil`) を、境界が一意に検証できる場合に
  受理する。zero terminator がなく、最終の境界検証済み payload の直後で exact EOF に達する archive は、
  最終 member が LArc の場合、または書庫内に構造検証済みの匿名通常 member を少なくとも 1 件含む場合だけ
  受理する。
- MacLHA の Macintosh OS marker を持つ member は、MacBinary / MacBinary II standard proposals に
  基づく有効な envelope の data fork だけを公開しながら、padding、resource fork、compatible trailing
  extension を含む全出力の LHA CRC16 を検証する。MacBinary ではない Macintosh member は変更せずに返す。
- hand-built level 0 / 1 / 2、codepage、metadata、static / legacy decoder vector、
  cooViewer `book.lzh` と lhasa の SHA-256 差分を追加。Swift 6.4 AddressSanitizer では
  parser / container 384 件と実 archive seed の method 320 件、計 704 deterministic mutant を実行し、
  test / sanitizer failure は 0 件だった。
- 供給された corpus directory の 227 archive は、当時の集計で 203 件が lhasa と byte-identical、8 件が
  Unix symlink semantics の差(後述のレビュー修正で `.symlink` として展開)、9 件が KaitoKit 側の想定内 failure (PM1 系 4 件: 非対応 3 / truncated 1、PM2 非対応
  3 件、4.5 GiB member に対する既定 4 GiB 上限 1 件、parent traversal 拒否 1 件)、7 件が
  lhasa / oracle 側の failure (LH2 / LH3 2、malformed PM2 1、truncated 1、unusual link / EA 3) だった。
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
- M3 の RAR4 reader。main / file / end header、header CRC、64-bit size、RAR Unicode / legacy 名、
  `EXT_TIME`、stored、unpack version 29 の LZ / PPMd-H と block transition、展開後 CRC32 を実装。
  RAR3 standard VM の E8 / E8E9 / Itanium / Delta / RGB / Audio は native 実装し、custom VM は
  明示的に拒否する。圧縮 version 15 / 20 / 26 を含む version 29 以外も明示的に非対応。
- RAR4 solid は window / Huffman / 距離 / filter program / PPMd model を entry 間で継続し、
  順方向 skip、後方再開、暗号化 solid を扱う。RAR3 per-file AES-128-CBC と `-hp` header
  encryption、old (`.rar` / `.r00`) / new (`.partN.rar`) multi-volume、上限付き SFX prefix、
  非最終 split part の packed CRC32 を実装。SFX prefix と multi-volume の組合せは明示的に非対応。
- M3 の RAR5 reader。CRC 付き main / file / service / encryption / end header、vint / extra record、
  サイズ不明 entry、stored と圧縮アルゴリズム version 0 の LZ (method 1〜5)、Delta / E8 /
  E8E9 / ARM filter を実装。solid は stored member の混在、member ごとの dictionary minimum
  変更、順方向 skip / 後方再開を扱う。
- RAR5 per-file AES-256-CBC と archive `-hp` header encryption、PBKDF2-HMAC-SHA256、password
  check、暗号化 CRC / BLAKE2sp HashMAC、暗号化 multi-volume を end-to-end 実装。非最終 part の
  packed CRC32 / BLAKE2sp、保持した directory descriptor からの sibling open、既定 128 volume
  上限、path を再解決しない `reopen()` を含む。archive-header KDF は個別の `count` を最大 24 に
  制限し、全 header-encrypted volume の異なる `(password, salt, count)` context を public API の
  `ReadLimits.maxRAR5HeaderKDFWork` へ HMAC-SHA256 iteration 単位で `2^count + 32` ずつ累積する。
  同一 context の key-cache hit は再加算せず、既定値は最大コストの `count = 24` context 4 件分
  (`4 * (2^24 + 32)`)。
- RAR5 の file-copy redirection の展開、RAR5 SFX、Data / 任意 `ByteSource` からの volume 継続、
  サイズ不明の暗号化 stored entry は明示的に非対応。圧縮アルゴリズム version 1 と version 2 以上、
  method 6 以上、file-encryption record version 1 以上、KDF count 上限超過は、対象 entry の
  stream 作成時に拒否し、他の entry の一覧・読み取りを妨げない。codec 辞書の既定上限は 1 GiB。
- RAR5 実書庫 5 本、431 file stream、915,433,332 bytes を RAR 7.23 と SHA-256 差分確認。
  RAR4 は `st1200-pts.rar` の 19/19 file と 241,647,978-byte PPMd↔LZ entry が一致した。
  追加 corpus 20 書庫では 47 regular file と 5 symlink target が一致し、既知 password で
  oracle を得られない暗号化 entry は 1 件、破損 `seek_data_cursor0` は双方が拒否した。
  RAR4 / RAR5 の unit-level deterministic mutant を合計 544 件実行。さらに 8 種の RAR seed から
  400 件を `Scripts/fuzz/run-mutants.sh` の ASan build で実行し、crash / hang / sanitizer finding は 0 件。
- test 時に 7zz で生成する各 7z method / AES / solid fixture、10 MiB streaming、cooViewer
  fixture の SHA-256 差分テスト (`/opt/homebrew/bin/7zz` がない環境では明示的に skip)。
- 検出、一覧、展開、SHA-256 差分 oracle、ベンチマークを提供する `kaito` CLI。
  `sha` は entry 全体の `Data` を保持せず、再利用する有界 buffer で逐次 hash する。
  controlled before/after median は book RAR5 155.346→155.431 ms、TIFF RAR5
  637.541→610.447 ms、最終 warm wall time は 0.15 / 0.61 s。以前の約 0.62 秒差は
  `swift run` の cold-start / planning 混入だった。
- memory-mapped `Data` 経路を計測する `kaito bench --data`。
- 最大 20 エントリの再現可能なランダムアクセスを計測する `kaito bench --random`。
- 圧縮方式と暗号化状態を表示する `kaito list`。
- XADArchive の cooViewer 利用面と ZIP 遅延ローカルヘッダ既定値 API を覆う薄い
  `KaitoKitCompat` 層。
- archive member に結び付けた hard link、安全な dirfd ベースのパス展開、単体・CLI テスト。
- エントリ・PAX・パス・総メタデータの上限と、ASan/UBSan ミュータント実行スクリプト。
- ユニバーサル `KaitoKit.framework` を組み立てるスクリプトと移行ガイド。
- 設計書: 要件、安全規則、実装方式、API 層、検証方針、マイルストーン。
- RAR / LHA の敵対レビュー(39 エージェント)確定 9 件の修正。RAR29 LZ は symbol ループの
  各 iteration で入力枯渇を検査し(履歴の無い symbol 258 の no-op 経路)、RAR5 filter は caller
  buffer 長に依存せず途中再開する。RAR5 の hard link (redirection type 4) / file reference (type 5)
  は body なしの 0-byte entry として一覧・読み取りでき、solid chain と総展開サイズに参加しない
  (type 4 は展開時に hard link、type 5 の copy 展開は非対応)。`ArchiveReader.extract` の
  hard link 出所 key は最寄りの既存 ancestor を解決する(未作成の `/private/tmp` と `/tmp` 表記)。
  RAR4 / RAR5 の Unix symlink は `linkTargetStoredAsData` を公開して stored target から展開し、
  LHA の `-lhd-` + `S_IFLNK` は `name|target` を `.symlink` / `linkPath` に分離する。
  `ReadLimits.maxMetadataRecordCount` は書庫累計ではなく record set 単位(LHA member の
  extension chain、RAR5 header の extra area)の上限になった。RAR4 `-p` の compressed entry は
  decoder の malformed / truncated を `.wrongPassword` に正規化し、`-hp` は物理的に短い
  envelope と後続切断を `.truncated` として区別する。`ReaderOptions.maxRAR5KDFCountPower` /
  `maxSevenZipAESCyclesPower` は代入時にも 24 / 62 へ clamp する。
- Scripts/fuzz: RAR4 LZ / PPMd-H、RAR5 LZ、LHA lh4 / lh6 / lh7 の packed-range locator と
  compressed seed 生成、`--require-payload-ranges`。RAR5 LZ seed は同梱の project-generated
  fixture(`Tests/Fixtures/rar5/lz-small.rar.b64`)から復元し、`rar` は明示指定時だけ使う。corpus 依存テストは
  `KAITOKIT_RAR4_CORPUS` / `KAITOKIT_LHA_CORPUS` などの環境変数で指定し、libarchive
  (BSD-2-Clause)/ ISC 由来の小さな fixture を `Tests/Fixtures` に base64 で固定する
  (`Tests/Fixtures/NOTICE`)。
