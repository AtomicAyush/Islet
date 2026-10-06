import Foundation

/// Why a card offers no Allow, only Deny and Answer in the app.
enum ApprovalWithheld: Equatable, Hashable, Sendable {
    /// The host does not withdraw its own prompt when the hook answers.
    case hostNotListed
    /// A key of the tool's input the card has no layout for: it could change what Allow
    /// does unseen.
    case unknownKey(String)
    /// A value not of the kind the card shows for its key.
    case unexpectedValue(String)
    /// A character a reader could not see, or one that reorders the text.
    case hiddenCharacters
    /// A write to, or a command naming, a place that runs things or holds what approves
    /// them: shell start-up files, launch agents, git hooks, Claude's and Codex's
    /// settings and hooks, Islet's folder.
    case sensitivePath(String)
    /// A patch this parser does not follow line by line.
    case patchNotUnderstood
    /// An address that could be read as going to more than one place
    /// (`ApprovalText.isUnclearAddress`).
    case unclearAddress
    /// Islet cannot sign for this agent (`ApprovalSigner.Status`).
    case cannotSign
}

/// What a card shows of a request, and whether it may offer Allow.
struct ApprovalBody: Equatable, Sendable {
    var headline: String
    /// The input's keys in the order drawn: known ones in their layout's order, the rest
    /// after, sorted.
    var keys: [String]
    /// The files a patch names, for Codex's apply_patch.
    var patchFiles: [String] = []
    var withheld: Set<ApprovalWithheld>
    /// What the card draws, every key of the input in it (`sections(_:patchFiles:home:)`).
    var sections: [ApprovalSection] = []

    var offersAllow: Bool { withheld.isEmpty }

    /// The keys each tool's card lays out; any other key withholds Allow.
    static let knownKeys: [String: [String]] = [
        "Bash": ["command", "description", "timeout", "run_in_background", "dangerouslyDisableSandbox"],
        "Write": ["file_path", "content"],
        "Edit": ["file_path", "old_string", "new_string", "replace_all"],
        "MultiEdit": ["file_path", "edits"],
        "NotebookEdit": ["notebook_path", "cell_id", "new_source", "cell_type", "edit_mode"],
        "WebFetch": ["url", "prompt"],
        "WebSearch": ["query", "allowed_domains", "blocked_domains"],
    ]
    /// Codex hands its hook only these.
    static let codexKnownKeys: [String: [String]] = [
        "Bash": ["command", "description"],
        "apply_patch": ["command"],
        "Edit": ["command"],
        "Write": ["command"],
    ]

    /// The tools shown at all, as the hook offers them.
    static func isShown(_ tool: String, agent: ApprovalAgent) -> Bool {
        if tool.hasPrefix("mcp__") { return true }
        switch agent {
        case .claude: return knownKeys[tool] != nil
        case .chatgpt: return codexKnownKeys[tool] != nil
        }
    }

