import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An app that uses, or can use, the Mac's location, offered for leaving out of the
/// location arrow.
struct LocationApp: Hashable, Sendable, Identifiable {
    let bundleIdentifier: String
    let name: String
    /// The app on disk, for its icon; nil for one known only by its identifier.
    let bundlePath: String?
    /// When location services last started or stopped giving it the Mac's location.
    var lastUsed: Date?

    var id: String { bundleIdentifier }
}

/// The apps that use the Mac's location, and where the list came from.
struct LocationAppSnapshot: Equatable, Sendable {
    enum Source: Sendable {
        /// Location services' own list of its clients, the one System Settings shows
        /// under Privacy & Security › Location Services.
        case locationServices
        /// That list couldn't be read: the installed apps whose Info.plist says why
        /// they would want the Mac's location, whether or not they ever asked.
        case installedApps
    }

    var apps: [LocationApp]
    var source: Source
}

/// Reads which apps use the Mac's location. Location services keep their clients in
/// a property list anyone can read: an entry for each app, helper and part of macOS
/// that has asked, with when each last got the Mac's location. Its own services, and
/// the entries System Settings hides, are left out, as is anything that isn't an app
/// on this Mac: daemons and frameworks have no app to name or to open. A helper app
/// nested in another counts as the outer one, as the location arrow names it.
enum LocationAppReader {
    static let clientsURL = URL(fileURLWithPath: "/var/db/locationd/clients.plist")

