# ``KaitoKit``

Read, inspect, stream, and extract common archive formats with a native Swift API.

## Overview

KaitoKit opens archives from file URLs, `Data`, and custom random-access byte sources. It supports
ZIP, 7-Zip, RAR4/RAR5, LHA, tar, gzip, bzip2, XZ, UNIX compress, and compressed-tar filename forms.
Entry names retain both their decoded display string and their original bytes.

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
