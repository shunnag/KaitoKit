# HFS+ decmpfs の読み取り（2026-09-22）

環境: macOS 27.2（26B5091g）/ Apple Silicon / Apple Swift 6.4（swiftlang-6.4.0.34.1）/ macOS 27.0 SDK。
worktree: `<repo>`（`wt/decmpfs`）。git コマンド・main repository・Web・第三者の実装 source は使っていない。

orchestrator が sandbox 外で fixture の生成、全 11 本の本文照合、7-Zip の対応 5 type の展開照合を完了した。
`hfs-decmpfs.dmg.gz.b64` / `manifest-decmpfs.json` を収録し、新 image を含む DMG / 文書 / CLI テストは失敗 0。
Apple の実物の type 4 / 8 と ditto の type 7 / 8 も raw HFS+ image で SHA-256 が一致した。
以下では提供された外部実行結果と sandbox 内の実行結果を区別し、初回の拒否や FACTS 訂正の証拠も残す。

## 実装と範囲

- `HFSPlusVolume.decmpfsAttributes`: attributes fork（ID 8）の B-tree を一度走査し、正確な名前
  `com.apple.decmpfs` の inline 値だけを CNID ごとに保持する。key 長・UTF-16 長・偶数境界・record 長を検査。
  先頭 extent が 0 block なら属性 file は無い。他の属性の data は解釈しない。件数は `maxEntryCount`、値は 64 KiB、走査量は既存の metadata budget、
  保持量は `maxTotalMetadataSize`。fork data（0x20）、extents（0x30）、非零 startBlock は一覧用の印だけを残す。
  同じ CNID の続き record があっても fork の印を維持し、他の file の一覧・読み取りを妨げない。
- `HFSVolumeListing`: UF_COMPRESSED は hard link の indirect node を解決してから属性を探す。
  header の展開長を `uncompressedSize`、inline payload 長 / resource fork 長を `compressedSize` に公開し、
  `hfsCompressed=true` と `decmpfsType` を付ける。属性無し・bad magic はサイズ不明で一覧し、読むと
  `malformed`。fork data 属性は `unsupportedMethod("HFS+ decmpfs attribute stored as a fork")`。
- `DecmpfsDecompressor`: type 1 / 3 / 4 / 7 / 8 / 9 / 10 / 11 / 12 を順に返す。resource fork は 64 KiB ごと、
  末尾は残りの長さ。圧縮 chunk は 69,632 byte 以下、fork 範囲・表長・chunk 数・割り当て上限を検査し、
  展開済み 1 chunk と圧縮 1 chunk を保持する。offset / descriptor 表は必要な組だけを読む。
- zlib は CMF/FLG を検査し、system zlib の raw inflate が最終 block に達することと展開長を確認する。
  Adler-32 は無くてもよく、残り 0–4 byte を許す。LZVN / LZFSE は Apple Compression の stream API で
  END・実出力長・入力消費長を検査する（下記の FACT 7 の反例による変更）。
- type 5 / 13 / 14 と未知の type は header のサイズで一覧し、本文は type 番号を付けた `unsupportedMethod`。
  resource fork は圧縮 file の別 entry にしない。既存の非圧縮 file / symlink / hard link / fork は従来どおり。

## 実装入力

Metz, "Hierarchical File System (HFS)"（libyal/libfshfs 文書、GFDL 1.3、裁定 1）の
"The HFS+ attributes file" / "Compressed data extended attribute" / "File content"、
Apple TN1150 の Attributes File 章（`inbox/dmg/tn1150.txt` 2852–2970 行）、chflags(2)、
利用者の orchestrator が提供した FACTS 1–9。形式の具体値は提供された FACTS を主入力とし、
TN1150 の章と保存済み文書の hash を照合した。

```text
$ shasum -a 256 inbox/dmg/libfshfs-hfs.asciidoc
26cfeafc3b35f3d78e93bd5e7615ab7cc4e87e2b4b4c45f78f978a52e8b6d470  inbox/dmg/libfshfs-hfs.asciidoc
```

黒箱観察の番号・内容は [design.md §10](../design.md) の decmpfs 追補に列挙した。
Apple Compression の `bvxn` / raw size / payload size / payload / `bvx$` envelope を使う。
Apple の decmpfs / xnu headers（decmpfs.h / hfs_format.h）、libarchive、The Sleuth Kit、afsctool、lzfse、
libfshfs C code、dmg2img、7-Zip、XADMaster その他の実装 source は開いていない。

## fixture の手順と生成結果

`Tests/Fixtures/dmg/generate-decmpfs.sh`（bash + Python 3、macOS のみ）:

1. 決定的な自作 text pattern で原本を作る。12 MB、HFS+、`-type UDIF -layout GPTSPUD` の rw image を create / attach。
2. `ditto --hfsCompression` で 20,000 byte / 300,000 byte を type 7 / 8 にし、ctypes の raw getxattr で
   type を assert。type 8 は offset 表から 5 chunk も確認する。orchestrator の実測では圧縮可能な入力でも
   16,384 byte 以下は非圧縮、16,385–65,536 byte は type 7。20,000 / 300,000 byte の指定は維持する。
3. inline / resource fork を `setxattr(XATTR_SHOWCOMPRESSION = 0x20)` と `chflags(UF_COMPRESSED = 0x20)`
   で合成する。type 1 は raw、type 9 は必須の `0xCC` + raw。type 3 は zlib（reader は `0xFF` + raw も受理）。
   type 4 の chunk は zlib（Adler 付き）、zlib（Adler 無し）、raw、zlib、zlib。
   type 11 / 12 は `/usr/lib/libcompression.dylib` の encode 出力。type 4 の map は支給された 50 byte。
4. 読める全 file を mount 上で `cmp`。type 5 / 13 は本文比較をしない。`empty1.bin` は空 type 1、
   追加の `empty-compressed` は EINVAL なら省略する手順だが、今回は両方とも driver が受理した。
   UF_COMPRESSED flag と属性の type / size を確認する。
