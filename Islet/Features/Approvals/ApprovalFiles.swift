import Darwin
import Foundation

/// The folder approvals pass through, Islet's alone:
///
///     ~/Library/Application Support/Islet/Approvals/     0700
///         .lock               held by the running Islet
///         presence.json       Islet is running, and what hooks may ask   0600
///         Requests/<id>.json  hook → Islet, never rewritten               0600
///         Answers/<id>.json   Islet → hook, signed, never overwritten     0600
///         Passed/<session>/   ChatGPT's hook: requests left to the app, each by
///                             the first 16 hex digits of its digest           0700
///
/// Only Islet makes the folders; a hook finding one missing, a link, someone else's or
/// open to others offers nothing. Every file is read without following a link or
/// waiting on a pipe, and checked on what was opened; every file Islet writes is made
/// whole under a hidden name and moved into place, and an answer only into a name not
/// yet taken.
struct ApprovalFolder: Sendable {
    let root: URL

    var requests: URL { root.appendingPathComponent("Requests", isDirectory: true) }
    var answers: URL { root.appendingPathComponent("Answers", isDirectory: true) }
    var passed: URL { root.appendingPathComponent("Passed", isDirectory: true) }
    var presence: URL { root.appendingPathComponent("presence.json") }
    var lock: URL { root.appendingPathComponent(".lock") }

    static var standard: ApprovalFolder {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return ApprovalFolder(root: support.appendingPathComponent("Islet/Approvals", isDirectory: true))
    }

    /// A request's or answer's file name: 32 lowercase hex digits and `.json`.
    static func isID(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    func request(_ id: String) -> URL { requests.appendingPathComponent(id + ".json") }
    func answer(_ id: String) -> URL { answers.appendingPathComponent(id + ".json") }

    /// Makes the folders, or puts right their modes; false if one is not a folder of
    /// this user's (a link, say), which is never followed or replaced.
    func prepare() -> Bool {
        let parent = root.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return [root, requests, answers, passed].allSatisfy(Self.prepareDirectory)
    }

    private static func prepareDirectory(_ url: URL) -> Bool {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT, mkdir(url.path, 0o700) == 0 || errno == EEXIST else { return false }
            guard lstat(url.path, &info) == 0 else { return false }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { return false }
        if info.st_mode & 0o777 != 0o700 { return chmod(url.path, 0o700) == 0 }
        return true
    }

    /// Whether every folder is as a hook needs it.
    var isSound: Bool {
        [root, requests, answers].allSatisfy { url in
            var info = stat()
            return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
                && info.st_mode & 0o777 == 0o700
        }
    }
}

/// Reading and writing the folder's files safely.
enum ApprovalFiles {
    /// What was opened: for telling a file changed since it was read.
    struct Stamp: Equatable, Sendable {
        var inode: UInt64
        var size: Int64
        var modified: Double
    }

    /// The bytes of `url` and their stamp, if it is a regular file of this user's, not a
    /// link, at most `limit` bytes, and with none of `forbidden` in its mode (others
    /// reading or writing, by default).
    static func read(_ url: URL, limit: Int, forbidden: mode_t = 0o077) -> (data: Data, stamp: Stamp)? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & forbidden == 0, info.st_size <= limit
        else { return nil }
        var data = Data(count: Int(info.st_size) + 1)
        var total = 0
        while total < data.count {
            let count = data.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress! + total, buffer.count - total)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            total += count
        }
        guard total <= limit else { return nil }
        data.count = total
        let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        return (data, Stamp(inode: UInt64(info.st_ino), size: Int64(info.st_size), modified: modified))
    }

    /// The stamp of `url` as it is now, without following a link.
    static func stamp(_ url: URL) -> Stamp? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        return Stamp(inode: UInt64(info.st_ino), size: Int64(info.st_size), modified: modified)
    }

    /// Writes `data` to `url` with `mode`: whole, under a hidden name made only if none
    /// was there, flushed to disk, then moved into place. With `exclusive`, only if
    /// nothing has the name yet, so an answer is never overwritten; otherwise replacing
    /// what had it (a link included, never what it points at).
    @discardableResult
    static func write(_ data: Data, to url: URL, mode: mode_t = 0o600, exclusive: Bool) -> Bool {
        let folder = url.deletingLastPathComponent()
        let temp = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { return false }
        var ok = fchmod(fd, mode) == 0
        if ok {
            ok = data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { return false }
                    offset += count
                }
                return true
            }
        }
        ok = ok && fsync(fd) == 0
        close(fd)
        if ok {
            ok = exclusive ? renamex_np(temp.path, url.path, UInt32(RENAME_EXCL)) == 0 : rename(temp.path, url.path) == 0
        }
        if !ok { unlink(temp.path) }
        return ok
    }

    static func remove(_ url: URL) {
        unlink(url.path)
    }

    /// Removes the folder `url` and the files in it, if it is a folder of this user's;
    /// a link is removed itself, never followed.
    static func removeFolder(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            unlink(url.path)
            return
        }
        for name in names(in: url) { unlink(url.appendingPathComponent(name).path) }
        rmdir(url.path)
    }

    /// The files in `folder`, by name, hidden ones included; [] if it cannot be read.
    static func names(in folder: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }

    /// When a file in `folder` was last changed, without following a link.
    static func modified(_ url: URL) -> Date? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
    }
}

/// The lock a running Islet holds on its approvals folder, so a second copy of Islet
/// running at once leaves approvals to the first.
final class ApprovalLock {
    private var fd: Int32 = -1

    var isHeld: Bool { fd >= 0 }

    func take(_ url: URL) -> Bool {
        guard fd < 0 else { return true }
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        self.fd = fd
        return true
    }

    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}
