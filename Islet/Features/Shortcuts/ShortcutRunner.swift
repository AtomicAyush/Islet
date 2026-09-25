import AppKit

/// A shortcut to run: by its identifier where Islet knows it, which survives a rename
/// and tells two shortcuts of the same name apart, or else by its name.
struct ShortcutTarget: Hashable, Sendable {
    var identifier: String?
    var name: String

    /// What the tool is given to find the shortcut by.
    var argument: String { identifier ?? name }
}

/// One line of `shortcuts list --show-identifiers`: a shortcut, or a folder.
struct ShortcutListing: Hashable, Sendable {
    var name: String
    /// `nil` for a line the tool printed without one.
    var identifier: String?
}

/// Text a shortcut handed back, as the tool wrote it out.
struct ShortcutOutput: Equatable, Sendable {
    var text: String
    /// The shortcut gave back more than Islet keeps; `text` is its beginning.
    var isTruncated = false
}

/// How a run of a shortcut ended.
enum ShortcutRunResult: Equatable, Sendable {
    /// It ran to the end, with the text it gave back, if any and if it was asked for.
    case succeeded(ShortcutOutput?)
    case failed(ShortcutRunFailure)
    /// The task running it was cancelled, and the shortcut stopped with it.
    case cancelled
}

enum ShortcutRunFailure: Equatable, Sendable {
    /// No shortcut by that identifier or name any more: renamed, or deleted.
    case notFound
    /// It ran and failed, or could not be started.
    case failed
    /// It was still going when its time was up, and was stopped.
    case timedOut
}

/// The `shortcuts` command line tool, the one public way to list the person's
/// shortcuts and run one. It talks to the same runner as the Shortcuts app, so a run
/// from here is a real run: it shows its dialogs, and macOS shows its own indicator in
/// the menu bar while it goes.
///
/// Every call waits off the main thread, and every run is timed: a tool that never
/// answers is stopped rather than waited on for ever.
struct ShortcutsTool: Sendable {
    let executable: URL

    static let system = ShortcutsTool(executable: URL(fileURLWithPath: "/usr/bin/shortcuts"))

    /// Listing takes a few tens of milliseconds; one that has not answered in ten
    /// seconds is not going to.
    static let listTimeout: TimeInterval = 10
    /// Output beyond this is cut off: enough for any text worth reading in the island,
    /// and a bound on what a shortcut that returns a whole file can make Islet hold.
    static let outputLimit = 64 * 1024
    private static let outputName = "output.txt"

    // MARK: Listing

