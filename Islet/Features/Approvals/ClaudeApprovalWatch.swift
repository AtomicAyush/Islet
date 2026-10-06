import Foundation

/// How Islet tells a Claude Code request was answered in the app, which says nothing to
/// the hook: the first of these withdraws the card.
enum ClaudeApprovalSignal: String, Equatable, Sendable {
    /// The command is running: Claude Code started a shell for it since the asking
    /// (`ClaudeBashCommand`), Bash only.
    case commandRunning
    /// The session's pending entry for it is gone: the allowed tool ended, or the turn
    /// ended or a prompt was sent.
    case pendingGone
    /// The transcript has the tool's result (a denial lands at once), a later message,
    /// or an interruption.
    case transcript
    /// The hook has gone, or the session's Claude Code.
    case gone
}

/// Reads the signals for the requests on show. Called off the main thread.
enum ClaudeApprovalWatch {
    /// What the watch knew from earlier looks.
    struct Memory: Sendable {
        /// The requests whose pending entry has been seen in their session's file, by id.
        var seenPending: Set<String> = []
    }

    /// The folders a transcript may be read from: Claude Code's projects folder, in the
    /// home folder or `$CLAUDE_CONFIG_DIR`.
    static func transcriptRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var roots = [home.appendingPathComponent(".claude/projects").path]
        if let config = environment["CLAUDE_CONFIG_DIR"], config.hasPrefix("/") {
            roots.append(URL(fileURLWithPath: config).appendingPathComponent("projects").path)
        }
        return roots
    }

    /// For each request, the first signal that it was answered in the app, if any.
    static func look(
        _ requests: [ApprovalRequest], records: [ClaudeSessionRecord], memory: inout Memory, roots: [String],
        children: (Int32) -> [ClaudeProcess.Child] = ClaudeProcess.children(of:),
        hookAlive: (ApprovalRequest) -> Bool = { ApprovalRequestReader.hookAlive($0) }
    ) -> [String: ClaudeApprovalSignal] {
        var signals: [String: ClaudeApprovalSignal] = [:]
        let claude = requests.filter { $0.agent == .claude }
        let byAgent = Dictionary(grouping: claude.filter { $0.agentPid > 1 }, by: \.agentPid)
        // 1. Each command running, but for one asked twice at once: its shell cannot say
        // which was allowed.
        for (pid, asked) in byAgent {
            let bash = asked.filter { $0.command != nil }
            guard !bash.isEmpty else { continue }
            let pending = bash.map { request in
                ClaudePermissionRequest(agentId: request.agentId, tool: "Bash", at: request.created,
                                        command: ClaudeBashCommand.fingerprint(request.command ?? ""))
            }
            let running = ClaudeBashCommand.running(pending, children: children(pid))
            for (request, running) in zip(bash, running) where running { signals[request.id] = .commandRunning }
        }
        let sessions = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for request in claude where signals[request.id] == nil {
            // 4. The hook gone, or the session over.
            if !hookAlive(request) {
                signals[request.id] = .gone
                continue
            }
            let record = sessions[request.sessionId]
            if let record, ClaudeProcess.isRunning(record) == false {
                signals[request.id] = .gone
                continue
            }
            // 2. Its pending entry, once seen, gone.
            if let record, !request.pendingInput.isEmpty {
                let listed = record.pending.contains { entry in
                    entry.agentId == request.agentId && entry.tool == request.tool && entry.input == request.pendingInput
                }
                if listed {
                    memory.seenPending.insert(request.id)
                } else if memory.seenPending.contains(request.id) {
                    signals[request.id] = .pendingGone
                    continue
                }
            }
            // 3. The transcript.
            if let path = allowedTranscript(request.transcriptPath, roots: roots),
               ClaudeApprovalTranscript.answered(request, path: path) {
                signals[request.id] = .transcript
            }
        }
        memory.seenPending.formIntersection(Set(claude.map(\.id)))
        return signals
    }

    /// `path`, if it is a transcript under one of `roots`, no `..` in it.
    static func allowedTranscript(_ path: String, roots: [String]) -> String? {
        guard path.hasPrefix("/"), path.hasSuffix(".jsonl"), !path.split(separator: "/").contains("..") else { return nil }
        return roots.contains { path.hasPrefix($0 + "/") } ? path : nil
    }
}

/// Reads the end of a transcript for what became of a tool call.
enum ClaudeApprovalTranscript {
    static let tailLength = 1024 * 1024
    private static let interruption = "[Request interrupted by user"

    /// Whether the transcript shows `request`'s call answered: the latest call of the
    /// same tool with the same input followed by its result, a later message, or an
    /// interruption.
    static func answered(_ request: ApprovalRequest, path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(tailLength) ? size - UInt64(tailLength) : 0)
        guard let data = try? handle.readToEnd() else { return false }
        return answered(request, lines: data.split(separator: UInt8(ascii: "\n")).map { Data($0) })
    }

    static func answered(_ request: ApprovalRequest, lines: [Data]) -> Bool {
        let wanted = ApprovalValue.object(request.input)
        var call: (id: String, message: String)?
        var after = false
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = object["message"] as? [String: Any]
            else { continue }
            let blocks = message["content"] as? [[String: Any]] ?? []
            let type = object["type"] as? String
            if type == "assistant" {
                let messageID = message["id"] as? String ?? ""
                if let use = blocks.last(where: { block in
                    block["type"] as? String == "tool_use" && block["name"] as? String == request.tool
                        && block["input"].map(ApprovalValue.init) == wanted
                }), let id = use["id"] as? String {
                    call = (id, messageID)
                    after = false
                } else if let call, messageID != call.message {
                    after = true
                }
            } else if type == "user", let call {
                if blocks.contains(where: { $0["type"] as? String == "tool_result" && $0["tool_use_id"] as? String == call.id }) {
                    after = true
                }
                let texts = blocks.compactMap { $0["text"] as? String } + [message["content"] as? String].compactMap { $0 }
                if texts.contains(where: { $0.hasPrefix(interruption) }) { after = true }
            }
        }
        return call != nil && after
    }
}