    /// Where the fallback looks, a folder deep: the apps, and those in Utilities.
    static let applicationFolders = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/System/Applications"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
    ]

    /// The Info.plist keys an app gives its reason for wanting the Mac's location under.
    static let usageKeys = [
        "NSLocationUsageDescription", "NSLocationWhenInUseUsageDescription",
        "NSLocationAlwaysAndWhenInUseUsageDescription",
    ]

    /// Location services' list where it can be read, the installed apps where not.
    /// `appURL` finds an app by bundle identifier, for one whose recorded path has gone.
    static func read(
        clients: URL = clientsURL, folders: [URL] = applicationFolders,
        excluding own: String = PrivacyPrefs.ownBundleIdentifier,
        appURL: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    ) -> LocationAppSnapshot {
        if let data = try? Data(contentsOf: clients), let apps = apps(fromClients: data, excluding: own, appURL: appURL) {
            return LocationAppSnapshot(apps: apps, source: .locationServices)
        }
        return LocationAppSnapshot(apps: appsDeclaringLocation(in: folders, excluding: own), source: .installedApps)
    }

    /// The fields a client is placed by. A list whose entries carry none of them is in
    /// a form this doesn't know.
    static let clientFields = ["BundleId", "BundlePath", "Executable"]

    /// The apps in location services' list, the most recently given the Mac's location
    /// first, then by name. Nil when `data` isn't such a list, or is one in a form
    /// this doesn't know, so that the installed apps stand in rather than none.
    ///
    /// Clients are keyed by bundle identifier, by executable or by bundle path. Each
    /// is put down to the outermost app its recorded path or executable lies in, or,
    /// where those have gone, to wherever an app with its identifier is now, and
    /// known by that app's identifier and name. Entries for one app merge.
    static func apps(fromClients data: Data, excluding own: String, appURL: (String) -> URL?) -> [LocationApp]? {
        guard let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        let clients = list.values.compactMap { $0 as? [String: Any] }
        if !clients.isEmpty, !clients.contains(where: { client in clientFields.contains { client[$0] != nil } }) {
            return nil
        }
        var found: [String: LocationApp] = [:]
        for client in clients {
            if client["isSystemService"] as? Bool == true || client["SuppressShowingInSettings"] as? Bool == true { continue }
            guard let path = app(of: client, appURL: appURL),
                  let id = infoPlist(ofApp: path)?["CFBundleIdentifier"] as? String, !isOwn(id, own) else { continue }
            let lastUsed = lastUse(of: client)
            if found[id] == nil {
                found[id] = LocationApp(bundleIdentifier: id, name: name(ofApp: path), bundlePath: path, lastUsed: lastUsed)
            } else if let lastUsed, lastUsed > found[id]?.lastUsed ?? .distantPast {
                found[id]?.lastUsed = lastUsed
            }
        }
        return sorted(Array(found.values))
    }

    /// The app a client is or sits in, where it is on this Mac.
    private static func app(of client: [String: Any], appURL: (String) -> URL?) -> String? {
        for case let path? in [client["BundlePath"] as? String, client["Executable"] as? String] {
            if let app = PrivacyAppResolver.outermostAppBundle(in: path), FileManager.default.fileExists(atPath: app) {
                return app
            }
        }
        guard let id = client["BundleId"] as? String, let url = appURL(id),
              let app = PrivacyAppResolver.outermostAppBundle(in: url.path), FileManager.default.fileExists(atPath: app)
        else { return nil }
        return app
    }

    /// The apps in `folders`, and a folder below, whose Info.plist gives a reason for
    /// wanting the Mac's location, by name. The first of two copies of an app wins.
    static func appsDeclaringLocation(in folders: [URL], excluding own: String) -> [LocationApp] {
        let files = FileManager.default
        var paths: [String] = []
        for folder in folders {
            for item in (try? files.contentsOfDirectory(atPath: folder.path)) ?? [] where !item.hasPrefix(".") {
                let path = folder.appendingPathComponent(item).path
                if item.hasSuffix(".app") {
                    paths.append(path)
                } else {
                    let inner = (try? files.contentsOfDirectory(atPath: path)) ?? []
                    paths += inner.filter { $0.hasSuffix(".app") }.map { (path as NSString).appendingPathComponent($0) }
                }
            }
        }
        var apps: [LocationApp] = []
        var seen = Set<String>()
        for path in paths {
            guard let info = infoPlist(ofApp: path), let id = info["CFBundleIdentifier"] as? String,
                  usageKeys.contains(where: { info[$0] != nil }), !isOwn(id, own), seen.insert(id).inserted else { continue }
            apps.append(LocationApp(bundleIdentifier: id, name: name(ofApp: path), bundlePath: path, lastUsed: nil))
        }
        return sorted(apps)
    }

    /// The most recently given the Mac's location first; those never given it, and
    /// ties, by name.
    static func sorted(_ apps: [LocationApp]) -> [LocationApp] {
        apps.sorted { a, b in
            let (x, y) = (a.lastUsed ?? .distantPast, b.lastUsed ?? .distantPast)
            if x != y { return x > y }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// The latest of a client's start and stop times, which location services keep
    /// for each kind of look-up.
    static func lastUse(of client: [String: Any]) -> Date? {
        client.compactMap { key, value -> Date? in
            guard key.hasSuffix("TimeStarted") || key.hasSuffix("TimeStopped") else { return nil }
            if let date = value as? Date { return date }
            return (value as? Double).map { Date(timeIntervalSinceReferenceDate: $0) }
        }.max()
    }

    private static func infoPlist(ofApp path: String) -> [String: Any]? {
        let url = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// The name the Finder shows.
    private static func name(ofApp path: String) -> String {
        PrivacyApp(bundlePath: path).name
    }

    /// Islet, or anything under its identifier.
    static func isOwn(_ bundleIdentifier: String, _ own: String) -> Bool {
        bundleIdentifier == own || bundleIdentifier.hasPrefix(own + ".")
    }
}

/// The apps that use the Mac's location, read off the main thread and kept between
/// visits to Settings. Read again whenever the option shows, and whenever location
/// services rewrite their list while the picker is open.
@MainActor
@Observable
final class LocationAppList {
    static let shared = LocationAppList()

    /// Nil until the first read is in.
    private(set) var snapshot: LocationAppSnapshot?

    @ObservationIgnored private let clientsURL: URL
    @ObservationIgnored private let folders: [URL]
    @ObservationIgnored private let own: String
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var readAgain = false
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var changeTask: Task<Void, Never>?

    init(
        clientsURL: URL = LocationAppReader.clientsURL, folders: [URL] = LocationAppReader.applicationFolders,
        excluding own: String = PrivacyPrefs.ownBundleIdentifier
    ) {
        self.clientsURL = clientsURL
        self.folders = folders
        self.own = own
    }

    /// Reads the list again. A call while a read is under way reads once more after it.
    func refresh() {
        guard !reading else { readAgain = true; return }
        reading = true
        let (clients, folders, own) = (clientsURL, self.folders, self.own)
        Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                LocationAppReader.read(clients: clients, folders: folders, excluding: own)
            }.value
            guard let self else { return }
            if snapshot != self.snapshot { self.snapshot = snapshot }
            reading = false
            if readAgain { readAgain = false; refresh() }
        }
    }

    /// The picker has opened: read the list, and keep reading it as it changes until
    /// the last picker showing it closes.
    func appeared() {
        viewers += 1
        if viewers == 1 { watch() }
        refresh()
    }

    func disappeared() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { stopWatching() }
    }

    /// The window showing the option is closing, and whatever it had open with it.
    func closed() {
        viewers = 0
        stopWatching()
    }

    /// Location services replace the file rather than write into it, so a replaced
    /// file is watched afresh.
    private func watch() {
        stopWatching()
        let descriptor = open(clientsURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .attrib, .delete, .rename], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.fileChanged() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    private func fileChanged() {
        changeTask?.cancel()
        changeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, viewers > 0 else { return }
            watch()
            refresh()
        }
    }

    private func stopWatching() {
        changeTask?.cancel()
        changeTask = nil
        source?.cancel()
        source = nil
    }
}

