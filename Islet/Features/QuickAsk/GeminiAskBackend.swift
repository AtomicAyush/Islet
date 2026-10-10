import Foundation

/// Gemini, through Gemini CLI, signed in as it is (`GeminiCLIInstall`). Each question is a
/// run of its own, with Gemini CLI's cheapest, fastest model, that is given nothing to work
/// with: no tools, no extensions, no MCP servers, no skills, none of the person's hooks
/// (Islet's own among them) and no context files; no telemetry or usage statistics, and
/// Islet's instructions in place of Gemini CLI's own. All of that is a settings file and an
/// instructions file in the run's own folder, which Gemini CLI applies over the person's
/// (`GEMINI_CLI_SYSTEM_SETTINGS_PATH`, `GEMINI_SYSTEM_MD`). The answer comes as it is
/// written.
///
/// Gemini CLI saves every session, with no switch to stop it, and keeps a record of each
/// folder it runs in. So it runs in one folder of Islet's that stays, recorded once, with a
/// session id Islet gives it, and as the run ends Islet deletes that session's file from
/// `~/.gemini/tmp`. A run cut short by Islet quitting leaves its file, so each run first
/// deletes any other session of that folder's (only Quick Ask runs there), as Quick Ask
/// does as Islet starts; nothing else in `~/.gemini/tmp` is touched. Gemini CLI writes
/// what it was asked, the picture too, into a report in its temporary folder when the
/// service fails, so that folder is the run's own, which goes as the run ends.
@MainActor
final class GeminiAskBackend: AskBackend {
    let provider = AskProvider.gemini

    struct Setup {
        /// Gemini CLI's command, if it is installed.
        var binary: () -> URL?
        /// Whether it is signed in.
        var signedIn: () -> Bool
        var environment: [String: String]
        /// The home folder whose `~/.gemini/tmp` a run's session is deleted from.
        var home = FileManager.default.homeDirectoryForCurrentUser
        /// Where Gemini CLI runs: a folder of Islet's own.
        var workingDirectory: URL
        var parent = FileManager.default.temporaryDirectory

        static var standard: Setup {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            return Setup(
                binary: { GeminiCLIInstall.findBinary() },
                signedIn: { GeminiCLIInstall.isSignedIn() },
                environment: AskEnvironment.base(extra: [:]),
                workingDirectory: support.appendingPathComponent("Islet/Gemini/Quick Ask", isDirectory: true)
            )
        }
    }

    /// Gemini CLI's name for its cheapest, fastest model, whichever that is.
    nonisolated static let model = "flash-lite"
    /// A name no MCP server has: with it alone allowed, none is.
    nonisolated static let noServer = "islet-none"
    /// The picture's name in the run's folder.
    nonisolated static let imageName = "screen.jpg"

    /// The sessions of runs still under way, which a run's sweep of leftovers keeps.
    private static var running: Set<String> = []

    private let setup: Setup
    var offline: () -> Bool = { AskNetwork.shared.isOffline }

    init(setup: Setup = .standard) {
        self.setup = setup
    }

    /// Deletes the sessions runs cut short by Islet quitting left, off the main thread: as
    /// Quick Ask starts, before any run.
    nonisolated static func removeLeftovers(setup: Setup = .standard) {
        let (folder, home) = (setup.workingDirectory, setup.home)
        DispatchQueue.global(qos: .utility).async {
            GeminiSessionCleanup.removeLeftovers(of: folder, home: home)
        }
    }

    func status() -> AskStatus {
        guard setup.binary() != nil else { return .notInstalled }
        guard setup.signedIn() else { return .signInNeeded }
        return .ready
    }

    func prepare() {}
    func close() {}

    /// Gemini's models all take pictures.
    var takesImages: Bool { setup.binary() != nil }

    func answer(_ question: String, after earlier: [AskTurn]) -> AsyncThrowingStream<String, Error> {
        answer(question, showing: nil, after: earlier)
    }

