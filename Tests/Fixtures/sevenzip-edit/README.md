# P5 7z editing fixtures

`bcj.7z`, `bcj2.7z`, and `ppmd.7z` were replaced on **2026-09-27** for KaitoKit
0.11.0. Their payloads are now entirely project-authored (MIT); the former Apple
executable payloads are no longer present. The other 30 archives are unchanged.

The current 33 archives total **1,655,900 bytes**. The largest remains `s200.7z`
(216,624 bytes, below 256 KiB). Archives plus `expected-structures.json` and
`expected-decrypted.json` total **2,039,509 bytes**, within the original
Step 0 budget of 2 MiB. `SHA256SUMS` now covers the files actually checked into
this directory, using paths relative to this directory, including the public
values, generator and documentation. It supersedes the imported scratch manifest.

## Reproduce the project-owned filter fixtures

Run from the repository root:

```sh
python3 -B Tests/Fixtures/sevenzip-edit/generate-filters.py
python3 -B Tests/Fixtures/sevenzip-edit/generate-filters.py --check
```

The pinned writer is `/opt/homebrew/bin/7zz`, **7-Zip (z) 26.03 (arm64),
2026-09-03**. The generator uses Python's standard library and 7zz as a black-box
writer/reader. No external decoder or writer source is imported.

The retained names are compatibility names, not descriptions of system programs:

| Entry | Kind | Bytes | Permissions | Project-owned source |
|---|---|---:|---|---|
| `cat` | file | 184,336 | 0755 | SHAKE-256 noise seeded with `KaitoKit 0.11.0 synthetic x86 cat`, NOPs, E8/E9 rel32 |
| `ls` | file | 252,512 | 0755 | SHAKE-256 noise seeded with `KaitoKit 0.11.0 synthetic x86 ls`, NOPs, E8/E9 rel32 |
| `t.txt` | file | 50,000 | 0644 | Numbered, project-authored PPMd text lines |

Each binary uses 64-byte records with four seeded noise bytes and forward/backward
relative calls and jumps at offsets 16 and 40. Each archive retains **one solid
folder, three substreams, 486,848 decoded bytes**, and a plain header. The two
binary entries still cross multiple 64 KiB read boundaries. The exact coder
properties, binds, packed input order, file property order, timestamp presence,
entry order/kinds and permissions are checked against the structural golden.

These are the exact writer commands, run in the temporary input directory with
`TZ=UTC LC_ALL=C`; `$OUT` abbreviates that same temporary directory:

```sh
/opt/homebrew/bin/7zz a -t7z -y -bd -mmt=1 -ms=on -mhc=off -mtm=on -m0=BCJ -m1=LZMA2:d=19 -mtc=on -mta=on "$OUT/bcj.7z" cat ls t.txt
/opt/homebrew/bin/7zz a -t7z -y -bd -mmt=1 -ms=on -mhc=off -mtm=on -m0=LZMA2:d=19 -mf=BCJ2 -mtc=on -mta=on "$OUT/bcj2.7z" cat ls t.txt
/opt/homebrew/bin/7zz a -t7z -y -bd -mmt=1 -ms=on -mhc=off -mtm=on -m0=PPMd:o=6:mem=23 -mtc=off -mta=off "$OUT/ppmd.7z" cat ls t.txt
```

After 7zz writes each archive, the generator normalizes every present creation,
access and modification FILETIME to **2023-01-01 00:00:00 UTC**
(`133170048000000000`) and recomputes the next/start header CRCs. This preserves
all timestamp flags while removing filesystem birthtime and access-time variation.
Inputs have fixed permissions, atime and mtime; encoding uses one thread.

`generate-filters.py` independently parses the new plain headers into the existing
structural schema and updates only these three records plus provenance metadata.
Their `expected-decrypted.json` arrays remain empty: none of the three uses AES.
It checks each substream CRC against the authored input, runs `7zz t -t7z`, and
compares `7zz x -so` with every input byte. Decompressing BCJ's LZMA2 stage without
BCJ proves the filter changed the stream. BCJ2 retains four nonempty packed
streams (32,309 / 153 / 2,894 / 2,894 bytes); its two LZMA-decoded branch streams
contain 27,300 / 27,304 bytes, so both branch types are exercised.