    static func make(_ request: ApprovalRequest, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ApprovalBody {
        var withheld = Set<ApprovalWithheld>()
        if !request.allowOffered { withheld.insert(.hostNotListed) }
        let tool = request.tool
        let isMCP = tool.hasPrefix("mcp__")
        let known = (request.agent == .claude ? knownKeys : codexKnownKeys)[tool] ?? []
        if !isMCP {
            for key in request.input.keys where !known.contains(key) { withheld.insert(.unknownKey(key)) }
        }
        let keys = known.filter { request.input[$0] != nil } + request.input.keys.filter { !known.contains($0) }.sorted()
        let paths = ApprovalPaths(home: home, cwd: request.cwd)

        // The header's words, strictly.
        let header = [request.cwd, request.project, request.agentType, request.hostName, tool]
        if header.contains(where: { ApprovalText.hiddenCharacter(in: $0, rule: .strict) != nil }) {
            withheld.insert(.hiddenCharacters)
        }

        func string(_ key: String, required: Bool = true) -> String? {
            guard let value = request.input[key] else {
                if required { withheld.insert(.unexpectedValue(key)) }
                return nil
            }
            guard case .string(let text) = value else {
                withheld.insert(.unexpectedValue(key))
                return nil
            }
            return text
        }
        func strict(_ text: String?) {
            if let text, ApprovalText.hiddenCharacter(in: text, rule: .strict) != nil { withheld.insert(.hiddenCharacters) }
        }
        func lenient(_ text: String?) {
            if let text, ApprovalText.hiddenCharacter(in: text, rule: .lenient) != nil { withheld.insert(.hiddenCharacters) }
        }
        func path(_ key: String) {
            guard let file = string(key) else { return }
            strict(file)
            if let reason = paths.sensitive(file) { withheld.insert(.sensitivePath(reason)) }
        }
        func flag(_ key: String) {
            if let value = request.input[key], case .bool = value {} else if request.input[key] != nil {
                withheld.insert(.unexpectedValue(key))
            }
        }

        var headline = "Use \(tool)"
        var patchFiles: [String] = []
        switch (request.agent, tool) {
        case (.claude, "Bash"):
            let command = string("command")
            strict(command)
            lenient(string("description", required: false))
            if let command, let reason = paths.named(in: command) { withheld.insert(.sensitivePath(reason)) }
            flag("run_in_background")
            flag("dangerouslyDisableSandbox")
            if let timeout = request.input["timeout"], case .number = timeout {} else if request.input["timeout"] != nil {
                withheld.insert(.unexpectedValue("timeout"))
            }
            headline = request.input["dangerouslyDisableSandbox"] == .bool(true)
                ? "Run a command outside the sandbox" : "Run a command"
        case (.chatgpt, "Bash"):
            let command = string("command")
            strict(command)
            lenient(string("description", required: false))
            if let command, let reason = paths.named(in: command) { withheld.insert(.sensitivePath(reason)) }
            // Codex's description is the model's own justification, a network request's
            // target among them: it is shown as what ChatGPT says, never as Islet's words.
            headline = "Run a command with more access"
        case (.claude, "Write"):
            path("file_path")
            lenient(string("content"))
            headline = "Write a file"
        case (.claude, "Edit"):
            path("file_path")
            lenient(string("old_string"))
            lenient(string("new_string"))
            flag("replace_all")
            headline = "Edit a file"
        case (.claude, "MultiEdit"):
            path("file_path")
            if case .array(let edits)? = request.input["edits"] {
                for edit in edits {
                    guard case .object(let fields) = edit,
                          Set(fields.keys).isSubset(of: ["old_string", "new_string", "replace_all"]),
                          let old = fields["old_string"]?.string, let new = fields["new_string"]?.string
                    else {
                        withheld.insert(.unexpectedValue("edits"))
                        continue
                    }
                    lenient(old)
                    lenient(new)
                }
            } else {
                withheld.insert(.unexpectedValue("edits"))
            }
            headline = "Edit a file"
        case (.claude, "NotebookEdit"):
            path("notebook_path")
            strict(string("cell_id", required: false))
            lenient(string("new_source"))
            strict(string("cell_type", required: false))
            strict(string("edit_mode", required: false))
            headline = "Edit a notebook"
        case (.claude, "WebFetch"):
            let url = string("url")
            strict(url)
            if let url, ApprovalText.isUnclearAddress(url) { withheld.insert(.unclearAddress) }
            lenient(string("prompt", required: false))
            headline = "Fetch a page"
        case (.claude, "WebSearch"):
            strict(string("query"))
            for key in ["allowed_domains", "blocked_domains"] {
                guard let value = request.input[key] else { continue }
                guard case .array(let items) = value, items.allSatisfy({ $0.string != nil }) else {
                    withheld.insert(.unexpectedValue(key))
                    continue
                }
                items.compactMap(\.string).forEach { strict($0) }
            }
            headline = "Search the web"
        case (.chatgpt, "apply_patch"), (.chatgpt, "Edit"), (.chatgpt, "Write"):
            if let patch = string("command") {
                lenient(patch)
                if let files = ApprovalPatch.files(in: patch) {
                    patchFiles = files
                    for file in files {
                        strict(file)
                        if let reason = paths.sensitive(file) { withheld.insert(.sensitivePath(reason)) }
                    }
                } else {
                    withheld.insert(.patchNotUnderstood)
                }
            }
            headline = "Change files"
        default:
            if isMCP {
                let parts = tool.dropFirst(5).components(separatedBy: "__")
                let server = parts.first ?? ""
                let name = parts.dropFirst().joined(separator: "__")
                headline = name.isEmpty ? "Use \(server)" : "Use \(name) from \(server)"
                for key in request.input.keys { strict(key) }
                for value in request.input.values { value.strings.forEach { lenient($0) } }
                for text in request.input.values.flatMap(\.strings) { if let reason = paths.named(in: text) {
                    withheld.insert(.sensitivePath(reason))
                } }
            } else {
                withheld.insert(.unknownKey(tool))
            }
        }
        return ApprovalBody(headline: headline, keys: keys, patchFiles: patchFiles, withheld: withheld,
                            sections: sections(request, patchFiles: patchFiles, home: home))
    }
}

/// The places whose writes withhold Allow: what runs at login or in a shell, a git
/// repository's hooks, Claude's and Codex's settings and hooks (the hook scripts and
/// their key files among them), and Islet's own folder. The home folder's volume does
/// not tell capitals from small letters, and takes `ſ` and `ß` for `s` and `ss` as well,
/// so neither do these: `~/.CLAUDE` is `~/.claude`, and `~/.zſhenv` is `~/.zshenv`.
struct ApprovalPaths {
    let home: String
    let cwd: String

