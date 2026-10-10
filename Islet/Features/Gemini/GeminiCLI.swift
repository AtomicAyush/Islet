import AppKit
import Foundation

// Gemini CLI, Google's command line agent, beside Antigravity in the Gemini activity: what
// the Mac says of its sessions, where a click on one goes, its hook as Settings gives it,
// and whether it is installed and signed in, for Quick Ask. Islet never writes `~/.gemini`;
// of it, only `settings.json` is read, for the hook and the kind of sign-in, and whether a
// credentials file is there is looked at, never what it holds.

/// What the Mac says of a Gemini CLI session beyond its file: whether its process still
/// runs, when its own file (the transcript Gemini keeps) was last written, and whether a
/// tool it asked about has started a process since. Read off the main thread.
struct GeminiCLILook: Equatable, Sendable {
    /// `nil` when its file names no process.
    var isRunning: Bool?
    var transcriptModified: Date?
    var toolStarted = false

    /// A process the session started this long after asking is the tool it asked about,
    /// allowed; hooks run as it asks start sooner.
    static let toolSlack: TimeInterval = 0.5
    /// What a process of Islet's own hook has in its arguments.
    static let hookMark = GeminiCLIHooks.scriptName

    static func look(at record: GeminiSessionRecord, home: URL) -> GeminiCLILook {
        var look = GeminiCLILook()
        if let pid = record.pid {
            if let started = ClaudeProcess.startTime(of: pid) {
                look.isRunning = record.pidStarted.map { abs(started.timeIntervalSince($0)) <= ClaudeProcess.startSlack } ?? true
            } else {
                look.isRunning = false
            }
        }
        look.transcriptModified = transcriptModified(record.transcriptPath, home: home)
        if record.state == .needsInput, record.waitingFor == .approval, look.isRunning == true, let pid = record.pid {
            let after = record.since.addingTimeInterval(toolSlack)
            look.toolStarted = ClaudeProcess.children(of: pid).contains { child in
                child.started > after && !child.arguments.contains { $0.contains(hookMark) || $0.contains("gemini-cli-hook") }
            }
        }
        return look
    }

    /// When the session's own file was written, if it is an ordinary file inside
    /// `~/.gemini/tmp`, a link or a step up never followed out. Only its date is read.
    static func transcriptModified(_ path: String, home: URL) -> Date? {
        guard path.hasPrefix("/"), path.hasSuffix(".jsonl"), !path.split(separator: "/").contains("..") else { return nil }
        let tmp = home.appendingPathComponent(".gemini/tmp", isDirectory: true).resolvingSymlinksInPath()
            .standardizedFileURL.path
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath()
            .standardizedFileURL.path
        guard folder.hasPrefix(tmp + "/"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular
        else { return nil }
        return attributes[.modificationDate] as? Date
    }
}

/// Where a click on a Gemini CLI session goes, as for Claude Code in a terminal: Terminal
/// or iTerm at the session's tab, found by its terminal (`ClaudeTerminalTabs`), or the app
/// it runs in as it is.
enum GeminiCLIHost {
    /// `nil` where the hook could not tell which app the session runs in.
    nonisolated static func target(for record: GeminiSessionRecord) -> ClaudeOpenTarget? {
        guard record.isCLI, !record.hostApp.isEmpty else { return nil }
        switch record.hostApp {
        case ClaudeHostApps.terminal, ClaudeHostApps.iTerm:
            guard !record.tty.isEmpty else { return .app(record.hostApp) }
            return .terminalTab(app: record.hostApp, tty: "/dev/" + record.tty)
        default:
            return .app(record.hostApp)
        }
    }

    /// Brings the app forward, at the session's tab where it can, if it is running;
    /// returns whether it was.
    @MainActor
    static func open(_ record: GeminiSessionRecord) -> Bool {
        switch target(for: record) {
        case .terminalTab(let bundleID, let tty)?:
            // The app comes forward at once; the tab follows, if Islet may ask for it.
            guard ClaudeHostApps.activate(bundleID) else { return false }
            ClaudeTerminalTabs.select(tty: tty, in: bundleID)
            return true
        case .app(let bundleID)?:
            return ClaudeHostApps.activate(bundleID)
        case .claudeSession?, nil:
            return false
        }
    }

