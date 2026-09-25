import AppKit
import Observation

/// Whether macOS lets Islet see keys before it acts on them. Only ever checked on
/// its own: the system prompt appears when someone clicks Grant Access, never
/// because the feature was switched on.
@MainActor
@Observable
final class AccessibilityAccess {
    private(set) var isGranted = false

    /// Called whenever `isGranted` flips.
    @ObservationIgnored var onChange: () -> Void = {}

    func refresh() {
        let granted = AXIsProcessTrusted()
        guard granted != isGranted else { return }
        isGranted = granted
        onChange()
    }

    /// What System Settings calls the list Islet has to be in, for text that sends
    /// people there: macOS 27 renamed the Accessibility pane.
    nonisolated static var paneName: String {
        if #available(macOS 27, *) {
            return "Device Control and Data Access"
        }
        return "Accessibility"
    }

    /// Shows the system prompt, which also adds Islet to the Accessibility list, and
    /// opens that list in System Settings.
    func request() {
        // The literal key: the imported constant is a global var Swift 6 rejects.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        // The pane's anchor from before macOS 27. Whether it still opens the renamed
        // pane there is unverified.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