The public golden was regenerated with
`KAITOKIT_WRITE_7Z_PUBLIC_GOLDEN=1 TZ=UTC swift test --filter SevenZipPublicValueGoldenTests`
after moving `public-values.json` to a temporary backup. Only the three replaced
archive records changed; `public-values.json.sha256` was refreshed. Use the
writable-cache SwiftPM flags in the [release verification record](../../../Documentation/verification/2026-09-27-release-preparation-0.11.0.md)
when running inside the workspace sandbox. Refresh `SHA256SUMS` after intentionally
updating any covered file; verify it from this directory with `shasum -a 256 -c SHA256SUMS`.

## Historical Step 0 record (2026-09-26)

The following describes the initial scratch freeze. Its scratch-only statements,
commands and reader observations apply to that earlier stage. The filter rows
below now describe the replacements; all other archived observations are retained.

Frozen on 2026-09-26 from items 1–6 of `SP/specs/final-p45/P5.md`, with the user's scratch-only scope. Here `SP` is the parent scratchpad directory and `P5` is `SP/p5`. No fixtures were copied into a product repository, and no product implementation was changed.

At the initial freeze, the set had 33 archives and met its 2 MiB scratch budget. Current sizes are recorded above.

The original scratch `SHA256SUMS` froze the archives, goldens, documentation, scratch tool/scripts and retained run logs. Re-creation does **not** reproduce the bytes: AES IVs, filesystem birth/access timestamps, tool behavior and historical inputs can differ. Later stages should import these exact files and verify the manifest. `make-fixtures.py` refuses to overwrite an existing archive set.

Passwords are `secret` everywhere except `mix.7z`: its `a.txt` folder uses `secret`, and its `b.bin` folder uses `secret2`. The two ordinary files in `copyaes.7z` are 4,096 and 65,537 bytes; `mix.7z`'s b.bin is 8,192 bytes.

**Tools used in this run**

```text
$ /opt/homebrew/bin/7zz i
7-Zip (z) 26.03 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-09-03
 64-bit arm_v:8.5-A locale=C.UTF-8 Threads:16 OPEN_MAX:1048576, ASM
$ /usr/bin/bsdtar --version
bsdtar 3.5.3 - libarchive 3.7.4 zlib/1.2.12 liblzma/5.4.3 bz2lib/1.0.8
$ python3 --version
Python 3.14.7
$ sw_vers
ProductName:		macOS
ProductVersion:		27.2
BuildVersion:		26B5091g
$ swift --version
Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)
Target: arm64-apple-macosx27.2.0
```

Note the macOS tar executable reports **bsdtar 3.5.3, libarchive 3.7.4**; the executable and library version are distinct. KaitoKit is the supplied `./KaitoKit` export of **d35f2da**. The tiny `tools/p5tool` Swift package depends only on this local export. It was built in release mode. `logs/build-command.json` has the full argv/environment, and `logs/build.log` retains compiler, native-build deprecation and macOS diagnostic warnings; the build exited 0.

The sole GK writer invocation used the already-built P45 tool to create `empty_gk.7z`, with no source arguments (`ArchiveWriter.create` then `finish`). Its binary SHA-256 is recorded in `logs/recipes.json`. It was not used for this stage's KaitoKit verification.

**Commands and creation recipes**

The task scripts run from P5 were:

```sh
python3 -B scripts/build-tool.py
python3 -B scripts/make-fixtures.py
python3 -B scripts/verify-fixtures.py
python3 -B scripts/compute-expected.py
python3 -B scripts/compute-expected.py --check
python3 -B scripts/document-and-freeze.py
python3 -B scripts/audit-freeze.py
```

The first build ran while the fixture-generation scripts were being prepared. All configured build/module caches and temporary paths are under `P5/work/`; Python bytecode writing is disabled. The exported KaitoKit tree and `SP/p45`, `SP/p5review`, and `SP/specs` were read as inputs.

