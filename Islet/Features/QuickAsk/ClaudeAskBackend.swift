import Foundation
import Security

/// Claude, through the command line tool that comes inside the Claude app (Claude
/// Code). It can't borrow the app's own sign-in, so the person makes a token for it
/// once (`claude setup-token`) and gives it to Islet, which keeps it in its own item in
/// the keychain (`ClaudeTokenStore`).
///
/// Each question is a run of its own that keeps nothing: no session saved, none of the
/// person's settings, hooks, plugins, MCP servers, slash commands or memory, and no
/// tools at all. The answer comes as it is written.
@MainActor
final class ClaudeAskBackend: AskBackend {
    let provider = AskProvider.claude

    struct Setup {
        /// The tool, if the Claude app has one.
        var binary: () -> URL?
        var tokens: any ClaudeTokenStore
        var environment: [String: String]
        var parent = FileManager.default.temporaryDirectory
        /// Where what a run says of Claude's usage limits goes, as it says it.
        var limits: @MainActor (ClaudeUsage.LimitEvent) -> Void = { _ in }

        static var standard: Setup {
            Setup(
                binary: { ClaudeAskBackend.findBinary() },
                tokens: KeychainClaudeTokenStore(),
                environment: AskEnvironment.base(extra: [
                    "DISABLE_TELEMETRY": "1",
                    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
                    "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
                ]),
                limits: { UsageCenter.shared.received($0) }
            )
        }
    }

    /// The cheapest, fastest model.
    nonisolated static let model = "claude-haiku-4-5-20251001"

    private let setup: Setup
    var offline: () -> Bool = { AskNetwork.shared.isOffline }

    init(setup: Setup = .standard) {
        self.setup = setup
    }

    var tokens: any ClaudeTokenStore { setup.tokens }

