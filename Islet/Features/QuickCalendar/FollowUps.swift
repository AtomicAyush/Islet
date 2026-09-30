import AppKit
import SwiftUI
import Observation

/// An event added from the box without a place, to ask about later. What is kept of it
/// between launches is only what finds the event again and says when to ask: its
/// identifiers, its start, when to ask and how often it has been asked. Never its
/// title, place or notes; those are read from the calendar as the card goes up.
struct FollowUp: Equatable {
    static let version = 1
    /// Asked about at most this often.
    static let maxAsks = 2

    /// EventKit's identifier for the event.
    let id: String
    /// Its identifier on the calendar's server, should the first change as it syncs.
    let externalID: String?
    /// When it starts, as added: an event that has moved since is not asked about.
    let start: Date
    var due: Date
    var asks: Int

    var saved: [String: Any] {
        var saved: [String: Any] = [
            "v": Self.version,
            "id": id,
            "start": start.timeIntervalSince1970,
            "due": due.timeIntervalSince1970,
            "asks": asks,
        ]
        if let externalID { saved["externalID"] = externalID }
        return saved
    }

    /// One read back, or `nil` for anything unreadable, of another version, or out of
    /// range.
    init?(saved: Any) {
        guard let saved = saved as? [String: Any],
              saved["v"] as? Int == Self.version,
              let id = saved["id"] as? String, !id.isEmpty, id.count < 1024,
              let start = saved["start"] as? Double, start.isFinite,
              let due = saved["due"] as? Double, due.isFinite, due <= start,
              let asks = saved["asks"] as? Int, (0..<Self.maxAsks).contains(asks)
        else { return nil }
        let externalID = saved["externalID"] as? String
        if saved["externalID"] != nil, externalID == nil { return nil }
        self.init(id: id, externalID: externalID, start: Date(timeIntervalSince1970: start),
                  due: Date(timeIntervalSince1970: due), asks: asks)
    }

    init(id: String, externalID: String?, start: Date, due: Date, asks: Int = 0) {
        self.id = id
        self.externalID = externalID
        self.start = start
        self.due = due
        self.asks = asks
    }
}

/// Where the follow-up's card goes up: the island (`IslandFollowUpPresenter`), or a
/// test's stand-in.
@MainActor
protocol FollowUpPresenter: AnyObject {
    /// Puts the card up, returning whether it is showing: Presentation Mode or a Focus
    /// can hold it back.
    func present(_ card: FollowUpCardModel) -> Bool
    /// Keeps the card up while the pointer is on it or its field is typed in.
    func hold(_ held: Bool)
    func dismiss()
    var isShowing: Bool { get }
}

/// Asks, a while after an event was added without a place, whether to add one: "Add a
/// place for Dentist?". It asks at most twice, never once the event has started, and
/// not at all for one deleted, moved or given a place meanwhile.
///
/// The list lives in the defaults, so a follow-up outlasts a restart, as a Pomodoro
/// session does; turning the feature off in Settings forgets it.
@MainActor
@Observable
final class QuickCalendarFollowUps {
    static let key = "feature.quickcalendar.followUps"
    static let maxAsks = FollowUp.maxAsks
    /// Asked no later than this before the event starts.
    static let lead: TimeInterval = 30 * 60
    /// An event closer than this when added isn't asked about: a nudge wouldn't help.
    static let soonest: TimeInterval = 15 * 60
    /// Not now: asked again in an hour, or a quarter of an hour before it starts.
    static let again: TimeInterval = 60 * 60
    static let lastCall: TimeInterval = 15 * 60
    /// Held back: tried again in a quarter of an hour.
    static let retry: TimeInterval = 15 * 60

    private(set) var pending: [FollowUp] = []
    /// The card up, if one is.
    private(set) var card: FollowUpCardModel?
    @ObservationIgnored var didWrite: () -> Void = {}

    @ObservationIgnored private let store: any CalendarStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: any KeepAwakeClock
    @ObservationIgnored private let presenter: any FollowUpPresenter
    @ObservationIgnored private var alarm: KeepAwakeAlarm?
    @ObservationIgnored private var isStarted = false