    /// A picture goes as a file in the run's folder, named in the question as Gemini CLI
    /// takes one (`@path`), the folder added to what it may read; it goes as soon as Gemini
    /// CLI has read it, or as the run ends.
    func answer(_ question: String, showing image: ScreenSnapshot?, after earlier: [AskTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard let binary = setup.binary() else { return continuation.finish(throwing: AskFailure.notInstalled) }
            guard setup.signedIn() else { return continuation.finish(throwing: AskFailure.notSignedIn) }
            if offline() { return continuation.finish(throwing: AskFailure.offline) }
            let working = setup.workingDirectory
            do {
                try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                return continuation.finish(throwing: AskFailure.exited(-1))
            }
            let session = UUID().uuidString.lowercased()
            var files = ["settings.json": Self.settings, "system.md": Data(AskInstructions.text.utf8)]
            if let image { files[Self.imageName] = image.jpeg }
            let text = AskInstructions.prompt(question, showing: image, after: earlier)
            var launch = AskProcess.Launch(
                executable: binary,
                arguments: { Self.arguments(session: session, folder: $0, image: image != nil) },
                environment: { [environment = setup.environment] folder in
                    Self.environment(environment, binary: binary, folder: folder)
                },
                files: files,
                input: Data(Self.input(text, folder: nil, image: false).utf8),
                parent: setup.parent
            )
            launch.workingDirectory = working
            // Why Gemini CLI could not sign in it says only on its standard error.
            launch.keepsErrors = GeminiOutput.errorsKept
            if image != nil {
                // The question names the picture by its path, which only the run's folder gives.
                launch.inputFor = { folder in Data(Self.input(text, folder: folder, image: true).utf8) }
                launch.readOnce = (Self.imageName, GeminiOutput.hasRead)
            }
            let home = setup.home
            let task = Task {
                var parser = GeminiOutput()
                Self.running.insert(session)
                GeminiSessionCleanup.removeLeftovers(of: working, home: home, keeping: Self.running)
                defer {
                    Self.running.remove(session)
                    GeminiSessionCleanup.remove(session, home: home)
                }
                do {
                    for try await output in AskProcess.run(launch) {
                        switch output {
                        case .line(let line):
                            if let answer = try parser.take(line) { continuation.yield(answer) }
                        case .errors(let text):
                            parser.takeErrors(text)
                        case .exited(let status):
                            try parser.finish(status: status)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AskErrors.map(error))
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                // A run stopped early may still be writing its session as it goes.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                    GeminiSessionCleanup.remove(session, home: home)
                }
            }
        }
    }

    /// Headless (the question comes on stdin, never in the arguments), streamed as JSON
    /// lines, with the fast model; the folder trusted for this run alone, so Gemini CLI
    /// neither asks nor stops; no extensions and no MCP server; the session under Islet's
    /// id, for its file to be found and deleted. With a picture, the run's own folder may
    /// be read, for it.
    nonisolated static func arguments(session: String, folder: URL, image: Bool) -> [String] {
        ["-o", "stream-json", "-m", model, "--skip-trust", "-e", "none", "--allowed-mcp-server-names", noServer,
         "--session-id", session] + (image ? ["--include-directories", folder.path] : [])
    }

    /// The settings Gemini CLI applies over the person's, last: no hooks, no tools or
    /// skills, no context files (a name none has), nothing sent about its use, no
    /// checkpoints, no updates. Gemini CLI takes no `admin` settings from this file, so the
    /// person's extensions and MCP servers are kept out by the arguments (`-e none`,
    /// `--allowed-mcp-server-names`); the MCP servers allowed here, none, would still keep
    /// them out without.
    nonisolated static let settings: Data = {
        let settings: [String: Any] = [
            "hooksConfig": ["enabled": false],
            "tools": ["core": [String]()],
            "skills": ["enabled": false],
            "mcp": ["allowed": [noServer]],
            "context": ["fileName": "ISLET-QUICK-ASK-NO-CONTEXT.md", "discoveryMaxDirs": 1],
            "privacy": ["usageStatisticsEnabled": false],
            "telemetry": ["enabled": false],
            "model": ["skipNextSpeakerCheck": true],
            "general": ["checkpointing": ["enabled": false], "enableAutoUpdate": false,
                        "enableAutoUpdateNotification": false],
        ]
        return (try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])) ?? Data("{}".utf8)
    }()

    /// The environment: the base, with the folders Gemini CLI and Node are in first, its
    /// settings and Islet's instructions from the run's folder, the run's folder as its
    /// temporary folder (for its error reports, which hold the question, to go with it and
    /// never land where the hook looks for a CLI session's), and no telemetry or
    /// relaunching itself.
    nonisolated static func environment(_ base: [String: String], binary: URL, folder: URL) -> [String: String] {
        let path = [binary.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", base["PATH"] ?? "/usr/bin:/bin"]
        return base.merging([
            "PATH": path.joined(separator: ":"),
            "TMPDIR": folder.path + "/",
            "GEMINI_CLI_SYSTEM_SETTINGS_PATH": folder.appendingPathComponent("settings.json").path,
            "GEMINI_SYSTEM_MD": folder.appendingPathComponent("system.md").path,
            "GEMINI_TELEMETRY_ENABLED": "false",
            "GEMINI_CLI_NO_RELAUNCH": "true",
            "NO_COLOR": "1",
        ]) { $1 }
    }

    /// What goes on stdin. Gemini CLI reads an `@` and what follows as a file to include,
    /// and a question starting with `/` as one of its commands, so every `@` of the person's
    /// is escaped as it documents (`\@`), and a `/` at the start is put after a word. With
    /// a picture, its path follows on a line of its own, every character but letters,
    /// digits, `/`, `.`, `-` and `_` escaped, as Gemini CLI reads a path with spaces.
    nonisolated static func input(_ text: String, folder: URL?, image: Bool) -> String {
        var text = text.replacingOccurrences(of: "@", with: "\\@")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") { text = "Question: " + text }
        guard image, let folder else { return text }
        return text + "\n@" + escaped(folder.appendingPathComponent(imageName).path)
    }

    nonisolated static func escaped(_ path: String) -> String {
        var out = ""
        for character in path {
            if character.isASCII, character.isLetter || character.isNumber || "/._-".contains(character) {
                out.append(character)
            } else {
                out += "\\" + String(character)
            }
        }
        return out
    }
}

