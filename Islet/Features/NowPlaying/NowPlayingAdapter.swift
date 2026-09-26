import Foundation

/// Talks to the system's now-playing sessions through the bundled mediaremote-adapter.
///
/// Since macOS 15.4 MediaRemote only answers Apple's own processes, so the adapter
/// framework is loaded by `/usr/bin/perl` (which qualifies) and reports on stdout as
/// JSON lines. Two long-lived processes stream changes: one to the session MediaRemote
/// has elected, one to the list of every session. They are kept apart because the
/// list leans on more of MediaRemote's private functions: should one of them be
/// missing or crash on some system, the list goes and the elected session's stream
/// carries on. Each command is a short-lived process of its own.
///
/// Everything mutable is confined to `queue`. Snapshots are delivered on the main
/// queue.
final class NowPlayingAdapter: @unchecked Sendable {
    private let perl = URL(fileURLWithPath: "/usr/bin/perl")
    private let script: URL
    private let framework: URL
    private let queue = DispatchQueue(label: "com.ayush.Islet.nowPlaying", qos: .utility)

    private var onUpdate: (@Sendable (NowPlayingSnapshot?) -> Void)?
    private var onSessions: (@Sendable (NowPlayingMediaRemoteSessions) -> Void)?
    /// The elected session's stream.
    private let stream = Channel(function: "stream")
    /// Every session, elected or not (a local change to the adapter, see its
    /// VENDORED.md).
    private let list = Channel(function: "sessions")
    private var emptyWork: DispatchWorkItem?
    private var commands: Set<Process> = []

    /// Consecutive early exits before giving up: the adapter may be broken for good
    /// on this system, and relaunching it forever would only burn CPU.
    private static let maxFailures = 6
    /// A process that ran this long was healthy, so its exit starts the count afresh.
    private static let healthyRun: TimeInterval = 60
    /// "Nothing playing" is held back this long. The stream reports an empty state
    /// whenever it starts, and in passing when a player hands over to another.
    private static let emptyDelay: TimeInterval = 0.6
    /// The list's exit status when this system's MediaRemote cannot list sessions
    /// (the adapter's `kMRAExitCannotListSessions`). Launching it again would only
    /// fail again, so the island does without it.
    static let cannotListStatus: Int32 = 13

    /// One long-lived adapter process and what it has said so far. Confined to
    /// `queue`, as the adapter is.
    private final class Channel: @unchecked Sendable {
        /// The adapter function it runs.
        let function: String
        var process: Process?
        var reader: DispatchSourceRead?
        var parser = NowPlayingStreamParser()
        /// Bumped for every process launched and on stop, so callbacks from one that
        /// has since been replaced are ignored.
        var generation = 0
        var launchedAt = Date.distantPast
        var failures = 0
        var restartWork: DispatchWorkItem?
        /// This process has printed the list whole at least once.
        var hasListed = false

        init(function: String) {
            self.function = function
        }
    }

    /// `nil` when the adapter is not in the app bundle; the feature then does nothing.
    init?(bundle: Bundle = .main) {
        guard let script = bundle.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let framework = bundle.url(forResource: "MediaRemoteAdapter", withExtension: "framework"),
              FileManager.default.isExecutableFile(atPath: perl.path)
        else { return nil }
        self.script = script
        self.framework = framework
    }

    // MARK: Stream

    /// Starts streaming. `onUpdate` receives each new state of the session MediaRemote
    /// has elected on the main queue, `nil` meaning nothing is playing; `onSessions`
    /// every session's, elected or not, each time the list changes, and an empty list
    /// when it cannot be had.
    func startStream(
        onUpdate: @escaping @Sendable (NowPlayingSnapshot?) -> Void,
        onSessions: @escaping @Sendable (NowPlayingMediaRemoteSessions) -> Void
    ) {
        queue.async { [self] in
            self.onUpdate = onUpdate
            self.onSessions = onSessions
            for channel in [stream, list] {
                channel.failures = 0
                launch(channel)
            }
        }
    }

    /// Stops the streams and any commands still running. Synchronous, so the child
    /// processes are gone before the app quits.
    func stop() {
        queue.sync {
            onUpdate = nil
            onSessions = nil
            for channel in [stream, list] {
                channel.generation += 1
                channel.restartWork?.cancel()
                channel.restartWork = nil
                terminate(channel)
            }
            emptyWork?.cancel()
            emptyWork = nil
            for command in commands where command.isRunning {
                command.terminate()
            }
            commands.removeAll()
        }
    }

