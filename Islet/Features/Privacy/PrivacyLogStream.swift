import Foundation
import Darwin
import Darwin.membership

/// A line of the system log that says something about a sensor, reduced to what it
/// says as it arrives: pids, bundle identifiers, paths. The text itself is never kept.
struct PrivacyLogRecord: Equatable, Sendable {
    var event: PrivacyLogEvent
    /// The process that logged the line.
    var pid: pid_t
    /// Changes when a pid is reused; 0 where it could not be read.
    var pidVersion: UInt32
    var processPath: String?
    var date: Date
}

/// What a line of the log says. These are private messages, not an interface: each
/// is matched loosely, and anything that does not match is ignored rather than
/// misread.
enum PrivacyLogEvent: Equatable, Sendable {
    /// The logging process started or stopped a camera stream (CoreMediaIO, in the
    /// client). `stream` names the device and stream, as the process numbers them.
    case cameraStream(stream: String, started: Bool)
    /// The capture service started or stopped a capture, for a client it does not
    /// name.
    case capture(PrivacyCaptureClients.Kind, started: Bool)
    /// The capture service started or stopped a capture that macOS leaves unmarked,
    /// such as AirPlay's screen mirroring: its client may hide the indicator. The
    /// service says so in place of whether it started, and says the same both ways.
    case captureUnmarked(PrivacyCaptureClients.Kind)
    /// A process connected to the capture service.
    case captureClient(pid: pid_t)
    /// The permission daemon checked a client of the capture service.
    case captureCheck(PrivacyCaptureCheck)
    /// The audio server reports a process starting or stopping recording.
    case recordingClient(pid: pid_t, running: Bool)
    /// Control Center's list of what is in use changed.
    case controlCenter(active: [PrivacyControlCenterList.Entry])
    /// Control Center's list of what was in use in the last few seconds changed.
    case controlCenterRecent([PrivacyControlCenterList.Entry])
    /// The menu bar's location arrow changed.
    case locationIcon(PrivacyLocationIcon)
}

/// A permission check the capture service made for a client: who was checked, and
/// the app responsible for it.
struct PrivacyCaptureCheck: Equatable, Sendable {
    var accessingPID: pid_t
    var accessingPath: String?
    var responsiblePath: String?
}

/// The menu bar's location arrow: off, hollow while an app waits for a fix, solid
/// while one is getting fixes.
enum PrivacyLocationIcon: Equatable, Sendable {
    case inactive, requesting, receiving
}

extension PrivacyLogEvent {
    // MARK: Parsing

    /// Reads a line of the log. `process` is the logging process's name.
    static func parse(process: String, subsystem: String?, category: String?, message: String) -> PrivacyLogEvent? {
        switch process {
        case "replayd":
            return parseCaptureService(message)
        case "tccd":
            return parsePermissionCheck(message)
        case "coreaudiod":
            guard let pid = Int32(message.after("Report client ")?.prefix { $0.isNumber } ?? ""),
                  let state = message.after(" running: ")
            else { return nil }
            return .recordingClient(pid: pid, running: state.hasPrefix("yes"))
        case "ControlCenter":
            guard category == "sensor-indicators" else { return nil }
            if message.hasPrefix("Active activity attributions changed to ") {
                return .controlCenter(active: controlCenterEntries(message))
            }
            if message.hasPrefix("Recent activity attributions changed to ") {
                return .controlCenterRecent(controlCenterEntries(message))
            }
            return nil
        case "locationd":
            return parseLocation(message)
        default:
            // CoreMediaIO logs from inside whichever process uses the camera.
            guard subsystem == "com.apple.cmio" else { return nil }
            for (marker, started) in [(":CMIODeviceStartStream (", true), (":CMIODeviceStopStream (", false)] {
                if let rest = message.after(marker), let end = rest.firstIndex(of: ")") {
                    return .cameraStream(stream: String(rest[..<end]), started: started)
                }
            }
            return nil
        }
    }

