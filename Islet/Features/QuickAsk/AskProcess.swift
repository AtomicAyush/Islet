import Darwin
import Foundation

/// One run of a command line tool that answers a question: ChatGPT's or Claude's. The
/// question goes in on its standard input, never in its arguments, where every process
/// on the Mac could read it; its output comes back a line at a time as it prints it.
///
/// It runs in a folder of its own, empty but for the files the run is given, which goes
/// as the tool exits, with exactly the environment it is given and nothing of Islet's,
/// in a process group of its own: stopping it stops whatever it started too. Stopping
/// is SIGTERM to the group, then SIGKILL a second on. It is given up on and stopped
/// when it prints nothing for `firstOutput`, or runs past `total`, or when whoever reads
/// its output stops reading. What it prints on its standard error is thrown away,
/// unread.
///
/// Every run still going is known to `ChildProcesses`, so none outlives Islet.
final class AskProcess: ChildProcess, @unchecked Sendable {
    struct Launch {
        var executable: URL
        /// The arguments, given the run's own folder.
        var arguments: (URL) -> [String]
        /// The whole environment the tool sees, given the run's own folder.
        var environment: (URL) -> [String: String]
        /// Files put in the folder before the tool starts, by name.
        var files: [String: Data] = [:]
        /// One of `files` the tool reads once (a picture of the screen), taken away as soon
        /// as a line it prints says it has been read, as well as with the folder.
        var readOnce: (name: String, isRead: @Sendable (String) -> Bool)?
        /// What the tool reads on its standard input.
        var input: Data
        var firstOutput: TimeInterval = AskLimits.firstOutput
        var total: TimeInterval = AskLimits.total
        /// Where the run's folder is made. Tests give their own.
        var parent = FileManager.default.temporaryDirectory
    }

    enum Output: Equatable {
        case line(String)
        /// The tool exited, with this status (128 and the signal, for a signal).
        case exited(Int32)
    }

    enum Failure: Error, Equatable {
        case couldNotStart
        /// Nothing at all printed within `firstOutput`.
        case silent
        case timedOut
    }

    static let folderPrefix = "Islet Ask "

    /// Runs the tool; its output as it comes. Ending the task that reads it stops the tool.
    static func run(_ launch: Launch) -> AsyncThrowingStream<Output, Error> {
        AsyncThrowingStream { continuation in
            let run = AskProcess(launch: launch, continuation: continuation)
            continuation.onTermination = { _ in run.stop() }
            run.start()
        }
    }