    init(store: any CalendarStore, defaults: UserDefaults, clock: any KeepAwakeClock, presenter: any FollowUpPresenter) {
        self.store = store
        self.defaults = defaults
        self.clock = clock
        self.presenter = presenter
    }

    // MARK: Lifecycle

    func start() {
        isStarted = true
        pending = ((defaults.array(forKey: Self.key) ?? []).compactMap(FollowUp.init(saved:)))
            .sorted { $0.due < $1.due }
        review()
    }

    /// Islet is quitting: the list is kept for the next launch.
    func close() {
        isStarted = false
        alarm?.cancel()
        alarm = nil
        if card != nil { presenter.dismiss() }
        card = nil
    }

    /// The feature was turned off: every follow-up is forgotten.
    func forget() {
        close()
        pending = []
        save()
    }

    // MARK: Adding and removing

    /// Asks about the event's place `delay` after `created`, or half an hour before it
    /// starts if that is sooner; not at all if that would be within a quarter of an hour.
    @discardableResult
    func add(_ added: AddedEvent, created: Date, delay: TimeInterval) -> Bool {
        let due = min(created.addingTimeInterval(delay), added.start.addingTimeInterval(-Self.lead))
        guard due >= created.addingTimeInterval(Self.soonest) else { return false }
        pending.removeAll { $0.id == added.id }
        pending.append(FollowUp(id: added.id, externalID: added.externalID, start: added.start, due: due))
        pending.sort { $0.due < $1.due }
        save()
        schedule()
        return true
    }

    func remove(id: String) {
        guard pending.contains(where: { $0.id == id }) else { return }
        pending.removeAll { $0.id == id }
        save()
        schedule()
    }

    // MARK: Asking

    /// Looks at the list again: at its alarm, and on wake, a change of clock or time
    /// zone, or a change to the calendars. Each one due is checked on the calendar and
    /// asked about, one at a time, or dropped without a word.
    func review() {
        guard isStarted else { return }
        let now = clock.now
        while card == nil, let next = pending.first, next.due <= now {
            guard let event = stillWanted(next, at: now) else {
                pending.removeFirst()
                continue
            }
            ask(next, about: event, at: now)
        }
        save()
        schedule()
    }

    /// The event as the calendar has it now, if it still wants a place: not deleted,
    /// not moved, not given a place or a call to join, and not started.
    private func stillWanted(_ followUp: FollowUp, at now: Date) -> DayEvent? {
        guard now < followUp.start,
              let event = store.event(id: followUp.id, externalID: followUp.externalID, start: followUp.start),
              event.start == followUp.start, !event.isAllDay, !event.isOnline,
              (event.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return event
    }

    private func ask(_ followUp: FollowUp, about event: DayEvent, at now: Date) {
        var followUp = followUp
        let card = FollowUpCardModel(
            followUp: followUp, eventID: event.eventID, title: Clashes.named(event), start: event.start, end: event.end
        )
        card.answer = { [weak self, weak card] answer in
            guard let self, let card else { return }
            self.answered(answer, card: card)
        }
        card.hold = { [weak self] held in self?.presenter.hold(held) }
        card.gone = { [weak self, weak card] in
            guard let self, let card, self.card === card, !self.presenter.isShowing else { return }
            self.card = nil
            self.review()
        }
        pending.removeFirst()
        guard presenter.present(card) else {
            // Held back: tried again a little later, if there is time.
            followUp.due = now.addingTimeInterval(Self.retry)
            if followUp.due < followUp.start.addingTimeInterval(-Self.lastCall) { insert(followUp) }
            return
        }
        self.card = card
        // Asked: counted now, so a card left unanswered, or Islet quitting under it,
        // counts too. The next time is set now, and Not now needs nothing more.
        followUp.asks += 1
        followUp.due = min(now.addingTimeInterval(Self.again), followUp.start.addingTimeInterval(-Self.lastCall))
        if followUp.asks < Self.maxAsks, followUp.due > now { insert(followUp) }
    }

    private func answered(_ answer: FollowUpCardModel.Answer, card: FollowUpCardModel) {
        switch answer {
        case .add(let place):
            let place = place.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !place.isEmpty else { return }
            do {
                // The event as it was found, under its identifier now.
                try store.update(id: card.eventID, location: place, notes: nil)
                didWrite()
            } catch {
                card.problem = "Calendar didn't take it — try again"
                return
            }
            pending.removeAll { $0.id == card.followUp.id }
        case .dontAsk:
            pending.removeAll { $0.id == card.followUp.id }
        case .notNow:
            break
        }
        if self.card === card {
            self.card = nil
            presenter.dismiss()
        }
        save()
        schedule()
    }

    private func insert(_ followUp: FollowUp) {
        pending.removeAll { $0.id == followUp.id }
        pending.append(followUp)
        pending.sort { $0.due < $1.due }
    }

    // MARK: Keeping

    /// One alarm, for the soonest due.
    private func schedule() {
        alarm?.cancel()
        alarm = nil
        guard isStarted, let next = pending.first?.due else { return }
        alarm = clock.schedule(at: max(next, clock.now)) { [weak self] in self?.review() }
    }

    /// Written only when the list changes.
    private func save() {
        let stored = defaults.array(forKey: Self.key)
        guard !pending.isEmpty else {
            if stored != nil { defaults.removeObject(forKey: Self.key) }
            return
        }
        let current = (stored ?? []).compactMap(FollowUp.init(saved:))
        guard current != pending || stored?.count != pending.count else { return }
        defaults.set(pending.map(\.saved), forKey: Self.key)
    }
}

/// The card asking for a place, while it is up: the event's title and start, read from
/// the calendar as it went up, and the place being typed. Memory only.
@MainActor
@Observable
final class FollowUpCardModel {
    enum Answer: Equatable {
        case add(String)
        case notNow
        case dontAsk
    }

