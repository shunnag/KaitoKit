import Darwin

/// A reader can reuse its last direct child directory while extracting consecutive entries.
final class ExtractionDirectoryCache {
    private struct Entry {
        let component: String
        let root: ExtractedFileIdentity
        let parent: ExtractedFileIdentity
        let mode: mode_t
        let handle: ExtractionDirectoryHandle
    }

    private var entry: Entry?

    func open(_ components: [String], below rootDescriptor: Int32, create: Bool) throws -> ExtractionDirectoryHandle {
        guard components.count == 1, let component = components.first else {
            return try ExtractionDirectoryAccess.open(components, below: rootDescriptor, create: create)
        }
        var root = stat()
        guard Darwin.fstat(rootDescriptor, &root) == 0 else {
            return try ExtractionDirectoryAccess.open(components, below: rootDescriptor, create: create)
        }
        var parent = stat()
        if let entry, entry.component.utf8.elementsEqual(component.utf8), entry.root == Self.identity(root),
           Darwin.fstatat(rootDescriptor, component, &parent, AT_SYMLINK_NOFOLLOW) == 0,
           entry.mode == parent.st_mode, entry.parent == Self.identity(parent) {
            return entry.handle
        }

        entry = nil
        let handle = try ExtractionDirectoryAccess.open(components, below: rootDescriptor, create: create)
        // Only the current extraction may own a temporary permission change.
        if !handle.hasTemporaryMode, Darwin.fstat(handle.descriptor, &parent) == 0 {
            entry = Entry(component: component, root: Self.identity(root), parent: Self.identity(parent),
                          mode: parent.st_mode, handle: handle)
        }
        return handle
    }

    func reset() { entry = nil }

    private static func identity(_ info: stat) -> ExtractedFileIdentity {
        ExtractedFileIdentity(device: info.st_dev, inode: info.st_ino, generation: info.st_gen)
    }
}