For the 13 Step 0.1 prototypes, `make-fixtures.py` used `shutil.copyfile(SP/p45/<origin>, P5/fixtures/<name>)`; the audit verifies byte identity to each origin. `g_*` are the GK prototype archives; `z_*`, `m`, and `s200` are the supplied 7zz prototype archives. This stage did not rerun or reconstruct their historical creation commands. The three filter archives were subsequently replaced by the project-owned generator documented above.

New inputs are generated in `work/inputs` by the exact literals and `hashlib.shake_256` calls in `scripts/make-fixtures.py`. That script makes the directories and relative `link -> a.txt` symlink and sets atime/mtime to Unix 1672531200. Birthtime is not fixed. These are the external creation commands that actually ran; `P5`/`SP` below abbreviate the full paths in `logs/creation-commands.json`.

```sh
P5="$PWD"
SP="${P5%/*}"
(cd "$P5/work/inputs/pair" && /opt/homebrew/bin/7zz a -t7z -y -mtc=on -mta=on "$P5/fixtures/z_times.7z" a.txt b.txt)
(cd "$P5/work/inputs/special" && /opt/homebrew/bin/7zz a -t7z -y -snl "$P5/fixtures/z_special.7z" a.txt empty.txt emptydir link)
(cd "$P5" && /usr/bin/bsdtar -cf "$P5/fixtures/lib.7z" --format 7zip -C "$P5/work/inputs/lib" .)
(cd "$P5/work/inputs/mix" && /opt/homebrew/bin/7zz a -psecret "$P5/fixtures/mix.7z" a.txt)
(cd "$P5/work/inputs/mix" && /opt/homebrew/bin/7zz a -psecret2 "$P5/fixtures/mix.7z" b.bin)
(cd "$P5/work/inputs/copyaes" && /opt/homebrew/bin/7zz a -t7z -y -mx0 -psecret "$P5/fixtures/copyaes.7z" small.bin large.bin)
(cd "$P5/work/inputs/pair" && /opt/homebrew/bin/7zz a -t7z -y -mhc=off -mhe=on -psecret "$P5/fixtures/z_aesonlyh.7z" a.txt b.txt)
(cd "$P5/work/inputs/dirs" && /opt/homebrew/bin/7zz a -t7z -y -mhe=on -psecret "$P5/fixtures/z_aeshdirs.7z" one two)
(cd "$P5" && "$SP/p45/tools/p45tool/.build/out/Products/Release/p45tool" write 7z "$P5/fixtures/empty_gk.7z")
(cd "$P5/work/inputs/pair" && /opt/homebrew/bin/7zz a "$P5/fixtures/empty_7zz.7z" a.txt)
(cd "$P5/work/inputs/pair" && /opt/homebrew/bin/7zz d "$P5/fixtures/empty_7zz.7z" a.txt)
```

All eleven creation subprocesses exited 0. `logs/creation-commands.json` contains argv, cwd, exit code, stdout and stderr for each. The table below also records the Python-built cases. Those use the unchanged prototype's `W`, `number`, `serialize_header`, `write_files`, `write_streams_info`, and `start_header`. `zero_lzma2` is parsed/reserialized from the measured P5 review fixture and remains byte-identical. `solid_zero` compresses its small literal with Python raw LZMA2 and builds both substreams with the prototype.

