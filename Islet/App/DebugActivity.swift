#if DEBUG
import SwiftUI

/// A stand-in second activity for checking two-activity layouts (the bubble) in
/// debug builds: `islet://debug/second` toggles it.
@MainActor
final class DebugActivity: IslandActivity {
    static let shared = DebugActivity()

    let id = "debug.second"
    let symbol = "ladybug.fill"
    var priority: ActivityPriority { .background }

    func compactLeading() -> AnyView {
        AnyView(Image(systemName: "ladybug.fill").foregroundStyle(.pink).font(.system(size: 13, weight: .bold)))
    }

    func compactTrailing() -> AnyView {
        AnyView(Text("Debug").font(.system(size: 12, weight: .semibold)).foregroundStyle(.pink))
    }

    func minimal() -> AnyView {
        AnyView(Image(systemName: "ladybug.fill").foregroundStyle(.pink).font(.system(size: 12, weight: .bold)))
    }

    func expanded() -> AnyView {
        AnyView(Text("A debug activity").foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity))
    }

    func toggle() {
        let center = ActivityCenter.shared
        if center.isShowing(id: id) { center.end(id: id) } else { center.show(self) }
    }
}
#endif
