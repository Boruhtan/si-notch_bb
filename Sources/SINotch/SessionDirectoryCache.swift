import Foundation

/// Cache directory membership, never file sizes or contents. Appends are still
/// detected on every poll; additions, removals and replacements invalidate the
/// listing through directory metadata. Missing directories are retried.
struct SessionDirectoryCache {
    private struct Entry {
        let metadata: SessionFileMetadata
        let children: [URL]
    }
    private var entries: [URL: Entry] = [:]
    private let capacity = 1024

    mutating func contents(of directory: URL) -> [URL] {
        guard let metadata = SessionFileMetadata(directory), metadata.isDirectory else {
            entries[directory] = nil
            return []
        }
        if let cached = entries[directory], cached.metadata == metadata { return cached.children }
        guard let children = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            entries[directory] = nil
            return []
        }
        if entries.count >= capacity { entries.removeAll(keepingCapacity: true) }
        entries[directory] = Entry(metadata: metadata, children: children)
        return children
    }
}