5. detach / UDZO convert。`7zz l` で全 payload 名を確認し、type 3 / 4 / 7 / 8 / 9 を `7zz x` で
   一時 directory へ展開して原本と `cmp`。7zz の失敗・file の欠落・不一致は生成失敗とする。
   type 1 / 10 / 11 / 12 / 13 は 7-Zip 26.03 が空 file にするため、この比較には含めない。
6. image の gzip + base64 が 200 KB 未満であることを確認し、image と manifest-decmpfs.json を保存する。
   manifest は既存と同じ payload / images 形式に decmpfsType と `sevenZipVerified` を加える。
   `sevenZipVerified` は実際に 7zz x / cmp を通った file だけ true、それ以外は false。既存 image と manifest.json は触らない。

### sandbox 外で完了した生成

orchestrator が `bash Tests/Fixtures/dmg/generate-decmpfs.sh` を実行し、exit 0。
合成した全 case が driver に受理され、`empty-compressed` も収録した。実出力の末尾:

```text
Method = HFS+
Characteristics = ZLIB-attr ZLIB-rsrc LZVN-attr LZVN-rsrc COPY-attr COPY-rsrc LZFSE-attr LZFSE-rsrc 0x2022
Everything is Ok
Files: 5
Size:       621680
Compressed: 24476
ditto7.txt: 7zz x / cmp OK
ditto8.txt: 7zz x / cmp OK
inline3.bin: 7zz x / cmp OK
inline9.bin: 7zz x / cmp OK
zlib4.bin: 7zz x / cmp OK
hfs-decmpfs.dmg: 24476 bytes -> 7320 b64 bytes
```

image は 24,476 byte、SHA-256 は
`c147ff1649660f2b244510c490204496fe46bcfa3de5ddea8b78e3c45744a867`。
収録した gzip + base64 は 7,320 byte で、200 KB の上限内。

### 初回の sandbox 内の実行記録

修正前の実行結果（exit 1、この時点で生成を停止）:

```text
$ bash Tests/Fixtures/dmg/generate-decmpfs.sh
hdiutil: WARNING: 'hdiutil create -size -volname ...' is deprecated. Please use 'diskutil image create from/blank -size --volumeName ...' instead.
hdiutil: create failed - 装置が構成されていません
失敗: hdiutil create -size 12m -fs HFS+ -volname KaitoDecmpfs -type UDRW -layout GPTSPUD "$WORK/rw.dmg" (exit 1)
```

拒否されたコマンドは
`hdiutil create -size 12m -fs HFS+ -volname KaitoDecmpfs -type UDRW -layout GPTSPUD "$WORK/rw.dmg"`。
attach / ditto / setxattr / chflags / detach / convert には達していない。別方式の image を代作していない。
上記は修正前の実行記録。レビュー後、orchestrator の環境で `-type UDRW` が
`invalid argument for -type` と判明したため、生成器は既存 generate.sh と同じ `-type UDIF` に訂正した。
以降の hdiutil 実行と生成の完了は上記の orchestrator による sandbox 外の実行。
sandbox 内では指示どおり hdiutil を再実行していない。
生成器の構文確認は次のとおり（埋め込み Python は `ast.parse`）。

```text
generate-decmpfs.sh: bash -n OK; 4 embedded Python blocks parsed
generate.sh: bash -n OK; 5 embedded Python blocks parsed
```

## type の検証範囲

新 fixture の読める 11 file はすべて HFS+ driver の `cmp` と manifest の SHA-256 に一致した。
KaitoKit の `read`、小 buffer の stream、`reopen()`、逆順読み取りを含む 2 件の fixture テストも通過した。
type 5 / 13 は header size で一覧し、読むと番号付き `unsupportedMethod`。
`maxEntrySize` を 300,000 未満にした open の `limitExceeded` も確認した。

| type | 方式・置き場 | 検証済みの新 fixture | 既存 fixture・単体検証 |
| --- | --- | --- | --- |
| 1 | stored inline | inline1.bin（840）、empty1.bin（0）、empty-compressed（0） | stored / 空 / 長さ違いの vector |
| 3 | zlib inline | inline3.bin（840） | Adler 有無、raw、最終 block 無し・余剰 byte の拒否 |
| 4 | zlib resource | zlib4.bin（300,000、5 chunk） | zlib / Adler 無し / raw 混在、dataOffset=64、不正 descriptor / count |
| 7 | LZVN inline | ditto7.txt（20,000） | 既存 compressed.txt（57,000）、padding・破損 vector |
| 8 | LZVN resource | ditto8.txt（300,000、5 chunk） | LZVN / padding vector、逆行 offset / count の拒否 |
| 9 | `0xCC` + raw inline（必須 prefix） | inline9.bin（840） | prefix の欠落・誤り・長さ違い・空 file の vector |
| 10 | stored resource | raw10.bin（300,000、5 chunk） | 2 chunk、遅延読み取り、終端・割り当て上限 |
| 11 | LZFSE inline | inline11.bin（840） | Apple Compression encode / raw vector |
| 12 | LZFSE resource | lzfse12.bin（300,000、5 chunk） | 2 chunk の encode 出力と raw vector |
| 5 / 13 | 非対応 | type5.bin / type13.bin（header size 840） | 番号付き unsupportedMethod の vector |
| 14 / 未知 | 非対応 | 無し | 14 / 99 の unsupportedMethod の vector |

`DMGReaderTests.testDecmpfsAttributeErrorsAndHardLinkTarget` は既存 image の展開済み disk をメモリ内で変更し、
属性無し・bad magic・fork 属性・非零 startBlock・0x30 extents・名前の大小文字違いを「一覧可、読むと失敗」で確認した。
これらの各変異でも別 file の data.bin は一覧でき、元の SHA-256 で読める。
同じ inline 属性を indirect node の CNID へ移し、2 本の hard link の本文 hash・サイズ・resource fork 非公開も確認した。

## FACTS との差分

### FACT 8 の type 9 と独立 oracle の訂正

orchestrator の外部黒箱追試（裁定 4）では HFS+ driver は prefix 無しの type 9 を EINVAL で拒否した。
正しい payload は必須の `0xCC` + raw bytes、長さは header size + 1。type 1 は prefix 無しの raw のまま。
type 3 inline の `0xFF` + raw escape も driver が受理する。decoder・生成器・vector・日英 README を訂正した。