// MARK: - Settings

/// Apps whose use of location isn't marked or announced: those the person expects
/// to look it up, Weather and Find My to begin with. The row says which; Choose opens
/// every app that uses location, as System Settings lists them, to pick from.
///
/// Settings keeps its window when closed, so the row doesn't come and go with it: the
/// list is read again each time the window comes to the front, and the picker closed
/// with the window.
struct IgnoredLocationApps: View {
    /// Apps using location now, and when Islet last saw others using it.
    var inUse: [PrivacyApp] = []
    var seen: [PrivacyApp: Date] = [:]
    var list = LocationAppList.shared
    @State private var ignored = PrivacyPrefs.ignoredLocationAppIDs
    @State private var isChoosing = false

    var body: some View {
        LabeledContent("Don't show for location") {
            HStack(spacing: 8) {
                Text(LocationAppChoices.summary(of: ignored.map { LocationAppChoices.name(of: $0, in: list.snapshot) }))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Choose…") { isChoosing = true }
                    .popover(isPresented: $isChoosing, arrowEdge: .trailing) {
                        LocationAppPicker(list: list, inUse: inUse, seen: seen, ignored: $ignored)
                    }
            }
        }
        .background(WindowEvents(becameKey: { list.refresh() }, closing: {
            isChoosing = false
            list.closed()
        }))
        .onAppear { list.refresh() }
    }
}

/// What the picker lists, in its sections, and how the row sums up the choice.
enum LocationAppChoices {
    /// Apple apps that commonly look the Mac's location up, offered alongside the
    /// installed apps when location services' own list can't be read.
    static let usual = [
        "com.apple.weather", "com.apple.findmy", "com.apple.Maps", "com.apple.reminders",
        "com.apple.Photos", "com.apple.Home", "com.apple.iCal",
    ]

    /// How recent a look-up puts an app among those that used location recently.
    static let recentWindow: TimeInterval = 7 * 24 * 60 * 60

    struct Sections: Equatable {
        /// In use now, or given the Mac's location in the past week, by location
        /// services' reckoning or Islet's, the latest first.
        var recent: [LocationApp] = []
        /// The rest, by name: location services' other apps, or, without their list,
        /// the apps already chosen, those Islet has seen, and Apple's usual ones.
        var others: [LocationApp] = []
        /// Without location services' list, every installed app that says it can use
        /// location, shown on request.
        var installed: [LocationApp] = []
        /// Whether any app used location recently, whatever the search, so the
        /// headings stay put while searching.
        var hasRecent = false

        var isEmpty: Bool { recent.isEmpty && others.isEmpty && installed.isEmpty }
    }

