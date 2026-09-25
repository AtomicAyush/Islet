import SwiftUI

/// A filled circular button in the iPhone Live Activity style.
struct RoundButton: View {
    let symbol: String
    let tint: Color
    var diameter: CGFloat = 38
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.38, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(tint.opacity(isHovering ? 0.3 : 0.2)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
