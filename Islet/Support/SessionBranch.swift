import SwiftUI

/// The git branch a coding agent's session is on: Claude Code's, ChatGPT's and Gemini's.
/// Each hook reads it from the repository's own files at every event and keeps it in
/// the session's file (`branch`), the name of the branch checked out, or for a detached
/// HEAD its commit's first seven digits. The island shows it beside the session's
/// folder, and the hooks' banners name it there too, each while its activity's setting
/// asks for it.
enum SessionBranch {
    /// The most of a branch's name kept: the hooks cut a longer one in the middle to
    /// this, and so does Islet, should a file hold more.
    static let limit = 80
    /// The most a banner names, cut in the middle as the hooks cut it.
    static let bannerLimit = 20

    /// `text` as one line of plain text: control and formatting characters dropped
    /// (zero-width spaces and joiners, the marks that reorder text), as are anything
    /// Unicode says to draw as nothing and private-use characters; white space as single
    /// spaces, trimmed; accents stacked a few high at most, and no character longer than
    /// the longest emoji, as a banner keeps them; and cut in the middle to `limit`
    /// characters. "" when nothing is left that can be seen. Only the start of the text
    /// is read, so a file holding megabytes is not read through.
    static func clean(_ text: String, limit: Int = limit) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        var marks = 0
        for scalar in text.unicodeScalars.prefix(limit * CustomBanner.readPerCharacter) {
            let properties = scalar.properties
            switch properties.generalCategory {
            case .control, .format, .privateUse, .surrogate, .lineSeparator, .paragraphSeparator:
                continue
            case .nonspacingMark, .enclosingMark:
                marks += 1
                if marks > CustomBanner.maximumMarks { continue }
            default:
                marks = 0
            }
            if properties.isWhitespace {
                pendingSpace = !scalars.isEmpty
                marks = 0
                continue
            }
            // The replacement character stands for bytes that were not text at all.
            if properties.isDefaultIgnorableCodePoint || scalar.value == 0xFFFD { continue }
            if pendingSpace {
                scalars.append(" ")
                pendingSpace = false
            }
            scalars.append(scalar)
        }
        var cleaned = String(scalars)
        while cleaned.contains(where: { $0.unicodeScalars.count > CustomBanner.maximumScalarsPerCharacter }) {
            cleaned = String(cleaned.filter { $0.unicodeScalars.count <= CustomBanner.maximumScalarsPerCharacter })
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        let seen = cleaned.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .enclosingMark, .spaceSeparator: false
            default: scalar.value != 0x2800
            }
        }
        return seen ? middle(cleaned, limit: limit) : ""
    }

    /// `text` cut in the middle to at most `limit` characters, an ellipsis where it was
    /// cut, the start keeping the odd character: a branch's name is told apart as often
    /// by its end as by its start.
    static func middle(_ text: String, limit: Int) -> String {
        guard text.count > limit, limit > 2 else { return text }
        let head = limit / 2
        return String(text.prefix(head)) + "…" + String(text.suffix(limit - head - 1))
    }

    /// Whether Settings shows the branch for the activity by that id (`claudeCode`,
    /// `chatGPT` or `gemini`). On for any other: it has none to show.
    static func isShown(activity: String) -> Bool {
        switch activity {
        case "claudeCode": ClaudeCodePrefs.showsBranch
        case "chatGPT": ChatGPTPrefs.showsBranch
        case "gemini": GeminiPrefs.showsBranch
        default: true
        }
    }

    /// The branch beside a session's folder, as a banner names it: " · " and the branch
    /// cut to `bannerLimit`, or "" for none.
    static func bannerSuffix(_ branch: String) -> String {
        branch.isEmpty ? "" : " · " + middle(branch, limit: bannerLimit)
    }

    /// `text` without the branch a hook's banner named beside the folder (" · main"):
    /// the first place it follows a " · " and comes at the end or before another. As it
    /// was where the branch is not there.
    static func removed(_ branch: String, from text: String) -> String {
        guard !branch.isEmpty else { return text }
        let named = " · " + branch
        var from = text.startIndex
        while from < text.endIndex, let found = text.range(of: named, options: .literal, range: from..<text.endIndex) {
            let rest = text[found.upperBound...]
            if rest.isEmpty || rest.hasPrefix(" · ") {
                return String(text[..<found.lowerBound] + rest)
            }
            from = text.index(after: found.lowerBound)
        }
        return text
    }
}

/// A session's folder and, beside it, the git branch it is on, on one line: "Islet ·
/// main", a small branch before the branch's name. When the two don't fit, each gives
/// way in its middle, the shorter keeping all it needs, so the start and the end of both
/// stay in sight.
struct FolderBranchLabel: View {
    enum Size {
        /// A row's title: the folder in the title's own words, the branch quieter.
        case title
        /// The quieter line under a row's title, both in its words.
        case detail
        /// The line under an approval card's headline, both in its words and colour.
        case caption
    }

    let folder: String
    let branch: String
    var size: Size = .title
    /// Marks the branch as having letters that could pass for others, as an approval
    /// card marks them: underlined, in the attention colour.
    var isMarked = false

    var body: some View {
        HStack(spacing: 0) {
            Text(verbatim: folder)
                .font(folderFont)
                .foregroundStyle(folderStyle)
                .truncationMode(.middle)
            Text(verbatim: " · ")
                .font(branchFont)
                .foregroundStyle(.islandText(0.35))
                .fixedSize()
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: size == .title ? 9.5 : 8.5, weight: .semibold))
                .foregroundStyle(.islandGraphic(0.45))
                .padding(.trailing, 2)
            Text(verbatim: branch)
                .font(branchFont)
                .foregroundStyle(branchStyle)
                .underline(isMarked)
                .truncationMode(.middle)
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(folder), branch \(branch)")
    }

    private var folderFont: Font {
        switch size {
        case .title: .system(size: 13, weight: .semibold)
        case .detail: .system(size: 11.5, weight: .medium)
        case .caption: .system(size: 11)
        }
    }

    private var branchFont: Font {
        switch size {
        case .title: .system(size: 12, weight: .medium)
        case .detail: .system(size: 11.5, weight: .medium)
        case .caption: .system(size: 11)
        }
    }

    private var folderStyle: IslandStyle {
        switch size {
        case .title: .islandPrimary
        case .detail: .islandText(0.5)
        case .caption: .islandText(0.6)
        }
    }

    private var branchStyle: IslandStyle {
        if isMarked { return ClaudeCodePalette.attentionText }
        switch size {
        case .title, .caption: return .islandText(0.6)
        case .detail: return .islandText(0.5)
        }
    }
}
