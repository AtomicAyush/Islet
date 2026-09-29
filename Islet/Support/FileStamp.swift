import Foundation

/// A file as it was when a card was made for it: which file it is on its disk, its size,
/// when it was last changed, and the folder it is in. A card deletes its file only while
/// all of these still hold, so a file moved away, replaced by another file or a symbolic
/// link, or changed since, is left alone.
struct FileStamp: Equatable {
    var device: Int64
    var inode: UInt64
    var size: Int64
    var modified: TimeInterval
    /// The folder, with any symbolic links in its path followed.
    var folder: String

    /// `nil` for anything but a plain file: a folder, or a symbolic link, which is not
    /// followed.
    static func read(_ url: URL) -> FileStamp? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return FileStamp(
            device: Int64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size),
            modified: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000,
            folder: url.deletingLastPathComponent().resolvingSymlinksInPath().path
        )
    }

    /// Whether anything at all is at `url`, a symbolic link counting as itself.
    static func isThere(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// Deletes the file for good: not to the Trash, so it cannot be put back. Only a plain
    /// file: `unlink` refuses a folder, where FileManager's `removeItem` would empty one
    /// put in the file's place, and takes away a symbolic link rather than what it points
    /// to. Returns whether the file is gone.
    static func delete(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, unlink(url.path) == 0 else { return false }
        return lstat(url.path, &info) != 0 && errno == ENOENT
    }
}
