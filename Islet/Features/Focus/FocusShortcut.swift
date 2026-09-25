import AppKit
import Observation

/// Turning Focus on and off, which no public API allows: Islet runs a shortcut the
/// person made with the Set Focus action, through the `shortcuts` command line tool,
/// and the database watch shows what it did.
enum FocusShortcut {
    enum Failure: Equatable {
        /// No shortcut by that name any more: renamed or deleted.
        case notFound
        /// It ran and failed, or could not be started.
        case failed
    }

    private static let tool = URL(fileURLWithPath: "/usr/bin/shortcuts")
    /// A Set Focus shortcut takes a second or two. One still going after a minute is
    /// waiting on something nobody will answer (an Ask for Input, a Focus set to "Ask
    /// Each Time"), or the runner has wedged; it is stopped, so the next click works.
    static let runTimeout: TimeInterval = 60
    static let listTimeout: TimeInterval = 10

    /// The names of the person's shortcuts, sorted as Finder would, or `nil` if the
    /// tool could not be run, or did not answer in time.
    static func list() async -> [String]? {
        guard let result = await ToolRun(tool, ["list"], capturesOutput: true).result(timeout: listTimeout),
              result.status == 0
        else { return nil }
        let names = result.output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(Set(names)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Runs the shortcut called `name`. `nil` when it ran to the end. Cancelling the
    /// task stops the shortcut.
    static func run(_ name: String) async -> Failure? {
        // "--" ends the options, so a name that starts with a dash is still a name.
        let run = ToolRun(tool, ["run", "--", name], capturesOutput: false)
        guard let result = await run.result(timeout: runTimeout) else { return .failed }
        guard result.status != 0 else { return nil }
        // The tool says so only in words, and those are localised; the list is exact.
        if let names = await list(), !names.contains(name) { return .notFound }
        return .failed
    }

    static func openShortcutsApp() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// The person's shortcuts, for the picker in Settings. Listed when Settings shows the
/// picker and again as the pointer reaches it, so a shortcut made a moment ago in
/// Shortcuts is there to pick.
@MainActor
@Observable
final class FocusShortcutList {
    /// `nil` until the first listing comes back.
    private(set) var names: [String]?

    @ObservationIgnored private var isListing = false
    @ObservationIgnored private var listedAt = Date.distantPast

    func refresh() {
        // Hovering in and out of the picker should not list over and over.
        guard !isListing, Date().timeIntervalSince(listedAt) > 2 else { return }
        isListing = true
        Task {
            let listed = await FocusShortcut.list()
            names = listed ?? names ?? []
            listedAt = Date()
            isListing = false
        }
    }
}

/// Runs the chosen shortcut, one run at a time, and holds on to what went wrong long
/// enough for the home tile to say so.
@MainActor
@Observable
final class FocusToggle {
    private(set) var isRunning = false
    private(set) var failure: FocusShortcut.Failure?

    /// Called on the main actor when a run fails; never for a run cancelled.
    @ObservationIgnored var onFailure: (_ failure: FocusShortcut.Failure) -> Void = { _ in }
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var clearTask: Task<Void, Never>?

    func run(_ name: String) {
        guard !isRunning else { return }
        isRunning = true
        clearTask?.cancel()
        failure = nil
        runTask = Task { [weak self] in
            let failure = await FocusShortcut.run(name)
            guard let self, !Task.isCancelled else { return }
            runTask = nil
            isRunning = false
            guard let failure else { return }
            self.failure = failure
            onFailure(failure)
            clearTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.failure = nil
            }
        }
    }

    /// Stops a run in progress, shortcut and all, and forgets any failure: nothing
    /// more is reported. For the feature being switched off.
    func cancel() {
        runTask?.cancel()
        runTask = nil
        clearTask?.cancel()
        clearTask = nil
        isRunning = false
        failure = nil
    }
}

/// One run of a command line tool, with its arguments passed as they are (no shell).
/// It ends when the tool exits, when its time is up or when the task awaiting it is
/// cancelled, whichever comes first; ending early stops the tool, with SIGTERM and
/// then, if it lingers, SIGKILL. Nothing blocks while it runs but a thread reading
/// its output, which ends with the tool.
final class ToolRun: @unchecked Sendable {
    struct Result {
        var status: Int32
        var output: String
    }

    private let process = Process()
    private let pipe: Pipe?
    private let lock = NSLock()
    // Guarded by `lock`.
    private var continuation: CheckedContinuation<Result?, Never>?
    private var isEnded = false
    private var isLaunched = false
    private var status: Int32?
    private var output: Data?

    init(_ executable: URL, _ arguments: [String], capturesOutput: Bool) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        pipe = capturesOutput ? Pipe() : nil
        process.standardOutput = pipe ?? FileHandle.nullDevice
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
        do {
            try process.run()
        } catch {
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

    /// SIGTERM, and SIGKILL two seconds on for a tool that ignores it.
    private func stop() {
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in
            lock.lock()
            let lingers = status == nil
            lock.unlock()
            if lingers { kill(pid, SIGKILL) }
        }
    }
}

/// The panes of System Settings the Focus feature points to.
enum FocusSystemSettings {
    static func openFocus() {
        open("x-apple.systempreferences:com.apple.Focus-Settings.extension")
    }

    static func openFullDiskAccess() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