| Fixture | Bytes | Current-stage source / creation | `7zz t` | KaitoKit source + `.7z` URL open and full stream read |
|---|---:|---|---|---|
| `anti.7z` | 242 | z_special with kAnti set on its streamless empty file. | exit 0: Everything is Ok | open OK (4 entries); all nondirectory entries fully read (exit 0) |
| `archive_properties.7z` | 228 | z_times data with a kArchiveProperties section containing a comment property. | exit 0: Everything is Ok | open OK (2 entries); all nondirectory entries fully read (exit 0) |
| `bcj.7z` | 39,836 | `generate-filters.py`, project-authored payload, 7zz 26.03 (2026-09-27) | exit 0: Everything is Ok | open OK (3 entries); all nondirectory entries fully read (exit 0) |
| `bcj2.7z` | 38,532 | `generate-filters.py`, project-authored payload, 7zz 26.03 (2026-09-27) | exit 0: Everything is Ok | open OK (3 entries); all nondirectory entries fully read (exit 0) |
| `comment.7z` | 217 | z_times with an opaque FilesInfo property 0x16. | exit 0: Everything is Ok | open OK (2 entries); all nondirectory entries fully read (exit 0) |
| `copyaes.7z` | 69,873 | AES + Copy, files of 4096 and 65537 bytes (both sides of 64 KiB). | exit 0: Everything is Ok | open OK (2 entries); all nondirectory entries fully read (exit 0) |
| `empty_7zz.7z` | 32 | Created one member and deleted it; 32 bytes with no next header. | exit 0: Everything is Ok | open rejected: `malformed(empty 7z next header)` (exit 2) |
| `empty_fi0.7z` | 37 | sz.start_header plus kHeader/kFilesInfo/0/kEnd/kEnd. | exit 0: Everything is Ok | open OK (0 entries); all nondirectory entries fully read (exit 0) |
| `empty_gk.7z` | 34 | Called ArchiveWriter.create then finish, with no additions; header 01 00. | exit 0: Everything is Ok | open OK (0 entries); all nondirectory entries fully read (exit 0) |
| `external_names.7z` | 238 | Copy-coded AdditionalStreamsInfo stores names; FilesInfo kName external=1, stream index 0. | exit 0: Everything is Ok | open OK (2 entries); all nondirectory entries fully read (exit 0) |
| `g_aes.7z` | 109,406 | Byte-for-byte copy of `SP/p45/t7/g_aes.7z` | exit 0: Everything is Ok | open OK (9 entries); all nondirectory entries fully read (exit 0) |
| `g_aesh.7z` | 109,458 | Byte-for-byte copy of `SP/p45/t7/g_aesh.7z` | exit 0: Everything is Ok | open OK (9 entries); all nondirectory entries fully read (exit 0) |
| `g_plain.7z` | 109,212 | Byte-for-byte copy of `SP/p45/t7/g_plain.7z` | exit 0: Everything is Ok | open OK (9 entries); all nondirectory entries fully read (exit 0) |
| `lib.7z` | 4,426 | bsdtar 7zip writer, including root . and ./-prefixed member names. | exit 0: Everything is Ok | open OK (6 entries); all nondirectory entries fully read (exit 0) |
| `m.7z` | 208,894 | Byte-for-byte copy of `SP/p45/t7u/m.7z` | exit 0: Everything is Ok | open OK (10 entries); all nondirectory entries fully read (exit 0) |
| `mix.7z` | 8,488 | a.txt uses secret; b.bin (8192 bytes) uses secret2 in a separate folder. | exit 2 for both passwords; one wrong-password member each | open OK (2 entries); secret fails b.bin; secret2 fails a.txt (`wrongPassword`, exit 3) |
| `packpos16.7z` | 221 | z_times main packPos=16; sixteen zero bytes precede the main packs. | exit 0: Everything is Ok | open OK (2 entries); all nondirectory entries fully read (exit 0) |
| `ppmd.7z` | 80,554 | `generate-filters.py`, project-authored payload, 7zz 26.03 (2026-09-27) | exit 0: Everything is Ok | open OK (3 entries); all nondirectory entries fully read (exit 0) |
| `s200.7z` | 216,624 | Byte-for-byte copy of `SP/p45/t7s/s200.7z` | exit 0: Everything is Ok | open OK (200 entries); all nondirectory entries fully read (exit 0) |
| `sfx.7z` | 113,308 | cf fa ed fe then 4092 zero bytes, followed by g_plain.7z; freeze only if KaitoKit source+URL open succeeds. | exit 2: Cannot open the file as [7z] archive; Is not archive | open OK (9 entries); first signature at 4096; every payload hash matches g_plain (exit 0) |
| `solid_zero.7z` | 175 | One LZMA2 solid folder, substreams [nonempty, 0]; delete nonempty.txt to leave zero bytes. | exit 0: Everything is Ok | open OK (2 entries); all nondirectory entries fully read (exit 0) |
| `startpos.7z` | 218 | kStartPos defined on the first of two streamed files only. | exit 0: Everything is Ok | open OK (2 entries); all nondirectory entries fully read (exit 0) |
| `unknown_1a.7z` | 226 | z_times with an opaque FilesInfo property 0x1a. | exit 0: Everything is Ok | open OK (2 entries); all nondirectory entries fully read (exit 0) |
| `z_aes.7z` | 108,870 | Byte-for-byte copy of `SP/p45/t7/z_aes.7z` | exit 0: Everything is Ok | open OK (8 entries); all nondirectory entries fully read (exit 0) |
| `z_aesh.7z` | 108,800 | Byte-for-byte copy of `SP/p45/t7/z_aesh.7z` | exit 0: Everything is Ok | open OK (8 entries); all nondirectory entries fully read (exit 0) |
| `z_aeshdirs.7z` | 171 | Only streamless directory entries, encrypted header. | exit 0: Everything is Ok | open OK (3 entries); all nondirectory entries fully read (exit 0) |
| `z_aesonlyh.7z` | 256 | Encrypted, uncompressed (AES-only) header; encrypted file data. | exit 0: Everything is Ok | open OK (2 entries); all nondirectory entries fully read (exit 0) |
| `z_default.7z` | 108,725 | Byte-for-byte copy of `SP/p45/t7/z_default.7z` | exit 0: Everything is Ok | open OK (8 entries); all nondirectory entries fully read (exit 0) |
| `z_nonsolid.7z` | 109,258 | Byte-for-byte copy of `SP/p45/t7/z_nonsolid.7z` | exit 0: Everything is Ok | open OK (8 entries); all nondirectory entries fully read (exit 0) |
| `z_plainhdr.7z` | 108,828 | Byte-for-byte copy of `SP/p45/t7/z_plainhdr.7z` | exit 0: Everything is Ok | open OK (8 entries); all nondirectory entries fully read (exit 0) |
| `z_special.7z` | 231 | Empty file, empty directory, regular file, and stored relative symlink. | exit 0: Everything is Ok | open OK (4 entries); all nondirectory entries fully read (exit 0) |
| `z_times.7z` | 207 | 7zz archive with creation, access and modification times. | exit 0: Everything is Ok | open OK (2 entries); all nondirectory entries fully read (exit 0) |
| `zero_lzma2.7z` | 75 | Parsed and reserialized p5review/zero_lzma2.7z; one streamed zero-size file, LZMA2 pack 00. | exit 0: Everything is Ok | open OK (1 entries); all nondirectory entries fully read (exit 0) |

