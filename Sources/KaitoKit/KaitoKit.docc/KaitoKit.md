# ``KaitoKit``

Read, inspect, stream, and extract common archive formats with a native Swift API.

## Overview

KaitoKit opens archives from file URLs, `Data`, and custom random-access byte sources. It supports
ZIP / ZIP64, 7-Zip, RAR4/RAR5, LHA, StuffIt / StuffIt X, MacBinary / AppleSingle / BinHex, ISO 9660 / UDF (including BIN/CUE raw-sector images), WIM, Compound File (MS-CFB), CHM, ARJ, Apple Disk Image (UDIF + HFS+), cpio, ar (including `.deb`),
xar (including `.pkg`), CAB, RPM, tar, gzip, bzip2, XZ, zstd, LZ4, LZMA (`.lzma`), lzip (`.lz`), brotli (`.br`), UNIX compress,
pbzx, and compressed-tar / compressed-cpio filename forms. Entry names retain both their decoded display string and their
original bytes.

Use ``ArchiveReader`` for new code. It exposes typed errors, bounded whole-entry reads,
``EntryStream`` for incremental output, and ``ArchiveReader/reopen()`` for independent reader state
over the same input. Existing XADMaster-shaped call sites can import the separate
`KaitoKitCompat` product.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:MigrationFromXADMaster>
- ``ArchiveReader``
- ``ArchiveEntry``
- ``EntryStream``

### Configuration

- ``ReaderOptions``
- ``ReadLimits``
- ``EncodingPolicy``
- ``ExtractionOptions``

### Input and Errors

- ``ByteSource``
- ``RawName``
- ``ArchiveFormat``
- ``KaitoError``
