import SwiftUI

/// An answer's text in blocks, as a light Markdown reads: paragraphs, lists, fenced
/// code and headings. Nothing more of Markdown than that, and nothing in it acts: a link
/// is its words, not something to click.
enum AnswerBlock: Equatable {
    case paragraph(String)
    /// A list item with its mark: "•", or "1." for a numbered one.
    case item(mark: String, text: String)
    case code(String)
    case heading(String)

    /// Splits `text` into blocks, a line at a time. An unfinished code fence (an answer
    /// still coming) runs to the end.
    static func parse(_ text: String) -> [AnswerBlock] {
        var blocks: [AnswerBlock] = []
        var paragraph: [String] = []
        var code: [String]?

        func endParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    endParagraph()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(raw)
                continue
            }
            if line.isEmpty {
                endParagraph()
            } else if let heading = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                endParagraph()
                blocks.append(.heading(String(line[heading.upperBound...])))
            } else if let bullet = line.range(of: #"^[-*•]\s+"#, options: .regularExpression) {
                endParagraph()
                blocks.append(.item(mark: "•", text: String(line[bullet.upperBound...])))
            } else if let number = line.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) {
                endParagraph()
                let mark = line[number].trimmingCharacters(in: .whitespaces)
                blocks.append(.item(mark: mark, text: String(line[number.upperBound...])))
            } else {
                paragraph.append(line)
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        endParagraph()
        return blocks
    }

    /// Bold, italic and `code` within a line, as the system's Markdown reads them, with
    /// any link left as its words. Plain text where it doesn't read.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var styled = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        for run in styled.runs where run.link != nil {
            styled[run.range].link = nil
        }
        return styled
    }
}

/// An answer, drawn from its blocks, selectable while the box has the keyboard.
struct AnswerText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(AnswerBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.islandPrimary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: AnswerBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(AnswerBlock.inline(text))
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let text):
            Text(AnswerBlock.inline(text))
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
        case .item(let mark, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(mark)
                    .foregroundStyle(.islandText(0.6))
                    .monospacedDigit()
                Text(AnswerBlock.inline(text))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code(let code):
            // Wrapped rather than scrolled sideways: nothing of a quick answer is hidden.
            Text(code)
                .font(.system(size: 12, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.islandSurface(0.12)))
        }
    }
}
