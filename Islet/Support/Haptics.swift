import AppKit

/// Trackpad feedback for the moments the island changes shape under the pointer.
/// It only reaches a Force Touch trackpad, and only while a finger is resting on it,
/// which is exactly when someone is hovering or clicking.
enum Haptics {
    static func tap(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .generic) {
        guard Prefs.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
