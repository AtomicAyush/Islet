import AppKit
import CoreAudio
import Darwin

/// Puts a process down to the app it works for, so a sensor in use is named after
/// the app the person knows rather than a helper they have never heard of.
///
/// macOS records which app is responsible for every process it launches: WebKit's
/// GPU process for Safari (or Notes, or whichever app shows web content), a helper for
/// Chrome or any Electron app, a command-line tool for the terminal it runs in. That
/// settles most. Failing it, a process inside an app's bundle belongs to that app.
/// FaceTime's calls run in a daemon of their own, which is named for FaceTime.
/// Anything else is left unnamed rather than named after a daemon.
enum PrivacyAppResolver {
    private typealias ResponsiblePID = @convention(c) (pid_t) -> pid_t

    /// Not public API, so looked up rather than linked; without it the bundle paths
    /// still place helpers that live inside their app.
    private static let responsiblePID: ResponsiblePID? = {
        let everywhere = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let pointer = dlsym(everywhere, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(pointer, to: ResponsiblePID.self)
    }()

    /// Daemons that work for one app and are responsible for themselves.
    private static let daemonApps = [
        "/usr/libexec/avconferenced": "/System/Applications/FaceTime.app",
    ]

    /// The app a running process works for. `executablePath` stands in for the
    /// process's own path when the process may have gone already.
    static func app(pid: pid_t, executablePath: String? = nil) -> PrivacyApp? {
        guard pid > 0 else { return executablePath.flatMap(app(path:)) }
        let responsible = responsiblePID.map { $0(pid) }.flatMap { $0 > 0 ? $0 : nil } ?? pid
        if responsible != pid, let app = bundledApp(of: responsible) { return app }
        if let app = bundledApp(of: pid) { return app }
        if let path = executablePath, let app = app(path: path) { return app }
        return nil
    }

    /// The app a path belongs to: the outermost app bundle it lies in, or the app a
    /// daemon works for.
    static func app(path: String) -> PrivacyApp? {
        if let bundle = outermostAppBundle(in: path) { return PrivacyApp(bundlePath: bundle) }
        if let bundle = daemonApps[path] { return PrivacyApp(bundlePath: bundle) }
        return nil
    }

    /// An app by its bundle identifier, as Control Center names them. A helper app
    /// nested in another counts as the outer one.
    static func app(bundleIdentifier: String) -> PrivacyApp? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        return app(path: url.path)
    }

