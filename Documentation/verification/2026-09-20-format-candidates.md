# 追加できる形式の候補調査（2026-09-20、v0.7.0 時点）

環境: macOS 27.2 / Apple Silicon / 7-Zip 26.03 / libarchive 3.7.4（`/usr/bin/bsdtar`）と
Homebrew libarchive 3.8.9（keg-only、`/opt/homebrew/opt/libarchive/bin/bsdtar`）。
対象は「KaitoKit が現在読めない形式・方式のうち、何を追加できるか」であり、
実装は含まない。2026-09-09 の [形式キュー](2026-09-09-format-gap-queue.md) の
状況列は陳腐化していたため、本記録で v0.7.0 時点の候補一覧を作り直した。

## 方法

- 調査は 25 family / 161 形式を並列の調査エージェントで行い、そのうち「小〜中規模かつ出自が
  public-prose / mixed」の 81 件に懐疑レビュー（主張の反証）を、全体に網羅性の検査を 1 回掛けた。
- 採点軸は design.md の規則に合わせた 5 つ。**出自**（§10: 公開の散文仕様・RFC・vendor technote
  だけで実装できるか。第三者実装のソースにしか記述がないものは blocked）、**オラクル**（§8:
  手元の黒箱 writer / reader）、**既存コードの再利用**、**工数**（small = 既存 codec の配線、
  medium = 既存 codec 上の新 container（cpio / ar 規模）、large = 新 codec または複雑な container
  （CAB LZX / LHA 規模）、very-large = 7z / RAR / StuffIt X 規模）、**遭遇頻度**。
- 調査出力には仕様の所在・題名・URL・ライセンスだけを書かせ、アルゴリズム・定数表・decoder
  ソースの転記を禁止した。本記録もその範囲で書いている。**本記録は実装入力ではない。**
  各候補を実装する際は、ここに挙げた一次資料を改めて `inbox/` に取り込み、SHA256SUMS と
  design.md §10 の出自段落を書くこと。
- 生データ（各形式の詳細・81 件の反証結果・網羅性検査）は約 1.6 MB の JSON で、リポジトリには
  含めない。

## 手元のオラクル（本調査で確認した事実）

| 種別 | 事実 |
|---|---|
| 7zz 26.03 | 読める: ARJ、CAB（Quantum 含む）、CHM、MSI/CFB、NSIS、DMG（HFS+/APFS へ自動で降りる）、UDF、HFS+、APFS、WIM/ESD、SquashFS、CramFS、ext2-4、FAT、NTFS、VHD/VHDX/VDI/VMDK/QCOW2、GPT/MBR/APM、MsLZ(SZDD)、`.pmd`、lzma86、Base64、Mach-O fat、Intel HEX、SWF。**読めない**: ZOO、ARC、ACE、ALZ/EGG、Amiga LZX、lzip、lzop、brotli、`.lzfse`、exFAT、zstd-in-7z（04F71101）、ZIP Reduce/DCL Implode/TERSE。書ける: 7z、zip、tar、wim、gzip、bzip2、xz |
| bsdtar 3.7.4（OS 同梱） | 読める: WARC（0.18 / 1.0。1.1 は拒否）、LHA、RAR4/RAR5、xar、mtree、ISO、CAB、7z、`.tar.uu`。書ける: `--lzip`、`--lzma`、`--uuencode`、`--b64encode`、`--format pwb`、warc、mtree、xar、iso9660（`--options zisofs`）。lz4 / zstd は外部 CLI 経由 |
| Homebrew bsdtar 3.8.9 | liblz4 / libzstd をリンク。**zstd-in-7z を書け・読める**（下記で確認） |
| hdiutil | `create -format UDRO/UDCO/UDZO/UDBZ/ULFO/ULMO/UDTO/UNIV`、`-fs HFS+/APFS/UDF/FAT12-32/ExFAT`、`makehybrid -hfs -iso -joliet -udf`（UDF 1.02 / 1.50）。`create` / `convert` は非推奨警告付きだが動作する |
| その他導入済み | xorriso 1.5.8（zisofs / zisofs2 / 追記 session）、rpm 6.1.0（`rpmbuild` は `07070X` を書く）、rar/unrar 7.23（`-oi` の file reference、`-md5g` 以上の version 1）、xz 5.8.4（`--format=lzip` の展開、`--riscv`）、brotli 1.2.0、cabextract 1.11（Quantum を読む）、lha = Lhasa 0.6.0（読み取りのみ）、`/usr/bin/{uuencode,uudecode,applesingle,macbinary,binhex,ditto,dot_clean}`、compression_tool（LZFSE） |
| 本調査中に導入されたもの | unar/lsar 1.10.8_7、deark 1.7.3（下記「逸脱」）。deark は XADMaster 系統から独立した唯一の reader オラクルで、arj / zoo / arc / lbr / squeeze / crunch / crlzh / amiga_adf / amiga_dms / applesd / binhex / macbinary / mscompress / nufx / packit / lha(PMA) を読む |
| brew に無いもの | arj、zoo、arc（`arc` は Chromium 系ブラウザの cask）、nomarch、lbrate、unace、unalz、xdms、unlzx、unadf、macutils、libmspack、LHa for UNIX |

