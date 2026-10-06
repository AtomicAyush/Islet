import Darwin
import Foundation

/// macOS's floating thumbnail, kept off while Islet runs with Show screenshots here at
/// once on and the Screenshots feature on, and back as usual whenever it is not.
///
/// The switch is Islet's own setting (`ScreenshotsPrefs.showsAtOnce`). macOS's is written
/// to match only while the switch and the feature are both on: at launch, and when either
/// is turned on. It is taken away again when either is turned off, and when Islet quits,
/// from its menu, by SIGTERM (`TerminationSignal`) or as the Mac logs out, restarts or
/// shuts down; sudden termination is turned off meanwhile, so macOS always asks. Should
/// Islet stop with no chance to put it back (a crash, SIGKILL, Force Quit), its keeper
/// does (`FloatingThumbnailKeeper`): a process of its own that sleeps on a pipe only
/// Islet holds the other end of, and wakes when that end closes, however Islet went.
///
/// Every Islet that holds the thumbnail off is listed (`FloatingThumbnailHolders`), and
/// the thumbnail comes back only when the last of them lets go. Whichever order an old
/// Islet's putting it back and a new one's turning it off come in, as when one is
/// replaced by `install.sh`, it ends off while the new one runs; and a second Islet
/// quitting leaves the first's alone.
///
/// The thumbnail turned back on elsewhere (Show Floating Thumbnail under Options in the
/// Screenshot app) is not fought over: it is taken as the switch turned off. It is looked
/// for whenever Islet reads the settings anyway (`recheck()`), never on a timer, and as
/// it lets go, or its keeper does for it, so the next launch does not turn it off again.
///
/// All of it is done off the main thread, one thing at a time, in the order asked;
/// `stop()` alone waits, so that a quitting Islet has put the thumbnail back before it goes.
final class FloatingThumbnail: @unchecked Sendable {
    let defaults: UserDefaults
    private let settings: ScreenshotSettingsStore
    private let holders: FloatingThumbnailHolders
    private let keeper: FloatingThumbnailKeeper?
    /// This Islet, as the holders list it.
    private let holder = FloatingThumbnailHolders.Holder.current
    private let queue = DispatchQueue(label: "Islet.FloatingThumbnail", qos: .userInitiated)
    // Confined to `queue`.
    private var isFeatureOn = false
    /// Listed among the holders, with macOS's thumbnail written off.
    private var isHolding = false
    /// The switch was taken over at this launch from macOS's thumbnail, which was off.
    private var adopted = false
    private var running: FloatingThumbnailKeeper.Running?

    /// Tests give a stand-in for the Screenshot app's settings, defaults and a holders
    /// file of their own, and their own executable as the keeper, or none.
    init(
        settings: ScreenshotSettingsStore = .system,
        defaults: UserDefaults = .standard,
        holders: FloatingThumbnailHolders = .standard,
        keeper: FloatingThumbnailKeeper? = .islet
    ) {
        self.settings = settings
        self.defaults = defaults
        self.holders = holders
        self.keeper = keeper
    }

    /// Whether the switch is on.
    var showsAtOnce: Bool {
        defaults.bool(forKey: ScreenshotsPrefs.showsAtOnce)
    }

    /// At launch, whether the feature is on or not. The first time, the switch is taken
    /// over from macOS's setting, so a thumbnail turned off by an earlier Islet stays off;
    /// and a thumbnail left off by an Islet that went with its keeper is put back.
    func launched() {
        queue.async { [self] in
            settle()
            guard !isHolding else { return }
            holders.release(nil, anyway: adopted) { settings.restoreThumbnail() }
        }
    }

    /// The feature turned on.
    func start() {
        queue.async { [self] in
            isFeatureOn = true
            settle()
        }
    }

    /// The feature turned off, or Islet quitting: waits until the thumbnail is back.
    func stop() {
        queue.sync {
            isFeatureOn = false
            settle()
        }
    }

    /// The switch clicked. `done` is called on the main thread once macOS's setting has
    /// been changed to match.
    @MainActor
    func setShowsAtOnce(_ atOnce: Bool, then done: @escaping @MainActor () -> Void = {}) {
        defaults.set(atOnce, forKey: ScreenshotsPrefs.showsAtOnce)
        queue.async { [self] in
            settle()
            DispatchQueue.main.async { MainActor.assumeIsolated(done) }
        }
    }