    /// Folders left by runs that never finished, Islet having crashed or been killed.
    static func removeLeftovers(in parent: URL = FileManager.default.temporaryDirectory) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        for name in names where name.hasPrefix(folderPrefix) {
            try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))
        }
    }

    private let launch: Launch
    private let continuation: AsyncThrowingStream<Output, Error>.Continuation
    private let lock = NSLock()
    // Guarded by `lock`.
    private var pid: pid_t = 0
    private var folder: URL?
    private var isReaped = false
    private var isReadingDone = false
    private var isStopping = false
    private var hasOutput = false
    private var isOnceRead = false
    private var isFinished = false
    private var status: Int32 = 0
    private var failure: Failure?

    private init(launch: Launch, continuation: AsyncThrowingStream<Output, Error>.Continuation) {
        self.launch = launch
        self.continuation = continuation
    }

    /// The group's pid, once running: for tests.
    var processGroup: pid_t {
        lock.lock()
        defer { lock.unlock() }
        return pid
    }

    private func start() {
        guard let folder = makeFolder() else {
            continuation.finish(throwing: Failure.couldNotStart)
            return
        }
        var input: [Int32] = [-1, -1]
        var output: [Int32] = [-1, -1]
        guard pipe(&input) == 0 else { return fail(folder) }
        guard pipe(&output) == 0 else {
            input.forEach { close($0) }
            return fail(folder)
        }
        for fd in input + output { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        // A tool that exits before reading its input must not take Islet with it.
        _ = fcntl(input[1], F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, input[0], 0)
        posix_spawn_file_actions_adddup2(&actions, output[1], 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addchdir_np(&actions, folder.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own group; nothing open of Islet's but the three above; and the signals
        // Islet itself ignores or handles, back to their defaults.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGPIPE, SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGCHLD, SIGALRM, SIGUSR1, SIGUSR2] {
            sigaddset(&defaults, signal)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let path = launch.executable.path
        let argv = ([path] + launch.arguments(folder)).map { strdup($0) } + [nil]
        let envp = launch.environment(folder).sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var child: pid_t = 0
        let spawned = posix_spawn(&child, path, &actions, &attributes, argv, envp)
        close(input[0])
        close(output[1])
        guard spawned == 0 else {
            close(input[1])
            close(output[0])
            return fail(folder)
        }

        lock.lock()
        pid = child
        lock.unlock()
        ChildProcesses.shared.insert(self)

        let data = launch.input
        DispatchQueue.global(qos: .userInitiated).async {
            Self.write(data, to: input[1])
            close(input[1])
        }
        let reader = Thread { [self] in read(output[0]) }
        reader.qualityOfService = .userInitiated
        reader.start()
        let waiter = Thread { [self] in waitForExit(child) }
        waiter.qualityOfService = .utility
        waiter.start()

        let queue = DispatchQueue.global(qos: .utility)
        queue.asyncAfter(deadline: .now() + launch.firstOutput) { [self] in
            if !sawOutput { give(up: .silent) }
        }
        queue.asyncAfter(deadline: .now() + launch.total) { [self] in give(up: .timedOut) }
    }

    private func makeFolder() -> URL? {
        let folder = launch.parent.appendingPathComponent(Self.folderPrefix + UUID().uuidString, isDirectory: true)
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for (name, data) in launch.files {
                let url = folder.appendingPathComponent(name)
                guard manager.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                    throw Failure.couldNotStart
                }
            }
        } catch {
            try? manager.removeItem(at: folder)
            return nil
        }
        lock.lock()
        self.folder = folder
        lock.unlock()
        return folder
    }

    private func fail(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
        continuation.finish(throwing: Failure.couldNotStart)
    }

    private static func write(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let written = Darwin.write(fd, pointer, left)
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                left -= written
                pointer += written
            }
        }
    }

    // MARK: Output

    private var sawOutput: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasOutput
    }

    /// Reads the tool's output until every process that could write it has gone,
    /// passing on each whole line.
    private func read(_ fd: Int32) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            lock.lock()
            hasOutput = true
            lock.unlock()
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                removeIfRead(line)
                continuation.yield(.line(line))
            }
        }
        if !pending.isEmpty { continuation.yield(.line(String(decoding: pending, as: UTF8.self))) }
        close(fd)
        lock.lock()
        isReadingDone = true
        lock.unlock()
        finishIfDone()
    }

    /// The file the tool reads once goes as soon as a line says it was read.
    private func removeIfRead(_ line: String) {
        guard let (name, isRead) = launch.readOnce, isRead(line) else { return }
        lock.lock()
        let file = isOnceRead ? nil : folder?.appendingPathComponent(name)
        isOnceRead = true
        lock.unlock()
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    /// Waits for the tool to exit, then stops whatever it left running in its group and
    /// reaps it. Until reaped its pid stays its own, so the group cannot be anyone else's.
    private func waitForExit(_ child: pid_t) {
        var info = siginfo_t()
        while waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) != 0, errno == EINTR {}
        lock.lock()
        killpg(child, SIGKILL)
        var raw: Int32 = 0
        while waitpid(child, &raw, 0) < 0, errno == EINTR {}
        isReaped = true
        status = Self.exitStatus(raw)
        lock.unlock()
        ChildProcesses.shared.remove(self)
        finishIfDone()
    }

    /// The exit status, or 128 and the signal for a tool ended by one, as a shell says.
    static func exitStatus(_ raw: Int32) -> Int32 {
        let signal = raw & 0x7f
        return signal == 0 ? (raw >> 8) & 0xff : 128 + signal
    }

    private func finishIfDone() {
        lock.lock()
        guard isReaped, isReadingDone, !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let folder = self.folder
        let failure = self.failure
        let status = self.status
        lock.unlock()
        if let folder { try? FileManager.default.removeItem(at: folder) }
        if let failure {
            continuation.finish(throwing: failure)
        } else {
            continuation.yield(.exited(status))
            continuation.finish()
        }
    }

    // MARK: Stopping

    private func give(up reason: Failure) {
        lock.lock()
        let isOver = isFinished || isReaped
        if !isOver, failure == nil { failure = reason }
        lock.unlock()
        if !isOver { stop() }
    }

    /// SIGTERM to the group, and SIGKILL a second on if the tool is still there.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard pid > 0, !isReaped, !isStopping else { return }
        isStopping = true
        killpg(pid, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
            lock.lock()
            defer { lock.unlock() }
            if !isReaped { killpg(pid, SIGKILL) }
        }
    }

    func terminateNow() {
        lock.lock()
        defer { lock.unlock() }
        if pid > 0, !isReaped { killpg(pid, SIGTERM) }
    }
}
