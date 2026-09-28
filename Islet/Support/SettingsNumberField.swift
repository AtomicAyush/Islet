import SwiftUI

/// A whole number typed into Settings: taken when Return is pressed or the field is
/// left, kept within `range`, and put back as it was when what was typed isn't a number.
struct SettingsNumberField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let label: String
    @State private var text = ""
    @SwiftUI.FocusState private var isFocused: Bool

    var body: some View {
        TextField(label, text: $text)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 44)
            .focused($isFocused)
            .onAppear { text = String(value) }
            // The arrows, or another window, changed it: show the new number.
            .onChange(of: value) { _, new in
                if !isFocused { text = String(new) }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            .onSubmit(commit)
    }

    private func commit() {
        text = String(Self.clamped(text, to: range, keeping: value))
        if let typed = Int(text), typed != value { value = typed }
    }

    /// `typed` as a whole number within `range`; `current` when it isn't a number.
    static func clamped(_ typed: String, to range: ClosedRange<Int>, keeping current: Int) -> Int {
        guard let number = Int(typed.trimmingCharacters(in: .whitespaces)) else { return current }
        return min(max(number, range.lowerBound), range.upperBound)
    }
}