    /// The names of the person's shortcuts, sorted as Finder would, or `nil` if the
    /// tool could not be run, or did not answer in time.
    func names() async -> [String]? {
        guard let output = await listOutput(["list"]) else { return nil }
        let names = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(Set(names)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The person's shortcuts with their identifiers, in the order their library has
    /// them — or those in one folder, given its identifier. `nil` if the tool could
    /// not be run.
    func list(folder: String? = nil) async -> [ShortcutListing]? {
        var arguments = ["list", "--show-identifiers"]
        if let folder { arguments += ["--folder-name", folder] }
        return await listOutput(arguments).map(Self.listings)
    }

    /// The person's folders of shortcuts, with their identifiers.
    func folders() async -> [ShortcutListing]? {
        await listOutput(["list", "--folders", "--show-identifiers"]).map(Self.listings)
    }

    private func listOutput(_ arguments: [String]) async -> String? {
        guard let result = await ToolRun(executable, arguments, capturesOutput: true).result(timeout: Self.listTimeout),
              result.status == 0
        else { return nil }
        return result.output
    }

    /// Reads `Name (IDENTIFIER)` lines. The identifier is taken from the end of the
    /// line, since a name may have brackets of its own; a line without one is all name.
    static func listings(_ output: String) -> [ShortcutListing] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            guard line.hasSuffix(")"),
                  let open = line.range(of: " (", options: .backwards)
            else { return ShortcutListing(name: line, identifier: nil) }
            let identifier = String(line[open.upperBound..<line.index(before: line.endIndex)])
            let name = String(line[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
            guard UUID(uuidString: identifier) != nil, !name.isEmpty else {
                return ShortcutListing(name: line, identifier: nil)
            }
            return ShortcutListing(name: name, identifier: identifier)
        }
    }

    // MARK: Running

    /// Runs `target` and waits for it to end, for at most `timeout`. Cancelling the task
    /// stops the shortcut. With `capturesOutput`, the text the shortcut hands back comes
    /// with the result.
    ///
    /// Stopping it sends the tool SIGTERM, as the Focus toggle always has. With
    /// `interruptsFirst` it is sent SIGINT first, the one signal the tool handles, by
    /// asking its runner to stop: that records the run as cancelled and takes macOS's
    /// own indicator down cleanly. SIGTERM follows only if the tool is still there
    /// after `ToolRun.interruptGrace`.
    ///
    /// The run is recorded as Islet's while it lasts, so the watch on the Shortcuts
    /// database does not take it for one started elsewhere.
    func run(
        _ target: ShortcutTarget, timeout: TimeInterval, capturesOutput: Bool = false, interruptsFirst: Bool = false
    ) async -> ShortcutRunResult {
        let outputFolder = capturesOutput ? Self.makeOutputFolder() : nil
        defer {
            if let outputFolder { try? FileManager.default.removeItem(at: outputFolder) }
        }

        var arguments = ["run"]
        if let outputFolder {
            // Plain text, whatever the shortcut's last action made: a number, a list or
            // a dictionary comes out as it would be shown.
            arguments += [
                "--output-path", outputFolder.appendingPathComponent(Self.outputName).path,
                "--output-type", "public.plain-text",
            ]
        }
        // "--" ends the options, so a name that starts with a dash is still a name.
        arguments += ["--", target.argument]

        let launch = ShortcutLaunches.shared.begin(target)
        let started = Date()
        let result = await ToolRun(executable, arguments, capturesOutput: false, interruptsFirst: interruptsFirst)
            .result(timeout: timeout)
        ShortcutLaunches.shared.end(launch)

        if Task.isCancelled { return .cancelled }
        guard let result else {
            return Date().timeIntervalSince(started) >= timeout - 1 ? .failed(.timedOut) : .failed(.failed)
        }
        guard result.status == 0 else {
            // The tool says so only in words, and those are localised; the list is exact.
            return await isListed(target) == false ? .failed(.notFound) : .failed(.failed)
        }
        return .succeeded(outputFolder.flatMap { Self.readOutput(in: $0) })
    }

    /// Whether the tool still lists `target`; `nil` if it could not say.
    private func isListed(_ target: ShortcutTarget) async -> Bool? {
        if let identifier = target.identifier {
            return await list()?.contains { $0.identifier?.caseInsensitiveCompare(identifier) == .orderedSame }
        }
        return await names()?.contains(target.name)
    }

    /// A folder of its own for one run's output, so two runs never share a file. The
    /// tool makes the file (or, for several items, perhaps a folder of files) itself.
    private static func makeOutputFolder() -> URL? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("IsletShortcutOutput", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } catch {
            return nil
        }
    }

    /// The text the tool wrote into `folder`, up to `outputLimit` bytes. `nil` when it
    /// wrote nothing, or only white space: the shortcut gave nothing back.
    static func readOutput(in folder: URL) -> ShortcutOutput? {
        let manager = FileManager.default
        let output = folder.appendingPathComponent(outputName)
        var isFolder: ObjCBool = false
        guard manager.fileExists(atPath: output.path, isDirectory: &isFolder) else { return nil }
        let files: [URL]
        if isFolder.boolValue {
            let contents = (try? manager.contentsOfDirectory(
                at: output, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
            )) ?? []
            files = contents
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } else {
            files = [output]
        }

        var data = Data()
        var isTruncated = false
        for file in files {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            if !data.isEmpty { data.append(0x0A) }
            let room = max(0, outputLimit - data.count)
            let chunk = (try? handle.read(upToCount: room + 1)) ?? Data()
            if chunk.count > room {
                data.append(chunk.prefix(room))
                isTruncated = true
                break
            }
            data.append(chunk)
        }

        var text = String(decoding: data, as: UTF8.self)
        // A cut can land inside a character, which decodes as a replacement mark.
        if isTruncated, text.hasSuffix("\u{FFFD}") { text.removeLast() }
        text = text.trimmingCharacters(in: .newlines)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ShortcutOutput(text: text, isTruncated: isTruncated)
    }

    static func openShortcutsApp() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// The runs Islet has started, whatever started them (the Shortcuts feature or the
/// Focus toggle), kept a little past their end.
///
/// Every run writes a record to the Shortcuts database as it starts, and Islet's are
/// no different; the watch on that database asks here whether a new record is one of
/// Islet's before it treats it as a run started elsewhere. The record can arrive after
/// a quick run has already ended, so an ended run is kept for `grace` seconds.
final class ShortcutLaunches: @unchecked Sendable {
    static let shared = ShortcutLaunches()

    /// Long enough for the record of a run to be written and read, with room to spare.
    static let grace: TimeInterval = 15

    private struct Launch {
        var token: Int
        var target: ShortcutTarget
        var began: Date
        var ended: Date?
    }

    private let lock = NSLock()
    // Guarded by `lock`.
    private var launches: [Launch] = []
    private var nextToken = 0

    /// Records a run about to start; pass the token to `end(_:)` once it has.
    func begin(_ target: ShortcutTarget, at date: Date = Date()) -> Int {
        lock.lock()
        defer { lock.unlock() }
        nextToken &+= 1
        launches.append(Launch(token: nextToken, target: target, began: date))
        return nextToken
    }

    func end(_ token: Int, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        if let index = launches.firstIndex(where: { $0.token == token }) { launches[index].ended = date }
    }

    /// Whether a run the database recorded is one of Islet's: one run through the
    /// command line tool (`source`, when the record says) of the shortcut with this
    /// identifier or name, begun around `date`. A run is claimed once; a second record
    /// of the same shortcut needs a second run of Islet's to match.
    func claim(identifier: String?, name: String?, source: String?, date: Date?, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        launches.removeAll { $0.ended.map { now.timeIntervalSince($0) > Self.grace } ?? false }
        if let source, source != "commandline" { return false }

        func isSameShortcut(_ target: ShortcutTarget) -> Bool {
            if let ours = target.identifier, let identifier, ours.caseInsensitiveCompare(identifier) == .orderedSame {
                return true
            }
            if let name, target.name.caseInsensitiveCompare(name) == .orderedSame { return true }
            return false
        }
        // The clocks are the same Mac's, but the record is written a moment after the
        // tool starts; a few seconds either way is the same run.
        func isInTime(_ launch: Launch) -> Bool {
            guard let date else { return true }
            return date >= launch.began.addingTimeInterval(-5) && date <= (launch.ended ?? now).addingTimeInterval(5)
        }
        guard let index = launches.firstIndex(where: { isSameShortcut($0.target) && isInTime($0) }) else { return false }
        launches.remove(at: index)
        return true
    }
}

/// One run of a command line tool, with its arguments passed as they are (no shell).
/// It ends when the tool exits, when its time is up or when the task awaiting it is
/// cancelled, whichever comes first; ending early stops the tool, with SIGTERM and
/// then, if it lingers, SIGKILL — or, for a tool that handles it, SIGINT first. Nothing
/// blocks while it runs but a thread reading its output, which ends with the tool.
///
/// Every tool still going is known here, so that none outlives Islet: see
/// `terminateAll()`.
final class ToolRun: @unchecked Sendable {
    struct Result {
        var status: Int32
        var output: String
    }

    /// How long a tool asked to stop with SIGINT has before it is sent SIGTERM.
    static let interruptGrace: TimeInterval = 1.5

    /// Sends SIGTERM, there and then, to every tool still running: for the app about to
    /// quit. Stopping a run otherwise leaves its SIGTERM (after SIGINT's grace) and its
    /// SIGKILL to timers that a quitting app does not live to fire, so a tool slow to
    /// act on SIGINT would carry on, its shortcut with it, after Islet had gone. The
    /// tool's runner is its own, and goes with it, as the Focus toggle has always
    /// relied on.
    static func terminateAll() {
        for run in running.all() { run.terminateNow() }
    }

    /// The runs whose tools have been started and have not yet exited.
    private static let running = Registry()

    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        // Guarded by `lock`. Held strongly, and only until the tool exits, so a run
        // can always be reached while its tool is there to stop.
        private var runs: [ObjectIdentifier: ToolRun] = [:]

        func insert(_ run: ToolRun) {
            lock.lock()
            defer { lock.unlock() }
            runs[ObjectIdentifier(run)] = run
        }

        func remove(_ run: ToolRun) {
            lock.lock()
            defer { lock.unlock() }
            runs[ObjectIdentifier(run)] = nil
        }

        func all() -> [ToolRun] {
            lock.lock()
            defer { lock.unlock() }
            return Array(runs.values)
        }
    }

    private let process = Process()
    private let pipe: Pipe?
    private let interruptsFirst: Bool
    private let lock = NSLock()
    // Guarded by `lock`.
    private var continuation: CheckedContinuation<Result?, Never>?
    private var isEnded = false
    private var isLaunched = false
    private var status: Int32?
    private var output: Data?

    init(_ executable: URL, _ arguments: [String], capturesOutput: Bool, interruptsFirst: Bool = false) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        pipe = capturesOutput ? Pipe() : nil
        process.standardOutput = pipe ?? FileHandle.nullDevice
        self.interruptsFirst = interruptsFirst
    }

