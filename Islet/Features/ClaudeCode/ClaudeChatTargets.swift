import AppKit
import Foundation

/// Where a click on a session's row or banner takes the person: the app Claude Code runs
/// in, and inside it the session's own chat or tab where the app can be asked for it.
enum ClaudeOpenTarget: Equatable {
    /// The Claude app at the session, by its link for it,
    /// `claude://code/continue?session=local_…`, which the app also puts in its Dock menu.
    case claudeSession(URL)
    /// Terminal or iTerm, at the tab whose terminal is `tty` (`/dev/ttys003`).
    case terminalTab(app: String, tty: String)
    /// The app as it is: an editor, Warp, or a session the app cannot be asked for.
    case app(String)
}

extension ClaudeHostApps {
    nonisolated static let claudeApp = "com.anthropic.claudefordesktop"
    nonisolated static let terminal = "com.apple.Terminal"
    nonisolated static let iTerm = "com.googlecode.iterm2"

    /// The Claude app's id for a session, as its link takes it: `local_` then letters,
    /// digits and dashes, 64 at most.
    nonisolated static func validHostSession(_ id: String) -> String? {
        let rest = id.utf8.dropFirst(6)
        guard id.hasPrefix("local_"), (1...64).contains(rest.count), rest.allSatisfy(idCharacters.contains)
        else { return nil }
        return id
    }

    private nonisolated static let idCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-".utf8)

    /// A terminal as `ps` names it, `ttys` and a number.
    nonisolated static func validTTY(_ tty: String) -> String? {
        guard tty.hasPrefix("ttys") else { return nil }
        let number = tty.utf8.dropFirst(4)
        guard (1...4).contains(number.count), number.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
        else { return nil }
        return tty
    }

    /// Where a click on `record` goes, from the record alone, and for a session in the
    /// Claude app whose hook did not name the app's id for it, the app's own list of
    /// sessions (`ClaudeAppSessions`) in `appSessions`.
    nonisolated static func target(for record: ClaudeSessionRecord,
                                   appSessions: URL = ClaudeAppSessions.folder) -> ClaudeOpenTarget {
        switch record.hostApp {
        case claudeApp:
            guard let local = appSession(for: record, appSessions: appSessions),
                  let url = URL(string: "claude://code/continue?session=\(local)")
            else { return .app(record.hostApp) }
            return .claudeSession(url)
        case terminal, iTerm:
            guard !record.tty.isEmpty else { return .app(record.hostApp) }
            return .terminalTab(app: record.hostApp, tty: "/dev/" + record.tty)
        default:
            return .app(record.hostApp)
        }
    }

    /// The Claude app's id for the session: as the hook named it, or failing that, as
    /// the app's list has it for Claude Code's id. `nil` for a session in another app.
    nonisolated static func appSession(for record: ClaudeSessionRecord, appSessions: URL) -> String? {
        guard record.hostApp == claudeApp else { return nil }
        if !record.hostSession.isEmpty { return record.hostSession }
        return ClaudeAppSessions.localID(forCLI: record.id, in: appSessions).flatMap(validHostSession)
    }

    /// Brings forward the app `record` runs in, at the session where it can, if the app
    /// is running; returns whether it was.
    static func open(_ record: ClaudeSessionRecord) -> Bool {
        guard !record.hostApp.isEmpty,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: record.hostApp).first
        else { return false }
        switch target(for: record) {
        case .claudeSession(let url):
            guard let appURL = app.bundleURL else { return activate(record.hostApp) }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
            return true
        case .terminalTab(let bundleID, let tty):
            // The app comes forward at once; the tab follows, if Islet may ask for it.
            let opened = activate(bundleID)
            ClaudeTerminalTabs.select(tty: tty, in: bundleID)
            return opened
        case .app(let bundleID):
            return activate(bundleID)
        }
    }
}