    private func launch(_ channel: Channel) {
        guard onUpdate != nil else { return }
        terminate(channel)
        channel.generation += 1
        let generation = channel.generation
        channel.parser = NowPlayingStreamParser()
        channel.hasListed = false

        let process = Process()
        process.executableURL = perl
        // --micros: exact timestamps; the default ISO 8601 ones are whole seconds, so
        //   the extrapolated position could be up to a second out.
        // --debounce: players often report a track in several quick steps.
        process.arguments = [script.path, framework.path, channel.function, "--micros", "--debounce=60"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            // Stopped by a signal, a crash among them, is no exit status at all.
            let status = process.terminationReason == .exit ? process.terminationStatus : nil
            self?.queue.async { self?.exited(channel, generation: generation, status: status) }
        }

        // Stamped before launching, so a launch that fails at once counts as an early
        // exit and the backoff grows.
        channel.launchedAt = Date()
        do {
            try process.run()
        } catch {
            exited(channel, generation: generation, status: nil)
            return
        }
        channel.process = process

        // Read on this queue with plain read(2): closing the pipe from here can then
        // never race a read in progress, which FileHandle turns into an exception.
        let output = pipe.fileHandleForReading
        let descriptor = output.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.read(descriptor, from: channel, generation: generation)
        }
        source.setCancelHandler {
            // Closing the read end also stops a child that ignores SIGTERM: its next
            // write fails.
            try? output.close()
        }
        channel.reader = source
        source.resume()
    }

    private func terminate(_ channel: Channel) {
        channel.reader?.cancel()
        channel.reader = nil
        if let process = channel.process, process.isRunning { process.terminate() }
        channel.process = nil
    }

    private func read(_ descriptor: Int32, from channel: Channel, generation: Int) {
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        // Always drain, so a source can never spin on data nobody takes.
        guard generation == channel.generation else { return }
        if count > 0 {
            let changes = channel.parser.consume(Data(chunk[..<count]))
            if changes.contains(.system) { emit(channel.parser.snapshot()) }
            if changes.contains(.sessions) {
                channel.hasListed = true
                deliver(channel.parser.sessions())
            }
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
            // End of file. The termination handler decides whether to relaunch.
            channel.reader?.cancel()
            channel.reader = nil
        }
    }

    private func exited(_ channel: Channel, generation: Int, status: Int32?) {
        guard generation == channel.generation, onUpdate != nil else { return }
        terminate(channel)
        if channel === list {
            // A list the last process printed whole stands until the next one prints
            // its own; without one, nothing says which sessions are still there.
            if !channel.hasListed { deliver(NowPlayingMediaRemoteSessions()) }
            guard status != Self.cannotListStatus else { return }
        }
        if Date().timeIntervalSince(channel.launchedAt) > Self.healthyRun { channel.failures = 0 }
        channel.failures += 1
        guard channel.failures <= Self.maxFailures else {
            if channel === stream {
                emit(nil)
            } else {
                deliver(NowPlayingMediaRemoteSessions())
            }
            return
        }
        // 1, 2, 4 … 32 s.
        let delay = pow(2, Double(channel.failures - 1))
        let work = DispatchWorkItem { [weak self] in
            channel.restartWork = nil
            self?.launch(channel)
        }
        channel.restartWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func emit(_ snapshot: NowPlayingSnapshot?) {
        emptyWork?.cancel()
        emptyWork = nil
        guard let snapshot else {
            let work = DispatchWorkItem { [weak self] in
                self?.emptyWork = nil
                self?.deliver(nil)
            }
            emptyWork = work
            queue.asyncAfter(deadline: .now() + Self.emptyDelay, execute: work)
            return
        }
        deliver(snapshot)
    }

    private func deliver(_ snapshot: NowPlayingSnapshot?) {
        guard let onUpdate else { return }
        DispatchQueue.main.async { onUpdate(snapshot) }
    }

    private func deliver(_ sessions: NowPlayingMediaRemoteSessions) {
        guard let onSessions else { return }
        DispatchQueue.main.async { onSessions(sessions) }
    }

    // MARK: Commands

    /// Sends a command through MediaRemote, which delivers it to the app it has
    /// elected as now playing. With `app`, the adapter first checks that `app` is that
    /// one, and sends nothing if not. `completion` gets the outcome on the adapter's
    /// queue once the command's process has exited.
    func perform(
        _ command: NowPlayingCommand, onlyTo app: String?,
        completion: @escaping @Sendable (NowPlayingDelivery) -> Void
    ) {
        run(Self.arguments(for: command, onlyTo: app)) { status in
            completion(Self.delivery(exitStatus: status, checked: app != nil))
        }
    }

    /// The adapter's arguments for a command, after the script and framework paths.
    static func arguments(for command: NowPlayingCommand, onlyTo app: String?) -> [String] {
        var arguments: [String]
        switch command {
        case .togglePlayPause: arguments = ["send", "2"]
        case .next: arguments = ["send", "4"]
        case .previous: arguments = ["send", "5"]
        case .seek(let seconds): arguments = ["seek", String(Int64(max(0, seconds) * 1_000_000))]
        case .jumpBack: arguments = ["send", "12"]
        case .jumpForward: arguments = ["send", "13"]
        case .shuffle(let mode): arguments = ["shuffle", String(mode.rawValue)]
        case .repeatMode(let mode): arguments = ["repeat", String(mode.rawValue)]
        }
        if let app { arguments.append("--to=\(app)") }
        return arguments
    }

    /// What the command process's exit status says; `nil` when it could not be run.
    /// A checked command exits 10 when another app is now playing and 11 when none
    /// is, having sent nothing, and 12 when the framework cannot check, which leaves
    /// the plain send to try. Only 12 does: a checked command that could not even
    /// start fails, since the plain send after it is the one that could reach another
    /// app, and could not start either.
    static func delivery(exitStatus: Int32?, checked: Bool) -> NowPlayingDelivery {
        guard let exitStatus else { return checked ? .failed : .unavailable }
        switch (exitStatus, checked) {
        case (0, _): return .delivered
        case (10, true), (11, true): return .elsewhere
        case (12, true): return .unavailable
        default: return .failed
        }
    }

    private func run(_ arguments: [String], completion: @escaping @Sendable (Int32?) -> Void) {
        queue.async { [self] in
            let process = Process()
            process.executableURL = perl
            process.arguments = [script.path, framework.path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            // Kept until it exits so it can be reaped, and terminated by stop().
            process.terminationHandler = { [weak self] process in
                // Stopped by a signal (stop() terminates it) is no exit status at all.
                let status = process.terminationReason == .exit ? process.terminationStatus : -1
                guard let self else { return completion(status) }
                self.queue.async {
                    self.commands.remove(process)
                    completion(status)
                }
            }
            guard (try? process.run()) != nil else {
                completion(nil)
                return
            }
            commands.insert(process)
        }
    }
}

/// MediaRemote's sessions for every app, not only the one it has elected, as the
/// adapter lists them: one per app.
struct NowPlayingMediaRemoteSessions: Sendable {
    /// By app: the browser rather than its helper process for web media.
    var snapshots: [String: NowPlayingSnapshot] = [:]
    /// The app MediaRemote delivers commands to, as the list last found it.
    var elected: String?

    /// Which of two sessions of one app to show, as with two tabs playing in one
    /// browser: one that plays over one that does not, then the one MediaRemote has
    /// elected, then the one reported most recently.
    static func prefers(
        _ candidate: NowPlayingSnapshot, elected candidateIsElected: Bool,
        over other: NowPlayingSnapshot, elected otherIsElected: Bool
    ) -> Bool {
        if candidate.isPlaying != other.isPlaying { return candidate.isPlaying }
        if candidateIsElected != otherIsElected { return candidateIsElected }
        return candidate.timing.timestamp > other.timing.timestamp
    }
}

/// Turns the adapter's stdout into snapshots: the elected session's from the stream's
/// lines, and every session's from the list's.
///
/// A stream line is `{"type":"data","diff":Bool,"payload":{…}}`; a list line is the
/// same with `"type":"session"` and the session's `"id"`, and
/// `{"type":"sessionEnded","id":…}` says one is gone. A full payload replaces the
/// state; a diff is merged into it, a `null` value meaning the key is gone. The list
/// counts as changed only at `{"type":"sessionsListed"}`, which ends each of its
/// readings: a reading's lines can arrive in several chunks, and the sessions in an
/// early one alone are not the list. Lines carrying artwork run to hundreds of
/// kilobytes, so bytes are buffered and split on newlines before any decoding.
struct NowPlayingStreamParser {
    /// Which states a chunk of output changed.
    struct Changes: OptionSet {
        let rawValue: Int

        /// The session MediaRemote has elected, from the stream's own lines.
        static let system = Changes(rawValue: 1 << 0)
        /// The list of every session, read whole.
        static let sessions = Changes(rawValue: 1 << 1)
    }

    private var buffer = Data()
    /// How far into `buffer` has been searched for a newline already.
    private var scanned = 0
    private var system = NowPlayingPayloadState()
    /// Each session in the list by the adapter's id for it, its process and bundle.
    private var listed: [String: NowPlayingPayloadState] = [:]

    /// A line longer than this is not the adapter talking; drop it.
    private static let maxLine = 32 << 20

    /// Takes the next chunk of output. Returns which states its complete lines
    /// changed.
    mutating func consume(_ data: Data) -> Changes {
        buffer.append(data)
        var changes: Changes = []
        var start = buffer.startIndex
        var searchFrom = buffer.startIndex + scanned
        while let newline = buffer[searchFrom...].firstIndex(of: 0x0A) {
            if newline > start { changes.formUnion(apply(line: buffer[start..<newline])) }
            start = newline + 1
            searchFrom = start
        }
        buffer = start == buffer.startIndex ? buffer : Data(buffer[start...])
        scanned = buffer.count
        if buffer.count > Self.maxLine {
            buffer.removeAll()
            scanned = 0
        }
        return changes
    }

    private mutating func apply(line: Data) -> Changes {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return [] }
        let diff = message["diff"] as? Bool == true
        switch message["type"] as? String {
        case "data":
            guard let payload = message["payload"] as? [String: Any] else { return [] }
            system.apply(payload, diff: diff)
            return .system
        case "session":
            guard let id = message["id"] as? String, let payload = message["payload"] as? [String: Any] else { return [] }
            listed[id, default: NowPlayingPayloadState()].apply(payload, diff: diff)
            return []
        case "sessionEnded":
            if let id = message["id"] as? String { listed.removeValue(forKey: id) }
            return []
        case "sessionsListed":
            return .sessions
        default:
            return []
        }
    }

    /// The elected session's state, or `nil` when no player is reporting. Decodes new
    /// artwork, so call it off the main thread.
    mutating func snapshot() -> NowPlayingSnapshot? {
        system.snapshot()
    }

    /// Every listed session, one per app (see `NowPlayingMediaRemoteSessions.prefers`).
    /// Decodes new artwork, so call it off the main thread. A session without an app
    /// is left out: only the elected one can be unnamed, and the stream has it.
    mutating func sessions() -> NowPlayingMediaRemoteSessions {
        var result = NowPlayingMediaRemoteSessions()
        var electedApps: Set<String> = []
        for id in listed.keys.sorted() {
            guard let snapshot = listed[id]?.snapshot(), let app = snapshot.track.bundleID else { continue }
            let isElected = listed[id]?.isElected == true
            if isElected { result.elected = app }
            if let other = result.snapshots[app], !NowPlayingMediaRemoteSessions.prefers(
                snapshot, elected: isElected, over: other, elected: electedApps.contains(app)
            ) { continue }
            result.snapshots[app] = snapshot
            if isElected { electedApps.insert(app) } else { electedApps.remove(app) }
        }
        return result
    }
}

