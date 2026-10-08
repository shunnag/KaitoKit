# 制限と破損書庫の救済

[対応表](formats.md) と合わせて、採用前に対象書庫の方式を確認してください。
[README](../README.md#既知の制限) には主な制限をまとめています。

## 既知の制限

- ISO は UDF > Rock Ridge（NM あり）> Joliet > PVD の順で名前の木を選びます（UDF の構造が壊れていれば
  ISO 9660 側へ戻ります）。後続 session、interleaved / sparse の内容展開、
  zisofs2（ZF version 2）と multi-extent の zisofs は未対応です。
  長さ 0 の extent は LBA を検証しません（libarchive は空 file と symlink に 0xFFFFFFF0 を書きます）。
- UDF は複数 volume の volume set、extended allocation descriptor（ext_ad）、device / FIFO / socket の
  file type（`.other`）、resource fork 以外の named stream（数だけ `namedStreams` に記録）、multisession の
  基準 sector S ≠ 0 に対応しません。7-Zip は symlink を含む UDF image を開けないため、検証の主オラクルは
  macOS の UDF driver です。ISO 9660 側だけが zisofs を持つ hybrid（genisoimage `-udf -z`）では、UDF の木が
  圧縮されたままの本文を返します（未確認の組み合わせ）。
- WIM は solid / ESD（LZMS）、分割 `.swm` の他 part の resource、EFS 暗号化 file、symlink / junction 以外の
  reparse point（`.other`）、security descriptor と Windows attribute の復元、integrity table の検証に対応しません。
  chunk size は XPRESS が 4〜64 KiB の 2 冪、LZX が 32 KiB です。7-Zip は compressed WIM を書けないため、圧縮 fixture は自作 encoder の出力を
  7-Zip が展開して検証したものです。
- cpio は PWB、HP-UX device number の解釈、device node の再作成に対応しません。stripped `07070X` は RPM header が必要で、単体では検出しません。
  hard link の 0-byte placeholder は内容を補完しません。圧縮 cpio は名前（`.cpgz` / `.cpio.<codec>`）で判断し、名前の無い Data からは連鎖しません。
- CAB は None / MSZIP / LZX を展開します。Quantum は一覧できますが、読み取り時に
  `unsupportedMethod` になります。複数 cabinet にまたがる file も同様です。
- RPM は drpm、cpio でない payload、file list tags が不足した `07070X` を圧縮済み payload の 1 entry として公開します。
  stripped の SHA-256 file digest は本文の完全読取時に照合し、他の digest algorithm は値の公開だけです。
  hard link の 0-byte placeholder は補完しません。[検証記録](verification/2026-09-22-rpm-stripped-payload.md)。
- ACE は未対応です。ARJ は method 4（compressed fastest）、garbled（暗号化）、multi-volume の続き file が `unsupportedMethod` です。StuffIt X (`.sitx`) は [対応表](formats.md#stuffit-classicstuffit-5stuffit-x) の codec・前処理の制約があります。StuffIt の method 4/7/9〜12、classic の未記述の暗号 flag `0x10` は読み取り時に `unsupportedMethod` を返します。
- ZIP は同名のリムーバブルメディアを交換する spanned、split PKSFX（先頭 `.exe`）、method 96 (JPEG)、97 (WavPack) を扱いません。
  split ZIP は全巻が同じディレクトリに必要で、欠番は巻名付きエラーになります。既定上限は 128 巻、分割セットの damaged-directory recovery は対象外です。
- ZIP / tar の AppleDouble sidecar（Finder / ditto の `__MACOSX/._name`、macOS tar の `._name`）は既定
  （`ReaderOptions.appleDoublePolicy = .merge`）で一覧から消え、resource fork を持つものだけ
  `name/..namedfork/rsrc`（`formatSpecific["fork"] = "resource"`）として data file の直後に並びます。Finder 情報と
  xattr は復元しません。参照先が無い sidecar と AppleDouble でない `._` file はそのまま残り、暗号化された sidecar は
  中身を確かめられないので残ります（`.hide` は `__MACOSX/` 配下を名前で隠します）。`.expose` で書庫どおりの一覧に
  戻ります。
- zstd の外部辞書は非対応です。Dictionary_ID が非零なら `unsupportedMethod` になります。
- 7z は RISC-V filter (method 0x0B) と、7-Zip ZS の LZ4 / Brotli / LZ5 / Lizard coder を扱いません。Zstandard coder の properties は 3 byte または 5 byte だけを受理します。7-Zip ZS の FLZMA2 は標準の LZMA2（ID 21）として書かれるため、そのまま読めます。
- RAR4 は unpack version 15/20/26、custom VM、dictionary size が変わる solid 構成、SFX と multi-volume の組合せを
  扱いません。RAR5 は compression version 1、SFX と multi-volume の組合せ、
  サイズ不明の暗号化 stored entry を扱いません。
- LHA は `-pm1-` / `-pm2-` / `-lh2-` / `-lh3-` を一覧できますが、読み取り時に
  `unsupportedMethod` になります。resource fork は separate entry として公開しません。
- XZ は Apple Compression が扱う XZ container が対象で、同 liblzma が知らない RISC-V filter 付き
  stream は `unsupportedMethod("XZ RISC-V filter")` になります。LZMA_Alone は `.lzma` / `.tlz` 拡張子と妥当なheaderがあるときだけ対象です。gzip/bzip2/xz の
  concatenated stream は一つの entry として連結した出力を返します。
- lzip の version 0（2008 年以前の lzip 0.x）は `unsupportedMethod` です。空 member は単独 file のときだけ受理します。
- tar の旧 GNU sparse（typeflag `S`、header 内の sparse 表と拡張 block）は展開できます。star の `SCHILY.filetype=sparse`、Solaris の `SUN.holesdata` は `unsupportedMethod` です。GNU sparse の major.minor が 1.0 以外の 1.x も同様です。[検証記録](verification/2026-09-22-small-method-gaps.md)。
- pbzx は展開結果の先頭が cpio magic でなければ単一 stream として公開します。chunk の展開後サイズの合計を open 時に確定し、`maxEntrySize` と chunk 数の上限（`maxMetadataRecordCount`）を適用します。
- brotli は名前のない Data / ByteSource からは識別しません。checksum が無いため、破損した stream が error なく別の出力になることがあります。RFC 9841 の shared brotli framing（署名 `91 0A 42 52`）は brotli として識別せず `unsupportedFormat` になります。framing の無い shared dictionary 依存の stream は RFC 7932 と byte 上区別できないため識別できず、辞書の参照が先頭 64 KiB の試し復号に掛かれば `unsupportedFormat`、それより後ろなら読み取り中に `malformed`（または別の出力）になります。
- gzip/bzip2/xz/brotli/`.Z` の出力サイズは読み終えるまで不明です。modern API では `nil`、compat API では
  `entryHasSize == false` / `Int64.max` になります。
- 圧縮 tar の判定には URL の拡張子 hint を使います。filename を持たない Data/任意 `ByteSource` は
  単一 file stream として開きます。
- 組込み cancellation token は未提供です。incremental 処理は caller が `EntryStream` の read loop を
  終了して制御します。
- 破損書庫の救済は既定で無効です。`ReaderOptions.recoverDamagedArchives = true` にすると、
  ZIP（中央ディレクトリを失ったもの）・tar・LHA・RAR5 から読める entry を取り出せます。救済対象は
  「EOCD が見つからない ZIP」であり、EOCD はあるが中央ディレクトリが壊れている ZIP は
  従来どおり `malformed` です。7z はヘッダが末尾にあるため切り詰められた書庫を救済できません。
  切れた entry は `ArchiveEntry.isIncomplete` が `true` になり、**CRC-32 / WinZip AES の HMAC /
  MacBinary の CRC-16 をいずれも検証しません**。暗号化 entry から救済した byte は認証されて
  いないため、信頼できない入力として扱ってください（password verifier は救済時も働くので、
  誤ったパスワードは従来どおり `wrongPassword` になります）。完全な entry と健全な書庫の
  読み取り結果は、この設定を有効にしても変わりません。
- RAR5 の救済には意図的な制限が 2 つあります。後続巻が欠けた multi-volume 書庫は救済せず
  従来どおり失敗します（次巻へまたがる entry を「完全」と偽らないため）。solid 群で切れた
  member は `isIncomplete` として一覧に出ますが、読むと `truncated` になります（復号状態が
  後続 member と連続するため）。なお暗号化された不完全 RAR5 entry は、認証されない byte を
  返さず何も返しません。

> **Known limitations**
>
> - ISO selects its name tree in the order UDF > Rock Ridge (with NM) > Joliet > PVD (falling back to
>   ISO 9660 when the UDF structures are damaged). Later sessions, interleaved or
>   sparse content expansion, zisofs2 (ZF version 2) and zisofs on a multi-extent file are unsupported.
>   A zero-length extent's LBA is not validated (libarchive writes 0xFFFFFFF0 for empty files and symlinks).
> - WIM does not support solid / ESD (LZMS), resources stored in other `.swm` parts, EFS-encrypted files,
>   reparse points other than symbolic links and junctions (`.other`), restoring security descriptors and
>   Windows attributes, or verifying the integrity table. XPRESS supports power-of-two chunks from 4 to 64 KiB; LZX requires 32 KiB. 7-Zip
>   cannot write compressed WIMs, so the compressed fixtures are the output of our own encoders verified by
>   7-Zip extraction.
> - UDF does not support multi-volume volume sets, extended allocation descriptors (ext_ad), device /
>   FIFO / socket file types (`.other`), named streams other than the resource fork (only counted in
>   `namedStreams`), or a multisession base sector S ≠ 0. 7-Zip cannot open UDF images that contain a
>   symbolic link, so the primary verification oracle is macOS's own UDF driver. On a hybrid whose ISO
>   9660 side alone carries zisofs (genisoimage `-udf -z`), the UDF tree returns the still-compressed
>   bodies (an unverified combination).
> - cpio does not support PWB, HP-UX device number interpretation, or recreating device
>   nodes. Stripped `07070X` requires an RPM header and is not detected as a standalone archive.
>   A 0-byte hard-link placeholder is not filled in with its target's content. Compressed cpio
>   is recognised by name (`.cpgz` / `.cpio.<codec>`) and is not chained from an unnamed `Data`.
> - CAB extracts None, MSZIP and LZX. Quantum can be listed but fails with `unsupportedMethod`
>   when read, as does a file that spans several cabinets.
> - RPM exposes drpm, non-cpio payloads and `07070X` without usable file-list tags as one compressed
>   payload entry. Stripped file digests other than SHA-256 are exposed without verification.
>   Hard-link placeholders remain empty. See the [verification record](verification/2026-09-22-rpm-stripped-payload.md).
> - ACE; ARJ method 4, garbled files and continued multi-volume members; StuffIt X codecs,
>   preprocessing, encryption and recovery outside the supported set; StuffIt methods 4/7/9–12;
>   and the undocumented classic encryption flag `0x10` are unsupported.
> - ZIP does not handle same-name removable-media spanning, split PKSFX (`.exe` first segment),
>   or methods 96 (JPEG) and 97 (WavPack). Split ZIP requires every volume in one directory; a missing
>   volume is an error naming that file. The default limit is 128 volumes; damaged-directory recovery
>   is unavailable for split sets.
> - AppleDouble sidecars in ZIP and tar (Finder / ditto `__MACOSX/._name`, macOS tar `._name`) disappear
>   from the listing under the default `ReaderOptions.appleDoublePolicy = .merge`; only those carrying a
>   resource fork appear as `name/..namedfork/rsrc` (`formatSpecific["fork"] = "resource"`) right after
>   their data file. Finder information and xattrs are not restored. Orphan sidecars and `._` files that
>   are not AppleDouble stay listed, and encrypted sidecars stay because they cannot be inspected
>   (`.hide` still removes everything below `__MACOSX/` by name). `.expose` lists the archive as stored.
> - External zstd dictionaries are unsupported; a nonzero Dictionary_ID produces `unsupportedMethod`.
> - 7z does not handle the RISC-V filter (method 0x0B) or the LZ4 / Brotli / LZ5 / Lizard coders of 7-Zip ZS.
>   The Zstandard coder accepts only 3- or 5-byte properties. 7-Zip ZS's FLZMA2 is written as standard
>   LZMA2 (ID 21) and reads as such.
> - RAR4 does not handle unpack versions 15, 20 and 26, the custom VM, solid configurations whose
>   dictionary size changes, or SFX combined with multi-volume. RAR5 does not handle compression
>   version 1, SFX combined with multi-volume, or an encrypted stored entry
>   of unknown size.
> - LHA can list `-pm1-`, `-pm2-`, `-lh2-` and `-lh3-` but fails with `unsupportedMethod` when
>   reading them. Resource forks are not exposed as separate entries.
> - XZ covers the XZ container that Apple Compression handles; a stream carrying a RISC-V filter that
>   its liblzma does not know returns `unsupportedMethod("XZ RISC-V filter")`. LZMA_Alone is covered only with a
>   `.lzma` / `.tlz` extension and a plausible header. A concatenated gzip, bzip2 or xz stream is returned as one entry whose output
>   is the concatenation.
> - lzip version 0 (pre-2008 lzip 0.x) is `unsupportedMethod`; an empty member is accepted only in a
>   single-member file.
> - Old GNU sparse tar entries (typeflag `S`, sparse table and extension blocks) can be read. Star's
>   `SCHILY.filetype=sparse` and Solaris `SUN.holesdata` remain `unsupportedMethod`, as is any GNU sparse
>   major.minor other than 1.0 in the 1.x family.
> - pbzx exposes a single stream unless the expanded bytes start with a cpio magic. The sum of the
>   chunks' unpacked sizes is fixed at open and checked against `maxEntrySize`; the chunk count is
>   bounded by `maxMetadataRecordCount`.
> - brotli is never identified from an unnamed `Data` / `ByteSource`. Because the format has no checksum, a
>   corrupted stream may decode to different output without an error. The RFC 9841 shared brotli framing
>   (signature `91 0A 42 52`) is not identified as brotli and yields `unsupportedFormat`. A stream that depends
>   on a shared dictionary without framing is byte-compatible with RFC 7932 and cannot be told apart: it yields
>   `unsupportedFormat` when the dictionary reference falls inside the 64 KiB trial decode, and `malformed`
>   (or different output) during the read otherwise.
> - The output size of gzip, bzip2, xz, brotli and `.Z` is unknown until the read completes. The modern API
>   reports `nil`; the compat API reports `entryHasSize == false` and `Int64.max`.
> - Compressed tar detection uses the extension hint of the URL. A `Data` or custom `ByteSource`
>   with no filename is opened as a single-file stream.
> - No built-in cancellation token is provided. Incremental work is controlled by the caller ending
>   the `EntryStream` read loop.
> - Recovery of damaged archives is disabled by default. Setting
>   `ReaderOptions.recoverDamagedArchives = true` recovers the readable entries of ZIP (with a lost
>   central directory), tar, LHA and RAR5. Recovery applies to a ZIP whose EOCD cannot be found; a
>   ZIP that has an EOCD but a corrupt central directory is still `malformed`. 7z keeps its header at
>   the end, so a truncated 7z archive cannot be recovered. A truncated entry sets
>   `ArchiveEntry.isIncomplete` to `true` and **verifies none of CRC-32, the WinZip AES HMAC, or the
>   MacBinary CRC-16**. Bytes recovered from an encrypted entry are unauthenticated, so treat them as
>   untrusted input. The password verifier still runs during recovery, so a wrong password is still
>   reported as `wrongPassword`. Results for complete entries and undamaged archives are unchanged by
>   this setting.
> - RAR5 recovery has two deliberate limits. A multi-volume archive missing a later volume is not
>   recovered and fails as before, so that an entry continuing into the next volume is never
>   presented as complete. A truncated member of a solid group is listed as `isIncomplete` but
>   returns `truncated` when read, because its decoder state is continuous with the following
>   members. An incomplete encrypted RAR5 entry returns nothing at all rather than unauthenticated
>   bytes.
