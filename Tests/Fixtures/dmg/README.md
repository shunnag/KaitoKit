# Apple Disk Image fixtures

Disk images written by macOS tools (`hdiutil create` / `convert` / `makehybrid`, the HFS+ driver and
`ditto --hfsCompression`, all black-box writers) around a project-owned payload, by `generate.sh`.
`manifest.json` records every payload file's size and SHA-256 (symlink targets, the resource fork, the
hard-link pair and the decmpfs file are marked) and each image's size and SHA-256.

| Image | Format | Contents |
| --- | --- | --- |
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

Every HFS+ image is mounted read-only with `hdiutil attach` and compared file by file with the payload;
the compressed variants are also extracted with 7-Zip (which shows hard links as empty files, cannot read
decmpfs data and writes resource forks as xattrs, so those members are checked through the mount only).
No third-party UDIF or HFS+ implementation source was consulted (Documentation/verification/2026-09-22-dmg.md).

```sh
bash Tests/Fixtures/dmg/generate.sh   # macOS only: hdiutil, ditto, 7zz
swift test --filter DMGReaderTests
```
