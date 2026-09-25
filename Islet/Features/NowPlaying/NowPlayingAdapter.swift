import Foundation

/// Talks to the system's now-playing session through the bundled mediaremote-adapter.
///
/// Since macOS 15.4 MediaRemote only answers Apple's own processes, so the adapter
/// framework is loaded by `/usr/bin/perl` (which qualifies) and reports on stdout as
/// JSON lines. One long-lived process streams changes; each command is a short-lived
/// process of its own.
///
/// Everything mutable is confined to `queue`. Snapshots are delivered on the main
/// queue.
final class NowPlayingAdapter: @unchecked Sendable {
    private let perl = URL(fileURLWithPath: "/usr/bin/perl")
    private let script: URL
    private let framework: URL
    private let queue = DispatchQueue(label: "com.ayush.Islet.nowPlaying", qos: .utility)

    private var onUpdate: (@Sendable (NowPlayingSnapshot?) -> Void)?
    private var stream: Process?
    private var reader: DispatchSourceRead?
    private var parser = NowPlayingStreamParser()
    /// Bumped for every stream launched and on stop, so callbacks from a process
    /// that has since been replaced are ignored.
    private var generation = 0
    private var launchedAt = Date.distantPast
    private var failures = 0
    private var restartWork: DispatchWorkItem?
    private var emptyWork: DispatchWorkItem?
    private var commands: Set<Process> = []

    /// Consecutive early exits before giving up: the adapter may be broken for good
    /// on this system, and relaunching it forever would only burn CPU.
    private static let maxFailures = 6
    /// A stream that ran this long was healthy, so its exit starts the count afresh.
    private static let healthyRun: TimeInterval = 60
    /// "Nothing playing" is held back this long. The stream reports an empty state
    /// whenever it starts, and in passing when a player hands over to another.
    private static let emptyDelay: TimeInterval = 0.6

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

    /// Starts streaming. `onUpdate` receives each new state on the main queue, `nil`
    /// meaning nothing is playing.
    func startStream(onUpdate: @escaping @Sendable (NowPlayingSnapshot?) -> Void) {
        queue.async { [self] in
            self.onUpdate = onUpdate
            failures = 0
            launch()
        }
    }

    /// Stops the stream and any commands still running. Synchronous, so the child
    /// processes are gone before the app quits.
    func stop() {
        queue.sync {
            onUpdate = nil
            generation += 1
            restartWork?.cancel()
            restartWork = nil
            emptyWork?.cancel()
            emptyWork = nil
            terminateStream()
            for command in commands where command.isRunning {
                command.terminate()
            }
            commands.removeAll()
        }
    }

    private func launch() {
        guard onUpdate != nil else { return }
        terminateStream()
        generation += 1
        let generation = self.generation
        parser = NowPlayingStreamParser()

        let process = Process()
        process.executableURL = perl
        // --micros: exact timestamps; the default ISO 8601 ones are whole seconds, so
        //   the extrapolated position could be up to a second out.
        // --debounce: players often report a track in several quick steps.
        process.arguments = [script.path, framework.path, "stream", "--micros", "--debounce=60"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.streamExited(generation: generation) }
        }

        // Stamped before launching, so a launch that fails at once counts as an early
        // exit and the backoff grows.
        launchedAt = Date()
        do {
            try process.run()
        } catch {
            streamExited(generation: generation)
            return
        }
        stream = process

        // Read on this queue with plain read(2): closing the pipe from here can then
        // never race a read in progress, which FileHandle turns into an exception.
        let output = pipe.fileHandleForReading
        let descriptor = output.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.read(descriptor, generation: generation)
        }
        source.setCancelHandler {
            // Closing the read end also stops a child that ignores SIGTERM: its next
            // write fails.
            try? output.close()
        }
        reader = source
        source.resume()
    }

    private func terminateStream() {
        reader?.cancel()
        reader = nil
        if let process = stream, process.isRunning { process.terminate() }
        stream = nil
    }

    private func read(_ descriptor: Int32, generation: Int) {
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        // Always drain, so a source can never spin on data nobody takes.
        guard generation == self.generation else { return }
        if count > 0 {
            if parser.consume(Data(chunk[..<count])) { emit(parser.snapshot()) }
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
            // End of file. The termination handler decides whether to relaunch.
            reader?.cancel()
            reader = nil
        }
    }

    private func streamExited(generation: Int) {
        guard generation == self.generation, onUpdate != nil else { return }
        terminateStream()
        if Date().timeIntervalSince(launchedAt) > Self.healthyRun { failures = 0 }
        failures += 1
        guard failures <= Self.maxFailures else {
            emit(nil)
            return
        }
        // 1, 2, 4 … 32 s.
        let delay = pow(2, Double(failures - 1))
        let work = DispatchWorkItem { [weak self] in
            self?.restartWork = nil
            self?.launch()
        }
        restartWork = work
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

    // MARK: Commands

    func perform(_ command: NowPlayingCommand) {
        switch command {
        case .togglePlayPause: run(["send", "2"])
        case .next: run(["send", "4"])
        case .previous: run(["send", "5"])
        case .seek(let seconds): run(["seek", String(Int64(max(0, seconds) * 1_000_000))])
        case .jumpBack: run(["send", "12"])
        case .jumpForward: run(["send", "13"])
        case .shuffle(let mode): run(["shuffle", String(mode.rawValue)])
        case .repeatMode(let mode): run(["repeat", String(mode.rawValue)])
        }
    }

    private func run(_ arguments: [String]) {
        queue.async { [self] in
            let process = Process()
            process.executableURL = perl
            process.arguments = [script.path, framework.path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            // Kept until it exits so it can be reaped, and terminated by stop().
            process.terminationHandler = { [weak self] process in
                self?.queue.async { self?.commands.remove(process) }
            }
            guard (try? process.run()) != nil else { return }
            commands.insert(process)
        }
    }
}

/// Turns the adapter's stdout into snapshots.
///
/// Each line is `{"type":"data","diff":Bool,"payload":{…}}`. A full payload replaces
/// the state; a diff is merged into it, a `null` value meaning the key is gone. Lines
/// carrying artwork run to hundreds of kilobytes, so bytes are buffered and split on
/// newlines before any decoding.
struct NowPlayingStreamParser {
    private var buffer = Data()
    /// How far into `buffer` has been searched for a newline already.
    private var scanned = 0
    private var state: [String: Any] = [:]
    private var artworkSource: String?
    private var artwork: NowPlayingArtwork?

    /// A line longer than this is not the adapter talking; drop it.
    private static let maxLine = 32 << 20

    /// Takes the next chunk of output. Returns whether any complete line changed
    /// the state.
    mutating func consume(_ data: Data) -> Bool {
        buffer.append(data)
        var changed = false
        var start = buffer.startIndex
        var searchFrom = buffer.startIndex + scanned
        while let newline = buffer[searchFrom...].firstIndex(of: 0x0A) {
            if newline > start, apply(line: buffer[start..<newline]) { changed = true }
            start = newline + 1
            searchFrom = start
        }
        buffer = start == buffer.startIndex ? buffer : Data(buffer[start...])
        scanned = buffer.count
        if buffer.count > Self.maxLine {
            buffer.removeAll()
            scanned = 0
        }
        return changed
    }

    private mutating func apply(line: Data) -> Bool {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              message["type"] as? String == "data",
              let payload = message["payload"] as? [String: Any]
        else { return false }

        let previous = state
        if message["diff"] as? Bool == true {
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
        return true
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