### オーケストレータ自身による再確認

調査エージェントの主張のうち、A 群の前提になる 2 点と発見されたバグ 1 件は
オーケストレータが直接コマンドで確かめた。

```
$ bsdtar --lzip -cf t.tar.lz rnd2m.bin && xz -d --format=lzip -c t.tar.lz | bsdtar -tf -
rnd2m.bin

$ /opt/homebrew/opt/libarchive/bin/bsdtar --format 7zip --options 7zip:compression=zstd -cf t7.7z rnd2m.bin
$ 7zz l -slt t7.7z | grep Method
Method = 04F71101
$ /opt/homebrew/opt/libarchive/bin/bsdtar -tvf t7.7z
-rw-r--r--  0 0      0     2097152  9月 20 16:01 rnd2m.bin
$ .build/release/kaito sha t7.7z
0	ERROR	failed entry 0: Unsupported archive method: 7z method 0x04F71101	rnd2m.bin
```

## A. すぐ着手できる（出自クリーン・オラクル手元・既存コード再利用・小〜中）

| 候補 | 再利用 | オラクル | 工数 | 決めること・注意 |
|---|---|---|---|---|
| lzip `.lz` / `.tar.lz` | 既存 LZMA1 decoder | writer: `bsdtar --lzip`、reader: `xz -d --format=lzip` | 小 | `.tlz` の解釈（現在は tar.lzma。lzip 自身は `.tlz` = tar.lz）。lzip manual / I-D は付録に参照コードを含むため、散文部分だけを切り出して取り込む。CRC-32 と「plain LZMA1」の同一性は散文に明記が無く黒箱で確認。version 0 member は拒否 |
| brotli `.br` / `.tar.br` | Apple Compression `COMPRESSION_BROTLI`（macOS 12+、SDK で確認）。`XZDecompressor` と同型の wrapper | brotli CLI 1.2.0 | 小 | magic が無い（拡張子＋試し復号）。Apple の decoder は RFC 9841 の大窓（WBITS 30、実測 204 MB RSS）を受理し `maxDictionarySize` を見ないため、RFC 7932 / 9841 の散文から WBITS 検査を書く。サイズ・checksum は無い |
| 7z zstd coder（04 F7 11 01） | 既存 `ZstdDecompressor` | Homebrew bsdtar 3.8.9 が writer / reader（上記） | 小 | `SevenZipMethod` への登録と properties 長の検査、solid folder の再開。README「7z は zstd method を扱いません」を閉じる。7-Zip ZS / NanaZip の書庫 |
| 7z FLZMA2 | 既に LZMA2（ID 21）として読める（p7zip 17.05 書庫で確認） | p7zip | ゼロ | fixture 1 本と README 注記 |
| RAR5 file-copy redirection（`rar -oi`） | RAR5Reader | rar/unrar 7.23 | 小 | 現状は 0 byte の `other`。参照先を hard link と同様に公開し、`read()` の意味論と `ReadLimits` の増幅・`isEncrypted` を決める |
| ISO 9660 zisofs（ZF） | zlib（`DeflateDecompressor(zlibWrapped:)`） | writer: `bsdtar --options zisofs` / xorriso、reader: 両者 | 小 | 7zz は圧縮バイトのまま返すので負のコントロール。zisofs2 は version で門を置く |
| ISO 9660 後続 session | ISOReader | xorriso `-load sbsector N` | 小 | `ISOVolume.range` が session 自身の Volume Space Size で extent を切るため境界修正が必要（反証で `truncated` を再現）。session 選択の API を決め、既定は最初の session のまま |
| uuencode `.uu` / `.uue` / `.tar.uu` | SingleFileReader 型 | `/usr/bin/uuencode` / `uudecode`、bsdtar、python `binascii` | 小〜中 | 空白 trim 行を uudecode / bsdtar は拒否し binascii は受理する → 方針決定。design.md の回帰 corpus に uuencode 34 件があり出力が変わる |
| cpio PWB | CpioReader | `bsdtar --format pwb`、`bsdcpio -6` | 小 | 需要ほぼ皆無。bin 形式と magic が同じ。`bsdtar` の PWB 出力は通常 file では bin と同一なので IALLOC / ILARG を含む fixture は `CpioArchiveBuilder` で作る |
| LZFSE stream `.lzfse` | Apple Compression | compression_tool（同じ libcompression なので独立ではない）、brew lzfse | 小 | 価値低。magic 3 byte は最弱。Apple の decoder は終端 marker より先を chunk 単位で読み進むため XZ wrapper の末尾処理は転用できない |

