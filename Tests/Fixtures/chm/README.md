# CHM (HTML Help, ITSF) fixtures

Compiled-help files written by `generate.py`'s own ITSF writer, with the compressed section produced by the
project's CAB LZX encoder (`Scripts/fixtures/make-cab-lzx.py`, written from [MS-PATCH]). The container layout
follows Matthew Russotto's "Microsoft's HTML Help (.chm) format" and the Wise / Wing "Unofficial CHM
Specification" (both in `inbox/chm/`, see Documentation/verification/2026-09-21-chm.md). `manifest.json`
records every payload file's size and SHA-256 and each archive's size, SHA-256 and file list.

| Archive | Coverage |
| --- | --- |
| `basic.chm` | version 3, LZX window 64 KiB, reset every 2 blocks (the settings hh.exe uses), 9 user files (Japanese names, three directory levels, an empty file, a 70 KB file spanning block and reset boundaries) plus `#SYSTEM` / `#ITBITS` in the uncompressed section |
| `reset1-w17.chm` | window 128 KiB, LZX state reset at every 0x8000 block |
| `mixed-blocks.chm` | each reset interval starts with an uncompressed LZX block followed by an aligned-offset block |
| `e8.chm` | E8 translation on (header bit 1, translation size 0x12345678) over a payload full of E8 opcodes; positions restart at every reset interval |
| `multi-chunk.chm` | 300 files: several PMGL listing chunks and a PMGI index chunk |
| `uncompressed.chm` | no `MSCompressed` section; everything stored in section 0 |

Every archive is extracted with 7-Zip (`7zz x`) and compared file by file with the payload before it is
stored; no CHM compiler is installed here and 7-Zip cannot write CHM. A version 2 header written as Russotto
describes it is refused by 7-Zip ("Is not archive"), so no version 2 fixture exists. No third-party CHM
implementation source was consulted.

```sh
python3 Tests/Fixtures/chm/generate.py   # needs 7zz on PATH
swift test --filter CHMReaderTests
```
