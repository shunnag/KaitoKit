# ZIP XZ / legacy Zstandard fixtures

These are small, synthetic, redistributable test archives. Their UTF-8 payload is
`"XZ and Zstandard ZIP interoperability 日本語\n"` repeated 800 times: 38,400 bytes,
SHA-256 `16f3e0211c947966c0e1e379ac87c947174a6b227df976fe95373940be9449b4`.
The public fixture password is `KaitoFixture`.

`generate.py` uses Python 3.14.7's `zipfile`/`lzma`, 7-Zip 26.03, and macOS OpenSSL.
It reads no third-party archive-engine implementation source. Regenerate using
`/opt/homebrew/bin/python3 generate.py` on a host with `/opt/homebrew/bin/7zz`.
Generated archive hashes are recorded in `manifest.json`. Encryption salts and
ZIP timestamps may change when regenerating; payload bytes remain fixed.

| Fixture | Provenance / comparison |
| --- | --- |
| `xz.zip`, `xz-aes.zip`, `xz-zipcrypto.zip` | 7-Zip `-tzip -mm=XZ`, with no encryption, AES256, or ZipCrypto; extracted bytes compared using 7-Zip |
| `zstd93.zip` | Python `ZIP_ZSTANDARD`; extracted bytes compared using Python and 7-Zip |
| `zstd20.zip` | `zstd93.zip` with only local and central compression IDs changed from 93 to 20 |
| `zstd-aes93.zip` | The same Zstandard frame in a WinZip AE-2 wrapper made from public field layouts, Python PBKDF2/HMAC, and OpenSSL AES-CTR keystream; decrypted and decompressed bytes compared using 7-Zip |
| `zstd-aes20.zip` | Same encrypted payload/authentication code as the AES93 fixture; only actual-method fields differ |
| `small-dictionary.xz`, `empty.xz` | Python `lzma`, LZMA2 with a 1 MiB dictionary; used in bounded/concatenated stream tests |

The host's 7-Zip and Python builds reject ZIP method 20. These legacy-ID fixtures
therefore establish routing of an independently verified Zstandard frame under
the deprecated ID, not a direct differential test of a historical method-20 ZIP.
The canonical method-93 AES wrapper has an independent full-archive decoder check.

Specifications: [PKWARE APPNOTE §4.4.5](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT),
[WinZip AES 1.04](https://www.winzip.com/en/support/aes-encryption/).
Fixed salts and passwords in the synthetic AES wrapper are test data only.
