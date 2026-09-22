# Apple Disk Image fixtures

Disk images written by macOS tools (`hdiutil create` / `convert` / `makehybrid`, the HFS+ driver and
`ditto --hfsCompression`, all black-box writers) around a project-owned payload, by `generate.sh`.
`manifest.json` records every payload file's size and SHA-256 (symlink targets, the resource fork, the
hard-link pair and the decmpfs file are marked) and each image's size and SHA-256.

| Image | Format | Contents |
| --- | --- | --- |
| [`hfs-decmpfs.dmg`](hfs-decmpfs.dmg.gz.b64) | UDZO、GPTSPUD、HFS+ | decmpfs 1 / 3 / 4 / 7 / 8 / 9 / 10 / 11 / 12 の本文 11 本、一覧のみ 5 / 13。size / SHA-256 / type / 7zz 照合は [`manifest-decmpfs.json`](manifest-decmpfs.json) |
| `hfs-zlib.dmg` | UDZO (zlib chunks) | the HFS+ volume: nested directories, an empty file, a 755 script, a symbolic link, a hard-link pair with a resource fork, a decomposed Japanese name, a 200 KB file in 49 extents (extents overflow B-tree), a decmpfs-compressed file |
| `hfs-bzip2.dmg` | UDBZ (bzip2 chunks) | the same volume |
| `hfs-lzfse.dmg` | ULFO (lzfse chunks) | the same volume |
| `hfs-lzma.dmg` | ULMO (lzma chunks in xz containers) | the same volume |
| `hfs-adc.dmg` | UDCO (ADC chunks) | the same volume; KaitoKit refuses ADC with `unsupportedMethod` |
| `hfs-raw.dmg` | UDRO (raw and zero-fill chunks) | a two-file folder |
| `hfs-apm-zlib.dmg` | UDZO, Apple Partition Map (`-layout SPUD`) | the two-file folder |
| `hfs-bare-zlib.dmg` | UDZO, no partition map (`-layout NONE`) | the two-file folder |
| `iso-zlib.dmg` | UDZO around an ISO 9660 / Joliet image | the two-file folder, listed through the ISO reader |
| `apfs-zlib.dmg` | UDZO around an APFS volume | refused with `unsupportedMethod` |

各 HFS+ image は read-only mount して原本と比較し、圧縮 image は 7-Zip でも展開する。
hard link は空 file、resource fork は xattr になるため mount を真値にする。旧 `generate.sh` は decmpfs も
mount だけで照合したが、7-Zip 26.03 は type 3 / 4 / 7 / 8 / 9 の本文を byte 一致で展開できる。
No third-party UDIF or HFS+ implementation source was consulted (Documentation/verification/2026-09-22-dmg.md).

```sh
bash Tests/Fixtures/dmg/generate.sh   # macOS only: hdiutil, ditto, 7zz
swift test --filter DMGReaderTests
```

## decmpfs

`generate-decmpfs.sh` は `-type UDIF -layout GPTSPUD` の 12 MB HFS+ rw image に決定的な自作 text を置く。
20,000 / 300,000 byte は `ditto --hfsCompression` で type 7 / 8 にし、raw xattr で type と 5 chunk を確認する。
提供された黒箱計測では圧縮可能な入力でも 16,384 byte 以下は非圧縮、16,385–65,536 byte は type 7。
残りは Python ctypes の `setxattr(XATTR_SHOWCOMPRESSION)` / `chflags(UF_COMPRESSED)` で属性と resource fork を書く。
type 1 は raw、type 9 は必須の `0xCC` + raw。type 3 は zlib（`0xFF` + raw も対応）。
type 4 は Adler-32 付き / 無しの zlib と raw chunk を混ぜる。type 11 / 12 は Apple Compression の LZFSE 出力。
空の type 1（`empty1.bin` / `empty-compressed`）も driver が受理し、両方を収録した。

type 5 / 13 以外は mount 上の file を原本と `cmp` し、detach 後に UDZO へ変換する。
`7zz l` で全 file 名を確認し、`7zz x` で type 3 / 4 / 7 / 8 / 9 を展開して原本と `cmp` する。
展開失敗・欠落・不一致なら生成を失敗にする。7-Zip 26.03 は type 1 / 10 / 11 / 12 / 13 を空 file にするため、
これらは 7zz 照合の対象にしない。壊れた type 4 は Data Error になる（提供された黒箱観察、裁定 4）。
`manifest-decmpfs.json` に payload の size / SHA-256 / decmpfsType / `sevenZipVerified` と image の size / SHA-256 を記録し、
`sevenZipVerified` は実際に 7zz 展開と cmp が成功した file だけ true にする。
image を gzip + base64（200 KB 未満）で保存する。既存 image と `manifest.json` は再生成しない。

```sh
bash Tests/Fixtures/dmg/generate-decmpfs.sh
swift test --filter DMG
```

orchestrator が sandbox 外で生成・照合を完了した。image は 24,476 byte、gzip + base64 は 7,320 byte。
image の SHA-256 は `c147ff1649660f2b244510c490204496fe46bcfa3de5ddea8b78e3c45744a867`。
読める 11 file は mount 上の `cmp` と KaitoKit の SHA-256 が一致し、うち 5 file は `7zz x` / `cmp` も一致した。
新 image を含む DMG / 文書 / CLI テストは除外無しで失敗 0。
[出自・実行記録](../../../Documentation/verification/2026-09-22-hfsplus-decmpfs.md)。