## B. 中規模〜大規模だが出自はクリーン（価値順）

1. **DMG/UDIF + HFS+**（大）— macOS 利用者に最大の価値。XADMaster / The Unarchiver は HFS+ DMG を
   開けない（2026-09-09 の gap 調査で確認済）。UDIF container は公開散文（libmodi の文書、
   Just Solve）、HFS+ は Apple TN1150、writer は hdiutil（全圧縮種）、reader は 7zz、真値は
   `hdiutil attach`。container 単体では entry を出せないので HFS+ と一体で計画する。ADC（UDCO）は
   `unsupportedMethod` のままでよい。`maxEntrySize`（4 GiB）が partition entry を拒否する既定の
   見直し、koly 用の末尾署名 probe、plist 解析、chunk cache 付き ByteSource が要る。
   APFS（macOS 26 の hdiutil 既定）は Apple File System Reference が公開だが very-large。
   **2026-09-22 完了**（`.dmg` case。UDIF の zlib / bzip2 / lzfse / lzma / raw、HFS+ の catalog・extents overflow・
   hard link・resource fork。ADC と APFS と decmpfs は非対応。[検証記録](2026-09-22-dmg.md)）。
2. **既存形式の穴**（網羅性検査で判明、いずれも新 case なし）:
   classic StuffIt 分割セット（`inbox/stuffit/report/06-wrappers-and-segments.md` §"Classic StuffIt
   split files" に 100 byte の segment wrapper の記述あり。確認済。sibling 配管のみ）／GNU tar sparse・multi-volume（`TarReader.swift` が `unsupportedMethod`、
   bsdtar が writer）／圧縮 cpio の連鎖 `.cpgz` `.cpio.gz|xz|zst`（Archive Utility が出す。
   圧縮 tar と同じ staging）／ZIP・tar 内の `__MACOSX/._*` AppleDouble の扱い（Finder 製 zip 全部。
   現状は普通の file として一覧）／PE SFX 内 CAB（IExpress、`MSCF` は offset 0 でしか見ていない）／
   pbzx（flat `.pkg` の Payload。xz chunk の連結。chunk 表は `pkgutil --expand` 出力の黒箱計測）。
