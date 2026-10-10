import SwiftUI

/// A question Claude asks, as the card's body: each question in Claude's words, its
/// options as buttons (one to choose, or several where it says so) with what each says
/// of itself, and a field for words of the person's own ("Other…"). Laid out line by
/// line as `ApprovalQuestionLayout` measures it, so the card knows its height before it
/// is drawn and scrolls past `ApprovalLayout.bodyLimit`.
///
/// Choosing changes nothing until Answer, which arms as Allow does. The field takes the
/// keyboard only once clicked, as the island's fields do, and Return there only stops
/// typing: nothing typed ever answers.
struct ApprovalQuestionForm: View {
    let item: ApprovalItem
    let questions: [ApprovalQuestion]
    let state: ApprovalCardState
    /// The body's width (`ApprovalLayout.bodyWidth`), its padding included.
    let width: CGFloat
    var isEnabled = true
    @Environment(\.island) private var island
    @Environment(\.islandTheme) private var theme
    @SwiftUI.FocusState private var focused: Int?
    /// The question whose field is typed in.
    @State private var typing: Int?

    private typealias Layout = ApprovalQuestionLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !item.body.title.isEmpty {
                ApprovalBodyText(sections: [ApprovalSection(label: nil, text: item.body.title, style: .prose)], width: width)
                    .frame(height: Layout.titleHeight(item.body.title, width: width) - Layout.titleSpacing, alignment: .topLeading)
                Color.clear.frame(height: Layout.titleSpacing)
            }
            ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                questionView(question, index: index)
                if index < questions.count - 1 { Color.clear.frame(height: Layout.questionSpacing) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: island?.focusRequest ?? 0) { _, _ in takeCaret() }
        .onDisappear {
            if isTypingHere { island?.endTyping(.done) }
        }
    }

    private func questionView(_ question: ApprovalQuestion, index: Int) -> some View {
        let section = Layout.questionSection(question, index: index, count: questions.count)
        return VStack(alignment: .leading, spacing: 0) {
            ApprovalBodyText(sections: [section], width: width)
                .frame(height: Layout.textHeight([section], width: width), alignment: .topLeading)
            Color.clear.frame(height: Layout.optionsTop)
            ForEach(Array(question.options.enumerated()), id: \.offset) { number, option in
                optionButton(option, number: number, question: question, index: index)
                Color.clear.frame(height: Layout.optionSpacing)
            }
            field(index)
        }
    }

    // MARK: Options

    private func isChosen(_ index: Int, _ number: Int) -> Bool {
        state.choices.indices.contains(index) && state.choices[index].options.contains(number)
    }

    private func optionButton(_ option: ApprovalQuestion.Option, number: Int, question: ApprovalQuestion,
                              index: Int) -> some View {
        let chosen = isChosen(index, number)
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button {
            state.choose(number, in: index, of: questions)
        } label: {
            HStack(alignment: .top, spacing: 0) {
                Image(systemName: Self.mark(chosen: chosen, several: question.multiSelect))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(chosen ? .islandAccent(.claudeCode) : .islandGraphic(0.5))
                    .frame(width: Layout.markWidth, height: ApprovalLines.lineHeight)
                ApprovalBodyText(sections: Layout.optionSections(option), width: Layout.optionTextWidth(width))
                Spacer(minLength: 0)
            }
            .padding(.vertical, Layout.optionPadding)
            .frame(height: Layout.optionHeight(option, width: width), alignment: .topLeading)
            .background(shape.fill(chosen ? .islandAccent(.claudeCode).opacity(0.14) : .islandSurface(0.06)))
            .overlay(shape.strokeBorder(chosen ? .islandAccent(.claudeCode) : .islandDecorative(0), lineWidth: 1.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("\(number + 1). \(option.label)")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    static func mark(chosen: Bool, several: Bool) -> String {
        switch (several, chosen) {
        case (true, true): "checkmark.square.fill"
        case (true, false): "square"
        case (false, true): "largecircle.fill.circle"
        case (false, false): "circle"
        }
    }

    // MARK: Words of the person's own

    /// Whether one of the card's fields is typed in: the page it is on being typed in,
    /// from a click on one of them.
    private var isTypingHere: Bool {
        guard typing != nil, let island, let place = island.typingPlace else { return false }
        return place == .page(island.resolvedFocus)
    }

    private func field(_ index: Int) -> some View {
        let text = Binding(
            get: { state.choices.indices.contains(index) ? state.choices[index].other : "" },
            set: { state.write($0, in: index, of: questions) })
        let here = isTypingHere && typing == index
        return ZStack(alignment: .leading) {
            if text.wrappedValue.isEmpty {
                Text(questions[index].multiSelect ? "Other… (added to those chosen)" : "Other…")
                    .foregroundStyle(.islandText(0.45, on: .surface(0.1)))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            TextField("", text: text)
                .textFieldStyle(.plain)
                .foregroundStyle(.islandPrimary)
                .focused($focused, equals: index)
                // Return stops typing; it never answers.
                .onSubmit { island?.endTyping(.done) }
                .onExitCommand { island?.endTyping(.escape) }
                .accessibilityLabel("Your own answer")
            if !here {
                // The island has no keyboard until the field is clicked: the click is the
                // person asking to type.
                Rectangle()
                    .fill(.islandDecorative(0))
                    .contentShape(Rectangle())
                    .onTapGesture { beginTyping(index) }
                    .accessibilityHidden(true)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .frame(height: Layout.fieldHeight)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.islandSurface(0.1)))
        .disabled(!isEnabled)
    }

    private func beginTyping(_ index: Int) {
        guard isEnabled, let island else { return }
        typing = index
        // In the page the card is on, staying there as typing ends.
        InputCenter.shared.beginTyping(island, .page(island.resolvedFocus), TypingClient(
            key: { action in
                // ⌘Return answers nothing either: only a click on Answer does.
                if action == .close { island.endTyping(.close) }
            },
            ended: { _ in focused = nil },
            leavesPage: false
        ))
    }

    private func takeCaret() {
        guard isTypingHere, let typing else { return }
        DispatchQueue.main.async { focused = typing }
    }
}

extension ApprovalCardState {
    /// A click on option `number` of question `index`: where only one is taken, it is
    /// chosen in place of any other and of words typed (clicked again, none is); where
    /// several are, it is added or taken away.
    func choose(_ number: Int, in index: Int, of questions: [ApprovalQuestion]) {
        guard questions.indices.contains(index), questions[index].options.indices.contains(number) else { return }
        var all = fitted(to: questions)
        if questions[index].multiSelect {
            if all[index].options.contains(number) { all[index].options.remove(number) } else { all[index].options.insert(number) }
        } else {
            all[index].options = all[index].options == [number] ? [] : [number]
            all[index].other = ""
        }
        choices = all
        note = Self.wordsNote(all)
    }

    /// Words typed for question `index`: where only one answer is taken, they stand in
    /// place of any option chosen. A character that can't go is named as it is typed,
    /// not only once Answer is clicked.
    func write(_ words: String, in index: Int, of questions: [ApprovalQuestion]) {
        guard questions.indices.contains(index) else { return }
        var all = fitted(to: questions)
        all[index].other = words
        if !questions[index].multiSelect, !words.isEmpty { all[index].options = [] }
        if all != choices { choices = all }
        let next = Self.wordsNote(all)
        if next != note { note = next }
    }

    /// What is wrong with the first of `choices`' words that can't go, in a few words;
    /// `nil` where all can (`ApprovalQuestions.wordsProblem`).
    static func wordsNote(_ choices: [ApprovalChoice]) -> String? {
        choices.lazy.compactMap { ApprovalQuestions.wordsProblem($0.words)?.words }.first
    }

    private func fitted(to questions: [ApprovalQuestion]) -> [ApprovalChoice] {
        choices.count == questions.count ? choices : Array(repeating: ApprovalChoice(), count: questions.count)
    }
}
