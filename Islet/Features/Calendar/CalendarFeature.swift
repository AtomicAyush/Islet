import AppKit
import SwiftUI

/// The next event on the calendar, counting down beside the notch from a few minutes
/// before it starts until a few minutes in, with a Join button for video calls.
///
/// Access to the calendar is only ever asked for from a click, on the home tile or
/// in Settings; until then the feature shows the offer and nothing else.
@MainActor
final class CalendarFeature: Feature {
    let id = "calendar"
    let title = "Calendar"
    let symbol = "calendar"
    let summary = "Your next event, a few minutes before it starts."

    enum Key {
        static let leadMinutes = "calendar.leadMinutes"
        static let showJoin = "calendar.showJoin"
    }

    static let leadChoices = [5, 10, 15, 30]
    static let defaultLead = 10

    private let model = CalendarModel()
    private lazy var activity = CalendarActivity(model: model)
    private var isRunning = false
    private var isWidgetShown = false
    /// The priority the activity was last published with, so it is only re-sorted
    /// when that changes.
    private var publishedPriority: ActivityPriority?
    private var defaultsObserver: NSObjectProtocol?

    init() {
        model.onChange = { [weak self] in self?.sync() }
    }

    func start() {
        isRunning = true
        model.leadTime = Self.leadTime
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.leadTime = Self.leadTime }
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
        ]
    }

    /// `islet://calendar/join` joins the upcoming or current video call,
    /// `islet://calendar/open` shows the upcoming event in Calendar, and
    /// `islet://calendar/refresh` re-reads the calendar.
    func handle(_ url: URL) -> Bool {
        switch url.path() {
        case "/join":
            if let meeting = model.joinableMeeting() { CalendarApp.join(meeting) }
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

    private static var leadTime: TimeInterval {
        let minutes = UserDefaults.standard.integer(forKey: Key.leadMinutes)
        return TimeInterval((minutes > 0 ? minutes : defaultLead) * 60)
    }

    private func sync() {
        let center = ActivityCenter.shared

        // A preview can run while the feature is off; its tile comes and goes with it.
        let wantsWidget = isRunning || model.isShowingSample
        if wantsWidget != isWidgetShown {
            isWidgetShown = wantsWidget
            if wantsWidget {
                center.setHomeWidget(HomeWidget(
                    id: id, order: 20, weight: 1.5, view: AnyView(CalendarHomeTile(model: model))
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
        if !center.isShowing(id: activity.id) || publishedPriority != activity.priority {
            publishedPriority = activity.priority
            center.show(activity)
        }
    }
}

@MainActor
final class CalendarActivity: IslandActivity {
    let id = "calendar"
    let symbol = "calendar"
    let model: CalendarModel

    init(model: CalendarModel) { self.model = model }

    /// Joins the queue like any other activity, and takes the island over in the last
    /// two minutes.
    var priority: ActivityPriority { model.isImminent ? .high : .normal }
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

    var body: some View {
        Picker("Show an event", selection: $leadMinutes) {
            ForEach(CalendarFeature.leadChoices, id: \.self) { minutes in
                Text("\(minutes) minutes before it starts").tag(minutes)
            }
        }
        Toggle("Show Join button for video calls", isOn: $showJoin)
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
}