    /// `-[SCMediaAttributionManager updateScreenCaptureDidStart:…]:115 0x… hasStarted=1`,
    /// and the same for audio and the microphone; `…updateScreenCaptureDidStart:…]:111
    /// client has entitlement to suppress screen indicator`, which comes instead of
    /// `hasStarted` for a capture macOS leaves unmarked; `accepted client connection
    /// PID: 123`.
    private static func parseCaptureService(_ message: String) -> PrivacyLogEvent? {
        if let pid = message.after("accepted client connection PID: ").flatMap({ Int32($0.prefix { $0.isNumber }) }) {
            return .captureClient(pid: pid)
        }
        guard message.contains("CaptureDidStart") else { return nil }
        let kind: PrivacyCaptureClients.Kind
        if message.contains("ScreenCaptureDidStart") {
            kind = .screen
        } else if message.contains("updateAudioCaptureDidStart") {
            kind = .audio
        } else if message.contains("updateMicrophoneCaptureDidStart") {
            kind = .microphone
        } else {
            return nil
        }
        if let flag = message.after("hasStarted=")?.first { return .capture(kind, started: flag == "1") }
        if message.contains("suppress") { return .captureUnmarked(kind) }
        return nil
    }

    /// `AUTHREQ_ATTRIBUTION: msgID=…, attribution={responsible={TCCDProcess: …,
    /// responsible_path=…, binary_path=…}, accessing={TCCDProcess: identifier=…,
    /// pid=123, …, binary_path=…}, requesting={TCCDProcess: identifier=com.apple.replayd, …}, }`.
    /// Only checks the capture service asked for count.
    private static func parsePermissionCheck(_ message: String) -> PrivacyLogEvent? {
        guard message.hasPrefix("AUTHREQ_ATTRIBUTION"),
              let requesting = block("requesting", in: message),
              field("identifier", in: requesting) == "com.apple.replayd",
              let accessing = block("accessing", in: message),
              let pid = field("pid", in: accessing).flatMap({ Int32($0) })
        else { return nil }
        let responsible = block("responsible", in: message)
        return .captureCheck(PrivacyCaptureCheck(
            accessingPID: pid,
            accessingPath: path("binary_path", in: accessing),
            responsiblePath: responsible.flatMap { path("responsible_path", in: $0) ?? path("binary_path", in: $0) }
        ))
    }

    /// `{"msg":"#Notice Location icon should now be in state", "state":"ReceivingLocationInformation"}`.
    private static func parseLocation(_ message: String) -> PrivacyLogEvent? {
        guard message.contains("Location icon should now be in state") else { return nil }
        switch jsonValue("state", in: message) {
        case "Inactive": return .locationIcon(.inactive)
        case "RequestingLocationInformation": return .locationIcon(.requesting)
        case "ReceivingLocationInformation": return .locationIcon(.receiving)
        default: return nil
        }
    }

    /// `["aud:com.ayush.Islet", "loc:com.apple.findmy"]`.
    private static func controlCenterEntries(_ message: String) -> [PrivacyControlCenterList.Entry] {
        let sensors: [String: PrivacyMonitor.Sensor] = [
            "cam": .camera, "mic": .microphone, "scr": .screen, "aud": .systemAudio, "loc": .location,
        ]
        let quoted = message.split(separator: "\"", omittingEmptySubsequences: false).enumerated()
            .filter { $0.offset % 2 == 1 }.map(\.element)
        return quoted.compactMap { item in
            guard let colon = item.firstIndex(of: ":"), let sensor = sensors[String(item[..<colon])] else { return nil }
            let bundleID = String(item[item.index(after: colon)...])
            return bundleID.isEmpty ? nil : PrivacyControlCenterList.Entry(sensor: sensor, bundleID: bundleID)
        }
    }

    /// The `name={TCCDProcess: …}` part of a permission line, without its braces.
    private static func block(_ name: String, in message: String) -> Substring? {
        guard let rest = message.after("\(name)={TCCDProcess: "), let end = rest.firstIndex(of: "}") else { return nil }
        return rest[..<end]
    }

