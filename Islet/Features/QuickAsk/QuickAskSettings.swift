import AppKit
import SwiftUI

/// Quick Ask's options: who answers, the shortcut, connecting Claude, and what is kept
/// (nothing).
struct QuickAskSettings: View {
    let model: QuickAskModel
    @AppStorage(QuickAskFeature.Key.provider) private var provider = ""
    @State private var token = ""
    @State private var hasToken = false
    @State private var tokenProblem: String?

    var body: some View {
        Picker("Answer with", selection: chosen) {
            ForEach(AskProvider.allCases) { provider in
                Text(provider.title).tag(provider)
            }
        }
        ForEach(AskProvider.allCases) { provider in
            LabeledContent(provider.title) {
                let status = model.status(of: provider)
                // Here, Claude's sign-in is the row below.
                Text(provider == .claude && status == .signInNeeded ? "Not connected yet" : status.text(for: provider))
                    .foregroundStyle(status == .ready ? .secondary : .primary)
            }
        }
        LabeledContent("Shortcut") {
            ShortcutRecorder(combo: model.shortcut, problem: model.shortcutProblem) { model.setShortcut($0) }
        }
        claude
        Text(LocalizedStringKey(QuickAskSettings.privacy))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear {
                model.refreshStatuses()
                hasToken = claudeTokens?.hasToken ?? false
            }
    }

    /// The provider as chosen, or, before one is, the one that would answer.
    private var chosen: Binding<AskProvider> {
        Binding(
            get: { AskProvider(rawValue: provider) ?? model.provider },
            set: { provider = $0.rawValue }
        )
    }

    private var claudeTokens: (any ClaudeTokenStore)? {
        (model.backend(.claude) as? ClaudeAskBackend)?.tokens
    }

    @ViewBuilder
    private var claude: some View {
        LabeledContent {
            if hasToken {
                Button("Remove") {
                    claudeTokens?.remove()
                    hasToken = false
                    model.refreshStatuses()
                }
            } else {
                HStack {
                    SecureField("Token", text: $token, prompt: Text("Paste the token"))
                        .labelsHidden()
                        .frame(width: 180)
                    Button("Connect") { connect() }
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        } label: {
            Text("Connect Claude")
            Text(hasToken
                 ? "Connected. The token is kept in Islet's own keychain item."
                 : "Claude's app keeps its sign-in to itself. Run this once in Terminal, and paste the token it gives here:")
            if !hasToken, let command = QuickAskSettings.setupCommand {
                HStack(alignment: .firstTextBaseline) {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    .controlSize(.small)
                }
            }
            if let tokenProblem {
                Text(tokenProblem).foregroundStyle(.orange)
            }
        }
    }

    private func connect() {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try claudeTokens?.save(value)
            token = ""
            tokenProblem = nil
            hasToken = true
        } catch {
            tokenProblem = "The keychain didn't take it — try again"
        }
        model.refreshStatuses()
    }

    /// `claude setup-token`, with the Claude app's own tool, quoted for Terminal.
    static var setupCommand: String? {
        ClaudeAskBackend.findBinary().map { "\"\($0.path)\" setup-token" }
    }

    static let privacy = """
        **Islet keeps nothing.** Your question and its answer stay in memory while the box is open and are gone when it \
        closes — nothing is saved, logged, or put on the clipboard unless you press Copy. **On this Mac** answers with \
        Apple's on-device model; nothing leaves your Mac. **ChatGPT** and **Claude** send your question to OpenAI or \
        Anthropic through their app's own command-line tool, with no history or session saved on this Mac, no tools, \
        and none of your hooks, plugins or MCP servers; what OpenAI and Anthropic keep is up to their own privacy \
        policies. Your calendar is never sent to any of them. Quick questions to ChatGPT count towards the same usage \
        as the ChatGPT app. A file of instructions for Codex in ~/.codex (AGENTS.md) would go with each question to \
        ChatGPT.
        """
}