**Verification that actually ran**

For each archive, the verifier ran these exact argument patterns (absolute paths are retained in the log):

```sh
/opt/homebrew/bin/7zz t -psecret -y -bd "$P5/fixtures/NAME.7z"
"$P5/work/build/release/p5tool" "$P5/fixtures/NAME.7z" secret
# Additional runs for mix.7z:
/opt/homebrew/bin/7zz t -psecret2 -y -bd "$P5/fixtures/mix.7z"
"$P5/work/build/release/p5tool" "$P5/fixtures/mix.7z" secret2
```

That is **34 `7zz t` invocations and 34 opener invocations**. 31 `7zz t` invocations passed; the two mix runs and the SFX run exited 2. KaitoKit opened 32 of 33 distinct archives (33 of 34 invocations). It fully read and SHA-256-hashed every nondirectory entry on each successful open, retaining per-entry failures so both mix members were exercised. All payload reads passed except the expected opposite-password member in each mix run. `logs/validation.json` retains all argv, outputs, exit codes, entry metadata, payload hashes and typed errors.

Six additional compatibility listings ran as `/usr/bin/bsdtar -tf <archive>`:

| Archive | bsdtar listing result |
|---|---|
| `empty_7zz.7z` | exit 0: OK |
| `empty_fi0.7z` | exit 0: OK |
| `empty_gk.7z` | exit 1: Malformed 7-Zip archive |
| `lib.7z` | exit 0: OK |
| `solid_zero.7z` | exit 0: OK |
| `zero_lzma2.7z` | exit 0: OK |