    init(home: URL, cwd: String) {
        self.home = home.standardizedFileURL.path
        self.cwd = cwd
    }

    static let shellFiles = [".zshrc", ".zshenv", ".zprofile", ".zlogin", ".zlogout", ".bashrc", ".bash_profile",
                             ".bash_login", ".bash_logout", ".profile", ".login", ".cshrc", ".tcshrc", ".inputrc"]
    static let homeFolders = ["Library/LaunchAgents", ".claude", ".codex", "Library/Application Support/Islet",
                              ".config/fish", ".ssh"]
    /// Words that, in a command or a tool's argument, name such a place, in any capitals.
    static let namedInText = [".claude/", ".codex/", "islet-approvals", "Islet/Approvals", "Application Support/Islet",
                              "LaunchAgents", ".git/hooks", ".git/config", ".zshrc", ".zshenv", ".zprofile", ".bashrc",
                              ".bash_profile", ".profile", ".ssh", ApprovalKeychain.service]

    /// The place `path` writes to, if it is one of them: relative paths taken from the
    /// agent's folder, `~` from the home folder. The part of the path already there is
    /// followed through its links, `..` as the system takes it, so a new file reached
    /// through a linked folder counts where it lands; a link inside the agent's folder
    /// that leads out of it counts as such a place too.
    func sensitive(_ path: String) -> String? {
        var full = path
        if full == "~" || full.hasPrefix("~/") { full = home + full.dropFirst() }
        if !full.hasPrefix("/") { full = cwd + "/" + full }
        let plain = URL(fileURLWithPath: full).standardizedFileURL.path
        let resolved = Self.resolve(full)
        let homes = Set([home, Self.resolve(home)].flatMap(Self.forms))
        for candidate in Set([plain, resolved].flatMap(Self.forms)) {
            if let place = place(candidate, homes: homes) { return place }
        }
        let folder = Self.key(URL(fileURLWithPath: cwd).standardizedFileURL.path)
        let folderResolved = Self.key(Self.resolve(cwd))
        if Self.within(Self.key(plain), folder), !Self.within(Self.key(resolved), folderResolved) {
            return "a place outside the folder, through a link"
        }
        return nil
    }

    private func place(_ full: String, homes: Set<String>) -> String? {
        for base in homes {
            for name in Self.shellFiles where full == base + "/" + Self.key(name) { return "~/" + name }
            for folder in Self.homeFolders where Self.within(full, base + "/" + Self.key(folder)) {
                return "~/" + folder
            }
        }
        if full.contains("/.git/hooks/") || full.hasSuffix("/.git/hooks") || full.hasSuffix("/.git/config") {
            return ".git/hooks"
        }
        // A project's own settings can add hooks too.
        for folder in [".claude", ".codex"] where full.contains("/\(folder)/") || full.hasSuffix("/\(folder)") {
            return folder
        }
        return nil
    }

    /// The first such place named in a command or argument.
    func named(in text: String) -> String? {
        let text = Self.key(text)
        return Self.namedInText.first { text.contains(Self.key($0)) }
    }

