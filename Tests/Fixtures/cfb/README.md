# Compound File (MS-CFB) fixtures

Compound files written by `generate.py`'s own writer, built from [MS-CFB] v20240423 prose only
(inbox/cfb/MS-CFB.pdf), around a project-owned set of streams. `manifest.json` records every stream's
size and SHA-256, and each archive's size, SHA-256 and stream list.

| Archive | Coverage |
| --- | --- |
| `v3.cfb` | version 3 (512-byte sectors): streams in the mini stream (31 and 4095 bytes), one exactly at the 4096-byte cutoff, two large streams, an empty stream, three levels of storages, a 31-character name, `\x05SummaryInformation`, Japanese storage and stream names |
| `v3-interleaved.cfb` | as above with the large streams' sectors written round-robin (fragmented FAT chains) |
| `v4.cfb` | version 4 (4096-byte sectors, 64-bit sizes, directory sector count in the header) |
| `v3-difat.cfb` | version 3 plus a 7.2 MB stream, so the FAT needs 112 sectors and the DIFAT continues in a DIFAT sector past the 109 header entries |
| `msi-names.cfb` | stream names packed the Windows Installer way (`!_Tables`, `Binary.WrappedExe`, all digits, both full alphabets, `.`/`_`, `!!5`, an out-of-range unit — every one of the 64 alphabet positions); 7-Zip extracts them under the unpacked names, which `manifest.json` records as `published` |

Every archive is extracted with 7-Zip (`7zz x`) and compared stream by stream with the payload before
it is stored; 7-Zip cannot write CFB and no other CFB writer is installed. Two black-box observations
shaped the writer: 7-Zip refuses a file whose FAT holds many sectors that belong to no stream (the
DIFAT case therefore uses a real stream instead of filler sectors), and it warns about sectors after the
last non-free FAT entry, so the file ends there. 7-Zip lists a stream whose name starts with a control
character as `[5]SummaryInformation`, which is the spelling KaitoKit uses. No third-party CFB
implementation source was consulted (Documentation/verification/2026-09-21-cfb.md).

```sh
python3 Tests/Fixtures/cfb/generate.py   # needs 7zz on PATH
swift test --filter CFBReaderTests
```
