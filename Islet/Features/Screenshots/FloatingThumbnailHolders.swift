import Darwin
import Foundation

/// The Islets holding macOS's floating thumbnail off, one a line in a file of their own,
/// read and changed under a lock on it, together with macOS's setting. An Islet that went
/// without taking itself off, its keeper with it, is dropped by the next to look.
///
/// Built into the thumbnail keeper as well as Islet (`ThumbnailKeeper/main.swift`), so
/// it uses nothing else of Islet's.
struct FloatingThumbnailHolders: Sendable {
    let file: URL

    static let standard: FloatingThumbnailHolders = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return FloatingThumbnailHolders(file: support.appendingPathComponent("Islet/Screenshot thumbnail holders"))
    }()

    /// A running Islet: its process, and when that started, so a process given the same
    /// number later is not taken for it.
    struct Holder: Hashable, Sendable {
        let pid: pid_t
        let started: Int64

        static let current = Holder(pid: getpid(), started: Self.started(getpid()) ?? 0)

        init(pid: pid_t, started: Int64) {
            self.pid = pid
            self.started = started
        }

        init?(line: String) {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let pid = pid_t(parts[0]), let started = Int64(parts[1]) else { return nil }
            self.init(pid: pid, started: started)
        }

        var line: String { "\(pid) \(started)" }

        var isRunning: Bool {
            Self.started(pid) == started
        }

        /// When the process started, in microseconds; `nil` once it has gone, or has
        /// exited and waits only to be collected.
        private static func started(_ pid: pid_t) -> Int64? {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0, Int32(info.kp_proc.p_stat) != SZOMB else {
                return nil
            }
            let time = info.kp_proc.p_un.__p_starttime
            return Int64(time.tv_sec) * 1_000_000 + Int64(time.tv_usec)
        }
    }

    /// Lists `holder`, and once the list is saved calls `turnOff`, with it still locked.
    /// Listed first, an Islet that goes before the thumbnail is off, or just after, is
    /// let go for by its keeper all the same.
    func hold(_ holder: Holder, then turnOff: () -> Void) {
        change(creating: true, { $0.insert(holder) }, then: turnOff)
    }

    /// Takes `holder` off the list, and any Islet listed that has gone. If that leaves no
    /// one, and someone was taken off (or `anyway`, as for the Islet letting go itself),
    /// calls `restore`, with the list locked.
    func release(_ holder: Holder?, anyway: Bool = false, restore: () -> Void) {
        change(creating: false) { holders in
            let before = holders.count
            holders = holders.filter { $0 != holder && $0.isRunning }
            if holders.isEmpty, anyway || holders.count < before { restore() }
        }
    }

    /// Reads the list, lets `body` change it, writes it back if it has, and then calls
    /// `after`, all under the lock. Should the file not open (or not be there, and not
    /// wanted made), `body` and `after` still run, with no one listed.
    private func change(creating: Bool, _ body: (inout Set<Holder>) -> Void, then after: () -> Void = {}) {
        if creating {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let fd = open(file.path, O_RDWR | O_CLOEXEC | (creating ? O_CREAT : 0), 0o600)
        var holders: Set<Holder> = []
        guard fd >= 0 else {
            body(&holders)
            return after()
        }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0, errno == EINTR {}
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        holders = Set(lines.compactMap { Holder(line: String($0)) })
        let read = holders
        body(&holders)
        if holders != read || lines.count != read.count {
            let text = Data(holders.map { $0.line + "\n" }.sorted().joined().utf8)
            ftruncate(fd, 0)
            _ = text.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        }
        after()
    }
}

/// What Islet says to its thumbnail keeper, one byte at a time down the pipe between
/// them. The keeper hears nothing else until the pipe closes.
enum FloatingThumbnailKeeperNote: UInt8 {
    /// The thumbnail is now off for this Islet: should it go before letting go, a
    /// thumbnail found back on was turned on elsewhere.
    case held = 0x48
    /// This Islet is letting go, and has looked for the thumbnail turned on elsewhere
    /// itself: should it go now, the keeper still lets go for it, but a thumbnail found
    /// back on was put back by Islet.
    case releasing = 0x4C
    /// This Islet has let go, the thumbnail put back or left to others: the keeper exits
    /// touching nothing, as a later hold of the same Islet's is no business of its own.
    case released = 0x52
}
