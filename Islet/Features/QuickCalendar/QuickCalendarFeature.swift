import AppKit
import SwiftUI

/// An event added by typing it, in the island's box: "+Dentist tomorrow 3pm", or ⌘2 in
/// the box, and Add. The box shows what it read before anything is written, with blanks
/// for the place and notes and a warning if it clashes with the day; only Add writes,
/// and only that event, to the calendar chosen. Undo takes it away again for a while.
///
/// Left without a place, the event is asked about a couple of hours later (or half an
/// hour before it starts, if sooner) on a card: "Add a place for Dentist?". What is kept
/// for that between launches is only the event's identifiers and times
/// (`QuickCalendarFollowUps`).
///
/// The Today tile says how the day stands (free until when, and any clashes), and its
/// Summarise opens the Day page: free time, travel and events, from the start of the
/// person's day or from now. A clash is two busy events that overlap, or too little time
/// between them to get from one place to the other (`Clashes`, `DayPlan`); each is told
/// once on a card, if Settings asks. "Summarise my day", typed in the box, is answered
/// the same way.
///
/// Nothing typed is sent anywhere or kept: events are read by rules on this Mac
/// (`EventParser`), and the box forgets what was typed as it closes. The calendar is
/// never sent to a model: the day is worked out on this Mac.
@MainActor
final class QuickCalendarFeature: Feature {
    let id = "quickcalendar"
    let title = "Quick Calendar"
    let symbol = "calendar.badge.plus"
    let summary = "Add an event by typing it in the island, see when you're free, and hear of clashes."

    enum Key {
        /// The calendar events are added to; empty for the person's default.
        static let calendar = "feature.quickcalendar.calendar"
        /// Minutes an event lasts when nothing typed says.
        static let length = "feature.quickcalendar.length"
        static let askDetails = "feature.quickcalendar.askDetails"
        /// Hours after adding an event its missing place is asked for.
        static let askAfter = "feature.quickcalendar.askAfter"
        /// Minutes allowed to get to an event with a place.
        static let travel = "feature.quickcalendar.travel"
        /// The person's day, in minutes after midnight: free time is looked for within it.
        static let dayFrom = "feature.quickcalendar.dayFrom"
        static let dayTo = "feature.quickcalendar.dayTo"
        /// The calendars left out of clashes and free time, by identifier: a calendar
        /// added later is checked.
        static let unchecked = "feature.quickcalendar.unchecked"
        static let tellClashes = "feature.quickcalendar.tellClashes"
    }

    static let lengthChoices = [30, 45, 60, 90]
    static let defaultLength = 60
    static let askAfterChoices = [1, 2, 3, 4]
    static let defaultAskAfter = 2
    static let travelChoices = [0, 15, 30, 45, 60]
    static let defaultTravel = 30
    /// The lengths the preview's chip offers.
    static let previewLengths = [15, 30, 45, 60, 90, 120, 180]

    static let defaultDayFrom = 8 * 60
    static let defaultDayTo = 22 * 60

    static let modeID = "event"
    /// The Day page, as `islet://open?focus=quickcalendar` opens it.
    static let pageID = "quickcalendar"
    static let summariseID = "quickcalendar.summarise"

    /// Where the Today tile goes on the home page: just after Up next.
    static let tileOrder = 21
    var homeTile: HomeTileInfo? { HomeTileInfo(self, order: Self.tileOrder) }

    let model: QuickCalendarModel
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var changeWork: DispatchWorkItem?
    /// The Day page's height as last published.
    private var publishedHeight: CGFloat?

    init(model: QuickCalendarModel) {
        self.model = model
    }

