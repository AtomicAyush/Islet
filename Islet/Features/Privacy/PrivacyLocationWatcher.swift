import Foundation

/// Location in use, as the menu bar's arrow shows it, and the apps it is for.
///
/// Location services log the arrow's state as it changes: off, hollow while an app is
/// waiting on a fix, and solid while one is getting fixes. Only solid counts as in
/// use here, as it is the only state that says an app is being told where the Mac is;
/// an app that keeps a subscription open (Find My does, all day) holds the arrow
/// hollow for hours.
///
/// The arrow itself names nobody. Control Center's own list does, a few milliseconds
/// before the arrow turns solid, and keeps the app among its recent ones for twenty
/// seconds; a single fix, as a web page asking where it is gets, holds the arrow solid
/// for about twelve. So the apps named are those Control Center listed since the arrow
/// turned solid, or, failing that, any it lists now. Control Center already leaves out
/// macOS's own services. With neither, the arrow is for nobody that can be named: the
/// apps merely holding a subscription are not the ones getting the fix, so they are
/// not named in its place.
///
/// Nothing but the log says any of this, so lines the log may have missed leave it
/// unknown, and the arrow is taken to be off until the next line says otherwise: a
/// missed arrow rather than one stuck on.
struct PrivacyLocationTracker: Equatable {
    private(set) var icon = PrivacyLocationIcon.inactive
    private var receivingSince: Date?
    /// Control Center's active and recent location clients, by bundle identifier.
    private var active: [String] = []
    private var recent: [String] = []
    /// When Control Center last listed each client as active.
    private var lastActive: [String: Date] = [:]

    /// Control Center lists a client a moment before the arrow turns solid.
    static let leadTime: TimeInterval = 2

    /// Whether the arrow is solid, and the clients it is solid for, by bundle
    /// identifier, the newest first.
    var reading: (inUse: Bool, clients: [String]) {
        guard icon == .receiving else { return (false, []) }
        let listed = Array(Set(active + recent)).sorted { (lastActive[$0] ?? .distantPast) > (lastActive[$1] ?? .distantPast) }
        if let since = receivingSince?.addingTimeInterval(-Self.leadTime) {
            let fresh = listed.filter { (lastActive[$0] ?? .distantPast) >= since }
            if !fresh.isEmpty { return (true, fresh) }
        }
        return (true, listed)
    }

    mutating func iconChanged(_ icon: PrivacyLocationIcon, at date: Date) {
        if icon == .receiving, self.icon != .receiving { receivingSince = date }
        if icon != .receiving { receivingSince = nil }
        self.icon = icon
    }

    mutating func controlCenterChanged(active clients: [String], at date: Date) {
        for client in clients { lastActive[client] = date }
        active = clients
        forgetUnlisted()
    }

    mutating func controlCenterRecentChanged(_ clients: [String], at date: Date) {
        recent = clients
        for client in clients where lastActive[client] == nil { lastActive[client] = date }
        forgetUnlisted()
    }

    /// Lines may have been missed: what the arrow and Control Center showed is no
    /// longer known.
    mutating func linesLost() {
        self = PrivacyLocationTracker()
    }

    private mutating func forgetUnlisted() {
        let listed = Set(active + recent)
        lastActive = lastActive.filter { listed.contains($0.key) }
    }
}