    /// Runs the tool and waits for it. `nil` when it could not be started, took longer
    /// than `timeout` or was cancelled.
    func result(timeout: TimeInterval) async -> Result? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                guard !isEnded else {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                self.continuation = continuation
                lock.unlock()
                launch(timeout: timeout)
            }
        } onCancel: {
            end()
        }
    }

    private func launch(timeout: TimeInterval) {
        // Weak: the run is held by whoever awaits it, and after an early end by the
        // SIGKILL check, for as long as anything will come of it.
        process.terminationHandler = { [weak self] process in
            self?.exited(process.terminationStatus)
        }
        // Known before it starts: a tool that exits at once is let go by the handler
        // above, which must not come first.
        Self.running.insert(self)
        do {
            try process.run()
        } catch {
            Self.running.remove(self)
            end()
            return
        }
        lock.lock()
        isLaunched = true
        let endedAlready = isEnded
        lock.unlock()
        if endedAlready { stop() }

        if let pipe {
            // Read as it comes: a tool that fills the pipe waits for it to be read,
            // and would never exit. The pipe closes when the tool exits.
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                self.lock.lock()
                self.output = data
                self.lock.unlock()
                self.finishIfDone()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.end()
        }
    }

    private func exited(_ status: Int32) {
        lock.lock()
        self.status = status
        lock.unlock()
        Self.running.remove(self)
        finishIfDone()
    }

    private func finishIfDone() {
        lock.lock()
        guard let status, pipe == nil || output != nil else {
            lock.unlock()
            return
        }
        let result = Result(status: status, output: String(decoding: output ?? Data(), as: UTF8.self))
        let continuation = take()
        lock.unlock()
        continuation?.resume(returning: result)
    }

    /// Gives up on the tool: the wait returns `nil` at once, and the tool, if running,
    /// is stopped.
    func end() {
        lock.lock()
        let continuation = take()
        let isRunning = isLaunched && status == nil
        lock.unlock()
        continuation?.resume(returning: nil)
        if isRunning { stop() }
    }

    /// The waiting continuation, once; marks the run ended. Call holding `lock`.
    private func take() -> CheckedContinuation<Result?, Never>? {
        isEnded = true
        defer { continuation = nil }
        return continuation
    }

    private var lingers: Bool {
        lock.lock()
        defer { lock.unlock() }
        return status == nil
    }

    /// SIGTERM, and SIGKILL two seconds on for a tool that ignores it — after SIGINT
    /// and a moment's grace, for a tool that stops cleanly on that.
    private func stop() {
        let pid = process.processIdentifier
        let terminate = { [self] in
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in
                if lingers { kill(pid, SIGKILL) }
            }
        }
        guard interruptsFirst else {
            terminate()
            return
        }
        process.interrupt()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.interruptGrace) { [self] in
            if lingers { terminate() }
        }
    }

    /// SIGTERM at once, with no timer behind it, for `terminateAll()`.
    private func terminateNow() {
        lock.lock()
        let isRunning = isLaunched && status == nil
        lock.unlock()
        if isRunning { process.terminate() }
    }
}
