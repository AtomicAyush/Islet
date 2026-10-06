import CryptoKit
import Foundation

/// The agent asking.
enum ApprovalAgent: String, Sendable, CaseIterable {
    case claude
    case chatgpt

    var name: String {
        switch self {
        case .claude: "Claude"
        case .chatgpt: "ChatGPT"
        }
    }
}

/// How the agent's own prompt and the hook's wait go together.
enum ApprovalPolicy: String, Sendable {
    /// The app asks at the same moment, and the first answer wins (Claude Code under the
    /// Claude app).
    case concurrent
    /// The app asks only once the hook is done, so the hook waits only briefly (Codex,
    /// and Claude Code in a terminal).
    case blocking
}

/// A permission asked, as a hook offered it in `Requests/<id>.json`. What the tool is
/// to do is `call`, the exact text the hook made of the tool's name and input; Islet
/// works out its digest itself, so a file changed after the hook wrote it can show
/// other words but never earn an answer the hook takes.
struct ApprovalRequest: Equatable, Identifiable, Sendable {
    var id: String
    var agent: ApprovalAgent
    var policy: ApprovalPolicy
    /// Whether the hook found a host that withdraws its own prompt when the hook
    /// answers; Allow is offered only then.
    var allowOffered: Bool
    var sessionId: String
    var agentId: String
    var agentType: String
    var promptId: String
    var turnId: String
    var cwd: String
    var project: String
    var hostApp: String
    var hostName: String
    var transcriptPath: String
    var permissionMode: String
    var hookPid: Int32
    var hookStarted: Date
    var agentPid: Int32
    var created: Date
    var deadline: Date
    var tool: String
    /// The tool's input, every key of it.
    var input: [String: ApprovalValue]
    /// The SHA-256 of `call`, hex, as Islet worked it out.
    var digest: String
    /// Main's fingerprint of the input, linking the request to the session's pending
    /// entry; "" where the hook gave none.
    var pendingInput: String
    /// The request file as it was read, to tell it changed before Allow.
    var stamp: ApprovalFiles.Stamp

    /// The command, for a Bash request.
    var command: String? { tool == "Bash" ? input["command"]?.string : nil }
    var isBlocking: Bool { policy == .blocking }
}

/// A JSON value from a tool's input, kept whole so every key can be drawn.
indirect enum ApprovalValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([ApprovalValue])
    case object([String: ApprovalValue])

    init(_ any: Any) {
        switch any {
        case let value as String: self = .string(value)
        case let value as NSNumber:
            self = CFGetTypeID(value) == CFBooleanGetTypeID() ? .bool(value.boolValue) : .number(value.doubleValue)
        case let value as [Any]: self = .array(value.map(ApprovalValue.init))
        case let value as [String: Any]: self = .object(value.mapValues(ApprovalValue.init))
        default: self = .null
        }
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The value as one line of JSON, keys in order, for drawing a key the card has no
    /// layout for.
    var json: String {
        switch self {
        case .string(let value):
            let data = (try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])) ?? Data()
            return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
        case .number(let value): return value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .array(let values): return "[" + values.map(\.json).joined(separator: ",") + "]"
        case .object(let values):
            return "{" + values.keys.sorted().map { ApprovalValue.string($0).json + ":" + values[$0]!.json }
                .joined(separator: ",") + "}"
        }
    }

    /// Every string within, keys of objects included.
    var strings: [String] {
        switch self {
        case .string(let value): [value]
        case .array(let values): values.flatMap(\.strings)
        case .object(let values): values.keys.sorted() + values.keys.sorted().flatMap { values[$0]!.strings }
        default: []
        }
    }
}

/// Reads and checks request files.
enum ApprovalRequestReader {
    /// The largest request a hook writes: the call is at most 256 KB, and the rest small.
    static let sizeLimit = 300 * 1024
    /// How long before the request a hook may have started: the hook waits its turn for
    /// the session's file before offering.
    static let hookStartSlack: TimeInterval = 60
    /// The longest wait a hook asks for.
    static let longestWait: TimeInterval = 600

    enum Refusal: Error, Equatable {
        case unreadable, malformed, wrongName, badPid, hookGone, hookStartedElsewhen, badTimes, callMismatch
    }

