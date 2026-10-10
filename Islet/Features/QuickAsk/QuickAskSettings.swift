import AppKit
import SwiftUI

/// Quick Ask's options: who answers, Apple's model reading the calendar, the shortcut, what
/// "Look at my screen" looks at and Screen Recording for it, connecting Claude, and what is
/// kept (nothing).
struct QuickAskSettings: View {
    let model: QuickAskModel
    @AppStorage(QuickAskFeature.Key.provider) private var provider = ""
    @AppStorage(QuickAskFeature.Key.lookAt) private var lookAt = ScreenLookTarget.frontWindow
    @AppStorage(QuickAskFeature.Key.calendar) private var readsCalendar = true
    @State private var token = ""
    @State private var hasToken = false
    @State private var tokenProblem: String?

    var body: some View {
        Picker("Answer with", selection: chosen) {
            ForEach(AskProvider.allCases.filter { $0 == chosen.wrappedValue || AskProvider.isOffered($0, model.status(of:)) }) { provider in
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
        Toggle(isOn: $readsCalendar) {
            Text("Let Apple's model read your calendar")
            Text("When you ask it, like \"am I free today at 8?\", Apple's model looks up your events and free time in the calendars Quick Calendar checks. It only reads, here on your Mac: nothing is sent anywhere, and ChatGPT, Claude and Gemini are never given your calendar.")
        }
        LabeledContent("Shortcut") {
            ShortcutRecorder(combo: model.shortcut, problem: model.shortcutProblem) { model.setShortcut($0) }
        }
        Picker(selection: $lookAt) {
            ForEach(ScreenLookTarget.allCases) { target in
                Text(target.title).tag(target)
            }
        } label: {
            Text("Look at my screen")
            Text("What the eye beside the box's field (or ⇧⌘S in it) takes a picture of, only when you press it: the front window of the app you were in, or the whole display the island is on.")
        }
        LabeledContent {
            if model.screenPermission == .granted {
                Text("On").foregroundStyle(.secondary)
            } else {
                Button("Open System Settings") { ScreenPermission.openSettings() }
            }
        } label: {
            Text("Screen Recording")
            Text(model.screenPermission == .granted
                 ? "Islet may take a picture of your screen when you ask it to look."
                 : "Off. Islet needs it to look at your screen, and asks for it only the first time you press Look.")
        }
        claude
        Text(LocalizedStringKey(QuickAskSettings.privacy))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear {
                model.refreshStatuses()
                model.refreshScreenPermission()
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
        **Islet keeps nothing.** Your questions and their answers stay in memory while the island is open, for \
        follow-ups, and are gone when it closes — nothing is saved, logged, or put on the clipboard unless you press \
        Copy. **On this Mac** answers with Apple's on-device model; nothing leaves your Mac. **ChatGPT** and **Claude** \
        send your question, with the conversation so far, to OpenAI or Anthropic through their app's own command-line \
        tool, with no history or session saved on this Mac, no tools, and none of your hooks, plugins or MCP servers; \
        what OpenAI and Anthropic keep is up to their own privacy policies. Your calendar is never sent to ChatGPT or \
        Claude: after your day is summed up in the box, or On this Mac answers from your calendar, they're told only \
        that it was, and On this Mac alone is given it, for a follow-up; a question about your calendar meant for \
        them offers On this Mac instead. On this Mac reads your calendar only while its switch above is on, and only \
        reads it. **Look at my screen** takes one picture, only when you press it, of the front window \
        or the whole display, never with Islet's own windows in it, shown over the field before it goes. It goes \
        once, with your next question: to On this Mac, it stays on your Mac; to ChatGPT or Claude, it is sent with \
        it (to ChatGPT through a private file that goes as soon as it has been read). Follow-ups don't send it \
        again, and it is forgotten with the conversation. Quick questions to ChatGPT count towards the same usage as the ChatGPT app. A file of \
        instructions for Codex in ~/.codex (AGENTS.md) would go with each question to ChatGPT. **Gemini**, offered once \
        Gemini CLI is installed and signed in, sends your question, with the conversation so far (and a picture, if one \
        goes, from a private file in the run's own folder), to Google through Gemini CLI with its fast model, no tools, \
        extensions, MCP servers or context files, and none of your hooks; it counts towards Gemini CLI's quota. Gemini \
        CLI saves every session, so it runs in a folder of Islet's, and Islet deletes that question's session from \
        ~/.gemini/tmp as it ends, or with the next question should Islet quit first; what Google keeps is up to its own privacy policy.
        """
}
