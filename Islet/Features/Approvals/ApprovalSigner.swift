import CryptoKit
import Foundation

/// Signs Islet's answers with the approvals key, so a hook takes an answer only from
/// Islet: the agent and the commands it runs can write into Islet's folder, but cannot
/// read the Keychain.
///
/// The hook checks the signature against the public key in `islet-approvals.pub`
/// beside it, which Islet writes only when clicked to (`install(for:)`, `reset()`).
/// Since any program can replace the Keychain's item unasked, Islet signs for an agent
/// only while its key's public half is the one beside that agent's hook; otherwise the
/// card offers only Answer in the app, and Settings says the key changed outside Islet.
/// For the same reason, the first Set Up makes a key of its own rather than take one
/// found in the Keychain, and a later one writes out only the key already beside the
/// other hooks.
@MainActor
final class ApprovalSigner {
    enum Status: Equatable {
        /// Not read yet: it is read at the first Allow or Deny, or when Settings shows.
        case unread
        /// The key is at hand and matches the file beside the hook.
        case ready
        /// No key file beside the hook: approvals are not set up for this agent.
        case notInstalled
        /// The file beside the hook holds another key: someone changed one or the
        /// other outside Islet.
        case keyChanged
        /// No key in the Keychain, or the Keychain refused it.
        case noKey
    }

    /// The file beside each agent's installed hook script.
    let keyFiles: [ApprovalAgent: URL]
    private let store: ApprovalKeyStore
    private var key: P256.Signing.PrivateKey?
    /// Set once the Keychain refused, so it is not asked again until a click.
    private var refused = false

    static func standardKeyFiles(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ApprovalAgent: URL] {
        [.claude: home.appendingPathComponent(".claude/hooks/islet-approvals.pub"),
         .chatgpt: home.appendingPathComponent(".codex/hooks/islet-approvals.pub")]
    }

    init(store: ApprovalKeyStore, keyFiles: [ApprovalAgent: URL]) {
        self.store = store
        self.keyFiles = keyFiles
    }

    /// The text of the key file for `key`: its DER SubjectPublicKeyInfo in base64, 124
    /// characters.
    static func keyLine(_ key: P256.Signing.PublicKey) -> String {
        key.derRepresentation.base64EncodedString()
    }

    /// The key beside `agent`'s hook, if the file is one the hook would use: a regular
    /// file of this user's, not a link, not writable by others, holding a P-256 key.
    func installedKey(for agent: ApprovalAgent) -> String? {
        guard let url = keyFiles[agent], let file = ApprovalFiles.read(url, limit: 200, forbidden: 0o022) else {
            return nil
        }
        var line = String(decoding: file.data, as: UTF8.self)
        if line.hasSuffix("\n") { line.removeLast() }
        guard line.count == 124, line.hasPrefix("MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE"), line.hasSuffix("=="),
              let data = Data(base64Encoded: line), (try? P256.Signing.PublicKey(derRepresentation: data)) != nil
        else { return nil }
        return line
    }

    /// How signing for `agent` stands, without asking the Keychain.
    func status(for agent: ApprovalAgent) -> Status {
        guard let installed = installedKey(for: agent) else { return .notInstalled }
        guard let key else { return refused ? .noKey : .unread }
        return Self.keyLine(key.publicKey) == installed ? .ready : .keyChanged
    }

    /// The signature of an Allow or Deny, base64 DER: `nil` where Islet cannot sign for
    /// the agent (`status(for:)`). Reads the key the first time, the Keychain free to
    /// ask, so only after a click. An answer to a question Claude asks is an Allow
    /// signed with what was chosen (`chosen`, `ApprovalQuestions.signed`), as
    /// `v2|id|digest|allow|answered|chosen`; anything else is `v1|id|digest|decision|answered`.
    func sign(id: String, digest: String, decision: ApprovalDecision, answered: Int64, chosen: String? = nil,
              for agent: ApprovalAgent) -> String? {
        if key == nil, !refused { loadKey() }
        guard let key, status(for: agent) == .ready else { return nil }
        let message: String
        if let chosen {
            guard decision == .allow else { return nil }
            message = "v2|\(id)|\(digest)|allow|\(answered)|\(chosen)"
        } else {
            message = "v1|\(id)|\(digest)|\(decision.rawValue)|\(answered)"
        }
        return try? key.signature(for: Data(message.utf8)).derRepresentation.base64EncodedString()
    }

    /// Whether the key as read is not the one beside some hook: set up again, it would
    /// not be taken, so only Reset Key goes on.
    var differsFromInstalled: Bool {
        guard let key else { return false }
        let line = Self.keyLine(key.publicKey)
        return keyFiles.keys.contains { agent in installedKey(for: agent).map { $0 != line } ?? false }
    }

    /// Reads the key, if it has not been, for Settings to say how it stands before an
    /// answer is tried. Only where an agent is set up, Settings being on show.
    func check() {
        guard key == nil, !refused, keyFiles.keys.contains(where: { installedKey(for: $0) != nil }) else { return }
        loadKey()
    }

    private func loadKey() {
        switch store.load() {
        case .success(let loaded): key = loaded
        case .failure: refused = true
        }
    }

    /// A click to set up approvals for `agent`, its public half written beside the hook.
    /// The first agent set up gets a new key, in place of any item already in the
    /// Keychain; the next gets the key beside the first, and nothing if the Keychain's
    /// differs (Reset Key is the way on). False if the Keychain refused, the keys
    /// differ or the file could not be written.
    @discardableResult
    func install(for agent: ApprovalAgent) -> Bool {
        guard let url = keyFiles[agent] else { return false }
        refused = false
        let installed = Set(keyFiles.keys.compactMap { installedKey(for: $0) })
        if installed.isEmpty {
            let made = P256.Signing.PrivateKey()
            guard store.replace(made) else { return false }
            key = made
        } else if key == nil {
            loadKey()
        }
        guard let key, installed.isSubset(of: [Self.keyLine(key.publicKey)]) else { return false }
        return Self.writeKeyFile(Self.keyLine(key.publicKey), to: url)
    }

    /// A click on Reset approvals key: a new key, kept in place of the old, and written
    /// beside every hook that had one.
    @discardableResult
    func reset() -> Bool {
        let made = P256.Signing.PrivateKey()
        guard store.replace(made) else { return false }
        key = made
        refused = false
        var ok = true
        for (agent, url) in keyFiles where installedKey(for: agent) != nil || FileManager.default.fileExists(atPath: url.path) {
            ok = Self.writeKeyFile(Self.keyLine(made.publicKey), to: url) && ok
        }
        return ok
    }

    /// Writes the key file: whole and moved into place, 0644, replacing a link rather
    /// than writing through it. Only into a hooks folder that is there already.
    private static func writeKeyFile(_ line: String, to url: URL) -> Bool {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isFolder),
              isFolder.boolValue
        else { return false }
        return ApprovalFiles.write(Data((line + "\n").utf8), to: url, mode: 0o644, exclusive: false)
    }
}