3. **UDF**（大）— ECMA-167 / OSTA UDF 1.02–2.60（無償公開）。writer: `hdiutil makehybrid -udf`、
   `newfs_udf -r 1.02..2.60`、reader: 7zz。README の既知の制限を閉じる。hybrid の名前木の優先順位を
   決める。UDF ≤2.01 → metadata / virtual partition の順。**2026-09-21 に対応**（`.udf` case を追加、hybrid は
   UDF の木を優先。7zz は symlink を含む UDF を開けないため真値は macOS の UDF driver。
   [検証記録](2026-09-21-udf.md)）。
4. **WIM**（大）— Microsoft の WIM whitepaper（抽出ツール作成を許す通常の著作権表示）＋[MS-XCA]
   （OSP）。既存 LZX 再利用＋XPRESS 新規。実書庫の metadata resource は LZX なので LZX は前提。
   7zz が reader。ESD / solid WIM（LZMS）は source-only で blocked。**2026-09-21 に対応**（`.wim` case、
   7zz は compressed WIM を書けないため自作 encoder + 7zz 展開で fixture を作った。
   [検証記録](2026-09-21-wim.md)）。
5. **CHM/ITSS**（大）— 既存 LZX 再利用（reset interval の API 追加）。Wise / Wing の仕様書は GPL
   ライセンスの文書 → 裁定要。7zz と手元の日本語 `.chm` がオラクル。
   **2026-09-21 完了**（裁定 1 承認後。`.chm` case、Russotto + Wise / Wing 文書、実物 2 本で 7-Zip と一致。
   [検証記録](2026-09-21-chm.md)）。
6. **BIN/CUE 生セクタ CD image**（中）— ECMA-130。ISOReader をそのまま再利用。導入済みツールは
   2352 byte image を読めない（7zz / bsdtar / hdiutil で確認）ので、project-owned のセクタ encoder
   （EDC/ECC）で ground truth を作る。MDF はその上に乗る。NRG / CDI / `.mds` は blocked。
   **2026-09-21 完了**（EDC / ECC は検証しない方針にしたので fixture の trailer は無効値。
   [検証記録](2026-09-21-bincue.md)）。
7. **cpio newcx / rpm 6 payload（`07070X`）**（中）— rpm.org の散文＋黒箱計測（symlink の本文、
   hard link の最終 member、index 順と payload 順）。rpm 6.1 が writer。既存 v6 fixture は gzip
   payload（zstd ではない）。
8. **WARC**（中）— ISO 28500。gap queue の方針（XADMaster 同等: response / resource の payload、
   host/path 名）。bsdtar は 1.0 まで、block を返すのでオラクル間で byte が一致しない → 方針決定が先。
9. **MS-CFB → MSI**（中）— [MS-CFB] は OSP。7zz が reader。MSI の実ファイル名復元は source-only。
   `ConcatenatedByteSource` の 128 segment 上限を超える cabinet stream の連鎖が要る。
   **2026-09-21 に CFB 一般を対応**（`.compoundFile` case。MSI の名前は裁定 4 の承認後に 7-Zip の挙動から黒箱で
   復元。内蔵 cabinet の連鎖は見送り。[検証記録](2026-09-21-cfb.md)）。
10. **ZIP 旧 method Shrink(1) / Implode(6) / Reduce(2–5)**（各 中）— APPNOTE §5.1–5.3（bit 順・終端は
    黒箱で補う）。reader: unzip（Shrink / Implode）、7zz（Shrink / Implode）、deark（全部＋DCL）。
    writer は自作 encoder。レトロ DOS 用。DCL Implode(10) / TERSE(18) / LZ77(19) は blocked。
    **2026-09-21 完了**（[検証記録](2026-09-21-zip-legacy.md)）。
11. **ZOO / ARC / Squeeze / LBR**（中）— 既存 lh5・LZW・RLE90・CRC16（`StuffItWrapper.xmodem` を
    昇格）を再利用。deark が独立 reader（xadsha は PAK method 11・LBR pad・ARC 数件で誤る）。
    ZOO 2.x の拡張 entry と ARC method 5/6/7/10 は散文が無い。歴史的。
