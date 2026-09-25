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

    /// A Set Focus shortcut takes a second or two. One still going after a minute is
    /// waiting on something nobody will answer (an Ask for Input, a Focus set to "Ask
    /// Each Time"), or the runner has wedged; it is stopped, so the next click works.
    static let runTimeout: TimeInterval = 60

    /// The names of the person's shortcuts, sorted as Finder would, or `nil` if the
    /// tool could not be run, or did not answer in time.
    static func list(tool: ShortcutsTool = .system) async -> [String]? {
        await tool.names()
    }

    /// Runs the shortcut called `name`. `nil` when it ran to the end. Cancelling the
    /// task stops the shortcut.
    ///
    /// Through the runner the Shortcuts feature uses, which records the run as Islet's:
    /// that feature's watch for runs started elsewhere then leaves it to the banner
    /// here.
    static func run(_ name: String, tool: ShortcutsTool = .system) async -> Failure? {
        switch await tool.run(ShortcutTarget(identifier: nil, name: name), timeout: runTimeout) {
        case .succeeded: nil
        case .failed(.notFound): .notFound
        case .failed, .cancelled: .failed
        }
    }

    static func openShortcutsApp() {
        ShortcutsTool.openShortcutsApp()
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

    @ObservationIgnored private let tool: ShortcutsTool
    @ObservationIgnored private var isListing = false
    @ObservationIgnored private var listedAt = Date.distantPast

    init(tool: ShortcutsTool = .system) {
        self.tool = tool
    }

    func refresh() {
        // Hovering in and out of the picker should not list over and over.
        guard !isListing, Date().timeIntervalSince(listedAt) > 2 else { return }
        isListing = true
        Task {
            let listed = await FocusShortcut.list(tool: tool)
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
    @ObservationIgnored private let tool: ShortcutsTool

    init(tool: ShortcutsTool = .system) {
        self.tool = tool
    }

    func run(_ name: String) {
        guard !isRunning else { return }
        isRunning = true
        clearTask?.cancel()
        failure = nil
        runTask = Task { [weak self, tool] in
            let failure = await FocusShortcut.run(name, tool: tool)
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
