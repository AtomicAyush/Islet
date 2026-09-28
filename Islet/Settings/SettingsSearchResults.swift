import SwiftUI

/// What both of the Settings window's views, the tabs and the results, see: the
/// search, and the defaults every setting is kept in. Whatever else Settings puts in
/// the environment for its controls belongs here too, or results go without it.
struct SettingsWindowEnvironment: ViewModifier {
    let search: SettingsSearch

    func body(content: Content) -> some View {
        content
            .modifier(SettingsIslandTheme())
            .environment(search)
            .defaultAppStorage(search.defaults)
    }
}

extension View {
    func settingsWindowEnvironment(_ search: SettingsSearch) -> some View {
        modifier(SettingsWindowEnvironment(search: search))
    }
}

/// Every match, grouped under its tab and section or feature, each with its real
/// controls and a button that shows it in its tab. Shown in place of the tabs while
/// the toolbar's field has a query, and empty otherwise.
struct SettingsSearchResults: View {
    /// Groups shown straight away, enough to fill the window. The rest follow once
    /// typing pauses, a few at a time: making every feature's settings for a query
    /// like "s" at once takes as long as opening the Activities tab, which would hold
    /// up a keystroke typed meanwhile.
    static let firstGroups = 6
    static let groupsPerStep = 3

    let search: SettingsSearch
    @AppStorage(SettingsView.tabKey) private var tab = "general"
    /// How many groups are shown, and for which change to the query.
    @State private var shown: (revision: Int, count: Int) = (0, firstGroups)

    var body: some View {
        Group {
            if !search.isSearching {
                Color.clear
            } else if search.groups.isEmpty {
                ContentUnavailableView {
                    Label("No settings match “\(search.query.trimmingCharacters(in: .whitespaces))”",
                          systemImage: "magnifyingglass")
                } description: {
                    Text("Try the name of an activity, or a word from one of its settings.")
                }
            } else {
                Form {
                    ForEach(search.groups.prefix(shown.revision == search.revision ? shown.count : Self.firstGroups)) { group in
                        ResultGroup(group: group, search: search)
                    }
                }
                .task(id: search.revision) { await showTheRest() }
                .formStyle(.grouped)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Search results")
            }
        }
        // A tab asked for from elsewhere (an islet://settings link) shows itself
        // rather than waiting behind the results.
        .onChange(of: tab) {
            if search.isSearching { search.clear() }
        }
    }

    /// Once typing pauses, adds the groups not yet shown a few at a time, letting the
    /// window draw and take keys in between.
    private func showTheRest() async {
        let revision = search.revision
        try? await Task.sleep(for: .milliseconds(250))
        var count = Self.firstGroups
        while !Task.isCancelled, count < search.groups.count {
            count += Self.groupsPerStep
            shown = (revision, count)
            try? await Task.sleep(for: .milliseconds(15))
        }
    }
}

/// One group of results. Equatable, so that typing on leaves a group that still
/// matches as it is rather than making its settings again.
private struct ResultGroup: View, Equatable {
    let group: SettingsSearchGroup
    let search: SettingsSearch

    var body: some View {
        if case .feature(let feature) = group.entries[0].source {
            FeatureSection(feature: feature, saysWhenOff: true) {
                ResultHeading(group: group, search: search)
            }
        } else {
            Section {
                ForEach(group.entries) { entry in
                    if case .general(let row) = entry.source { row }
                }
            } header: {
                ResultHeading(group: group, search: search)
            }
        }
    }

    static func == (a: ResultGroup, b: ResultGroup) -> Bool {
        a.group.id == b.group.id && a.group.entries.map(\.id) == b.group.entries.map(\.id)
    }
}

private struct ResultHeading: View {
    let group: SettingsSearchGroup
    let search: SettingsSearch

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(group.heading)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                search.show(group)
            } label: {
                Text("Show in \(group.tabTitle)")
                    .font(.callout)
            }
            .buttonStyle(.link)
            .accessibilityLabel("Show \(group.spokenName) in \(group.tabTitle)")
        }
    }
}

extension View {
    /// Marks the row a search result scrolls to in its tab, and lights it for a
    /// moment when one does.
    func settingsSearchTarget(_ id: String) -> some View {
        modifier(SearchHighlight(id: id)).id(id)
    }

    /// Lights this row with the target `id` names, for a result that spans rows.
    func settingsSearchHighlight(_ id: String) -> some View {
        modifier(SearchHighlight(id: id))
    }

    /// Brings a result's row into view when it is shown in this tab.
    func settingsSearchScrolling(tab: String) -> some View {
        modifier(SearchScrolling(tab: tab))
    }
}

private struct SearchHighlight: ViewModifier {
    let id: String
    @Environment(SettingsSearch.self) private var search: SettingsSearch?

    func body(content: Content) -> some View {
        let lit = search?.highlighted.contains(id) ?? false
        content.background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(lit ? 0.2 : 0))
                .padding(.horizontal, -6)
                .padding(.vertical, -3)
                .animation(.easeOut(duration: lit ? 0.15 : 0.9), value: lit)
                .accessibilityHidden(true)
        }
    }
}

private struct SearchScrolling: ViewModifier {
    let tab: String
    @Environment(SettingsSearch.self) private var search: SettingsSearch?

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .onAppear { scroll(proxy) }
                .onChange(of: search?.pendingScroll) { scroll(proxy) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let search, let target = search.pendingScroll, target.tab == tab else { return }
        search.pendingScroll = nil
        // The tab's rows are laid out just after it appears.
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(target.id, anchor: .center)
            }
        }
    }
}
