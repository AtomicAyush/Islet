import AppKit

/// Where the menu bar's status items begin beside the island. On a MacBook they crowd
/// up against the notch, and the bubble would land on top of them; when it would not
/// fit in the gap, the island folds the second activity in instead.
enum MenuBarRoom {
    /// The left edge, in global x, of the first status item at or right of `edge` on
    /// the given display, or `nil` if there is none.
    ///
    /// Each status item is a window at the status window level, and any app may read
    /// the window list's bounds without permission. The list puts its origin at the
    /// top left, but its x runs along the same axis as AppKit's, and a display's items
    /// sit at the top of its bounds. Islet's own item counts too: the bubble must not
    /// cover it either. Takes a few milliseconds (tens, the first time in a process),
    /// so it is best called off the main thread.
    static func firstStatusItem(rightOf edge: CGFloat, on display: CGDirectDisplayID) -> CGFloat? {
        let screen = CGDisplayBounds(display)
        let level = Int(CGWindowLevelForKey(.statusWindow))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.compactMap { window -> CGFloat? in
            guard window[kCGWindowLayer as String] as? Int == level,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  abs(frame.minY - screen.minY) < 1,
                  frame.minX >= edge, frame.minX < screen.maxX
            else { return nil }
            return frame.minX
        }.min()
    }
}