    private static func bundledApp(of pid: pid_t) -> PrivacyApp? {
        let paths = [NSRunningApplication(processIdentifier: pid)?.bundleURL?.path, executablePath(of: pid)]
        for case let path? in paths {
            if let app = app(path: path) { return app }
        }
        return nil
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    /// When the process now holding `pid` started, or `nil` where there is none. A
    /// line logged before then came from an earlier process that held the same pid.
    static func startDate(of pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    /// The outermost `.app` in a path, so a helper, an XPC service or an extension
    /// counts as its app.
    static func outermostAppBundle(in path: String) -> String? {
        var prefix = ""
        for component in path.split(separator: "/") {
            prefix += "/" + component
            if component.hasSuffix(".app") { return prefix }
        }
        return nil
    }
}

/// What the log has named, for `PrivacyMonitor` to put beside what the system says is
/// in use.
struct PrivacyNames: Equatable, Sendable {
    /// A process the audio server reports recording, a microphone or what the Mac
    /// plays; which, only Core Audio can say.
    struct Recorder: Equatable, Sendable {
        var pid: pid_t
        var app: PrivacyApp?
    }

    /// Apps streaming from a camera.
    var camera: [PrivacyApp] = []
    /// Apps capturing the screen through macOS's capture service.
    var screen: [PrivacyApp] = []
    /// Whether all the capture service is doing with the screen is what macOS leaves
    /// unmarked, such as AirPlay's mirroring, though WindowServer counts it as a
    /// capture all the same.
    var screenUnmarked = false
    /// Apps recording what the Mac plays, or the microphone, through the same service,
    /// which the audio server then reports as its own.
    var capturedAudio: [PrivacyApp] = []
    var capturedMicrophone: [PrivacyApp] = []
    /// The processes the audio server reports recording that Core Audio agrees are.
    var recorders: [Recorder] = []
    /// Location as the menu bar's arrow shows it, and who it is for.
    var location = PrivacyUse()
    /// What Control Center itself lists as in use, to name what nothing else can.
    var controlCenter: [PrivacyMonitor.Sensor: [PrivacyApp]] = [:]
}

// MARK: - Camera

/// The processes streaming from a camera, as they log it themselves: CoreMediaIO
/// writes a line from inside every process that starts or stops a camera stream, so
/// the line's own process is the client.
///
/// A client can start, stop and start again within a few milliseconds while it sets
/// up, and the camera's own "off" can reach Islet after the second start's line. So
/// the camera going off clears only clients that started before it went off, not every
/// client. A process is known by its pid and the pid's version, which changes if the
/// pid is reused; a version of 0 is a line whose version could not be read, which
/// matches any.
struct PrivacyCameraClients: Equatable {
    struct Client: Equatable {
        var version: UInt32
        /// The streams it started and has not stopped, as "device stream" pairs. A
        /// process can run two cameras at once.
        var streams: [String]
        var lastStart: Date
        var app: PrivacyApp?
    }

    private(set) var clients: [pid_t: Client] = [:]

    var isEmpty: Bool { clients.isEmpty }
    var pids: Set<pid_t> { Set(clients.keys) }

    /// The clients' apps, the earliest first, each once.
    var apps: [PrivacyApp] {
        var apps: [PrivacyApp] = []
        for client in clients.values.sorted(by: { $0.lastStart < $1.lastStart }) {
            if let app = client.app, !apps.contains(app) { apps.append(app) }
        }
        return apps
    }

    mutating func started(pid: pid_t, version: UInt32, stream: String, at date: Date, app: PrivacyApp?) {
        var client = clients[pid] ?? Client(version: version, streams: [], lastStart: date, app: app)
        if client.version != version, client.version != 0, version != 0 {
            // The pid was reused: the process that had it is gone.
            client = Client(version: version, streams: [], lastStart: date, app: app)
        }
        client.streams.append(stream)
        client.lastStart = max(client.lastStart, date)
        if client.version == 0 { client.version = version }
        if client.app == nil { client.app = app }
        clients[pid] = client
    }

    mutating func stopped(pid: pid_t, version: UInt32, stream: String) {
        guard var client = clients[pid] else { return }
        guard client.version == version || client.version == 0 || version == 0 else { return }
        if let index = client.streams.firstIndex(of: stream) {
            client.streams.remove(at: index)
        } else {
            // A stop for a stream it was not seen starting: the log dropped a line, or
            // the stream began before Islet was watching.
            client.streams.removeAll()
        }
        clients[pid] = client.streams.isEmpty ? nil : client
    }

    mutating func exited(pid: pid_t) {
        clients[pid] = nil
    }

    /// Every camera went off at `date`: clients that started before then are done.
    mutating func cameraOff(at date: Date) {
        clients = clients.filter { $0.value.lastStart > date }
    }
}

// MARK: - Screen and system audio

/// Who macOS's capture service (replayd, behind ScreenCaptureKit and the screenshot
/// tools) is capturing for.
///
/// The service logs each capture starting and stopping, but not for whom. Before a
/// capture starts it checks the client's permission, and the permission daemon logs
/// that check with the client's process and the app responsible for it; the newest such
/// check before the start names it. Failing that, the newest client to connect does,
/// though a client that connected long before (Control Center, FaceTime, anything that
/// only watches) says nothing and is not used.
///
/// A stop does not say whose capture stopped either. Captures rarely overlap; when
/// they do, the newest is taken to stop first. A client that quits is dropped
/// whatever the log said, and the stop the service logs for it afterwards is then
/// owed, rather than taken from a capture still running: a screenshot tool is often
/// gone before its stop arrives.
///
/// Some captures macOS leaves unmarked: AirPlay's screen mirroring has the service let
/// its client hide the indicator, and the service says so in place of a start or a
/// stop. WindowServer counts it as a capture all the same. So while nothing marked is
/// running and an unmarked capture started or stopped since WindowServer's flag went
/// on, the flag stands for that alone, and the screen counts as not captured, as macOS
/// shows it.
struct PrivacyCaptureClients: Equatable {
    enum Kind: Hashable, Sendable {
        /// The screen, or a window on it.
        case screen
        /// What the Mac plays.
        case audio
        /// The microphone, through the capture service rather than directly.
        case microphone
    }

    struct Client: Equatable {
        var pid: pid_t?
        var app: PrivacyApp?
        var date: Date
        /// Named by a permission check, rather than guessed from a connection.
        var checked = false
    }

    private(set) var screen: [Client] = []
    private(set) var audio: [Client] = []
    private(set) var microphone: [Client] = []
    /// Recent permission checks the capture service made, and recent connections to
    /// it, newest last.
    private var checks: [Client] = []
    private var connections: [Client] = []
    /// Stops the service still owes for captures dropped because their client quit:
    /// when each client quit, by kind.
    private var owedStops: [Kind: [Date]] = [:]
    /// When WindowServer's flag went on, while it is on; `nil` while it is off, and
    /// where it was on already when watching began.
    private var flagOnSince: Date?
    /// The newest unmarked screen capture starting or stopping, and the newest marked
    /// one.
    private var unmarkedAt: Date?
    private var screenChangedAt: Date?

    /// How long before a start a permission check or a connection still names it.
    static let window: TimeInterval = 1.5
    /// How long after a start an unnamed capture may still be named by a check that
    /// reached Islet late.
    static let lateCheck: TimeInterval = 0.5
    /// How long a client that quit owes its stop.
    static let owedStopTime: TimeInterval = 5
    /// How long before WindowServer's flag is seen going on an unmarked capture may
    /// have set it: the flag is read every couple of seconds where WindowServer's
    /// notifications do not arrive.
    static let flagLead: TimeInterval = PrivacyScreenWatcher.pollInterval + 2

    var pids: Set<pid_t> {
        Set((screen + audio + microphone).compactMap(\.pid))
    }

    func apps(_ kind: Kind) -> [PrivacyApp] {
        var apps: [PrivacyApp] = []
        for client in self[kind] {
            if let app = client.app, !apps.contains(app) { apps.append(app) }
        }
        return apps
    }

    /// Whether the screen is captured only by what macOS leaves unmarked, so far as
    /// the capture service says: nothing marked is running, and an unmarked capture
    /// started or stopped since WindowServer's flag went on. Where the flag was on
    /// already when watching began, an unmarked capture being the service's latest
    /// word on the screen counts as that.
    var screenUnmarked: Bool {
        guard screen.isEmpty, let unmarkedAt else { return false }
        if let flagOnSince { return unmarkedAt >= flagOnSince.addingTimeInterval(-Self.flagLead) }
        return unmarkedAt > (screenChangedAt ?? .distantPast)
    }

    mutating func checked(pid: pid_t, app: PrivacyApp?, at date: Date) {
        let check = Client(pid: pid, app: app, date: date, checked: true)
        checks = Self.recent(checks + [check], before: date)
        // A capture that started a moment ago with only a guess at its client takes
        // this check instead.
        for kind in [Kind.screen, .audio, .microphone] {
            if let last = self[kind].last, !last.checked, date.timeIntervalSince(last.date) < Self.lateCheck {
                self[kind][self[kind].count - 1] = Client(pid: pid, app: app, date: last.date, checked: true)
            }
        }
    }

    mutating func connected(pid: pid_t, app: PrivacyApp?, at date: Date) {
        connections = Self.recent(connections + [Client(pid: pid, app: app, date: date)], before: date)
    }

    mutating func changed(_ kind: Kind, started: Bool, at date: Date) {
        if kind == .screen { screenChangedAt = max(screenChangedAt ?? date, date) }
        if started {
            let named = Self.newest(checks, before: date) ?? Self.newest(connections, before: date)
            self[kind].append(Client(pid: named?.pid, app: named?.app, date: date, checked: named?.checked ?? false))
        } else if !payOwedStop(kind, at: date), !self[kind].isEmpty {
            self[kind].removeLast()
        }
    }

    /// An unmarked capture started or stopped; the service does not say which.
    mutating func unmarked(_ kind: Kind, at date: Date) {
        guard kind == .screen else { return }
        unmarkedAt = max(unmarkedAt ?? date, date)
    }

    mutating func exited(pid: pid_t, at date: Date) {
        for kind in [Kind.screen, .audio, .microphone] {
            let dropped = self[kind].filter { $0.pid == pid }.count
            guard dropped > 0 else { continue }
            self[kind].removeAll { $0.pid == pid }
            owedStops[kind, default: []] += Array(repeating: date, count: dropped)
        }
    }

    /// WindowServer's flag went on at `date`, or, for `nil`, was on already when
    /// watching began.
    mutating func screenFlagOn(since date: Date?) {
        flagOnSince = date
    }

    /// The screen stopped being captured at `date`: captures from before then are over.
    mutating func screenStopped(at date: Date) {
        flagOnSince = nil
        screen.removeAll { $0.date < date }
    }

    /// Lines may have been missed. Audio and microphone captures have nothing but the
    /// log to say when they end, so they are let go: a dot missed until the next
    /// start, rather than one kept on after its stop. The screen's are held to
    /// WindowServer's flag.
    mutating func linesLost() {
        audio = []
        microphone = []
        owedStops[.audio] = nil
        owedStops[.microphone] = nil
    }

    /// Takes a stop owed by a client that quit, if one is owed.
    private mutating func payOwedStop(_ kind: Kind, at date: Date) -> Bool {
        var owed = (owedStops[kind] ?? []).filter { date.timeIntervalSince($0) < Self.owedStopTime }
        let paid = !owed.isEmpty
        if paid { owed.removeFirst() }
        owedStops[kind] = owed.isEmpty ? nil : owed
        return paid
    }

    private subscript(kind: Kind) -> [Client] {
        get {
            switch kind {
            case .screen: screen
            case .audio: audio
            case .microphone: microphone
            }
        }
        set {
            switch kind {
            case .screen: screen = newValue
            case .audio: audio = newValue
            case .microphone: microphone = newValue
            }
        }
    }

    private static func newest(_ clients: [Client], before date: Date) -> Client? {
        clients.last { $0.date <= date && date.timeIntervalSince($0.date) <= window }
    }

    private static func recent(_ clients: [Client], before date: Date) -> [Client] {
        clients.filter { date.timeIntervalSince($0.date) <= window * 4 }.suffix(8)
    }
}

/// The processes the audio server reports as recording, in the order they began. It
/// reports each client as it starts and stops doing input: the microphone and what the
/// Mac plays alike, and the Sound Mixer among them.
///
/// A report is only as good as the last line read, and one missed would leave an app
/// counted as recording long after it stopped. So each is held to what Core Audio
/// says of the process before it counts.
struct PrivacyRecorders: Equatable {
    private(set) var recorders: [PrivacyNames.Recorder] = []

    var pids: Set<pid_t> { Set(recorders.map(\.pid)) }

    mutating func changed(pid: pid_t, running: Bool, app: @autoclosure () -> PrivacyApp?) {
        if running {
            guard !recorders.contains(where: { $0.pid == pid }) else { return }
            recorders.append(PrivacyNames.Recorder(pid: pid, app: app()))
        } else {
            exited(pid: pid)
        }
    }

    mutating func exited(pid: pid_t) {
        recorders.removeAll { $0.pid == pid }
    }

    /// The recorders Core Audio agrees are recording. `isRecording` is `nil` where
    /// Core Audio cannot be asked, and the reports then stand.
    func confirmed(by isRecording: (pid_t) -> Bool?) -> [PrivacyNames.Recorder] {
        recorders.filter { isRecording($0.pid) != false }
    }
}

/// Control Center's own list of what is in use, by sensor and bundle identifier. It is
/// what the person sees when they open Control Center, so it names what the other
/// sources cannot; but it is logged only when it changes, and it names apps only by
/// bundle, so it is never the first choice.
struct PrivacyControlCenterList: Equatable {
    struct Entry: Equatable, Sendable {
        var sensor: PrivacyMonitor.Sensor
        var bundleID: String
    }

    private(set) var active: [Entry] = []

    mutating func update(active entries: [Entry]) {
        active = entries
    }

    func bundleIDs(for sensor: PrivacyMonitor.Sensor, excluding own: String?) -> [String] {
        active.filter { $0.sensor == sensor && $0.bundleID != own }.map(\.bundleID)
    }
}

// MARK: - Tracker

/// Names the apps behind each sensor from the system log, and says whether location and
/// the Mac's own sound are in use at all, which only the log can.
///
/// One stream of the log is kept open, filtered by the log daemon to the handful of
/// lines that matter, for every sensor at once; it costs nothing while nothing is
/// logged. macOS opens the log only to administrators, so on another account nothing
/// is named but the microphone. Lines are reduced to pids and apps as they arrive; no
/// text from the log is kept or shown.
///
/// A camera or a screen capture already running when the stream opens logged its
/// start before then, so the log's store is read back for it, once. Lines the stream
/// may have missed since (`PrivacyLogStream`'s gaps) let go of what only the log says;
/// what the audio server reports is held to Core Audio at every report.
///
/// Every process named is also watched for exiting, as a process that quits logs
/// nothing more. All work happens on a private serial queue.
final class PrivacyNameTracker: @unchecked Sendable {
    enum Status: Equatable, Sendable {
        /// Not watching anything that needs the log.
        case off
        /// Reading the log.
        case running
        /// macOS opens the log only to administrators.
        case notAdministrator
        /// The log could not be read, or kept closing.
        case failed
    }

    typealias Report = @MainActor @Sendable (PrivacyNames) -> Void
    typealias StatusReport = @MainActor @Sendable (Status) -> Void

    private let queue = DispatchQueue(label: "islet.privacy.names", qos: .utility)
    private lazy var stream = PrivacyLogStream(queue: queue)

    // Confined to `queue`.
    private var report: Report?
    private var statusReport: StatusReport?
    private var sensors: Set<PrivacyMonitor.Sensor> = []
    private var status = Status.off
    private var camera = PrivacyCameraClients()
    private var captures = PrivacyCaptureClients()
    private var recorders = PrivacyRecorders()
    private var controlCenter = PrivacyControlCenterList()
    private var location = PrivacyLocationTracker()
    /// Whether a camera is on, and the screen captured, as the system last said.
    private var cameraOn = false
    private var screenOn = false
    private var exits: [pid_t: DispatchSourceProcess] = [:]
    /// The recorders' processes in the audio server, watched for starting and
    /// stopping.
    private var recorderProcesses: [pid_t: AudioObjectID] = [:]
    /// Apps by bundle identifier, as Control Center gives them.
    private var bundles: [String: PrivacyApp] = [:]
    private var lastReported: PrivacyNames?
    private var reportPending = false
    /// Sensors whose lines are being read back from the log's store.
    private var lookingBack: Set<PrivacyMonitor.Sensor> = []

    /// How far back to look for a camera client when the camera comes on with none
    /// known: the client's line comes just before the camera starts.
    static let lookback: TimeInterval = 3
    /// How far back to look, a step at a time, for whoever is using a camera, or
    /// capturing the screen, that was in use before the stream opened: a minute, ten,
    /// then an hour. Each step reads the store afresh, from a tenth of a second of CPU
    /// for the minute to a second or so for the hour, and is taken only while nothing
    /// has been found.
    static let catchUp: [TimeInterval] = [60, 600, 3600]

    /// Starts watching the log for `sensors`, or changes what it watches for. `report`
    /// gets every change of names; `status` whether the log can be read.
    func watch(_ sensors: Set<PrivacyMonitor.Sensor>, report: @escaping Report, status: @escaping StatusReport) {
        queue.async { [self] in
            self.report = report
            statusReport = status
            let before = self.sensors
            self.sensors = sensors
            forget(before.subtracting(sensors))
            if !sensors.contains(.camera) { cameraOn = false }
            if !sensors.contains(.screen) { screenOn = false }
            if sensors != before || self.status == .off {
                openStream()
            }
            let current = self.status
            DispatchQueue.main.async { MainActor.assumeIsolated { status(current) } }
            scheduleReport()
        }
    }

    /// Synchronous, so the stream, and the `log stream` child where there is one, is
    /// closed before the app quits. Nothing on the queue waits on the main thread.
    func stop() {
        queue.sync {
            report = nil
            statusReport = nil
            stream.stop()
            forget(sensors)
            sensors = []
            status = .off
            cameraOn = false
            screenOn = false
            lastReported = nil
        }
    }

    /// The camera went on or off at `date`, by CoreMediaIO's reckoning. `atStart` is
    /// the first reading, when a camera that is on may have been for a while.
    func cameraChanged(on: Bool, at date: Date, atStart: Bool) {
        queue.async { [self] in
            guard sensors.contains(.camera) else { return }
            cameraOn = on
            if on {
                // The client logged its start just before the camera came on; if that
                // line was missed (the stream was reopening), or came before the
                // stream opened, look for it.
                lookBack(.camera, over: atStart ? Self.catchUp : [Self.lookback], from: date)
            } else {
                camera.cameraOff(at: date)
                scheduleReport()
            }
        }
    }

    /// WindowServer's flag changed at `date`. `atStart` is the first reading, when a
    /// capture under way may have been for a while.
    func screenChanged(captured: Bool, at date: Date, atStart: Bool) {
        queue.async { [self] in
            guard sensors.contains(.screen) else { return }
            screenOn = captured
            if captured {
                captures.screenFlagOn(since: atStart ? nil : date)
                if atStart { lookBack(.screen, over: Self.catchUp, from: date) }
            } else {
                captures.screenStopped(at: date)
            }
            scheduleReport()
        }
    }

    /// Core Audio's microphone readings changed, as they do when a call ends: the
    /// recorders are held to Core Audio again.
    func recheckRecorders() {
        queue.async { [self] in
            if !recorders.recorders.isEmpty { scheduleReport() }
        }
    }

    // MARK: Stream

    private func openStream() {
        let predicate = PrivacyLogEvent.predicate(for: sensors)
        stream.start(predicate: predicate, handler: { [weak self] record in
            self?.handle(record)
        }, status: { [weak self] status in
            self?.streamStatusChanged(status)
        }, gap: { [weak self] in
            self?.linesLost()
        })
    }

    private func streamStatusChanged(_ status: Status) {
        guard self.status != status else { return }
        self.status = status
        if status == .running {
            // Whatever is in use already started before the stream could see it.
            lookBack(.camera, over: Self.catchUp, from: Date())
            lookBack(.screen, over: Self.catchUp, from: Date())
        } else {
            forget(sensors)
        }
        guard let statusReport else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { statusReport(status) } }
        scheduleReport()
    }

    /// Drops what is known of sensors no longer watched, or no longer readable.
    private func forget(_ gone: Set<PrivacyMonitor.Sensor>) {
        if gone.contains(.camera) { camera = PrivacyCameraClients() }
        if gone.contains(.screen) || gone.contains(.systemAudio) {
            captures = PrivacyCaptureClients()
            recorders = PrivacyRecorders()
        }
        if gone.contains(.location) { location = PrivacyLocationTracker() }
        if !gone.isEmpty { controlCenter = PrivacyControlCenterList() }
        syncWatches()
    }

    /// Lines may have been missed. What only the log says, with nothing to check it
    /// against, is let go: a dot missed until the next line, rather than one stuck on.
    /// Cameras and the screen are held to the system's own readings, and recorders to
    /// Core Audio's, so they stay.
    private func linesLost() {
        captures.linesLost()
        location.linesLost()
        controlCenter = PrivacyControlCenterList()
        scheduleReport()
    }

    // MARK: Events

    private func handle(_ record: PrivacyLogRecord) {
        let date = record.date
        switch record.event {
        case .cameraStream(let stream, let started):
            guard sensors.contains(.camera), record.pid > 0 else { return }
            if started {
                let app = PrivacyAppResolver.app(pid: record.pid, executablePath: record.processPath)
                camera.started(pid: record.pid, version: record.pidVersion, stream: stream, at: date, app: app)
            } else {
                camera.stopped(pid: record.pid, version: record.pidVersion, stream: stream)
            }

        case .capture(let kind, let started):
            captures.changed(kind, started: started, at: date)

        case .captureUnmarked(let kind):
            captures.unmarked(kind, at: date)

        case .captureClient(let pid):
            captures.connected(pid: pid, app: PrivacyAppResolver.app(pid: pid), at: date)

        case .captureCheck(let check):
            // The client may be gone already (a screenshot tool quits within a tenth of
            // a second), so the paths the check logged come first.
            let app = check.responsiblePath.flatMap(PrivacyAppResolver.app(path:))
                ?? check.accessingPath.flatMap(PrivacyAppResolver.app(path:))
                ?? PrivacyAppResolver.app(pid: check.accessingPID)
            captures.checked(pid: check.accessingPID, app: app, at: date)

        case .recordingClient(let pid, let running):
            guard sensors.contains(.systemAudio) else { return }
            recorders.changed(pid: pid, running: running, app: PrivacyAppResolver.app(pid: pid))
            // The audio server may report a client a moment before Core Audio shows
            // it recording; look again once it has.
            if running { queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.scheduleReport() } }

        case .controlCenter(let active):
            controlCenter.update(active: active)
            location.controlCenterChanged(active: active.filter { $0.sensor == .location }.map(\.bundleID), at: date)

        case .controlCenterRecent(let recent):
            location.controlCenterRecentChanged(recent.filter { $0.sensor == .location }.map(\.bundleID), at: date)

        case .locationIcon(let icon):
            location.iconChanged(icon, at: date)
        }
        syncWatches()
        scheduleReport()
    }