    /// The names a session's row gives the apps Gemini CLI is mostly run in; any other
    /// goes by "Terminal".
    nonisolated static let appNames = [
        ClaudeHostApps.terminal: "Terminal", ClaudeHostApps.iTerm: "iTerm", "com.microsoft.VSCode": "VS Code",
        "com.todesktop.230313mzl4w4u92": "Cursor", "dev.warp.Warp-Stable": "Warp", "com.mitchellh.ghostty": "Ghostty",
        "dev.zed.Zed": "Zed",
    ]
}

/// The tab Terminal or iTerm has in front: its terminal, and in iTerm its session's id.
struct GeminiTerminalTab: Equatable, Sendable {
    /// As `ps` names it, `ttys003`.
    var tty: String
    var session: String = ""
}

/// Whether a Gemini CLI session's tab is the one in front, for leaving its Done banner
/// down. Terminal and iTerm say which tab their front window shows when asked through
/// their scripting, and Islet asks only where macOS already lets it (the person allowed it
/// with a click on a session's row, `ClaudeTerminalTabs`): it never asks for leave here.
/// Nothing is changed in either app. Where it can't be told, the banner shows.
enum GeminiTerminalFront {
    /// The script naming the front window's tab, its tty then a tab and iTerm's session
    /// id; `nil` for an app it does not know. The tab character is made before iTerm's
    /// terms apply: inside them `tab` is iTerm's tab, not the character.
    static func script(for bundleID: String) -> String? {
        switch bundleID {
        case ClaudeHostApps.terminal:
            """
            with timeout of 1 second
              tell application id "com.apple.Terminal" to return (tty of selected tab of window 1)
            end timeout
            """
        case ClaudeHostApps.iTerm:
            """
            with timeout of 1 second
              set gap to character id 9
              tell application id "com.googlecode.iterm2"
                set s to current session of current window
                return (tty of s) & gap & (unique id of s)
              end tell
            end timeout
            """
        default:
            nil
        }
    }

    /// The tab in front of `bundleID`'s front window, asked within a second; `nil` when
    /// Islet may not ask without asking leave first, or the app does not say.
    @MainActor
    static func frontTab(of bundleID: String) -> GeminiTerminalTab? {
        guard let source = script(for: bundleID), isAllowed(bundleID), let script = NSAppleScript(source: source)
        else { return nil }
        var error: NSDictionary?
        return script.executeAndReturnError(&error).stringValue.flatMap(parse)
    }

    /// What a script said: `/dev/ttys003`, then for iTerm a tab and the session's id.
    static func parse(_ text: String) -> GeminiTerminalTab? {
        let parts = text.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard let device = parts.first, device.hasPrefix("/dev/"),
              let tty = ClaudeHostApps.validTTY(String(device.dropFirst(5)))
        else { return nil }
        let session = parts.count > 1 && UUID(uuidString: parts[1]) != nil ? parts[1] : ""
        return GeminiTerminalTab(tty: tty, session: session)
    }

    /// Whether `tab` is the session's: by iTerm's session id where both have one, else by
    /// the terminal.
    static func matches(_ record: GeminiSessionRecord, _ tab: GeminiTerminalTab) -> Bool {
        if !record.itermSession.isEmpty, !tab.session.isEmpty {
            return record.itermSession.caseInsensitiveCompare(tab.session) == .orderedSame
        }
        return !record.tty.isEmpty && record.tty == tab.tty
    }

    private static func isAllowed(_ bundleID: String) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        return withExtendedLifetime(target) {
            guard let address = target.aeDesc else { return false }
            return AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, false) == noErr
        }
    }
}

/// The hooks Gemini CLI needs in `~/.gemini/settings.json`, as Settings shows and copies
/// them and the README gives them: a `"hooks"` entry with each event running the hook
/// script, copied to `~/.gemini/hooks/islet-gemini-cli.sh`, with its kind. Gemini CLI's
/// timeouts are in milliseconds; the script ends within three seconds. Islet never writes
/// `~/.gemini`; the person adds it.
enum GeminiCLIHooks {
    /// The hooks' name, which `hooksConfig.disabled` would list to turn them off.
    static let name = "islet"
    static let scriptName = "islet-gemini-cli.sh"
    static let script = "~/.gemini/hooks/" + scriptName
    static let file = "~/.gemini/settings.json"
    static let events: [(event: String, kind: String)] = [
        ("SessionStart", "start"),
        ("SessionEnd", "end"),
        ("BeforeAgent", "prompt"),
        ("AfterAgent", "stop"),
        ("BeforeTool", "tool-start"),
        ("AfterTool", "tool"),
        ("Notification", "notification"),
    ]
    /// Milliseconds.
    static let timeout = 5000

