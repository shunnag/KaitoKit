# 変更履歴

すべての注目すべき変更をこのファイルに記録する。書式は
[Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に、
バージョニングは [Semantic Versioning](https://semver.org/lang/ja/) に従う。

## [0.1.0] - Unreleased

### 追加・修正（2026-09-09、XADMaster との black-box 差分調査から）

- 7z の coder 連鎖に対応。byte を消費する coder（LZMA / LZMA2 / PPMd7 / Deflate /
  BZip2 / AES）の入力が他 coder の出力である folder を、宣言サイズちょうどで
  上限内に実体化してから復号する。`-m0=BCJ2 -m1=LZMA2 -m2=LZMA -m3=LZMA` が作る
  `LZMA -> LZMA -> LZMA2 -> BCJ2.main` の folder が展開できるようになった。
  入力がもともと byte 範囲の経路は割り当てなしのまま。

- LZMA_Alone（`.lzma`）を単一 entry 形式として追加。13 byte header を検証して
  既存の LZMA 復号器へ繋ぐ。magic を持たない形式なので判定は最後に行い、
  拡張子・properties・辞書サイズ・range coder 先頭 byte がすべて揃うことを要求する。
  互換層の `formatName()` は XADMaster と同じ `LZMA_Alone` を返す。

- `.tar.Z` / `.tZ` を `.tar.gz` / `.tar.bz2` / `.tar.xz` と同じ compressed-tar 経路に
  載せた。4 形式すべてが同じ entry 列と同じ内容を返す。

- 7z の SPARC / IA-64 branch filter に対応。変換規則は 7-Zip を
  `-m0=<FILTER> -m1=Copy -mhc=off` で filter 出力オラクルとして使い、
  実行ファイルの入出力だけから導出した（記録は
  `Documentation/verification/2026-09-09-branch-filter-derivation.md`）。
  6 回 × 8,192 byte の敵対的ベクタでオラクルと完全一致する。
  RISC-V filter は XADMaster も全 entry を空で返すため対象外とし、
  引き続き明示的に unsupported とする。

- 破損書庫の救済モード `ReaderOptions.recoverDamagedArchives`(既定 false)を追加。
  中央ディレクトリを失った ZIP は local file header を走査して救済し、tar と LHA は
  切断点まで entry を保持する。切れた entry は `ArchiveEntry.isIncomplete` で示し、
  読めた byte だけを返す(いずれも原本の正しい prefix であることを実測で確認)。
  EOCD を潰した ZIP は XADMaster と同じ総合 SHA-256 に到達し、ZIP と LHA の
  切れた entry では XADMaster が 0 byte を返すのに対し KaitoKit は救済できる。
  不完全な entry では CRC-32 / WinZip AES HMAC / MacBinary CRC-16 の検証を飛ばすため、
  救済した byte は認証されていない旨を公開 doc に明記した。password verifier は
  救済時も働き、誤ったパスワードは `wrongPassword` のままになる。
  健全な書庫 95 件と暗号化書庫 6 件は、この設定の有無で結果が完全に一致する。

- tar の形式判定が member header の数値フィールドまで解析していたため、size が壊れた
  tar が `malformed` ではなく「未対応形式」に化けていたのを修正。判定は 512 byte・
  非空のパス名・checksum 一致だけを見る。あわせて、先頭が 0 で埋まったファイルを
  「空の tar」として受理していた挙動を止めた(ISO 9660 が tar と誤判定され、
  0 件で成功していた直接の原因)。


- CRC-16/ARC を実行時判定付き PMULL / PCLMULQDQ folding で高速化。小入力・未対応 CPU は
  従来の slice-by-eight を維持し、公開 API・逐次更新・検証結果を変えずに LHA 展開時間を短縮。

- RAR29 / LHA static Huffman の展開を高速化。CRC16 slice-by-eight、境界検証付きの
  重複 match コピー、生バッファの Huffman lookup / bit reservoir により性能目標を達成。

### 修正・高速化（2026-09-08）

- RAR5 の復号失敗を軽量な内部状態で保持し、ヘッダ走査では上限付き先読みバッファを
  再利用して展開・open を高速化。公開 API・エラー・展開内容は維持。

- RAR5 の長い password は実測済みの先頭 127 Unicode scalars を優先し、全 UTF-8 への
  fallback で既存 writer 互換を保持。symbolic-link target の末尾が NAME_MAX を超える場合も
  安全な dangling link として展開できるよう修正。

- RAR4 solid 群内の stored member を共有状態に影響させず読み取り、RAR5 symbolic link の
  read / stream が header target の UTF-8 bytes を返すよう修正。

- RAR5 の重複 match コピー・局所状態・Huffman lookup と PPMd の固定確率表 / mask を高速化し、
  TIFF RAR5 と solid PPMd の展開を XADMaster の 1.5 倍以内に改善。

- symlink target の最後の `..` まで既存の実 directory を要求し、後続 entry / 別 archive による
  未作成成分の symlink pivot を拒否。root 内の親相対 target と安全な前方参照は維持。
- EUC-JP 半角カナが主体の名前は既知語がなくても評価し、`ｶﾀｶﾅ半角.txt` の CP932 誤判定を修正。
- RAR4 非 BMP password の方式を archive 単位で記憶し、solid prefix の entry ごとの再展開を解消。
  header CRC の選択と KDF cache を再利用し、非最終候補では error 種別によらず次の候補を検証。
- CLI の失敗 entry と CRC 不一致の source member を stderr / ERROR TSV の両方で区別。
- RAR3 writer の 127 文字 cap を移行ガイドの password 項目へ統合。

- RAR3 Audio standard filter の fingerprint 長を実 program の 216 bytes に修正。
- RAR3 の長い password と BMP 外の Unicode password の互換性を修正。UTF-16 を優先し、
  CRC 検証で Unix scalar 表現へ fallback。候補の出力は検証前に呼出側へ公開しない。
- 結合文字の前後でも `/` を byte 境界で扱い、安全な名前の誤拒否と symlink 経由の展開先逸脱を修正。
- 展開 root 内に留まる親相対 symlink target を許容。途中の既存 symlink は追わない。
- LHA level 0〜3 の 0xFF / backslash separator、level-0 Unix metadata、CP932 の 0x8E lead byte
  と EUC-JP halfwidth kana の誤判定を修正。
- CLI `sha` / `extract` は失敗を entry ごとに報告して後続へ進み、部分成功では非ゼロ終了。
- PPMd の重複した state 全走査を廃し、検証済み arena span、range decoder の特殊化、
  状態検索と頻度集計の改善で RAR4 / 7z の展開を高速化。
- ZipCrypto のランダムな一バイト password hint に依存していたテストを最終 CRC 検証へ修正。

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