    /// The Claude app keeps its tool in a folder per version; the newest. The tool sits
    /// directly in that folder, or, from 2.1.286, in a folder of its own inside it.
    nonisolated static func findBinary(
        root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code")
    ) -> URL? {
        let files = FileManager.default
        let versions = (try? files.contentsOfDirectory(atPath: root.path)) ?? []
        for version in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
            let folder = root.appendingPathComponent(version)
            let inside = ((try? files.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
                .map { folder.appendingPathComponent($0) }
            for place in [folder] + inside {
                let binary = place.appendingPathComponent("claude.app/Contents/MacOS/claude")
                if files.isExecutableFile(atPath: binary.path) { return binary }
            }
        }
        return nil
    }

    func status() -> AskStatus {
        guard setup.binary() != nil else { return .notInstalled }
        guard setup.tokens.hasToken else { return .signInNeeded }
        return .ready
    }

    func prepare() {}
    func close() {}

    /// Claude's models all take pictures.
    var takesImages: Bool { setup.binary() != nil }

    func answer(_ question: String, after earlier: [AskTurn]) -> AsyncThrowingStream<String, Error> {
        answer(question, showing: nil, after: earlier)
    }

    /// A picture goes on stdin with the question, as a message of Claude's own (`stream-json`
    /// input), never as a file: Claude Code reads files only with the tools it isn't given.
    func answer(_ question: String, showing image: ScreenSnapshot?, after earlier: [AskTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard let binary = setup.binary() else { return continuation.finish(throwing: AskFailure.notInstalled) }
            guard let token = setup.tokens.token() else { return continuation.finish(throwing: AskFailure.notSignedIn) }
            if offline() { return continuation.finish(throwing: AskFailure.offline) }
            let launch = Self.launch(
                binary, token: token, environment: setup.environment,
                arguments: image == nil ? Self.arguments : Self.imageArguments,
                input: image.map { Self.message(AskInstructions.prompt(question, showing: $0, after: earlier), image: $0) }
                    ?? Data(AskInstructions.prompt(question, after: earlier).utf8),
                parent: setup.parent
            )
            let limits = setup.limits
            ClaudeRuns.quickAsk.begin()
            let task = Task {
                defer { ClaudeRuns.quickAsk.end() }
                var parser = ClaudeOutput()
                do {
                    for try await output in AskProcess.run(launch) {
                        switch output {
                        case .line(let line):
                            if let answer = try parser.take(line) { continuation.yield(answer) }
                            if let event = parser.takeLimits() { limits(event) }
                        case .exited(let status):
                            try parser.finish(status: status)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AskErrors.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A run of the tool signed in with `token`. Claude's own configuration, which it
    /// writes as it starts, goes in the run's folder and with it, not in the person's.
    nonisolated static func launch(
        _ binary: URL, token: String, environment: [String: String], arguments: [String], input: Data, parent: URL
    ) -> AskProcess.Launch {
        AskProcess.Launch(
            executable: binary,
            arguments: { _ in arguments },
            environment: { folder in
                environment.merging([
                    "CLAUDE_CODE_OAUTH_TOKEN": token,
                    "CLAUDE_CONFIG_DIR": folder.appendingPathComponent("config").path,
                ]) { $1 }
            },
            input: input,
            parent: parent
        )
    }

    /// Print mode with no session saved; no tools; no settings from anywhere, so none of
    /// the person's hooks, and hooks off besides; no MCP servers but an empty list; no
    /// slash commands. Streamed as it is written. The empty strings are arguments of
    /// their own: no tools, no setting sources.
    nonisolated static let arguments = [
        "-p", "--no-session-persistence", "--model", model, "--tools", "", "--setting-sources", "",
        "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#, "--disable-slash-commands",
        "--settings", #"{"disableAllHooks":true}"#, "--system-prompt", AskInstructions.text,
        "--output-format", "stream-json", "--include-partial-messages", "--verbose",
    ]

    /// The same with another system prompt: Islet's tiny request for Claude's limits.
    nonisolated static func arguments(systemPrompt: String) -> [String] {
        var list = arguments
        if let index = list.firstIndex(of: "--system-prompt"), index + 1 < list.count { list[index + 1] = systemPrompt }
        return list
    }

    /// The same, with the question coming as a message rather than as text, for a picture
    /// to go in it.
    nonisolated static let imageArguments = arguments + ["--input-format", "stream-json"]

    /// The question and the picture as one user message, on one line: the picture first,
    /// as Anthropic suggests, then the words.
    nonisolated static func message(_ text: String, image: ScreenSnapshot) -> Data {
        let content: [[String: Any]] = [
            ["type": "image", "source": ["type": "base64", "media_type": ScreenSnapshot.mediaType,
                                         "data": image.jpeg.base64EncodedString()]],
            ["type": "text", "text": text],
        ]
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        let data = (try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])) ?? Data()
        return data + Data("\n".utf8)
    }
}

/// Claude's `stream-json` lines, as they come.
struct ClaudeOutput {
    private(set) var answer = ""
    private var isDone = false
    /// What the run last said of Claude's usage limits, until taken.
    private var limits: ClaudeUsage.LimitEvent?

    /// The answer so far, if this line adds to it. A line saying what the limits are
    /// is kept for `takeLimits`; it adds nothing to the answer.
    mutating func take(_ line: String, at date: Date = Date()) throws -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "stream_event":
            guard let event = object["event"] as? [String: Any], event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String, !text.isEmpty else { return nil }
            answer += text
            return answer
        case "system":
            // Retries tell of a refused sign-in long before the last of them gives up.
            guard object["subtype"] as? String == "api_retry" else { return nil }
            let status = object["error_status"] as? Int ?? 0
            if status == 401 || status == 403 { throw AskFailure.notSignedIn }
            if (status == 429 || status == 529), (object["attempt"] as? Int ?? 0) >= 2 { throw AskFailure.busy }
            return nil
        case "rate_limit_event":
            limits = ClaudeUsage.limitEvent(object, at: date) ?? limits
            return nil
        case "result":
            isDone = true
            if object["is_error"] as? Bool == true {
                throw Self.failure(object["result"] as? String ?? "", status: object["api_error_status"] as? Int)
            }
            guard answer.isEmpty, let result = object["result"] as? String, !result.isEmpty else { return nil }
            answer = result
            return answer
        default:
            return nil
        }
    }

    /// What the run has said of the limits since last asked, if anything.
    mutating func takeLimits() -> ClaudeUsage.LimitEvent? {
        defer { limits = nil }
        return limits
    }

    func finish(status: Int32) throws {
        guard answer.isEmpty else { return }
        throw AskFailure.exited(status)
    }

    static func failure(_ message: String, status: Int?) -> AskFailure {
        let lower = message.lowercased()
        if status == 401 || status == 403 || lower.contains("not logged in") || lower.contains("authenticate") {
            return .notSignedIn
        }
        if status == 429 || status == 529 || lower.contains("overloaded") { return .busy }
        return .provider(AskErrors.oneLine(message))
    }
}

/// Where the token for Claude is kept.
protocol ClaudeTokenStore: AnyObject {
    var hasToken: Bool { get }
    func token() -> String?
    func save(_ token: String) throws
    func remove()
}

/// The token in Islet's own keychain item, which Islet alone reads. Islet never reads
/// the Claude app's.
final class KeychainClaudeTokenStore: ClaudeTokenStore {
    static let service = "com.ayush.Islet.ClaudeToken"
    static let account = "Claude"

    enum Failure: Error { case notSaved(OSStatus) }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }

    var hasToken: Bool {
        var probe = query
        probe[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(probe as CFDictionary, nil) == errSecSuccess
    }

    func token() -> String? {
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(read as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func save(_ token: String) throws {
        remove()
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.notSaved(status) }
    }

    func remove() {
        SecItemDelete(query as CFDictionary)
    }
}