    /// The entry, `"hooks": { … }`, to go inside the file's outer braces.
    static var entryJSON: String {
        // Two lines a handler, short enough to read in Settings and the README.
        let entries = events.map { event, kind in
            "    \"\(event)\": [\n"
                + "      { \"hooks\": [ { \"name\": \"\(name)\", \"type\": \"command\", \"timeout\": \(timeout),\n"
                + "          \"command\": \"/bin/bash \(script) \(kind)\" } ] }\n"
                + "    ]"
        }
        return "\"hooks\": {\n" + entries.joined(separator: ",\n") + "\n}\n"
    }

    static func copy(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(entryJSON, forType: .string)
    }
}

/// `~/.gemini/settings.json` as Gemini CLI reads it: JSON with comments, which are taken
/// out first. Read-only, at most a megabyte.
enum GeminiSettingsFile {
    static func url(home: URL) -> URL {
        home.appendingPathComponent(".gemini/settings.json")
    }

    enum Read {
        case missing
        case unreadable
        case object([String: Any])
    }

    static func read(home: URL) -> Read {
        let file = url(home: home)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else { return .missing }
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 1_048_576,
              let data = FileManager.default.contents(atPath: file.path),
              let object = parse(String(decoding: data, as: UTF8.self))
        else { return .unreadable }
        return .object(object)
    }

    static func parse(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(stripComments(text).utf8))) as? [String: Any]
    }

    /// `text` without `//` and `/* */` comments, those inside strings left as they are.
    static func stripComments(_ text: String) -> String {
        var out = ""
        var chars = Array(text.unicodeScalars)[...]
        var inString = false
        while let c = chars.first {
            chars = chars.dropFirst()
            if inString {
                out.unicodeScalars.append(c)
                if c == "\\", let next = chars.first {
                    out.unicodeScalars.append(next)
                    chars = chars.dropFirst()
                } else if c == "\"" {
                    inString = false
                }
            } else if c == "\"" {
                inString = true
                out.unicodeScalars.append(c)
            } else if c == "/", chars.first == "/" {
                while let next = chars.first, next != "\n" { chars = chars.dropFirst() }
            } else if c == "/", chars.first == "*" {
                chars = chars.dropFirst()
                while let next = chars.first, !(next == "*" && chars.dropFirst().first == "/") { chars = chars.dropFirst() }
                chars = chars.dropFirst(2)
                out.unicodeScalars.append(" ")
            } else {
                out.unicodeScalars.append(c)
            }
        }
        return out
    }

    /// The value at `path` in `object`, through objects alone.
    static func value(_ object: [String: Any], _ path: String...) -> Any? {
        var current: Any? = object
        for key in path {
            guard let dictionary = current as? [String: Any] else { return nil }
            current = dictionary[key]
        }
        return current
    }
}

/// Whether Islet's hook is set up for Gemini CLI, from `~/.gemini/settings.json` and the
/// script beside it, read-only.
struct GeminiCLIHookSetup: Equatable {
    enum Status: Equatable {
        /// No settings.json.
        case noFile
        /// One that is not JSON, or too big to be one.
        case unreadable
        /// `hooksConfig.enabled` is false: Gemini CLI runs no hooks at all.
        case hooksOff
        /// No hook in it runs Islet's script.
        case notAdded
        /// `hooksConfig.disabled` names Islet's hooks.
        case disabled
        /// On some of its events, not all.
        case partial(missing: [String])
        /// In settings.json, without the script it runs.
        case scriptMissing
        case ready
    }

    var status: Status
    /// Whether Gemini CLI asks folders to be trusted before it runs hooks in them, as it
    /// does unless `security.folderTrust.enabled` is false.
    var trustsFolders = true