    func start() {
        let model = model
        model.daysChanged = { [weak self] in self?.daysChanged() }
        model.refresh()
        InputCenter.shared.register(Self.mode(model))
        InputCenter.shared.register(Self.summarise(model))
        model.followUps.start()
        model.clashes.start()
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didWakeNotification)
        observe(.default, .NSSystemClockDidChange)
        observe(.default, .NSSystemTimeZoneDidChange)
        observe(.default, .NSCalendarDayChanged)
        model.store.changed = { [weak self] in self?.calendarsChanged() }
        let center = ActivityCenter.shared
        center.setHomeWidget(HomeWidget(
            id: id, order: Self.tileOrder, personal: .schedule,
            view: AnyView(QuickCalendarTodayTile(
                model: model,
                summarise: {
                    model.dayShown = .today
                    IslandManager.shared.focusedController?.model.select(focus: QuickCalendarFeature.pageID)
                },
                newEvent: { InputCenter.shared.open(QuickCalendarFeature.modeID) }
            ))
        ))
        publishPage()
    }

    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        changeWork?.cancel()
        changeWork = nil
        model.store.changed = {}
        model.daysChanged = {}
        model.clashes.stop()
        InputCenter.shared.unregister(id: Self.modeID)
        InputCenter.shared.unregister(command: Self.summariseID)
        ActivityCenter.shared.removeHomeWidget(id: id)
        ActivityCenter.shared.removePage(id: Self.pageID)
        publishedHeight = nil
        let stillOn = model.defaults.object(forKey: Prefs.Key.featureEnabled(id)) as? Bool ?? enabledByDefault
        if stillOn {
            // Islet is quitting: follow-ups are kept for the next launch.
            model.followUps.close()
        } else {
            model.followUps.forget()
        }
    }

    func settingsView() -> AnyView? {
        AnyView(QuickCalendarSettings(model: model))
    }

    /// A card for a made-up event, whose buttons only close it.
    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "Asking for a missing place") {
                let start = Date().addingTimeInterval(3 * 3600)
                let card = FollowUpCardModel(
                    followUp: FollowUp(id: "sample", externalID: nil, start: start, due: Date()),
                    title: "Dentist", start: start, end: start.addingTimeInterval(3600)
                )
                card.isSample = true
                let presenter = IslandFollowUpPresenter()
                card.hold = { presenter.hold($0) }
                _ = presenter.present(card)
            },
        ]
    }

    /// Event mode in the box.
    static func mode(_ model: QuickCalendarModel) -> InputMode {
        InputMode(
            id: modeID, title: "New event", symbol: "calendar.badge.plus", tint: .quickCalendar,
            placeholder: "Dentist tomorrow 3pm", order: 1, prefix: "+",
            suggest: { suggestion(for: $0, model: model) },
            makeSession: { QuickAddSession(model: model) }
        )
    }

    /// "Summarise my day", typed in either mode: answered from the calendar on this Mac,
    /// and never sent to a model unless the person asks for just those words to be.
    static func summarise(_ model: QuickCalendarModel) -> InputCommand {
        InputCommand(
            id: summariseID,
            matches: { DaySummaryRequest.day(for: $0) != nil },
            hint: "Summarise your day from Calendar, on this Mac",
            symbol: DayPageLayout.symbol,
            view: { text, anyway in
                AnyView(DaySummaryAnswer(model: model, day: DaySummaryRequest.day(for: text) ?? .today, anyway: anyway))
            }
        )
    }

    /// Typed in Ask mode, a line that reads as an event rather than a question offers to
    /// add it: "Add “Dentist” tomorrow 15:00 to Calendar?". Taking it only switches the box to
    /// Event mode, where it can be checked before anything is added.
    static func suggestion(for text: String, model: QuickCalendarModel) -> String? {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" })
        guard !text.trimmingCharacters(in: .whitespaces).hasSuffix("?"),
              let first = words.first, !questionWords.contains(String(first)) else { return nil }
        let parsed = model.parser().parse(text)
        guard let start = parsed.start, !parsed.title.isEmpty else { return nil }
        let format = QuickCalendarFormat(model: model)
        let when = parsed.isAllDay ? format.dayInSentence(start) : format.dayInSentence(start) + " " + format.time(start)
        return "Add “\(parsed.title)” \(when) to Calendar?"
    }

    static let questionWords: Set<String> = [
        "what", "whats", "what's", "when", "where", "who", "whom", "whose", "why", "how", "which", "is", "are", "was",
        "were", "can", "could", "should", "would", "will", "do", "does", "did", "am", "has", "have", "tell", "explain",
    ]

    // MARK: Keeping up

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A new day, or the clock moved: today and tomorrow are read again.
                self.model.readDays()
                self.model.followUps.review()
                self.model.clashes.review()
            }
        }
        observers.append((center, token))
    }

    /// The calendars changed, here or on another device: EventKit tells of it in bursts
    /// while a calendar syncs, and one look after it settles is enough.
    private func calendarsChanged() {
        changeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.refresh()
                self.model.followUps.review()
                self.model.clashes.review()
                (InputCenter.shared.box.session as? QuickAddSession)?.calendarChanged()
            }
        }
        changeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: Day

    /// The days read changed, or the Day page shows the other one.
    private func daysChanged() {
        publishPage()
        model.clashes.review()
    }

    /// The Day page, at the height of the day it shows.
    private func publishPage() {
        let plan = model.access == .granted ? model.plan(model.dayShown, at: model.now()) : nil
        let height = DayPageLayout.height(for: plan)
        guard height != publishedHeight else { return }
        let center = ActivityCenter.shared
        let page = IslandPage(id: Self.pageID, symbol: DayPageLayout.symbol, height: height, view: AnyView(DayPage(model: model)))
        if publishedHeight == nil {
            center.setPage(page)
        } else {
            withAnimation(.islandMorph) { center.setPage(page) }
        }
        publishedHeight = height
    }
}

extension FeatureTint {
    /// Event mode's chip, Add and the follow-up card: Calendar's blue.
    static let quickCalendar = FeatureTint.colour(CalendarPalette.blue)
}
