# Getting Started

Open an archive, inspect its entries, and choose between whole-entry and streaming reads.

## Add the package

Add `https://github.com/shunnag/KaitoKit.git` as a Swift package dependency and link the
`KaitoKit` product. KaitoKit requires macOS 26 or later and Swift 6.

```swift
import Foundation
import KaitoKit
```

## Open and inspect an archive

Use a file URL when the reader may need filesystem context, including RAR continuation volumes and
compressed-tar extension hints.

```swift
let url = URL(fileURLWithPath: "/tmp/book.cbz")
let reader = try ArchiveReader.open(url: url)

for entry in reader.entries {
    print(entry.index, entry.kind, entry.uncompressedSize as Any, entry.name)
}
```

Use `Data` for an archive already in memory, including an archive read from another entry.

```swift
let nestedData = try outerReader.read(outerEntry)
let nestedReader = try ArchiveReader.open(data: nestedData)
```

## Read or stream an entry

``ArchiveReader/read(_:)`` returns one `Data` value and applies `maxInMemorySize`. Stream larger
entries into a caller-owned buffer.

```swift
let stream = try reader.stream(entry)
var buffer = [UInt8](repeating: 0, count: 256 * 1_024)

while true {
    let count = try buffer.withUnsafeMutableBytes { bytes in
        try stream.read(into: bytes)
    }
    if count == 0 { break }
    consume(buffer[0..<count])
}
```

Read until zero or an error. Checks that cover the complete stream finish on the final read.

## Extract entries

The destination argument is a directory; KaitoKit appends the entry path.

```swift
let destination = URL(fileURLWithPath: "/tmp/unpacked", isDirectory: true)
for entry in reader.entries where entry.kind != .directory {
    _ = try reader.extract(entry, to: destination)
}

for directory in reader.entries.filter({ $0.kind == .directory }).sorted(by: {
    $0.pathComponents.count > $1.pathComponents.count
}) {
    _ = try reader.extract(directory, to: destination)
}
```

Process directory entries after their children when final directory dates and permissions matter.
The caller should keep the extraction root unchanged until each operation returns.

## Configure limits and parallel readers

```swift
var limits = ReadLimits()
limits.maxEntrySize = 2 * 1_024 * 1_024 * 1_024
limits.maxTotalUncompressedSize = 16 * 1_024 * 1_024 * 1_024
limits.maxInMemorySize = 256 * 1_024 * 1_024

let configured = try ArchiveReader.open(
    url: url,
    options: ReaderOptions(limits: limits)
)
let workerReader = try configured.reopen()
```

An `ArchiveReader` and an `EntryStream` are stateful and not thread-safe. Give each actor or worker
its own reopened reader. Entries with the same nonnegative `solidGroup` belong to one dependency
group; `-1` identifies an independent entry.

For a stable local single file, `Data(contentsOf:options:.mappedIfSafe)` can avoid an eager copy.
Prefer URL opening for multi-volume RAR, and use streaming rather than mapped output for large
entries.
