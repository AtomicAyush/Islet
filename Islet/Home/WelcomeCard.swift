import SwiftUI

/// Shown once, the first time Islet runs.
struct WelcomeCard: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text("Islet is running")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Rest the pointer on the notch to open it.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }
}