The SFX prefix is exactly `cf fa ed fe` followed by 4,092 zero bytes and then `g_plain.7z`. The opener passes the whole `FileByteSource` to `ArchiveReader.open(source:sourceURL:options:)` with `sfx.7z` as the URL hint. The first 7z signature is at 4,096, and the parsed entries and every payload SHA-256 match g_plain. Thus KaitoKit's nonzero-offset open prerequisite passed and the fixture is frozen; the spec's direct-`RebasedByteSource` fallback was **not needed**. The ordinary `7zz t` command rejects this synthetic Mach-O prefix with `Cannot open the file as [7z] archive` / `Is not archive`; that incompatibility is preserved as a measured result. No forced-format SFX command was run.

The 32-byte `empty_7zz.7z` is deliberately retained as a negative KaitoKit golden: `malformed(empty 7z next header)` / `Malformed archive: empty 7z next header`. `empty_gk.7z` has plaintext header `01 00`, `empty_fi0.7z` has `01 05 00 00 00`, and the latter is accepted by all three readers. No extraction commands or product test suites were run in this step.

**Expected-value derivation**

`fixtures/expected-structures.json` initially contained 33 records computed using `SP/p45/sz.py`; three filter records now come from `generate-filters.py`. `fixtures/expected-decrypted.json` contains 21 AES-folder records, including encrypted-header folders. The prototype SHA-256 is `bf7c041ed1af8213ee5f98e1ef174adff58f0cf6401f37c772729c62c6bfa064`. `scripts/prototype.py` imports it directly without modifying or copying it. Neither 7zz listings nor KaitoKit's decoded metadata were used as the source of structural golden values.

The wrapper retains raw property envelopes/order using `sz.P`. It adapts only three unsupported prototype cases: (1) removes the SFX prefix into `work/parser-inputs` before `sz.Archive`, then adds the base to physical ranges; (2) records the absent next header without inventing or parsing replacement header bytes; (3) decodes AdditionalStreamsInfo with `sz.decode_folder`, resolves external kName index 0, and passes the names to the original `sz.parse_files`, retaining the original external property bytes. Every other header, coder graph, CRC, substream, file name, timestamp, attribute, StartPos and flag uses the original parser.

Ranges are physical file offsets plus lengths; `packPos` and `nextHeaderOffset` remain 7z-relative. `mainPackEnd` includes `baseOffset`. FILETIME and StartPos use exact unsigned decimal strings to avoid JSON consumer precision loss. `nameRawHex` omits the UTF-16 NUL terminator. Raw property bytes preserve presence/defined bits, dummy padding, comments, unknown properties and external flags. Main, additional and encoded-header streams each retain coders, isComplex, property presence, binds, packed inputs, unpack sizes, CRCs, physical pack ranges/digests and substreams. The empty next-header case records length 0 and the hash of empty bytes, distinguished from an empty kHeader.

AES `plaintextSHA256` is the output of the AES coder **before decompression**, trimmed to its declared output size. Padded AES output and fully decoded folder hashes are recorded separately. The original `sz.sevenzip_key`, `sz.aes_cbc` and `sz.decode_folder` compute these values; every AES folder was decoded and checked against stored folder/substream CRCs, with `secret2` selected only for mix's second folder. `baselineReaders` contains measured reader outcomes for future negative tests and is distinct from parser-computed fields. A second computation with `--check` matched both golden JSON files byte-for-byte.

**Provenance and later-stage boundary**

`NOTICE-lines.txt` is the provenance text for later stages to append to their own `Tests/Fixtures/NOTICE`. No destination NOTICE was edited here. Keep all imported archives and both JSON files together; preserve the fixture filenames.

Step 0.6 is intentionally a deferred test: **no archive with an offset beyond 4 GiB was created or frozen**. AC-G17 must construct its own APFS sparse file inside the later test. This step neither ran AC-G17 nor changed KaitoKit's internal tests.

To audit the delivered bytes without regenerating the archives, run `python3 -B scripts/audit-freeze.py`. To independently re-evaluate the goldens in this scratch environment, run `python3 -B scripts/compute-expected.py --check` (requires the pinned P45 parser).
