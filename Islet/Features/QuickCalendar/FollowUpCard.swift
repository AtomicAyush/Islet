import AppKit
import SwiftUI

enum FollowUpCardLayout {
    static let width: CGFloat = 340
    static let height: CGFloat = 112
}

/// The card asking for the place of an event added without one: its field, and Add, Not
/// now and Don't ask. The field is typed in only once it is clicked, which gives the
/// island the keyboard; the card stays up meanwhile.
struct FollowUpCard: View {
    @Bindable var card: FollowUpCardModel
    @Environment(\.island) private var island
    @SwiftUI.FocusState private var isFocused: Bool
    @State private var isHovering = false

    private static let place = TypingPlace.card(FollowUpCardModel.bannerID)

    var body: some View {
        let format = QuickCalendarFormat(calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent, now: Date())
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.islandAccent(.quickCalendar))
                    .accessibilityHidden(true)
                // Two lines for a long title, then cut from its end: its start names the event.
                Text("Add a place for \(Text(card.title).bold())?")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.islandText(0.9))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Text(format.day(card.start) + " " + format.time(card.start))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.islandText(0.55))
                    .lineLimit(1)
                    .fixedSize()
            }
            field
            HStack(spacing: 6) {
                QuickAddFilledButton(title: "Add", isEnabled: !card.place.trimmingCharacters(in: .whitespaces).isEmpty) {
                    finish(.add(card.place))
                }
                InputQuietButton(title: "Not now", symbol: "clock.arrow.circlepath") { finish(.notNow) }
                InputQuietButton(title: "Don't ask", symbol: "bell.slash") { finish(.dontAsk) }
                    .help("Turn these off in Settings › Quick Calendar")
                Spacer(minLength: 0)
                InputQuietButton(title: "More…", symbol: "calendar") { openInCalendar() }
                    .help("Open the event in Calendar")
            }
            Text(card.problem ?? "Turn these off in Settings")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(card.problem == nil ? .islandText(0.4) : .islandHueText(.warning))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: FollowUpCardLayout.width, height: FollowUpCardLayout.height, alignment: .topLeading)
        .onHover { hovering in
            isHovering = hovering
            card.hold(hovering || isTypingHere)
        }
        .onChange(of: isTypingHere) { _, typing in card.hold(typing || isHovering) }
        .onChange(of: island?.focusRequest ?? 0) { _, _ in takeCaret() }
        .onDisappear {
            if isTypingHere { island?.endTyping(.done) }
            let gone = card.gone
            DispatchQueue.main.async { gone() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Add a place for \(card.title)?")
    }

    private var isTypingHere: Bool {
        island?.typingPlace == Self.place
    }

    @ViewBuilder
    private var field: some View {
        HStack(spacing: 5) {
            ZStack(alignment: .leading) {
                if card.place.isEmpty {
                    Text("Location")
                        .foregroundStyle(.islandText(0.4, on: .surface(0.1)))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextField("", text: $card.place)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.islandPrimary)
                    .focused($isFocused)
                    .onSubmit { finish(.add(card.place)) }
                    .onExitCommand { island?.endTyping(.escape) }
                    .accessibilityLabel("Location")
                if !isTypingHere {
                    // The island has no keyboard until the field is clicked: the click
                    // is the person asking to type.
                    Rectangle()
                        .fill(.islandDecorative(0))
                        .contentShape(Rectangle())
                        .onTapGesture { beginTyping() }
                        .accessibilityHidden(true)
                }
            }
            .font(.system(size: 12))
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.islandSurface(0.1)))
        .accessibilityAction(named: "Type a place") { beginTyping() }
    }

    private func beginTyping() {
        guard let island else { return }
        InputCenter.shared.beginTyping(island, Self.place, TypingClient(
            key: { action in
                switch action {
                case .accept: finish(.add(card.place))
                case .close: island.endTyping(.close)
                case .mode, .look: break
                }
            },
            leavesPage: false
        ))
    }

    private func takeCaret() {
        guard isTypingHere else { return }
        DispatchQueue.main.async { isFocused = true }
    }

    private func finish(_ answer: FollowUpCardModel.Answer) {
        if case .add(let place) = answer, place.trimmingCharacters(in: .whitespaces).isEmpty { return }
        if isTypingHere { island?.endTyping(.done) }
        if card.isSample {
            ActivityCenter.shared.dismissBanner(id: FollowUpCardModel.bannerID)
            return
        }
        card.answer(answer)
    }

    private func openInCalendar() {
        if isTypingHere { island?.endTyping(.done) }
        guard !card.isSample else { return }
        CalendarApp.show(CalendarEvent(
            id: card.eventID, eventIdentifier: card.eventID, occurrence: nil, title: card.title,
            start: card.start, end: card.end, isAllDay: false, location: nil, color: nil, meeting: nil
        ))
    }
}