    static func check(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> GeminiCLIHookSetup {
        let script = home.appendingPathComponent(".gemini/hooks/" + GeminiCLIHooks.scriptName)
        switch GeminiSettingsFile.read(home: home) {
        case .missing: return GeminiCLIHookSetup(status: .noFile)
        case .unreadable: return GeminiCLIHookSetup(status: .unreadable)
        case .object(let settings):
            return check(settings, scriptExists: FileManager.default.fileExists(atPath: script.path))
        }
    }

    /// What a settings.json's contents say: the events whose hooks run Islet's script.
    static func check(_ settings: [String: Any], scriptExists: Bool) -> GeminiCLIHookSetup {
        let trusts = GeminiSettingsFile.value(settings, "security", "folderTrust", "enabled") as? Bool != false
        func result(_ status: Status) -> GeminiCLIHookSetup { GeminiCLIHookSetup(status: status, trustsFolders: trusts) }
        if GeminiSettingsFile.value(settings, "hooksConfig", "enabled") as? Bool == false { return result(.hooksOff) }
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        var on: Set<String> = []
        var names: Set<String> = []
        for event in GeminiCLIHooks.events.map(\.event) {
            guard let definitions = hooks[event] as? [Any] else { continue }
            for case let definition as [String: Any] in definitions {
                let handlers = [definition] + ((definition["hooks"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
                for handler in handlers {
                    guard let command = handler["command"] as? String, command.contains(GeminiCLIHooks.scriptName) else { continue }
                    on.insert(event)
                    names.insert(handler["name"] as? String ?? command)
                    names.insert(command)
                }
            }
        }
        if on.isEmpty { return result(.notAdded) }
        let disabled = (GeminiSettingsFile.value(settings, "hooksConfig", "disabled") as? [Any] ?? [])
            .compactMap { $0 as? String }
        if disabled.contains(where: names.contains) { return result(.disabled) }
        let missing = GeminiCLIHooks.events.map(\.event).filter { !on.contains($0) }
        if !missing.isEmpty { return result(.partial(missing: missing)) }
        return result(scriptExists ? .ready : .scriptMissing)
    }

    /// The line Settings shows.
    var words: String {
        var line = switch status {
        case .noFile: "Not set up: there's no \(GeminiCLIHooks.file) yet"
        case .unreadable: "Not set up: \(GeminiCLIHooks.file) isn't JSON Islet can read"
        case .hooksOff: "Turned off: hooksConfig.enabled is false, so Gemini CLI runs no hooks"
        case .notAdded: "Not set up: no hook in \(GeminiCLIHooks.file) runs \(GeminiCLIHooks.scriptName)"
        case .disabled: "Turned off: hooksConfig.disabled lists Islet's hook"
        case .partial(let missing):
            "Partly set up: no \(missing.joined(separator: ", ")) hook runs \(GeminiCLIHooks.scriptName)"
        case .scriptMissing: "Not set up: the hooks are there, but \(GeminiCLIHooks.script) is missing"
        case .ready: "Set up"
        }
        if trustsFolders, status == .ready || status == .scriptMissing || status.isPartial {
            line += ". Gemini CLI runs hooks only in folders you trust"
        }
        return line
    }
}

private extension GeminiCLIHookSetup.Status {
    var isPartial: Bool {
        if case .partial = self { return true }
        return false
    }
}

/// Gemini CLI as installed, for Quick Ask: where its command is, and whether it is signed
/// in, told from `settings.json`'s kind of sign-in and, for a Google account, whether its
/// credentials file is there. The credentials themselves are never read.
enum GeminiCLIInstall {
    /// Where Homebrew, npm and the like put the command.
    nonisolated static func findBinary(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let files = FileManager.default
        var places = ["/opt/homebrew/bin/gemini", "/usr/local/bin/gemini"].map(URL.init(fileURLWithPath:))
        places += [".npm-global/bin", ".local/bin", ".volta/bin", ".bun/bin"]
            .map { home.appendingPathComponent($0).appendingPathComponent("gemini") }
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        let versions = (try? files.contentsOfDirectory(atPath: nvm.path)) ?? []
        places += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { nvm.appendingPathComponent($0).appendingPathComponent("bin/gemini") }
        return places.first { files.isExecutableFile(atPath: $0.path) }
    }

    /// The kinds of sign-in Gemini CLI names in `security.auth.selectedType`.
    static let googleAccount = "oauth-personal"

    nonisolated static func isSignedIn(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard case .object(let settings) = GeminiSettingsFile.read(home: home) else { return false }
        let kind = (GeminiSettingsFile.value(settings, "security", "auth", "selectedType") as? String)
            ?? (settings["selectedAuthType"] as? String) ?? ""
        guard !kind.isEmpty else { return false }
        guard kind == googleAccount else { return true }
        let gemini = home.appendingPathComponent(".gemini", isDirectory: true)
        return ["oauth_creds.json", "gemini-credentials.json"].contains { name in
            FileManager.default.fileExists(atPath: gemini.appendingPathComponent(name).path)
        }
    }
}