/// Gemini CLI's `stream-json` lines, as they come: the answer in pieces, then a result.
/// And what it printed on its standard error, where alone it says why it could not sign
/// in, which is looked through for that and never shown.
struct GeminiOutput {
    private(set) var answer = ""
    private var error: String?
    private var errors = ""

    /// How much of Gemini CLI's standard error is kept: its reason for not signing in
    /// comes first, before the stack of where it was thrown.
    static let errorsKept = 16_384

    /// The answer so far, if this line adds to it.
    mutating func take(_ line: String) throws -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "message":
            guard object["role"] as? String == "assistant", let content = object["content"] as? String,
                  !content.isEmpty else { return nil }
            answer += content
            return answer
        case "error":
            if object["severity"] as? String == "error", let message = object["message"] as? String { error = message }
            return nil
        case "result":
            guard object["status"] as? String == "error" else { return nil }
            let message = ((object["error"] as? [String: Any])?["message"] as? String) ?? error ?? ""
            throw Self.failure(message)
        default:
            return nil
        }
    }

    /// Gemini CLI has read the picture: it says what it was asked, the picture in it, only
    /// once it has.
    @Sendable
    static func hasRead(_ line: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return false }
        return (type == "message" && object["role"] as? String == "user") || type == "result" || type == "error"
    }

    /// What Gemini CLI printed on its standard error.
    mutating func takeErrors(_ text: String) {
        errors = text
    }

    /// Why the run ended with no answer: a sign-in turned away, as its standard error or
    /// its last error says; signing in cut short by a quota, the network or a busy Google,
    /// as its standard error says; exit 41, Gemini CLI's for a sign-in it has not got; its
    /// last error; a quota its standard error names; signing in failed for no reason it
    /// gives; or the exit status alone.
    func finish(status: Int32) throws {
        guard answer.isEmpty else { return }
        if let problem = GeminiSignIn.problem(in: errors) ?? error.flatMap(GeminiSignIn.problem(in:)) {
            throw AskFailure.signIn(problem)
        }
        // Gemini CLI says "Error authenticating" for whatever stopped it signing in, the
        // network and Google's own quotas and outages too: those are not the sign-in's fault.
        let signingIn = GeminiSignIn.failed(in: errors)
        if signingIn, let failure = Self.cutShort(errors) { throw failure }
        if status == 41 { throw AskFailure.signIn(.notSignedIn) }
        if let error { throw Self.failure(error) }
        if Self.isQuota(errors) { throw AskFailure.usageLimit(resets: Self.resets(errors)) }
        if signingIn { throw AskFailure.signIn(.notSignedIn) }
        throw AskFailure.exited(status)
    }

    /// Words on the standard error saying the network failed, or Google was too busy to
    /// answer. Without the bare "503", which its stack of line numbers could hold by chance.
    static let networkWords = ["fetch failed", "enotfound", "getaddrinfo", "econnrefused", "econnreset", "etimedout",
                               "eai_again", "enetunreach", "ehostunreach", "socket hang up"]
    static let busyWords = ["unavailable", "overloaded"]

    /// A quota, the network or a busy Google, as the standard error says, if it does.
    static func cutShort(_ text: String) -> AskFailure? {
        let lower = text.lowercased()
        if isQuota(text) { return .usageLimit(resets: resets(text)) }
        if networkWords.contains(where: lower.contains) { return .offline }
        if busyWords.contains(where: lower.contains) { return .busy }
        return nil
    }

    /// Words saying a quota or rate limit was reached. Without the bare "429", which the
    /// standard error's stack of line numbers could hold by chance.
    static let quotaWords = ["quota", "resource_exhausted", "resource exhausted", "rate limit", "ratelimit",
                             "too many requests"]

    static func isQuota(_ text: String) -> Bool {
        let lower = text.lowercased()
        return quotaWords.contains(where: lower.contains)
    }

    static func failure(_ message: String) -> AskFailure {
        let lower = message.lowercased()
        if isQuota(message) || lower.contains("429") {
            return .usageLimit(resets: resets(message))
        }
        if let problem = GeminiSignIn.problem(in: message) { return .signIn(problem) }
        if ["401", "re-authenticate", "reauthenticate", "login required", "not logged in", "sign in", "log in",
            "authentication"].contains(where: lower.contains) {
            return .signIn(.notSignedIn)
        }
        if ["fetch failed", "enotfound", "getaddrinfo", "econnrefused", "econnreset", "etimedout", "eai_again",
            "network", "offline"].contains(where: lower.contains) {
            return .offline
        }
        if ["503", "overloaded", "unavailable", "capacity"].contains(where: lower.contains) { return .busy }
        var plain = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if plain.hasPrefix("[API Error: "), plain.hasSuffix("]") { plain = String(plain.dropFirst(12).dropLast()) }
        return .provider(AskErrors.oneLine(plain))
    }

    /// When a quota resets, as the error says ("Please retry in 23.5s", "Suggested retry
    /// after 60s"), in Islet's words; `nil` where it doesn't say.
    static func resets(_ message: String) -> String? {
        guard let match = message.firstMatch(of: #/retry (?:in|after) ([0-9]+(?:\.[0-9]+)?)(ms|s)/#),
              let value = Double(match.output.1) else { return nil }
        let seconds = match.output.2 == "ms" ? value / 1000 : value
        if seconds < 90 { return "in \(max(1, Int(seconds.rounded()))) seconds" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 90 { return "in \(minutes) minutes" }
        return "in about \(Int((seconds / 3600).rounded())) hours"
    }
}

/// Why Gemini CLI turned a question away at signing in, as it says on its standard error
/// or in its stream: in Islet's words, which never repeat Gemini CLI's (they could hold
/// the question, or a key).
enum GeminiSignIn: Equatable, Sendable {
    /// Google no longer lets a personal account signed in with Google use Gemini CLI
    /// (`IneligibleTierError`, reason `UNSUPPORTED_CLIENT`).
    case personalAccount
    /// Google won't let this account use Gemini CLI, for another reason it gives
    /// (`IneligibleTierError`): its location, its age, a work account.
    case accountNotEligible
    /// The Gemini API key Gemini CLI has is not a valid one.
    case invalidKey
    /// Gemini CLI has no sign-in, or could not use the one it has (exit 41).
    case notSignedIn

    /// The problem `text` names, if it names one.
    static func problem(in text: String) -> GeminiSignIn? {
        let lower = text.lowercased()
        if lower.contains("unsupported_client") || lower.contains("this client is no longer supported") {
            return .personalAccount
        }
        if lower.contains("ineligibletiererror") || lower.contains("ineligibletiers") { return .accountNotEligible }
        if ["api key not valid", "api_key_invalid", "invalid api key", "api key expired", "api key is invalid"]
            .contains(where: lower.contains) {
            return .invalidKey
        }
        if ["please set an auth method", "manual authorization is required", "unauthenticated", "invalid_grant"]
            .contains(where: lower.contains) {
            return .notSignedIn
        }
        return nil
    }

    /// Whether `text` says signing in failed, whatever the reason: it may be no fault of
    /// the sign-in, so this is the last thing it is taken for.
    static func failed(in text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("error authenticating") || lower.contains("fatalauthenticationerror")
    }

    /// What went wrong and what can be done: `other` is the provider offered instead, if any.
    func text(instead other: AskProvider?) -> String {
        let ask = other.map { "ask \($0.name) instead" } ?? "ask with another model"
        switch self {
        case .personalAccount: return "Google no longer lets personal accounts use Gemini CLI. Use a Gemini API key, or \(ask)."
        case .accountNotEligible: return "Google won't let this account use Gemini CLI. Use a Gemini API key, or \(ask)."
        case .invalidKey: return "Gemini CLI's API key isn't valid. Check it in gemini's /auth, or \(ask)."
        case .notSignedIn: return "Gemini CLI couldn't sign in. Use a Gemini API key, or \(ask)."
        }
    }
}

/// Deletes a Quick Ask run's session from `~/.gemini/tmp`: the file Gemini CLI saved it in,
/// `chats/session-<time>-<the id's first 8>.jsonl`, only where the file's first line names
/// that session, and a folder of the session's own beside it, if there is one. Nothing else
/// there is touched.
enum GeminiSessionCleanup {
    /// Deletes every session but `keeping` of the project Gemini CLI keeps for `folder`,
    /// Quick Ask's own: the one whose `.project_root` names it. Runs cut short by Islet
    /// quitting leave theirs there.
    nonisolated static func removeLeftovers(of folder: URL, home: URL, keeping: Set<String> = []) {
        let manager = FileManager.default
        let tmp = home.appendingPathComponent(".gemini/tmp", isDirectory: true)
        let names = Set([folder.standardizedFileURL.path, folder.resolvingSymlinksInPath().path])
        let projects = ((try? manager.contentsOfDirectory(atPath: tmp.path)) ?? []).prefix(2000)
        let kept = Set(keeping.map { String($0.prefix(8)) })
        for project in projects {
            let root = tmp.appendingPathComponent(project, isDirectory: true)
            guard let owner = firstLine(root.appendingPathComponent(".project_root")), names.contains(owner) else { continue }
            let chats = root.appendingPathComponent("chats", isDirectory: true)
            guard kind(chats) == .typeDirectory, let entries = try? manager.contentsOfDirectory(atPath: chats.path) else { continue }
            for name in entries {
                let entry = chats.appendingPathComponent(name)
                if name.hasPrefix("session-"), name.hasSuffix(".jsonl"), kind(entry) == .typeRegular {
                    let id = name.dropLast(6).split(separator: "-").last.map(String.init) ?? ""
                    if !kept.contains(id) { try? manager.removeItem(at: entry) }
                } else if UUID(uuidString: name) != nil, !keeping.contains(name.lowercased()), kind(entry) == .typeDirectory {
                    try? manager.removeItem(at: entry)
                }
            }
        }
    }

    /// What `url` is, not following a link.
    private nonisolated static func kind(_ url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    /// A small file's first line, trimmed: at most 4 KB is read.
    private nonisolated static func firstLine(_ file: URL) -> String? {
        guard kind(file) == .typeRegular, let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096), let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: false).first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    nonisolated static func remove(_ session: String, home: URL) {
        guard session.range(of: #"^[0-9a-f-]{36}$"#, options: .regularExpression) != nil else { return }
        let manager = FileManager.default
        let tmp = home.appendingPathComponent(".gemini/tmp", isDirectory: true)
        let projects = ((try? manager.contentsOfDirectory(atPath: tmp.path)) ?? []).prefix(2000)
        let suffix = "-" + session.prefix(8) + ".jsonl"
        for project in projects {
            let chats = tmp.appendingPathComponent(project, isDirectory: true).appendingPathComponent("chats", isDirectory: true)
            guard let names = try? manager.contentsOfDirectory(atPath: chats.path) else { continue }
            for name in names where name.hasPrefix("session-") && name.hasSuffix(suffix) {
                let file = chats.appendingPathComponent(name)
                if isSession(file, session) { try? manager.removeItem(at: file) }
            }
            let own = chats.appendingPathComponent(session, isDirectory: true)
            var isFolder: ObjCBool = false
            if manager.fileExists(atPath: own.path, isDirectory: &isFolder), isFolder.boolValue {
                try? manager.removeItem(at: own)
            }
        }
    }

    /// Whether the file's first line, its header, names `session`: at most 4 KB is read.
    nonisolated static func isSession(_ file: URL, _ session: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return false }
        let line = data.split(separator: UInt8(ascii: "\n"), maxSplits: 1, omittingEmptySubsequences: false).first ?? data
        let header = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
        return header?["sessionId"] as? String == session
    }
}