    /// The request in `url`, or why it is refused. `startTime` gives when a process
    /// started, `nil` for one not running.
    static func read(_ url: URL, now: Date, startTime: (Int32) -> Date? = ClaudeProcess.startTime(of:))
        -> Result<ApprovalRequest, Refusal> {
        let name = url.deletingPathExtension().lastPathComponent
        guard url.pathExtension == "json", ApprovalFolder.isID(name) else { return .failure(.wrongName) }
        guard let file = ApprovalFiles.read(url, limit: sizeLimit) else { return .failure(.unreadable) }
        return parse(file.data, id: name, stamp: file.stamp, now: now, startTime: startTime)
    }

    static func parse(_ data: Data, id: String, stamp: ApprovalFiles.Stamp, now: Date,
                      startTime: (Int32) -> Date?) -> Result<ApprovalRequest, Refusal> {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["version"] as? Int == 1, object["id"] as? String == id,
              let agent = (object["agent"] as? String).flatMap(ApprovalAgent.init(rawValue:)),
              let policy = (object["policy"] as? String).flatMap(ApprovalPolicy.init(rawValue:)),
              let call = object["call"] as? String, let tool = object["tool"] as? String
        else { return .failure(.malformed) }
        func text(_ key: String) -> String { object[key] as? String ?? "" }
        func whole(_ key: String) -> Int64? {
            guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            guard value == value.rounded(), abs(value) < 1e12 else { return nil }
            return Int64(value)
        }
        guard let hookPid = whole("hookPid"), (2...99_999).contains(hookPid),
              let agentPid = whole("agentPid"), agentPid == 0 || (2...99_999).contains(agentPid)
        else { return .failure(.badPid) }
        guard let created = whole("created"), let deadline = whole("deadline"), let hookStarted = whole("hookStarted"),
              deadline > created, Double(deadline - created) <= longestWait,
              Double(created) <= now.timeIntervalSince1970 + 2
        else { return .failure(.badTimes) }
        // The hook still running: started as it says, and not long before it asked.
        guard let started = startTime(Int32(hookPid)) else { return .failure(.hookGone) }
        let start = started.timeIntervalSince1970
        guard abs(start - Double(hookStarted)) <= 2, start >= Double(created) - hookStartSlack,
              start <= Double(created) + 2
        else { return .failure(.hookStartedElsewhen) }
        // The call is the tool and its input, and the request's tool is the call's.
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(call.utf8)) as? [String: Any],
              parsed["tool"] as? String == tool, Set(parsed.keys) == ["tool", "input"]
        else { return .failure(.callMismatch) }
        let input: [String: ApprovalValue]
        switch parsed["input"].map(ApprovalValue.init) {
        case .object(let values)?: input = values
        default: return .failure(.callMismatch)
        }
        let digest = SHA256.hash(data: Data(call.utf8)).map { String(format: "%02x", $0) }.joined()
        if let given = object["digest"] as? String, given != digest { return .failure(.callMismatch) }
        return .success(ApprovalRequest(
            id: id, agent: agent, policy: policy, allowOffered: object["allowOffered"] as? Bool ?? false,
            sessionId: text("sessionId"), agentId: text("agentId"), agentType: text("agentType"),
            promptId: text("promptId"), turnId: text("turnId"), cwd: text("cwd"), project: text("project"),
            hostApp: text("hostApp"), hostName: text("hostName"), transcriptPath: text("transcriptPath"),
            permissionMode: text("permissionMode"), hookPid: Int32(hookPid),
            hookStarted: Date(timeIntervalSince1970: Double(hookStarted)), agentPid: Int32(agentPid),
            created: Date(timeIntervalSince1970: Double(created)), deadline: Date(timeIntervalSince1970: Double(deadline)),
            tool: tool, input: input, digest: digest, pendingInput: text("pendingInput"), stamp: stamp))
    }

    /// Whether the hook that offered `request` is still running: the same process, not
    /// a later one given its number.
    static func hookAlive(_ request: ApprovalRequest, startTime: (Int32) -> Date? = ClaudeProcess.startTime(of:)) -> Bool {
        guard let started = startTime(request.hookPid) else { return false }
        return abs(started.timeIntervalSince1970 - request.hookStarted.timeIntervalSince1970) <= 2
    }
}