    /// `path` as compared: composed and case folded, as the volume compares names.
    static func key(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil)
    }

    /// `path` as compared, and as the same place without the data volume's own name
    /// (`/System/Volumes/Data/Users/…` is `/Users/…`).
    static func forms(_ path: String) -> [String] {
        let path = key(path)
        let data = "/system/volumes/data/"
        return path.hasPrefix(data) ? [path, String(path.dropFirst(data.count - 1))] : [path]
    }

    static func within(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    /// `path` with the longest part of it that exists resolved by the system (links
    /// followed, `..` taken after them, letters as stored), and the rest added back
    /// with its `..` worked out.
    static func resolve(_ path: String) -> String {
        var parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var rest: [String] = []
        while true {
            let head = "/" + parts.joined(separator: "/")
            if let real = realpath(head, nil) {
                defer { free(real) }
                var full = String(cString: real)
                for part in rest {
                    switch part {
                    case ".": continue
                    case "..": full = (full as NSString).deletingLastPathComponent
                    default: full = full == "/" ? "/" + part : full + "/" + part
                    }
                }
                return full
            }
            guard let last = parts.popLast() else { return URL(fileURLWithPath: path).standardizedFileURL.path }
            rest.insert(last, at: 0)
        }
    }
}

/// Codex's patches (`*** Begin Patch` … `*** End Patch`), followed strictly: every
/// line a header, a hunk marker or a hunk's line, every path relative and within the
/// folder. `nil` for anything else.
enum ApprovalPatch {
    static func files(in patch: String) -> [String]? {
        var lines = patch.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.first == "*** Begin Patch", lines.last == "*** End Patch", lines.count >= 2 else { return nil }
        var files: [String] = []
        var inFile = false
        for line in lines.dropFirst().dropLast() {
            if let path = header(line, "*** Add File: ") ?? header(line, "*** Update File: ") ?? header(line, "*** Delete File: ") {
                guard safe(path) else { return nil }
                files.append(path)
                inFile = !line.hasPrefix("*** Delete File: ")
            } else if let path = header(line, "*** Move to: ") {
                guard inFile, safe(path) else { return nil }
                files.append(path)
            } else if inFile, line.hasPrefix("@@") || line.hasPrefix("+") || line.hasPrefix("-") || line.hasPrefix(" ")
                        || line == "*** End of File" || line.isEmpty {
                continue
            } else {
                return nil
            }
        }
        return files.isEmpty ? nil : files
    }

    private static func header(_ line: String, _ prefix: String) -> String? {
        line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
    }