/// One session's state as the adapter reports it, full payloads and diffs merged,
/// and the snapshot it makes.
struct NowPlayingPayloadState {
    private var state: [String: Any] = [:]
    private var artworkSource: String?
    private var artwork: NowPlayingArtwork?

    /// MediaRemote delivers commands to this session's app, as the list says; the
    /// stream's own lines never say.
    var isElected: Bool { state[Key.elected] as? Bool ?? false }

    mutating func apply(_ payload: [String: Any], diff: Bool) {
        let previous = state
        if diff {
            for (key, value) in payload {
                state[key] = value is NSNull ? nil : value
            }
        } else {
            state = payload
        }
        let now = Date().timeIntervalSince1970 * 1_000_000
        let elapsed = number(state[Key.elapsed])
        let moved = elapsed != number(previous[Key.elapsed])
        let sameItem = [Key.title, Key.artist, Key.album, Key.bundle, Key.parentBundle].allSatisfy {
            state[$0] as? String == previous[$0] as? String
        }
        if elapsed != nil, state[Key.timestamp] == nil {
            // A player that sends no timestamp: an unchanged position keeps the stamp
            // it had, or a full re-send would snap it back to where it was reported —
            // but only for the same item; a new track at the same position is new.
            state[Key.timestamp] = moved || !sameItem ? now : previous[Key.timestamp] ?? now
        } else if moved, number(state[Key.timestamp]) == number(previous[Key.timestamp]) {
            // A new position without a new timestamp was true when it arrived.
            state[Key.timestamp] = now
        }
        reanchorIfNeeded(previous: previous)
    }