    // MARK: Looking back

    /// Reads back from the log's store what the stream could not have seen of
    /// `sensor`: a camera stream or a screen capture that started before the stream
    /// opened, or whose line it missed. A window at a time, the shortest first, only
    /// while still needed, and never two at once for a sensor. The store is read by a
    /// child process on a queue of its own.
    private func lookBack(_ sensor: PrivacyMonitor.Sensor, over windows: [TimeInterval], from date: Date) {
        guard let window = windows.first, status == .running, needsLookBack(sensor), !lookingBack.contains(sensor),
              let predicate = PrivacyLogEvent.storedPredicate(for: sensor)
        else { return }
        lookingBack.insert(sensor)
        let queue = queue
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let records = PrivacyLogStream.storedRecords(matching: predicate, since: date.addingTimeInterval(-window))
            queue.async { self?.lookedBack(sensor, records, then: Array(windows.dropFirst()), from: date) }
        }
    }

    private func lookedBack(_ sensor: PrivacyMonitor.Sensor, _ records: [PrivacyLogRecord], then windows: [TimeInterval], from date: Date) {
        lookingBack.remove(sensor)
        // The stream may have caught up meanwhile; its lines are the better ones.
        guard needsLookBack(sensor) else { return }
        for record in records.sorted(by: { $0.date < $1.date }) where Self.replays(record, for: sensor) {
            handle(record)
        }
        lookBack(sensor, over: windows, from: date)
    }

    private func needsLookBack(_ sensor: PrivacyMonitor.Sensor) -> Bool {
        switch sensor {
        case .camera: sensors.contains(.camera) && cameraOn && camera.isEmpty
        case .screen: sensors.contains(.screen) && screenOn && captures.screen.isEmpty && !captures.screenUnmarked
        case .microphone, .systemAudio, .location: false
        }
    }

    /// What a look-back for `sensor` replays: that sensor's own lines, and none about
    /// a client whose pid has since passed to a newer process, which would otherwise
    /// be named, and kept, in its place.
    static func replays(_ record: PrivacyLogRecord, for sensor: PrivacyMonitor.Sensor) -> Bool {
        func stillItsOwn(_ pid: pid_t) -> Bool {
            PrivacyAppResolver.startDate(of: pid).map { $0 <= record.date } ?? true
        }
        switch (sensor, record.event) {
        case (.camera, .cameraStream):
            return stillItsOwn(record.pid)
        case (.screen, .captureClient(let pid)):
            return stillItsOwn(pid)
        case (.screen, .captureCheck(let check)):
            return stillItsOwn(check.accessingPID)
        case (.screen, .capture(.screen, _)), (.screen, .captureUnmarked(.screen)):
            return true
        default:
            return false
        }
    }

    // MARK: Watching processes

    /// Watches every process named for exiting, and every recorder's process in the
    /// audio server for starting and stopping, and stops watching the rest.
    private func syncWatches() {
        let needed = camera.pids.union(captures.pids).union(recorders.pids).filter { $0 > 0 }
        for (pid, source) in exits where !needed.contains(pid) {
            source.cancel()
            exits[pid] = nil
        }
        for pid in needed where exits[pid] == nil {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            source.setEventHandler { [weak self] in self?.exited(pid) }
            exits[pid] = source
            source.resume()
            // Gone before the watch began, so it will never fire.
            if kill(pid, 0) != 0, errno == ESRCH { exited(pid) }
        }

        let recording = recorders.pids
        for (pid, process) in recorderProcesses where !recording.contains(pid) {
            for address in PrivacyMicrophoneWatcher.processActivity { unlisten(process, address) }
            recorderProcesses[pid] = nil
        }
        for pid in recording where recorderProcesses[pid] == nil {
            guard let process = PrivacyMicrophoneWatcher.processObject(pid: pid) else { continue }
            recorderProcesses[pid] = process
            for address in PrivacyMicrophoneWatcher.processActivity { listen(process, address) }
        }
    }

    private func exited(_ pid: pid_t) {
        exits.removeValue(forKey: pid)?.cancel()
        if let process = recorderProcesses.removeValue(forKey: pid) {
            for address in PrivacyMicrophoneWatcher.processActivity { unlisten(process, address) }
        }
        camera.exited(pid: pid)
        captures.exited(pid: pid, at: Date())
        recorders.exited(pid: pid)
        scheduleReport()
    }

    private var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    private func listen(_ process: AudioObjectID, _ address: AudioObjectPropertyAddress) {
        var address = address
        AudioObjectAddPropertyListener(process, &address, Self.recorderChanged, context)
    }

    /// Fails harmlessly for a process that has already gone.
    private func unlisten(_ process: AudioObjectID, _ address: AudioObjectPropertyAddress) {
        var address = address
        AudioObjectRemovePropertyListener(process, &address, Self.recorderChanged, context)
    }

    /// Called on the HAL's notification thread when a recorder starts or stops IO. The
    /// tracker is never released while listening (`PrivacyMonitor` keeps it for the
    /// life of the app), and it stops listening when it stops.
    private static let recorderChanged: AudioObjectPropertyListenerProc = { _, _, _, context in
        guard let context else { return noErr }
        let tracker = Unmanaged<PrivacyNameTracker>.fromOpaque(context).takeUnretainedValue()
        tracker.queue.async { tracker.scheduleReport() }
        return noErr
    }

    // MARK: Reporting

    /// Lines come in bursts; they are gathered into one report.
    private func scheduleReport() {
        guard !reportPending else { return }
        reportPending = true
        queue.asyncAfter(deadline: .now() + 0.05) { [self] in
            reportPending = false
            sendReport()
        }
    }

    private func sendReport() {
        guard let report else { return }
        let names = currentNames()
        guard names != lastReported else { return }
        lastReported = names
        DispatchQueue.main.async { MainActor.assumeIsolated { report(names) } }
    }

    private func currentNames() -> PrivacyNames {
        var names = PrivacyNames()
        guard status == .running else { return names }
        if sensors.contains(.camera) { names.camera = camera.apps }
        if sensors.contains(.screen) {
            names.screen = captures.apps(.screen)
            names.screenUnmarked = captures.screenUnmarked
        }
        if sensors.contains(.systemAudio) {
            names.capturedAudio = captures.apps(.audio)
            names.recorders = recorders.confirmed(by: PrivacyMicrophoneWatcher.isRecording(pid:))
        }
        names.capturedMicrophone = captures.apps(.microphone)
        if sensors.contains(.location) {
            let reading = location.reading
            names.location = PrivacyUse(inUse: reading.inUse, apps: reading.clients.compactMap(app(bundleIdentifier:)))
        }
        let own = Bundle.main.bundleIdentifier
        for sensor in PrivacyMonitor.Sensor.allCases where sensor != .location {
            let apps = controlCenter.bundleIDs(for: sensor, excluding: own).compactMap(app(bundleIdentifier:))
            if !apps.isEmpty { names.controlCenter[sensor] = apps }
        }
        return names
    }

    /// An app as Control Center names it, by bundle identifier, looked up once.
    private func app(bundleIdentifier: String) -> PrivacyApp? {
        if let app = bundles[bundleIdentifier] { return app }
        guard let app = PrivacyAppResolver.app(bundleIdentifier: bundleIdentifier) else { return nil }
        bundles[bundleIdentifier] = app
        return app
    }
}
