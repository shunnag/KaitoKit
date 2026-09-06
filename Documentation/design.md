# KaitoKit 設計書(2026-09-06 初版)

## 1. 要件(ユーザー指示 + 現状調査から)

- 名称: KaitoKit.framework(解凍Kit)。github.com/shunnag/KaitoKit に新規リポジトリ。shunnag 配下に同名なし。無関係の小規模リポジトリが 2 件(Kaito1108/KaitoKit、KietUTE2812/KaitoKit)存在するが枠組みではない。
- XADMaster のコードは流用しない(クリーンルーム)。XADMaster 利用ソフトが**低い移行コスト**で移れる API 形状。
- macOS 26 以上。x86_64 + arm64(ユニバーサル)。Linux は考えない。
- 安全と性能のバランス。XADMaster フォークで得た経験(MODERNIZATION.md #1〜#66、ファジング、Scripts/bench)を活かす。
- 実装言語はオープン(Rust/Go/純 Swift)。多角的に検討して決める。

## 2. cooViewer が実際に使っている XADMaster の面(移行の最小面)

- 生成: `XADArchive(file:)`, `XADArchive(data:)`(mmap した Data を渡す)。クラス既定 `defaultZipLazyLocalHeaders` / `setDefaultZipLazyLocalHeaders(_:)`(cooViewer 設定「ZIP 書庫をより速く開く」)。
- 列挙: `numberOfEntries()`, `name(ofEntry:)`(文字コード自動判定込みの表示名), `entryIsDirectory(_:)`, `entryHasSize(_:)`, `uncompressedSize(ofEntry:)`(64bit), `entryIsEncrypted(_:)`, `isEncrypted()`.
- 展開: `contents(ofEntry:)` → Data(フォーク API `remainingFileContentsWithSizeHint` で事前確保)。
- 暗号: `setPassword(_:)`。
- 並列: `solidGroup(ofEntry:)`(フォーク追加 #59)で solid グループ判定 → perEntry / byGroup / serial の展開粒度。
- XADArchiveDelegate は未使用(文字コード・パスワード・進捗のコールバックは自前)。
- 使い方の特徴: actor で直列化、展開プール(独立に再オープンした複数 archive)、ネスト書庫(zip 内 zip/PDF/EPUB)を Data から開く、zip 爆弾対策で 64bit サイズを事前に見る、ローカル固定ボリュームのみ mmap。

一般の XADMaster 利用者が使う面(移行ガイドの対象): `XADArchive` の上記 + `extractEntry:to:`、`attributesOfEntry:`(日付・POSIX 権限・フラグ)、`entryIsLink/entryIsResourceFork`、`nameEncoding`、`XADArchiveDelegate`(`archiveNeedsPassword:`、`archive:nameEncodingForData:guess:confidence:`、進捗)、`XADSimpleUnarchiver`、下層 `XADArchiveParser`/`CSHandle`。

## 3. XADMaster フォークの経験から引き継ぐ設計ルール

安全(#1〜#48、ファジング):
- 攻撃者制御の長さ・カウント・シフト量・オフセットは**読んだ場所で**上限と符号を検証する(VLA なし、`Int` の符号付き演算に頼らない、`<<` の前に範囲確認、64bit で計算してから 32bit へ落とさない)。
- ハフマン/ラン長テーブルの充填は必ずテーブル長で打ち切る。
- ループの前進保証(RAR5 ブロック、XZ ブロック、CFBF FAT、ISO CE 連鎖)。
- 宣言サイズ由来の確保は上限つきにし、符号化(圧縮)ヘッダが宣言する復号サイズを信用しない(実バイトの裏付けがあるカウントだけを厳密に扱う)。
- 検出: ASan/UBSan+ミュータント(makemutants.py 方式)、実書庫 SHA-256 相互検証(libFuzzer は Apple toolchain の Swift で使えない)。

性能(#10〜#11、#51〜#66、Scripts/bench):
- CRC32 は system zlib `crc32()`(M4 Max ~47 GB/s)。自前テーブルや 3 ストリーム HW 実装は不要。
- AES は CommonCrypto/CryptoKit、派生鍵はプロセス内キャッシュ(7z 暗号化 645→21 ms)。
- 展開結果は宣言サイズで**事前確保した不変バッファ**へ直接(Swift 側の NSMutableData→Data 橋渡しコピーを消す)。
- I/O バッファは大きく(通常 256 KB、既知長 stored の直接読みは 4 MB)。ビットリーダは 64bit リザーバ(RAR5 が記号ごとにオフセット照会)。
- LZSS 窓コピーは非ラップ時 memcpy の高速経路。
- ZIP は中央ディレクトリを一括メモリで解析、ローカルヘッダは初回展開まで遅延(2000 件 open 11〜14 ms)。
- LZMA2 solid の後方シークはチャンク索引で再デコードを局所化。
- solid グループ id を公開し、利用側が並列粒度を決められるようにする(非 solid 7z 5.2 倍、ブロック solid 5.3 倍)。
- 計測の作法: 交互実行ペア、同一ハーネス、SHA 相互検証、マイクロベンチは実データ。

文字コード(#49、#64、bench sjis2000):
- 厳密に有効な UTF-8 なら判定器を通さず UTF-8(短い日本語名の誤判定回避)。
- CP932(Shift_JIS)・EUC-JP・UTF-8 の判定を本体で持つ(UniversalDetector 相当)。未宣言の legacy 名を書庫全体で集約し、構造検査と必要な場合だけ一度の Foundation `NSString.stringEncoding(for:encodingOptions:)` で共通 encoding を選ぶ。その encoding で変換できない名前だけ単名判定へ戻し、実コーパスで比較する。
- 表示名とは別に生バイト列を保持し、判定を後から差し替えられるようにする(XADString 相当)。

## 4. 性能の目標値(Scripts/bench results-2026-08-27、M4 Max、XADMaster final)

| ケース | XADMaster |
|---|---|
| open zip 2000 件(ASCII / SJIS) | 11.8 / 14.3 ms |
| extract book-deflate.cbz(200 件 1.2 GB) | 682 ms |
| extract book-stored.cbz | 26.5 ms |
| extract book-rar4 / rar5 (JPEG 200 件) | 34 / 36 ms |
| extract book-tiff-rar4 / rar5 | 351 / 352 ms |
| extract book-tiff.7z(LZMA2) | 423 ms |
| extract book-solid.7z | 7.3 s |
| extract book-enc.7z | 21 ms |

目標: 同一コーパスで XADMaster final の 1.3 倍以内(open と deflate/stored は同等)、SHA-256 一致。

## 5. 形式の優先順位(cooViewer と日本語コミック用途)

1. ZIP/CBZ(stored, deflate, bzip2, deflate64, LZMA, ZipCrypto, WinZip AES, ZIP64, CP932 名)
2. RAR/CBR(RAR 2.9/3.x, RAR 5.x, solid, 分割、暗号化)
3. 7z/CB7(LZMA, LZMA2, PPMd, BCJ/BCJ2, Delta, Deflate, BZip2, AES-256, solid/ブロック)
4. LHA/LZH(lh0, lh4〜lh7, lh1, lz4/lz5/lzs, ヘッダ level 0/1/2, SJIS 名, 0x46 コードページ)
5. tar 系(ustar/pax/GNU)+ gz/bz2/xz(xz は Compression framework)
6. 後段候補: CAB(MSZIP/LZX), zstd, StuffIt/SIT(要検討), ISO, ARJ, ACE

## 6. 実装方式の比較(調査 2026-09-06)

事実(実機で確認):
- Swift toolchain(Xcode 26.6 / Swift 6.3.3、Xcode-beta 6.4): `import zlib`(1.2.12、crc32 あり)と `import Compression` は Swift から直接使える。bzip2 は SDK に bzlib.h と libbz2.tbd があるが modulemap がないので systemLibrary ターゲットで包む。
- Apple Compression の COMPRESSION_LZMA は **xz コンテナのみ**復号(.lzma / raw LZMA2 は 0 バイト)。zstd・deflate64・raw LZMA なし。
- libarchive 3.7.4 は macOS 26 に同梱で SDK に .tbd はあるがヘッダなし(App Store 審査で private 扱いの報告)。rar/7z の暗号化復号は非対応(既知)。
- `swiftc -target x86_64-apple-macos26` でクロスビルドし Rosetta 実行可。`swift build --arch arm64 --arch x86_64` でユニバーサル化できる。
- `-sanitize=fuzzer` は Apple toolchain の Swift で非対応(libFuzzer なし)。ASan は使える → ミュータント駆動(makemutants.py 方式)+ ASan/UBSan、実書庫 SHA 相互検証で代替。
- Rust/Go toolchain は未導入(導入は要ユーザー確認)。

| 案 | 内容 | 長所 | 短所 |
|---|---|---|---|
| (a) 純 Swift + システムライブラリ | 構造解析・LZMA/LZMA2・PPMd・RAR3/RAR5・LZH・Deflate64 を Swift で実装。deflate=zlib、bzip2=libbz2、xz=Compression、AES/SHA/PBKDF2=CommonCrypto/CryptoKit | 単一ツールチェーン、SwiftPM でそのまま配布(Washi と同じ運用)、ユニバーサル化が容易、メモリ安全(境界検査・型)、ライセンスが単純(MIT、クリーンルーム)、XADMaster 利用者(Swift/ObjC)に自然 | 復号器を書く量が多い(LZMA、PPMd、RAR、LZH)、Swift のビット単位処理は C より遅くなり得る(unsafe を局所化して対処)、Swift の算術トラップは DoS になるので検証済み演算の規律が要る |
| (b) Rust コア + Swift API | zip/sevenz-rust2/delharc/lzma-rs/ruzstd 等 + cbindgen/UniFFI | メモリ安全と C 並みの速度、既存クレートで zip/7z/lha/tar/xz/zstd を即カバー | **RAR は完全実装が C++ unrar(UnRAR ライセンス、非 OSI)しかなく、純 Rust の unrar-rs は成熟度未検証**、Rust 導入と 2 言語保守、FFI 境界でのストリーム/シーク/進捗/キャンセル設計、xcframework 配布、Codex/開発者の Swift 中心の体制と合わない |
| (c) システム libarchive | dlopen/tbd リンク | 実装ゼロで多形式 | ヘッダ未提供・App Store 審査リスク、rar/7z の暗号化非対応、ランダムアクセスとエントリ生バイト名の扱いが弱い、Apple のビルド構成不明 |
| (d) 既存 C ライブラリ同梱 | LZMA SDK(公開ドメイン)、unrar(UnRAR ライセンス)、lhasa(ISC)、libdeflate(MIT) | 成熟・高速 | XADMaster と同じ C の危険性(今回の 48 件の教訓)、ライセンス混在、"新しい安全な設計" という目的に反する |

判断: **(a) 純 Swift + システムライブラリ**を採用し、コーデック層を差し替え可能な設計にする(将来、性能上どうしても必要なコーデックだけ Rust/C を差し込める)。RAR はクリーンルーム(RAR5 は RARLab technote、RAR3 は unrar/libarchive/7-Zip の**挙動**を仕様として扱い、コードは写さない。標準フィルタ(E8/E8E9/Delta/ARM/RGB/Audio)のみをネイティブ実装し VM は持たない= unrar 5 以降と同じ方針)。

## 7. API 設計方針

3 層:
1. `KaitoKit`(モダン API、Swift 6・Sendable): `ArchiveReader`(URL / Data / ByteSource から open、形式自動判定、書庫単位の `nameEncoding`)、`ArchiveEntry`(index、生バイト名+判定済み表示名、パス成分、サイズ(64bit)、圧縮サイズ、種別(file/dir/link/resource fork)、暗号化、日付、POSIX/DOS 属性、solidGroup、format 固有情報)、`read(entry) -> Data`(宣言サイズで事前確保)、`stream(entry)`(逐次読み)、`extract(entry, to:)`、`PasswordProvider`(同期/非同期)、`Progress`/キャンセル、`EncodingPolicy`(自動判定・固定・候補提示)。インスタンスは非スレッド安全(XADMaster と同じ契約)、`reopen()` で同じ ByteSource を共有した並列用の複製を安価に作る。
2. `KaitoKitCompat`(XADMaster 互換 API): 実体は `KaitoArchive` で、`public typealias XADArchive = KaitoArchive` を提供し `XADArchive` と同じ Swift シグネチャ(`init?(file:)`, `init?(data:)`, `numberOfEntries()`, `name(ofEntry:)`, `contents(ofEntry:)`, `uncompressedSize(ofEntry:)`, `entryIsDirectory(_:)`, `entryHasSize(_:)`, `entryIsEncrypted(_:)`, `isEncrypted()`, `setPassword(_:)`, `solidGroup(ofEntry:)`, `extractEntry(_:to:)`, `attributesOfEntry(_:)`, `XADArchiveDelegate` 相当のプロトコル)。`import XADMaster` → `import KaitoKitCompat` で主要用途はそのまま動くことを目標にする(ObjC 公開を加える場合は `@objc(KKArchive)` のように `KK` 接頭辞で XADMaster と衝突させない)。
3. 内部: `ByteSource`(file/mmap/Data、256 KB バッファ)、`BitReader`(64bit リザーバ、LE/BE)、`Checked` 演算、`Codec` プロトコル(ストリーム復号、window、フィルタ)、`FormatParser` レジストリ(シグネチャ判定)。

## 8. 検証・計測

- 差分テスト: 同一書庫を KaitoKit と XADMaster(cooViewer の Frameworks)/7zz/unrar/lhasa/bsdtar で展開し SHA-256 を比較(CLI `kaito` に diff モード)。
- フィクスチャ生成: 7zz・rar 7.23(RAR5)・lha(作成には LHa for UNIX が必要、lhasa は展開のみ)・bsdtar・zip(Info-ZIP)+ makesjiszip.py。RAR4 は rar 6.x が必要(要相談)。
- 安全: ASan/UBSan ビルド + ミュータント(makemutants.py)+ 決定的な破損ケース、巨大宣言サイズ・爆弾・循環参照の単体テスト。
- 性能: Scripts/bench の方法論(交互実行、同一ハーネス、SHA 相互検証)を kaito CLI に移植し、XADMaster final と比較。目標 1.3 倍以内。

## 9. マイルストーン(beads 子 issue)

- M0 リポジトリ・パッケージ骨格・コア基盤(ByteSource/BitReader/Checked/Entry/文字コード判定/エラー/CLI/テスト基盤/CI/ベンチ・ファズ台)
- M1 ZIP(中央ディレクトリ駆動、ZIP64、遅延ローカルヘッダ、stored/deflate/deflate64/bzip2/LZMA、ZipCrypto/WinZip AES、CP932 名、拡張フィールド)
- M2 LZMA/LZMA2 + 7z(全コーダ、BCJ/BCJ2/Delta、AES-256、solid、group id、辞書リセット索引)
- M3 RAR3 + RAR5(PPMd H 共有、標準フィルタ、分割、暗号化)
- M4 LHA(lh0/lh1/lh4〜7/lz4/lz5/lzs、ヘッダ 0/1/2、SJIS、0x46)
- M5 tar/gz/bz2/xz、形式判定の網羅、KaitoKitCompat 完成、移行ガイド
- M6 cooViewer で ArchiveSource を KaitoKit に差し替える PoC(設定フラグ)、差分/ベンチ報告

## 10. 出自(プロベナンス)と参照の規則

- XADMaster のコードは実装資料として**参照・流用しない**。比較する場合もブラックボックスの展開オラクルに限る。ユーザー指示。
- 復号器ごとに参照した資料を design.md と該当ソースの先頭コメントに記録する。
- 読んでよい一次資料(公開ドメイン/公式): LZMA SDK の `lzma-specification.txt`・`7zFormat.txt`・`C/Ppmd7.c`・`C/Ppmd7.h`・`C/Ppmd7Dec.c`、Shkarin の PPMd var.H / var.I、RARLab の RAR 5.0 technote、LHa for UNIX の `header.doc`、PKWARE APPNOTE、POSIX tar、RFC 1951/1952。
- RAR 2.9/3.x は **7-Zip の Rar29 復号器を参照しない**(unRAR 制限付きコードから派生すると MIT を汚す)。挙動の参照は libarchive の `archive_read_support_format_rar.c`(BSD-2)と非公式のフォーマットノートに限り、`unrar` はブラックボックスのオラクルとしてのみ使う。
- 参照はいずれも「挙動と仕様」を学ぶためで、コードを写さない。ライセンスは MIT 単一。
