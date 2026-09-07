# Migrating from XADMaster

Move existing XADArchive-shaped code incrementally, or adopt ArchiveReader directly.

## Use the compatibility product

Link `KaitoKitCompat`, replace the import, and retain the existing type spelling through its public
alias.

```swift
// import XADMaster
import KaitoKitCompat

guard let archive = XADArchive(file: path) else { return }
for index in 0..<archive.numberOfEntries() {
    print(archive.name(ofEntry: index) as Any)
}
```

`KaitoArchive` provides the common XADArchive surface: file/Data/URL initialization, entry queries,
whole-entry data, directory-based extraction, attributes, password and name-encoding setters,
solid-group IDs, delegate callbacks, `lastError`, and the ZIP lazy-local-header class default.

Important compatibility details:

- Directory names omit their trailing separator only in the compatibility facade.
- An unknown size is `entryHasSize(_:) == false` and `Int64.max`; ArchiveReader uses `nil`.
- `extractEntry(_:to:)` takes a destination directory and returns `Bool`.
- `entryIsLink(_:)` combines symbolic and hard links. `entryIsResourceFork(_:)` is always false.
- Delegate methods have Swift default implementations. The delegate is assigned after the
  failable initializer, so encrypted headers need ArchiveReader options at open time.
- A failed compatibility operation records a typed ``KaitoError`` in `lastError`.

## Adopt ArchiveReader

| XADMaster concept | KaitoKit replacement |
|---|---|
| `XADArchive` | ``ArchiveReader`` or `KaitoArchive` |
| `XADSimpleUnarchiver` | ``ArchiveReader/extract(_:to:options:)`` backed by the Extractor engine |
| entry contents `CSHandle` | ``EntryStream`` |
| input `CSHandle` | ``ByteSource`` and ``ByteReader`` |
| `XADString` | ``RawName`` plus ``ArchiveEntry/name`` |
| fixed/guessed name encoding | ``EncodingPolicy`` and ``ArchiveReader/nameEncoding`` |
| XAD error codes | thrown ``KaitoError`` cases |

```swift
let options = ReaderOptions(
    encodingPolicy: .automatic(likelyLanguage: "ja"),
    limits: ReadLimits(),
    password: password
)
let reader = try ArchiveReader.open(url: url, options: options)
```

Reader instances are not thread-safe. Use ``ArchiveReader/reopen()`` for each concurrent worker,
and schedule entries sharing a nonnegative `solidGroup` together. URL-backed RAR readers can locate
continuation volumes; Data and arbitrary byte sources intentionally have no sibling-file context.

See the repository's `Documentation/migration-from-xadmaster.md` for complete API, delegate,
streaming, string-encoding, error, and cooViewer `ArchiveSource` mapping tables.
