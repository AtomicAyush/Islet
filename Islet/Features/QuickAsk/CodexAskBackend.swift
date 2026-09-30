import AppKit
import Foundation

/// ChatGPT, through the command line tool that comes inside the ChatGPT app (Codex),
/// signed in as the app is. Each question is a run of its own, which keeps nothing: no
/// session, no history, none of the person's configuration, hooks, plugins, MCP servers
/// or project instructions, and no tools at all — no shell, no files, no web. Codex has
/// no switch for the last, so Islet gives it a model with none (`CodexCatalog`), and
/// without that it does not run.
@MainActor
final class CodexAskBackend: AskBackend {
    let provider = AskProvider.chatGPT

    struct Setup {
        /// The tool, if the ChatGPT app is installed.
        var binary: () -> URL?
        /// Codex's list of models, which the ChatGPT app keeps up to date.
        var modelsCache: URL
        var environment: [String: String]
        var parent = FileManager.default.temporaryDirectory

        static var standard: Setup {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Setup(
                binary: { CodexAskBackend.findBinary() },
                modelsCache: home.appendingPathComponent(".codex/models_cache.json"),
                environment: AskEnvironment.base(extra: [:])
            )
        }
    }

    private let setup: Setup
    var offline: () -> Bool = { AskNetwork.shared.isOffline }

    init(setup: Setup = .standard) {
        self.setup = setup
    }

    nonisolated static let bundleID = "com.openai.chat"
    nonisolated static let toolPath = "Contents/Resources/codex-cli/bin/codex"