同じ追試で **7-Zip 26.03 は decmpfs type 3 / 4 / 7 / 8 / 9 を byte 一致で展開できる**と確認された。
「decmpfs 本文を読めない」という当初の記述は誤り。type 1 / 10 / 11 / 12 / 13 は空 file を書き、
壊れた type 4 fork は Data Error と報告する。生成器は対応 5 type を選択して展開し、cmp 成功後にだけ
manifest の `sevenZipVerified` を true にする。外部生成した新 image でも対応する 5 file の展開と cmp が通過した。

今回も hdiutil を使わず既存 hfs-zlib.dmg の type 7 を `7zz x -ir!compressed.txt` で展開し、
元の `b"compress me please " * 3000` と cmp、既存 manifest と SHA-256 が一致することを確認した。
この実行で生成器の再帰 include 指定と展開先探索も確かめた（実出力）:

```text

7-Zip (z) 26.03 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-09-03
 64-bit arm_v:8.5-A locale=C.UTF-8 Threads:16 OPEN_MAX:1048576, ASM

Scanning the drive for archives:
1 file, 55233 bytes (54 KiB)

Extracting archive: /tmp/kaito-decmpfs-7zz-review-spj6kji0/hfs-zlib.dmg
--
Path = /tmp/kaito-decmpfs-7zz-review-spj6kji0/hfs-zlib.dmg
Type = Dmg
Physical Size = 55233
Method = Zero2 ZLIB CRC
Blocks = 13
Cluster Size = 1048576
Comment = 
{
unpack-size: 8388608
ID: 453f36f7035844dd91e62ed7bf9e27da
master-checksum: CRC: 86CEE445
pack-checksum: CRC: AB130107
pack-offset: 0
pack-length: 46434
xml-offset: 46434
xml-length: 8287
}
----
Path = 4.disk imageÔºàApple_HFS: 4Ôºâ
Size = 8347648
Packed Size = 45896
Comment = disk imageÔºàApple_HFS: 4Ôºâ
Method = Zero2 ZLIB CRC
Blocks = 6
Cluster Size = 1048576
Checksum = 7329E9E8
ID = 4
--
Path = 4.disk imageÔºàApple_HFS: 4Ôºâ
Type = HFS
Physical Size = 8347648
Method = HFS+
Characteristics = LZVN-attr
Cluster Size = 4096
Free Space = 7282688
Created = 2026-09-22 05:07:45
Modified = 2026-09-22 05:07:49

Everything is Ok

Size:       57000
Compressed: 55233
7zz x -ir!compressed.txt / cmp: OK; sha256=1529342ad87ce73c260a1fa429559fc1f2bd861ac8cca998d0264e7bc90a6439
```

### 既存 compressed.txt の type

既存 hfs-zlib / hfs-bzip2 / hfs-lzfse / hfs-lzma の属性はすべて **type 7**。
当初の type 8 のテスト期待値は次の実出力で失敗したため、支給指示の許容どおり 7 に修正した。

```text
XCTAssertEqual failed: ("Optional("7")") is not equal to ("Optional("8")") - compressed.txt
```

4 image すべての 57,000 byte の本文 SHA-256 が既存 manifest と一致した。

### FACT 7 の buffer API の戻り値は破損判定にならない

Apple Compression で `b"LZVN envelope / KaitoKit\n" * 90`（2,250 byte）を encode すると、
LZVN payload は 57 byte、先頭 2 byte は `e0 09` になった。payload をこの 2 byte に切り詰め、
raw size=2250、payload size=2 の envelope を作ると、`compression_decode_buffer` は出力先を一切変えずに
**2250** を返した。戻り値だけを成功条件にした初回テストでは破損 vector が通り、3 assertion が失敗した。

このため stream API の END（status 1）・実出力長・入力消費長を成功条件にした。
stream API では EOS で切った prefix の後に 7 byte の 0 が必要だった。full payload を先に試し、失敗時は
末尾 0 を除去した候補、次に後ろから最大 64 個の 0x06 候補を試す。切った候補にだけ 7 byte の 0 を補う。
同じ decoded buffer を使うので、保持する chunk 数は増えない。以下は ctypes による黒箱追試の実出力。

```text
raw size: 2250 payload size: 57 prefix: e009
full buffer returned: 2250 matches: True changed: 2250
stream init: 0 cap: 2250 status: 1 src remaining: 0 output count: 2250 matches: True changed: 2250
stream init: 0 cap: 2251 status: 1 src remaining: 0 output count: 2250 matches: True changed: 2250
trim zeros buffer returned: 2250 matches: True changed: 2250
stream init: 0 cap: 2250 status: 0 src remaining: 0 output count: 2249 matches: False changed: 2249
stream init: 0 cap: 2251 status: 0 src remaining: 0 output count: 2249 matches: False changed: 2249
trim + 7 zeros buffer returned: 2250 matches: True changed: 2250
stream init: 0 cap: 2250 status: 1 src remaining: 0 output count: 2250 matches: True changed: 2250
stream init: 0 cap: 2251 status: 1 src remaining: 0 output count: 2250 matches: True changed: 2250
first 2 bytes buffer returned: 2250 matches: False changed: 0
stream init: 0 cap: 2250 status: 0 src remaining: 0 output count: 0 matches: False changed: 0
stream init: 0 cap: 2251 status: 0 src remaining: 0 output count: 0 matches: False changed: 0
prefix without EOS buffer returned: 2250 matches: False changed: 2249
stream init: 0 cap: 2250 status: 0 src remaining: 0 output count: 2249 matches: False changed: 2249
stream init: 0 cap: 2251 status: 0 src remaining: 0 output count: 2249 matches: False changed: 2249
with 200 zeros buffer returned: 0 matches: True changed: 2250
stream init: 0 cap: 2250 status: -1 src remaining: 0 output count: 0 matches: False changed: 0
stream init: 0 cap: 2251 status: -1 src remaining: 0 output count: 0 matches: False changed: 0
ff buffer returned: 0 matches: False changed: 0
stream init: 0 cap: 2250 status: -1 src remaining: 0 output count: 0 matches: False changed: 0
stream init: 0 cap: 2251 status: -1 src remaining: 0 output count: 0 matches: False changed: 0
```