12. **ARJ**（中、container＋stored のみ）— ARJ Software の technote 2 版（2001 年版は末尾に UNARJ の
    C 抜粋を含むので切除して取り込む）＋CC0 wiki。7zz / deark / unar が reader、writer は手元にも
    brew にも無い（MacPorts arj か DOSBox）。method 1–3 は既存 `LZSStaticHuffmanDecoder` の
    parameter 違いである可能性が高いが、design.md に記録済みの ar002 スニペット開示（design.md:684、
    699、`LZSStaticHuffmanDecoder.swift:17`）が ARJ codec の汚染に当たるかの裁定が先。method 4 と
    garble は source-only。実書庫の 34/38 member が method 1 なので stored のみでは価値が薄い。
    **2026-09-21 完了**（container + stored + method 1〜3。method 1〜3 は既存 LHA decoder の lh6 parameter で、
    実物 11 書庫が 7-Zip と一致。method 4 / garbled / multi-volume は非対応。[検証記録](2026-09-21-arj.md)）。
13. **ADF**（中）、**SquashFS**（大）、**AppleSingle / MacBinary / BinHex 単体**（中: 既存 parser は
    private かつ StuffIt envelope 専用で、`FormatDetector.stuffItInput` が非 StuffIt payload を
    `unsupportedFormat` にする。検出順序の変更と既存テストの反転が要る。**2026-09-21 に対応**、
    [検証記録](2026-09-21-macwrappers.md)）、**AppleDouble**（中:
    製品方針。modern macOS の writer は xattr block を持ち、その記述は APSL ソースのみ）、
    **ish**（中: 作者公開の `ISHFORM2.DOC` / `INTERISH.DOC` が `ish203s.lzh`（Vector）内にあり、
    日本語の一次資料。blocked ではない）、**zstd / LZ4 外部辞書**（中、稀）、**MsLZ SZDD `.DL_`**
    （小だが libmspack ページ（無ライセンス、擬似コード）の裁定要）、**PET / SPK**（tar の alias。
    PET は末尾 32 byte の MD5、SPK は Synology 公式ビルドが不透明 container）。

## C. 出自またはオラクルで阻まれる（裁定がなければ着手不可）

ACE 1.x / 2.x（codec は GPL/LGPL/BSD ソースのみ、writer 無し）、ALZ の難読化 Deflate と EGG
（ESTsoft の仕様は AES/LEA KDF と LZMA framing を欠く）、Amiga LZX / PowerPacker / DMS / XPK、
Compact Pro / PackIt 圧縮 / DiskDoubler / Now Compress（Unarchiver wiki は §10 で「直接の入力なし」
扱い、しかも C 抜粋を含む）、CAB Quantum（Russotto のページは無ライセンス RE 散文＋C 表。
cabextract / 7zz は decoder として確認済、writer 無し）、LHA -lh2- / -lh3-（散文・writer・reader
すべて無し）、-pm1- / -pm2-（source-only。deark と Lhasa が reader）、StuffIt classic method 4 / 7 /
9–12・flag 0x10（何も存在しない）、StuffIt X の残り（Iron v1 は Ch.50 が未納品、Root 暗号 /
recovery / segment / base-N は Ch.15–22 が未納品）、RAR4 v15 / 20 / 26（bitplane 散文で可能だが
LHA 級の新 codec を version ごとに、需要ほぼ無し）、RAR5 v1（design.md:609 により bitplane は
RAR5 で不許可。>4 GiB のテスト入力が要る）、7z / xz RISC-V filter（散文が無い。2026-09-09 /
2026-09-18 に導出を保留済）、ZIP 94 / 96 / 97、ZIP strong encryption（flag 0x0040。writer も
decoder オラクルも無し）、lzop、lrzip、rzip、grzip、zpaq（書庫内 ZPAQL bytecode の実行が必要）、
PAQ8 / LPAQ / QUAD / BALZ / BCM、PEA、YZ1 / GCA / DGCA / BGA / JACK / Belon / NOA / HKI / BH、
NSIS / InstallShield / Inno Setup、DAA / UIF / ISZ、VDI、ESD（LZMS）、drpm、CramFS（GPL header
のみ）、UEFI capsule。