    /// A `name=value` field of a block, up to the next comma.
    private static func field(_ name: String, in block: Substring) -> String? {
        let fields = block.components(separatedBy: ", ")
        return fields.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
    }

    /// A path field, which may hold commas of its own: up to the next field or the
    /// block's end.
    private static func path(_ name: String, in block: Substring) -> String? {
        guard let rest = block.after(" \(name)=") ?? (block.hasPrefix("\(name)=") ? block.dropFirst(name.count + 1) : nil) else {
            return nil
        }
        let value = rest.range(of: ", binary_path=").map { rest[..<$0.lowerBound] } ?? rest
        return value.hasPrefix("/") ? String(value) : nil
    }

    /// A `"name":"value"` pair of a line logged as JSON, unescaped.
    private static func jsonValue(_ name: String, in message: String) -> String? {
        guard let rest = message.after("\"\(name)\":\""), let end = rest.firstIndex(of: "\"") else { return nil }
        return rest[..<end].replacingOccurrences(of: "\\/", with: "/")
    }

    // MARK: Filtering

    /// The one filter for everything `sensors` needs, so the log daemon passes on only
    /// those lines. Control Center's list is always read: it names what the others
    /// cannot.
    ///
    /// Lines are picked out by subsystem where they have one, which the daemon can
    /// narrow down before it looks at the text; picked out by process, the same lines
    /// cost the stream about three times the CPU. The capture service and the audio
    /// server log these lines under no subsystem, so they are picked out by process.
    static func predicate(for sensors: Set<PrivacyMonitor.Sensor>) -> String {
        var clauses: [String] = []
        if sensors.contains(.camera) {
            clauses.append(cameraClause)
        }
        if sensors.contains(.screen) || sensors.contains(.systemAudio) {
            clauses += captureClauses
        }
        if sensors.contains(.systemAudio) {
            clauses.append(#"(process == "coreaudiod" AND eventMessage CONTAINS "PublishRecordingClientInfo: Report client ")"#)
        }
        if sensors.contains(.location) {
            clauses.append(#"(subsystem == "com.apple.locationd.Core" AND category == "Core" AND eventMessage CONTAINS "Location icon should now be in state")"#)
        }
        clauses.append(#"(subsystem == "com.apple.controlcenter" AND category == "sensor-indicators" AND eventMessage CONTAINS "activity attributions changed to")"#)
        return clauses.joined(separator: " OR ")
    }

    /// The filter for reading back what the stream could not have seen of `sensor`:
    /// the camera's own lines, or the capture service's and its permission checks.
    /// Both are kept in the log's store; nothing else these lines come from is.
    static func storedPredicate(for sensor: PrivacyMonitor.Sensor) -> String? {
        switch sensor {
        case .camera: cameraClause
        case .screen: captureClauses.joined(separator: " OR ")
        case .microphone, .systemAudio, .location: nil
        }
    }

    private static let cameraClause =
        #"(subsystem == "com.apple.cmio" AND (eventMessage CONTAINS ":CMIODeviceStartStream (" OR eventMessage CONTAINS ":CMIODeviceStopStream ("))"#

    private static let captureClauses = [
        #"(process == "replayd" AND (eventMessage CONTAINS "CaptureDidStart" OR eventMessage CONTAINS "accepted client connection PID: "))"#,
        #"(subsystem == "com.apple.TCC" AND category == "access" AND eventMessage BEGINSWITH "AUTHREQ_ATTRIBUTION" AND eventMessage CONTAINS "identifier=com.apple.replayd,")"#,
    ]
}

private extension StringProtocol {
    /// What follows the first `marker`, if it is there.
    func after(_ marker: String) -> SubSequence? {
        range(of: marker).map { self[$0.upperBound...] }
    }
}

// MARK: - Stream

/// A live stream of the system log, filtered by the log daemon, delivering the lines
/// that parse as `PrivacyLogEvent`s.
///
/// It reads the log in-process through LoggingSupport's live stream, the private class
/// behind `log stream`, where it exists; otherwise, or if that keeps failing, through
/// `/usr/bin/log stream` as a child process. Either closes now and then (the log daemon
/// is launched on demand and exits when idle); it is reopened, after a pause that
/// grows if it keeps closing straight away. macOS opens the log only to
/// administrators, so on another account it is not opened at all.
///
/// Lines logged while it is closed, or that the log daemon drops because too much is
/// being logged, never arrive. Whoever reads the stream is told when that may have
/// happened (`gap`), so that what it knows only from the log can be let go rather
/// than kept past its time.
///
/// Confined to the queue it is made with: every method is called there, and every
/// handler is called there.
final class PrivacyLogStream: @unchecked Sendable {
    typealias Status = PrivacyNameTracker.Status
    typealias Handler = (PrivacyLogRecord) -> Void

    private enum Transport { case inProcess, child }

    private let queue: DispatchQueue
    private var handler: Handler?
    private var status: ((Status) -> Void)?
    private var gap: (() -> Void)?
    private var predicate = ""
    private var transport = Transport.inProcess
    /// Bumped on every open and close, so a handler from a stream already closed is
    /// recognised and ignored.
    private var generation = 0
    private var openedAt = Date.distantPast
    /// Whether it has opened since `start`: opening again means lines were missed.
    private var hasOpened = false
    /// Closings in a row that came soon after opening.
    private var quickFailures = 0
    private var liveStream: NSObject?
    private var child: Process?
    private var childBuffer = Data()
    private var retry: DispatchWorkItem?

    /// A stream that closes sooner than this after opening counts as failing.
    static let settleTime: TimeInterval = 10
    /// Failures in a row before trying the other way, or giving up.
    static let attempts = 3

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Opens the stream with `predicate`, closing any stream already open. `gap` is
    /// called when lines may have been missed since: dropped by the log daemon, or
    /// logged while the stream was reopening.
    func start(
        predicate: String, handler: @escaping Handler, status: @escaping (Status) -> Void, gap: @escaping () -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        close()
        self.predicate = predicate
        self.handler = handler
        self.status = status
        self.gap = gap
        quickFailures = 0
        hasOpened = false
        guard Self.isAdministrator else {
            status(.notAdministrator)
            return
        }
        transport = Self.liveStreamClass == nil ? .child : .inProcess
        open()
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        close()
        handler = nil
        status = nil
        gap = nil
    }

    // MARK: Opening and closing

    private func open() {
        generation &+= 1
        openedAt = Date()
        let opened: Bool
        switch transport {
        case .inProcess: opened = openLiveStream()
        case .child: opened = openChild()
        }
        guard opened else {
            closed(generation)
            return
        }
        status?(.running)
        if hasOpened { gap?() }
        hasOpened = true
    }

    private func close() {
        generation &+= 1
        retry?.cancel()
        retry = nil
        if let liveStream {
            Self.send("invalidate", to: liveStream)
            self.liveStream = nil
        }
        if let child {
            child.terminationHandler = nil
            (child.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if child.isRunning { child.terminate() }
            self.child = nil
        }
        childBuffer = Data()
    }

    /// The stream closed, or never opened. It is reopened after a pause; if it keeps
    /// closing as soon as it opens, the other way is tried, then no more.
    private func closed(_ closedGeneration: Int) {
        guard closedGeneration == generation, handler != nil else { return }
        close()
        if Date().timeIntervalSince(openedAt) < Self.settleTime {
            quickFailures += 1
        } else {
            quickFailures = 0
        }
        if quickFailures >= Self.attempts {
            guard transport == .inProcess else {
                status?(.failed)
                return
            }
            transport = .child
            quickFailures = 0
        }
        let pause = min(pow(2, Double(quickFailures)), 60)
        let work = DispatchWorkItem { [weak self] in self?.open() }
        retry = work
        queue.asyncAfter(deadline: .now() + pause, execute: work)
    }

    // MARK: In process

    private static let liveStreamClass: NSObject.Type? = {
        guard dlopen("/System/Library/PrivateFrameworks/LoggingSupport.framework/LoggingSupport", RTLD_NOW) != nil else {
            return nil
        }
        return NSClassFromString("OSLogEventLiveStream") as? NSObject.Type
    }()

    private static let liveStreamSelectors = [
        "setFilterPredicate:", "setEventHandler:", "setInvalidationHandler:", "setDroppedEventHandler:",
        "setFlags:", "setQueue:", "activate", "invalidate",
    ]

    private func openLiveStream() -> Bool {
        guard let streamClass = Self.liveStreamClass else { return false }
        let stream = streamClass.init()
        guard Self.liveStreamSelectors.allSatisfy({ stream.responds(to: NSSelectorFromString($0)) }) else { return false }
        let generation = generation
        let queue = queue

        stream.setValue(NSPredicate(format: predicate), forKey: "filterPredicate")
        // Default level: every line wanted is logged there, and anything more detailed
        // makes processes log more everywhere.
        stream.setValue(NSNumber(value: UInt64(0)), forKey: "flags")
        stream.setValue(queue, forKey: "queue")

        // The event is reused for the next line, so it is read before this returns.
        let onEvent: @convention(block) (NSObject) -> Void = { [weak self] event in
            guard let record = Self.record(from: event) else { return }
            queue.async { self?.deliver(record, generation: generation) }
        }
        let onInvalidation: @convention(block) (Int32, AnyObject?) -> Void = { [weak self] _, _ in
            queue.async { self?.closed(generation) }
        }
        let onDropped: @convention(block) (AnyObject?) -> Void = { [weak self] _ in
            queue.async { self?.dropped(generation) }
        }
        Self.set(onEvent, "setEventHandler:", on: stream)
        Self.set(onInvalidation, "setInvalidationHandler:", on: stream)
        Self.set(onDropped, "setDroppedEventHandler:", on: stream)
        Self.send("activate", to: stream)
        liveStream = stream
        return true
    }

    private static func record(from event: NSObject) -> PrivacyLogRecord? {
        // A property a later macOS dropped reads as missing, rather than raising. The
        // class is asked, not the event: the event answers no for all of them.
        let eventClass: AnyClass? = object_getClass(event)
        func value(_ key: String) -> Any? {
            class_getInstanceMethod(eventClass, NSSelectorFromString(key)) != nil ? event.value(forKey: key) : nil
        }
        guard let process = value("process") as? String,
              let message = value("composedMessage") as? String,
              let parsed = PrivacyLogEvent.parse(
                  process: process,
                  subsystem: value("subsystem") as? String,
                  category: value("category") as? String,
                  message: message
              )
        else { return nil }
        return PrivacyLogRecord(
            event: parsed,
            pid: (value("processIdentifier") as? NSNumber)?.int32Value ?? 0,
            pidVersion: (value("processIdentifierVersion") as? NSNumber)?.uint32Value ?? 0,
            processPath: value("processImagePath") as? String,
            date: value("date") as? Date ?? Date()
        )
    }

    private typealias BlockSetter = @convention(c) (NSObject, Selector, AnyObject) -> Void
    private typealias Action = @convention(c) (NSObject, Selector) -> Void

    /// Calls a setter that takes a block. (Key-value coding would do, but these have
    /// no getters.)
    private static func set<Block>(_ block: Block, _ selector: String, on object: NSObject) {
        let selector = NSSelectorFromString(selector)
        let setter = unsafeBitCast(object.method(for: selector), to: BlockSetter.self)
        setter(object, selector, unsafeBitCast(block, to: AnyObject.self))
    }

    private static func send(_ selector: String, to object: NSObject) {
        let selector = NSSelectorFromString(selector)
        guard object.responds(to: selector) else { return }
        unsafeBitCast(object.method(for: selector), to: Action.self)(object, selector)
    }

    // MARK: Child process

    private func openChild() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "ndjson", "--level", "default", "--predicate", predicate]
        process.qualityOfService = .utility
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let generation = generation
        let queue = queue
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            queue.async { self?.childWrote(data, generation: generation) }
        }
        process.terminationHandler = { [weak self] _ in
            queue.async { self?.closed(generation) }
        }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return false
        }
        child = process
        return true
    }