    nonisolated static func findBinary() -> URL? {
        let apps = [NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
                    URL(fileURLWithPath: "/Applications/ChatGPT.app")].compactMap { $0 }
        return apps.map { $0.appendingPathComponent(toolPath) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func status() -> AskStatus {
        guard setup.binary() != nil else { return .notInstalled }
        guard CodexCatalog.build(from: setup.modelsCache) != nil else { return .notReady }
        return .ready
    }

    func prepare() {}
    func close() {}

    func answer(_ question: String, after earlier: [AskTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard let binary = setup.binary() else { return continuation.finish(throwing: AskFailure.notInstalled) }
            // Never with Codex's own tools: no model without them, no run.
            guard let catalog = CodexCatalog.build(from: setup.modelsCache) else {
                return continuation.finish(throwing: AskFailure.notReady)
            }
            if offline() { return continuation.finish(throwing: AskFailure.offline) }
            let launch = AskProcess.Launch(
                executable: binary,
                arguments: { Self.arguments(folder: $0, model: catalog.model) },
                environment: { [environment = setup.environment] _ in environment },
                files: ["instructions.md": Data(AskInstructions.text.utf8), "catalog.json": catalog.json],
                input: Data(AskInstructions.prompt(question, after: earlier).utf8),
                parent: setup.parent
            )
            let task = Task {
                var parser = CodexOutput()
                do {
                    for try await output in AskProcess.run(launch) {
                        switch output {
                        case .line(let line):
                            if let answer = try parser.take(line) { continuation.yield(answer) }
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

    /// Codex's arguments, in the run's own folder: an ephemeral run that reads none of
    /// the person's configuration, rules, skills or project files, sends no analytics,
    /// keeps no history, and asks for nothing, with every feature that could give the
    /// model a tool turned off as well as the model having none. The question comes on
    /// stdin. Only a global AGENTS.md in Codex's own folder can't be left out.
    nonisolated static func arguments(folder: URL, model: String) -> [String] {
        let path = folder.path
        return [
            "exec", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check",
            "--sandbox", "read-only", "--json", "-C", path, "-m", model,
            "-c", "model_catalog_json=\(path)/catalog.json",
            "-c", "model_instructions_file=\(path)/instructions.md",
            "-c", "model_reasoning_effort=low",
            "-c", "approval_policy=never",
            "-c", "history.persistence=none",
            "-c", "log_dir=\(path)/log",
            "-c", "analytics.enabled=false",
            "-c", "skills.bundled.enabled=false",
            // Not even the names of the person's skills, and not the one tool left that
            // the model would otherwise have: asking the person to choose (Plan mode's).
            "-c", "skills.include_instructions=false",
            "-c", "tools.experimental_request_user_input={enabled=false}",
            "-c", "include_permissions_instructions=false",
            "-c", "include_apps_instructions=false",
            "-c", "include_collaboration_mode_instructions=false",
            "-c", "include_environment_context=false",
            "-c", "web_search=disabled",
            "-c", "project_doc_max_bytes=0",
        ] + disabledFeatures.flatMap { ["--disable", $0] } + ["-"]
    }

    nonisolated static let disabledFeatures = [
        "hooks", "plugins", "apps", "shell_tool", "unified_exec", "view_image", "multi_agent", "browser_use",
        "computer_use", "image_generation", "goals", "sleep_tool", "tool_suggest", "skill_search", "memories",
        "shell_snapshot", "in_app_browser",
    ]
}

/// A model for Codex with no tools, made from the ChatGPT app's own list of models: the
/// fast one, with every tool it would be given taken away and the shell turned off.
/// Anything not as expected — no list, no such model, a list that no longer reads — and
/// there is no model, and ChatGPT is not asked: never with its tools.
enum CodexCatalog {
    /// The fast model, and the one before it.
    static let models = ["gpt-6-luna", "gpt-5.6-luna"]
    static let removed = ["tool_mode", "apply_patch_tool_type", "web_search_tool_type", "multi_agent_version"]

    struct Built {
        var model: String
        var json: Data
    }

    static func build(from cache: URL) -> Built? {
        guard let data = try? Data(contentsOf: cache) else { return nil }
        return build(data)
    }

    static func build(_ data: Data) -> Built? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["models"] as? [[String: Any]] else { return nil }
        for slug in models {
            guard var entry = list.first(where: { $0["slug"] as? String == slug }) else { continue }
            for key in removed { entry[key] = nil }
            entry["shell_type"] = "disabled"
            entry["experimental_supported_tools"] = [String]()
            entry["supports_search_tool"] = false
            for key in ["include_skills_usage_instructions", "include_plugin_usage_instructions",
                        "include_apps_usage_instructions"] where entry[key] != nil {
                entry[key] = false
            }
            guard let json = try? JSONSerialization.data(withJSONObject: ["models": [entry]], options: [.sortedKeys]),
                  isToolFree(json, slug: slug) else { return nil }
            return Built(model: slug, json: json)
        }
        return nil
    }

    /// Reads the list back as Codex would, to be sure of what it says.
    static func isToolFree(_ json: Data, slug: String) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let list = root["models"] as? [[String: Any]], list.count == 1,
              let entry = list.first, entry["slug"] as? String == slug else { return false }
        return entry["shell_type"] as? String == "disabled"
            && (entry["experimental_supported_tools"] as? [Any])?.isEmpty == true
            && entry["supports_search_tool"] as? Bool == false
            && removed.allSatisfy { entry[$0] == nil }
    }
}

/// Codex's `--json` lines, as they come: it prints the whole answer at once.
struct CodexOutput {
    private(set) var answer: String?
    private var error: String?

    /// The answer, if this line brings it.
    mutating func take(_ line: String) throws -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "item.completed":
            guard let item = object["item"] as? [String: Any], item["type"] as? String == "agent_message",
                  let text = item["text"] as? String else { return nil }
            answer = text
            return text
        case "error":
            error = object["message"] as? String
            return nil
        case "turn.failed":
            let message = ((object["error"] as? [String: Any])?["message"] as? String) ?? error ?? ""
            throw Self.failure(message)
        default:
            return nil
        }
    }

    func finish(status: Int32) throws {
        guard answer == nil else { return }
        if let error { throw Self.failure(error) }
        throw AskFailure.exited(status)
    }

    static func failure(_ message: String) -> AskFailure {
        let lower = message.lowercased()
        if lower.contains("usage limit") {
            let resets = message.range(of: #"try again (at|in) [^.]+"#, options: .regularExpression)
                .map { String(message[$0].dropFirst("try again ".count)) }
            return .usageLimit(resets: resets)
        }
        if lower.contains("401") || lower.contains("unauthorized") || lower.contains("log in") || lower.contains("login")
            || lower.contains("sign in") {
            return .notSignedIn
        }
        if lower.contains("error sending request") || lower.contains("network") || lower.contains("offline")
            || lower.contains("dns") || lower.contains("connect") {
            return .offline
        }
        if lower.contains("429") || lower.contains("overloaded") || lower.contains("capacity") { return .busy }
        return .provider(AskErrors.oneLine(message))
    }
}