    /// When playback starts or stops, the player's new position often arrives in a
    /// later line than the play state, and some players never send it. Until it
    /// does, carry on from where the old reading had got to, so a pause freezes the
    /// position where it happened rather than where it was last reported.
    private mutating func reanchorIfNeeded(previous: [String: Any]) {
        let wasPlaying = previous[Key.playing] as? Bool ?? false
        let isPlaying = state[Key.playing] as? Bool ?? false
        guard wasPlaying != isPlaying,
              state[Key.title] as? String == previous[Key.title] as? String,
              let elapsed = number(state[Key.elapsed]), elapsed == number(previous[Key.elapsed]),
              number(state[Key.timestamp]) == number(previous[Key.timestamp])
        else { return }
        let now = Date()
        state[Key.elapsed] = Self.timing(from: previous).position(at: now) * 1_000_000
        state[Key.timestamp] = now.timeIntervalSince1970 * 1_000_000
    }

    /// The current state, or `nil` when no player is reporting. Decodes new artwork,
    /// so call it off the main thread.
    mutating func snapshot() -> NowPlayingSnapshot? {
        guard let title = state[Key.title] as? String, !title.isEmpty else { return nil }

        let encoded = state[Key.artwork] as? String
        if encoded != artworkSource {
            artworkSource = encoded
            artwork = encoded.flatMap(NowPlayingArtwork.decode(base64:))
        }

        let reportedRate = number(state[Key.rate])
        let bundleID = state[Key.parentBundle] as? String ?? state[Key.bundle] as? String
        return NowPlayingSnapshot(
            track: NowPlayingTrack(
                title: title,
                artist: state[Key.artist] as? String ?? "",
                album: state[Key.album] as? String ?? "",
                bundleID: bundleID
            ),
            isPlaying: state[Key.playing] as? Bool ?? false,
            timing: Self.timing(from: state),
            speed: reportedRate.flatMap { $0 > 0 ? $0 : nil } ?? 1,
            artwork: artwork,
            isVideo: NowPlayingVideo.isVideo(
                mediaType: state[Key.mediaType] as? String,
                bundleID: bundleID,
                artworkAspect: artwork?.aspectRatio
            ),
            // 0 is MediaRemote's "unknown", which gets no toggle either.
            shuffle: integer(state[Key.shuffle]).flatMap(NowPlayingShuffle.init(rawValue:)),
            repeatMode: integer(state[Key.repeatMode]).flatMap(NowPlayingRepeat.init(rawValue:)),
            jumpsBack: state[Key.jumpsBack] as? Bool ?? false,
            jumpsForward: state[Key.jumpsForward] as? Bool ?? false
        )
    }