    let followUp: FollowUp
    /// The event's identifier as the calendar has it now, which a sync may have changed
    /// since it was added.
    let eventID: String
    let title: String
    let start: Date
    let end: Date
    var place = ""
    var problem: String?
    /// A preview's: its buttons only close it.
    var isSample = false
    @ObservationIgnored var answer: (Answer) -> Void = { _ in }
    @ObservationIgnored var hold: (Bool) -> Void = { _ in }
    @ObservationIgnored var gone: () -> Void = {}

    init(followUp: FollowUp, eventID: String? = nil, title: String, start: Date, end: Date) {
        self.followUp = followUp
        self.eventID = eventID ?? followUp.id
        self.title = title
        self.start = start
        self.end = end
    }

    static let bannerID = "quickcalendar.followup"
}

/// The follow-up's card in the island, as a card banner: held while the pointer is on
/// it or its field is typed in, as the Screenshots card is.
@MainActor
final class IslandFollowUpPresenter: FollowUpPresenter {
    static let duration: TimeInterval = 20
    static let heldDuration: TimeInterval = 10 * 60
    private var banner: IslandBanner?

    func present(_ card: FollowUpCardModel) -> Bool {
        let banner = IslandBanner(
            id: FollowUpCardModel.bannerID,
            style: .card(width: FollowUpCardLayout.width, height: FollowUpCardLayout.height),
            duration: Self.duration,
            interruption: .active,
            personal: .schedule,
            content: AnyView(FollowUpCard(card: card))
        )
        self.banner = banner
        let center = ActivityCenter.shared
        center.present(banner)
        guard center.banner?.id == FollowUpCardModel.bannerID else {
            // Held back, or waiting to know whether it will be: it is asked again later.
            center.dismissBanner(id: FollowUpCardModel.bannerID)
            self.banner = nil
            return false
        }
        return true
    }

    func hold(_ held: Bool) {
        guard var banner, isShowing else { return }
        banner.duration = held ? Self.heldDuration : Self.duration
        ActivityCenter.shared.present(banner)
    }

    func dismiss() {
        ActivityCenter.shared.dismissBanner(id: FollowUpCardModel.bannerID)
        banner = nil
    }

    var isShowing: Bool {
        ActivityCenter.shared.banner?.id == FollowUpCardModel.bannerID
    }
}