## D. 対象外（メディア抽出であって書庫展開ではない）

SWF、FLV、PDF、NDS、NSA / SAR、Mach-O universal、Intel HEX、MIME（.eml / .mht）、ELF / PE / COFF。
2026-09-09 の gap queue の判断を維持する。

## 固定コスト（新しい `ArchiveFormat` case 1 つあたり）

exhaustive switch 2 箇所（`ArchiveReader.swift:135`、`kaito/main.swift:29`）、Compat の formatName、
README の冒頭 JP+EN（`ReleaseReviewDocumentationTests` が検査）と対応表 2 つ、CHANGELOG の公開 enum
破壊的変更の注記、design.md §10 の出自段落、verification 記録、`Tests/Fixtures/NOTICE`、
`Scripts/fuzz/mutate.py` の payload locator、Compat / CLI テスト。実績: LZMA_Alone + tar.Z 18 file、
ar 23 file、ISO 22 file、LZ4 74 file。複数の新 case は 1 リリースにまとめて利用側（cooViewer）の
source break を 1 回にし、alias で済むもの（PET / SPK → tar、MDF / BIN → iso、PMA → lha、
FLZMA2 → 7z）は case を増やさない。

## 先に決めてもらう裁定（C 群の多くを左右する）

1. GPL / GFDL ライセンスの**文書**（kernel docs、Wise / Wing CHM 仕様、GNU tar manual）を入力に
   使ってよいか。
2. パブリックドメインの**ソース**（zoo 2.10 のコメント、LZWCOM、Caie の PowerPacker decoder、
   xDMS、Shkarin PPMd）を LZMA SDK / PPMd の前例として許すか。
3. 無ライセンスの RE 散文（libmspack SZDD / KWAJ、Russotto Quantum、Unarchiver wiki の Compact
   Pro / DiskDoubler / AlZipSpecs、MacDisk ADC）を一次入力にしてよいか。
4. GPL ツールの**挙動のみ**の参照（7zz の MSI 名、libarchive の lzop）を RAR4 / libarchive の
   前例に含めるか。
5. 開示済みの ARJ / ar002 `read_pt_len` スニペットが ARJ codec の汚染になるか。
6. メディア抽出（SWF tier A、MIME）を範囲に入れるか。
7. libAppleArchive（閉じた C ライブラリ内の container 解析）を §6 の許可リストに加えるか（AAR / YAA 用）。
8. design.md §8「XADMaster は性能基準のみ」と 2026-09-09 gap queue「XADMaster 実行ファイルが
   オラクル」の矛盾をどちらに寄せるか（StuffIt / xar の前例は後者）。

## 副産物: 既存バグ（再現済）

7z の x86 BCJ（03030103）/ ARM64（0A）filter を 1 MiB 超のランダム系 payload に掛けた書庫で
`Checksum mismatch`。7zz 26.03 `-m0=BCJ -m1=LZMA2`、`-m0=BCJ -m1=Copy`、`-m0=ARM64 -m1=LZMA2`、
`-m0=ARM64 -m1=Copy`、および p7zip 17.05 `-m0=bcj -m1=lzma2` の書庫で再現。1,048,576 byte は通り
1,114,112 byte で失敗。ARM / ARMT / PPC / SPARC / IA64 / Delta / Swap2 / Swap4 / BCJ2 は 2 MiB で通り、
plain LZMA2 は 12 MiB で通る。既存 fixture は 8 KiB（`SevenZipFilterTests.swift:68`）。
v0.7.0 の HEAD（`3e48efc`、tree clean）の release build で再現した。

