import AppKit
import SwiftUI
import Observation

/// Where a clash's card goes up: the island (`IslandClashPresenter`), or a test's
/// stand-in.
@MainActor
protocol ClashPresenter: AnyObject {
    /// Nothing else is showing, and the island is closed: a moment to tell of a clash.
    var isResting: Bool { get }
    /// Puts the card up, returning whether it is showing: Presentation Mode or a Focus
    /// can hold it back.
    func present(_ card: ClashCardModel) -> Bool
}

/// Tells of each clash today and tomorrow once, on a card, while the island is resting:
/// "Standup and Dentist overlap 15:00 – 15:15". Settings' Tell me about clashes turns it
/// off.
///
/// What has been told is kept in memory only, so after a restart a clash may be told
/// again. A clash the person saw as they added the event in the box isn't told.
@MainActor
final class QuickCalendarClashes {
    /// Looked at again this long after a card went up, or couldn't: one card at a time.
    static let again: TimeInterval = 60

    private(set) var told: Set<String> = []
    /// Events added in the box, by identifier, whose clashes were shown there.
    private var hushed: Set<String> = []
    /// The model it tells of, which owns it.
    weak var model: QuickCalendarModel?
    private let clock: any KeepAwakeClock
    private let presenter: any ClashPresenter
    private var alarm: KeepAwakeAlarm?
    private var isStarted = false
    /// When the last card went up.
    private var lastTold: Date?

    init(clock: any KeepAwakeClock, presenter: any ClashPresenter) {
        self.clock = clock
        self.presenter = presenter
    }

    func start() {
        isStarted = true
        review()
    }

    func stop() {
        isStarted = false
        alarm?.cancel()
        alarm = nil
    }

    /// The event was added in the box, which showed its clashes as it was typed.
    func hush(_ added: AddedEvent) {
        hushed.insert(added.id)
    }

    /// The next clash not yet told, today's then tomorrow's, if it has yet to start.
    func untold(at now: Date) -> (clash: Clash, day: QuickDay)? {
        guard let model, model.access == .granted else { return nil }
        for day in QuickDay.allCases {
            for clash in model.plan(day, at: now).clashes where clash.second.start > now && !told.contains(clash.id) {
                let ids = [clash.first.eventID, clash.second.eventID].compactMap { $0 }
                if ids.contains(where: hushed.contains) { continue }
                return (clash, day)
            }
        }
        return nil
    }

    /// Tells of the next clash if the island is resting, and otherwise looks again in a
    /// minute.
    func review() {
        alarm?.cancel()
        alarm = nil
        guard isStarted, let model, model.tellsClashes else { return }
        let now = clock.now
        guard let (clash, day) = untold(at: now) else { return }
        let next = lastTold.map { $0.addingTimeInterval(Self.again) } ?? now
        if next <= now, presenter.isResting {
            let words = DayWords(format: QuickCalendarFormat(model: model))
            let card = ClashCardModel(clash: clash, day: day, sentence: words.sentence(clash))
            if presenter.present(card) {
                told.insert(clash.id)
                lastTold = now
            }
        }
        alarm = clock.schedule(at: max(next, now.addingTimeInterval(Self.again))) { [weak self] in self?.review() }
    }
}

/// A clash as its card tells it.
@MainActor
final class ClashCardModel {
    static let bannerID = "quickcalendar.clash"
    let clash: Clash
    let day: QuickDay
    let sentence: String

    init(clash: Clash, day: QuickDay, sentence: String) {
        self.clash = clash
        self.day = day
        self.sentence = sentence
    }
}

enum ClashCardLayout {
    static let width: CGFloat = 340
    static let height: CGFloat = 76
}

/// The clash's card in the island, as a card banner.
@MainActor
final class IslandClashPresenter: ClashPresenter {
    static let duration: TimeInterval = 8

    var isResting: Bool {
        ActivityCenter.shared.banner == nil
            && !IslandManager.shared.controllers.values.contains { $0.model.isExpanded || $0.model.typingPlace != nil }
    }

    func present(_ card: ClashCardModel) -> Bool {
        let center = ActivityCenter.shared
        center.present(IslandBanner(
            id: ClashCardModel.bannerID,
            style: .card(width: ClashCardLayout.width, height: ClashCardLayout.height),
            duration: Self.duration,
            interruption: .active,
            personal: .schedule,
            content: AnyView(ClashCard(card: card))
        ))
        guard center.banner?.id == ClashCardModel.bannerID else {
            // Held back: it is told later.
            center.dismissBanner(id: ClashCardModel.bannerID)
            return false
        }
        return true
    }
}

/// "Clash today": the two events and what is wrong, and the way to the Day page.
struct ClashCard: View {
    let card: ClashCardModel
    @Environment(\.island) private var island

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.islandHue(.warning))
                    .accessibilityHidden(true)
                Text(card.day == .today ? "Clash today" : "Clash tomorrow")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.islandHueText(.warning))
                Spacer(minLength: 4)
                InputQuietButton(title: "Show day", symbol: DayPageLayout.symbol) { showDay() }
                    .fixedSize()
                    .accessibilityHint("Opens your day in the island")
            }
            Text(card.sentence)
                .font(.system(size: 12.5))
                .foregroundStyle(.islandText(0.9))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: ClashCardLayout.width, height: ClashCardLayout.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel((card.day == .today ? "Clash today: " : "Clash tomorrow: ") + card.sentence)
    }

    private func showDay() {
        FeatureRegistry.shared.feature(QuickCalendarFeature.self)?.model.dayShown = card.day
        ActivityCenter.shared.dismissBanner(id: ClashCardModel.bannerID)
        (island ?? IslandManager.shared.focusedController?.model)?.expand(focus: QuickCalendarFeature.pageID)
    }
}