再現用の黒箱 probe（実装 source は参照しない）:

```python
import ctypes, struct
lib = ctypes.CDLL('/usr/lib/libcompression.dylib')
args = [ctypes.c_void_p,ctypes.c_size_t,ctypes.c_void_p,ctypes.c_size_t,ctypes.c_void_p,ctypes.c_uint32]
for name in ['compression_encode_buffer','compression_decode_buffer']:
    fn = getattr(lib, name); fn.argtypes=args; fn.restype=ctypes.c_size_t
class Stream(ctypes.Structure):
    _fields_=[('dst_ptr',ctypes.c_void_p),('dst_size',ctypes.c_size_t),('src_ptr',ctypes.c_void_p),('src_size',ctypes.c_size_t),('state',ctypes.c_void_p)]
lib.compression_stream_init.argtypes=[ctypes.POINTER(Stream),ctypes.c_int,ctypes.c_uint32]
lib.compression_stream_init.restype=ctypes.c_int
lib.compression_stream_process.argtypes=[ctypes.POINTER(Stream),ctypes.c_int]
lib.compression_stream_process.restype=ctypes.c_int
lib.compression_stream_destroy.argtypes=[ctypes.POINTER(Stream)]
lib.compression_stream_destroy.restype=ctypes.c_int
raw=b'LZVN envelope / KaitoKit\n'*90
enc=ctypes.create_string_buffer(len(raw)+4096)
n=lib.compression_encode_buffer(enc,len(enc),ctypes.create_string_buffer(raw),len(raw),None,0x801)
encoded=enc.raw[:n]; payload=encoded[12:-4]
print('raw size:',len(raw),'payload size:',len(payload),'prefix:',payload[:2].hex())
for label,p in [('full',payload),('trim zeros',payload.rstrip(bytes([0]))),('trim + 7 zeros',payload.rstrip(bytes([0]))+bytes(7)),('first 2 bytes',payload[:2]),('prefix without EOS',payload[:-8]),('with 200 zeros',payload+bytes(200)),('ff',b'\xff'*20)]:
    wrapped=b'bvxn'+struct.pack('<II',len(raw),len(p))+p+b'bvx$'
    src=ctypes.create_string_buffer(wrapped)
    dst=ctypes.create_string_buffer(b'\xa5'*len(raw), len(raw))
    result=lib.compression_decode_buffer(dst,len(raw),src,len(wrapped),None,0x801)
    print(label, 'buffer returned:',result,'matches:',dst.raw==raw,'changed:',sum(b!=0xa5 for b in dst.raw))
    for capacity in [len(raw),len(raw)+1]:
        dst=ctypes.create_string_buffer(b'\xa5'*capacity,capacity)
        s=Stream(); init=lib.compression_stream_init(ctypes.byref(s),1,0x801)
        s.src_ptr=ctypes.addressof(src);s.src_size=len(wrapped)
        s.dst_ptr=ctypes.addressof(dst);s.dst_size=capacity
        status=lib.compression_stream_process(ctypes.byref(s),1)
        print('stream init:',init,'cap:',capacity,'status:',status,'src remaining:',s.src_size,'output count:',capacity-s.dst_size,'matches:',dst.raw[:len(raw)]==raw,'changed:',sum(b!=0xa5 for b in dst.raw))
        lib.compression_stream_destroy(ctypes.byref(s))
```

## build とテストの実出力

### fixture 到着前の sandbox 内の検証

素の `swift build` は既定の module cache への書き込みで失敗した:

```text
<unknown>:0: error: error opening '<home>/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: <home>/.cache/clang/ModuleCache: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macosx14.0'
```

以降は cache を worktree 内に置き、SwiftPM の子 sandbox を無効にして外側の sandbox 内で実行した。

```sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/clang-module-cache"
swift build --disable-sandbox --cache-path "$PWD/.build/swiftpm-cache"
swift test --disable-sandbox --cache-path "$PWD/.build/swiftpm-cache" --filter DMG --skip DMGDecmpfsTests.testFixture
swift test --disable-sandbox --cache-path "$PWD/.build/swiftpm-cache" --filter ReleaseReviewDocumentationTests
```

レビュー修正後、fixture 到着前の build（exit 0、compiler error / warning 無し。先頭 2 行は sandbox のユーザー cache 警告）:

```text
warning: <home>/Library/org.swift.swiftpm/configuration is not accessible or not writable, disabling user-level cache features.
warning: <home>/Library/org.swift.swiftpm/security is not accessible or not writable, disabling user-level cache features.
Building for debugging...
[2 / 14] KaitoKit
[5 / 17] KaitoKit
[14 / 16] KaitoKitDynamic-product
Build complete! (2.08秒)
```

この時点で上の 3 コマンドを再実行した。DMG は KaitoKitTests 15 件 + compat 1 件 = **16 件、失敗 0**、
ReleaseReviewDocumentationTests は **4 件、失敗 0**、合計 **20 件、失敗 0**。
新 image に依存する `testFixtureContentsAndStreams` / `testFixtureEntrySizeLimitAtOpen` の 2 件は
`--skip DMGDecmpfsTests.testFixture` で選択から除いた。fixture が無いことを成功扱いする XCTSkip は入れていない。
レビューで追加した type 9 の必須 marker / 空 / 長さ違いと、非零 startBlock / 0x30 属性も通過した。

DMG の build 後の実出力:

```text
Test Suite 'Selected tests' started at 2026-09-22 19:19:33.002.
Test Suite 'KaitoKitTests.xctest' started at 2026-09-22 19:19:33.003.
Test Suite 'CLISmokeTests' started at 2026-09-22 19:19:33.003.
Test Case '-[KaitoKitTests.CLISmokeTests testDetectAndListDMG]' started.
Test Case '-[KaitoKitTests.CLISmokeTests testDetectAndListDMG]' passed (0.572 seconds).
Test Suite 'CLISmokeTests' passed at 2026-09-22 19:19:33.575.
	 Executed 1 test, with 0 failures (0 unexpected) in 0.572 (0.572) seconds
Test Suite 'DMGDecmpfsTests' started at 2026-09-22 19:19:33.575.
Test Case '-[KaitoKitTests.DMGDecmpfsTests testChunksAreReadOnDemandAndAllocationsAreBounded]' started.
Test Case '-[KaitoKitTests.DMGDecmpfsTests testChunksAreReadOnDemandAndAllocationsAreBounded]' passed (0.002 seconds).
Test Case '-[KaitoKitTests.DMGDecmpfsTests testInlineStoredAndRawMarkers]' started.
Test Case '-[KaitoKitTests.DMGDecmpfsTests testInlineStoredAndRawMarkers]' passed (0.000 seconds).
Test Case '-[KaitoKitTests.DMGDecmpfsTests testInlineType9RequiresStoredMarker]' started.
Test Case '-[KaitoKitTests.DMGDecmpfsTests testInlineType9RequiresStoredMarker]' passed (0.000 seconds).
Test Case '-[KaitoKitTests.DMGDecmpfsTests testInlineZlibWithAndWithoutAdlerRequiresFinalBlock]' started.
Test Case '-[KaitoKitTests.DMGDecmpfsTests testInlineZlibWithAndWithoutAdlerRequiresFinalBlock]' passed (0.000 seconds).
Test Case '-[KaitoKitTests.DMGDecmpfsTests testLZFSEInlineAndResourceChunks]' started.
Test Case '-[KaitoKitTests.DMGDecmpfsTests testLZFSEInlineAndResourceChunks]' passed (0.004 seconds).
Test Case '-[KaitoKitTests.DMGDecmpfsTests testLZVNPaddingAndCorruption]' started.
Test Case '-[KaitoKitTests.DMGDecmpfsTests testLZVNPaddingAndCorruption]' passed (0.001 seconds).
Test Case '-[KaitoKitTests.DMGDecmpfsTests testMalformedResourceTables]' started.
Test Case '-[KaitoKitTests.DMGDecmpfsTests testMalformedResourceTables]' passed (0.000 seconds).
Test Case '-[KaitoKitTests.DMGDecmpfsTests testZlibResourceMixedChunksAndEnvelopeOffset]' started.
Test Case '-[KaitoKitTests.DMGDecmpfsTests testZlibResourceMixedChunksAndEnvelopeOffset]' passed (0.017 seconds).
Test Suite 'DMGDecmpfsTests' passed at 2026-09-22 19:19:33.599.
	 Executed 8 tests, with 0 failures (0 unexpected) in 0.024 (0.025) seconds
Test Suite 'DMGReaderTests' started at 2026-09-22 19:19:33.600.
Test Case '-[KaitoKitTests.DMGReaderTests testCompressedImagesListTheHFSVolumeLikeTheMountedDisk]' started.
Test Case '-[KaitoKitTests.DMGReaderTests testCompressedImagesListTheHFSVolumeLikeTheMountedDisk]' passed (0.087 seconds).
Test Case '-[KaitoKitTests.DMGReaderTests testDamagedImagesAreRejected]' started.
Test Case '-[KaitoKitTests.DMGReaderTests testDamagedImagesAreRejected]' passed (0.035 seconds).
Test Case '-[KaitoKitTests.DMGReaderTests testDecmpfsAttributeErrorsAndHardLinkTarget]' started.
Test Case '-[KaitoKitTests.DMGReaderTests testDecmpfsAttributeErrorsAndHardLinkTarget]' passed (0.915 seconds).
Test Case '-[KaitoKitTests.DMGReaderTests testR5SectorByteOverflowIsRejected]' started.
Test Case '-[KaitoKitTests.DMGReaderTests testR5SectorByteOverflowIsRejected]' passed (0.000 seconds).
Test Case '-[KaitoKitTests.DMGReaderTests testR9CompressedChunkMustReachValidatedEnd]' started.
Test Case '-[KaitoKitTests.DMGReaderTests testR9CompressedChunkMustReachValidatedEnd]' passed (0.011 seconds).
Test Case '-[KaitoKitTests.DMGReaderTests testRawImageISOInsideUDIFAndUnsupportedVolumes]' started.
Test Case '-[KaitoKitTests.DMGReaderTests testRawImageISOInsideUDIFAndUnsupportedVolumes]' passed (0.029 seconds).
Test Suite 'DMGReaderTests' passed at 2026-09-22 19:19:34.677.
	 Executed 6 tests, with 0 failures (0 unexpected) in 1.077 (1.077) seconds
Test Suite 'KaitoKitTests.xctest' passed at 2026-09-22 19:19:34.677.
	 Executed 15 tests, with 0 failures (0 unexpected) in 1.673 (1.674) seconds
Test Suite 'Selected tests' passed at 2026-09-22 19:19:34.677.
	 Executed 15 tests, with 0 failures (0 unexpected) in 1.673 (1.675) seconds
Test Suite 'Selected tests' started at 2026-09-22 19:19:34.742.
Test Suite 'KaitoKitCompatTests.xctest' started at 2026-09-22 19:19:34.742.
Test Suite 'KaitoArchiveDMGTests' started at 2026-09-22 19:19:34.742.
Test Case '-[KaitoKitCompatTests.KaitoArchiveDMGTests testDiskImageNamesItsFormatAndReadsTheHFSVolume]' started.
Test Case '-[KaitoKitCompatTests.KaitoArchiveDMGTests testDiskImageNamesItsFormatAndReadsTheHFSVolume]' passed (0.010 seconds).
Test Suite 'KaitoArchiveDMGTests' passed at 2026-09-22 19:19:34.752.
	 Executed 1 test, with 0 failures (0 unexpected) in 0.010 (0.010) seconds
Test Suite 'KaitoKitCompatTests.xctest' passed at 2026-09-22 19:19:34.752.
	 Executed 1 test, with 0 failures (0 unexpected) in 0.010 (0.010) seconds
Test Suite 'Selected tests' passed at 2026-09-22 19:19:34.752.
	 Executed 1 test, with 0 failures (0 unexpected) in 0.010 (0.010) seconds
```

文書テストの実出力:

```text
Test Suite 'ReleaseReviewDocumentationTests' started at 2026-09-22 19:21:47.690.
Test Case '-[KaitoKitTests.ReleaseReviewDocumentationTests testFollowupReviewDocumentsSFXAuxiliaryAndTAZChanges]' started.
Test Case '-[KaitoKitTests.ReleaseReviewDocumentationTests testFollowupReviewDocumentsSFXAuxiliaryAndTAZChanges]' passed (0.006 seconds).
Test Case '-[KaitoKitTests.ReleaseReviewDocumentationTests testReadmeIntroductionsAndIntegrationNotesDocumentFormatsAndSafetyLimits]' started.
Test Case '-[KaitoKitTests.ReleaseReviewDocumentationTests testReadmeIntroductionsAndIntegrationNotesDocumentFormatsAndSafetyLimits]' passed (0.003 seconds).
Test Case '-[KaitoKitTests.ReleaseReviewDocumentationTests testRelease081DocumentsAllFourteenReviewFixes]' started.
Test Case '-[KaitoKitTests.ReleaseReviewDocumentationTests testRelease081DocumentsAllFourteenReviewFixes]' passed (0.006 seconds).
Test Case '-[KaitoKitTests.ReleaseReviewDocumentationTests testReleaseReviewRecordExistsAndIsLinkedFromChangelog]' started.
Test Case '-[KaitoKitTests.ReleaseReviewDocumentationTests testReleaseReviewRecordExistsAndIsLinkedFromChangelog]' passed (0.002 seconds).
Test Suite 'ReleaseReviewDocumentationTests' passed at 2026-09-22 19:21:47.706.
	 Executed 4 tests, with 0 failures (0 unexpected) in 0.016 (0.016) seconds
```

### 新 fixture を含む sandbox 外の検証

orchestrator が image を置いてから次を実行した。build は成功し、fixture の 2 件を除外せず、
KaitoKitTests 50 件と KaitoKitCompatTests 1 件の計 **51 件、失敗 0**。提供された実出力:

```sh
swift build
swift test --filter 'DMG|ReleaseReviewDocumentationTests|CLISmokeTests'
```

```text
Executed 30 tests, with 0 failures (0 unexpected) in 26.729 (26.733) seconds   (DMG suites)
Executed 10 tests, with 0 failures (0 unexpected) in 0.062 (0.062) seconds
Executed 6 tests, with 0 failures (0 unexpected) in 1.089 (1.089) seconds
Executed 4 tests, with 0 failures (0 unexpected) in 0.016 (0.016) seconds     (ReleaseReviewDocumentationTests)
Executed 50 tests, with 0 failures (0 unexpected) in 27.895 (27.900) seconds  (KaitoKitTests total for the filter)
Executed 1 test, with 0 failures (0 unexpected) in 0.010 (0.010) seconds      (KaitoKitCompatTests)
```

### 最終文書更新後の sandbox 内の確認

外部結果を反映した文書で次を実行し、exit 0。**4 件、失敗 0**。
前述の cache 設定を使い、先頭の SwiftPM ユーザー cache 警告 2 行は同じ。build 以降の実出力:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/clang-module-cache" \
swift test --disable-sandbox --cache-path "$PWD/.build/swiftpm-cache" --filter ReleaseReviewDocumentationTests
```

```text
Build complete! (2.57秒)
Test Suite 'Selected tests' started at 2026-09-22 19:37:32.299.
Test Suite 'KaitoKitTests.xctest' started at 2026-09-22 19:37:32.299.
Test Suite 'ReleaseReviewDocumentationTests' started at 2026-09-22 19:37:32.299.
Test Case '-[KaitoKitTests.ReleaseReviewDocumentationTests testFollowupReviewDocumentsSFXAuxiliaryAndTAZChanges]' started.
Test Case '-[KaitoKitTests.ReleaseReviewDocumentationTests testFollowupReviewDocumentsSFXAuxiliaryAndTAZChanges]' passed (0.006 seconds).
Test Case '-[KaitoKitTests.ReleaseReviewDocumentationTests testReadmeIntroductionsAndIntegrationNotesDocumentFormatsAndSafetyLimits]' started.
Test Case '-[KaitoKitTests.ReleaseReviewDocumentationTests testReadmeIntroductionsAndIntegrationNotesDocumentFormatsAndSafetyLimits]' passed (0.003 seconds).
Test Case '-[KaitoKitTests.ReleaseReviewDocumentationTests testRelease081DocumentsAllFourteenReviewFixes]' started.
Test Case '-[KaitoKitTests.ReleaseReviewDocumentationTests testRelease081DocumentsAllFourteenReviewFixes]' passed (0.006 seconds).
Test Case '-[KaitoKitTests.ReleaseReviewDocumentationTests testReleaseReviewRecordExistsAndIsLinkedFromChangelog]' started.
Test Case '-[KaitoKitTests.ReleaseReviewDocumentationTests testReleaseReviewRecordExistsAndIsLinkedFromChangelog]' passed (0.002 seconds).
Test Suite 'ReleaseReviewDocumentationTests' passed at 2026-09-22 19:37:32.316.
	 Executed 4 tests, with 0 failures (0 unexpected) in 0.016 (0.017) seconds
Test Suite 'KaitoKitTests.xctest' passed at 2026-09-22 19:37:32.316.
	 Executed 4 tests, with 0 failures (0 unexpected) in 0.016 (0.017) seconds
Test Suite 'Selected tests' passed at 2026-09-22 19:37:32.316.
	 Executed 4 tests, with 0 failures (0 unexpected) in 0.016 (0.017) seconds
