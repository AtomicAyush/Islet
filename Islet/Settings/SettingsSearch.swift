import AppKit
import SwiftUI

/// Words Settings search finds something by, besides its title (and, for a feature,
/// its summary).
struct SettingsSearchTerms {
    /// The words on its settings: the toggles', pickers' and headings' labels.
    var labels: [String] = []
    /// Other words people use for it: other names, apps it works with, abbreviations.
    var keywords: [String] = []
}

/// One thing a search can find: a row of the General tab, or a feature's section.
struct SettingsSearchEntry: Identifiable {
    enum Source {
        case general(GeneralRow)
        case feature(any Feature)
    }

    /// Also the row's scroll target in its tab.
    let id: String
    let source: Source
    let title: String
    /// The tag of the tab it is on.
    let tab: String
    /// The results group it goes under: a General section, or the feature itself.
    let groupID: String
    let heading: String
    /// Its place in Settings, which breaks ties.
    let order: Int
    fileprivate let fields: [SettingsSearchIndex.Field]
}

/// Entries shown together under one heading, in the order Settings shows them.
struct SettingsSearchGroup: Identifiable {
    let id: String
    let tab: String
    let heading: String
    let entries: [SettingsSearchEntry]

    var tabTitle: String { tab == "general" ? "General" : "Activities" }

    /// What its Show button shows, for VoiceOver.
    var spokenName: String { entries.count == 1 ? entries[0].title : "these settings" }
}

/// Every General row and feature, as words ready to compare. Built once, the first
/// time anything is searched for.
@MainActor
struct SettingsSearchIndex {
    /// How strongly a word counts, strongest first: a title beats the label of a
    /// setting, which beats another name, which beats the summary.
    enum Rank: Int, Comparable {
        case summary = 1, keyword, label, title

        static func < (a: Rank, b: Rank) -> Bool { a.rawValue < b.rawValue }
    }

    fileprivate struct Field {
        let rank: Rank
        let words: [String]
    }

    let entries: [SettingsSearchEntry]

    init(features: [any Feature]) {
        var entries: [SettingsSearchEntry] = []
        for row in GeneralRow.allCases {
            let terms = row.searchTerms
            let section = row.section
            entries.append(SettingsSearchEntry(
                id: row.id,
                source: .general(row),
                title: row.title,
                tab: "general",
                groupID: "general." + (section ?? ""),
                heading: section.map { "General › \($0)" } ?? "General",
                order: entries.count,
                fields: Self.fields(title: row.title, terms: terms, summary: section)
            ))
        }
        for feature in features {
            entries.append(SettingsSearchEntry(
                id: "feature." + feature.id,
                source: .feature(feature),
                title: feature.title,
                tab: "activities",
                groupID: "feature." + feature.id,
                heading: "Activities › \(feature.title)",
                order: entries.count,
                fields: Self.fields(title: feature.title, terms: feature.searchTerms, summary: feature.summary)
            ))
        }
        self.entries = entries
    }

    private static func fields(title: String, terms: SettingsSearchTerms, summary: String?) -> [Field] {
        [
            Field(rank: .title, words: words(in: title)),
            Field(rank: .label, words: terms.labels.flatMap(words)),
            Field(rank: .keyword, words: terms.keywords.flatMap(words)),
            Field(rank: .summary, words: summary.map(words) ?? []),
        ]
    }

    /// The words of `text`, without case or accents, so "Résumé" and "resume" compare
    /// equal. Anything that is not a letter or digit separates them: "per-app" is two.
    nonisolated static func words(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// The entries every word of `query` starts a word of, best first. A word counts
    /// by the strongest place it is found, a little more where it is the whole word,
    /// and an entry by all of its words together; ties keep Settings' own order.
    func search(_ query: String) -> [SettingsSearchEntry] {
        let wanted = Self.words(in: query)
        guard !wanted.isEmpty else { return [] }
        var scored: [(entry: SettingsSearchEntry, score: Int)] = []
        for entry in entries {
            var total = 0
            var all = true
            for word in wanted {
                var best = 0
                for field in entry.fields {
                    for candidate in field.words where candidate.hasPrefix(word) {
                        best = max(best, field.rank.rawValue * 10 + (candidate == word ? 2 : 0))
                    }
                }
                if best == 0 { all = false; break }
                total += best
            }
            if all { scored.append((entry, total)) }
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.entry.order < $1.entry.order }
            .map(\.entry)
    }

    /// `search(query)` under their headings: the groups in the order of their best
    /// entry, and a group's entries in the order Settings shows them.
    func groups(for query: String) -> [SettingsSearchGroup] {
        let found = search(query)
        var order: [String] = []
        var members: [String: [SettingsSearchEntry]] = [:]
        for entry in found {
            if members[entry.groupID] == nil { order.append(entry.groupID) }
            members[entry.groupID, default: []].append(entry)
        }
        return order.map { id in
            let entries = members[id]!.sorted { $0.order < $1.order }
            return SettingsSearchGroup(id: id, tab: entries[0].tab, heading: entries[0].heading, entries: entries)
        }
    }
}

/// Where a result was shown in its tab: the row to bring into view once the tab shows.
struct SettingsScrollTarget: Equatable {
    let tab: String
    let id: String
}

/// The Settings window's search: what the field holds, the results for it, and the
/// row a result was shown at in its tab.
@MainActor
@Observable
final class SettingsSearch {
    /// How long a row stays lit after a result is shown in its tab.
    static let highlightDuration: Duration = .seconds(1.6)