    private static func safe(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.hasPrefix("~")
            && !path.split(separator: "/").contains("..")
    }
}

extension ApprovalBody {
    /// The body as drawn, a section for every key of the input: the tool's own layout
    /// for the keys it knows, `key = value` for any other, and the model's words last.
    static func sections(_ request: ApprovalRequest, patchFiles: [String], home: URL) -> [ApprovalSection] {
        let input = request.input
        var shown = Set<String>()
        var sections: [ApprovalSection] = []
        func text(_ key: String) -> String? {
            guard let value = input[key] else { return nil }
            shown.insert(key)
            return value.string ?? value.json
        }
        func code(_ key: String, label: String? = nil) {
            if let value = text(key) { sections.append(ApprovalSection(label: label, text: value, style: .code)) }
        }
        func field(_ key: String) {
            if let value = text(key) { sections.append(ApprovalSection(label: nil, text: "\(key) = \(value)", style: .field)) }
        }
        let says = "\(request.agent.name) says"

        switch request.tool {
        case "Bash":
            code("command")
            for key in ["timeout", "run_in_background", "dangerouslyDisableSandbox"] { field(key) }
        case "Write":
            if let path = text("file_path") {
                let exists = FileManager.default.fileExists(atPath: Self.resolve(path, cwd: request.cwd, home: home))
                // A file's last line ends with a return, which starts no line of its own.
                let content = input["content"]?.string ?? ""
                let count = ApprovalLines.realLines(content).count - (content.hasSuffix("\n") ? 1 : 0)
                sections.append(ApprovalSection(
                    label: (exists ? "Replaces the file" : "New file") + " · \(count) line\(count == 1 ? "" : "s")",
                    text: path, style: .code))
            }
            code("content", label: "content")
        case "Edit":
            code("file_path")
            if let old = text("old_string") { sections.append(ApprovalSection(label: nil, text: old, style: .removed)) }
            if let new = text("new_string") { sections.append(ApprovalSection(label: nil, text: new, style: .added)) }
            field("replace_all")
        case "MultiEdit":
            code("file_path")
            if case .array(let edits)? = input["edits"] {
                shown.insert("edits")
                for (index, edit) in edits.enumerated() {
                    guard case .object(let fields) = edit else {
                        sections.append(ApprovalSection(label: "edit \(index + 1)", text: edit.json, style: .field))
                        continue
                    }
                    let label = "Edit \(index + 1) of \(edits.count)" + (fields["replace_all"] == .bool(true) ? ", every match" : "")
                    sections.append(ApprovalSection(label: label, text: fields["old_string"]?.string ?? "", style: .removed))
                    sections.append(ApprovalSection(label: nil, text: fields["new_string"]?.string ?? "", style: .added))
                    for key in fields.keys.sorted() where !["old_string", "new_string", "replace_all"].contains(key) {
                        sections.append(ApprovalSection(label: nil, text: "\(key) = \(fields[key]!.json)", style: .field))
                    }
                }
            }
        case "NotebookEdit":
            code("notebook_path")
            for key in ["cell_id", "edit_mode", "cell_type"] { field(key) }
            code("new_source", label: "new_source")
        case "WebFetch":
            if let url = text("url") {
                let hosts = ApprovalText.urlHosts(in: url)
                sections.append(ApprovalSection(label: nil, text: url, style: .code, bold: hosts))
                for host in hosts where ApprovalText.asciiHost(host) != host.lowercased() {
                    sections.append(ApprovalSection(label: nil, text: "host = \(ApprovalText.asciiHost(host))", style: .field))
                }
            }
            if let prompt = text("prompt") { sections.append(ApprovalSection(label: "prompt", text: prompt, style: .prose)) }
        case "WebSearch":
            code("query")
            for key in ["allowed_domains", "blocked_domains"] { field(key) }
        case "apply_patch":
            if !patchFiles.isEmpty {
                sections.append(ApprovalSection(label: nil, text: "files = " + patchFiles.joined(separator: ", "), style: .field))
            }
            code("command")
        default:
            if request.tool.hasPrefix("mcp__") {
                for key in input.keys.sorted() {
                    shown.insert(key)
                    sections.append(ApprovalSection(label: key, text: input[key]!.pretty(), style: .code))
                }
            } else if request.agent == .chatgpt {
                // Codex's Edit and Write carry a patch, as apply_patch does.
                if !patchFiles.isEmpty {
                    sections.append(ApprovalSection(label: nil, text: "files = " + patchFiles.joined(separator: ", "),
                                                    style: .field))
                }
                code("command")
            }
        }
        for key in input.keys.sorted() where !shown.contains(key) && key != "description" { field(key) }
        if let words = text("description"), !words.isEmpty {
            sections.append(ApprovalSection(label: says, text: words, style: .prose))
        }
        return sections
    }

    /// `path` as a full path: `~` from the home folder, a relative one from `cwd`.
    static func resolve(_ path: String, cwd: String, home: URL) -> String {
        if path == "~" || path.hasPrefix("~/") { return home.path + path.dropFirst() }
        return path.hasPrefix("/") ? path : cwd + "/" + path
    }
}

extension ApprovalValue {
    /// The value as indented JSON, keys in order, for a tool's arguments.
    func pretty(_ indent: String = "") -> String {
        let inner = indent + "  "
        switch self {
        case .array(let values) where !values.isEmpty:
            return "[\n" + values.map { inner + $0.pretty(inner) }.joined(separator: ",\n") + "\n" + indent + "]"
        case .object(let values) where !values.isEmpty:
            return "{\n" + values.keys.sorted().map { inner + ApprovalValue.string($0).json + ": " + values[$0]!.pretty(inner) }
                .joined(separator: ",\n") + "\n" + indent + "}"
        case .string(let value) where indent.isEmpty:
            return value
        default:
            return json
        }
    }
}
