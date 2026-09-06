/// The logical kind of an archive entry.
public enum EntryKind: String, Sendable, CaseIterable {
    /// A regular file.
    case file

    /// A directory.
    case directory

    /// A symbolic link.
    case symlink

    /// A hard link.
    case hardlink

    /// A format-specific or otherwise unsupported entry type.
    case other
}
