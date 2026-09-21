# 7z Zstandard coder fixtures

Project-owned byte sequences (the same `first.bin` / `second.bin` / `empty` set as
`sevenzip-swap`) written as 7z archives whose single solid folder uses the
Zstandard coder, method ID `04 F7 11 01`. The ID comes from the official
[Methods.txt](https://github.com/ip7z/7zip/blob/main/DOC/Methods.txt) (`04 F7 11 xx`
is reserved for Tino Reichardt's external codecs, `01` is ZSTD). The packed stream
is a plain RFC 8878 frame sequence; the writer stores a 5-byte properties blob
(`01 05 <level> 00 00`: zstd version 1.5, the compression level — `01` and `13` in the
two fixtures — and two reserved bytes) that the decoder does not use.

The writer is Homebrew libarchive's `bsdtar` 3.8.9
(`--format 7zip --options 7zip:compression=zstd,7zip:compression-level=N`), the
same coder layout that 7-Zip ZS / NanaZip produce. Mainline 7-Zip 26.03 lists the
archives but cannot decode the coder, so `generate.py` verifies the fixtures two
ways: the packed stream carved from offset 32 (its size taken from `7zz l -slt`)
is decoded by the `zstd` 1.5.7 CLI and compared with the concatenated members, and
every entry is extracted with `bsdtar -xOf`. `manifest.json` records the SHA-256 of
the archives and the original entries, the writer version and the arguments.
Regeneration keeps the entry hashes; archive hashes may change with timestamps.

```sh
python3 Tests/Fixtures/sevenzip-zstd/generate.py
swift test --filter SevenZipZstdTests
```
