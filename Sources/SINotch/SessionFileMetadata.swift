import Darwin
import Foundation

/// One syscall per candidate, without Foundation's attribute dictionaries or
/// URL resource prefetching. lstat preserves the scanners' symlink rejection.
struct SessionFileMetadata {
    let inode: UInt64
    let size: UInt64
    let modified: Date
    let owner: uid_t
    let isRegularFile: Bool
    let isDirectory: Bool

    init?(_ url: URL) {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            path.map { lstat($0, &info) } ?? -1
        }
        guard result == 0, info.st_size >= 0 else { return nil }
        inode = UInt64(info.st_ino)
        size = UInt64(info.st_size)
        modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) +
                        Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        owner = info.st_uid
        isRegularFile = info.st_mode & S_IFMT == S_IFREG
        isDirectory = info.st_mode & S_IFMT == S_IFDIR
    }
}