/// The Claude app's own list of Claude Code sessions, a file each under
/// `~/Library/Application Support/Claude/claude-code-sessions/<account>/<organisation>/`,
/// read for the few fields that say which session is which and which was last on screen,
/// and nothing else. Read only.
enum ClaudeAppSessions {
    static var folder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Claude/claude-code-sessions", isDirectory: true)
    }

    /// One session's file, as far as it is read.
    struct Entry: Decodable, Equatable {
        /// The app's id, `local_…`.
        var sessionId: String
        /// Claude Code's own id for the session, which its hooks are given.
        var cliSessionId: String?
        /// Claude Code's ids for it before a `/clear` gave it a new one.
        var priorCliSessionIds: [String]?
        var isArchived: Bool?
        /// When the session last came on screen in the app, in milliseconds since 1970.
        /// The app writes it each time one does, and nothing when one goes.
        var lastFocusedAt: Double?
    }

    /// No session file is bigger than this; one that is, is not read.
    static let largestFile = 4 << 20

    /// The session files, two folders down.
    static func files(in folder: URL) -> [URL] {
        let manager = FileManager.default
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        var files: [URL] = []
        for account in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: options)) ?? [] {
            for organisation in (try? manager.contentsOfDirectory(at: account, includingPropertiesForKeys: nil, options: options)) ?? [] {
                let inside = (try? manager.contentsOfDirectory(
                    at: organisation, includingPropertiesForKeys: [.contentModificationDateKey], options: options)) ?? []
                files += inside.filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("local_") }
            }
        }
        return files
    }

    static func entry(at file: URL) -> Entry? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= largestFile,
              let data = try? Data(contentsOf: file)
        else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    /// The app's id for the session Claude Code knows as `cli`, now or before a
    /// `/clear`, if the app has it and it is not archived.
    static func localID(forCLI cli: String, in folder: URL) -> String? {
        guard !cli.isEmpty else { return nil }
        return files(in: folder).lazy.compactMap(entry(at:)).first { entry in
            entry.isArchived != true && (entry.cliSessionId == cli || entry.priorCliSessionIds?.contains(cli) == true)
        }?.sessionId
    }

    /// Whether `local` is the session the app last brought on screen: not archived, and
    /// none other came on screen after it. Only files written since it did are read.
    static func isLastFocused(_ local: String, in folder: URL) -> Bool {
        let files = files(in: folder)
        guard let own = files.first(where: { $0.deletingPathExtension().lastPathComponent == local }),
              let mine = entry(at: own), mine.sessionId == local, mine.isArchived != true,
              let focused = mine.lastFocusedAt
        else { return false }
        let since = Date(timeIntervalSince1970: focused / 1000 - 1)
        for file in files where file != own {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < since { continue }
            if let other = entry(at: file), other.isArchived != true, (other.lastFocusedAt ?? 0) > focused { return false }
        }
        return true
    }
}

/// Whether a reply that finished in a Claude Code session is in front of the person.
/// Only the Claude app says which session it shows: the one it last brought on screen,
/// while it is in front with a window up. A terminal or an editor does not, so a session
/// in one is never taken to be on screen.
enum ClaudeDoneOnScreen {
    static func isOnScreen(_ record: ClaudeSessionRecord, look: ChatScreenLook,
                           appSessions: URL = ClaudeAppSessions.folder) -> Bool {
        guard look.shows(record.hostApp),
              let local = ClaudeHostApps.appSession(for: record, appSessions: appSessions)
        else { return false }
        return ClaudeAppSessions.isLastFocused(local, in: appSessions)
    }
}

/// Selecting a session's tab in Terminal or iTerm, through their scripting. macOS asks
/// the person once whether Islet may control the app; it asks only as the result of a
/// click on a session, never by itself, and once answered, a session's tab is selected
/// only if they said yes. The app has come forward by then either way.
enum ClaudeTerminalTabs {
    private static let queue = DispatchQueue(label: "Islet.ClaudeTerminalTabs")

    /// The script for `bundleID`, which takes the tty as its argument, or `nil` for an
    /// app it does not know.
    static func script(for bundleID: String) -> String? {
        switch bundleID {
        case ClaudeHostApps.terminal:
            """
            on run argv
              set wanted to item 1 of argv
              tell application id "com.apple.Terminal"
                with timeout of 5 seconds
                  repeat with w in windows
                    repeat with t in tabs of w
                      if tty of t is wanted then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        return
                      end if
                    end repeat
                  end repeat
                end timeout
              end tell
            end run
            """
        case ClaudeHostApps.iTerm:
            """
            on run argv
              set wanted to item 1 of argv
              tell application id "com.googlecode.iterm2"
                with timeout of 5 seconds
                  repeat with w in windows
                    repeat with t in tabs of w
                      repeat with s in sessions of t
                        if tty of s is wanted then
                          select w
                          select t
                          select s
                          activate
                          return
                        end if
                      end repeat
                    end repeat
                  end repeat
                end timeout
              end tell
            end run
            """
        default:
            nil
        }
    }

    /// Selects the tab off the main thread, asking leave to first if macOS has not been
    /// told; nothing if the person said no.
    static func select(tty: String, in bundleID: String) {
        guard let script = script(for: bundleID), ClaudeHostApps.validTTY(String(tty.dropFirst(5))) != nil else { return }
        queue.async {
            var status = permission(for: bundleID, asking: false)
            if status == OSStatus(errAEEventWouldRequireUserConsent) { status = permission(for: bundleID, asking: true) }
            guard status == noErr else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script, tty]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }

    private static func permission(for bundleID: String, asking: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        return withExtendedLifetime(target) {
            guard let address = target.aeDesc else { return OSStatus(paramErr) }
            return AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, asking)
        }
    }
}
