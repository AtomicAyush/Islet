import AppKit
import SwiftUI

/// The next event on the calendar, counting down beside the notch from a few minutes
/// before it starts until a few minutes in, with a Join button for video calls. The
/// button comes beside the notch too as a call draws near, and stays until ten minutes
/// in for anyone running late, or until it is clicked.
///
/// Access to the calendar is only ever asked for from a click, on the home tile or
/// in Settings; until then the feature shows the offer and nothing else.
@MainActor
final class CalendarFeature: Feature {
    let id = "calendar"
    let title = "Calendar"
    let symbol = "calendar"
    let summary = "Your next event, a few minutes before it starts."

    /// Where the tile goes on the home page, until the person puts it somewhere else.
    static let tileOrder = 20
    var homeTile: HomeTileInfo? { HomeTileInfo(self, order: Self.tileOrder) }

    enum Key {
        static let leadMinutes = "calendar.leadMinutes"
        static let showJoin = "calendar.showJoin"
        static let joinLeadMinutes = "calendar.joinLeadMinutes"
    }

    static let leadChoices = [5, 10, 15, 30]
    static let defaultLead = 10
    /// How long before a call its Join button can come beside the notch, never sooner
    /// than the event itself shows (`CalendarTiming.joinWindow`).
    static let joinLeadChoices = [1, 2, 5, 10]
    static let defaultJoinLead = 5

    let model: CalendarModel
    private lazy var activity = CalendarActivity(model: model)
    private var isRunning = false
    private var isWidgetShown = false
    /// The priority and trailing width the activity was last published with, so it is
    /// only re-published when one of them changes.
    private var publishedPriority: ActivityPriority?
    private var publishedTrailingWidth: CGFloat?
    private var defaultsObserver: NSObjectProtocol?

    /// Tests hand in a model of their own.
    init(model: CalendarModel? = nil) {
        let model = model ?? CalendarModel()
        self.model = model
        model.onChange = { [weak self] in self?.sync() }
    }

    func start() {
        isRunning = true
        applySettings()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }
        model.start()
        sync()
    }

    func stop() {
        isRunning = false
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        model.stop()
        ActivityCenter.shared.end(id: activity.id)
        ActivityCenter.shared.removeHomeWidget(id: id)
        isWidgetShown = false
        publishedPriority = nil
        publishedTrailingWidth = nil
    }

    func settingsView() -> AnyView? {
        AnyView(CalendarSettings(model: model))
    }

    /// Each runs for ten seconds on sample events, then hands back to the calendar.
    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "Meeting in 5 minutes") { [model] in
                model.showSample([.sampleMeeting()], for: 10)
            },
            FeaturePreview(title: "Event starting now") { [model] in
                model.showSample([.sampleStartingNow()], for: 10)
            },
            FeaturePreview(title: "Up next on the home page") { [model] in
                model.showSample(CalendarEvent.sampleDay(), for: 10)
                IslandManager.shared.focusedController?.model.expand(focus: IslandViewModel.homeFocus)
            },
            FeaturePreview(title: "Joining a call that has started") { [model] in
                model.showSample([.sampleMeetingUnderway()], for: 10)
            },
        ]
    }

    /// `islet://calendar/join` joins the video call under way or coming up
    /// (`CalendarModel.eventToJoin`), `islet://calendar/open` shows the upcoming event
    /// in Calendar, and `islet://calendar/refresh` re-reads the calendar.
    func handle(_ url: URL) -> Bool {
        switch url.path() {
        case "/join":
            joinMeeting()
        case "/open":
            let now = Date()
            if let event = model.featured ?? model.visibleEvents.first(where: { !$0.isAllDay && $0.end > now }) {
                CalendarApp.show(event)
            }
        case "/refresh":
            model.refresh()
        default:
            return false
        }
        return true
    }

    /// Joins the call under way or coming up, and returns it, or `nil` with none to join.
    @discardableResult
    func joinMeeting() -> CalendarEvent? {
        guard let event = model.eventToJoin() else { return nil }
        model.join(event)
        return event
    }

    /// Whether the calendar has been read since the feature started, or never can be.
    var hasReadCalendar: Bool {
        isRunning && (model.hasFetched || model.access != .granted)
    }

    private func applySettings() {
        let defaults = UserDefaults.standard
        model.leadTime = Self.minutes(defaults.integer(forKey: Key.leadMinutes), or: Self.defaultLead)
        let showsJoin = defaults.object(forKey: Key.showJoin) as? Bool ?? true
        model.joinLead = showsJoin
            ? Self.minutes(defaults.integer(forKey: Key.joinLeadMinutes), or: Self.defaultJoinLead)
            : nil
    }

    private static func minutes(_ minutes: Int, or fallback: Int) -> TimeInterval {
        TimeInterval((minutes > 0 ? minutes : fallback) * 60)
    }

    private func sync() {
        let center = ActivityCenter.shared

        // A preview can run while the feature is off; its tile comes and goes with it.
        let wantsWidget = isRunning || model.isShowingSample
        if wantsWidget != isWidgetShown {
            isWidgetShown = wantsWidget
            if wantsWidget {
                center.setHomeWidget(HomeWidget(
                    id: id, order: Self.tileOrder, weight: 1.5, personal: .schedule, view: AnyView(CalendarHomeTile(model: model))
                ))
            } else {
                center.removeHomeWidget(id: id)
            }
        }

        guard model.featured != nil else {
            center.end(id: activity.id)
            publishedPriority = nil
            return
        }
        if !center.isShowing(id: activity.id) || publishedPriority != activity.priority
            || publishedTrailingWidth != activity.compactTrailingWidth {
            publishedPriority = activity.priority
            publishedTrailingWidth = activity.compactTrailingWidth
            center.show(activity)
        }
    }
}