    private(set) var query = ""
    private(set) var groups: [SettingsSearchGroup] = []
    /// Counts changes to the query, telling a query typed again from the last time it
    /// was typed.
    private(set) var revision = 0
    /// The rows lit for a moment after a result is shown in its tab.
    private(set) var highlighted: Set<String> = []
    /// Taken by the tab it names once it has scrolled there.
    var pendingScroll: SettingsScrollTarget?

    /// Where Settings keeps its tab and every setting; a test's own suite in the harness.
    @ObservationIgnored let defaults: UserDefaults
    /// Puts text in the search field when the search changes from elsewhere.
    @ObservationIgnored var showQuery: ((String) -> Void)?
    /// Gives the search field the keyboard.
    @ObservationIgnored var focusField: (() -> Void)?
    /// Swaps the tabs for the results, or back, as a search starts or ends.
    @ObservationIgnored var searchingChanged: ((Bool) -> Void)?

    @ObservationIgnored private let features: @MainActor () -> [any Feature]
    @ObservationIgnored private var builtIndex: SettingsSearchIndex?
    @ObservationIgnored private var fade: Task<Void, Never>?
    @ObservationIgnored private var announcement: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, features: @escaping @MainActor () -> [any Feature] = { FeatureRegistry.shared.features }) {
        self.defaults = defaults
        self.features = features
    }

    var index: SettingsSearchIndex {
        if let builtIndex { return builtIndex }
        let index = SettingsSearchIndex(features: features())
        builtIndex = index
        return index
    }

    /// Whether the results stand in for the tabs: anything but spaces is a search.
    var isSearching: Bool { !query.allSatisfy(\.isWhitespace) }

    /// What VoiceOver says once typing pauses.
    var spokenSummary: String {
        let count = groups.reduce(0) { $0 + $1.entries.count }
        if count == 0 { return "No settings match “\(query.trimmingCharacters(in: .whitespaces))”" }
        return count == 1 ? "1 result" : "\(count) results"
    }

    /// The field's text changed.
    func search(_ text: String) {
        guard text != query else { return }
        let wasSearching = isSearching
        query = text
        revision += 1
        groups = isSearching ? index.groups(for: text) : []
        if isSearching != wasSearching { searchingChanged?(isSearching) }
        announce()
    }

    /// Escape, or the field's clear button: back to the tab that was showing, which a
    /// search never changes.
    func clear() {
        showQuery?("")
        search("")
    }

    func focus() {
        focusField?()
    }

    /// Ends the search and shows `tab`, even if it is the tab already chosen.
    func showTab(_ tab: String) {
        clear()
        defaults.set(tab, forKey: SettingsView.tabKey)
    }

    /// Ends the search and shows `group` in its tab, scrolled to and lit for a moment.
    func show(_ group: SettingsSearchGroup) {
        let rows = group.entries.map(\.id)
        showTab(group.tab)
        pendingScroll = SettingsScrollTarget(tab: group.tab, id: rows[0])
        highlighted = Set(rows)
        fade?.cancel()
        fade = Task { [weak self] in
            try? await Task.sleep(for: Self.highlightDuration)
            guard !Task.isCancelled else { return }
            self?.highlighted = []
        }
    }

    private func announce() {
        announcement?.cancel()
        guard isSearching else { return }
        announcement = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [.announcement: spokenSummary, .priority: NSAccessibilityPriorityLevel.medium.rawValue]
            )
        }
    }
}
