import AppKit
import Foundation

/// What hooks need to know before offering a request, as Islet sees it now.
struct ApprovalConditions: Equatable, Sendable {
    /// The agents Islet takes requests from: approvals on, and the hook's key Islet's.
    var accepting: Set<ApprovalAgent> = []
    /// How long a blocking request may wait, in seconds, by host kind.
    var chatGPTWait = 30
    var terminalWait = 30
    /// The screen locked, or the Mac asleep.
    var locked = false
    /// Presentation Mode on.
    var presenting = false
    /// The screen being shared or recorded, before Presentation Mode has come on.
    var captured = false
    /// The island showing on the display with the pointer.
    var visible = true
    /// The frontmost app's bundle id.
    var frontmost = ""

    /// Whether a blocking request could be shown now.
    var showsBlocking: Bool { !locked && !presenting && !captured && visible }
}

/// Reads the conditions, and keeps `presence.json` saying them while Islet takes
/// requests. Hooks trust the file only while the process it names is running and
/// started when it says, so a file left by an Islet that crashed offers nothing.
@MainActor
final class ApprovalPresence {
    let folder: ApprovalFolder
    private let processStart: Date
    private var written: ApprovalConditions?

    init(folder: ApprovalFolder, processStart: Date? = nil) {
        self.folder = folder
        self.processStart = processStart
            ?? ClaudeProcess.startTime(of: getpid()) ?? Date()
    }

    /// Writes the file if what it says has changed.
    func update(_ conditions: ApprovalConditions, now: Date = Date()) {
        guard conditions != written else { return }
        let object: [String: Any] = [
            "version": 1,
            "pid": Int(getpid()),
            "started": Int(processStart.timeIntervalSince1970),
            "accepting": Dictionary(uniqueKeysWithValues: ApprovalAgent.allCases.map {
                ($0.rawValue, conditions.accepting.contains($0))
            }),
            "wait": ["chatgpt": conditions.chatGPTWait, "terminal": conditions.terminalWait],
            "locked": conditions.locked, "presenting": conditions.presenting, "captured": conditions.captured,
            "visible": conditions.visible, "frontmost": conditions.frontmost,
            "updated": Int(now.timeIntervalSince1970),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              ApprovalFiles.write(data, to: folder.presence, exclusive: false)
        else { return }
        written = conditions
    }

    /// Takes the file away: Islet is going, or takes no requests.
    func withdraw() {
        ApprovalFiles.remove(folder.presence)
        written = nil
    }
}

/// Watches the lock, sleep and the frontmost app; the rest is read when asked.
@MainActor
final class ApprovalConditionWatch {
    private(set) var locked = false
    private(set) var asleep = false
    var onChange: () -> Void = {}
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    func start() {
        locked = Self.screenIsLocked()
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        let watch: [(NotificationCenter, Notification.Name, @MainActor (ApprovalConditionWatch) -> Void)] = [
            (distributed, Notification.Name("com.apple.screenIsLocked"), { $0.locked = true }),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), { $0.locked = false }),
            (workspace, NSWorkspace.willSleepNotification, { $0.asleep = true }),
            (workspace, NSWorkspace.screensDidSleepNotification, { $0.asleep = true }),
            (workspace, NSWorkspace.didWakeNotification, { $0.asleep = false }),
            (workspace, NSWorkspace.screensDidWakeNotification, { $0.asleep = false }),
            (workspace, NSWorkspace.didActivateApplicationNotification, { _ in }),
        ]
        for (center, name, apply) in watch {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    apply(self)
                    self.onChange()
                }
            }
            observers.append((center, token))
        }
    }

    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }

    var frontmost: String { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "" }

    /// Whether the session's screen is locked now, from the window server.
    static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
