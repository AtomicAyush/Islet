import Foundation
import Network
import os

/// Claude's limits asked for afresh where the numbers shown have grown old: the smallest
/// request Claude's command line tool can make, signed in with Quick Ask's token and run
/// as Quick Ask runs it (`ClaudeAskBackend`: no session saved, no tools, none of the
/// person's settings, hooks or MCP servers, its configuration in the run's own folder),
/// with the cheapest model, a one-word prompt and a one-line system prompt. Claude's tool
/// says the limits (`rate_limit_event`) as the answer's headers come, before any of the
/// answer, and the run is stopped there and then, SIGTERM and SIGKILL a second on, so
/// that next to nothing is generated. A run that starts its answer without them is
/// stopped as the first words come, and any run at `timeout`.
///
/// It is made only as the AI Usage tile or the Claude Code page is about to show, where
/// the newest figures are over 20 minutes old, at most once every 15 minutes (kept across
/// relaunches), and never while offline, without a token, without the Claude app's tool,
/// while the island saves energy or in Low Power Mode, or while Quick Ask is asking
/// Claude. Nothing of it shows in Quick Ask, and a failure is said in Settings alone.
enum ClaudeUsageRefresh {
    /// Figures older than this are refreshed: as old as dims them.
    static let oldAfter: TimeInterval = UsageStatus.staleAfter
    /// The least time between two refreshes.
    static let interval: TimeInterval = 15 * 60
    /// The longest a refresh runs before it is stopped.
    static let timeout: TimeInterval = 20
    /// What is asked: one word, answered in one, if the answer were ever let start.
    static let prompt = "Hi"
    static let systemPrompt = "Reply with one word."

    /// Quick Ask's arguments with the short system prompt in place of its own.
    static var arguments: [String] { ClaudeAskBackend.arguments(systemPrompt: systemPrompt) }

    /// How Islet gets at Claude and at what holds a refresh back, which tests replace.
    struct System {
        /// Quick Ask's tool, token store, environment and folder for runs.
        var setup: ClaudeAskBackend.Setup
        /// Called off the main thread.
        var offline: @Sendable () -> Bool
        var lowPower: () -> Bool
        /// Whether Quick Ask is asking Claude now.
        var asking: () -> Bool
        var timeout: TimeInterval = ClaudeUsageRefresh.timeout

        static var live: System {
            System(
                setup: .standard,
                offline: { ClaudeUsageRefresh.isOffline() },
                lowPower: { ProcessInfo.processInfo.isLowPowerModeEnabled },
                asking: { ClaudeRuns.quickAsk.isRunning }
            )
        }
    }

    /// Why no refresh is made.
    enum Skip: Equatable, Sendable {
        /// Turned off in Settings.
        case off
        /// Claude's limits aren't read: its activity is off, or Show usage limits is.
        case notShown
        /// The Claude app's record hasn't been looked at yet since its limits began
        /// showing.
        case notReadYet
        case underWay
        /// The newest figures are no older than `oldAfter`.
        case fresh
        /// One was made less than `interval` ago.
        case tooSoon
        /// The island saves energy.
        case saving
        case lowPower
        case notInstalled
        case noToken
        /// Quick Ask is asking Claude, and its answer will say the limits.
        case asking
        case offline
    }

    /// What came of a refresh.
    enum Outcome: Equatable, Sendable {
        case read(ClaudeUsage.LimitEvent)
        /// Claude turned the token away.
        case notSignedIn
        /// The tool exited, or began its answer, without saying the limits.
        case noFigures
        /// Nothing came within `timeout`.
        case timedOut
        /// The tool couldn't be started, or said it had failed.
        case failed
    }

    /// What Settings says of refreshing: what came of the last refresh, or what stops
    /// one where it is due.
    enum Note: Equatable, Sendable {
        case done(Date, Outcome)
        case cannot(Skip)
    }

    /// The run of `launch`, until the limits come, the answer starts without them, the
    /// tool exits or `launch` gives up on it. Leaving the loop over its output stops the
    /// tool at once.
    @MainActor
    static func run(_ launch: AskProcess.Launch) async -> Outcome {
        var parser = ClaudeOutput()
        do {
            for try await output in AskProcess.run(launch) {
                switch output {
                case .line(let line):
                    let answer = try parser.take(line)
                    if var event = parser.takeLimits() {
                        event.source = .refresh
                        return .read(event)
                    }
                    if answer != nil { return .noFigures }
                case .exited:
                    return .noFigures
                }
            }
            return .noFigures
        } catch {
            switch error {
            case AskFailure.notSignedIn: return .notSignedIn
            case AskProcess.Failure.timedOut, AskProcess.Failure.silent: return .timedOut
            default: return .failed
            }
        }
    }

    /// The launch of a refresh: Quick Ask's, with the short prompts, given up on after
    /// `timeout`.
    static func launch(_ binary: URL, token: String, system: System) -> AskProcess.Launch {
        var launch = ClaudeAskBackend.launch(binary, token: token, environment: system.setup.environment,
                                             arguments: arguments, input: Data(prompt.utf8), parent: system.setup.parent)
        launch.firstOutput = system.timeout
        launch.total = system.timeout
        return launch
    }

    /// Whether the Mac is offline as the system sees it, asked once and waited for up to
    /// a second; online where it doesn't say. Called off the main thread.
    static func isOffline(wait: TimeInterval = 1) -> Bool {
        let monitor = NWPathMonitor()
        let said = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let answered = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { path in
            said.withLock { $0 = path.status == .unsatisfied }
            answered.signal()
        }
        monitor.start(queue: DispatchQueue(label: "com.ayush.Islet.UsageLimits.network", qos: .utility))
        _ = answered.wait(timeout: .now() + wait)
        monitor.cancel()
        return said.withLock { $0 } ?? false
    }
}

/// Quick Ask's runs of Claude going now, which a refresh of Claude's limits waits out.
final class ClaudeRuns: @unchecked Sendable {
    static let quickAsk = ClaudeRuns()

    private let lock = NSLock()
    // Guarded by `lock`.
    private var count = 0

    func begin() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func end() {
        lock.lock()
        count = max(0, count - 1)
        lock.unlock()
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return count > 0
    }
}