    /// The picker's apps, those matching `search` where it is set. `chosen` apps are
    /// always listed, even when nothing else knows them. Islet itself never is.
    /// `seen` holds when Islet last saw each app using location; where that is later
    /// than location services' time, it counts instead.
    static func sections(
        snapshot: LocationAppSnapshot, chosen: [String], inUse: [PrivacyApp], seen: [PrivacyApp: Date],
        search: String = "", now: Date = Date(), own: String = PrivacyPrefs.ownBundleIdentifier,
        lookUp: (String) -> LocationApp? = installedApp
    ) -> Sections {
        var byID: [String: LocationApp] = [:]
        for app in snapshot.apps { byID[app.id] = app }
        var sighted: [String] = []
        for (use, date) in inUse.map({ ($0, now) }) + seen.map({ ($0.key, $0.value) }) {
            guard let id = use.bundleIdentifier else { continue }
            var app = byID[id] ?? LocationApp(bundleIdentifier: id, name: use.name, bundlePath: use.bundlePath, lastUsed: nil)
            if date > app.lastUsed ?? .distantPast { app.lastUsed = date }
            byID[id] = app
            sighted.append(id)
        }
        func app(_ id: String) -> LocationApp {
            byID[id] ?? lookUp(id) ?? LocationApp(bundleIdentifier: id, name: id, bundlePath: nil, lastUsed: nil)
        }

        // The apps known to have used location, with the latest time for each.
        let used = unique((snapshot.source == .locationServices ? snapshot.apps.map(\.id) : []) + sighted).map(app)
        let recent = LocationAppReader.sorted(used.filter {
            ($0.lastUsed.map { now.timeIntervalSince($0) } ?? .infinity) <= recentWindow
        })
        let listed = Set(recent.map(\.id))

        var others = used + chosen.map(app)
        var installed: [LocationApp] = []
        if snapshot.source == .installedApps {
            others += usual.compactMap { byID[$0] ?? lookUp($0) }
            installed = snapshot.apps
        }
        others = unique(others.filter { !listed.contains($0.id) })
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let shown = listed.union(others.map(\.id))
        installed = installed.filter { !shown.contains($0.id) }

        let query = search.trimmingCharacters(in: .whitespaces)
        func keep(_ app: LocationApp) -> Bool {
            !LocationAppReader.isOwn(app.id, own)
                && (query.isEmpty || app.name.localizedStandardContains(query) || app.id.localizedStandardContains(query))
        }
        return Sections(
            recent: recent.filter(keep), others: others.filter(keep), installed: installed.filter(keep),
            hasRecent: recent.contains { !LocationAppReader.isOwn($0.id, own) }
        )
    }

    /// The apps the picker keeps listed: those chosen when it opened, so one switched
    /// off stays where it was, to be switched back on, and those chosen since.
    static func listed(openedWith opened: [String], now current: [String]) -> [String] {
        opened + current.filter { !opened.contains($0) }
    }

    /// `ids` with an app's own entry added or taken out. A helper is listed as the
    /// app it sits in, so each switch stands for exactly one entry.
    static func ids(_ ids: [String], setting bundleIdentifier: String, chosen: Bool) -> [String] {
        if chosen { return ids.contains(bundleIdentifier) ? ids : ids + [bundleIdentifier] }
        return ids.filter { $0 != bundleIdentifier }
    }

    /// "Weather, Find My" for one or two, a count for more.
    static func summary(of names: [String]) -> String {
        switch names.count {
        case 0: "None"
        case 1, 2: names.joined(separator: ", ")
        default: "\(names.count) apps"
        }
    }

    static func name(of bundleIdentifier: String, in snapshot: LocationAppSnapshot?) -> String {
        snapshot?.apps.first { $0.id == bundleIdentifier }?.name ?? installedApp(bundleIdentifier)?.name ?? bundleIdentifier
    }

    /// An installed app, by bundle identifier.
    static func installedApp(_ bundleIdentifier: String) -> LocationApp? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        let app = PrivacyApp(bundlePath: url.path)
        return LocationApp(bundleIdentifier: bundleIdentifier, name: app.name, bundlePath: url.path, lastUsed: nil)
    }

    private static func unique<T: Identifiable>(_ items: [T]) -> [T] {
        var seen = Set<T.ID>()
        return items.filter { seen.insert($0.id).inserted }
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}