    /// Looks whether the thumbnail held off has been turned back on elsewhere, and if so
    /// turns the switch off to match, leaving macOS's setting as it was made. Called when
    /// the settings are read anyway: for Settings, as Islet becomes active, and as a
    /// screenshot arrives.
    func recheck() {
        queue.async { [self] in
            guard isHolding, !settings.thumbnailIsOff() else { return }
            IslandLog.app.notice("Screenshot thumbnail turned back on elsewhere: Show screenshots here at once is off")
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated { setShowsAtOnce(false) }
            }
        }
    }

    /// Waits for everything asked so far to be done: for tests.
    func settled() {
        queue.sync {}
    }

    /// The keeper's process while there is one: for tests.
    var keeperProcess: pid_t? {
        queue.sync { running?.pid }
    }

    private func settle() {
        adoptIfNeeded()
        let wanted = isFeatureOn && showsAtOnce
        if wanted, !isHolding {
            hold()
        } else if !wanted, isHolding {
            release()
        }
    }

    /// The switch, the first time this Islet runs with one of its own: on if macOS's
    /// thumbnail is off, as the switch of earlier Islets left it.
    private func adoptIfNeeded() {
        guard defaults.object(forKey: ScreenshotsPrefs.showsAtOnce) == nil else { return }
        adopted = settings.thumbnailIsOff()
        defaults.set(adopted, forKey: ScreenshotsPrefs.showsAtOnce)
    }

    /// The keeper first, and Islet listed, so the thumbnail is never off without one to
    /// put it back; then the keeper is told it is off.
    private func hold() {
        running = keeper?.start(holder: holder, holders: holders)
        holders.hold(holder) { settings.turnThumbnailOff() }
        running?.held()
        isHolding = true
        ProcessInfo.processInfo.disableSuddenTermination()
    }

    /// Lets go, and then lets the keeper go, telling it so: it exits touching nothing.
    /// A thumbnail turned back on elsewhere, not yet noticed, turns the switch off.
    private func release() {
        if showsAtOnce, !settings.thumbnailIsOff() {
            IslandLog.app.notice("Screenshot thumbnail turned back on elsewhere: Show screenshots here at once is off")
            defaults.set(false, forKey: ScreenshotsPrefs.showsAtOnce)
        }
        running?.releasing()
        holders.release(holder, anyway: true) { settings.restoreThumbnail() }
        isHolding = false
        running?.released()
        running = nil
        ProcessInfo.processInfo.enableSuddenTermination()
    }
}

/// What puts macOS's floating thumbnail back when Islet could not: the thumbnail keeper,
/// a small tool of its own in Islet's bundle (`ThumbnailKeeper/main.swift`), which does
/// that and nothing else. It has no Dock icon or windows, a name of its own, so killing
/// Islet by name (`killall -9 Islet`) leaves it to do its work, and it is not one of the
/// tools Islet ends as it quits.
///
/// Its standard input is a pipe whose other end only Islet holds, so it sleeps in a read
/// that ends when that end closes, however Islet stops: the kernel closes it for a
/// process that crashed or was killed. It then lets go for that Islet
/// (`FloatingThumbnailHolders`), which puts the thumbnail back unless another Islet
/// still holds it, and exits. Islet letting go itself says so
/// (`FloatingThumbnailKeeperNote`), and the keeper exits touching nothing.
struct FloatingThumbnailKeeper: Sendable {
    /// The executable started as the keeper: Islet's, or a test's.
    let executable: URL?
    /// The Screenshot app's settings domain, or a test's own.
    let domain: String
    /// Islet's own defaults domain, and its switch there, which the keeper turns off for
    /// a thumbnail it finds turned back on elsewhere.
    let defaultsDomain: String
    let switchKey: String

    static let islet = FloatingThumbnailKeeper(
        executable: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ThumbnailKeeper"),
        domain: ScreenshotSettingsStore.systemDomain,
        defaultsDomain: Bundle.main.bundleIdentifier ?? "com.ayush.Islet",
        switchKey: ScreenshotsPrefs.showsAtOnce
    )

    /// A keeper started, and Islet's end of its pipe.
    final class Running: @unchecked Sendable {
        let pid: pid_t
        private let end: Int32

        init(pid: pid_t, end: Int32) {
            self.pid = pid
            self.end = end
        }

        /// Tells the keeper the thumbnail is now off.
        func held() {
            say(.held)
        }

        /// Tells the keeper Islet is letting go.
        func releasing() {
            say(.releasing)
        }

        /// Tells the keeper Islet has let go, and closes Islet's end, which ends it.
        func released() {
            say(.released)
            close(end)
        }

        /// One byte, which fits in the pipe whether the keeper is reading or not; written
        /// to a keeper that has gone, it is lost, with no SIGPIPE.
        private func say(_ note: FloatingThumbnailKeeperNote) {
            var byte = note.rawValue
            while write(end, &byte, 1) < 0, errno == EINTR {}
        }
    }

    /// Starts a keeper for `holder`; `nil` if it could not be started.
    func start(holder: FloatingThumbnailHolders.Holder, holders: FloatingThumbnailHolders) -> Running? {
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { return nil }
        // Islet's end stays out of every other process it starts, or one outliving it
        // would keep the keeper waiting.
        for fd in ends { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(ends[1], F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, ends[0], 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own group, out of reach of a ^C meant for Islet run from a terminal; nothing
        // open of Islet's but the pipe; the signals Islet handles, back to their defaults;
        // and those the keeper ignores held back until it does, so one sent as it starts
        // cannot end it.
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
        for signal in [SIGTERM, SIGINT, SIGHUP] { sigaddset(&mask, signal) }
        posix_spawnattr_setsigmask(&attributes, &mask)

        let path = executable.path
        let arguments = [path, domain, holders.file.path, holder.line, defaultsDomain, switchKey]
        let argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var child: pid_t = 0
        let spawned = posix_spawn(&child, path, &actions, &attributes, argv, environ)
        close(ends[0])
        guard spawned == 0 else {
            close(ends[1])
            IslandLog.app.error("Couldn't start the screenshot thumbnail's keeper: \(spawned)")
            return nil
        }
        // Collected when it exits, heard from the kernel rather than waited on.
        let ended = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .global(qos: .utility))
        ended.setEventHandler {
            _ = waitpid(child, nil, WNOHANG)
            ended.cancel()
        }
        ended.resume()
        return Running(pid: child, end: ends[1])
    }
}