    /// Players can report playing with a rate of 0 for a moment (buffering), so the
    /// position only moves when both say it does, and never for a player that
    /// reports no position at all.
    private static func timing(from state: [String: Any]) -> NowPlayingTiming {
        let elapsed = number(state[Key.elapsed])
        let playing = state[Key.playing] as? Bool ?? false
        let rate = playing && elapsed != nil ? (number(state[Key.rate]) ?? 1) : 0
        return NowPlayingTiming(
            elapsed: (elapsed ?? 0) / 1_000_000,
            timestamp: number(state[Key.timestamp]).map { Date(timeIntervalSince1970: $0 / 1_000_000) } ?? Date(),
            rate: max(0, rate),
            duration: (number(state[Key.duration]) ?? 0) / 1_000_000
        )
    }

    private enum Key {
        static let title = "title"
        static let artist = "artist"
        static let album = "album"
        static let bundle = "bundleIdentifier"
        static let parentBundle = "parentApplicationBundleIdentifier"
        static let playing = "playing"
        static let rate = "playbackRate"
        static let elapsed = "elapsedTimeMicros"
        static let timestamp = "timestampEpochMicros"
        static let duration = "durationMicros"
        static let artwork = "artworkData"
        static let mediaType = "mediaType"
        static let shuffle = "shuffleMode"
        static let repeatMode = "repeatMode"
        static let jumpsBack = "supportsRewind15Seconds"
        static let jumpsForward = "supportsFastForward15Seconds"
        static let elected = "elected"
    }
}

private func number(_ value: Any?) -> Double? {
    (value as? NSNumber)?.doubleValue
}

/// A whole number, or `nil`. `Int(_:)` would trap on a fraction or anything out of
/// range, and a player can put whatever it likes in the payload.
private func integer(_ value: Any?) -> Int? {
    number(value).flatMap { Int(exactly: $0) }
}