```
$ head -c 2097152 /dev/urandom > rnd2m.bin && shasum -a 256 rnd2m.bin
4c2c75eb71ba6bb4c4822897df667cd7369b246f7187c6150963e9eec6f9cb32  rnd2m.bin
$ 7zz a -m0=BCJ -m1=LZMA2 bcj.7z rnd2m.bin && 7zz t bcj.7z | tail -1
Everything is Ok
$ .build/release/kaito sha bcj.7z
0	ERROR	failed entry 0: Checksum mismatch (source member 0)	rnd2m.bin
partial	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
$ .build/release/kaito sha plain.7z          # -m0=LZMA2
0	2097152	4c2c75eb71ba6bb4c4822897df667cd7369b246f7187c6150963e9eec6f9cb32	rnd2m.bin
```

同日中に修正した（[修正記録](2026-09-20-sevenzip-bcj-large-payload.md)）。再現に使った書庫は `.build/repro-bcj/`（git 管理外、`swift package clean`
で消える）に置いたが、乱数 payload は記録していない。任意の 2 MiB 乱数で再現するので、上記コマンドで
作り直せる。

## 本記録で直した文書

- `Documentation/verification/2026-09-09-format-gap-queue.md` の状況列（8・12 番と CAB LZX は完了済）に
  2026-09-20 の追記を加えた。
- `Sources/KaitoKit/KaitoKit.docc/KaitoKit.md` の概要が ZIP / 7z / RAR / LHA / tar / gzip / bzip2 / xz /
  compress しか挙げていなかったので、v0.7.0 の対応形式に合わせた。
- `Documentation/migration-from-xadmaster.md` §11 が StuffIt / zstd stream / ZIP 95 / CAB LZX / RPM zstd
  payload / RAR5 SFX を未対応と書いていたので、README の「既知の制限」に合わせた。

## 逸脱の記録

- 調査エージェントに「brew install も網羅的な導入もしない」と指示したが、懐疑レビュー段階の
  1 エージェントが 14:35 に `brew install unar deark` を実行した（Cellar の mtime で確認）。
  利用者の判断で両方とも残す（deark は上記のとおり独立 reader オラクルとして有用）。
- WebFetch の保存物 `corion.html`（HTTP 521 の本文）と `unar.html`（theunarchiver.com のトップ）が
  リポジトリ直下に落ちていたため、内容を確認して削除した。
- ツール可用性の調査エージェントが、7-Zip の対応形式・method 一覧を得る目的で GitHub 上の 7-Zip
  ソース 5 file（エージェントの自己申告ではなく、全 111 エージェントの tool 呼出し履歴から取得 URL を
  抽出した監査で判明）（`CPP/7zip/Archive/Zip/ZipHandler.cpp`、`Zip/ZipHeader.h`、`Cab/CabHandler.cpp`、
  `DmgHandler.cpp`、`UI/Console/Main.cpp`）を取得した。抽出したのは「7-Zip がどの method 番号 /
  block 種別を扱うか」の一覧だけで、復号アルゴリズムではない。それでも §10 の規則に反するため、
  この一覧は本記録に転記せず、ZIP method 番号は APPNOTE、CAB の method は MS-CAB、DMG の block 種別は
  公開散文（libmodi 文書 / Just Solve）から改めて取ること。7-Zip ソースは KaitoKit の実装入力に
  していない。
- 懐疑レビューの一部で、WebFetch の要約が仕様ページに埋め込まれた C の断片を自動表示した（ARJ
  2001 年 technote の末尾、SQDATE.DOC §III–IV、ADF FAQ、TN1189、Russotto の Quantum ページ、
  hanshq.net の ZIP 解説、lzip manual / I-D の付録）。これらのページを実装入力にする場合は、
  2026-09-18 の lzip の前例どおり散文だけに切り詰めて `inbox/` に取り込み、§10 に記録すること。
- 同じ監査で、調査エージェントは XADMaster / The Unarchiver のソースを開いていない（取得したのは
  theunarchiver.com と GitHub wiki の対応形式ページのみ）。GPL / LGPL プロジェクト（unalz、
  libmirage、wimlib、ntfs-3g 等）は LICENSE / README / ディレクトリ一覧だけを取得した。