/// Every app that uses location, searchable by name, each with a switch to leave it
/// out. Recent ones come first. Where location services' list can't be read, the
/// installed apps that say they can use location wait behind a button. Return stays
/// with the search; Escape closes it.
struct LocationAppPicker: View {
    let list: LocationAppList
    let inUse: [PrivacyApp]
    let seen: [PrivacyApp: Date]
    @Binding var ignored: [String]
    /// Empty and folded away when the popover opens; set otherwise only to draw it
    /// part way through.
    @State private var search: String
    @State private var showsInstalled: Bool
    /// The apps chosen when the picker opened.
    @State private var opened: [String]
    @SwiftUI.FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(
        list: LocationAppList, inUse: [PrivacyApp], seen: [PrivacyApp: Date], ignored: Binding<[String]>,
        search: String = "", showsInstalled: Bool = false
    ) {
        self.list = list
        self.inUse = inUse
        self.seen = seen
        _ignored = ignored
        _search = State(initialValue: search)
        _showsInstalled = State(initialValue: showsInstalled)
        _opened = State(initialValue: ignored.wrappedValue)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .padding(10)
            Divider()
            Group {
                if let snapshot = list.snapshot {
                    content(snapshot)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 340)
            Divider()
            HStack {
                Button("Reset to Weather and Find My") { set(PrivacyPrefs.defaultIgnoredLocationApps) }
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(10)
        }
        .frame(width: 340)
        .onAppear {
            searchFocused = true
            list.appeared()
        }
        .onDisappear { list.disappeared() }
    }

    @ViewBuilder
    private func content(_ snapshot: LocationAppSnapshot) -> some View {
        let sections = LocationAppChoices.sections(
            snapshot: snapshot, chosen: LocationAppChoices.listed(openedWith: opened, now: ignored),
            inUse: inUse, seen: seen, search: search
        )
        let searching = !search.trimmingCharacters(in: .whitespaces).isEmpty
        let fallback = snapshot.source == .installedApps
        if sections.isEmpty {
            Text(searching ? "No app matches." : "No app has asked for the Mac's location.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    section("Used location recently", sections.recent)
                    section(sections.hasRecent || fallback ? "Other apps" : "Apps that use location", sections.others)
                    if fallback {
                        if searching || showsInstalled {
                            section("Apps that can use location", sections.installed)
                        } else if !sections.installed.isEmpty {
                            Button("Show all apps that can use location") { showsInstalled = true }
                                .buttonStyle(.link)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                        Text("macOS's own list of apps using location can't be read, so these are the apps that say they can use it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ apps: [LocationApp]) -> some View {
        if !apps.isEmpty {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 2)
            ForEach(apps) { app in row(app) }
        }
    }

    private func row(_ app: LocationApp) -> some View {
        HStack(spacing: 8) {
            LocationAppIcon(app: app)
                .frame(width: 20, height: 20)
            Text(app.name).lineLimit(1)
            Spacer(minLength: 8)
            Toggle(app.name, isOn: Binding(
                get: { ignored.contains(app.id) },
                set: { set(LocationAppChoices.ids(ignored, setting: app.id, chosen: $0)) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func set(_ ids: [String]) {
        ignored = ids
        UserDefaults.standard.set(ids, forKey: PrivacyPrefs.ignoredLocationApps)
    }
}

/// An app's icon, or a plain app icon for one not on this Mac.
private struct LocationAppIcon: View {
    let app: LocationApp

    var body: some View {
        Image(nsImage: app.bundlePath.map { NSWorkspace.shared.icon(forFile: $0) } ?? NSWorkspace.shared.icon(for: .application))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
    }
}

/// Calls `becameKey` whenever the window it sits in comes to the front, and `closing`
/// as that window closes.
private struct WindowEvents: NSViewRepresentable {
    var becameKey: () -> Void
    var closing: () -> Void

    func makeNSView(context: Context) -> EventsView { EventsView() }

    func updateNSView(_ view: EventsView, context: Context) {
        view.becameKey = becameKey
        view.closing = closing
    }

    final class EventsView: NSView {
        var becameKey: () -> Void = {}
        var closing: () -> Void = {}
        private var observers: [NSObjectProtocol] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let centre = NotificationCenter.default
            observers = [
                centre.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.becameKey() }
                },
                centre.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.closing() }
                },
            ]
        }
    }
}