@MainActor
final class CalendarActivity: IslandActivity {
    let id = "calendar"
    let name = "Calendar"
    var spokenStatus: String? {
        guard let event = model.featured else { return nil }
        let minutes = CalendarCountdown.minutes(until: event.start, at: Date())
        return minutes > 0 ? "\(event.title), in \(minutes) \(minutes == 1 ? "minute" : "minutes")" : "\(event.title), now"
    }
    let symbol = "calendar"
    /// Its page lists the events by title.
    var personal: PersonalContent? { .schedule }
    let model: CalendarModel

    init(model: CalendarModel) { self.model = model }

    /// Joins the queue like any other activity, and takes the island over from two
    /// minutes before, or from when its Join button comes, until five minutes in
    /// (`CalendarTiming.State.isImminent`).
    var priority: ActivityPriority { model.isImminent ? .high : .normal }
    /// Room for the Join button beside the countdown while it is up.
    var compactTrailingWidth: CGFloat? { model.showsJoin ? CalendarCompactJoin.width : nil }
    var expandedHeight: CGFloat { 96 }

    func compactLeading() -> AnyView { AnyView(CalendarCompactLeading(model: model)) }
    func compactTrailing() -> AnyView { AnyView(CalendarCompactTrailing(model: model)) }
    func minimal() -> AnyView { AnyView(CalendarMinimal(model: model)) }
    func expanded() -> AnyView { AnyView(CalendarExpanded(model: model)) }
}

private struct CalendarSettings: View {
    let model: CalendarModel
    @AppStorage(CalendarFeature.Key.leadMinutes) private var leadMinutes = CalendarFeature.defaultLead
    @AppStorage(CalendarFeature.Key.showJoin) private var showJoin = true
    @AppStorage(CalendarFeature.Key.joinLeadMinutes) private var joinLeadMinutes = CalendarFeature.defaultJoinLead

    var body: some View {
        Picker("Show an event", selection: $leadMinutes) {
            ForEach(CalendarFeature.leadChoices, id: \.self) { minutes in
                Text("\(minutes) minutes before it starts").tag(minutes)
            }
        }
        Toggle("Show Join button for video calls", isOn: $showJoin)
        Picker(selection: joinLead) {
            ForEach(joinLeadChoices, id: \.self) { minutes in
                Text(minutes == 1 ? "1 minute before it starts" : "\(minutes) minutes before it starts").tag(minutes)
            }
        } label: {
            Text("Join beside the notch")
            Text("Until five minutes in, the call takes the island over from music and other activities. Rest the pointer on the green camera a moment, then click to join.")
        }
        .disabled(!showJoin)
        LabeledContent("Calendar access") {
            switch model.access {
            case .granted:
                Text("Allowed").foregroundStyle(.secondary)
            case .undetermined:
                Button("Allow…") { model.requestAccess() }
            case .denied, .restricted:
                HStack {
                    Text(model.access == .denied ? "Off" : "Restricted").foregroundStyle(.secondary)
                    Button("Open Privacy Settings…") { CalendarApp.openPrivacySettings() }
                }
            }
        }
        .onAppear { model.refreshAccess() }
    }

    /// No sooner than the event itself shows.
    private var joinLeadChoices: [Int] {
        CalendarFeature.joinLeadChoices.filter { $0 <= leadMinutes }
    }

    /// The choice nearest the one made that the event's lead allows, as the model takes it.
    private var joinLead: Binding<Int> {
        Binding(
            get: {
                let choices = joinLeadChoices
                return choices.last { $0 <= joinLeadMinutes } ?? choices.first ?? CalendarFeature.defaultJoinLead
            },
            set: { joinLeadMinutes = $0 }
        )
    }
}