Test Suite 'Selected tests' started at 2026-09-22 19:37:32.376.
Test Suite 'KaitoKitCompatTests.xctest' started at 2026-09-22 19:37:32.376.
Test Suite 'KaitoKitCompatTests.xctest' passed at 2026-09-22 19:37:32.376.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds
Test Suite 'Selected tests' passed at 2026-09-22 19:37:32.376.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
```

## CLI の実出力（既存 hfs-zlib.dmg）

```sh
python3 -c "import base64,gzip,pathlib;pathlib.Path('/tmp/hfs-zlib.dmg').write_bytes(gzip.decompress(base64.b64decode(pathlib.Path('Tests/Fixtures/dmg/hfs-zlib.dmg.gz.b64').read_bytes())))"
.build/debug/kaito list /tmp/hfs-zlib.dmg
```

exit 0:

```text
0	57000	file	HFS+ decmpfs (LZVN)	plain	compressed.txt
1	20000	file	HFS+ (stored)	plain	data.bin
2	0	file	HFS+ (stored)	plain	empty.txt
3	200000	file	HFS+ (stored)	plain	fragmented.bin
4	10	file	HFS+ (stored)	plain	hardlink-to-readme
5	20	file	HFS+ (stored)	plain	hardlink-to-readme/..namedfork/rsrc	fork=resource
6	14	symlink	HFS+ (stored)	plain	link-to-nested
7	10	file	HFS+ (stored)	plain	readme.txt
8	20	file	HFS+ (stored)	plain	readme.txt/..namedfork/rsrc	fork=resource
9	18	file	HFS+ (stored)	plain	script.sh
10	0	directory	HFS+ (stored)	plain	sub
11	0	directory	HFS+ (stored)	plain	sub/deeper
12	5	file	HFS+ (stored)	plain	sub/deeper/deep.txt
13	7	file	HFS+ (stored)	plain	sub/nested.txt
14	19	file	HFS+ (stored)	plain	日本語.txt
```

```sh
.build/debug/kaito sha /tmp/hfs-zlib.dmg
```

exit 0。compressed.txt の `1529342a…0a6439` は manifest.json の値と一致。
manifest に size / sha256 のある 12 payload すべてを CLI 出力と照合した（symlink の本文は Swift テストで確認）:

```text
0	57000	1529342ad87ce73c260a1fa429559fc1f2bd861ac8cca998d0264e7bc90a6439	compressed.txt
1	20000	a06327736240383e10a0974abfd86f3a904851c4bb2d116adf94992e69915cff	data.bin
2	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	empty.txt
3	200000	725af8c8618d9f5e15e02987d54bb41840ee1793c0ea46c3e26c75cc402d841b	fragmented.bin
4	10	c6ced9f772ab08b591a1d3a1057bf4fd267ab64b1536d170f61722afb16677de	hardlink-to-readme
5	20	0cb150c72bf19f6d78a3e5bf2acf321133804de0c7c6bc520b225a826be1d965	hardlink-to-readme/..namedfork/rsrc
6	14	cfc0bc158d2749344c871b8d1af0e039284a5e7876075aa7ad9ed3b61874f62a	link-to-nested
7	10	c6ced9f772ab08b591a1d3a1057bf4fd267ab64b1536d170f61722afb16677de	readme.txt
8	20	0cb150c72bf19f6d78a3e5bf2acf321133804de0c7c6bc520b225a826be1d965	readme.txt/..namedfork/rsrc
9	18	299001868fb8c02fd431c336c6d058f5558c5dff5b5af5e6fe04b870a6a9cbba	script.sh
10	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	sub
11	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	sub/deeper
12	5	64896f89fd11190013b70103e603a1c5826e56b7fb7d2197ab279b0690043599	sub/deeper/deep.txt
13	7	370a8c04b8a65bb4494275eec227f1b694db04c76da6b0b8ae88ed1ab19790a3	sub/nested.txt
14	19	1f06c4462778e16d84ec28f021875dbff3352d5c7d2534c0039d39ef8a3e559b	日本語.txt
total	15	0832395170e500da397bc0d689d33709be1a717fa8bada1a8ab3adf229baf26b	
```

## CLI の実出力（新 hfs-decmpfs.dmg）

以下は orchestrator が sandbox 外で実行した結果。

```sh
.build/debug/kaito list /tmp/hfs-decmpfs.dmg
```

```text
0	20000	file	HFS+ decmpfs (LZVN)	plain	ditto7.txt
1	300000	file	HFS+ decmpfs (LZVN)	plain	ditto8.txt
2	0	file	HFS+ decmpfs (stored)	plain	empty-compressed
3	0	file	HFS+ decmpfs (stored)	plain	empty1.bin
4	840	file	HFS+ decmpfs (stored)	plain	inline1.bin
5	840	file	HFS+ decmpfs (LZFSE)	plain	inline11.bin
6	840	file	HFS+ decmpfs (zlib)	plain	inline3.bin
7	840	file	HFS+ decmpfs (stored)	plain	inline9.bin
8	300000	file	HFS+ decmpfs (LZFSE)	plain	lzfse12.bin
9	300000	file	HFS+ decmpfs (stored)	plain	raw10.bin
10	840	file	HFS+ decmpfs (type 13)	plain	type13.bin
11	840	file	HFS+ decmpfs (type 5)	plain	type5.bin
12	300000	file	HFS+ decmpfs (zlib)	plain	zlib4.bin
```

```sh
.build/debug/kaito sha /tmp/hfs-decmpfs.dmg
```

```text
0	20000	e7489893748b27f305799d031e7ad74fd7317cddb70ee790bb0e5333771fcfc9	ditto7.txt
1	300000	2e9d82a07c6bb40515db2a93759cd4a32b075ca2aa3dd8a8bab3a221d7ddae2a	ditto8.txt
2	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	empty-compressed
3	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	empty1.bin
4	840	5e6e6782c244ac9fa61c1b3b7ab254a66ce2da51ef888ecf1792110bea40a5da	inline1.bin
5	840	5e6e6782c244ac9fa61c1b3b7ab254a66ce2da51ef888ecf1792110bea40a5da	inline11.bin
6	840	5e6e6782c244ac9fa61c1b3b7ab254a66ce2da51ef888ecf1792110bea40a5da	inline3.bin
7	840	5e6e6782c244ac9fa61c1b3b7ab254a66ce2da51ef888ecf1792110bea40a5da	inline9.bin
8	300000	2e9d82a07c6bb40515db2a93759cd4a32b075ca2aa3dd8a8bab3a221d7ddae2a	lzfse12.bin
9	300000	2e9d82a07c6bb40515db2a93759cd4a32b075ca2aa3dd8a8bab3a221d7ddae2a	raw10.bin
10	ERROR	failed entry 10: Unsupported archive method: HFS+ decmpfs (type 13)	type13.bin
11	ERROR	failed entry 11: Unsupported archive method: HFS+ decmpfs (type 5)	type5.bin
12	300000	2e9d82a07c6bb40515db2a93759cd4a32b075ca2aa3dd8a8bab3a221d7ddae2a	zlib4.bin
partial	11	4cefcff38df5cd96486f880ea090d9f56be1626709c59af3d93ea84b3633a76d
```

読める 11 payload の SHA-256 はすべて `manifest-decmpfs.json` と一致した。
type5.bin / type13.bin は header size 840 で一覧し、本文は予定どおり `Unsupported archive method`。

## Apple の実物と ditto の照合（sandbox 外）

orchestrator が `hdiutil create -size 20m -fs HFS+` で作った rw image を使い、KaitoKit からは raw HFS+ image として読んだ。
Apple が書いた decmpfs 属性 / resource fork の組をそのまま
`setxattr(XATTR_SHOWCOMPRESSION)` + `chflags(UF_COMPRESSED)` で移し、ditto の出力も加えた。
以下は `kaito sha` と原本の `shasum -a 256` が一致した、提供された照合値。

| type | 原本 | byte / chunk | 一致した SHA-256 |
| --- | --- | --- | --- |
| 4 | `/Applications/MainStage Creator Studio.app/Contents/Info.plist` | 20,111 / 1 | `38bbc0b8647b06200d70ddffccf44b8431116eab99fafb6b8fc4d0a8e2583b8e` |
| 4 | `/Applications/Xcode.app/Contents/_CodeSignature/CodeResources` | 32,692,064 / 499 | `eb5d1041e8b47cba1ad458c5338796052a941b764e829fb0195b04cc80926d8a` |
| 8 | `/usr/share/man/man1/ls.1` | 23,359 / 1 | `831758775fe2fdaa3d5acf913dfd5024a608fd3538281e0d1cab857ce66faa95` |
| 8 | `/usr/share/dict/web2` | 2,493,885 / 39 | `be41ad97963bf8dabedd5871d5d691596175269d540956b0f9965a885c2bbab9` |
| 8 | `/usr/bin/zip` | 617,856 / 10 | `ee6dc1e0b766023a1720792ba15c6de0fb3f5f785bf4354044a6d289dc68d711` |

type 4 は Apple の Adler-32 無しの zlib。type 8 は EOS 後の 195 / 16,952 byte の 0 padding を含み、
`/usr/bin/zip` には `0x06` + raw の chunk も 1 個あった。
ditto が書いた 2,493,093 byte の text（type 8、39 chunk）と 19,800 byte の text（type 7）も一致した。

同じ image 上の負例も想定したエラーになった（orchestrator の報告）:

| 負例 | 結果 |
| --- | --- |
| type 4 の誤った resource map | `malformed("hfs+ decmpfs resource envelope")` |
| type 9 の `0xCC` 欠落 | `malformed("hfs+ decmpfs stored inline marker or size")` |
| type 1 に `0xCC` を追加 | `malformed("hfs+ decmpfs inline size")` |
| type 5 | `unsupportedMethod("HFS+ decmpfs (type 5)")`。HFS+ driver 自体も EAGAIN |

`ditto --hfsCompression /usr/share/dict` で mount 先へ直接コピーする操作は、source の SIP `restricted` flag により
`Operation not permitted` で失敗した。このため上記の実物照合は属性 / resource fork の組を移す手順で完了した。
当初予定した dict の直接コピーと UDZO 変換の結果とは区別する。

## 変更ファイル（git 不使用の作業記録）

- `Sources/KaitoKit/Formats/DMG/HFSPlusVolume.swift`: attributes B-tree、fork の先頭 extent 判定。
- `Sources/KaitoKit/Formats/DMG/DMGReader.swift`: header / 実サイズ / method / target CNID と stream の接続。
- `Sources/KaitoKit/Formats/DMG/DecmpfsDecompressor.swift`（新規）: header、chunk 表、stored / zlib / LZVN / LZFSE。
- `Tests/KaitoKitTests/DMGReaderTests.swift`: 既存 compressed.txt の hash、属性エラーと hard link。
- `Tests/KaitoKitTests/DMGDecmpfsTests.swift`（新規）: 新 fixture の 2 テストと独立 vector の 8 テスト。
- `Tests/KaitoKitTests/CLISmokeTests.swift`: decmpfs の実サイズ・method・sha の期待値。
- `Tests/Fixtures/dmg/generate-decmpfs.sh`（新規）: generator、mount / cmp / 7zz の一覧・対応 type の展開照合。
- `Tests/Fixtures/dmg/generate.sh`: 7-Zip の decmpfs 対応範囲のコメントを訂正（既存 image は再生成しない）。
- `Tests/Fixtures/dmg/README.md`: 新 image / manifest と生成・検証方法。
- `Tests/Fixtures/NOTICE`: 自作 payload と出自。
- `README.md`: 日英の対応範囲。
- `CHANGELOG.md`: Unreleased の項目。
- `Documentation/design.md`: 出自・番号付き黒箱観察・FACT 7 の反例。
- `Documentation/verification/2026-09-22-hfsplus-decmpfs.md`（新規）: 本記録。
- `Documentation/verification/README.md`: 索引の先頭行。

orchestrator が生成した `Tests/Fixtures/dmg/hfs-decmpfs.dmg.gz.b64` と
`Tests/Fixtures/dmg/manifest-decmpfs.json` も収録した。既存 dmg image と manifest.json は未変更。

fixture 到着前のレビュー指示後に変更した file は上記のうち DecmpfsDecompressor.swift / HFSPlusVolume.swift /
DMGDecmpfsTests.swift / DMGReaderTests.swift / generate-decmpfs.sh / generate.sh /
Tests/Fixtures/dmg/README.md / Tests/Fixtures/NOTICE / README.md / Documentation/design.md / 本記録の 11 本。
このレビュー修正では hdiutil の再実行、既存 fixture の再生成、commit は行っていない。

最終の外部結果の反映で変更したのは本記録、Documentation/verification/README.md、
Tests/Fixtures/dmg/README.md、Tests/Fixtures/NOTICE、CHANGELOG.md、README.md、Documentation/design.md の 7 本。
この文書更新では image / manifest / 生成器を変更せず、hdiutil と commit は実行していない。