    /// One JSON object a line; the first line is a banner and the last a summary,
    /// neither of which parses as an event. Lines the daemon dropped are reported as
    /// a loss event of their own.
    private func childWrote(_ data: Data, generation: Int) {
        guard generation == self.generation, !data.isEmpty else { return }
        childBuffer.append(data)
        while let newline = childBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = childBuffer[childBuffer.startIndex..<newline]
            childBuffer.removeSubrange(childBuffer.startIndex...newline)
            if let record = Self.record(fromJSON: line) {
                deliver(record, generation: generation)
            } else if line.range(of: Data(#""eventType":"lossEvent""#.utf8)) != nil {
                dropped(generation)
            }
        }
    }

    private static let timestampFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return formatter
    }()

    static func record(fromJSON line: Data) -> PrivacyLogRecord? {
        guard line.first == UInt8(ascii: "{"),
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let message = object["eventMessage"] as? String
        else { return nil }
        let path = object["processImagePath"] as? String
        guard let parsed = PrivacyLogEvent.parse(
            process: path.map { ($0 as NSString).lastPathComponent } ?? "",
            subsystem: object["subsystem"] as? String,
            category: object["category"] as? String,
            message: message
        ) else { return nil }
        return PrivacyLogRecord(
            event: parsed,
            pid: (object["processID"] as? NSNumber)?.int32Value ?? 0,
            pidVersion: 0,
            processPath: path,
            date: (object["timestamp"] as? String).flatMap(timestampFormat.date(from:)) ?? Date()
        )
    }

    private func deliver(_ record: PrivacyLogRecord, generation: Int) {
        guard generation == self.generation else { return }
        handler?(record)
    }

    /// The daemon dropped lines: too much was being logged for it to keep up.
    private func dropped(_ droppedGeneration: Int) {
        guard droppedGeneration == generation else { return }
        gap?()
    }

    // MARK: Looking back

    /// The lines matching `predicate` from `since` until now, read back from the log's
    /// store by `/usr/bin/log show`: for what the stream could not have seen, having
    /// opened after it was logged. A few tenths of a second of CPU for a few minutes'
    /// worth, more for an hour's, so read only when needed and never polled.
    ///
    /// A child process rather than `OSLogStore`, which does the same in-process but
    /// keeps tens of megabytes in Islet afterwards, and more after every read; the
    /// child hands it all back when it exits. Blocks until done, so it is called on
    /// a queue of its own.
    static func storedRecords(matching predicate: String, since: Date) -> [PrivacyLogRecord] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show", "--style", "ndjson", "--start", "@\(Int(since.timeIntervalSince1970.rounded(.down)))", "--predicate", predicate,
        ]
        process.qualityOfService = .utility
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        // A store that will not answer is given up on rather than waited for.
        let giveUp = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30, execute: giveUp)
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        giveUp.cancel()
        return output.split(separator: UInt8(ascii: "\n")).compactMap { record(fromJSON: Data($0)) }
    }

    // MARK: Access

    /// Whether this account is an administrator's, the only kind macOS streams the log
    /// to.
    static var isAdministrator: Bool {
        var user = [UInt8](repeating: 0, count: 16)
        var admin = [UInt8](repeating: 0, count: 16)
        var isMember: Int32 = 0
        guard mbr_uid_to_uuid(getuid(), &user) == 0,
              mbr_gid_to_uuid(80, &admin) == 0, // the admin group
              mbr_check_membership(user, admin, &isMember) == 0
        else { return false }
        return isMember != 0
    }
}
